use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use thiserror::Error;

pub const PROTOCOL_VERSION: u32 = 1;
pub const STATE_SCHEMA_V1: u32 = 1;
pub const VISIBLE_SLICE_SCHEMA_V1: u32 = 1;
pub const DEFAULT_LIST_LIMIT: usize = 200;
pub const MAX_VISIBLE_LINES: usize = 256;
pub const MAX_VISIBLE_BYTES: usize = 64 * 1024;
pub const VISIBLE_SLICE_HEADER_LEN: usize = 48;

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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_line: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_lines: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_bytes: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub editor_revision: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_byte: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_byte: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub replacement: Option<Vec<u8>>,
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

    pub fn read_visible_lines(
        document_id: impl Into<String>,
        start_line: usize,
        max_lines: usize,
        max_bytes: usize,
        based_on_revision: u64,
    ) -> Self {
        let mut request = Self::bare(CommandKind::ReadVisibleLines, based_on_revision);
        request.document_id = Some(document_id.into());
        request.start_line = Some(start_line);
        request.max_lines = Some(max_lines);
        request.max_bytes = Some(max_bytes);
        request
    }

    pub fn replace_document(
        document_id: impl Into<String>,
        editor_revision: u64,
        start_byte: usize,
        end_byte: usize,
        replacement: &[u8],
        based_on_revision: u64,
    ) -> Self {
        let mut request = Self::bare(CommandKind::ReplaceDocument, based_on_revision);
        request.document_id = Some(document_id.into());
        request.editor_revision = Some(editor_revision);
        request.start_byte = Some(start_byte);
        request.end_byte = Some(end_byte);
        request.replacement = Some(replacement.to_vec());
        request
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
            start_line: None,
            max_lines: None,
            max_bytes: None,
            editor_revision: None,
            start_byte: None,
            end_byte: None,
            replacement: None,
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
    ReadVisibleLines,
    ReplaceDocument,
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
    #[serde(default)]
    pub resource: Option<ResourceDescriptor>,
    #[serde(default)]
    pub edit: Option<EditAck>,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ResourceDescriptor {
    pub resource_id: u64,
    pub generation: u64,
    pub document_id: String,
    pub application_revision: u64,
    pub editor_revision: u64,
    pub start_line: usize,
    pub end_line: usize,
    pub byte_len: usize,
    pub truncated: bool,
    pub start_byte: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EditAck {
    pub document_id: String,
    pub editor_revision: u64,
    pub start_byte: usize,
    pub old_end_byte: usize,
    pub new_end_byte: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VisibleTextSlice {
    pub document_id: String,
    pub application_revision: u64,
    pub editor_revision: u64,
    pub start_line: usize,
    pub end_line: usize,
    pub truncated: bool,
    pub start_byte: usize,
    pub bytes: Vec<u8>,
}

impl VisibleTextSlice {
    pub fn decode(
        bytes: &[u8],
        descriptor: &ResourceDescriptor,
    ) -> std::result::Result<Self, ProtocolError> {
        if bytes.len() < VISIBLE_SLICE_HEADER_LEN {
            return Err(ProtocolError::MalformedVisibleSlice(
                "resource is shorter than its header",
            ));
        }
        if &bytes[..4] != b"SPVS" {
            return Err(ProtocolError::MalformedVisibleSlice(
                "resource magic mismatch",
            ));
        }
        let schema = read_u32(bytes, 4);
        if schema != VISIBLE_SLICE_SCHEMA_V1 {
            return Err(ProtocolError::MalformedVisibleSlice(
                "unsupported visible slice schema",
            ));
        }
        let application_revision = read_u64(bytes, 8);
        let editor_revision = read_u64(bytes, 16);
        let start_line = read_u64(bytes, 24) as usize;
        let end_line = read_u64(bytes, 32) as usize;
        let flags = read_u32(bytes, 40);
        let payload_len = read_u32(bytes, 44) as usize;
        if payload_len != bytes.len() - VISIBLE_SLICE_HEADER_LEN {
            return Err(ProtocolError::MalformedVisibleSlice(
                "visible slice length mismatch",
            ));
        }
        if payload_len != descriptor.byte_len
            || application_revision != descriptor.application_revision
            || editor_revision != descriptor.editor_revision
            || start_line != descriptor.start_line
            || end_line != descriptor.end_line
            || (flags & 1 != 0) != descriptor.truncated
        {
            return Err(ProtocolError::MalformedVisibleSlice(
                "resource descriptor mismatch",
            ));
        }
        if payload_len > MAX_VISIBLE_BYTES || end_line < start_line {
            return Err(ProtocolError::MalformedVisibleSlice(
                "visible slice exceeds bounds",
            ));
        }
        Ok(Self {
            document_id: descriptor.document_id.clone(),
            application_revision,
            editor_revision,
            start_line,
            end_line,
            truncated: flags & 1 != 0,
            bytes: bytes[VISIBLE_SLICE_HEADER_LEN..].to_vec(),
            start_byte: descriptor.start_byte,
        })
    }

    pub fn display_text(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }
}

fn read_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(
        bytes[offset..offset + 4]
            .try_into()
            .expect("visible slice header"),
    )
}

fn read_u64(bytes: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes(
        bytes[offset..offset + 8]
            .try_into()
            .expect("visible slice header"),
    )
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProtocolError {
    #[error("{field} must be valid UTF-8")]
    InvalidUtf8Path { field: &'static str },
    #[error("{field} must not contain NUL")]
    NulPath { field: &'static str },
    #[error("{field} is required")]
    MissingPath { field: &'static str },
    #[error("malformed visible slice: {0}")]
    MalformedVisibleSlice(&'static str),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn encoded_slice(
        application_revision: u64,
        editor_revision: u64,
        start_line: u64,
        end_line: u64,
        truncated: bool,
        payload: &[u8],
    ) -> Vec<u8> {
        let mut bytes = vec![0; VISIBLE_SLICE_HEADER_LEN + payload.len()];
        bytes[..4].copy_from_slice(b"SPVS");
        bytes[4..8].copy_from_slice(&VISIBLE_SLICE_SCHEMA_V1.to_le_bytes());
        bytes[8..16].copy_from_slice(&application_revision.to_le_bytes());
        bytes[16..24].copy_from_slice(&editor_revision.to_le_bytes());
        bytes[24..32].copy_from_slice(&start_line.to_le_bytes());
        bytes[32..40].copy_from_slice(&end_line.to_le_bytes());
        bytes[40..44].copy_from_slice(&(u32::from(truncated)).to_le_bytes());
        bytes[44..48].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        bytes[VISIBLE_SLICE_HEADER_LEN..].copy_from_slice(payload);
        bytes
    }

    #[test]
    fn visible_slice_decode_validates_descriptor_and_bounds() {
        let payload = b"line 12\nline 13\n";
        let descriptor = ResourceDescriptor {
            resource_id: 7,
            generation: 3,
            document_id: "doc".to_string(),
            application_revision: 9,
            editor_revision: 11,
            start_line: 12,
            end_line: 14,
            byte_len: payload.len(),
            truncated: false,
            start_byte: 128,
        };
        let bytes = encoded_slice(9, 11, 12, 14, false, payload);
        let slice = VisibleTextSlice::decode(&bytes, &descriptor).expect("decode slice");
        assert_eq!(slice.bytes, payload);
        assert_eq!(slice.start_byte, 128);
        assert_eq!(slice.display_text(), "line 12\nline 13\n");

        let mut mismatched = descriptor.clone();
        mismatched.byte_len += 1;
        assert!(VisibleTextSlice::decode(&bytes, &mismatched).is_err());

        let oversized = vec![0; VISIBLE_SLICE_HEADER_LEN + MAX_VISIBLE_BYTES + 1];
        assert!(VisibleTextSlice::decode(&oversized, &descriptor).is_err());
    }
}
