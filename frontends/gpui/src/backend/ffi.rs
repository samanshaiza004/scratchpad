use crate::protocol::{
    MAX_VISIBLE_BYTES, PROTOCOL_VERSION, STATE_SCHEMA_V1, VISIBLE_SLICE_HEADER_LEN,
};
use libloading::Library;
use std::ffi::c_void;
use std::mem::{ManuallyDrop, offset_of, size_of};
use std::path::Path;
use std::ptr::NonNull;
use std::{ptr, slice};
use thiserror::Error;

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CaliberStatus {
    Ok = 0,
    InvalidArgument = 1,
    InvalidHandle = 2,
    BufferTooSmall = 3,
    LimitExceeded = 4,
    NotFound = 5,
    Stale = 6,
    Unavailable = 7,
    QueueFull = 8,
    UnsupportedVersion = 9,
    Internal = 10,
}

impl CaliberStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            CaliberStatus::Ok => "ok",
            CaliberStatus::InvalidArgument => "invalid_argument",
            CaliberStatus::InvalidHandle => "invalid_handle",
            CaliberStatus::BufferTooSmall => "buffer_too_small",
            CaliberStatus::LimitExceeded => "limit_exceeded",
            CaliberStatus::NotFound => "not_found",
            CaliberStatus::Stale => "stale",
            CaliberStatus::Unavailable => "unavailable",
            CaliberStatus::QueueFull => "queue_full",
            CaliberStatus::UnsupportedVersion => "unsupported_version",
            CaliberStatus::Internal => "internal",
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CaliberContextConfig {
    pub struct_size: u32,
    pub max_command_bytes: usize,
    pub max_publication_bytes: usize,
    pub max_resource_bytes: usize,
    pub max_resources: usize,
    pub telemetry_width: usize,
    pub max_pending_commands: usize,
}

#[repr(C)]
#[derive(Debug)]
pub struct CaliberStatePublication {
    pub revision: u64,
    pub schema: u32,
    pub reserved: u32,
    pub data: *const u8,
    pub len: usize,
    pub lease: *mut c_void,
}

impl Default for CaliberStatePublication {
    fn default() -> Self {
        Self {
            revision: 0,
            schema: 0,
            reserved: 0,
            data: ptr::null(),
            len: 0,
            lease: ptr::null_mut(),
        }
    }
}

#[repr(C)]
#[derive(Debug)]
pub struct CaliberResourceView {
    pub resource_id: u64,
    pub generation: u64,
    pub data: *const u8,
    pub len: usize,
    pub lease: *mut c_void,
}

impl Default for CaliberResourceView {
    fn default() -> Self {
        Self {
            resource_id: 0,
            generation: 0,
            data: ptr::null(),
            len: 0,
            lease: ptr::null_mut(),
        }
    }
}

#[repr(C)]
pub struct CaliberTelemetryInfo {
    pub sequence: u64,
    pub schema: u32,
    pub reserved: u32,
    pub value_count: usize,
    pub value_size: usize,
}

#[repr(C)]
pub struct CaliberContext {
    _private: [u8; 0],
}

#[repr(C)]
pub struct CaliberApiV1 {
    pub abi_version: u32,
    pub struct_size: u32,
    pub context_create: Option<
        unsafe extern "C" fn(
            *const CaliberContextConfig,
            *mut *mut CaliberContext,
        ) -> CaliberStatus,
    >,
    pub context_destroy: Option<unsafe extern "C" fn(*mut CaliberContext)>,
    pub context_dispatch:
        Option<unsafe extern "C" fn(*const CaliberContext, *const u8, usize) -> CaliberStatus>,
    pub context_peek_command:
        Option<unsafe extern "C" fn(*const CaliberContext, *mut usize) -> CaliberStatus>,
    pub context_take_command: Option<
        unsafe extern "C" fn(*const CaliberContext, *mut u8, usize, *mut usize) -> CaliberStatus,
    >,
    pub context_publish_state: Option<
        unsafe extern "C" fn(
            *const CaliberContext,
            u32,
            *const u8,
            usize,
            *mut u64,
        ) -> CaliberStatus,
    >,
    pub context_read_latest_state: Option<
        unsafe extern "C" fn(*const CaliberContext, *mut CaliberStatePublication) -> CaliberStatus,
    >,
    pub state_publication_release: Option<unsafe extern "C" fn(*mut CaliberStatePublication)>,
    pub context_map_resource: Option<
        unsafe extern "C" fn(
            *const CaliberContext,
            u64,
            u64,
            *mut CaliberResourceView,
        ) -> CaliberStatus,
    >,
    pub resource_release: Option<unsafe extern "C" fn(*mut CaliberResourceView)>,
    pub context_publish_resource: Option<
        unsafe extern "C" fn(
            *const CaliberContext,
            *const u8,
            usize,
            *mut u64,
            *mut u64,
        ) -> CaliberStatus,
    >,
    pub context_release_resource:
        Option<unsafe extern "C" fn(*const CaliberContext, u64, u64) -> CaliberStatus>,
    pub context_publish_telemetry:
        Option<unsafe extern "C" fn(*const CaliberContext, *const usize, usize) -> CaliberStatus>,
    pub context_read_latest_telemetry: Option<
        unsafe extern "C" fn(
            *const CaliberContext,
            *mut usize,
            usize,
            *mut CaliberTelemetryInfo,
        ) -> CaliberStatus,
    >,
    pub context_wake_sequence:
        Option<unsafe extern "C" fn(*const CaliberContext, *mut u64) -> CaliberStatus>,
}

impl CaliberApiV1 {
    pub fn required_size() -> usize {
        offset_of!(CaliberApiV1, context_wake_sequence)
            + size_of::<
                Option<unsafe extern "C" fn(*const CaliberContext, *mut u64) -> CaliberStatus>,
            >()
    }

    pub fn validate(&self) -> Result<ValidatedCaliberApi, FfiError> {
        if self.abi_version != PROTOCOL_VERSION {
            return Err(FfiError::UnsupportedAbi {
                got: self.abi_version,
                want: PROTOCOL_VERSION,
            });
        }
        if (self.struct_size as usize) < Self::required_size() {
            return Err(FfiError::TruncatedApiTable {
                got: self.struct_size as usize,
                want: Self::required_size(),
            });
        }
        Ok(ValidatedCaliberApi {
            dispatch: self
                .context_dispatch
                .ok_or(FfiError::MissingApiFunction("context_dispatch"))?,
            read_latest_state: self
                .context_read_latest_state
                .ok_or(FfiError::MissingApiFunction("context_read_latest_state"))?,
            release_state: self
                .state_publication_release
                .ok_or(FfiError::MissingApiFunction("state_publication_release"))?,
            map_resource: self
                .context_map_resource
                .ok_or(FfiError::MissingApiFunction("context_map_resource"))?,
            release_resource: self
                .resource_release
                .ok_or(FfiError::MissingApiFunction("resource_release"))?,
            release_context_resource: self
                .context_release_resource
                .ok_or(FfiError::MissingApiFunction("context_release_resource"))?,
            wake_sequence: self
                .context_wake_sequence
                .ok_or(FfiError::MissingApiFunction("context_wake_sequence"))?,
        })
    }
}

#[derive(Clone, Copy)]
pub struct ValidatedCaliberApi {
    dispatch: unsafe extern "C" fn(*const CaliberContext, *const u8, usize) -> CaliberStatus,
    read_latest_state:
        unsafe extern "C" fn(*const CaliberContext, *mut CaliberStatePublication) -> CaliberStatus,
    release_state: unsafe extern "C" fn(*mut CaliberStatePublication),
    map_resource: unsafe extern "C" fn(
        *const CaliberContext,
        u64,
        u64,
        *mut CaliberResourceView,
    ) -> CaliberStatus,
    release_resource: unsafe extern "C" fn(*mut CaliberResourceView),
    release_context_resource:
        unsafe extern "C" fn(*const CaliberContext, u64, u64) -> CaliberStatus,
    wake_sequence: unsafe extern "C" fn(*const CaliberContext, *mut u64) -> CaliberStatus,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct BackendOutput {
    pub data: *mut u8,
    pub len: usize,
}

impl Default for BackendOutput {
    fn default() -> Self {
        Self {
            data: ptr::null_mut(),
            len: 0,
        }
    }
}

pub type BackendStatus = i32;
pub type StartFn =
    unsafe extern "C" fn(*const u8, usize, *mut *mut u8, *mut usize) -> BackendStatus;
pub type PumpFn = unsafe extern "C" fn(*mut *mut u8, *mut usize) -> BackendStatus;
pub type StopFn = unsafe extern "C" fn(*const u8, usize, *mut *mut u8, *mut usize) -> BackendStatus;
pub type FreeFn = unsafe extern "C" fn(*mut u8);
pub type LeaseFn = unsafe extern "C" fn() -> BackendStatus;

type ApiFn = unsafe extern "C" fn() -> *const CaliberApiV1;
type ContextFn = unsafe extern "C" fn() -> *mut CaliberContext;

#[derive(Clone, Copy)]
struct BridgeSymbols {
    pump: PumpFn,
    stop: StopFn,
    free: FreeFn,
    lease_acquired: LeaseFn,
    lease_released: LeaseFn,
    resource_lease_acquired: LeaseFn,
    resource_lease_released: LeaseFn,
}

pub struct LoadedBackend {
    library: Library,
    start: StartFn,
    caliber_api: ApiFn,
    caliber_context: ContextFn,
    symbols: BridgeSymbols,
}

impl LoadedBackend {
    pub fn load(path: &Path) -> Result<Self, FfiError> {
        // SAFETY: The backend path is selected by gpui-dev/user configuration.
        // The library is retained by BackendSessionRaw for the full lifetime of
        // copied function pointers and returned opaque handles.
        let library = unsafe { Library::new(path) }.map_err(FfiError::LoadLibrary)?;
        let start = load_symbol(&library, b"scratchpad_gpui_backend_start\0")?;
        let caliber_api = load_symbol(&library, b"scratchpad_gpui_backend_caliber_api\0")?;
        let caliber_context = load_symbol(&library, b"scratchpad_gpui_backend_caliber_context\0")?;
        let symbols = BridgeSymbols {
            pump: load_symbol(&library, b"scratchpad_gpui_backend_pump\0")?,
            stop: load_symbol(&library, b"scratchpad_gpui_backend_stop\0")?,
            free: load_symbol(&library, b"scratchpad_gpui_backend_free\0")?,
            lease_acquired: load_symbol(
                &library,
                b"scratchpad_gpui_backend_state_lease_acquired\0",
            )?,
            lease_released: load_symbol(
                &library,
                b"scratchpad_gpui_backend_state_lease_released\0",
            )?,
            resource_lease_acquired: load_symbol(
                &library,
                b"scratchpad_gpui_backend_resource_lease_acquired\0",
            )?,
            resource_lease_released: load_symbol(
                &library,
                b"scratchpad_gpui_backend_resource_lease_released\0",
            )?,
        };
        Ok(Self {
            library,
            start,
            caliber_api,
            caliber_context,
            symbols,
        })
    }

    pub fn start(self, start_json: &[u8]) -> Result<BackendSessionRaw, FfiError> {
        let LoadedBackend {
            library,
            start,
            caliber_api,
            caliber_context,
            symbols,
        } = self;
        // A Go c-shared library owns process-lifetime runtime state. Retain it
        // before invoking start so even a failed start/ABI validation cannot
        // accidentally unload a partially initialized Go runtime.
        let library = ManuallyDrop::new(library);
        let mut out = BackendOutput::default();
        let status = unsafe {
            (start)(
                start_json.as_ptr(),
                start_json.len(),
                &mut out.data,
                &mut out.len,
            )
        };
        let start_response = take_backend_output(out.data, out.len, symbols.free);
        if status != 0 {
            return Err(FfiError::Status {
                operation: "backend_start",
                status: CaliberStatus::Internal,
            });
        }
        let api_ptr =
            NonNull::new(unsafe { (caliber_api)() }.cast_mut()).ok_or(FfiError::NullApi)?;
        let context = NonNull::new(unsafe { (caliber_context)() }).ok_or(FfiError::NullContext)?;
        let api = unsafe { api_ptr.as_ref() }.validate()?;
        Ok(BackendSessionRaw {
            _library: Some(library),
            symbols,
            api,
            context,
            shutdown_done: false,
            start_response,
        })
    }
}

fn load_symbol<T: Copy>(library: &Library, name: &'static [u8]) -> Result<T, FfiError> {
    let symbol = unsafe { library.get::<T>(name) }
        .map_err(|_| FfiError::MissingBridgeSymbol(symbol_name(name)))?;
    Ok(*symbol)
}

fn symbol_name(name: &'static [u8]) -> &'static str {
    match name {
        b"scratchpad_gpui_backend_start\0" => "scratchpad_gpui_backend_start",
        b"scratchpad_gpui_backend_caliber_api\0" => "scratchpad_gpui_backend_caliber_api",
        b"scratchpad_gpui_backend_caliber_context\0" => "scratchpad_gpui_backend_caliber_context",
        b"scratchpad_gpui_backend_pump\0" => "scratchpad_gpui_backend_pump",
        b"scratchpad_gpui_backend_stop\0" => "scratchpad_gpui_backend_stop",
        b"scratchpad_gpui_backend_free\0" => "scratchpad_gpui_backend_free",
        b"scratchpad_gpui_backend_state_lease_acquired\0" => {
            "scratchpad_gpui_backend_state_lease_acquired"
        }
        b"scratchpad_gpui_backend_state_lease_released\0" => {
            "scratchpad_gpui_backend_state_lease_released"
        }
        b"scratchpad_gpui_backend_resource_lease_acquired\0" => {
            "scratchpad_gpui_backend_resource_lease_acquired"
        }
        b"scratchpad_gpui_backend_resource_lease_released\0" => {
            "scratchpad_gpui_backend_resource_lease_released"
        }
        _ => "unknown",
    }
}

pub struct BackendSessionRaw {
    _library: Option<ManuallyDrop<Library>>,
    symbols: BridgeSymbols,
    api: ValidatedCaliberApi,
    context: NonNull<CaliberContext>,
    shutdown_done: bool,
    start_response: Option<Vec<u8>>,
}

unsafe impl Send for BackendSessionRaw {}

impl BackendSessionRaw {
    #[allow(clippy::too_many_arguments)]
    pub fn from_parts(
        api: &'static CaliberApiV1,
        context: NonNull<CaliberContext>,
        pump: PumpFn,
        stop: StopFn,
        free: FreeFn,
        lease_acquired: LeaseFn,
        lease_released: LeaseFn,
        resource_lease_acquired: LeaseFn,
        resource_lease_released: LeaseFn,
    ) -> Result<Self, FfiError> {
        Ok(Self {
            _library: None,
            symbols: BridgeSymbols {
                pump,
                stop,
                free,
                lease_acquired,
                lease_released,
                resource_lease_acquired,
                resource_lease_released,
            },
            api: api.validate()?,
            context,
            shutdown_done: false,
            start_response: None,
        })
    }

    pub fn take_start_response(&mut self) -> Option<Vec<u8>> {
        self.start_response.take()
    }

    pub fn dispatch(&self, bytes: &[u8]) -> Result<(), FfiError> {
        let ptr = if bytes.is_empty() {
            ptr::null()
        } else {
            bytes.as_ptr()
        };
        let status = unsafe { (self.api.dispatch)(self.context.as_ptr(), ptr, bytes.len()) };
        if status == CaliberStatus::Ok {
            Ok(())
        } else {
            Err(FfiError::Status {
                operation: "context_dispatch",
                status,
            })
        }
    }

    pub fn pump(&self) -> Result<Option<Vec<u8>>, FfiError> {
        let mut out = BackendOutput::default();
        let status = unsafe { (self.symbols.pump)(&mut out.data, &mut out.len) };
        let response = take_backend_output(out.data, out.len, self.symbols.free);
        if status == 0 {
            Ok(response)
        } else {
            Err(FfiError::Status {
                operation: "backend_pump",
                status: CaliberStatus::Internal,
            })
        }
    }

    pub fn wake_sequence(&self) -> Result<u64, FfiError> {
        let mut sequence = 0;
        let status = unsafe { (self.api.wake_sequence)(self.context.as_ptr(), &mut sequence) };
        if status == CaliberStatus::Ok {
            Ok(sequence)
        } else {
            Err(FfiError::Status {
                operation: "context_wake_sequence",
                status,
            })
        }
    }

    pub fn read_state_copy(&self) -> Result<StateCopy, FfiError> {
        let lease = StateLease::acquire(
            self.context,
            self.api,
            self.symbols.lease_acquired,
            self.symbols.lease_released,
        )?;
        lease.copy()
    }

    pub fn read_resource_copy(
        &self,
        resource_id: u64,
        generation: u64,
    ) -> Result<Vec<u8>, FfiError> {
        let lease = ResourceLease::acquire(
            self.context,
            self.api,
            self.symbols.resource_lease_acquired,
            self.symbols.resource_lease_released,
            resource_id,
            generation,
        )?;
        lease.copy()
    }

    pub fn shutdown(&mut self, stop_json: &[u8]) -> Result<Option<Vec<u8>>, FfiError> {
        if self.shutdown_done {
            return Ok(None);
        }
        let mut out = BackendOutput::default();
        let ptr = if stop_json.is_empty() {
            ptr::null()
        } else {
            stop_json.as_ptr()
        };
        let status =
            unsafe { (self.symbols.stop)(ptr, stop_json.len(), &mut out.data, &mut out.len) };
        let response = take_backend_output(out.data, out.len, self.symbols.free);
        if status == 0 {
            self.shutdown_done = true;
            Ok(response)
        } else {
            Err(FfiError::Status {
                operation: "backend_stop",
                status: CaliberStatus::Internal,
            })
        }
    }
}

impl Drop for BackendSessionRaw {
    fn drop(&mut self) {
        if !self.shutdown_done {
            let _ = self.shutdown(&[]);
        }
    }
}

fn take_backend_output(data_ptr: *mut u8, len: usize, free: FreeFn) -> Option<Vec<u8>> {
    if data_ptr.is_null() {
        return None;
    }
    let data = if len == 0 {
        Vec::new()
    } else {
        unsafe { slice::from_raw_parts(data_ptr, len) }.to_vec()
    };
    unsafe { free(data_ptr) };
    Some(data)
}

struct StateLease {
    publication: CaliberStatePublication,
    api: ValidatedCaliberApi,
    lease_released: LeaseFn,
    accounted: bool,
}

impl StateLease {
    fn acquire(
        context: NonNull<CaliberContext>,
        api: ValidatedCaliberApi,
        lease_acquired: LeaseFn,
        lease_released: LeaseFn,
    ) -> Result<Self, FfiError> {
        let mut publication = CaliberStatePublication::default();
        let status = unsafe { (api.read_latest_state)(context.as_ptr(), &mut publication) };
        if status != CaliberStatus::Ok {
            return Err(FfiError::Status {
                operation: "context_read_latest_state",
                status,
            });
        }
        if publication.schema != STATE_SCHEMA_V1 {
            let got = publication.schema;
            let mut lease = Self {
                publication,
                api,
                lease_released,
                accounted: false,
            };
            lease.release();
            return Err(FfiError::UnsupportedStateSchema {
                got,
                want: STATE_SCHEMA_V1,
            });
        }
        if unsafe { (lease_acquired)() } != 0 {
            unsafe { (api.release_state)(&mut publication) };
            return Err(FfiError::LeaseAccountingFailed);
        }
        Ok(Self {
            publication,
            api,
            lease_released,
            accounted: true,
        })
    }

    fn copy(mut self) -> Result<StateCopy, FfiError> {
        if self.publication.len > 0 && self.publication.data.is_null() {
            self.release();
            return Err(FfiError::NullStateData);
        }
        let data = if self.publication.len == 0 {
            Vec::new()
        } else {
            unsafe { slice::from_raw_parts(self.publication.data, self.publication.len) }.to_vec()
        };
        let copy = StateCopy {
            revision: self.publication.revision,
            schema: self.publication.schema,
            data,
        };
        self.release();
        Ok(copy)
    }

    fn release(&mut self) {
        if !self.publication.lease.is_null() {
            unsafe { (self.api.release_state)(&mut self.publication) };
            if self.accounted {
                let _ = unsafe { (self.lease_released)() };
                self.accounted = false;
            }
            self.publication.lease = ptr::null_mut();
            self.publication.data = ptr::null();
            self.publication.len = 0;
        }
    }
}

impl Drop for StateLease {
    fn drop(&mut self) {
        self.release();
    }
}

struct ResourceLease {
    view: CaliberResourceView,
    api: ValidatedCaliberApi,
    context: NonNull<CaliberContext>,
    resource_id: u64,
    generation: u64,
    lease_released: LeaseFn,
    accounted: bool,
    released: bool,
}

impl ResourceLease {
    fn acquire(
        context: NonNull<CaliberContext>,
        api: ValidatedCaliberApi,
        lease_acquired: LeaseFn,
        lease_released: LeaseFn,
        resource_id: u64,
        generation: u64,
    ) -> Result<Self, FfiError> {
        let mut view = CaliberResourceView::default();
        let status =
            unsafe { (api.map_resource)(context.as_ptr(), resource_id, generation, &mut view) };
        if status != CaliberStatus::Ok {
            return Err(FfiError::Status {
                operation: "context_map_resource",
                status,
            });
        }
        if unsafe { (lease_acquired)() } != 0 {
            unsafe { (api.release_resource)(&mut view) };
            let _ = unsafe {
                (api.release_context_resource)(context.as_ptr(), resource_id, generation)
            };
            return Err(FfiError::ResourceLeaseAccountingFailed);
        }
        Ok(Self {
            view,
            api,
            context,
            resource_id,
            generation,
            lease_released,
            accounted: true,
            released: false,
        })
    }

    fn copy(mut self) -> Result<Vec<u8>, FfiError> {
        if self.view.len > MAX_VISIBLE_BYTES + VISIBLE_SLICE_HEADER_LEN {
            let len = self.view.len;
            self.release();
            return Err(FfiError::ResourceTooLarge {
                len,
                max: MAX_VISIBLE_BYTES + VISIBLE_SLICE_HEADER_LEN,
            });
        }
        if self.view.len > 0 && self.view.data.is_null() {
            self.release();
            return Err(FfiError::NullResourceData);
        }
        let data = if self.view.len == 0 {
            Vec::new()
        } else {
            unsafe { slice::from_raw_parts(self.view.data, self.view.len) }.to_vec()
        };
        self.release();
        Ok(data)
    }

    fn release(&mut self) {
        if self.released {
            return;
        }
        if !self.view.lease.is_null() {
            unsafe { (self.api.release_resource)(&mut self.view) };
        }
        let _ = unsafe {
            (self.api.release_context_resource)(
                self.context.as_ptr(),
                self.resource_id,
                self.generation,
            )
        };
        if self.accounted {
            let _ = unsafe { (self.lease_released)() };
            self.accounted = false;
        }
        self.view = CaliberResourceView::default();
        self.released = true;
    }
}

impl Drop for ResourceLease {
    fn drop(&mut self) {
        self.release();
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateCopy {
    pub revision: u64,
    pub schema: u32,
    pub data: Vec<u8>,
}

#[derive(Debug, Error)]
pub enum FfiError {
    #[error("load backend library: {0}")]
    LoadLibrary(#[source] libloading::Error),
    #[error("missing backend bridge symbol {0}")]
    MissingBridgeSymbol(&'static str),
    #[error("Caliber ABI version mismatch: got {got}, want {want}")]
    UnsupportedAbi { got: u32, want: u32 },
    #[error("Caliber ABI table is truncated: got {got} bytes, want at least {want}")]
    TruncatedApiTable { got: usize, want: usize },
    #[error("missing Caliber API function {0}")]
    MissingApiFunction(&'static str),
    #[error("backend returned a null Caliber API pointer")]
    NullApi,
    #[error("backend returned a null Caliber context pointer")]
    NullContext,
    #[error("{operation} returned {status:?} ({})", status.as_str())]
    Status {
        operation: &'static str,
        status: CaliberStatus,
    },
    #[error("state schema mismatch: got {got}, want {want}")]
    UnsupportedStateSchema { got: u32, want: u32 },
    #[error("state lease returned non-zero length with null data pointer")]
    NullStateData,
    #[error("backend rejected state lease accounting")]
    LeaseAccountingFailed,
    #[error("backend rejected resource lease accounting")]
    ResourceLeaseAccountingFailed,
    #[error("resource returned non-zero length with null data pointer")]
    NullResourceData,
    #[error("resource length {len} exceeds {max} byte bound")]
    ResourceTooLarge { len: usize, max: usize },
}
