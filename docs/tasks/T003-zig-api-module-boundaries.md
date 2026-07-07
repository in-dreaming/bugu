# T003 Zig API、可选 C ABI 与模块边界设计

状态：DONE  
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

## 7. Deliverables

- [docs/design/audio-zig-api.md](../design/audio-zig-api.md)：Zig-first API、模块依赖图、source tree/build.zig 草案、handle 生命周期、线程要求、可选 C ABI 边界、third_party_adapters 规则。

## 8. Evidence

- 执行命令：
  - `Get-Content -LiteralPath docs\tasks\asetup.md -Encoding UTF8`
  - `Get-Content -LiteralPath docs\tasks\tasks.md -Encoding UTF8`
  - `Get-Content -LiteralPath docs\tasks\T003-zig-api-module-boundaries.md -Encoding UTF8`
  - `Get-Content -LiteralPath docs\design\audio-engine-design.md -Encoding UTF8`
  - `Get-Content -LiteralPath docs\design\audio-runtime-contract.md -Encoding UTF8`
  - `Get-Content -LiteralPath docs\research\audio-backend-decoder-codec.md -Encoding UTF8`
- 输入数据：T001 的 backend/decoder/codec 结论；T002 的队列、snapshot、render callback、telemetry 和生命周期 contract；audio-engine-design 的分层架构、backend、mixer、asset、event、spatial 和 ADR 章节。
- 输出摘要：新增 `audio-zig-api.md`，明确 `bugu_audio_core`、`bugu_audio_device`、`bugu_audio_mixer`、`bugu_audio_assets`、`bugu_audio_events`、`bugu_audio_spatial`、`bugu_acoustics`、`bugu_audio_tooling`、`bugu_audio_visual_debug`、`third_party_adapters` 的职责和依赖；覆盖 engine/device/bank/event/listener/emitter/bus/telemetry/error API；给出 C ABI size/version/opaque handle 策略；定义 third-party adapter 不泄漏 miniaudio/SDL/SDL_sound/dr_wav/gpu 类型。
- 失败或限制：本任务是设计任务，未创建 `build.zig`、Zig source files 或 submodule；实现和编译验证从 T004 起进行。
- 验收对应：
  - Zig API 草案、C ABI 和模块图：见 design 文档第 2、5、6、8 节。
  - API 线程要求：见第 6、10 节。
  - handle 生命周期：见第 5.1 节。
  - T004-T008 需求：见第 11 节。
  - third_party_adapters：见第 4、9 节。
  - runtime/tooling/debug 边界：见第 2、6、10 节。
  - build.zig 模块树和可测试性：见第 3、4 节。

## 9. 不得越界

- 不实现 API。
- 不为了某个临时 backend 牺牲长期边界。

## 10. Activity Log

- 2026-07-07：任务创建。
- 2026-07-08：开始 T003，读取 T001/T002 产物并设计 Zig-first API、模块边界、C ABI 边界和 build.zig 模块树。
- 2026-07-08：完成 docs/design/audio-zig-api.md，更新 Deliverables/Evidence，状态置为 DONE。
