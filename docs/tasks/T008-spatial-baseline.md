# T008 基础空间音频：attenuation、cone、Doppler

状态：DONE  
类型：Design+Implementation  
优先级：P1  
依赖：T005，T007  
预计产物：AttenuationProfile MVP、3D sound demo。

## 1. 背景

复合声学传播之前，必须先有稳定的基础 3D 参数模型。否则 acoustic solver 输出无法进入 mixer。

## 2. 必读

- docs/design/audio-engine-design.md 第 9 节
- T005 mixer
- T007 event runtime

## 3. 实现范围

必须实现：

- Listener position、orientation、velocity。
- Emitter position、orientation、velocity。
- distance volume curve：linear、inverse、custom LUT 至少两种。
- cone directivity：inner angle、outer angle、outer gain、outer low-pass。
- simple stereo panning 或 equal-power pan。
- Doppler pitch ratio，带 clamp。
- 参数平滑。

## 4. 不需要实现

- HRTF。
- occlusion raycast。
- acoustic propagation。

## 5. 验收标准

- listener 绕声源移动时 pan 和 gain 连续。
- 声源背向 listener 时 cone gain 和 low-pass 生效。
- 高速相对运动时 pitch ratio 合理且有 clamp。
- 所有参数进入 audio thread 前转换为 snapshot。
- AttenuationProfile 可被事件或 sound asset 引用。
- Evidence 必须包含至少一组数值轨迹：listener/emitter transform -> gain/pan/filter/pitch 输出。
- demo 若有可视化，必须使用 in-dreaming/gpu；纯音频/日志 demo 不需要可视化。

## 6. Demo 场景

- 一个 listener 绕 8 个声源移动。
- 一个有方向性的喇叭声源旋转。
- 一个高速通过 listener 的声源测试 Doppler。

## 6.1 禁止 mock

- 不能手写 pan/gain 曲线冒充空间计算。
- cone 和 Doppler 必须从 orientation、position、velocity 计算。
- 不能用 acoustic propagation 任务的临时假 occlusion 混入本任务验收。

## 7. Deliverables

- `src/spatial/spatial.zig`：listener/emitter `Transform`, `Vec3`, `AttenuationProfile`, linear/inverse/custom LUT distance curves, cone directivity, Doppler pitch ratio with clamp, and smoothing helper.
- `src/mixer/mixer.zig`：per-voice equal-power pan, low-pass filter, pitch step support for sample voices.
- `examples/spatial_demo.zig`：non-visual spatial demo that prints transform -> gain/pan/filter/pitch trajectories and renders a short spatialized tone.
- `build.zig`: adds `zig build spatial-demo`.

## 8. Evidence

- Build/test command:
  - `zig build test`
  - Result: passed.
- Spatial demo command:
  - `zig build spatial-demo`
- Numeric trajectory output:
  - `orbit step=0 listener=(6.00,0.00,0.00) distance=6.000 gain=0.0417 pan=-1.0000 lowpass=1400.0 pitch=1.0000`
  - `orbit step=1 listener=(4.24,0.00,4.24) distance=6.000 gain=0.1271 pan=-0.7071 lowpass=14114.8 pitch=1.0000`
  - `orbit step=2 listener=(-0.00,0.00,6.00) distance=6.000 gain=0.1667 pan=0.0000 lowpass=20000.0 pitch=1.0000`
  - `orbit step=3 listener=(-4.24,0.00,4.24) distance=6.000 gain=0.1271 pan=0.7071 lowpass=14114.8 pitch=1.0000`
  - `orbit step=4 listener=(-6.00,0.00,-0.00) distance=6.000 gain=0.0417 pan=1.0000 lowpass=1400.0 pitch=1.0000`
  - `orbit step=5 listener=(-4.24,0.00,-4.24) distance=6.000 gain=0.0417 pan=0.7071 lowpass=1400.0 pitch=1.0000`
  - `orbit step=6 listener=(0.00,0.00,-6.00) distance=6.000 gain=0.0417 pan=-0.0000 lowpass=1400.0 pitch=1.0000`
  - `orbit step=7 listener=(4.24,0.00,-4.24) distance=6.000 gain=0.0417 pan=-0.7071 lowpass=1400.0 pitch=1.0000`
- Cone and Doppler output:
  - `cone back-facing gain=0.0417 cone_gain=0.2500 lowpass=1400.0`
  - `doppler relative_velocity=-180 pitch=0.6558 clamp=[0.5,2.0]`
- Render output:
  - `spatial render frames=9728 peak=0.028260 rms=0.019421 active=1 clipping=0`
  - `bugu-spatial-render.wav`: `38444` bytes before cleanup.
- Real path:
  - Demo computes spatial params from listener/emitter transforms.
  - Params enter mixer before render through `TestVoiceDesc` pan/lowpass/gain.
  - Mixer applies equal-power pan and one-pole low-pass in the render path using pre-existing voice state, without file I/O or allocation.
- Limitations:
  - No HRTF, occlusion raycast, or acoustic propagation is implemented or claimed.
  - Low-pass is a simple one-pole filter for P1 baseline evidence.
  - Spatial params are calculated on the control/demo side before render; later tasks can snapshot them for event-driven voices.

## 9. Activity Log

- 2026-07-07：任务创建。
- 2026-07-08：开始 T008，读取 spatial design and T005/T007 runtime.
- 2026-07-08：实现 baseline spatial parameter calculation, mixer pan/low-pass/pitch hooks and non-visual demo.
- 2026-07-08：通过 `zig build test` and `zig build spatial-demo`; 状态置为 DONE。
