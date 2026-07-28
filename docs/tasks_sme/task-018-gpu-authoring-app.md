# TASK-018：实现 in-dreaming/gpu SME 作者应用

## 元数据
- 状态：待实施
- 执行波次：8
- 硬依赖：TASK-013、TASK-016、TASK-017
- 协作关系：TASK-019 另建 runtime debug 工具；本任务拥有 `tools/sme_authoring/` UI
- 预计改动范围：`tools/sme_authoring/`、`third_party_adapters/gpu/` 必要扩展、`build.zig`、`docs/validation/sme/authoring-smoke.json`

## 目标
交付可编辑完整 SME project、调用shared compiler/runtime preview并执行live tuning/hot reload/rollback的图形作者应用。

## 上下文
可视工具必须使用现有`in-dreaming/gpu` submodule，不得引入ImGui/upstream SDL/第二RHI。GPU不可用的headless CLI仍由TASK-017提供，但不能代替本任务验收。

## 前置条件
- authoring core/CLI。
- hot reload/rollback。
- Bus/sidechain metadata。
- Windows MSVC visualizer build经验可复用，但不复制CMake cache。

## 实施范围
### 必须完成
- project browser、state graph、tempo/meter timeline、cue/fill route、layer/curve、bus/sidechain/stinger/profile编辑。
- waveform/timeline sample snapping与错误overlay。
- shared validation/build/preview。
- transport controls、candidate/plan/layer/bus meters。
- live tuning publish、generation状态、rollback。
- autosave/recovery和明确dirty state。
- muted deterministic automated smoke mode。

### 明确不包含
- DAW音频编辑、录音、插件宿主。
- 其他GUI/RHI依赖。

## 设计与执行细节
1. UI model是shared authoring core的view，不复制schema。
2. 每次build/reload显示hash/generation/diagnostics。
3. invalid project不可发布。
4. crash recovery写到明确project-local recovery文件，不覆盖source。
5. GPU shader/UI错误不得影响headless compiler。

## 接口与数据契约
新增build steps：`sme-authoring-build`、`sme-authoring`、`sme-authoring-smoke`。smoke加载fixture、执行edit/validate/build/preview/reload、输出JSON并退出。

## 文件变更
- authoring UI。
- 仅在不足时扩展GPU adapter，第三方类型仍不进入music core。
- build steps和smoke artifact。

## 验证
### 自动化验证
- `zig build test`。
- MSVC环境运行`zig build sme-authoring-smoke`，JSON证明真实project/core/runtime路径。
### 手工验证
- 创建state/tempo/cue/fill/layer，preview，修改curve，hot reload，rollback。
### 边界与失败场景
- GPU unavailable、invalid edit、save conflict、reload rejection、device absent（offline preview）。

## 完成定义
- [ ] 所有v1 author对象可创建/编辑/校验。
- [ ] preview/reload用真实runtime。
- [ ] smoke可自动重复。
- [ ] 无第二GUI/RHI栈。

## 风险与注意事项
在Windows使用MSVC ABI；不要复用错误的MinGW/Strawberry cache。
