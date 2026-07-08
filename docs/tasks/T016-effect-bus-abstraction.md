# T016 Effect bus abstraction

Status: DONE  
Type: Implementation  
Priority: P2  
Dependencies: T005,T014,T015  
Expected artifacts: fixed `EffectBuses` mixer abstraction, public effect bus controls/snapshot, `examples/effect_bus_demo.zig`, [effect bus snapshot](../validation/acoustic-t016-effect-bus-snapshot.txt)

## 1. Background

T014 added a real reverb send/return, but it lived as ad hoc fields directly on `Mixer`. T016 turns that path into a fixed effect bus abstraction so later acoustic and authoring work can target bus sends/returns instead of mixer-internal delay-line state.

## 2. Scope

- Add fixed `EffectBuses` and `ReverbEffectBus` state inside the mixer.
- Keep `reverb_send` as the compatibility voice send for T014/T015.
- Route dry bus sums and reverb return explicitly through master.
- Add public `setEffectBus` and `effectBusSnapshot` controls on `Engine`.
- Add a demo that renders real PCM through the effect bus and reports send/return meters.

## 3. Acceptance Criteria

- No allocation, locks, file I/O, logging, or GPU waits on the render path.
- Reverb delay state is encapsulated in the effect bus, not loose mixer fields.
- Effect bus controls change the real render path and expose measured send/return peaks.
- Existing acoustic mapping/effects/event demos remain green.

## 4. Evidence

- `zig build test` passed.
- `zig build effect-bus-demo` passed.
- `zig build acoustic-effects-demo` passed.
- `zig build acoustic-event-demo` passed.
- `zig build acoustic-mapping-demo` passed.
- `zig build validation-report` passed.
- Demo output saved to [acoustic-t016-effect-bus-snapshot.txt](../validation/acoustic-t016-effect-bus-snapshot.txt):
  - `frames=12032`
  - `peak=0.202914`
  - `rms=0.091415`
  - `clipping=0`
  - `reverb_send_peak=0.158288`
  - `reverb_return_peak=0.066481`
  - `return_gain=0.42`
  - `feedback=0.38`

## 5. Activity Log

- 2026-07-08: Started after T015; scope limited to fixed reverb effect bus abstraction and validation, not a dynamic graph.
- 2026-07-08: Replaced loose mixer reverb fields with fixed `EffectBuses`/`ReverbEffectBus`, explicit send/return metering, and public `Engine.setEffectBus`/`effectBusSnapshot`.
- 2026-07-08: Added `examples/effect_bus_demo.zig` and validation evidence; existing acoustic demos continue to route `late_reverb_send` through the real effect bus.
