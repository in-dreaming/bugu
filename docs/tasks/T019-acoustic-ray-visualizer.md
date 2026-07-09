# T019 Acoustic Ray Visualizer

## Goal

Add an interactive GPU-backed acoustic propagation visualizer for Bugu. The tool is a Zig demo and validation surface for acoustic ray behavior. It also drives realtime `hello.wav` playback through `bugu_audio` (dual-solve: GPU for visualization, CPU `solveAcoustic` for mixer parameters). It is not a production GPU acoustic backend.

## Build

```powershell
& E:\env\activate-dong-build.ps1
# or Launch-VsDevShell so MSVC `cl` is on PATH
zig build acoustic-visualizer-build
```

Run interactively (loops `examples/data/hello.wav` by default):

```powershell
zig build acoustic-visualizer
```

For an automated smoke run (muted, 3 frames):

```powershell
zig build acoustic-visualizer-smoke
```

CLI flags:

- `--once`: run 3 frames then exit (smoke)
- `--mute`: skip opening the audio device
- `--report <path>`: write the runtime report

The Zig build compiles `tools/acoustic_visualizer/*.zig` into a static library (MSVC ABI on Windows), then CMake links it with the `gpu` target and stages shaders/DLLs/`hello.wav` under `build/acoustic_visualizer`. Run the executable from that directory. If a stale CMake cache selected MinGW/Strawberry GCC, delete `build/acoustic_visualizer` and rerun.

## Controls

- `W/A/S/D`: move listener
- Arrow keys: move source
- Mouse drag: place source
- `Space`: toggle door open/closed (updates GPU rays and realtime audio)
- `R`: reset scene
- `1/2/3`: concrete, wood, rock material presets
- `Esc` or window close: quit

## Implementation Notes

Application logic is Zig (`main.zig`, `scene.zig`, `render_cpu.zig`, `gpu_app.zig`, `audio_bridge.zig`) with a thin `@cImport` adapter in `third_party_adapters/gpu`. GPU compute ray tracing uses `acoustic_trace.slang`; debug geometry is built on CPU and drawn with `acoustic_draw.slang`.

Realtime audio:

1. Import/load `hello.wav` into a bank
2. `postAcousticEvent` with `loop=true`
3. Each frame: map `AppState` → `TestScenes.doorOpening` + portal → `solveAcoustic` → `mapAcousticResponseToSnapshot` → `AcousticEventInstance.update`

GPU metrics remain for visualization; mixer parameters come from the CPU acoustic solver so listenability matches `acoustic_demo --device`.
