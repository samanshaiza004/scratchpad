use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use thiserror::Error;

pub const PROTOCOL_VERSION: u32 = 1;
pub const STATE_SCHEMA_V1: u32 = 1;
pub const DEFAULT_LIST_LIMIT: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StartRequest {
    pub version: u32,
    pub request_id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_path: Option<String>,
}

impl StartRequest {
    pub fn new(workspace_path: Option<PathBuf>) -> Result<Self> {
        Ok(Self {
            version: PROTOCOL_VERSION,
            request_id: request_id(),
            workspace_path: optional_path(workspace_path.as_deref(), "workspace_path")?,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StopRequest {
    pub version: u32,
    pub request_id: u64,
}

impl StopRequest {
    pub fn new() -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id(),
        }
    }
}

impl Default for StopRequest {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CommandRequest {
    pub version: u32,
    pub request_id: u64,
    pub based_on_revision: u64,
    pub command: CommandKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discard: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relative_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
}

impl CommandRequest {
    pub fn snapshot(based_on_revision: u64) -> Self {
        Self::bare(CommandKind::Snapshot, based_on_revision)
    }

    pub fn ping() -> Self {
        Self::bare(CommandKind::Ping, 0)
    }

    pub fn open_path(path: &Path, based_on_revision: u64) -> Result<Self> {
        let mut request = Self::bare(CommandKind::OpenPath, based_on_revision);
        request.path = Some(required_path(path, "path")?);
        Ok(request)
    }

    pub fn select_document(document_id: impl Into<String>, based_on_revision: u64) -> Self {
        let mut request = Self::bare(CommandKind::SelectDocument, based_on_revision);
        request.document_id = Some(document_id.into());
        request
    }

    pub fn save_document(document_id: impl Into<String>, based_on_revision: u64) -> Self {
        let mut request = Self::bare(CommandKind::SaveDocument, based_on_revision);
        request.document_id = Some(document_id.into());
        request
    }

    pub fn close_document(
        document_id: impl Into<String>,
        discard: bool,
        based_on_revision: u64,
    ) -> Self {
        let mut request = Self::bare(CommandKind::CloseDocument, based_on_revision);
        request.document_id = Some(document_id.into());
        request.discard = Some(discard);
        request
    }

    pub fn list_directory(relative_path: Option<&Path>, based_on_revision: u64) -> Result<Self> {
        let mut request = Self::bare(CommandKind::ListDirectory, based_on_revision);
        request.relative_path = optional_path(relative_path, "relative_path")?;
        request.limit = Some(DEFAULT_LIST_LIMIT);
        Ok(request)
    }

    fn bare(command: CommandKind, based_on_revision: u64) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id(),
            based_on_revision,
            command,
            path: None,
            document_id: None,
            discard: None,
            relative_path: None,
            limit: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CommandKind {
    Snapshot,
    Ping,
    OpenPath,
    SelectDocument,
    SaveDocument,
    CloseDocument,
    ListDirectory,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Response {
    pub version: u32,
    #[serde(default)]
    pub request_id: u64,
    pub lifecycle: String,
    pub ok: bool,
    pub outcome: Outcome,
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub based_on_revision: u64,
    #[serde(default)]
    pub state: Option<StateEnvelope>,
    #[serde(default)]
    pub directory_listing: Option<DirectoryListing>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Outcome {
    pub code: String,
    #[serde(default)]
    pub message: String,
    #[serde(default)]
    pub retryable: bool,
}

impl Outcome {
    pub fn ok() -> Self {
        Self {
            code: "ok".to_string(),
            message: String::new(),
            retryable: false,
        }
    }

    pub fn error(code: impl Into<String>, message: impl Into<String>, retryable: bool) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            retryable,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct StateEnvelope {
    pub schema: u32,
    pub revision: u64,
    pub application_revision: u64,
    pub has_workspace: bool,
    #[serde(default)]
    pub workspace_root: String,
    #[serde(default)]
    pub active: String,
    #[serde(default)]
    pub documents: Vec<StateDocument>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StateDocument {
    pub id: String,
    pub path: String,
    pub status: String,
    pub dirty: bool,
    pub editor_revision: u64,
    #[serde(default)]
    pub language: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DirectoryListing {
    pub relative_path: String,
    pub limit: usize,
    pub truncated: bool,
    pub entries: Vec<DirectoryEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DirectoryEntry {
    pub name: String,
    pub path: String,
    pub dir: bool,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProtocolError {
    #[error("{field} must be valid UTF-8")]
    InvalidUtf8Path { field: &'static str },
    #[error("{field} must not contain NUL")]
    NulPath { field: &'static str },
    #[error("{field} is required")]
    MissingPath { field: &'static str },
}

pub type Result<T> = std::result::Result<T, ProtocolError>;

fn request_id() -> u64 {
    static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);
    NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed)
}

fn required_path(path: &Path, field: &'static str) -> Result<String> {
    let value = optional_path(Some(path), field)?;
    value.ok_or(ProtocolError::MissingPath { field })
}

fn optional_path(path: Option<&Path>, field: &'static str) -> Result<Option<String>> {
    let Some(path) = path else {
        return Ok(None);
    };
    let Some(value) = path.to_str() else {
        return Err(ProtocolError::InvalidUtf8Path { field });
    };
    if value.contains('\0') {
        return Err(ProtocolError::NulPath { field });
    }
    Ok(Some(value.to_string()))
}

pub fn decode_response(bytes: &[u8]) -> std::result::Result<Response, serde_json::Error> {
    serde_json::from_slice(bytes)
}

pub fn decode_state(bytes: &[u8]) -> std::result::Result<StateEnvelope, serde_json::Error> {
    serde_json::from_slice(bytes)
}
