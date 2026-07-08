# T018 GPU spike scene coverage

Status: DONE  
Type: Research+Prototype  
Priority: P2  
Dependencies: T013,T017  
Expected artifacts: expanded `tools/gpu_acoustic_spike` scene matrix, [GPU spike scene coverage snapshot](../validation/gpu-acoustic-spike-t018-report.txt)

## 1. Background

T013 validated the minimal GPU acoustic propagation spike for open_air, thick_wall, wall_hole, and open_field. T018 expands the same real GPU path to include door closed/open and cave openness coverage so future GPU backend work has a broader scene matrix.

## 2. Scope

- Keep the current single packed buffer path because the active RHI helper binds one buffer field.
- Add door closed/open scene inputs and expected portal delta validation.
- Add cave scene openness validation without claiming reflection/reverb GPU support.
- Re-run the real in-dreaming/gpu CMake target and executable.

## 3. Acceptance Criteria

- Shader dispatch still runs through `in-dreaming/gpu`.
- Scene count increases beyond T013 and validates all scenes with tolerances.
- Cave coverage is limited to direct/transmission/portal/openness/lowpass subset; no fake reverb output.
- Audio render thread remains untouched.

## 4. Evidence

- `& E:\env\activate-dong-build.ps1` executed.
- `cmake -S tools/gpu_acoustic_spike -B build/gpu_acoustic_spike -G Ninja -DCMAKE_BUILD_TYPE=Release` passed.
- `cmake --build build/gpu_acoustic_spike --target bugu_gpu_acoustic_spike` passed.
- `build\gpu_acoustic_spike\bugu_gpu_acoustic_spike.exe` passed from its target directory.
- Output saved to [gpu-acoustic-spike-t018-report.txt](../validation/gpu-acoustic-spike-t018-report.txt):
  - dedicated compute queue
  - `open_air`, `thick_wall`, `wall_hole`, `door_closed`, `door_open`, `cave`, `open_field`
  - `door_open portal=0.22959`
  - `cave openness=0.31250`
  - `validation=PASSED scenes=7`

## 5. Activity Log

- 2026-07-08: Started from T013 spike; selected scene coverage expansion as the next real GPU slice.
- 2026-07-08: Expanded packed scene input with explicit openness-solid count for cave-style non-occluding enclosure coverage.
- 2026-07-08: Validated seven-scene GPU spike through real `in-dreaming/gpu` compute dispatch/readback. No production async backend or GPU reverb/reflection claim is made.
