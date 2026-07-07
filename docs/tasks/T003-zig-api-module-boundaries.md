# T003 Zig API、可选 C ABI 与模块边界设计

状态：TODO  
类型：Design  
优先级：P0  
依赖：T002  
预计产物：docs/design/audio-zig-api.md

## 1. 背景

Bugu 必须用 Zig 实现。需要先设计 Zig-first API 和模块边界，让 runtime、editor、脚本绑定、后端和测试都能通过一致接口工作。若后续确实需要跨语言集成，可在 Zig API 外提供可选 C ABI 导出层。公共 API 不应泄漏 miniaudio、SDL、SDL_sound 或任何第三方类型。

## 2. 必读

- docs/tasks/asetup.md
- docs/design/audio-engine-design.md 的第 3、4、5、7、8、9、17 节
- T002 产物

## 3. 模块边界

必须明确这些模块的职责和依赖方向：

- bugu_audio_core
- bugu_audio_device
- bugu_audio_mixer
- bugu_audio_assets
- bugu_audio_events
- bugu_audio_spatial
- bugu_acoustics
- bugu_audio_tooling
- bugu_audio_visual_debug
- third_party_adapters

## 4. API 范围

至少覆盖：

- engine create/destroy/start/stop/update
- device enumerate/open/close/reopen
- bank load/unload/hot_reload
- post event/stop event/set parameter
- listener create/update
- emitter attach/update/detach
- bus volume/mute/meter query
- telemetry query
- error reporting

## 5. 设计要求

- Zig API 必须体现所有权、allocator 归属、错误集、线程要求。
- 对外 handle 必须是不泄漏内部布局的稳定 handle；如果提供 C ABI，则使用 opaque handle。
- API 要能表达失败原因，但不能在 audio render thread 格式化错误字符串。
- 需要区分 runtime API、tool/editor API、debug API。
- 不允许 API 依赖 miniaudio、SDL、SDL_sound、in-dreaming/gpu 的具体类型；这些只能出现在 adapter 层。
- 如果设计 C ABI 导出层，需要定义 ABI 版本和结构体 size/version 策略。
- build.zig 模块划分和 submodule 依赖入口必须写清楚。

## 6. 验收标准

- 输出完整 Zig API 草案、可选 C ABI 边界和模块依赖图。
- 对每个 API 写明线程要求。
- 对每类 handle 写明生命周期。
- 对 T004-T008 的实现需求足够明确。
- 明确 third_party_adapters 如何包住 submodule 依赖。
- 明确哪些 API 是 runtime 主路径、哪些只是 debug/tooling，不允许 debug/tooling 泄漏到 audio render thread。
- 给出最小 build.zig 模块树，说明每个模块是否可独立测试。
- 更新 docs/tasks/tasks.md。

## 7. 不得越界

- 不实现 API。
- 不为了某个临时 backend 牺牲长期边界。

## 8. Activity Log

- 2026-07-07：任务创建。
