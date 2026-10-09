# TASK-018：实现 in-dreaming/gpu SME 作者应用

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：GPU Tooling/Product UX
- 评审角色：Authoring、GPU、Runtime、QA
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-018/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-018/`（原始产物）
- 执行波次：12
- 硬依赖：TASK-013、TASK-016、TASK-017、TASK-027
- 协作关系：TASK-019 另建 runtime debug 工具；本任务拥有 `tools/sme_authoring/` UI
- 预计改动范围：`tools/sme_authoring/`、`third_party_adapters/gpu/` 必要扩展、`build_support/sme_steps.zig`、`zig-out/sme-validation/TASK-018/authoring-smoke.json`

## 目标
交付可编辑完整 SME project、调用shared compiler/runtime preview并执行live tuning/hot reload/rollback的图形作者应用。

## 上下文
可视工具必须使用现有 `in-dreaming/gpu` submodule，不得引入 ImGui/upstream SDL/第二 RHI。已核验的 pinned commit `8b0f2bc657775d899dc4d724918a1e6be9ffa450` 只有现有可视化基础，不能假定它提供可直接做作者应用的 text/IME/focus/widget 基础设施。TASK-027 先独立交付并 qualify 所需窗口输入、文本/字形、focus/clipboard/IME contract 及必要 submodule extension；本任务消费这些真实产物，建立应用层 editor/widget。GPU 不可用的 headless CLI 由 TASK-017 提供，不能代替 GUI 验收。

## 前置条件
- TASK-027 已通过独立 review 的 pinned GPU capability matrix、真实 text input/IME/focus/clipboard/render 接口、平台 smoke 和（需要扩展时）已验证的新 exact submodule pin/ABI/build evidence。缺失则本任务 BLOCKED，不得悄悄引入其他 GUI/RHI。
- authoring core/CLI。
- hot reload/rollback。
- Bus/sidechain metadata。
- Windows MSVC visualizer build经验可复用，但不复制CMake cache。

## 实施范围
### 必须完成
- 应用级可访问焦点/输入框/数值字段、文本选择/光标/滚动、剪贴板、中文/非 ASCII IME composition、键盘快捷键、undo/redo、modal focus、validation affordances，建立可被 graph/timeline/inspector 共用的 widget 层。
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

- `T018-A / QualifiedInputShell`：输入为TASK-027 qualified input/text/IME/focus API、TASK-017 authoring core；产物为 `tools/sme_authoring/ui/input.zig`、`focus.zig`、`text_field.zig`（计划新增）、窗口 shell 与 TASK-027 capability 接入报告。测试真实 keyboard/mouse/text events、中文 IME commit/cancel、selection/clipboard、focus loss/modal capture、undo/redo，字段 round-trip 到 shared core；仅程序调用 setter 不算输入验收。
- `T018-B / ProjectPersistence`：输入为T018-A shell/widgets、TASK-017 project reader/writer；产物为 project browser、open/save/conflict UI、dirty state、autosave/recovery coordinator 与 recovery fixture；测试 source 不被 recovery 覆盖、crash 重启显式恢复/丢弃、相对路径、冲突保护和成功保存后的清理。
- `T018-C / GraphAndMusicTimeline`：输入为T018-A widgets、TASK-017 shared graph/tempo/cue/fill models 与 validators；产物为 state graph、tempo/meter/beat-group、cue/fill editors、sample snapping 与错误 overlay；测试新建/键盘修改/undo/保存重开、6/8 `[3,3]` 与变拍号、time-linear ramp/anchor、invalid route 阻止 publish。
- `T018-D / LayersAndMixInspectors`：输入为T018-A widgets、TASK-017 layer/bus/profile models、TASK-013 meters 和 TASK-010 quality reports；产物为 layer/curve/bus/sidechain/stinger/profile editors 和真实 preview meters/quality inspector；测试每个模型字段 GUI→shared source→bank round-trip、matching-layout 输出、SRC/DC/loop/true-peak/RMS/LUFS/storage/seek 诊断可定位。
- `T018-E / LivePublishAndSmoke`：输入为T018-B/C/D 编辑工作流、TASK-016 publish/rollback 和真实 runtime preview；产物为真实 runtime connection、live tune/generation/reload/rollback UI 和 deterministic full smoke JSON；测试失败 edit 无 publish、old/new generation、真实 PCM/trace hashes、设备缺失时显式 offline preview。
- 顺序为 TASK-027→A→B/C/D→E；各片单独提交并由独立 Reviewer 验证当前 commit 产物/命令/失败场景，全部通过后才可整体进入 `REVIEW`。任何 GPU submodule 补丁由 TASK-027 拥有并先 qualify，本任务不隐藏上游扩展工作量。

## 设计与执行细节
1. UI model是shared authoring core的view，不复制schema。
2. 每次build/reload显示hash/generation/diagnostics。
3. invalid project不可发布。
4. crash recovery 只写 `<project>/.sme-recovery/<session-id>/`，使用原子临时文件+rename，不覆盖 source；成功保存后清理对应 session，启动时由用户显式选择恢复。
5. GPU shader/UI错误不得影响headless compiler。
6. UI 输入层区分 physical key/shortcut、committed UTF-8 text 和 IME preedit；composition 尚未 commit 不写 source model，Escape/cancel/focus loss 不重复 commit。焦点和 selection 属于 UI thread，不能直接写 runtime 的 mutable state。
7. Smoke 使用真实事件分发/控件编辑路径完成创建、修改、save/reopen、validate/build/preview/reload；GPU 绘制与输入 smoke 不能被 model-only API 操作或静态截图替代。记录输入阶段、commit 文本 hash、focus owner、model hash、diagnostic codes，不记录敏感剪贴板内容。

## 接口与数据契约
新增 build steps：`sme-authoring-build`、`sme-authoring`、`sme-authoring-smoke`。Smoke JSON envelope 固定包含 `schema_version`、commit、project/bank hash、GPU adapter/backend（无设备序列）、逐 stage status/duration、diagnostic codes、preview PCM/trace hashes、reload old/new generation 和 final result；路径使用 repo/project-relative 值。

## 文件变更
- authoring UI。
- 通过 TASK-027 已冻结/qualify 的 GPU adapter 增加应用级输入/widget binding；必要新增底层能力退回 TASK-027 独立 extension slice，第三方类型仍不进入 music core。
- build steps 和 `zig-out/sme-validation/TASK-018/authoring-smoke.json`；只把脱敏摘要写入 TASK-018 evidence。

## 验证
### 自动化验证
- `zig build test`。
- MSVC 环境运行 `zig build sme-authoring-smoke`，JSON 证明真实 input/widget→project→compiler→runtime 路径；每个 T018 子交付都有单独 headless model tests 和适用的真实 GPU/input smoke stage，所有已完成阶段从 TASK-001 CI scaffold 起持续执行。
### 手工验证
- Windows x86_64+MSVC 的真实窗口中，键盘/鼠标创建 state/tempo/cue/fill/layer，中文 IME 输入并 commit/cancel，切换焦点、clipboard、undo/redo，save/reopen，preview，修改 curve，hot reload，rollback；手工 IME 证据补足 automated event tests，不能以 smoke 预填模型代替。
### 边界与失败场景
- GPU unavailable、invalid edit、save conflict、reload rejection、device absent（offline preview）。

## 完成定义
- [ ] 本任务已交付 headless model/protocol tests 通过 TASK-001 稳定注册 seam 加入既有 `zig build test`/PR gate；GPU/input smoke 在具备条件的受管 runner 显式持续执行并单独报告，证据随子交付产生，不等待 TASK-021 首次接入 CI。
- [ ] 所有v1 author对象可创建/编辑/校验。
- [ ] preview/reload用真实runtime。
- [ ] smoke schema 已版本化且在相同输入下除明确的 duration 字段外结果可重复。
- [ ] recovery 路径、清理/恢复规则和忽略规则有 crash/save-conflict 测试。
- [ ] 无第二GUI/RHI栈。
- [ ] TASK-027 依赖与 T018-A 输入/文本/focus 子交付均有独立证据，中文 IME 与完整真实编辑路径通过，不假定 pinned upstream 已有 widget 工具包。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐实际依赖、量化/输入契约、独立审查产物与持续 gate；仅修订任务文档，状态保持 `TODO`。

## 风险与注意事项
在Windows使用MSVC ABI；不要复用错误的MinGW/Strawberry cache。

