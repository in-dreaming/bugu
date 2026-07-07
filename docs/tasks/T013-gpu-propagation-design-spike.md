# T013 GPU propagation 设计与 spike

状态：TODO  
类型：Research+Prototype  
优先级：P3  
依赖：T010，T012  
预计产物：docs/design/gpu-acoustic-propagation.md，GPU spike 结论。

## 1. 背景

GPU 加速只能在 CPU acoustic propagation correctness 成立后进行。GPU 目标是加速 ray/voxel/probe 求解，不改变 AcousticResponse 语义，更不能让 audio render thread 等 GPU。

## 2. 必读

- T010 CPU propagation MVP
- T012 validation/profile
- docs/design/audio-engine-design.md 第 10、11、12、14 节
- in-dreaming/gpu RHI 相关文档和源码；必须通过 git submodule 引入

## 3. 设计范围

必须比较：

- 基于 in-dreaming/gpu 的 GPU compute voxel tracing。
- 基于 in-dreaming/gpu 可暴露能力的 hardware ray query 可行性；如果 RHI 不支持，不得绕过 RHI 私接平台 API，除非先形成 ADR。
- CPU/GPU hybrid：CPU portal/probe + GPU ray batch。
- Offline/probe bake + runtime dynamic correction。

## 4. Spike 范围

只做最小 spike：

- 输入一个简化 voxel grid。
- 输入 listener、source、portal。
- 批量发射 direct、penetration、escape rays。
- 输出与 CPU 版本同构的 AcousticResponse 子集。
- 异步 readback，延迟 1-2 frames 可接受。

## 5. 必须回答的问题

1. GPU 结果晚到时如何 fallback？
2. readback 成本和延迟是多少？
3. GPU tracing 会不会与渲染 queue 争抢导致 frame spike？
4. 哪些数据需要 persistent buffer？
5. 如何保持 CPU/GPU backend 结果可对比？
6. GPU backend 在低端硬件如何禁用？

## 6. 验收标准

- 不改 audio render thread 实时安全 contract。
- 输出 GPU 与 CPU 的结果对比。
- 给出是否进入正式实现的结论。
- spike 如需可视化，必须使用 in-dreaming/gpu。
- 第三方或 RHI 依赖必须 submodule 化。
- 如果不值得做，也要明确原因和后续条件。
- 如果 in-dreaming/gpu 当前缺少所需 compute/ray query 能力，任务应输出 capability gap 和 BLOCKED/REVIEW 结论，不能绕过 RHI 使用其他图形 API。
- Evidence 必须包含 GPU dispatch 或 capability probe 的真实执行记录；设计-only 不能标 DONE。
- 更新 docs/tasks/tasks.md。

## 7. 不得越界

- 不做 GPU mixer。
- 不要求 RTX/DXR 作为唯一后端。
- 不直接替换 CPU propagation。
- 不用 CPU 结果冒充 GPU spike 结果；CPU fallback 只能作为对照。

## 8. Activity Log

- 2026-07-07：任务创建。
