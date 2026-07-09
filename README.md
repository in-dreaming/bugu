# Bugu

Bugu is a Zig-first game audio engine prototype focused on real runtime audio paths: mixer voices, event-driven playback, spatial audio, acoustic propagation, effect routing, and validation tooling.

The project is not product-ready yet. It has a working CPU/offline validation path and a real GPU acoustic propagation spike, but public API stability, production backend lifecycle, asset pipeline hardening, CI integration, and documentation still need work before release.

## Current Capabilities

- Fixed-quantum mixer with a bounded real voice pool.
- Sample voices, test-tone voices, stable voice handles, gain ramps, pan, low-pass, pitch, and release.
- SFX/music/master bus labels plus a fixed reverb effect bus with send/return metering.
- Miniaudio device backend and offline WAV/PCM render path.
- WAV/PCM asset import into a TOML manifest plus float32 blob bank.
- Event runtime with random selection, switch selection, RTPC volume curves, stop events, and real sample voice creation.
- Event-driven acoustic runtime via `postAcousticEvent` and `AcousticEventInstance.update`.
- Spatial baseline: attenuation, cone filtering, Doppler pitch, and pan.
- CPU acoustic propagation MVP using scene, voxel, material, portal, room/probe data.
- Acoustic response mapping into mixer snapshots, delayed layers, reverb sends, and runtime voice updates.
- GPU acoustic propagation spike through `in-dreaming/gpu` and Slang compute, currently validated on seven scenes.
- Interactive Zig GPU acoustic ray visualizer using the `in-dreaming/gpu` SDL-backed window path, Slang compute tracing, and realtime `hello.wav` playback driven by CPU dual-solve acoustics.
- Repeatable validation wrapper for CPU/offline tests and explicit GPU validation.

## Repository Layout

```text
src/                         Zig engine modules
examples/                    Runnable demos and validation programs
tools/run_validation.ps1     CPU/offline validation wrapper, optional GPU mode
tools/gpu_acoustic_spike/    in-dreaming/gpu Slang compute spike
tools/acoustic_visualizer/    Interactive GPU acoustic ray visualizer
docs/design/                 Architecture and subsystem designs
docs/tasks/                  Completed task records and evidence links
docs/validation/             Captured validation snapshots
docs/product-readiness-roadmap.md
```

## Requirements

Core Zig path:

- Zig `0.16.0` as used by the current workspace.
- PowerShell on Windows for the validation wrapper.
- Git submodules initialized.

GPU spike and visualizer path:

- `E:\env\activate-dong-build.ps1` or an equivalent CMake/Ninja/MSVC/SDK environment.
- `third_party/in_dreaming_gpu` submodule and nested dependencies initialized.
- A machine capable of running the selected `in-dreaming/gpu` compute/render backend.

## Quick Start

Run unit tests:

```powershell
zig build test
```

Run the full CPU/offline validation gate:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_validation.ps1
```

Run a single demo:

```powershell
zig build event-demo
zig build acoustic-event-demo
zig build effect-bus-demo
```

Render an offline tone WAV:

```powershell
zig build tone -- --offline --seconds 2 --voices 16 --out bugu-tone.wav
```

Run the GPU acoustic spike explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_validation.ps1 -Gpu -DongBuildEnv E:\env\activate-dong-build.ps1
```

The GPU path is explicit by design. If the requested GPU build environment is missing, validation fails instead of silently falling back to CPU.

Build and run the interactive acoustic ray visualizer (Zig host + GPU shaders + realtime `hello.wav`):

```powershell
& E:\env\activate-dong-build.ps1
zig build acoustic-visualizer
```

Build it without launching the interactive window:

```powershell
$vs = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
& "$vs\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -SkipAutomaticLocation

zig build acoustic-visualizer-build
```

Run the automated visualizer smoke test (muted, 3 frames):

```powershell
zig build acoustic-visualizer-smoke
```

On Windows, the visualizer Zig module targets the MSVC ABI and CMake builds `gpu` with `cl`. If an older CMake cache selected MinGW/Strawberry GCC, delete `build/acoustic_visualizer` once and rerun the Zig step.

Visualizer controls: `W/A/S/D` move the listener, arrow keys move the source, mouse drag places the source, `Space` toggles the door (and updates realtime audio), `1/2/3` switch material presets, `R` resets, and `Esc` quits. Pass `--mute` to skip device playback.

## Validation

The main validation entry point is:

```powershell
tools\run_validation.ps1
```

It runs real code paths for:

- unit tests,
- asset import and bank playback,
- event runtime,
- spatial parameters,
- CPU acoustic propagation,
- acoustic mapping/effects/event runtime,
- fixed effect bus routing,
- validation report,
- offline tone WAV render.

Recorded evidence lives in `docs/validation/`, including:

- `t017-validation-wrapper-snapshot.txt`
- `gpu-acoustic-spike-t018-report.txt`
- `acoustic-ray-visualizer-report.txt`
- `acoustic-t015-event-runtime-snapshot.txt`
- `acoustic-t016-effect-bus-snapshot.txt`

## Important Constraints

- Bugu engine code is Zig-first.
- Third-party dependencies must be git submodules.
- SDL usage, if added, must use the `in-dreaming/SDL` fork/branch required by the task docs.
- Visual tools must use `in-dreaming/gpu`; do not introduce a separate temporary window/RHI stack.
- The audio render thread must not allocate, lock, perform file I/O, wait on GPU, or format logs.
- GPU propagation is an acceleration candidate, not the correctness source. CPU propagation remains the reference.
- No task should be considered complete from mock, stub, fixed constant, or silent fallback behavior.

## Product Readiness

See [docs/product-readiness-roadmap.md](docs/product-readiness-roadmap.md).

The next recommended work is:

1. Public API and lifetime hardening.
2. Backend lifecycle and Windows device smoke gate.
3. Versioned asset bank schema and failure tests.
4. CI validation integration.
5. Real-time safety audit and stress tests.
6. User quick start and integration docs.
7. GPU backend object and async readback design.

## Status

As of 2026-07-09, tasks T001-T019 are complete. The current baseline has real CPU/offline validation, a real GPU spike, and an interactive GPU acoustic ray visualizer, but it should still be treated as an engine prototype moving toward product readiness.
