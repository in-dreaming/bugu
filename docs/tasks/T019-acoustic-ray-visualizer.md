# T019 Acoustic Ray Visualizer

## Goal

Add an interactive GPU-backed acoustic propagation visualizer for Bugu. The tool is a demo and validation surface for acoustic ray behavior; it is not a production GPU acoustic backend and does not drive realtime audio output.

## Build

```powershell
& E:\env\activate-dong-build.ps1
cmake -S tools/acoustic_visualizer -B build/acoustic_visualizer -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/acoustic_visualizer --target bugu_acoustic_visualizer
```

Run from the build output directory so the copied Slang and runtime DLL files are found:

```powershell
cd build/acoustic_visualizer
.\bugu_acoustic_visualizer.exe
```

For an automated smoke run:

```powershell
.\bugu_acoustic_visualizer.exe --once --report acoustic-ray-visualizer-runtime-report.txt
```

## Controls

- `W/A/S/D`: move listener
- Arrow keys: move source
- Mouse drag: place source
- `Space`: toggle door open/closed
- `R`: reset scene
- `1/2/3`: concrete, wood, rock material presets
- `Esc` or window close: quit

## Implementation Notes

The tool links only against the existing `gpu` target and uses `third_party/in_dreaming_gpu` for the SDL-backed platform/window/surface path. It uses GPU compute ray tracing through `acoustic_trace.slang`, then renders visual debug geometry through `acoustic_draw.slang`.

The visualizer shows wall geometry, the source/listener markers, a colored ray fan, reflected/transmitted/portal paths, and response bars. Runtime metrics include direct gain, occlusion, reflection energy, portal gain, reverb send, and confidence.

The first version intentionally uses compute ray tracing rather than hardware RT acceleration structures, matching the currently validated Bugu GPU acoustic spike path.
