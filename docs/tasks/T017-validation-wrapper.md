# T017 Validation wrapper

Status: DONE  
Type: Validation+Tooling  
Priority: P2  
Dependencies: T012-T016  
Expected artifacts: `tools/run_validation.ps1`, [validation wrapper snapshot](../validation/t017-validation-wrapper-snapshot.txt)

## 1. Background

T012 defines a validation matrix, and T013-T016 added more commands. T017 adds a single script entry point that runs the real validation commands instead of requiring each agent to manually reconstruct the matrix.

## 2. Scope

- Run Zig unit tests and all CPU/offline demos that exercise asset, event, spatial, acoustic, effect, and validation-report paths.
- Run offline tone render with real PCM output.
- Support explicit GPU spike validation with `-Gpu`, `-DongBuildEnv`, and `-GpuBuildDir`.
- Fail on missing GPU environment when GPU validation is requested; do not silently fall back.

## 3. Acceptance Criteria

- Script exits nonzero on the first failed command.
- Default script path performs real CPU/offline validation commands.
- GPU path is explicit and runs the real CMake/RHI spike when requested.
- Validation evidence records command, input coverage, and output summary.

## 4. Evidence

- `powershell -ExecutionPolicy Bypass -File tools\run_validation.ps1` passed.
- Output saved to [t017-validation-wrapper-snapshot.txt](../validation/t017-validation-wrapper-snapshot.txt).
- Default CPU/offline gate executed:
  - `zig build test`
  - `zig build asset-demo`
  - `zig build event-demo`
  - `zig build spatial-demo`
  - `zig build acoustic-demo`
  - `zig build acoustic-mapping-demo`
  - `zig build acoustic-effects-demo`
  - `zig build acoustic-event-demo`
  - `zig build effect-bus-demo`
  - `zig build validation-report`
  - `zig build tone -- --offline --seconds 0.25 --voices 16 --out bugu-validation-tone.wav`
- GPU path is present but was not run in this evidence pass; `-Gpu` requires the dong build environment and fails if it is missing.

## 5. Activity Log

- 2026-07-08: Started after T016 to consolidate repeatable validation commands.
- 2026-07-08: Added `tools/run_validation.ps1` with strict external-command exit checking, CPU/offline validation matrix, offline tone render, and explicit GPU spike mode.
- 2026-07-08: Ran the default wrapper successfully and recorded output summary.
