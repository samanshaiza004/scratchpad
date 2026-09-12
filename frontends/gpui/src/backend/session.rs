use crate::backend::ffi::{BackendSessionRaw, FfiError, LoadedBackend};
use crate::protocol::{
    CommandRequest, ResourceDescriptor, Response, StartRequest, StopRequest, VisibleTextSlice,
    decode_response, decode_state,
};
use std::path::PathBuf;
use thiserror::Error;

#[derive(Debug, Clone, Default)]
pub struct BackendSessionConfig {
    pub backend_library: Option<PathBuf>,
    pub workspace_path: Option<PathBuf>,
}

pub struct BackendSession {
    raw: BackendSessionRaw,
    start_response: Option<Response>,
}

unsafe impl Send for BackendSession {}

impl BackendSession {
    pub fn open(config: BackendSessionConfig) -> Result<Self, BackendSessionError> {
        let backend_library = config
            .backend_library
            .or_else(|| std::env::var_os("SCRATCHPAD_GPUI_BACKEND_LIBRARY").map(PathBuf::from))
            .or_else(|| std::env::var_os("SCRATCHPAD_BACKEND_LIBRARY").map(PathBuf::from))
            .ok_or(BackendSessionError::MissingBackendLibrary)?;
        let request = StartRequest::new(config.workspace_path)?;
        let json = serde_json::to_vec(&request)?;
        let mut raw = LoadedBackend::load(&backend_library)?.start(&json)?;
        let start_response = raw
            .take_start_response()
            .map(|bytes| decode_response(&bytes))
            .transpose()?;
        Ok(Self {
            raw,
            start_response,
        })
    }

    pub fn from_raw(raw: BackendSessionRaw) -> Self {
        Self {
            raw,
            start_response: None,
        }
    }

    pub fn take_start_response(&mut self) -> Option<Response> {
        self.start_response.take()
    }

    pub fn dispatch(&self, request: &CommandRequest) -> Result<(), BackendSessionError> {
        let json = serde_json::to_vec(request)?;
        self.raw.dispatch(&json)?;
        Ok(())
    }

    pub fn pump(&self) -> Result<Option<Response>, BackendSessionError> {
        let Some(response) = self.raw.pump()? else {
            return Ok(None);
        };
        Ok(Some(decode_response(&response)?))
    }

    pub fn read_state(&self) -> Result<crate::protocol::StateEnvelope, BackendSessionError> {
        let copy = self.raw.read_state_copy()?;
        Ok(decode_state(&copy.data)?)
    }

    pub fn read_visible_slice(
        &self,
        descriptor: &ResourceDescriptor,
    ) -> Result<VisibleTextSlice, BackendSessionError> {
        let bytes = self.read_visible_resource_copy(descriptor)?;
        Ok(VisibleTextSlice::decode(&bytes, descriptor)?)
    }

    pub fn read_visible_resource_copy(
        &self,
        descriptor: &ResourceDescriptor,
    ) -> Result<Vec<u8>, BackendSessionError> {
        Ok(self
            .raw
            .read_resource_copy(descriptor.resource_id, descriptor.generation)?)
    }

    pub fn wake_sequence(&self) -> Result<u64, BackendSessionError> {
        Ok(self.raw.wake_sequence()?)
    }

    pub fn shutdown(&mut self) -> Result<Option<Response>, BackendSessionError> {
        let request = StopRequest::new();
        let json = serde_json::to_vec(&request)?;
        let Some(response) = self.raw.shutdown(&json)? else {
            return Ok(None);
        };
        Ok(Some(decode_response(&response)?))
    }
}

#[derive(Debug, Error)]
pub enum BackendSessionError {
    #[error("SCRATCHPAD_GPUI_BACKEND_LIBRARY is required")]
    MissingBackendLibrary,
    #[error(transparent)]
    ProtocolPath(#[from] crate::protocol::ProtocolError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Ffi(#[from] FfiError),
}
