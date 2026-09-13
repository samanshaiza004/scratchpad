use crate::protocol::{
    DirectoryEntry, DirectoryListing, Outcome, StateDocument, StateEnvelope, VisibleTextSlice,
};
use crate::scheduler::BackendUpdate;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellModel {
    pub state: StateEnvelope,
    pub tree: Vec<TreeRow>,
    pub status: StatusLine,
    pub command_palette_open: bool,
    pub settings_open: bool,
    pub close_dialog: Option<String>,
    pub active_selection: ActiveSelection,
    pub visible: Option<VisibleTextSlice>,
}

impl Default for ShellModel {
    fn default() -> Self {
        Self {
            state: StateEnvelope::default(),
            tree: Vec::new(),
            status: StatusLine::default(),
            command_palette_open: false,
            settings_open: false,
            close_dialog: None,
            active_selection: ActiveSelection::Workspace,
            visible: None,
        }
    }
}

impl ShellModel {
    pub fn apply_update(&mut self, update: BackendUpdate) {
        if let Some(state) = update.state {
            self.state = state;
            if self.visible.as_ref().is_some_and(|slice| {
                !self.state.documents.iter().any(|doc| {
                    doc.id == self.state.active
                        && doc.id == slice.document_id
                        && doc.editor_revision == slice.editor_revision
                        && self.state.application_revision == slice.application_revision
                })
            }) {
                self.visible = None;
            }
            if !self.state.active.is_empty() {
                self.active_selection = ActiveSelection::Document(self.state.active.clone());
            }
        }
        if let Some(listing) = update.listing {
            self.apply_listing(listing);
        }
        if let Some(visible) = update.visible {
            let is_current = visible.document_id == self.state.active
                && visible.application_revision == self.state.application_revision
                && self.state.documents.iter().any(|document| {
                    document.id == visible.document_id
                        && document.editor_revision == visible.editor_revision
                });
            if is_current {
                self.visible = Some(visible);
            }
        }
        self.status = StatusLine::from_outcome(update.outcome, self.state.revision);
    }

    pub fn apply_listing(&mut self, listing: DirectoryListing) {
        self.tree = listing
            .entries
            .into_iter()
            .map(|entry| TreeRow::from_entry(&listing.relative_path, entry))
            .collect();
    }

    pub fn active_document(&self) -> Option<&StateDocument> {
        self.state
            .documents
            .iter()
            .find(|document| document.id == self.state.active)
    }

    pub fn dirty_count(&self) -> usize {
        self.state
            .documents
            .iter()
            .filter(|document| document.dirty)
            .count()
    }

    pub fn workspace_name(&self) -> String {
        if self.state.workspace_root.is_empty() {
            return "No workspace".to_string();
        }
        Path::new(&self.state.workspace_root)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(&self.state.workspace_root)
            .to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActiveSelection {
    Workspace,
    TreePath(String),
    Document(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeRow {
    pub name: String,
    pub path: String,
    pub dir: bool,
    pub depth: usize,
}

impl TreeRow {
    fn from_entry(relative_root: &str, entry: DirectoryEntry) -> Self {
        let depth = if relative_root.is_empty() {
            0
        } else {
            PathBuf::from(relative_root).components().count()
        };
        Self {
            name: entry.name,
            path: entry.path,
            dir: entry.dir,
            depth,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusLine {
    pub code: String,
    pub message: String,
    pub retryable: bool,
    pub revision: u64,
}

impl Default for StatusLine {
    fn default() -> Self {
        Self {
            code: "idle".to_string(),
            message: "Ready".to_string(),
            retryable: false,
            revision: 0,
        }
    }
}

impl StatusLine {
    fn from_outcome(outcome: Outcome, revision: u64) -> Self {
        let message = if outcome.message.is_empty() {
            outcome.code.clone()
        } else {
            outcome.message
        };
        Self {
            code: outcome.code,
            message,
            retryable: outcome.retryable,
            revision,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(application_revision: u64, editor_revision: u64) -> StateEnvelope {
        StateEnvelope {
            schema: 1,
            revision: application_revision,
            application_revision,
            has_workspace: true,
            workspace_root: "/tmp/workspace".to_string(),
            active: "doc".to_string(),
            documents: vec![StateDocument {
                id: "doc".to_string(),
                path: "/tmp/workspace/note.txt".to_string(),
                status: "open".to_string(),
                dirty: false,
                editor_revision,
                language: "text".to_string(),
            }],
        }
    }

    fn visible(application_revision: u64, editor_revision: u64) -> VisibleTextSlice {
        VisibleTextSlice {
            document_id: "doc".to_string(),
            application_revision,
            editor_revision,
            start_line: 0,
            end_line: 1,
            truncated: false,
            start_byte: 0,
            bytes: b"current\n".to_vec(),
        }
    }

    fn update(state: Option<StateEnvelope>, visible: Option<VisibleTextSlice>) -> BackendUpdate {
        BackendUpdate {
            response: None,
            state,
            listing: None,
            visible,
            outcome: Outcome::ok(),
        }
    }

    #[test]
    fn rejects_visible_content_with_stale_editor_revision() {
        let mut model = ShellModel::default();
        model.apply_update(update(Some(state(3, 7)), Some(visible(3, 7))));
        assert!(model.visible.is_some());

        model.apply_update(update(None, Some(visible(3, 6))));
        assert_eq!(model.visible.as_ref().unwrap().editor_revision, 7);

        model.apply_update(update(Some(state(4, 8)), None));
        assert!(model.visible.is_none());
    }
}
