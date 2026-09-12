use gpui_kit::base::Selectable;
use gpui_kit::component::button::Button;
use gpui_kit::component::list::ListItem;
use gpui_kit::component::tab::{Tab, TabBar};
use gpui_kit::component::tree::{Tree, TreeItem, TreeState};
use gpui_kit::{
    App, AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled, Window,
    application, div, prelude::FluentBuilder,
};
use scratchpad_gpui::app::ShellModel;
use scratchpad_gpui::backend::BackendSessionConfig;
use scratchpad_gpui::scheduler::{BackendCommand, BackendScheduler};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

struct ShellView {
    model: ShellModel,
    scheduler: BackendScheduler,
    tree: Entity<TreeState>,
}

impl ShellView {
    fn new(model: ShellModel, scheduler: BackendScheduler, tree: Entity<TreeState>) -> Self {
        Self {
            model,
            scheduler,
            tree,
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
                format!(
                    "lines {}–{} · revision {}{}\n{}",
                    slice.start_line,
                    slice.end_line,
                    slice.editor_revision,
                    if slice.truncated { " · bounded" } else { "" },
                    slice.display_text()
                )
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
                .child(label)
                .selected(selected);
            if !entry.is_folder() && !workspace_root.is_empty() {
                let path = PathBuf::from(&workspace_root).join(relative);
                let scheduler = tree_scheduler.clone();
                item = item.on_click(move |_, _, _| {
                    let _ = scheduler.submit(BackendCommand::OpenPath(path.clone()));
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
            view.model.command_palette_open = !view.model.command_palette_open;
            cx.notify();
        });
        let settings = cx.listener(|view, _, _, cx| {
            view.model.settings_open = !view.model.settings_open;
            cx.notify();
        });
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
                    .child(div().w_64().border_r_1().child(tree))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .flex_1()
                            .child(tabs)
                            .child(div().flex_1().p_4().child(viewport)),
                    ),
            )
            .when(self.model.command_palette_open, |this| {
                this.child(div().p_3().child("Command palette: semantic commands only"))
            })
            .when(self.model.settings_open, |this| {
                this.child(div().p_3().child("Settings: frontend-local shell settings"))
            })
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
                let entity = cx.new(|_| {
                    ShellView::new(ShellModel::default(), scheduler.clone(), tree.clone())
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
                        view.model.apply_update(update);
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
            cx.new(|_| ShellView::new(ShellModel::default(), scheduler.clone(), tree.clone()))
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
