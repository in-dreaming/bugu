# Bugu Zig API and Module Boundary Design

状态：Draft v0.1  
日期：2026-07-08  
任务：T003 Zig API、可选 C ABI 与模块边界设计  
依赖：T001 backend/decoder/codec research、T002 realtime runtime contract

## 1. Goals

Bugu exposes a Zig-first API. C ABI support is optional and wraps the Zig runtime with opaque handles; it does not define the engine's internal design.

API principles:

- Public runtime APIs never expose `ma_device`, `SDL_AudioStream`, `Sound_Sample`, `drwav`, `gpu` RHI objects, platform handles, or third-party allocator types.
- Ownership, allocator responsibility, thread requirements, and error sets are visible at the API boundary.
- Audio render thread entry points are tiny and separate from game/runtime/tooling APIs.
- Debug and tooling APIs cannot be called from the render thread unless explicitly marked render-safe.
- All handles are stable ids or opaque objects. Public handles do not reveal internal layout.

## 2. Module Graph

```
app/game/editor
    |
    v
bugu_audio_core -------------------------------+
    |                                          |
    +--> bugu_audio_events                     |
    +--> bugu_audio_assets                     |
    +--> bugu_audio_spatial                   |
    +--> bugu_audio_device                    |
    +--> bugu_audio_mixer                     |
    +--> bugu_acoustics                       |
    |                                          |
    +--> bugu_audio_tooling ------------------+
    +--> bugu_audio_visual_debug ------------> third_party_adapters/gpu

bugu_audio_device ----------------------------> third_party_adapters/miniaudio
bugu_audio_device ----------------------------> third_party_adapters/sdl_audio
bugu_audio_assets ----------------------------> third_party_adapters/dr_wav
bugu_audio_assets ----------------------------> third_party_adapters/optional_decoders
bugu_audio_visual_debug ----------------------> third_party_adapters/gpu
```

Dependency rules:

- `bugu_audio_core` owns the engine facade, public handles, config, allocator roots, queues, thread startup, shutdown, error domains, and telemetry query API.
- `bugu_audio_device` owns device enumeration/open/close/reopen and backend callback adapters. It depends on `bugu_audio_mixer` only through a narrow render callback interface.
- `bugu_audio_mixer` owns fixed quantum rendering, voice pool hot data, bus graph render order, DSP primitives used by the render path, and render telemetry counters.
- `bugu_audio_assets` owns source import, decode workers, bank metadata/blob representation, stream chunk planning, and bank lifetime pins.
- `bugu_audio_events` owns event resolution, state/switch/RTPC evaluation, random/sequence containers, and conversion to voice requests.
- `bugu_audio_spatial` owns listener/emitter transforms, attenuation profiles, cone/directivity, Doppler, and baseline 3D parameters.
- `bugu_acoustics` owns acoustic scene data, propagation backend interfaces, AcousticResponseBuffer, and conversion to AcousticSnapshot inputs.
- `bugu_audio_tooling` owns import CLI/editor-only validation, manifest inspection, offline profile collation, and authoring metadata.
- `bugu_audio_visual_debug` owns visual debug data extraction and in-dreaming/gpu integration. It is not linked into the render hot path.
- `third_party_adapters` is the only place that includes or translates third-party C headers. Adapter APIs return Bugu-owned structs and error sets.

## 3. Proposed Source Tree

```
build.zig
src/
  bugu_audio.zig
  core/
    engine.zig
    handles.zig
    config.zig
    errors.zig
    telemetry.zig
    queues.zig
    snapshot.zig
  device/
    device.zig
    backend.zig
    offline.zig
    miniaudio_backend.zig
    sdl_backend.zig
  mixer/
    mixer.zig
    voice.zig
    bus.zig
    dsp.zig
    render_context.zig
  assets/
    bank.zig
    decode.zig
    import_wav.zig
    stream.zig
  events/
    event.zig
    parameter.zig
    runtime.zig
  spatial/
    transform.zig
    attenuation.zig
    listener.zig
    emitter.zig
  acoustics/
    scene.zig
    response.zig
    snapshot.zig
    propagation.zig
  tooling/
    import_cli.zig
    validate_bank.zig
  visual_debug/
    debug_export.zig
    gpu_view.zig
  c_api/
    bugu_audio_c.zig
third_party_adapters/
  miniaudio/
    miniaudio_shim.c
    miniaudio_adapter.zig
  dr_libs/
    dr_wav_shim.c
    dr_wav_adapter.zig
  sdl/
    sdl_audio_adapter.zig
  gpu/
    gpu_adapter.zig
```

`src/bugu_audio.zig` re-exports the stable Zig API. Internal modules may use narrower package imports in tests, but application code should import `bugu_audio`.

## 4. build.zig Shape

Minimum package targets:

| Zig module | Source | Depends on | Independently testable |
|---|---|---|---|
| `bugu_audio` | `src/bugu_audio.zig` | core facade modules | Yes |
| `bugu_audio_core` | `src/core/engine.zig` | queues/snapshot/errors/telemetry | Yes |
| `bugu_audio_device` | `src/device/device.zig` | core handles/errors, mixer render interface | Yes with offline backend |
| `bugu_audio_mixer` | `src/mixer/mixer.zig` | core snapshot/telemetry | Yes |
| `bugu_audio_assets` | `src/assets/bank.zig` | core handles/errors, decoder adapters | Yes |
| `bugu_audio_events` | `src/events/runtime.zig` | core, assets, mixer voice request ABI | Yes |
| `bugu_audio_spatial` | `src/spatial/attenuation.zig` | core math, events parameters | Yes |
| `bugu_acoustics` | `src/acoustics/propagation.zig` | core snapshot, spatial transforms | Yes |
| `bugu_audio_tooling` | `src/tooling/import_cli.zig` | assets, optional decoder adapters | Yes |
| `bugu_audio_visual_debug` | `src/visual_debug/debug_export.zig` | tooling/acoustics/spatial, gpu adapter | Yes if gpu submodule exists |
| `bugu_audio_c` | `src/c_api/bugu_audio_c.zig` | `bugu_audio` | ABI smoke tests |

Third-party integration:

- P0 adds `third_party/miniaudio` and `third_party/dr_libs` only when T004/T006 implement them.
- Each C library is built by a Bugu-owned shim translation unit under `third_party_adapters/*`.
- `build.zig` exposes feature flags such as `enable_miniaudio`, `enable_sdl`, `enable_wav_import`, `enable_visual_debug`.
- No build step may download dependencies. Missing submodules produce a clear build error for the feature that requires them.
- The public `bugu_audio` module compiles without SDL/gpu visual debug features.

## 5. Public Zig Types

### 5.1 Handles

```zig
pub const EngineHandle = extern struct { index: u32, generation: u32 };
pub const DeviceHandle = extern struct { index: u32, generation: u32 };
pub const BankHandle = extern struct { index: u32, generation: u32 };
pub const EventId = extern struct { value: u64 };
pub const VoiceHandle = extern struct { index: u32, generation: u32 };
pub const ListenerHandle = extern struct { index: u32, generation: u32 };
pub const EmitterHandle = extern struct { index: u32, generation: u32 };
pub const BusId = extern struct { value: u32 };
pub const ParameterId = extern struct { value: u32 };
pub const StateGroupId = extern struct { value: u32 };
pub const SwitchGroupId = extern struct { value: u32 };
```

Handle lifecycle:

- `EngineHandle` is valid from `createEngine` until `destroyEngine`.
- `DeviceHandle` is valid from successful open/start until close/device destruction. Device lost does not invalidate the handle unless reopen fails permanently.
- `BankHandle` is valid after load completion. Unload marks it unavailable for new events; old voices may keep internal refs until release.
- `VoiceHandle` may become stale after stop, steal, natural end, or bank unload fade. Generation prevents stale-handle reuse.
- `ListenerHandle` and `EmitterHandle` remain valid until explicit destroy/detach or engine destroy.
- `BusId`, `EventId`, and parameter/state/switch ids are data ids from banks or authoring registries; they are not pointers.

### 5.2 Config And Errors

```zig
pub const EngineConfig = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32 = 48_000,
    quantum_frames: u32 = 256,
    command_queue_capacity: u32 = 4096,
    worker_completion_capacity: u32 = 1024,
    max_real_voices: u32 = 64,
    max_virtual_voices: u32 = 512,
    backend: BackendPreference = .miniaudio,
    enable_offline_backend: bool = true,
};

pub const BuguError = error{
    InvalidHandle,
    InvalidState,
    OutOfMemory,
    QueueFull,
    DeviceUnavailable,
    DeviceLost,
    UnsupportedFormat,
    MissingSubmodule,
    BankLoadFailed,
    BankInUse,
    EventNotFound,
    ParameterNotFound,
    BackendFeatureUnavailable,
    RealtimeContractViolation,
};
```

Allocator ownership:

- The caller provides `EngineConfig.allocator`.
- Engine creation allocates runtime pools, queues, snapshots, device adapter buffers, and non-render metadata.
- Render-thread buffers are allocated before device start and freed after callback stop.
- Asset importer/tooling may accept a separate scratch allocator.
- Render-thread APIs never accept allocators.

## 6. Runtime API Draft

Thread labels:

- `GT`: Game thread or any non-render caller that owns gameplay commands.
- `ACT`: Audio Control Thread.
- `ART`: Audio Render Thread/device callback.
- `WT`: Worker/tool thread.
- `Tool`: editor/import/debug tooling, never render thread.

### 6.1 Engine

| API | Thread | Ownership | Notes |
|---|---|---|---|
| `createEngine(config: EngineConfig) BuguError!*Engine` | GT before start | caller owns returned engine until destroy | Allocates runtime pools; does not start device callback |
| `destroyEngine(engine: *Engine) void` | GT after stop | releases all engine resources | Requires stopped engine; joins non-render threads outside ART |
| `start(engine: *Engine, desc: StartDesc) BuguError!void` | GT | engine starts ACT and backend | Publishes initial empty RenderSnapshot |
| `stop(engine: *Engine, mode: StopMode) BuguError!void` | GT | engine transitions to draining/stopped | Stops backend before freeing render data |
| `update(engine: *Engine, dt: f32) BuguError!void` | GT | pumps non-threaded mode or tool mode | Optional when ACT is a real thread |
| `requestShutdown(engine: *Engine) BuguError!void` | GT | posts shutdown command | Non-blocking command path |

### 6.2 Device

| API | Thread | Ownership | Notes |
|---|---|---|---|
| `enumerateDevices(engine: *Engine, allocator: Allocator) BuguError![]DeviceInfo` | GT/Tool | caller frees returned slice | Not render-safe |
| `openDevice(engine: *Engine, desc: DeviceOpenDesc) BuguError!DeviceHandle` | GT | engine owns device adapter | Fails if backend feature/submodule missing |
| `closeDevice(engine: *Engine, handle: DeviceHandle) BuguError!void` | GT/ACT | engine stops callback first | No ART resource free while callback active |
| `reopenDevice(engine: *Engine, handle: DeviceHandle, desc: DeviceOpenDesc) BuguError!void` | GT/ACT | preserves runtime state | Used for device lost or format change |
| `queryDeviceStatus(engine: *Engine, handle: DeviceHandle) BuguError!DeviceStatus` | GT/Tool | value return | Includes lost/reopening/offline state |

Backend callback boundary:

```zig
pub const BackendRenderContext = opaque {};

pub fn renderDeviceCallback(
    ctx: *BackendRenderContext,
    output: []f32,
    frame_count: u32,
) callconv(.C) void;
```

Only `bugu_audio_device` calls this from a backend callback. It may only touch `BackendRenderContext`, `SnapshotSwap.acquireForRender`, mixer render, fixed FIFO, and atomic telemetry.

### 6.3 Bank And Assets

| API | Thread | Ownership | Notes |
|---|---|---|---|
| `loadBank(engine: *Engine, path: []const u8, opts: BankLoadOptions) BuguError!BankHandle` | GT/Tool | engine owns loaded bank | May enqueue worker I/O; not ART |
| `unloadBank(engine: *Engine, bank: BankHandle, mode: UnloadMode) BuguError!void` | GT | old voices may pin old blob | New events rejected after unload begins |
| `hotReloadBank(engine: *Engine, bank: BankHandle, path: []const u8) BuguError!void` | GT/Tool | engine creates new immutable blob | Old blob released by generation/refcount |
| `queryBankInfo(engine: *Engine, bank: BankHandle) BuguError!BankInfo` | GT/Tool | value return | No source path strings on ART |
| `importWav(tool: *ImportContext, path: []const u8, opts: ImportOptions) BuguError!ImportResult` | Tool | caller/tool owns output | T006/T012 tooling path |

Decoder APIs belong to assets/tooling, not device. Runtime decode workers report through `WorkerCompletionQueue`.

### 6.4 Events And Parameters

| API | Thread | Ownership | Notes |
|---|---|---|---|
| `postEvent(engine: *Engine, event: EventId, target: EventTarget, opts: PostEventOptions) BuguError!VoiceHandle` | GT | enqueues AudioCommand | Returns logical handle; may virtualize |
| `stopVoice(engine: *Engine, voice: VoiceHandle, fade_ms: u32) BuguError!void` | GT | enqueues stop | Stale handles return `InvalidHandle` or no-op by policy |
| `stopEvent(engine: *Engine, event: EventId, target: EventTarget, fade_ms: u32) BuguError!void` | GT | command path | Resolved by ACT |
| `setParameter(engine: *Engine, id: ParameterId, value: f32, scope: ParameterScope) BuguError!void` | GT | command path | RTPC smoothing done by ACT/mixer |
| `setState(engine: *Engine, group: StateGroupId, state: u32) BuguError!void` | GT | command path | Bank-authored ids |
| `setSwitch(engine: *Engine, target: EventTarget, group: SwitchGroupId, value: u32) BuguError!void` | GT | command path | Target-local switch |

All event APIs enqueue commands. They never directly mutate voice hot data.

### 6.5 Listener And Emitter

| API | Thread | Ownership | Notes |
|---|---|---|---|
| `createListener(engine: *Engine, desc: ListenerDesc) BuguError!ListenerHandle` | GT | engine owns listener state | ACT snapshot copy |
| `updateListener(engine: *Engine, listener: ListenerHandle, transform: Transform3D, velocity: Vec3) BuguError!void` | GT | command path or double-buffered GT state | Used by spatial/acoustics |
| `destroyListener(engine: *Engine, listener: ListenerHandle) BuguError!void` | GT | delayed release | Must not invalidate active snapshot |
| `attachEmitter(engine: *Engine, desc: EmitterDesc) BuguError!EmitterHandle` | GT | engine owns emitter state | May bind game object id |
| `updateEmitter(engine: *Engine, emitter: EmitterHandle, transform: Transform3D, velocity: Vec3) BuguError!void` | GT | command path | T008 uses this for attenuation/Doppler |
| `detachEmitter(engine: *Engine, emitter: EmitterHandle) BuguError!void` | GT | delayed release | Active voices may keep last transform/fade |

### 6.6 Bus And Telemetry

| API | Thread | Ownership | Notes |
|---|---|---|---|
| `setBusVolume(engine: *Engine, bus: BusId, volume: f32, ramp_ms: u32) BuguError!void` | GT | command path | ACT/mixer convert to automation |
| `setBusMute(engine: *Engine, bus: BusId, mute: bool) BuguError!void` | GT | command path | Snapshot update |
| `queryBusMeter(engine: *Engine, bus: BusId) BuguError!BusMeter` | GT/Tool | value return from telemetry copy | Render writes atomics, Control aggregates |
| `queryTelemetry(engine: *Engine) TelemetrySnapshot` | GT/Tool | value return | p99/p999 calculated outside ART |
| `resetTelemetry(engine: *Engine) void` | GT/Tool | resets non-render aggregate | ART counters reset only via safe atomic exchange |

### 6.7 Errors

| API | Thread | Ownership | Notes |
|---|---|---|---|
| `getLastErrorCode(engine: *Engine) ErrorCode` | GT/Tool | value return | For C ABI and tools |
| `formatError(code: ErrorCode, buffer: []u8) []const u8` | GT/Tool | caller buffer | Never ART |
| `registerErrorSink(engine: *Engine, sink: ErrorSink) BuguError!void` | GT/Tool | engine stores callback | Sink is invoked outside ART |

Audio Render Thread records numeric counters or codes only. It does not format strings or call user error sinks.

## 7. Internal Render API

The render API is intentionally not the public game API:

```zig
pub const RenderInput = struct {
    snapshot: *const RenderSnapshot,
    output: []f32,
    frames: u32,
};

pub fn renderQuantum(ctx: *RenderContext, input: RenderInput) void;
```

Rules:

- `RenderContext` is allocated and prepared before device start.
- `renderQuantum` performs bounded loops over snapshot voice/bus arrays.
- It may write atomic telemetry.
- It does not allocate, lock, open files, call decoder APIs, wait for workers/GPU, or call debug/tooling APIs.

## 8. Optional C ABI Boundary

C ABI exists for bindings and tools that cannot import Zig directly. It wraps the Zig API with opaque handles:

```c
#define BUGU_AUDIO_ABI_VERSION 1

typedef struct bugu_engine bugu_engine;
typedef struct { uint32_t size; uint32_t version; } bugu_struct_header;

typedef struct {
    uint32_t size;
    uint32_t version;
    uint32_t sample_rate;
    uint32_t quantum_frames;
    uint32_t max_real_voices;
    uint32_t max_virtual_voices;
    uint32_t command_queue_capacity;
    uint32_t flags;
} bugu_engine_config;

typedef struct { uint32_t index; uint32_t generation; } bugu_voice_handle;
typedef struct { uint32_t index; uint32_t generation; } bugu_bank_handle;
typedef struct { uint64_t value; } bugu_event_id;

int32_t bugu_engine_create(const bugu_engine_config* config, bugu_engine** out_engine);
void bugu_engine_destroy(bugu_engine* engine);
int32_t bugu_engine_start(bugu_engine* engine);
int32_t bugu_engine_stop(bugu_engine* engine, uint32_t mode);
int32_t bugu_bank_load(bugu_engine* engine, const char* path, bugu_bank_handle* out_bank);
int32_t bugu_post_event(bugu_engine* engine, bugu_event_id event, bugu_voice_handle* out_voice);
int32_t bugu_set_parameter(bugu_engine* engine, uint32_t parameter_id, float value);
int32_t bugu_query_telemetry(bugu_engine* engine, void* out_struct, uint32_t out_size);
```

C ABI rules:

- Every input/output struct starts with `size` and `version` when it can evolve.
- All returned objects are opaque or stable value handles.
- ABI functions return numeric error codes; string formatting is a non-render helper.
- C ABI functions are not render-thread APIs unless explicitly named under an internal backend namespace.
- C ABI does not expose third-party headers.

## 9. Third-Party Adapter Boundaries

### 9.1 miniaudio

Adapter owns:

- `ma_device` lifetime.
- device callback conversion to `BackendRenderContext`.
- backend-specific format negotiation and device lost mapping to Bugu `DeviceStatus`.

Adapter exports only Bugu structs:

```zig
pub fn openMiniaudioDevice(desc: DeviceOpenDesc, ctx: *BackendRenderContext) BuguError!DeviceAdapter;
```

No public API or core module stores `ma_*` types.

### 9.2 SDL Audio

P1 adapter owns SDL initialization subset, device ids, AudioStream/callback glue, and fork commit reporting. If the in-dreaming fork is not available, SDL-specific targets fail clearly; upstream SDL is not substituted.

### 9.3 dr_libs and optional decoders

Decoder adapters expose:

```zig
pub const DecodedInfo = struct {
    sample_rate: u32,
    channels: u16,
    format: SampleFormat,
    frame_count: u64,
    loop: ?LoopPoints,
};

pub fn inspectWav(reader: Reader) BuguError!DecodedInfo;
pub fn decodeWavChunk(reader: Reader, dst: []f32, request: DecodeRequest) BuguError!DecodeResult;
```

Adapters do not do file I/O in the render path. T006 may use VFS callbacks or tooling file APIs on worker/tool threads.

### 9.4 in-dreaming/gpu

Only `bugu_audio_visual_debug` and future GPU acoustic spike code may depend on gpu adapter types. `bugu_acoustics` core exposes CPU/GPU-agnostic propagation interfaces and receives `AcousticResponseBuffer`, never RHI objects.

## 10. Thread Requirements Summary

| API group | GT | ACT | ART | WT | Tool |
|---|---:|---:|---:|---:|---:|
| Engine create/destroy/start/stop | Yes | Internal | No | No | Yes for offline |
| Device enumerate/open/close/reopen | Yes | Internal | callback only | No | Yes |
| Bank load/unload/hot reload | Yes | Internal | No | load/decode completion | Yes |
| Event/parameter/state/switch | Yes | consumes | No | No | Yes for preview |
| Listener/emitter update | Yes | consumes | No | No | Yes for preview |
| Mixer render quantum | No | No | Yes | No | offline only via offline backend |
| Telemetry query/format | Yes | aggregate | atomic write only | No | Yes |
| Visual debug | No | snapshot export only | No | No | Yes |

## 11. Requirements For Later Tasks

### T004 P0 backend

- Implement `bugu_audio_device` with miniaudio low-level device adapter and offline backend.
- Use `BackendRenderContext` and fixed quantum FIFO; do not expose miniaudio in public API.
- Evidence must prove callback path calls Bugu render adapter, not a backend-owned sine shortcut.

### T005 Mixer/Voice/Bus

- Implement `bugu_audio_mixer` hot data and `RenderSnapshot` consumption.
- Voice/bus handles must follow generation semantics.
- Bus meters update telemetry without formatting logs on ART.

### T006 Assets

- Implement `bugu_audio_assets` and dr_wav adapter.
- Bank metadata/blobs are immutable once published to snapshots.
- Runtime decode completion goes through WorkerCompletionQueue.

### T007 Events

- Implement `bugu_audio_events` so `postEvent` enqueues AudioCommand and ACT creates voice requests.
- Do not call voice internals directly from public event API.

### T008 Spatial

- Implement listener/emitter handles, transform updates, attenuation profile lookup, cone and Doppler parameter calculation.
- Spatial output becomes per-voice parameters in the Control -> Render snapshot path.

### T009-T011 Acoustics

- Keep `bugu_acoustics` output as AcousticResponse/AcousticSnapshot.
- Do not write mixer parameters directly from propagation backends.

### T012/T013 Tooling And Debug

- Use `bugu_audio_tooling` for evidence schema, profile collation, and import validation.
- Use `bugu_audio_visual_debug` only with in-dreaming/gpu for visualization; text/JSON fallback is acceptable only where the task allows non-visual output.

## 12. Acceptance Examples

- A game can create an engine, start miniaudio/offline backend, load a bank, post an event, update a listener/emitter, and query telemetry without seeing third-party types.
- A backend callback can call only `renderDeviceCallback` with a `BackendRenderContext`.
- A tool can import WAV using `bugu_audio_tooling` without linking the runtime device backend.
- A C binding can create/destroy engine and post events using opaque handles and `size/version` structs.
- A debug visualization module can be disabled at build time without changing mixer/device/assets APIs.
