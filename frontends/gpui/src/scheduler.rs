use crate::backend::{BackendSession, BackendSessionConfig};
use crate::protocol::{
    CommandRequest, DirectoryListing, MAX_VISIBLE_BYTES, MAX_VISIBLE_LINES, Outcome, Response,
    StateEnvelope, VisibleTextSlice,
};
use gpui_kit::{App, AppContext, Task};
use std::collections::VecDeque;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackendCommand {
    Snapshot,
    Ping,
    RefreshWorkspace,
    OpenPath(PathBuf),
    SelectDocument(String),
    SaveDocument(String),
    CloseDocument {
        document_id: String,
        discard: bool,
    },
    ListDirectory(Option<PathBuf>),
    ReadVisibleLines {
        document_id: String,
        start_line: usize,
    },
    ReplaceDocument {
        document_id: String,
        editor_revision: u64,
        start_byte: usize,
        end_byte: usize,
        replacement: Vec<u8>,
    },
    Shutdown,
}

impl BackendCommand {
    fn request(self, based_on_revision: u64) -> Result<Option<CommandRequest>, SchedulerError> {
        match self {
            BackendCommand::Snapshot => Ok(Some(CommandRequest::snapshot(based_on_revision))),
            BackendCommand::Ping => Ok(Some(CommandRequest::ping())),
            BackendCommand::RefreshWorkspace => {
                Ok(Some(CommandRequest::refresh_workspace(based_on_revision)))
            }
            BackendCommand::OpenPath(path) => {
                Ok(Some(CommandRequest::open_path(&path, based_on_revision)?))
            }
            BackendCommand::SelectDocument(document_id) => Ok(Some(
                CommandRequest::select_document(document_id, based_on_revision),
            )),
            BackendCommand::SaveDocument(document_id) => Ok(Some(CommandRequest::save_document(
                document_id,
                based_on_revision,
            ))),
            BackendCommand::CloseDocument {
                document_id,
                discard,
            } => Ok(Some(CommandRequest::close_document(
                document_id,
                discard,
                based_on_revision,
            ))),
            BackendCommand::ListDirectory(relative_path) => Ok(Some(
                CommandRequest::list_directory(relative_path.as_deref(), based_on_revision)?,
            )),
            BackendCommand::ReadVisibleLines {
                document_id,
                start_line,
            } => Ok(Some(CommandRequest::read_visible_lines(
                document_id,
                start_line,
                MAX_VISIBLE_LINES,
                MAX_VISIBLE_BYTES,
                based_on_revision,
            ))),
            BackendCommand::ReplaceDocument {
                document_id,
                editor_revision,
                start_byte,
                end_byte,
                replacement,
            } => Ok(Some(CommandRequest::replace_document(
                document_id,
                editor_revision,
                start_byte,
                end_byte,
                &replacement,
                based_on_revision,
            ))),
            BackendCommand::Shutdown => Ok(None),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackendUpdate {
    pub response: Option<Response>,
    pub state: Option<StateEnvelope>,
    pub listing: Option<DirectoryListing>,
    pub visible: Option<VisibleTextSlice>,
    pub outcome: Outcome,
}

impl BackendUpdate {
    fn error(message: impl Into<String>) -> Self {
        Self {
            response: None,
            state: None,
            listing: None,
            visible: None,
            outcome: Outcome::error("rust_scheduler_error", message, false),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SchedulerError {
    #[error(transparent)]
    ProtocolPath(#[from] crate::protocol::ProtocolError),
    #[error(transparent)]
    Backend(#[from] crate::backend::session::BackendSessionError),
    #[error("scheduler has stopped")]
    Stopped,
}

#[derive(Default, Debug)]
pub struct PendingCommands {
    queue: VecDeque<BackendCommand>,
}

impl PendingCommands {
    pub fn push(&mut self, command: BackendCommand) {
        match &command {
            BackendCommand::Snapshot => {
                if self
                    .queue
                    .iter()
                    .any(|queued| matches!(queued, BackendCommand::Snapshot))
                {
                    return;
                }
            }
            BackendCommand::ListDirectory(_) => self
                .queue
                .retain(|queued| !matches!(queued, BackendCommand::ListDirectory(_))),
            BackendCommand::RefreshWorkspace => self
                .queue
                .retain(|queued| !matches!(queued, BackendCommand::RefreshWorkspace)),
            BackendCommand::SelectDocument(_) => self
                .queue
                .retain(|queued| !matches!(queued, BackendCommand::SelectDocument(_))),
            BackendCommand::ReadVisibleLines { .. } => self
                .queue
                .retain(|queued| !matches!(queued, BackendCommand::ReadVisibleLines { .. })),
            BackendCommand::Shutdown => self.queue.clear(),
            _ => {}
        }
        self.queue.push_back(command);
    }

    pub fn pop(&mut self) -> Option<BackendCommand> {
        self.queue.pop_front()
    }

    pub fn len(&self) -> usize {
        self.queue.len()
    }

    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }
}

#[derive(Clone)]
pub struct BackendScheduler {
    command_tx: async_channel::Sender<BackendCommand>,
}

impl BackendScheduler {
    pub fn submit(&self, command: BackendCommand) -> Result<(), SchedulerError> {
        self.command_tx
            .try_send(command)
            .map_err(|_| SchedulerError::Stopped)
    }

    pub fn start_on_gpui(
        cx: &mut App,
        config: BackendSessionConfig,
    ) -> (Self, async_channel::Receiver<BackendUpdate>, Task<()>) {
        let (command_tx, command_rx) = async_channel::bounded(64);
        let (update_tx, update_rx) = async_channel::unbounded();
        let task = cx.background_spawn(async move {
            let mut session = match BackendSession::open(config) {
                Ok(session) => session,
                Err(error) => {
                    let _ = update_tx
                        .send(BackendUpdate::error(error.to_string()))
                        .await;
                    return;
                }
            };
            worker_loop(&mut session, command_rx, update_tx).await;
        });
        (Self { command_tx }, update_rx, task)
    }
}

async fn worker_loop(
    session: &mut BackendSession,
    command_rx: async_channel::Receiver<BackendCommand>,
    update_tx: async_channel::Sender<BackendUpdate>,
) {
    let mut pending = PendingCommands::default();
    let mut revision = 0;
    if let Some(response) = session.take_start_response() {
        let state = session.read_state().ok();
        if let Some(state) = &state {
            revision = state.application_revision;
        }
        let outcome = response.outcome.clone();
        if update_tx
            .send(BackendUpdate {
                response: Some(response),
                state,
                listing: None,
                visible: None,
                outcome,
            })
            .await
            .is_err()
        {
            return;
        }
    }

    while let Ok(command) = command_rx.recv().await {
        pending.push(command);
        while let Ok(command) = command_rx.try_recv() {
            pending.push(command);
        }

        while let Some(command) = pending.pop() {
            if command == BackendCommand::Shutdown {
                let update = match session.shutdown() {
                    Ok(response) => BackendUpdate {
                        response,
                        state: None,
                        listing: None,
                        visible: None,
                        outcome: Outcome::ok(),
                    },
                    Err(error) => BackendUpdate::error(error.to_string()),
                };
                let _ = update_tx.send(update).await;
                return;
            }

            let should_read_visible = matches!(
                &command,
                BackendCommand::OpenPath(_) | BackendCommand::SelectDocument(_)
            );
            let mut update = run_one(session, command, revision);
            if should_read_visible
                && update.outcome.code == "ok"
                && let Some(state) = &update.state
                && !state.active.is_empty()
            {
                let visible_revision = state.application_revision;
                let visible_update = run_one(
                    session,
                    BackendCommand::ReadVisibleLines {
                        document_id: state.active.clone(),
                        start_line: 0,
                    },
                    visible_revision,
                );
                if visible_update.outcome.code == "ok" {
                    update.visible = visible_update.visible;
                    update.state = visible_update.state;
                } else {
                    update.outcome = visible_update.outcome;
                }
            }
            if let Some(state) = &update.state {
                revision = state.application_revision;
            } else if let Some(response) = &update.response {
                revision = response.revision;
            }
            if update_tx.send(update).await.is_err() {
                return;
            }
        }
    }
    let _ = session.shutdown();
}

fn run_one(session: &BackendSession, command: BackendCommand, revision: u64) -> BackendUpdate {
    let request = match command.request(revision) {
        Ok(Some(request)) => request,
        Ok(None) => return BackendUpdate::error("shutdown cannot be run as a command request"),
        Err(error) => return BackendUpdate::error(error.to_string()),
    };
    if let Err(error) = session.dispatch(&request) {
        return BackendUpdate::error(error.to_string());
    }
    let response = match session.pump() {
        Ok(response) => response,
        Err(error) => return BackendUpdate::error(error.to_string()),
    };
    let visible = match response
        .as_ref()
        .and_then(|response| response.resource.as_ref())
    {
        Some(resource) => match session.read_visible_slice(resource) {
            Ok(slice) => Some(slice),
            Err(error) => {
                return BackendUpdate {
                    response,
                    state: None,
                    listing: None,
                    visible: None,
                    outcome: Outcome::error("resource_read_failed", error.to_string(), false),
                };
            }
        },
        None => None,
    };
    let state = match session.read_state() {
        Ok(state) => Some(state),
        Err(error) => {
            return BackendUpdate {
                response,
                state: None,
                listing: None,
                visible,
                outcome: Outcome::error("state_read_failed", error.to_string(), false),
            };
        }
    };
    let listing = response
        .as_ref()
        .and_then(|response| response.directory_listing.clone());
    let outcome = response
        .as_ref()
        .map(|response| response.outcome.clone())
        .unwrap_or_else(Outcome::ok);
    BackendUpdate {
        response,
        state,
        listing,
        visible,
        outcome,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coalesces_only_safe_latest_value_commands() {
        let mut pending = PendingCommands::default();
        pending.push(BackendCommand::Snapshot);
        pending.push(BackendCommand::Snapshot);
        pending.push(BackendCommand::SelectDocument("a".into()));
        pending.push(BackendCommand::SelectDocument("b".into()));
        pending.push(BackendCommand::RefreshWorkspace);
        pending.push(BackendCommand::RefreshWorkspace);
        pending.push(BackendCommand::ListDirectory(None));
        pending.push(BackendCommand::ListDirectory(Some("src".into())));
        pending.push(BackendCommand::ReadVisibleLines {
            document_id: "a".into(),
            start_line: 0,
        });
        pending.push(BackendCommand::ReadVisibleLines {
            document_id: "b".into(),
            start_line: 12,
        });
        assert_eq!(pending.len(), 5);

        let mut scroll = PendingCommands::default();
        for start_line in 0..100 {
            scroll.push(BackendCommand::ReadVisibleLines {
                document_id: "active".into(),
                start_line,
            });
        }
        assert_eq!(scroll.len(), 1);
        assert_eq!(
            scroll.pop(),
            Some(BackendCommand::ReadVisibleLines {
                document_id: "active".into(),
                start_line: 99,
            })
        );
    }
}
