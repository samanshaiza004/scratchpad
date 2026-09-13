//! Scratchpad's product command vocabulary as seen by the GPUI frontend.
//!
//! The strings in this module are the application command IDs from
//! `commands.InitialVocabulary`.  They are intentionally represented as a
//! validated string newtype instead of a second Rust enum of semantic
//! commands.  A GPUI action can therefore dispatch an existing Scratchpad
//! command while focus/navigation actions stay local to the frontend.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ProductCommandId(&'static str);

impl ProductCommandId {
    pub const fn as_str(self) -> &'static str {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandCategory {
    File,
    Document,
    Workspace,
    View,
    Edit,
    Markdown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProductCommand {
    pub id: ProductCommandId,
    pub title: &'static str,
    pub category: CommandCategory,
}

const fn command(
    id: &'static str,
    title: &'static str,
    category: CommandCategory,
) -> ProductCommand {
    ProductCommand {
        id: ProductCommandId(id),
        title,
        category,
    }
}

/// The ordered Scratchpad command vocabulary exposed to frontend surfaces.
///
/// Keep this list in the same order as `commands.InitialVocabulary`.  The
/// unit test below parses that Go declaration, so adding or removing a Go
/// command without updating this table fails close to the source of the
/// mismatch.
pub const PRODUCT_COMMANDS: &[ProductCommand] = &[
    command("file.open", "Open", CommandCategory::File),
    command("file.save", "Save", CommandCategory::File),
    command("file.save-as", "Save As", CommandCategory::File),
    command("document.find", "Find", CommandCategory::Document),
    command(
        "document.find-replace",
        "Find and Replace",
        CommandCategory::Document,
    ),
    command("file.quick-open", "Quick Open", CommandCategory::File),
    command(
        "workspace.search",
        "Workspace Search",
        CommandCategory::Workspace,
    ),
    command(
        "document.close",
        "Close Document",
        CommandCategory::Document,
    ),
    command(
        "document.activate",
        "Activate Document",
        CommandCategory::Document,
    ),
    command(
        "document.close-others",
        "Close Other Documents",
        CommandCategory::Document,
    ),
    command(
        "document.close-all",
        "Close All Documents",
        CommandCategory::Document,
    ),
    command(
        "document.reopen-closed",
        "Reopen Closed Document",
        CommandCategory::Document,
    ),
    command(
        "document.go-to-line",
        "Go to Line",
        CommandCategory::Document,
    ),
    command("document.find-next", "Find Next", CommandCategory::Document),
    command(
        "document.find-previous",
        "Find Previous",
        CommandCategory::Document,
    ),
    command("tab.next", "Next Tab", CommandCategory::View),
    command("tab.previous", "Previous Tab", CommandCategory::View),
    command("file.open-recent", "Open Recent", CommandCategory::File),
    command("file.copy-path", "Copy Path", CommandCategory::File),
    command(
        "file.copy-relative-path",
        "Copy Relative Path",
        CommandCategory::File,
    ),
    command(
        "file.reveal",
        "Reveal in File Manager",
        CommandCategory::File,
    ),
    command(
        "file.reveal-active",
        "Reveal Active Document",
        CommandCategory::File,
    ),
    command(
        "view.toggle-sidebar",
        "Toggle Sidebar",
        CommandCategory::View,
    ),
    command("settings.open", "Settings", CommandCategory::View),
    command(
        "view.increase-font-size",
        "Increase Font Size",
        CommandCategory::View,
    ),
    command(
        "view.decrease-font-size",
        "Decrease Font Size",
        CommandCategory::View,
    ),
    command(
        "view.reset-font-size",
        "Reset Font Size",
        CommandCategory::View,
    ),
    command(
        "workspace.refresh",
        "Refresh Workspace",
        CommandCategory::Workspace,
    ),
    command(
        "workspace.focus-files",
        "Focus Files",
        CommandCategory::Workspace,
    ),
    command(
        "workspace.toggle-folder",
        "Toggle Folder",
        CommandCategory::Workspace,
    ),
    command("workspace.new-file", "New File", CommandCategory::Workspace),
    command(
        "workspace.new-folder",
        "New Folder",
        CommandCategory::Workspace,
    ),
    command("workspace.rename", "Rename", CommandCategory::Workspace),
    command("workspace.move", "Move", CommandCategory::Workspace),
    command(
        "workspace.trash",
        "Move to Trash",
        CommandCategory::Workspace,
    ),
    command("outline.toggle", "Toggle Outline", CommandCategory::View),
    command("item.toggle", "Toggle Task", CommandCategory::Edit),
    command(
        "selection.expand",
        "Expand Selection",
        CommandCategory::Edit,
    ),
    command("comment.toggle", "Toggle Comment", CommandCategory::Edit),
    command("document.format", "Format Table", CommandCategory::Document),
    command("edit.undo", "Undo", CommandCategory::Edit),
    command("edit.redo", "Redo", CommandCategory::Edit),
    command("edit.cut", "Cut", CommandCategory::Edit),
    command("edit.copy", "Copy", CommandCategory::Edit),
    command("edit.paste", "Paste", CommandCategory::Edit),
    command("edit.select-all", "Select All", CommandCategory::Edit),
    command("edit.indent-lines", "Indent Lines", CommandCategory::Edit),
    command("edit.outdent-lines", "Outdent Lines", CommandCategory::Edit),
    command("edit.delete-line", "Delete Line", CommandCategory::Edit),
    command(
        "edit.insert-line-above",
        "Insert Line Above",
        CommandCategory::Edit,
    ),
    command(
        "edit.insert-line-below",
        "Insert Line Below",
        CommandCategory::Edit,
    ),
    command("edit.move-line-up", "Move Line Up", CommandCategory::Edit),
    command(
        "edit.move-line-down",
        "Move Line Down",
        CommandCategory::Edit,
    ),
    command(
        "edit.duplicate-line",
        "Duplicate Line",
        CommandCategory::Edit,
    ),
    command("edit.join-lines", "Join Lines", CommandCategory::Edit),
    command(
        "markdown.toggle-strong",
        "Strong",
        CommandCategory::Markdown,
    ),
    command(
        "markdown.toggle-emphasis",
        "Emphasis",
        CommandCategory::Markdown,
    ),
    command(
        "markdown.toggle-strike",
        "Strikethrough",
        CommandCategory::Markdown,
    ),
    command(
        "markdown.toggle-inline-code",
        "Inline Code",
        CommandCategory::Markdown,
    ),
    command("markdown.insert-link", "Link", CommandCategory::Markdown),
    command("markdown.heading-1", "Heading 1", CommandCategory::Markdown),
    command("markdown.heading-2", "Heading 2", CommandCategory::Markdown),
    command("markdown.heading-3", "Heading 3", CommandCategory::Markdown),
    command(
        "markdown.toggle-bulleted-list",
        "Bulleted List",
        CommandCategory::Markdown,
    ),
    command(
        "markdown.toggle-numbered-list",
        "Numbered List",
        CommandCategory::Markdown,
    ),
    command("markdown.toggle-quote", "Quote", CommandCategory::Markdown),
    command("markdown.insert-task", "Task", CommandCategory::Markdown),
    command(
        "markdown.insert-code-block",
        "Code Block",
        CommandCategory::Markdown,
    ),
    command(
        "markdown.set-fence-language",
        "Code Fence Language",
        CommandCategory::Markdown,
    ),
    command("markdown.insert-table", "Table", CommandCategory::Markdown),
    command(
        "markdown.table-next",
        "Next Table Cell",
        CommandCategory::Markdown,
    ),
    command(
        "markdown.table-previous",
        "Previous Table Cell",
        CommandCategory::Markdown,
    ),
    command(
        "markdown.table-enter",
        "Next Table Row",
        CommandCategory::Markdown,
    ),
    command(
        "markdown.insert-divider",
        "Divider",
        CommandCategory::Markdown,
    ),
    command(
        "markdown.smart-paste",
        "Paste as Link",
        CommandCategory::Markdown,
    ),
];

pub fn command_by_id(id: &str) -> Option<ProductCommandId> {
    PRODUCT_COMMANDS
        .iter()
        .find(|command| command.id.as_str() == id)
        .map(|command| command.id)
}

pub fn descriptor(id: ProductCommandId) -> ProductCommand {
    PRODUCT_COMMANDS
        .iter()
        .copied()
        .find(|command| command.id == id)
        .expect("ProductCommandId must come from PRODUCT_COMMANDS")
}

/// Actions that are local to the GPUI frontend or dispatch an existing
/// Scratchpad product command.  There is deliberately no Rust enum variant
/// for each semantic command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrontendAction {
    Dispatch(ProductCommandId),
    Focus(FocusTarget),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusTarget {
    Editor,
    Files,
    Outline,
    Tabs,
    CommandPalette,
    Settings,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CommandPaletteModel {
    open: bool,
    query: String,
    selected: usize,
}

impl CommandPaletteModel {
    pub fn open(&mut self) {
        self.open = true;
        self.selected = 0;
    }

    pub fn close(&mut self) {
        self.open = false;
        self.query.clear();
        self.selected = 0;
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    pub fn query(&self) -> &str {
        &self.query
    }

    pub fn set_query(&mut self, query: impl Into<String>) {
        self.query = query.into();
        self.selected = 0;
    }

    pub fn filtered_commands(&self) -> Vec<ProductCommand> {
        let query = self.query.trim();
        if query.is_empty() {
            return PRODUCT_COMMANDS.to_vec();
        }

        let mut matches = PRODUCT_COMMANDS.to_vec();
        for token in query.split_whitespace().map(str::to_ascii_lowercase) {
            matches.retain(|command| command_matches_token(*command, &token));
        }
        matches
    }

    pub fn selected_index(&self) -> usize {
        self.selected
    }

    pub fn selected_command(&self) -> Option<ProductCommand> {
        self.filtered_commands().get(self.selected).copied()
    }

    pub fn move_selection(&mut self, delta: isize) {
        let count = self.filtered_commands().len();
        if count == 0 {
            self.selected = 0;
            return;
        }

        self.selected = (self.selected as isize + delta).rem_euclid(count as isize) as usize;
    }
}

fn command_matches_token(command: ProductCommand, token: &str) -> bool {
    let title = command.title.to_ascii_lowercase();
    let id = command.id.as_str().to_ascii_lowercase();
    if title.contains(token) || id.contains(token) {
        return true;
    }
    title
        .split(|character: char| !character.is_ascii_alphanumeric())
        .chain(id.split(|character: char| !character.is_ascii_alphanumeric()))
        .filter(|part| !part.is_empty())
        .any(|part| part.contains(token))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, HashSet};

    #[test]
    fn product_command_ids_are_unique() {
        let ids = PRODUCT_COMMANDS
            .iter()
            .map(|command| command.id)
            .collect::<HashSet<_>>();
        assert_eq!(ids.len(), PRODUCT_COMMANDS.len());
    }

    #[test]
    fn product_command_ids_match_go_initial_vocabulary_exactly() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../commands/commands.go"
        ));
        let mut constants = HashMap::new();
        let mut in_constants = false;
        for line in source.lines() {
            let trimmed = line.trim();
            if trimmed == "const (" {
                in_constants = true;
                continue;
            }
            if in_constants && trimmed == ")" {
                in_constants = false;
                continue;
            }
            if in_constants
                && let Some((name, value)) = trimmed.split_once("ID = \"")
                && let Some(id) = value.split_once('"').map(|(id, _)| id)
            {
                constants.insert(name.trim().to_string(), id.to_string());
            }
        }

        let mut in_vocabulary = false;
        let mut go_ids = Vec::new();
        for line in source.lines() {
            let trimmed = line.trim();
            if trimmed == "var InitialVocabulary = []ID{" {
                in_vocabulary = true;
                continue;
            }
            if in_vocabulary && trimmed == "}" {
                break;
            }
            if in_vocabulary {
                let name = trimmed.trim_end_matches(',').trim();
                if !name.is_empty() {
                    go_ids.push(
                        constants
                            .get(name)
                            .unwrap_or_else(|| panic!("unknown Go command constant {name}"))
                            .clone(),
                    );
                }
            }
        }

        let rust_ids = PRODUCT_COMMANDS
            .iter()
            .map(|command| command.id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(go_ids.len(), 75);
        assert_eq!(rust_ids, go_ids);
    }

    #[test]
    fn command_palette_filters_by_title_or_id_and_wraps_selection() {
        let mut palette = CommandPaletteModel::default();
        palette.open();
        palette.set_query("save");
        assert_eq!(
            palette
                .filtered_commands()
                .iter()
                .map(|command| command.id.as_str())
                .collect::<Vec<_>>(),
            vec!["file.save", "file.save-as"]
        );
        assert_eq!(palette.selected_command().unwrap().id.as_str(), "file.save");

        palette.move_selection(1);
        assert_eq!(
            palette.selected_command().unwrap().id.as_str(),
            "file.save-as"
        );
        palette.move_selection(1);
        assert_eq!(palette.selected_command().unwrap().id.as_str(), "file.save");

        palette.set_query("workspace.search");
        assert_eq!(
            palette.selected_command().unwrap().id.as_str(),
            "workspace.search"
        );
    }

    #[test]
    fn only_known_ids_can_be_resolved_for_dispatch() {
        let id = command_by_id("file.save").expect("stable product command");
        assert_eq!(id.as_str(), "file.save");
        assert!(command_by_id("rust.save").is_none());
        assert_eq!(descriptor(id).title, "Save");
        assert_eq!(
            FrontendAction::Dispatch(id),
            FrontendAction::Dispatch(ProductCommandId("file.save"))
        );
    }
}
