# T002 实时运行时 contract 与线程模型设计

状态：TODO  
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

## 7. 不得越界

- 不开始实现 backend。
- 不设计复杂声学算法，只定义 AcousticSnapshot 的线程边界。

## 8. Activity Log

- 2026-07-07：任务创建。
