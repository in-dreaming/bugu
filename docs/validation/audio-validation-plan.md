# Bugu Audio Validation, Profile, and Debug Plan

状态：Draft v0.1  
日期：2026-07-08  
任务：T012 validation/profile/debug

## 1. Scope

This plan is the repeatable gate for Bugu audio implementation tasks. It covers backend/device behavior, mixer pressure, asset/event/spatial flows, CPU acoustic propagation, AcousticResponse-to-mixer mapping, profile counters, and debug output.

Visualization is not implemented in T012. Any future visual debug tool must use `https://github.com/in-dreaming/gpu` as a git submodule and be wired through `build.zig`; text, JSON, and CSV reports are allowed without that dependency.

## 2. Automated Commands

| Command | Environment | Pass criteria |
|---|---|---|
| `zig build test` | CI or local, no device required | All unit tests pass; no mock-only success checks. |
| `zig build asset-demo` | CI or local, no device required | WAV import reads a real generated WAV, builds metadata/blob, renders nonzero samples. |
| `zig build event-demo` | CI or local, no device required | `postEvent` path creates sample voices; random/switch/RTPC behavior appears in output. |
| `zig build spatial-demo` | Local or CI if file writes allowed | Transform-derived attenuation/cone/Doppler prints numeric params and offline render telemetry. |
| `zig build acoustic-demo` | CI or local, no device required | Six acoustic scenes output distinct `AcousticResponse` values matching T010 direction checks. |
| `zig build acoustic-mapping-demo` | CI or local, no device required | Responses map through `AcousticMixerSnapshot` into mixer render telemetry with `clipping=0`. |
| `zig build acoustic-effects-demo` | CI or local, no device required | Acoustic snapshots drive real voice handle updates, delayed layers, reverb send, and offline render telemetry with `clipping=0`. |
| `zig build acoustic-event-demo` | CI or local, no device required | `postAcousticEvent` resolves a real sample event, starts snapshot layers, updates handles from a later snapshot, and renders nonzero telemetry with `clipping=0`. |
| `zig build effect-bus-demo` | CI or local, no device required | Voices route sends through the fixed reverb effect bus; send/return peaks are nonzero and `clipping=0`. |
| `zig build validation-report` | CI or local, no device required | Produces a text report from real counters, render timing samples, and acoustic scene outputs. |
| `cmake -S tools/gpu_acoustic_spike -B build/gpu_acoustic_spike -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build/gpu_acoustic_spike --target bugu_gpu_acoustic_spike && build/gpu_acoustic_spike/bugu_gpu_acoustic_spike.exe` | Local with `E:\env\activate-dong-build.ps1` and GPU/RHI available | Dispatches Bugu acoustic compute shader through `in-dreaming/gpu`, reads back response values, and validates GPU vs CPU tolerances. |
| `zig build tone -- --device --seconds 2` | Local real device only | Miniaudio backend opens/starts/stops a real device; no callback failure or clipping evidence. |
| `zig build tone -- --offline --seconds 2 --voices 64 --out <path>` | CI or local | Offline backend writes real WAV PCM; telemetry shows rendered frames, peak/RMS, no clipping. |

## 3. Test Matrix

| Area | Cases | Evidence source | Failure criteria |
|---|---|---|---|
| Backend | offline render, fixed quantum adapter, local device start/stop | T004 task evidence, `tone`, `validation-report` | Empty callback success, missing rendered frames, device run marked DONE without real device or allowed offline fallback. |
| Mixer | 64 real voices, stealing beyond limit, ramps, delayed reflection starts, fixed effect bus routing | `zig build test`, `validation-report`, `effect-bus-demo` | Peak/RMS zero for active voices, clipping in nominal demos, active/stolen counts inconsistent, effect send/return meters stay zero. |
| Stream/underrun | fixed quantum partial callback buffering | offline backend tests | Underrun/dropout counters rise in deterministic offline render. |
| Asset | WAV PCM16/float32 import, manifest/blob, preload bank | `asset-demo` | No real file read, unsupported codec claimed, metadata/blob absent. |
| Event | event resolve to sample voice, random/switch/RTPC, event-owned acoustic voice handles | `event-demo`, `acoustic-event-demo` | Direct voice internals used instead of event runtime path. |
| Spatial | distance attenuation, cone low-pass, Doppler pitch, pan | `spatial-demo`, unit tests | Values not derived from transforms or outside clamped ranges. |
| Acoustic propagation | open_air, thick_wall, wall_hole, door, cave, open_field | `acoustic-demo`, `acoustic-t010-response-snapshot.json` | Scenario-name hardcoding, no voxel/material/portal data, expected metric direction fails. |
| Acoustic mapping | direct/transmission/portal/reflection/reverb snapshot layers | `acoustic-mapping-demo`, `acoustic-t011-mapping-snapshot.json` | Mapping bypasses `AcousticMixerSnapshot`, portal pan ignores portal direction, render telemetry absent. |
| Profile | render max/p99/p999, dropout/underrun/clipping counters | `validation-report`, telemetry snapshots | Handwritten profile numbers, missing sample count, p99/p999 not derived from measured runs. |

## 4. Acoustic Scene Pass/Fail Rules

| Scene | Required direction |
|---|---|
| open_air | `direct_gain` high, `transmission_gain=0`, `openness` high, weak reverb. |
| thick_wall | direct path reduced, nonzero transmission, stronger low-pass, reflection present. |
| wall_hole | portal gain nonzero and apparent pan follows the opening, not source-through-wall. |
| door | portal gain changes with open fraction; smoothing can be enabled for 20-100 ms transition. |
| cave | stronger reflection/reverb and lower openness than open_field. |
| open_field | high openness, low late reverb, sparse reflection. |

## 5. Profile Rules

Profile data must come from real counters or measured render calls:

- `TelemetryCounters` for frames, quantums, callback count, dropout/underrun, peak/RMS, active/virtual/stolen voices, clipping, and mixer time.
- `validation-report` for measured render call duration distribution.
- No profile number may be typed into docs as evidence unless the command and input that produced it are recorded.

Audio render thread safety remains unchanged: no allocation, locks, file I/O, log formatting, GPU waits, lazy loads, or complex mutable shared structures in the render callback.

## 6. Debug Output Plan

Text/JSON debug, implemented now:

- Active/virtual/stolen voices from telemetry.
- Peak/RMS/clipping and render duration summary from `validation-report`.
- Acoustic voxel/material/portal effects through T010 response snapshots.
- AcousticResponse-to-mixer layer output through T011 mapping snapshots.

Future in-dreaming/gpu visualization:

- Submodule path: `third_party/in_dreaming_gpu`.
- Build integration: add an optional `debug-visualizer` executable in `build.zig` that imports Bugu audio and the RHI wrapper.
- Minimum views: bus meters, voice states, listener/emitter/cone, acoustic voxel occupancy, portal/opening overlays, ray families for direct/penetration/reflection/escape, response curves, and confidence timeline.
- Until this is implemented, no task may claim visual debug screenshots as evidence.

## 7. Mock/Fallback Gate

A task cannot be marked DONE if it only:

- returns success without generating samples, metadata, event-chain state, or `AcousticResponse`;
- hardcodes responses by scenario/test name;
- uses logs, random values, sleeps, or fixed constants as profile evidence;
- claims unsupported codecs, streaming, GPU, or visualization;
- uses a non-submodule dependency for required implementation work.

Allowed CI fallbacks must still execute real code: offline render, CPU acoustic backend, JSON/CSV debug, or PCM/WAV subset import.
