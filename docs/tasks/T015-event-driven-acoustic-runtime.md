# T015 Event-driven acoustic runtime integration

Status: DONE  
Type: Implementation  
Priority: P2  
Dependencies: T007,T010,T011,T014  
Expected artifacts: `EventRuntime.postAcousticEvent`, `AcousticEventInstance.update`, `examples/acoustic_event_demo.zig`, [event acoustic snapshot](../validation/acoustic-t015-event-runtime-snapshot.txt)

## 1. Background

T014 proved that acoustic snapshots can update mixer voice handles, but the demo still started acoustic layers directly. T015 connects posted events to acoustic snapshots so game-side code can post an event once, keep the returned acoustic instance, and update it as propagation results change.

## 2. Scope

- `postEvent` returns the real `VoiceHandle` for normal sample voices.
- `postAcousticEvent` resolves event variants/RTPC/switches, starts real sample voices from `AcousticMixerSnapshot` layers, and returns an `AcousticEventInstance`.
- `AcousticEventInstance.update` applies later snapshots through `Engine.updateVoice`; newly valid layers create new real sample voices.
- Demo uses generated WAV import, event runtime, CPU acoustic solver, snapshot mapping, offline render, and telemetry.

## 3. Acceptance Criteria

- No direct mixer voice hot-data mutation outside public `Engine.startSampleVoiceWithHandle` and `Engine.updateVoice`.
- Acoustic event parameters come from `solveAcoustic` and `mapAcousticResponseToSnapshot`, not scenario-name constants.
- Offline render produces nonzero peak/RMS and `clipping=0`.
- Existing validation stays green.

## 4. Evidence

- `zig build test` passed.
- `zig build acoustic-event-demo` passed.
- `zig build acoustic-effects-demo` passed.
- `zig build acoustic-mapping-demo` passed.
- `zig build validation-report` passed.
- Demo output saved to [acoustic-t015-event-runtime-snapshot.txt](../validation/acoustic-t015-event-runtime-snapshot.txt):
  - `closed_direct=0.15625`
  - `closed_portal=0.00201`
  - `open_portal=0.07408`
  - `post_layers=4`
  - `direct_handle=true`
  - `portal_handle=true`
  - `frames=20992`
  - `peak=0.036913`
  - `rms=0.021240`
  - `clipping=0`

## 5. Activity Log

- 2026-07-08: Started T015 after T014. Gap: acoustic updates existed only in direct demo code, not in posted event runtime.
- 2026-07-08: Added event-owned acoustic instances. `postEvent` now returns the real sample `VoiceHandle`; `postAcousticEvent` resolves the event and starts sample layers from `AcousticMixerSnapshot`; `AcousticEventInstance.update` applies later snapshots through `Engine.updateVoice`.
- 2026-07-08: Added `examples/acoustic_event_demo.zig` and `zig build acoustic-event-demo`; validated generated WAV import -> bank -> event runtime -> CPU acoustic solve -> snapshot mapping -> sample voice handles -> offline render telemetry.
