use crate::protocol::{CommandRequest, EditAck, StateEnvelope, VisibleTextSlice};
use std::str;
use thiserror::Error;

/// A source edit produced by the frontend-local editing session. The byte
/// range is global to the authoritative Go document, while the session keeps
/// only the current bounded window locally.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EditIntent {
    pub document_id: String,
    pub based_on_revision: u64,
    pub editor_revision: u64,
    pub start_byte: usize,
    pub end_byte: usize,
    pub replacement: Vec<u8>,
}

impl EditIntent {
    pub fn command(&self) -> CommandRequest {
        CommandRequest::replace_document(
            self.document_id.clone(),
            self.editor_revision,
            self.start_byte,
            self.end_byte,
            &self.replacement,
            self.based_on_revision,
        )
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum EditorSessionError {
    #[error("visible window is truncated")]
    TruncatedWindow,
    #[error("visible window is not valid UTF-8")]
    NonUtf8Window,
    #[error("replacement is not valid UTF-8")]
    NonUtf8Replacement,
    #[error("editing session position is outside its window")]
    InvalidPosition,
    #[error("editing session has an edit awaiting acknowledgement")]
    PendingEdit,
    #[error("editing session has no pending edit")]
    NoPendingEdit,
    #[error("edit acknowledgement does not match the pending edit")]
    MismatchedAcknowledgement,
    #[error("acknowledged edit state does not match the current document")]
    MismatchedState,
}

#[derive(Debug, Clone)]
struct PendingEdit {
    intent: EditIntent,
    bytes: Vec<u8>,
    anchor: usize,
    cursor: usize,
}

/// A deliberately small frontend-local editing session.
///
/// The session owns only one bounded, valid-UTF-8 source window plus caret and
/// selection state. Go remains authoritative for the complete document and
/// accepts the returned byte edit only when `editor_revision` still matches.
/// This is the Gate 4 spike, not a second editor implementation: selection,
/// viewport, IME preedit, shaping, and layout can grow around this seam later.
#[derive(Debug, Clone)]
pub struct EditorSession {
    document_id: String,
    application_revision: u64,
    editor_revision: u64,
    start_byte: usize,
    bytes: Vec<u8>,
    anchor: usize,
    cursor: usize,
    pending: Option<PendingEdit>,
}

impl EditorSession {
    pub fn from_visible(
        slice: &VisibleTextSlice,
        application_revision: u64,
    ) -> Result<Self, EditorSessionError> {
        if slice.application_revision != application_revision {
            return Err(EditorSessionError::MismatchedState);
        }
        if slice.truncated {
            return Err(EditorSessionError::TruncatedWindow);
        }
        if str::from_utf8(&slice.bytes).is_err() {
            return Err(EditorSessionError::NonUtf8Window);
        }
        Ok(Self {
            document_id: slice.document_id.clone(),
            application_revision,
            editor_revision: slice.editor_revision,
            start_byte: slice.start_byte,
            bytes: slice.bytes.clone(),
            anchor: 0,
            cursor: 0,
            pending: None,
        })
    }

    pub fn document_id(&self) -> &str {
        &self.document_id
    }

    pub fn application_revision(&self) -> u64 {
        self.application_revision
    }

    pub fn editor_revision(&self) -> u64 {
        self.editor_revision
    }

    pub fn start_byte(&self) -> usize {
        self.start_byte
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn caret(&self) -> usize {
        self.cursor
    }

    pub fn selection(&self) -> (usize, usize) {
        (self.anchor, self.cursor)
    }

    pub fn has_pending_edit(&self) -> bool {
        self.pending.is_some()
    }

    pub fn set_caret(&mut self, position: usize) -> Result<(), EditorSessionError> {
        self.set_selection(position, position)
    }

    pub fn set_selection(
        &mut self,
        anchor: usize,
        cursor: usize,
    ) -> Result<(), EditorSessionError> {
        if !self.is_boundary(anchor) || !self.is_boundary(cursor) {
            return Err(EditorSessionError::InvalidPosition);
        }
        self.anchor = anchor;
        self.cursor = cursor;
        Ok(())
    }

    pub fn insert_text(&mut self, text: &str) -> Result<EditIntent, EditorSessionError> {
        self.replace_bytes(text.as_bytes())
    }

    pub fn replace_bytes(&mut self, replacement: &[u8]) -> Result<EditIntent, EditorSessionError> {
        if self.pending.is_some() {
            return Err(EditorSessionError::PendingEdit);
        }
        if str::from_utf8(replacement).is_err() {
            return Err(EditorSessionError::NonUtf8Replacement);
        }
        let (start, end) = if self.anchor <= self.cursor {
            (self.anchor, self.cursor)
        } else {
            (self.cursor, self.anchor)
        };
        let global_start = self
            .start_byte
            .checked_add(start)
            .ok_or(EditorSessionError::InvalidPosition)?;
        let global_end = self
            .start_byte
            .checked_add(end)
            .ok_or(EditorSessionError::InvalidPosition)?;
        let intent = EditIntent {
            document_id: self.document_id.clone(),
            based_on_revision: self.application_revision,
            editor_revision: self.editor_revision,
            start_byte: global_start,
            end_byte: global_end,
            replacement: replacement.to_vec(),
        };
        let pending = PendingEdit {
            intent: intent.clone(),
            bytes: self.bytes.clone(),
            anchor: self.anchor,
            cursor: self.cursor,
        };
        self.bytes.splice(start..end, replacement.iter().copied());
        self.cursor = start + replacement.len();
        self.anchor = self.cursor;
        self.pending = Some(pending);
        Ok(intent)
    }

    pub fn acknowledge(
        &mut self,
        acknowledgement: &EditAck,
        state: &StateEnvelope,
    ) -> Result<(), EditorSessionError> {
        let Some(pending) = self.pending.as_ref() else {
            return Err(EditorSessionError::NoPendingEdit);
        };
        if acknowledgement.document_id != pending.intent.document_id
            || acknowledgement.start_byte != pending.intent.start_byte
            || acknowledgement.old_end_byte != pending.intent.end_byte
            || acknowledgement.new_end_byte
                != pending.intent.start_byte + pending.intent.replacement.len()
        {
            return Err(EditorSessionError::MismatchedAcknowledgement);
        }
        let Some(document) = state
            .documents
            .iter()
            .find(|document| document.id == self.document_id)
        else {
            return Err(EditorSessionError::MismatchedState);
        };
        if state.application_revision < pending.intent.based_on_revision
            || document.editor_revision != acknowledgement.editor_revision
        {
            return Err(EditorSessionError::MismatchedState);
        }
        self.application_revision = state.application_revision;
        self.editor_revision = acknowledgement.editor_revision;
        self.pending = None;
        Ok(())
    }

    pub fn reject(&mut self) -> Result<(), EditorSessionError> {
        let Some(pending) = self.pending.take() else {
            return Err(EditorSessionError::NoPendingEdit);
        };
        self.bytes = pending.bytes;
        self.anchor = pending.anchor;
        self.cursor = pending.cursor;
        Ok(())
    }

    fn is_boundary(&self, position: usize) -> bool {
        position <= self.bytes.len() && str::from_utf8(&self.bytes[..position]).is_ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{StateDocument, StateEnvelope};

    fn visible() -> VisibleTextSlice {
        VisibleTextSlice {
            document_id: "doc".to_string(),
            application_revision: 7,
            editor_revision: 11,
            start_line: 3,
            end_line: 4,
            truncated: false,
            start_byte: 100,
            bytes: b"hello\n".to_vec(),
        }
    }

    fn state(revision: u64, editor_revision: u64) -> StateEnvelope {
        StateEnvelope {
            schema: 1,
            revision,
            application_revision: revision,
            has_workspace: true,
            workspace_root: "/tmp".to_string(),
            active: "doc".to_string(),
            documents: vec![StateDocument {
                id: "doc".to_string(),
                path: "/tmp/doc.txt".to_string(),
                status: "dirty".to_string(),
                dirty: true,
                editor_revision,
                language: "text".to_string(),
            }],
        }
    }

    #[test]
    fn optimistic_edit_maps_window_bytes_and_acknowledges() {
        let mut session = EditorSession::from_visible(&visible(), 7).expect("session");
        session.set_selection(1, 4).expect("selection");
        let intent = session.insert_text("i").expect("edit");
        assert_eq!(session.bytes(), b"hio\n");
        assert_eq!(session.selection(), (2, 2));
        assert_eq!(intent.start_byte, 101);
        assert_eq!(intent.end_byte, 104);
        assert_eq!(intent.editor_revision, 11);
        assert!(session.has_pending_edit());

        let acknowledgement = EditAck {
            document_id: "doc".to_string(),
            editor_revision: 12,
            start_byte: 101,
            old_end_byte: 104,
            new_end_byte: 102,
        };
        session
            .acknowledge(&acknowledgement, &state(8, 12))
            .expect("acknowledge");
        assert_eq!(session.editor_revision(), 12);
        assert_eq!(session.application_revision(), 8);
        assert!(!session.has_pending_edit());
    }

    #[test]
    fn rejected_edit_rolls_back_local_window() {
        let mut session = EditorSession::from_visible(&visible(), 7).expect("session");
        session.set_caret(5).expect("caret");
        session.insert_text("!").expect("edit");
        assert_eq!(session.bytes(), b"hello!\n");
        session.reject().expect("reject");
        assert_eq!(session.bytes(), b"hello\n");
        assert_eq!(session.caret(), 5);
        assert!(!session.has_pending_edit());
    }

    #[test]
    fn gate_four_initially_rejects_non_utf8_or_truncated_windows() {
        let mut malformed = visible();
        malformed.bytes = vec![0xff];
        assert!(matches!(
            EditorSession::from_visible(&malformed, 7),
            Err(EditorSessionError::NonUtf8Window)
        ));
        let mut truncated = visible();
        truncated.truncated = true;
        assert!(matches!(
            EditorSession::from_visible(&truncated, 7),
            Err(EditorSessionError::TruncatedWindow)
        ));
    }
}
