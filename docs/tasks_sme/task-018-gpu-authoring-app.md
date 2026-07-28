# TASK-018：实现 in-dreaming/gpu SME 作者应用

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：GPU Tooling/Product UX
- 评审角色：Authoring、GPU、Runtime、QA
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-018/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-018/`（原始产物）
- 执行波次：8
- 硬依赖：TASK-013、TASK-016、TASK-017
- 协作关系：TASK-019 另建 runtime debug 工具；本任务拥有 `tools/sme_authoring/` UI
- 预计改动范围：`tools/sme_authoring/`、`third_party_adapters/gpu/` 必要扩展、`build_support/sme_steps.zig`、`zig-out/sme-validation/TASK-018/authoring-smoke.json`

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
- autosave/recovery 和明确 dirty state；recovery 固定写到 `<project>/.sme-recovery/`，源模板 `.gitignore` 必须忽略该目录，恢复文件只使用 project-relative asset IDs。
- muted deterministic automated smoke mode。

### 明确不包含
- DAW音频编辑、录音、插件宿主。
- 其他 GUI/RHI 依赖。
- 未经 TASK-023 support matrix 验证的平台；v1 本任务的必过 GUI target 是 Windows x86_64 + MSVC。

## 交付检查点

1. Window/RHI shell、project browser、save/autosave/recovery 和 deterministic smoke schema。
2. State graph 与 tempo/cue/fill timeline 编辑、validation overlay 和 sample snapping。
3. Layer/bus/sidechain/stinger/profile 编辑与真实 preview/meter。
4. Live tuning、generation publish、hot reload/rollback 与完整 smoke。
5. 每个检查点独立 review；全部通过后任务才可进入 `REVIEW`。

## 设计与执行细节
1. UI model是shared authoring core的view，不复制schema。
2. 每次build/reload显示hash/generation/diagnostics。
3. invalid project不可发布。
4. crash recovery 只写 `<project>/.sme-recovery/<session-id>/`，使用原子临时文件+rename，不覆盖 source；成功保存后清理对应 session，启动时由用户显式选择恢复。
5. GPU shader/UI错误不得影响headless compiler。

## 接口与数据契约
新增 build steps：`sme-authoring-build`、`sme-authoring`、`sme-authoring-smoke`。Smoke JSON envelope 固定包含 `schema_version`、commit、project/bank hash、GPU adapter/backend（无设备序列）、逐 stage status/duration、diagnostic codes、preview PCM/trace hashes、reload old/new generation 和 final result；路径使用 repo/project-relative 值。

## 文件变更
- authoring UI。
- 仅在不足时扩展GPU adapter，第三方类型仍不进入music core。
- build steps 和 `zig-out/sme-validation/TASK-018/authoring-smoke.json`；只把脱敏摘要写入 TASK-018 evidence。

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
- [ ] smoke schema 已版本化且在相同输入下除明确的 duration 字段外结果可重复。
- [ ] recovery 路径、清理/恢复规则和忽略规则有 crash/save-conflict 测试。
- [ ] 无第二GUI/RHI栈。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
在Windows使用MSVC ABI；不要复用错误的MinGW/Strawberry cache。
