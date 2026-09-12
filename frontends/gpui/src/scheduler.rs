use crate::backend::{BackendSession, BackendSessionConfig};
use crate::protocol::{CommandRequest, DirectoryListing, Outcome, Response, StateEnvelope};
use gpui_kit::{App, AppContext, Task};
use std::collections::VecDeque;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackendCommand {
    Snapshot,
    Ping,
    OpenPath(PathBuf),
    SelectDocument(String),
    SaveDocument(String),
    CloseDocument { document_id: String, discard: bool },
    ListDirectory(Option<PathBuf>),
    Shutdown,
}

impl BackendCommand {
    fn request(self, based_on_revision: u64) -> Result<Option<CommandRequest>, SchedulerError> {
        match self {
            BackendCommand::Snapshot => Ok(Some(CommandRequest::snapshot(based_on_revision))),
            BackendCommand::Ping => Ok(Some(CommandRequest::ping())),
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
            BackendCommand::Shutdown => Ok(None),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackendUpdate {
    pub response: Option<Response>,
    pub state: Option<StateEnvelope>,
    pub listing: Option<DirectoryListing>,
    pub outcome: Outcome,
}

impl BackendUpdate {
    fn error(message: impl Into<String>) -> Self {
        Self {
            response: None,
            state: None,
            listing: None,
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
            BackendCommand::SelectDocument(_) => self
                .queue
                .retain(|queued| !matches!(queued, BackendCommand::SelectDocument(_))),
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
                        outcome: Outcome::ok(),
                    },
                    Err(error) => BackendUpdate::error(error.to_string()),
                };
                let _ = update_tx.send(update).await;
                return;
            }

            let update = run_one(session, command, revision);
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
    let state = match session.read_state() {
        Ok(state) => Some(state),
        Err(error) => {
            return BackendUpdate {
                response,
                state: None,
                listing: None,
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
        pending.push(BackendCommand::ListDirectory(None));
        pending.push(BackendCommand::ListDirectory(Some("src".into())));
        assert_eq!(pending.len(), 3);
    }
}
