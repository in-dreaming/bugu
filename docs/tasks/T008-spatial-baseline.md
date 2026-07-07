# T008 基础空间音频：attenuation、cone、Doppler

状态：TODO  
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

## 7. Activity Log

- 2026-07-07：任务创建。
