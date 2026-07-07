# T004 P0 Zig 设备后端实现

状态：TODO  
类型：Implementation  
优先级：P0  
依赖：T002，T003  
预计产物：Zig backend 实现、最小播放 demo、build.zig/submodule 集成、验证记录。

## 1. 背景

P0 需要尽快稳定发声，但不能把 mixer 设计绑死在某个第三方库上。当前候选是 miniaudio；如果 T001 决定改用 SDL，则必须使用 in-dreaming/SDL.git enjin/gpu/main。无论选择哪个后端，Bugu 侧实现必须是 Zig，第三方库必须以 git submodule 引入。

## 2. 必读

- docs/tasks/asetup.md
- T002 运行时 contract
- T003 Zig API / 可选 C ABI 设计
- T001 中 backend 和 submodule 的调研结论

## 3. 实现范围

必须实现：

- Zig backend adapter。
- 第三方依赖的 git submodule 接入。
- build.zig 中的依赖编译/链接配置。
- device open/start/stop/close。
- callback 到 fixed quantum render 的适配。
- stereo float32 输出。
- sample rate 和 buffer size 配置。
- device error 和 basic telemetry。
- 一个最小 sine wave 或 test tone demo。

## 4. 不需要实现

- 完整 mixer。
- streaming。
- 声学传播。
- native WASAPI/CoreAudio/AAudio。

## 5. 验收标准

- demo 能通过真实设备 backend 播放稳定 test tone 至少 5 分钟；如果当前环境无音频设备，可额外提供 offline backend 生成真实 PCM/WAV 作为 CI fallback，但不能替代真实设备验收。
- 停止和销毁不崩溃、不泄漏明显资源。
- callback 内不分配、不锁、不做文件 I/O。
- 能记录 callback count、underrun/dropout 指标。
- 第三方类型不泄漏到公共 Zig API 或可选 C ABI。
- 如果使用 SDL，确认来源是 in-dreaming/SDL.git enjin/gpu/main。
- 依赖必须可通过 git submodule init/update 恢复。
- Evidence 必须包含：submodule 状态、zig build 命令、运行命令、5 分钟运行摘要或 offline PCM/WAV 输出摘要。
- 更新 docs/tasks/tasks.md 和本任务 Evidence。

## 5.1 禁止 mock

- 不能用空 callback 冒充播放成功。
- 不能调用系统播放器、外部命令或第三方 demo 冒充 Bugu backend。
- offline backend 必须走同一个 render callback/fixed quantum 适配路径，输出真实 sample buffer。

## 6. 验证建议

- 默认设备播放。
- 改 sample rate 和 period frames。
- start/stop 重复 100 次。
- 在 callback 中记录最大耗时，但不能格式化日志。

## 7. Activity Log

- 2026-07-07：任务创建。
