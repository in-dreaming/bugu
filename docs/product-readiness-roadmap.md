# Bugu Product Readiness Roadmap

Date: 2026-07-08  
Current baseline: T001-T018 complete, CPU/offline validation wrapper passing, GPU acoustic spike validated as a prototype.

## 1. Readiness Definition

Bugu is product-ready when it can be embedded by a game team with predictable behavior, stable APIs, repeatable validation, clear platform support, and no hidden mock or prototype-only paths in the default runtime.

Readiness does not require every long-term feature to be complete. It does require that shipped features have real implementations, documented limits, validation coverage, and operational guidance.

## 2. Current State

Completed foundations:

- Zig-first engine core with miniaudio/offline backend.
- Fixed-quantum mixer, voice pool, bus labels, effect bus, telemetry.
- WAV/PCM asset import and bank loading.
- Event runtime with random, switch, RTPC, sample voice handles, and acoustic event instances.
- Spatial baseline: attenuation, cone, Doppler, pan, low-pass.
- CPU acoustic propagation MVP with voxel/material/portal/probe scene inputs.
- Acoustic response mapping into mixer snapshots and real runtime effects.
- Validation wrapper: `tools/run_validation.ps1`.
- GPU acoustic spike through `in-dreaming/gpu`, expanded to seven scenes.

Known prototype limits:

- GPU propagation is still a spike, not a production backend.
- Device backend is still transitional; production platform coverage is not locked.
- Codec support is limited to explicit WAV/PCM paths.
- Event/runtime authoring is code/data-structure driven; no stable authoring pipeline or schema versioning yet.
- Debug visualization is not implemented.
- Public API and ABI are not frozen.

## 3. P0: Product Readiness Blockers

These must be completed before calling Bugu product-ready.

1. Stabilize public API and package layout.
   - Freeze core Zig API names for engine init, asset bank loading, events, voices, spatial params, acoustic snapshots, buses, telemetry, and shutdown.
   - Decide whether the first release includes C ABI exports.
   - Add API compatibility tests or compile-only sample projects.

2. Harden backend lifecycle.
   - Define device init/start/stop/recover semantics.
   - Add real device smoke evidence on supported Windows hardware.
   - Keep offline backend as CI path, but document it as test/offline output, not product device fallback.

3. Make asset pipeline shippable.
   - Define versioned bank manifest/schema.
   - Add validation for invalid WAVs, malformed manifests, missing blobs, unsupported formats, and sample-rate/channel conversion rules.
   - Decide MVP codec policy: WAV/PCM only, or add a real submodule-backed decoder.

4. Add runtime ownership and shutdown safety.
   - Document lifetime of Engine, Bank, EventRuntime, AcousticEventInstance, and sample buffers.
   - Add tests for destroying/stopping while voices are active.
   - Ensure no voice can reference freed sample memory in normal API usage.

5. Extend validation into CI.
   - Wire `tools/run_validation.ps1` into CI.
   - Store validation artifacts for failures.
   - Keep GPU spike as an opt-in hardware job, not a required default CI job.

## 4. P1: Production Quality Requirements

These make the engine reliable enough for early adopters.

1. Real-time safety audit.
   - Audit render path for allocation, locks, file I/O, logging, GPU waits, and lazy loading.
   - Add a static checklist per module.
   - Add stress tests for voice churn, event bursts, parameter updates, and long offline renders.

2. Bus and effect model hardening.
   - Move from one fixed reverb bus toward a small fixed send model if needed.
   - Add per-bus/effect meters and reset semantics.
   - Document supported routing graph for the first release.

3. Acoustic runtime integration hardening.
   - Add multi-emitter acoustic update tests.
   - Add stale acoustic response handling and smoothing policy.
   - Add explicit confidence/age propagation into mixer update decisions.

4. Error model and diagnostics.
   - Expand `BuguError` into actionable categories.
   - Ensure demos and tools print useful failure reasons.
   - Add structured validation output for CI parsing.

5. Documentation for users.
   - Add quick start.
   - Add integration guide.
   - Add asset pipeline guide.
   - Add event/acoustic authoring examples.
   - Add platform support matrix.

## 5. P2: GPU Path to Production

GPU work should remain acceleration-only until it has production integration.

Next GPU milestones:

1. Split the packed spike buffer into scene, material, portal, request, and output buffers when the RHI binding path supports it.
2. Add a backend object owned by the control/worker side, not by the audio render thread.
3. Add asynchronous readback ring with response age/confidence.
4. Integrate CPU fallback for unsupported GPU, late readback, or validation mismatch.
5. Extend cave coverage from openness-only to reflection/reverb terms.
6. Add door dynamic update history, not just closed/open one-shot inputs.
7. Keep CPU propagation as correctness reference.

Non-negotiable GPU rules:

- Do not block the audio render thread on GPU work.
- Do not bypass `in-dreaming/gpu`.
- Do not mark GPU production-ready from spike executable evidence alone.

## 6. P2: Debugging and Tooling

1. Add text/JSON validation artifacts for every demo.
2. Add profile summaries with p50/p95/p99/p999 render timing.
3. Add optional visual debug tool through `in-dreaming/gpu`.
4. Show voice states, bus/effect meters, listener/emitter transforms, acoustic voxels, portals, and response curves.
5. Keep non-visual CI reports available for headless environments.

## 7. Release Gates

Alpha gate:

- Public API is coherent but not frozen.
- Offline validation passes.
- Windows device smoke test passes.
- WAV/PCM asset pipeline documented.
- Event, spatial, acoustic, and effect demos pass.
- Known limits are documented.

Beta gate:

- API freeze candidate.
- CI validation is mandatory.
- Real device test matrix exists.
- Asset schema is versioned.
- Runtime lifetime rules are tested.
- No known real-time safety violations.

Product-ready gate:

- API/ABI policy is frozen for the release.
- Supported platform matrix is explicit.
- CI and release validation artifacts are archived.
- User documentation covers integration and troubleshooting.
- All default runtime paths are real implementations.
- Prototype-only features are opt-in and clearly labeled.

## 8. Suggested Next Tasks

Recommended next task order:

1. T019 Public API and lifetime hardening.
2. T020 Backend lifecycle and Windows device smoke gate.
3. T021 Versioned asset bank schema and failure tests.
4. T022 CI validation integration.
5. T023 Real-time safety audit and stress tests.
6. T024 User quick start and integration docs.
7. T025 GPU backend object and async readback design.

Each task should keep the existing rule: no mock completion, no silent fallback, evidence recorded, and one commit per completed task.
