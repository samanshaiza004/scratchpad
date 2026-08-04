#![cfg(all(target_os = "wasi", target_env = "p2"))]

use std::cell::Cell;

use youth_sdk::prelude::*;

const DOCUMENT: NodeKey = node!("document");
const SAVE: NodeKey = node!("save");
const STATUS: NodeKey = node!("status");

#[derive(Clone, Copy)]
enum ScratchpadStatus {
    Saved,
    Unsaved,
    Saving,
    Conflict,
    Failed,
}

impl ScratchpadStatus {
    const fn label(self) -> &'static str {
        match self {
            Self::Saved => "Saved",
            Self::Unsaved => "Unsaved changes",
            Self::Saving => "Saving...",
            Self::Conflict => "Conflict",
            Self::Failed => "Save failed",
        }
    }
}

thread_local! {
    static STATUS_VALUE: Cell<ScratchpadStatus> = const { Cell::new(ScratchpadStatus::Saved) };
}

struct Scratchpad;

impl Application for Scratchpad {
    fn view(context: &ViewContext) -> Result<Tree> {
        let document = context.text_document().current()?;
        validate_extension(document.filename())?;
        Ok(Tree::root(BoxNode::column([
            Text::new(node!("filename"), document.filename()),
            Editor::document(DOCUMENT, &document).grow(1),
            Text::new(STATUS, STATUS_VALUE.with(Cell::get).label()),
            Button::new(SAVE, "Save").shortcut(Shortcut::primary('s')),
        ])))
    }

    fn handle(context: &mut EventContext, events: &Events) -> Result<Update> {
        let document = context.text_document().current()?;
        validate_extension(document.filename())?;
        let mut update = Update::unchanged();

        if events
            .editor_dirty_changes()
            .any(|(editor, dirty)| editor == DOCUMENT.id() && dirty)
        {
            set_status(ScratchpadStatus::Unsaved);
            update = update.set_text(STATUS, ScratchpadStatus::Unsaved.label());
        }

        if events.activated(SAVE) {
            context
                .text_document()
                .request_save(&document, DOCUMENT)?;
            set_status(ScratchpadStatus::Saving);
            update = update.set_text(STATUS, ScratchpadStatus::Saving.label());
        }

        for completion in events.text_document_save_completions() {
            update = match completion.outcome() {
                TextDocumentSaveOutcome::Saved {
                    document,
                    version,
                    still_dirty,
                    ..
                } => {
                    let status = if still_dirty {
                        ScratchpadStatus::Unsaved
                    } else {
                        ScratchpadStatus::Saved
                    };
                    set_status(status);
                    update
                        .set_editor_document_version(DOCUMENT, document, version)
                        .set_text(STATUS, status.label())
                }
                TextDocumentSaveOutcome::Failed(TextDocumentFailure::Conflict) => {
                    set_status(ScratchpadStatus::Conflict);
                    update.set_text(STATUS, ScratchpadStatus::Conflict.label())
                }
                TextDocumentSaveOutcome::Failed(_) => {
                    set_status(ScratchpadStatus::Failed);
                    update.set_text(STATUS, ScratchpadStatus::Failed.label())
                }
            };
        }

        Ok(update)
    }
}

fn validate_extension(filename: &str) -> Result<()> {
    if filename.ends_with(".txt") || filename.ends_with(".md") {
        Ok(())
    } else {
        Err(Error::invalid_state()
            .with_message("Scratchpad accepts only .txt and .md documents"))
    }
}

fn set_status(status: ScratchpadStatus) {
    STATUS_VALUE.set(status);
}

youth_sdk::export_app!(Scratchpad);
