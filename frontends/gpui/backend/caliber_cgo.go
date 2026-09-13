package backend

/*
#cgo darwin LDFLAGS: -lcaliber_ffi -Wl,-rpath,@loader_path -Wl,-rpath,@executable_path
#cgo linux LDFLAGS: -lcaliber_ffi -Wl,-rpath,$ORIGIN
// Select the DLL explicitly: -lcaliber_ffi can pick Rust's MSVC static .lib.
#cgo windows LDFLAGS: -l:caliber_ffi.dll
#include <stdint.h>
#include <stddef.h>

typedef enum CaliberStatus {
	CaliberStatusOk = 0,
	CaliberStatusInvalidArgument = 1,
	CaliberStatusInvalidHandle = 2,
	CaliberStatusBufferTooSmall = 3,
	CaliberStatusLimitExceeded = 4,
	CaliberStatusNotFound = 5,
	CaliberStatusStale = 6,
	CaliberStatusUnavailable = 7,
	CaliberStatusQueueFull = 8,
	CaliberStatusUnsupportedVersion = 9,
	CaliberStatusInternal = 10,
} CaliberStatus;

typedef struct CaliberContext CaliberContext;

typedef struct CaliberContextConfig {
	uint32_t struct_size;
	size_t max_command_bytes;
	size_t max_publication_bytes;
	size_t max_resource_bytes;
	size_t max_resources;
	size_t telemetry_width;
	size_t max_pending_commands;
} CaliberContextConfig;

typedef struct CaliberStatePublication {
	uint64_t revision;
	uint32_t schema;
	uint32_t reserved;
	const uint8_t *data;
	size_t len;
	void *lease;
} CaliberStatePublication;

typedef struct CaliberResourceView {
	uint64_t resource_id;
	uint64_t generation;
	const uint8_t *data;
	size_t len;
	void *lease;
} CaliberResourceView;

typedef struct CaliberApiV1 {
	uint32_t abi_version;
	uint32_t struct_size;
	CaliberStatus (*context_create)(const CaliberContextConfig *, CaliberContext **);
	void (*context_destroy)(CaliberContext *);
	CaliberStatus (*context_dispatch)(const CaliberContext *, const uint8_t *, size_t);
	CaliberStatus (*context_peek_command)(const CaliberContext *, size_t *);
	CaliberStatus (*context_take_command)(const CaliberContext *, uint8_t *, size_t, size_t *);
	CaliberStatus (*context_publish_state)(const CaliberContext *, uint32_t, const uint8_t *, size_t, uint64_t *);
	CaliberStatus (*context_read_latest_state)(const CaliberContext *, CaliberStatePublication *);
	void (*state_publication_release)(CaliberStatePublication *);
	CaliberStatus (*context_map_resource)(const CaliberContext *, uint64_t, uint64_t, CaliberResourceView *);
	void (*resource_release)(CaliberResourceView *);
	CaliberStatus (*context_publish_resource)(const CaliberContext *, const uint8_t *, size_t, uint64_t *, uint64_t *);
	CaliberStatus (*context_release_resource)(const CaliberContext *, uint64_t, uint64_t);
	CaliberStatus (*context_publish_telemetry)(const CaliberContext *, const size_t *, size_t);
	CaliberStatus (*context_read_latest_telemetry)(const CaliberContext *, size_t *, size_t, void *);
	CaliberStatus (*context_wake_sequence)(const CaliberContext *, uint64_t *);
} CaliberApiV1;

extern const CaliberApiV1 *caliber_get_api(uint32_t version);

static size_t scratchpad_caliber_api_required_size(void) {
	return offsetof(CaliberApiV1, context_wake_sequence) + sizeof(((CaliberApiV1 *)0)->context_wake_sequence);
}

static CaliberStatus scratchpad_context_create(const CaliberApiV1 *api, const CaliberContextConfig *config, CaliberContext **out) {
	if (api == NULL || api->context_create == NULL) {
		return CaliberStatusInternal;
	}
	return api->context_create(config, out);
}

static void scratchpad_context_destroy(const CaliberApiV1 *api, CaliberContext *ctx) {
	if (api != NULL && api->context_destroy != NULL) {
		api->context_destroy(ctx);
	}
}

static CaliberStatus scratchpad_context_dispatch(const CaliberApiV1 *api, const CaliberContext *ctx, const uint8_t *data, size_t len) {
	if (api == NULL || api->context_dispatch == NULL) {
		return CaliberStatusInternal;
	}
	return api->context_dispatch(ctx, data, len);
}

static CaliberStatus scratchpad_context_peek_command(const CaliberApiV1 *api, const CaliberContext *ctx, size_t *out_len) {
	if (api == NULL || api->context_peek_command == NULL) {
		return CaliberStatusInternal;
	}
	return api->context_peek_command(ctx, out_len);
}

static CaliberStatus scratchpad_context_take_command(const CaliberApiV1 *api, const CaliberContext *ctx, uint8_t *out, size_t capacity, size_t *out_len) {
	if (api == NULL || api->context_take_command == NULL) {
		return CaliberStatusInternal;
	}
	return api->context_take_command(ctx, out, capacity, out_len);
}

static CaliberStatus scratchpad_context_publish_state(const CaliberApiV1 *api, const CaliberContext *ctx, uint32_t schema, const uint8_t *data, size_t len, uint64_t *revision) {
	if (api == NULL || api->context_publish_state == NULL) {
		return CaliberStatusInternal;
	}
	return api->context_publish_state(ctx, schema, data, len, revision);
}

static CaliberStatus scratchpad_context_read_latest_state(const CaliberApiV1 *api, const CaliberContext *ctx, CaliberStatePublication *out) {
	if (api == NULL || api->context_read_latest_state == NULL) {
		return CaliberStatusInternal;
	}
	return api->context_read_latest_state(ctx, out);
}

static void scratchpad_state_publication_release(const CaliberApiV1 *api, CaliberStatePublication *publication) {
	if (api != NULL && api->state_publication_release != NULL) {
		api->state_publication_release(publication);
	}
}

static CaliberStatus scratchpad_context_map_resource(const CaliberApiV1 *api, const CaliberContext *ctx, uint64_t resource_id, uint64_t generation, CaliberResourceView *out) {
	if (api == NULL || api->context_map_resource == NULL) {
		return CaliberStatusInternal;
	}
	return api->context_map_resource(ctx, resource_id, generation, out);
}

static void scratchpad_resource_release(const CaliberApiV1 *api, CaliberResourceView *view) {
	if (api != NULL && api->resource_release != NULL) {
		api->resource_release(view);
	}
}

static CaliberStatus scratchpad_context_publish_resource(const CaliberApiV1 *api, const CaliberContext *ctx, const uint8_t *data, size_t len, uint64_t *resource_id, uint64_t *generation) {
	if (api == NULL || api->context_publish_resource == NULL) {
		return CaliberStatusInternal;
	}
	return api->context_publish_resource(ctx, data, len, resource_id, generation);
}

static CaliberStatus scratchpad_context_release_resource(const CaliberApiV1 *api, const CaliberContext *ctx, uint64_t resource_id, uint64_t generation) {
	if (api == NULL || api->context_release_resource == NULL) {
		return CaliberStatusInternal;
	}
	return api->context_release_resource(ctx, resource_id, generation);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"runtime"
	"unsafe"
)

const requiredCaliberCommit = "abbe4f7"

var errNoCommand = errors.New("no pending Caliber command")

type caliberRuntime struct {
	api *C.CaliberApiV1
	ctx *C.CaliberContext
}

type caliberStateLease struct {
	Revision uint64
	Schema   uint32
	Data     unsafe.Pointer
	Len      uintptr
	lease    unsafe.Pointer
}

func loadCaliber() (*caliberRuntime, error) {
	api := C.caliber_get_api(C.uint32_t(ProtocolVersion))
	if api == nil {
		return nil, errors.New("linked Caliber cdylib does not support ABI version 1")
	}
	if api.abi_version != C.uint32_t(ProtocolVersion) {
		return nil, fmt.Errorf("Caliber ABI version mismatch: got %d want %d", uint32(api.abi_version), ProtocolVersion)
	}
	if C.size_t(api.struct_size) < C.scratchpad_caliber_api_required_size() {
		return nil, errors.New("Caliber ABI table is truncated")
	}
	config := C.CaliberContextConfig{
		struct_size:           C.uint32_t(unsafe.Sizeof(C.CaliberContextConfig{})),
		max_command_bytes:     C.size_t(MaxInputBytes),
		max_publication_bytes: C.size_t(MaxInputBytes),
		max_resource_bytes:    C.size_t(1 << 20),
		max_resources:         C.size_t(64),
		telemetry_width:       C.size_t(4),
		max_pending_commands:  C.size_t(16),
	}
	var ctx *C.CaliberContext
	if status := C.scratchpad_context_create(api, &config, &ctx); status != C.CaliberStatusOk {
		return nil, fmt.Errorf("create Caliber context: %s", caliberStatusString(status))
	}
	return &caliberRuntime{api: api, ctx: ctx}, nil
}

func (c *caliberRuntime) close() {
	if c == nil || c.ctx == nil {
		return
	}
	C.scratchpad_context_destroy(c.api, c.ctx)
	c.ctx = nil
}

func (c *caliberRuntime) apiPointer() unsafe.Pointer {
	if c == nil {
		return nil
	}
	return unsafe.Pointer(c.api)
}

func (c *caliberRuntime) contextPointer() unsafe.Pointer {
	if c == nil {
		return nil
	}
	return unsafe.Pointer(c.ctx)
}

func (c *caliberRuntime) dispatch(data []byte) error {
	var ptr *C.uint8_t
	if len(data) > 0 {
		ptr = (*C.uint8_t)(unsafe.Pointer(&data[0]))
	}
	if status := C.scratchpad_context_dispatch(c.api, c.ctx, ptr, C.size_t(len(data))); status != C.CaliberStatusOk {
		runtime.KeepAlive(data)
		return fmt.Errorf("Caliber dispatch: %s", caliberStatusString(status))
	}
	runtime.KeepAlive(data)
	return nil
}

func (c *caliberRuntime) takeCommand() ([]byte, error) {
	var length C.size_t
	if status := C.scratchpad_context_peek_command(c.api, c.ctx, &length); status != C.CaliberStatusOk {
		if status == C.CaliberStatusUnavailable {
			return nil, errNoCommand
		}
		return nil, fmt.Errorf("Caliber command peek: %s", caliberStatusString(status))
	}
	if uint64(length) > MaxInputBytes {
		return nil, fmt.Errorf("Caliber command exceeds %d byte limit", MaxInputBytes)
	}
	out := make([]byte, int(length))
	var outLen C.size_t
	var ptr *C.uint8_t
	if len(out) > 0 {
		ptr = (*C.uint8_t)(unsafe.Pointer(&out[0]))
	}
	if status := C.scratchpad_context_take_command(c.api, c.ctx, ptr, C.size_t(len(out)), &outLen); status != C.CaliberStatusOk {
		runtime.KeepAlive(out)
		return nil, fmt.Errorf("Caliber command take: %s", caliberStatusString(status))
	}
	runtime.KeepAlive(out)
	return out[:int(outLen)], nil
}

func (c *caliberRuntime) publishState(payload []byte) (uint64, error) {
	var revision C.uint64_t
	var ptr *C.uint8_t
	if len(payload) > 0 {
		ptr = (*C.uint8_t)(unsafe.Pointer(&payload[0]))
	}
	status := C.scratchpad_context_publish_state(c.api, c.ctx, C.uint32_t(StateSchemaV1), ptr, C.size_t(len(payload)), &revision)
	runtime.KeepAlive(payload)
	if status != C.CaliberStatusOk {
		return 0, fmt.Errorf("Caliber publish state: %s", caliberStatusString(status))
	}
	return uint64(revision), nil
}

func (c *caliberRuntime) publishResource(payload []byte) (uint64, uint64, error) {
	var resourceID C.uint64_t
	var generation C.uint64_t
	var ptr *C.uint8_t
	if len(payload) > 0 {
		ptr = (*C.uint8_t)(unsafe.Pointer(&payload[0]))
	}
	status := C.scratchpad_context_publish_resource(c.api, c.ctx, ptr, C.size_t(len(payload)), &resourceID, &generation)
	runtime.KeepAlive(payload)
	if status != C.CaliberStatusOk {
		return 0, 0, fmt.Errorf("Caliber publish resource: %s", caliberStatusString(status))
	}
	return uint64(resourceID), uint64(generation), nil
}

func (c *caliberRuntime) readResourceCopy(resourceID, generation uint64) ([]byte, error) {
	var view C.CaliberResourceView
	status := C.scratchpad_context_map_resource(c.api, c.ctx, C.uint64_t(resourceID), C.uint64_t(generation), &view)
	if status != C.CaliberStatusOk {
		return nil, fmt.Errorf("Caliber map resource: %s", caliberStatusString(status))
	}
	defer C.scratchpad_resource_release(c.api, &view)
	if uint64(view.len) > uint64(MaxVisibleBytes+visibleSliceHeaderBytes) {
		return nil, fmt.Errorf("Caliber resource exceeds %d byte limit", MaxVisibleBytes+visibleSliceHeaderBytes)
	}
	if view.len > 0 && view.data == nil {
		return nil, errors.New("Caliber resource returned a null data pointer")
	}
	data := make([]byte, int(view.len))
	if view.len > 0 {
		copy(data, unsafe.Slice((*byte)(unsafe.Pointer(view.data)), int(view.len)))
	}
	return data, nil
}

func (c *caliberRuntime) releaseResourceOwner(resourceID, generation uint64) error {
	status := C.scratchpad_context_release_resource(c.api, c.ctx, C.uint64_t(resourceID), C.uint64_t(generation))
	if status != C.CaliberStatusOk {
		return fmt.Errorf("Caliber release resource: %s", caliberStatusString(status))
	}
	return nil
}

func (c *caliberRuntime) readLatestStateCopy() ([]byte, uint64, uint32, error) {
	var publication C.CaliberStatePublication
	status := C.scratchpad_context_read_latest_state(c.api, c.ctx, &publication)
	if status != C.CaliberStatusOk {
		return nil, 0, 0, fmt.Errorf("Caliber read latest state: %s", caliberStatusString(status))
	}
	defer C.scratchpad_state_publication_release(c.api, &publication)
	if uint64(publication.len) > MaxInputBytes {
		return nil, 0, 0, fmt.Errorf("Caliber state exceeds %d byte limit", MaxInputBytes)
	}
	var data []byte
	if publication.len > 0 {
		data = make([]byte, int(publication.len))
		copy(data, unsafe.Slice((*byte)(unsafe.Pointer(publication.data)), int(publication.len)))
	}
	return data, uint64(publication.revision), uint32(publication.schema), nil
}

func (c *caliberRuntime) acquireLatestStateForTest() (caliberStateLease, error) {
	var publication C.CaliberStatePublication
	status := C.scratchpad_context_read_latest_state(c.api, c.ctx, &publication)
	if status != C.CaliberStatusOk {
		return caliberStateLease{}, fmt.Errorf("Caliber acquire latest state: %s", caliberStatusString(status))
	}
	return caliberStateLease{
		Revision: uint64(publication.revision),
		Schema:   uint32(publication.schema),
		Data:     unsafe.Pointer(publication.data),
		Len:      uintptr(publication.len),
		lease:    publication.lease,
	}, nil
}

func (c *caliberRuntime) releaseStateForTest(lease caliberStateLease) {
	publication := C.CaliberStatePublication{
		revision: C.uint64_t(lease.Revision),
		schema:   C.uint32_t(lease.Schema),
		data:     (*C.uint8_t)(lease.Data),
		len:      C.size_t(lease.Len),
		lease:    lease.lease,
	}
	C.scratchpad_state_publication_release(c.api, &publication)
}

func caliberStatusString(status C.CaliberStatus) string {
	switch status {
	case C.CaliberStatusOk:
		return "ok"
	case C.CaliberStatusInvalidArgument:
		return "invalid_argument"
	case C.CaliberStatusInvalidHandle:
		return "invalid_handle"
	case C.CaliberStatusBufferTooSmall:
		return "buffer_too_small"
	case C.CaliberStatusLimitExceeded:
		return "limit_exceeded"
	case C.CaliberStatusNotFound:
		return "not_found"
	case C.CaliberStatusStale:
		return "stale"
	case C.CaliberStatusUnavailable:
		return "unavailable"
	case C.CaliberStatusQueueFull:
		return "queue_full"
	case C.CaliberStatusUnsupportedVersion:
		return "unsupported_version"
	case C.CaliberStatusInternal:
		return "internal"
	default:
		return fmt.Sprintf("unknown_status_%d", int(status))
	}
}
