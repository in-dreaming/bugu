# T002 实时运行时 contract 与线程模型设计

状态：DONE  
类型：Design  
优先级：P0  
依赖：T001 可并行  
预计产物：docs/design/audio-runtime-contract.md

## 1. 背景

音频 render thread 的实时安全是整个引擎底座。后续 backend、mixer、streaming、声学传播都必须遵守同一套线程和数据交换 contract。

## 2. 必读

- docs/tasks/asetup.md 的实时安全红线
- docs/design/audio-engine-design.md 的第 4、5、10、11、12 节

## 3. 设计范围

必须设计：

- Game Thread 到 Audio Control Thread 的命令队列。
- Audio Control Thread 到 Audio Render Thread 的不可变 snapshot。
- Worker Thread 到 Audio Control Thread 的 job completion。
- Propagation backend 到 Audio Control Thread 的 AcousticResponseBuffer。
- 音频 render thread 可以读取的数据类型和禁止操作。
- device callback frame count 与 fixed quantum 的适配方式。
- shutdown、device lost、hot reload、bank unload 的线程边界。

## 4. 必须产出的接口草案

至少包含这些概念：

- AudioCommand
- AudioCommandQueue
- RenderSnapshot
- SnapshotSwap
- WorkerCompletionQueue
- AcousticSnapshot
- TelemetryCounters

不要求最终 Zig 语法完全正确，但字段、所有权和生命周期必须明确。若需要 C ABI 导出层，只描述 ABI 边界，不把主体设计成 C 实现。

## 5. 验收场景

文档必须解释这些场景如何安全执行：

1. 游戏线程连续 post 1000 个 play event。
2. 音频设备 callback 一次请求非固定帧数。
3. streaming worker 解码完成，通知控制线程。
4. GPU/CPU propagation 结果晚一帧到达。
5. Bank 热更新时旧 voice 仍在播放。
6. 设备断开并重开。
7. 游戏退出，所有线程安全停止。

## 6. 验收标准

- 每个跨线程数据流都写清楚 producer、consumer、所有权和生命周期。
- Audio render thread 不需要锁、不需要分配、不需要等待。
- 说明 fixed quantum 和 backend callback 的适配策略。
- 说明 telemetry 如何采集而不破坏实时安全。
- 明确 fallback backend、offline render、device lost、GPU result missing 时的状态机和线程边界。
- 明确哪些测试证据可证明没有 alloc/lock/I/O/GPU wait 进入 audio render thread。
- 更新 docs/tasks/tasks.md。

## 7. Deliverables

- [docs/design/audio-runtime-contract.md](../design/audio-runtime-contract.md)：实时线程模型、跨线程队列、snapshot swap、fixed quantum 适配、fallback/device lost/shutdown 边界、测试证据要求。

## 8. Evidence

- 执行命令：
  - `Get-Content -LiteralPath docs\tasks\asetup.md -Encoding UTF8`
  - `Get-Content -LiteralPath docs\tasks\tasks.md -Encoding UTF8`
  - `Get-Content -LiteralPath docs\tasks\T002-realtime-runtime-contract.md -Encoding UTF8`
  - `Get-Content -LiteralPath docs\design\audio-engine-design.md -Encoding UTF8`
- 输入数据：docs/tasks/asetup.md 实时安全红线；docs/design/audio-engine-design.md 第 4、5、10、11、12 节的 backend、mixer、propagation、threading 和 realtime safety 设计。
- 输出摘要：新增 runtime contract，覆盖 Game -> Control、Worker -> Control、Propagation -> Control、Control -> Render、Render -> Telemetry 的 producer/consumer/所有权/生命周期；定义 AudioCommand、AudioCommandQueue、RenderSnapshot、SnapshotSwap、WorkerCompletionQueue、AcousticSnapshot、TelemetryCounters；定义 variable callback 到 fixed quantum FIFO 适配和 device lost/offline fallback/GPU missing 边界。
- 失败或限制：本任务是设计任务，未实现 backend、queue、snapshot 或 mixer；真实 alloc/lock/I/O/GPU wait 审计证据从 T004 起由实现任务提供。
- 验收对应：
  - 跨线程数据流：见 runtime contract 第 3 节。
  - render thread 无锁/无分配/无等待：见第 1、2、7 节。
  - fixed quantum 适配：见第 5 节。
  - telemetry：见第 4.7 节。
  - fallback/device lost/GPU missing：见第 6、7 节。
  - 测试证据：见第 9 节。

## 9. 不得越界

- 不开始实现 backend。
- 不设计复杂声学算法，只定义 AcousticSnapshot 的线程边界。

## 10. Activity Log

- 2026-07-07：任务创建。
- 2026-07-08：开始设计实时运行时 contract，范围限定为线程模型、跨线程队列、snapshot、callback quantum 适配和生命周期边界。
- 2026-07-08：完成 docs/design/audio-runtime-contract.md，更新 Deliverables/Evidence，状态置为 DONE。
