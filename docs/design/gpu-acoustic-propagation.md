# Bugu GPU Acoustic Propagation Design and Spike Result

状态：Review v0.1  
日期：2026-07-08  
任务：T013 GPU propagation design/spike  
依赖：T010 CPU propagation MVP, T012 validation/profile gate

## 1. Conclusion

Do not move GPU acoustic propagation into formal implementation yet.

The required RHI dependency is now present as a git submodule at `third_party/in_dreaming_gpu`, commit `8b0f2bc657775d899dc4d724918a1e6be9ffa450`. The checked-out source exposes the right families of APIs for a future GPU path:

- compute binding dispatch,
- queue capability reporting,
- async/multi-queue graph examples,
- readback buffer/map APIs,
- experimental ray tracing headers.

However, this environment cannot execute a real RHI dispatch spike because:

- `cmake` is not installed;
- nested RHI submodule directories under `third_party/in_dreaming_gpu/modules/3rd` exist but are empty/not initialized;
- upstream `examples/07_compute_pipeline/main.c` explicitly reports validation as skipped because full resource binding is pending in that example.

T013 therefore stops at a capability-gated design and source-level probe. It must remain `REVIEW` until a GPU dispatch/readback run produces GPU `AcousticResponse` subset values comparable to T010 CPU output.

## 2. Capability Probe

Repeatable command:

```powershell
.\scripts\probe_gpu_acoustic_capabilities.ps1
```

Recorded output: [gpu-acoustic-capability-probe.txt](../validation/gpu-acoustic-capability-probe.txt)

Key findings:

| Capability | Probe result | T013 impact |
|---|---:|---|
| RHI submodule | present | dependency policy satisfied |
| CMake | missing | cannot build/run RHI examples here |
| nested slang-rhi/SDL/slang submodules | directories present but not initialized | cannot link RHI here |
| compute dispatch helper | present | viable primary path |
| queue capability query | present | can detect dedicated vs alias compute |
| readback APIs | present | viable response buffer readback path |
| async compute example | present | useful pattern for 1-2 frame latency |
| basic compute result validation | skipped upstream | do not claim acoustic GPU correctness yet |
| ray tracing API | present, experimental | optional later path, not required for MVP |

## 3. CPU Baseline to Match

The GPU backend must output the same semantic subset as T010, not PCM:

- direct gain and delay,
- transmission gain and low-pass proxy,
- portal/diffraction gain and direction,
- escape/openness,
- reflection/reverb terms where implemented,
- confidence.

Baseline snapshots:

- [T010 AcousticResponse snapshot](../validation/acoustic-t010-response-snapshot.json)
- [T011 mapping snapshot](../validation/acoustic-t011-mapping-snapshot.json)

Initial GPU correctness tolerance:

| Field | Tolerance |
|---|---|
| direct_gain | absolute <= 0.04 or relative <= 10% |
| transmission_gain | absolute <= 0.02 or relative <= 20% |
| portal_gain | absolute <= 0.03 or relative <= 20% |
| openness | absolute <= 0.08 |
| direction vectors | dot product >= 0.90 when valid |
| confidence | must decrease when GPU uses coarser data or stale readback |

No GPU result was produced in this task; the comparison contract is ready, but the implementation gate remains open.

## 4. Architecture

GPU propagation is a backend under the existing CPU semantic model:

```text
AcousticSceneSnapshot
  -> CPU backend or GPU backend
  -> AcousticResponseBuffer
  -> Audio Control Thread
  -> AcousticSnapshot
  -> Audio Render Thread
```

The audio render thread never waits on GPU fences, maps readback buffers, uploads scene data, or formats logs. It only consumes immutable snapshots produced earlier by the control thread.

## 5. Data Buffers

Persistent GPU buffers:

| Buffer | Contents | Update cadence |
|---|---|---|
| `VoxelBrickBuffer` | occupancy/material/thickness/openness cells | full build or dirty brick upload |
| `MaterialBuffer` | 3-band absorption/reflection/transmission/scattering | material table change |
| `PortalBuffer` | center, normal, radius, open area, material, state | door/opening changes |
| `RoomProbeBuffer` | room ids, RT60, density, openness | level load or bake update |
| `RayRequestBuffer` | listener/source/portal ray batches | every propagation update |
| `PathTermBuffer` | direct/transmission/portal/escape/reflection partials | GPU write |
| `ResponseReadbackRing` | compact response subset | 2-3 frame ring |

All buffers are derived from T009/T010 scene semantics. Backend-private acceleration structures are allowed, but they cannot change the meaning of the response fields.

## 6. Compute Voxel Tracing Path

Primary path for a formal spike:

1. Build a small `TestScene` equivalent on CPU.
2. Upload material table, voxel grid, portals, and ray requests.
3. Dispatch compute workgroups through `gpuComputeBindingDispatch`.
4. Each ray accumulates air length, solid material depth, portal hits, escape distance, and confidence.
5. Reduce path terms into one response record per source/listener pair.
6. Copy response records to readback ring.
7. Control thread consumes readback from frame N-1 or N-2.
8. Compare against T010 CPU solver for the same scene input.

This is preferred over hardware ray query for MVP because it uses the same voxel/material/portal data as the CPU solver and avoids RTX/DXR as a hard requirement.

## 7. Hardware Ray Query Path

Hardware ray tracing is optional. It may be used only if `in-dreaming/gpu` exposes the required capability through its C API and feature table.

Use cases:

- high-density reflection sampling,
- large outdoor escape rays,
- triangle/SDF acceleration derived from acoustic scene data.

Rules:

- Do not bypass `in-dreaming/gpu` with direct D3D12/Vulkan/Metal calls.
- If ray tracing is unsupported, fall back to compute voxel tracing or CPU.
- Ray query output must still reduce into `AcousticResponse`, not PCM.

## 8. Hybrid and Bake Options

| Approach | Use when | Notes |
|---|---|---|
| CPU portal/probe + GPU direct/escape rays | dynamic scenes with many emitters | CPU keeps topology deterministic; GPU handles ray batch volume. |
| GPU voxel tracing only | many short propagation queries per frame | Good first formal spike target. |
| Offline probe bake + runtime correction | large caves/interiors | Runtime GPU/CPU only updates dynamic doors/obstacles and direct/portal terms. |
| CPU-only fallback | low-end hardware, missing compute queue, late readback | Always valid and already implemented. |

## 9. Late GPU Result Fallback

If GPU readback is late:

1. Use the last valid `AcousticResponseBuffer`.
2. Increase smoothing based on response age and confidence.
3. If response age exceeds the configured frame budget, switch that source/listener pair to CPU propagation.
4. Never block the audio render thread.

Default latency budget: 1-2 frames. The response ring should be at least 3 frames to avoid overwriting data still in flight.

## 10. Queue and Frame Spike Controls

GPU work must query queue support:

- dedicated compute: allow async compute graph pass if frame budget permits;
- alias graphics: schedule serially at low priority or reduce ray count;
- unavailable/CPU backend: disable GPU propagation.

Per-frame controls:

- max ray requests per frame,
- max dirty brick uploads,
- max readback bytes,
- adaptive ray count when render frame time spikes,
- profile GPU pass duration through graph profiling when available.

## 11. Entry Conditions for Formal Implementation

T013 can move from `REVIEW` to `DONE` only after:

1. Install CMake in the development environment.
2. Initialize nested submodules:
   `git -C third_party/in_dreaming_gpu submodule update --init --recursive`
3. Build and run at least one compute/readback RHI example, preferably `25_async_compute_graph`.
4. Add a minimal acoustic compute shader that consumes one voxel/material/portal scene.
5. Produce GPU response subset output for open_air, thick_wall, wall_hole, and open_field.
6. Compare those GPU outputs against T010 CPU baseline with the tolerances above.

Until then, CPU propagation remains the correctness path and GPU remains an acceleration candidate only.
