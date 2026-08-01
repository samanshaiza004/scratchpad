#![cfg(all(target_os = "wasi", target_env = "p2"))]

use youth_sdk::prelude::*;

/// The Editor node's guest-owned document identity. Declared once, at
/// mount; the host owns the live buffer for as long as this node stays
/// installed. See the Editor session lifecycle in the Youth platform's
/// Gate A design notes -- a stable node identity implicitly owns one host
/// editor session while installed.
const DOCUMENT: NodeKey = node!("document");
const SAVE: NodeKey = node!("save");
const STATUS: NodeKey = node!("status");

const DOCUMENT_REVISION_KEY: &str = "document_revision";
const TEXT_KEY: &str = "text";

struct Scratchpad;

impl Application for Scratchpad {
    fn view(context: &ViewContext) -> Result<Tree> {
        // Guest state persists across restarts; the host's live buffer
        // persists across ordinary turns. On a fresh mount (first turn for
        // a fresh host session) these coincide: the Editor node is created
        // from exactly this declared revision and text. On every later
        // turn the declaration is compared against what the host already
        // has and, since the revision matches, ignored in favor of the
        // live buffer -- so re-declaring the last-saved text here every
        // turn never clobbers in-progress typing.
        let document_revision = context
            .state()
            .integer(DOCUMENT_REVISION_KEY)?
            .unwrap_or(1)
            .max(1) as u64;
        let text = context.state().text(TEXT_KEY)?.unwrap_or_default();

        Ok(Tree::root(BoxNode::column([
            Editor::new(DOCUMENT, DocumentRevision::new(document_revision), text),
            Text::new(STATUS, format!("Saved as revision {document_revision}")),
            Button::new(SAVE, "Save"),
        ])))
    }

    fn handle(context: &mut EventContext, events: &Events) -> Result<Update> {
        if !events.activated(SAVE) {
            return Ok(Update::unchanged());
        }

        // The one guest turn Save costs: read the host's current buffer,
        // then accept it. `accept` never touches the live buffer/cursor/
        // selection -- it only advances the guest's own bookkeeping, so
        // typing that happens between this snapshot and the turn
        // committing is not lost or overwritten.
        let snapshot = context.editor().snapshot(DOCUMENT)?;
        let new_revision = DocumentRevision::new(snapshot.document_revision().get() + 1);
        context.editor().accept(
            DOCUMENT,
            snapshot.document_revision(),
            snapshot.edit_sequence(),
            new_revision,
        )?;

        context
            .state()
            .set_integer(DOCUMENT_REVISION_KEY, new_revision.get() as i64)?;
        context.state().set_text(TEXT_KEY, snapshot.text())?;

        Ok(Update::new().set_text(
            STATUS,
            format!("Saved as revision {}", new_revision.get()),
        ))
    }
}

youth_sdk::export_app!(Scratchpad);
