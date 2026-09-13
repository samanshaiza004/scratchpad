use gpui_kit::base::Selectable;
use gpui_kit::component::button::Button;
use gpui_kit::component::list::ListItem;
use gpui_kit::component::tab::{Tab, TabBar};
use gpui_kit::component::tree::{Tree, TreeItem, TreeState};
use gpui_kit::{
    App, AppContext, Context, Entity, FocusHandle, InteractiveElement, IntoElement, ParentElement,
    Render, Styled, Window, application, div, prelude::FluentBuilder, px,
};
use scratchpad_gpui::app::ShellModel;
use scratchpad_gpui::backend::BackendSessionConfig;
use scratchpad_gpui::commands::{CommandPaletteModel, ProductCommandId};
use scratchpad_gpui::editor::EditorSession;
use scratchpad_gpui::scheduler::BackendUpdate;
use scratchpad_gpui::scheduler::{BackendCommand, BackendScheduler};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

struct ShellView {
    model: ShellModel,
    scheduler: BackendScheduler,
    tree: Entity<TreeState>,
    focus: FocusHandle,
    editor: Option<EditorSession>,
    palette: CommandPaletteModel,
    sidebar_visible: bool,
    editor_font_size: f32,
    viewport_start_line: usize,
    find_open: bool,
}

impl ShellView {
    fn new(
        model: ShellModel,
        scheduler: BackendScheduler,
        tree: Entity<TreeState>,
        focus: FocusHandle,
    ) -> Self {
        Self {
            model,
            scheduler,
            tree,
            focus,
            editor: None,
            palette: CommandPaletteModel::default(),
            sidebar_visible: true,
            editor_font_size: 16.0,
            viewport_start_line: 0,
            find_open: false,
        }
    }

    fn sync_tree(&self, cx: &mut Context<Self>) {
        let items = self
            .model
            .tree
            .iter()
            .map(|row| TreeItem::new(row.path.clone(), row.name.clone()))
            .collect::<Vec<_>>();
        self.tree.update(cx, |state, cx| state.set_items(items, cx));
    }

    fn apply_backend_update(&mut self, update: BackendUpdate, cx: &mut Context<Self>) {
        let response = update.response.clone();
        self.model.apply_update(update);

        if let Some(slice) = self.model.visible.as_ref() {
            self.viewport_start_line = slice.start_line;
            let reset = self.editor.as_ref().is_none_or(|editor| {
                editor.document_id() != slice.document_id
                    || editor.editor_revision() != slice.editor_revision
            });
            if reset {
                self.editor =
                    EditorSession::from_visible(slice, self.model.state.application_revision).ok();
            }
        } else if self.model.active_document().is_none() {
            self.editor = None;
        }

        if let Some(response) = response {
            if let Some(acknowledgement) = response.edit.as_ref() {
                if let Some(editor) = self.editor.as_mut() {
                    if response.ok {
                        if let Err(error) = editor.acknowledge(acknowledgement, &self.model.state) {
                            self.model.status.message = format!("edit reconciliation: {error}");
                        }
                    } else if response.outcome.code == "stale_editor_revision" {
                        let _ = editor.reject();
                        let _ = self.scheduler.submit(BackendCommand::ReadVisibleLines {
                            document_id: editor.document_id().to_string(),
                            start_line: 0,
                        });
                    }
                }
            }
        }
        cx.notify();
    }

    fn handle_editor_key(&mut self, event: &gpui_kit::KeyDownEvent) {
        let Some(editor) = self.editor.as_mut() else {
            return;
        };
        let key = event.keystroke.key.as_str();
        let modifiers = event.keystroke.modifiers;
        let extend = modifiers.shift;
        let mut intent = None;
        let mut viewport_request = None;
        match key {
            "left" => {
                let _ = editor.move_left(extend);
            }
            "right" => {
                let _ = editor.move_right(extend);
            }
            "up" => {
                let _ = editor.move_vertical(-1, extend);
            }
            "down" => {
                let _ = editor.move_vertical(1, extend);
            }
            "home" => {
                let _ = editor.move_home(extend);
            }
            "end" => {
                let _ = editor.move_end(extend);
            }
            "pageup" => {
                self.viewport_start_line = self.viewport_start_line.saturating_sub(64);
                viewport_request = Some(self.viewport_start_line);
            }
            "pagedown" => {
                self.viewport_start_line = self.viewport_start_line.saturating_add(64);
                viewport_request = Some(self.viewport_start_line);
            }
            "backspace" => {
                intent = editor.delete_backward().ok().flatten();
            }
            "enter" => {
                intent = editor.insert_text("\n").ok();
            }
            "a" if modifiers.control || modifiers.platform => editor.select_all(),
            _ => {
                if !modifiers.control
                    && !modifiers.alt
                    && !modifiers.platform
                    && let Some(text) = event.keystroke.key_char.as_deref()
                    && !text.is_empty()
                {
                    intent = editor.insert_text(text).ok();
                }
            }
        }
        if let Some(intent) = intent {
            let _ = self.scheduler.submit(BackendCommand::ReplaceDocument {
                document_id: intent.document_id,
                editor_revision: intent.editor_revision,
                start_byte: intent.start_byte,
                end_byte: intent.end_byte,
                replacement: intent.replacement,
            });
        }
        if let Some(start_line) = viewport_request {
            let _ = self.scheduler.submit(BackendCommand::ReadVisibleLines {
                document_id: editor.document_id().to_string(),
                start_line,
            });
        }
    }

    fn dispatch_product_command(&mut self, id: ProductCommandId) {
        match id.as_str() {
            "file.save" => {
                if !self.model.state.active.is_empty() {
                    let _ = self.scheduler.submit(BackendCommand::SaveDocument(
                        self.model.state.active.clone(),
                    ));
                }
            }
            "document.close" => {
                if !self.model.state.active.is_empty() {
                    let _ = self.scheduler.submit(BackendCommand::CloseDocument {
                        document_id: self.model.state.active.clone(),
                        discard: false,
                    });
                }
            }
            "workspace.refresh" => {
                let _ = self.scheduler.submit(BackendCommand::RefreshWorkspace);
            }
            "view.toggle-sidebar" => self.sidebar_visible = !self.sidebar_visible,
            "settings.open" => self.model.settings_open = !self.model.settings_open,
            "document.find" | "document.find-replace" => self.find_open = true,
            "document.find-next" | "document.find-previous" => {
                if self.model.matches.is_empty() {
                    self.model.status.message = "No current-document matches".to_string();
                }
            }
            "view.increase-font-size" => {
                self.editor_font_size = (self.editor_font_size + 1.0).min(48.0)
            }
            "view.decrease-font-size" => {
                self.editor_font_size = (self.editor_font_size - 1.0).max(8.0)
            }
            "view.reset-font-size" => self.editor_font_size = 16.0,
            "edit.select-all" => {
                if let Some(editor) = self.editor.as_mut() {
                    editor.select_all();
                }
            }
            "tab.next" | "tab.previous" => self.select_adjacent_tab(id.as_str() == "tab.next"),
            _ => {
                self.model.status.message = format!(
                    "{} is available in the command vocabulary; this surface is not wired yet",
                    id.as_str()
                );
            }
        }
    }

    fn select_adjacent_tab(&mut self, next: bool) {
        let docs = &self.model.state.documents;
        if docs.is_empty() {
            return;
        }
        let current = docs
            .iter()
            .position(|doc| doc.id == self.model.state.active)
            .unwrap_or(0);
        let index = if next {
            (current + 1) % docs.len()
        } else {
            (current + docs.len() - 1) % docs.len()
        };
        let _ = self
            .scheduler
            .submit(BackendCommand::SelectDocument(docs[index].id.clone()));
    }

    fn handle_palette_key(&mut self, event: &gpui_kit::KeyDownEvent) {
        let key = event.keystroke.key.as_str();
        match key {
            "escape" => {
                self.palette.close();
                self.model.command_palette_open = false;
            }
            "up" => self.palette.move_selection(-1),
            "down" => self.palette.move_selection(1),
            "enter" => {
                if let Some(command) = self.palette.selected_command() {
                    self.dispatch_product_command(command.id);
                    self.palette.close();
                    self.model.command_palette_open = false;
                }
            }
            "backspace" => {
                let mut query = self.palette.query().to_string();
                query.pop();
                self.palette.set_query(query);
            }
            _ => {
                if !event.keystroke.modifiers.control
                    && !event.keystroke.modifiers.alt
                    && !event.keystroke.modifiers.platform
                    && let Some(text) = event.keystroke.key_char.as_deref()
                {
                    let mut query = self.palette.query().to_string();
                    query.push_str(text);
                    self.palette.set_query(query);
                }
            }
        }
    }

    fn handle_find_key(&mut self, event: &gpui_kit::KeyDownEvent) {
        match event.keystroke.key.as_str() {
            "escape" => self.find_open = false,
            "backspace" => {
                self.model.find_query.pop();
            }
            "enter" => {
                if !self.model.find_query.is_empty() && !self.model.state.active.is_empty() {
                    let _ = self.scheduler.submit(BackendCommand::FindCurrent {
                        document_id: self.model.state.active.clone(),
                        query: self.model.find_query.clone(),
                    });
                }
            }
            _ => {
                if !event.keystroke.modifiers.control
                    && !event.keystroke.modifiers.alt
                    && !event.keystroke.modifiers.platform
                    && let Some(text) = event.keystroke.key_char.as_deref()
                {
                    self.model.find_query.push_str(text);
                }
            }
        }
    }
}

impl Render for ShellView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let active = self
            .model
            .active_document()
            .map(|doc| doc.path.clone())
            .unwrap_or_else(|| "No document selected".to_string());
        let viewport = self
            .model
            .visible
            .as_ref()
            .map(|slice| {
                let header = format!(
                    "lines {}–{} · revision {}{}\n",
                    slice.start_line,
                    slice.end_line,
                    slice.editor_revision,
                    if slice.truncated { " · bounded" } else { "" }
                );
                if let Some(editor) = self.editor.as_ref() {
                    format!("{header}{}", editor.display_text_with_caret())
                } else {
                    format!("{header}{}", slice.display_text())
                }
            })
            .unwrap_or_else(|| format!("Read-only document viewport\n{active}"));
        let tab_ids = self
            .model
            .state
            .documents
            .iter()
            .map(|document| document.id.clone())
            .collect::<Vec<_>>();
        let tab_scheduler = self.scheduler.clone();
        let tabs = self
            .model
            .state
            .documents
            .iter()
            .enumerate()
            .fold(
                TabBar::new("documents").underline(),
                |tabs, (_index, doc)| {
                    tabs.child(
                        Tab::new()
                            .label(format!(
                                "{}{}",
                                if doc.dirty { "● " } else { "" },
                                file_name(&doc.path)
                            ))
                            .selected(doc.id == self.model.state.active),
                    )
                },
            )
            .on_click(move |index, _, _| {
                if let Some(document_id) = tab_ids.get(*index) {
                    let _ =
                        tab_scheduler.submit(BackendCommand::SelectDocument(document_id.clone()));
                }
            });
        let workspace_root = self.model.state.workspace_root.clone();
        let tree_scheduler = self.scheduler.clone();
        let tree = Tree::new(&self.tree, move |index, entry, selected, _, _| {
            let relative = entry.item().id.to_string();
            let label = format!(
                "{}{}",
                if entry.is_folder() { "▸ " } else { "  " },
                entry.item().label
            );
            let mut item = ListItem::new(("workspace-entry", index))
                .child(div().pl(px((entry.depth() as f32) * 12.0)).child(label))
                .selected(selected);
            if !workspace_root.is_empty() {
                let path = PathBuf::from(&workspace_root).join(relative);
                let scheduler = tree_scheduler.clone();
                let relative_path = entry.item().id.to_string();
                let is_folder = entry.is_folder();
                item = item.on_click(move |_, _, _| {
                    let command = if is_folder {
                        BackendCommand::ListDirectory(Some(PathBuf::from(relative_path.clone())))
                    } else {
                        BackendCommand::OpenPath(path.clone())
                    };
                    let _ = scheduler.submit(command);
                });
            }
            item
        });

        let active_id = self.model.state.active.clone();
        let save_id = active_id.clone();
        let close_id = active_id.clone();
        let save_scheduler = self.scheduler.clone();
        let close_scheduler = self.scheduler.clone();
        let command_palette = cx.listener(|view, _, _, cx| {
            if view.model.command_palette_open {
                view.palette.close();
            } else {
                view.palette.open();
            }
            view.model.command_palette_open = !view.model.command_palette_open;
            cx.notify();
        });
        let settings = cx.listener(|view, _, _, cx| {
            view.model.settings_open = !view.model.settings_open;
            cx.notify();
        });
        let editor_key = cx.listener(|view, event, _, cx| {
            view.handle_editor_key(event);
            cx.notify();
        });
        let palette_key = cx.listener(|view, event, _, cx| {
            view.handle_palette_key(event);
            cx.notify();
        });
        let find = cx.listener(|view, _, _, cx| {
            view.find_open = !view.find_open;
            cx.notify();
        });
        let find_key = cx.listener(|view, event, _, cx| {
            view.handle_find_key(event);
            cx.notify();
        });
        let editor_focus = self.focus.clone();
        let palette_focus = self.focus.clone();
        let find_focus = self.focus.clone();

        let palette_items = self
            .palette
            .filtered_commands()
            .into_iter()
            .take(12)
            .enumerate()
            .fold(div().flex().flex_col().gap_1(), |list, (index, command)| {
                let selected = index == self.palette.selected_index();
                let id = command.id;
                let label = format!("{}  ·  {}", command.title, command.id.as_str());
                let on_click = cx.listener(move |view, _, _, cx| {
                    view.dispatch_product_command(id);
                    view.palette.close();
                    view.model.command_palette_open = false;
                    cx.notify();
                });
                list.child(
                    Button::new(format!("palette-command-{index}"))
                        .label(label)
                        .selected(selected)
                        .on_click(on_click),
                )
            });
        let palette_panel = div()
            .id("command-palette-panel")
            .track_focus(&palette_focus)
            .on_key_down(palette_key)
            .p_3()
            .border_1()
            .child(format!("Command palette  {}", self.palette.query()))
            .child(palette_items);
        let find_panel = div()
            .id("find-panel")
            .track_focus(&find_focus)
            .on_key_down(find_key)
            .p_3()
            .border_1()
            .child(format!(
                "Find: {}  ·  {}{}",
                self.model.find_query,
                self.model.matches.len(),
                if self.model.matches_truncated {
                    "+ matches"
                } else {
                    " matches"
                }
            ));

        let close_dialog_id = self.model.close_dialog.clone();
        let close_dialog = close_dialog_id.map(|document_id| {
            let save_scheduler = self.scheduler.clone();
            let discard_scheduler = self.scheduler.clone();
            let save_id = document_id.clone();
            let discard_id = document_id.clone();
            let save = cx.listener(move |view, _, _, cx| {
                let _ = save_scheduler.submit(BackendCommand::SaveDocument(save_id.clone()));
                view.model.close_dialog = None;
                cx.notify();
            });
            let discard = cx.listener(move |view, _, _, cx| {
                let _ = discard_scheduler.submit(BackendCommand::CloseDocument {
                    document_id: discard_id.clone(),
                    discard: true,
                });
                view.model.close_dialog = None;
                cx.notify();
            });
            let cancel = cx.listener(|view, _, _, cx| {
                view.model.close_dialog = None;
                cx.notify();
            });
            div()
                .id("close-dialog")
                .p_4()
                .border_1()
                .child("Unsaved changes")
                .child(format!("{} has unsaved changes.", file_name(&document_id)))
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(Button::new("close-save").label("Save").on_click(save))
                        .child(
                            Button::new("close-discard")
                                .label("Discard")
                                .on_click(discard),
                        )
                        .child(Button::new("close-cancel").label("Cancel").on_click(cancel)),
                )
        });
        let settings_panel = if self.model.settings_open {
            let increase = cx.listener(|view, _, _, cx| {
                view.dispatch_product_command(
                    scratchpad_gpui::commands::command_by_id("view.increase-font-size")
                        .expect("known command"),
                );
                cx.notify();
            });
            let decrease = cx.listener(|view, _, _, cx| {
                view.dispatch_product_command(
                    scratchpad_gpui::commands::command_by_id("view.decrease-font-size")
                        .expect("known command"),
                );
                cx.notify();
            });
            let reset = cx.listener(|view, _, _, cx| {
                view.dispatch_product_command(
                    scratchpad_gpui::commands::command_by_id("view.reset-font-size")
                        .expect("known command"),
                );
                cx.notify();
            });
            Some(
                div()
                    .p_3()
                    .border_1()
                    .child("Settings")
                    .child(format!("Editor font size: {:.0}px", self.editor_font_size))
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(Button::new("font-decrease").label("−").on_click(decrease))
                            .child(Button::new("font-reset").label("Reset").on_click(reset))
                            .child(Button::new("font-increase").label("+").on_click(increase)),
                    ),
            )
        } else {
            None
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .p_2()
                    .child(
                        Button::new("command-palette")
                            .label("Command palette")
                            .on_click(command_palette),
                    )
                    .child(Button::new("find").label("Find").on_click(find))
                    .child(Button::new("save").label("Save").on_click(move |_, _, _| {
                        if !save_id.is_empty() {
                            let _ = save_scheduler
                                .submit(BackendCommand::SaveDocument(save_id.clone()));
                        }
                    }))
                    .child(
                        Button::new("close")
                            .label("Close")
                            .on_click(move |_, _, _| {
                                if !close_id.is_empty() {
                                    let _ = close_scheduler.submit(BackendCommand::CloseDocument {
                                        document_id: close_id.clone(),
                                        discard: false,
                                    });
                                }
                            }),
                    )
                    .child(Button::new("settings").label("Settings").on_click(settings)),
            )
            .child(
                div()
                    .flex()
                    .flex_1()
                    .when(self.sidebar_visible, |this| {
                        this.child(div().w_64().border_r_1().child(tree))
                    })
                    .child(
                        div().flex().flex_col().flex_1().child(tabs).child(
                            div()
                                .id("editor-surface")
                                .flex_1()
                                .p_4()
                                .track_focus(&editor_focus)
                                .on_key_down(editor_key)
                                .child(div().text_size(px(self.editor_font_size)).child(viewport)),
                        ),
                    ),
            )
            .when_some(
                self.model.command_palette_open.then_some(palette_panel),
                |this, panel| this.child(panel),
            )
            .when(self.find_open, |this| this.child(find_panel))
            .when_some(settings_panel, |this, panel| this.child(panel))
            .when_some(close_dialog, |this, dialog| this.child(dialog))
            .child(div().p_2().child(format!(
                "{} · revision {} · {}",
                self.model.status.message,
                self.model.state.revision,
                self.model.workspace_name()
            )))
    }
}

fn file_name(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(path)
        .to_string()
}

fn main() {
    if std::env::var_os("SCRATCHPAD_GPUI_SMOKE").is_some() {
        match run_native_smoke() {
            Ok(revision) => eprintln!("scratchpad-gpui ready revision={revision} shutdown=ok"),
            Err(error) => {
                eprintln!("scratchpad-gpui smoke failed: {error}");
                std::process::exit(1);
            }
        }
        return;
    }
    run_application();
}

fn run_application() {
    application().run(|cx: &mut App| {
        gpui_kit::init(cx);
        let config = BackendSessionConfig {
            backend_library: std::env::var_os("SCRATCHPAD_GPUI_BACKEND_LIBRARY")
                .map(std::path::PathBuf::from),
            workspace_path: std::env::var_os("SCRATCHPAD_GPUI_WORKSPACE")
                .map(std::path::PathBuf::from),
        };
        let (scheduler, updates, backend_task) = BackendScheduler::start_on_gpui(cx, config);
        backend_task.detach();
        let _ = scheduler.submit(BackendCommand::ListDirectory(None));
        let mut view_entity = None;
        let window = cx
            .open_window(Default::default(), |_, cx| {
                let tree = cx.new(|cx| TreeState::new(cx));
                let focus = cx.focus_handle();
                let entity = cx.new(|_| {
                    ShellView::new(
                        ShellModel::default(),
                        scheduler.clone(),
                        tree.clone(),
                        focus.clone(),
                    )
                });
                view_entity = Some(entity.clone());
                entity
            })
            .expect("failed to open Scratchpad GPUI window");
        let weak_view = view_entity
            .expect("window entity was not created")
            .downgrade();
        let _ = window;
        cx.spawn(async move |cx| {
            while let Ok(update) = updates.recv().await {
                if weak_view
                    .update(cx, |view, cx| {
                        let has_listing = update.listing.is_some();
                        view.apply_backend_update(update, cx);
                        if has_listing {
                            view.sync_tree(cx);
                        }
                        cx.notify();
                    })
                    .is_err()
                {
                    break;
                }
            }
        })
        .detach();
    });
}

fn run_native_smoke() -> Result<u64, String> {
    let result = Arc::new(Mutex::new(None));
    let result_for_app = result.clone();
    let config = BackendSessionConfig {
        backend_library: std::env::var_os("SCRATCHPAD_GPUI_BACKEND_LIBRARY").map(PathBuf::from),
        workspace_path: std::env::var_os("SCRATCHPAD_GPUI_WORKSPACE").map(PathBuf::from),
    };
    let workspace = config.workspace_path.clone();

    application().run(move |cx: &mut App| {
        gpui_kit::init(cx);
        let (scheduler, updates, backend_task) = BackendScheduler::start_on_gpui(cx, config);
        backend_task.detach();
        let tree = cx.new(|cx| TreeState::new(cx));
        cx.open_window(Default::default(), |_, cx| {
            cx.new(|cx| {
                ShellView::new(
                    ShellModel::default(),
                    scheduler.clone(),
                    tree.clone(),
                    cx.focus_handle(),
                )
            })
        })
        .map_err(|error| error.to_string())
        .expect("failed to open GPUI smoke window");

        cx.spawn(async move |cx| {
            let smoke_result = run_smoke_commands(scheduler.clone(), updates, workspace).await;
            if smoke_result.is_err() {
                let _ = scheduler.submit(BackendCommand::Shutdown);
            }
            *result_for_app.lock().expect("smoke result lock") = Some(smoke_result);
            cx.update(|app| app.quit());
        })
        .detach();
    });

    result
        .lock()
        .expect("smoke result lock")
        .take()
        .unwrap_or_else(|| Err("GPUI smoke exited without a result".to_string()))
}

async fn run_smoke_commands(
    scheduler: BackendScheduler,
    updates: async_channel::Receiver<scratchpad_gpui::scheduler::BackendUpdate>,
    workspace: Option<PathBuf>,
) -> Result<u64, String> {
    let initial = updates
        .recv()
        .await
        .map_err(|error| format!("start update: {error}"))?;
    if !initial.outcome.code.eq("ok") {
        return Err(format!("start failed: {}", initial.outcome.message));
    }
    let mut state = initial
        .state
        .ok_or_else(|| "start update did not contain state".to_string())?;

    if let Some(workspace) = workspace {
        scheduler
            .submit(BackendCommand::ListDirectory(None))
            .map_err(|error| error.to_string())?;
        let listing = updates
            .recv()
            .await
            .map_err(|error| format!("listing update: {error}"))?;
        if !listing.outcome.code.eq("ok") || listing.listing.is_none() {
            return Err(format!("listing failed: {}", listing.outcome.message));
        }
        listing
            .state
            .ok_or_else(|| "listing update did not contain state".to_string())?;

        let path = workspace.join("README.md");
        scheduler
            .submit(BackendCommand::OpenPath(path))
            .map_err(|error| error.to_string())?;
        let opened = updates
            .recv()
            .await
            .map_err(|error| format!("open update: {error}"))?;
        if !opened.outcome.code.eq("ok") {
            return Err(format!("open failed: {}", opened.outcome.message));
        }
        let visible = opened
            .visible
            .as_ref()
            .ok_or_else(|| "open update did not contain a visible resource".to_string())?;
        if visible.bytes.len() > scratchpad_gpui::protocol::MAX_VISIBLE_BYTES {
            return Err(format!(
                "visible resource exceeded bound: {} bytes",
                visible.bytes.len()
            ));
        }
        state = opened
            .state
            .ok_or_else(|| "open update did not contain state".to_string())?;
        let document_id = state.active.clone();

        scheduler
            .submit(BackendCommand::SaveDocument(document_id.clone()))
            .map_err(|error| error.to_string())?;
        let saved = updates
            .recv()
            .await
            .map_err(|error| format!("save update: {error}"))?;
        if !saved.outcome.code.eq("ok") {
            return Err(format!("save failed: {}", saved.outcome.message));
        }
        saved
            .state
            .ok_or_else(|| "save update did not contain state".to_string())?;

        scheduler
            .submit(BackendCommand::CloseDocument {
                document_id,
                discard: true,
            })
            .map_err(|error| error.to_string())?;
        let closed = updates
            .recv()
            .await
            .map_err(|error| format!("close update: {error}"))?;
        if !closed.outcome.code.eq("ok") {
            return Err(format!("close failed: {}", closed.outcome.message));
        }
        state = closed
            .state
            .ok_or_else(|| "close update did not contain state".to_string())?;
    }

    scheduler
        .submit(BackendCommand::Shutdown)
        .map_err(|error| error.to_string())?;
    let stopped = updates
        .recv()
        .await
        .map_err(|error| format!("stop update: {error}"))?;
    if !stopped.outcome.code.eq("ok") {
        return Err(format!("stop failed: {}", stopped.outcome.message));
    }
    Ok(state.revision)
}
