# TASK-001：冻结 SME 公共契约并建立可编译模块扩展点

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Runtime/API 与 Zig build
- 评审角色：架构、公共 API、实时安全
- 工作量等级：`M`
- 证据路径：`docs/validation/sme/TASK-001/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-001/`（原始产物）
- 执行波次：1
- 硬依赖：TASK-025
- 协作关系：为全部后续任务提供唯一命名、类型和目录契约
- 预计改动范围：`src/music/`（新增）、`src/bugu_audio.zig`、`build.zig`、`build_support/sme_steps.zig`（新增）、`tests/sme/contract_test.zig`（新增）

## 目标
交付能被现有 `zig build test` 编译的 SME module skeleton，冻结公共 ID、handle、error、request、receipt、thread annotation、生命周期状态和 task 扩展 seam，使后续任务不再各自定义冲突接口。

## 上下文
当前 production 基座是 `src/runtime/runtime.zig` 的 `ControlRuntime`、三缓冲 `RenderSnapshot` 和拥有独立 `Mixer` 的 `RuntimeRenderer`；`src/device/device.zig` 的 `RuntimeOfflineBackend`、`RuntimeMiniaudioBackend` 直接接受 renderer，绕过 `Engine.render`。`Engine` 与依赖它的 `EventRuntime` 是兼容路径。SME 目标 contract 在 `setup.md` 第 4 节定义，代码尚未实现。本任务冻结 production 扩展契约，不把新模块骨架或 legacy Engine 播放当作 SME 完成。

## 前置条件
- Zig 0.16.0 可运行。
- TASK-025 提供 production 基线准入工件：MPSC 强制交错、snapshot one-shot 终结、snapshot/owner lease 与 RT 有界重试审计结果，以及复现问题的修复后回归。疑点未复现时必须记录覆盖和限制，不宣称已确认缺陷。
- 当前 `zig build test` 基线结果可追溯；影响上述 production contract 的失败不得仅记为无关后继续。

## 实施范围
### 必须完成
- 新增 `src/music/api.zig`、`root.zig`、`ids.zig`、`errors.zig`、`contract.zig`；`api.zig` 是公共 façade，`root.zig` 只做内部聚合。
- 定义 FNV-1a 64 stable IDs、opaque generation handles、`MusicError`、`MusicRequest`、`MusicReceipt`、runtime state enum。
- 定义 Game/Control/Worker/Render API thread requirement，使用注释和 compile-time test 固化，不把第三方类型暴露到公共 API。
- 在 `src/bugu_audio.zig` 把 `music` namespace 固定转发到 `src/music/api.zig`；不导出未实现 runtime。
- 把 `build.zig` 的 SME 追加点抽到新增 `build_support/sme_steps.zig`，不改变已有 step 行为；冻结独立 build fragment 的发现/注册 API，后续任务只提交自己的 fragment，不并行编辑聚合入口。
- 扩展 TASK-025 已建立的 baseline CI workflow，在每次受支持的源码/任务变更上执行当前已落地 SME tests/fixtures；此处只启用真实已存在的目标，之后自动随注册扩展，不等待 TASK-021 才运行持续 gate。
- 建立 SME 测试发现/注册规则，使独立的 `tests/sme/*.zig` 自动或显式注册到现有 `zig build test`，且无需后续并行任务共同修改一个测试聚合文件。
- 为后续 module 预留稳定 import 规则，但不得创建返回 success 的空实现。

### 明确不包含
- scheduler、clock、bank、director、mixer group 或播放逻辑。
- C ABI。
- libogg/libopus 或 GPU 工具。

## 设计与执行细节
1. ID 均为 distinct packed/enum wrapper，避免把 StateId 当 SegmentId。
2. handle 至少含 index + generation；默认零值无效。
3. `MusicRequest` 覆盖 set state/parameter/context、stinger、duck、pause/resume/stop；preview seek 必须标为 tool-only。
4. `MusicError` 使用 `setup.md` 的冻结基线；新增错误必须有触发语义测试。
5. `MusicReceipt` 分离 request accepted、plan prepared/published/acquired/partially_executed/complete、cancel requested/effective 与 rejected；accepted/published/acquired 都不表示 mixer 已执行，取消也不能撤回已生成的 PCM。
6. build seam 只能组织构建，不产生 fake target；测试注册必须确定排序并在新增测试文件未被运行时使验证失败。

### Production 所有权与兼容扩展点

- 每个 production context 是一对 `ControlRuntime`/`RuntimeRenderer`：Control 拥有 MusicRuntime/Director/Planner 的非实时状态；Render 独占唯一 Mixer、scheduler execution cursor 和 `render_frame`。Snapshot 是 immutable 状态传递，不是第二个 mixer 或时间源。
- `Engine`/现有 `EventRuntime.postEvent(*Engine, ...)` 的公共语义保持兼容冻结。新增 `src/events/runtime_adapter.zig`（计划路径，TASK-014 所有）显式把 legacy event 解析结果转换为 production control commands；不把 `Engine.mixer` 同时交给 renderer，不创建 SME 专用并行 mixer。TASK-001 只声明 seam，TASK-014 实现，TASK-023 验证迁移文档。
- 原 `bugu_audio.runtime`、`bugu_audio.device` 公共路径保留；`bugu_audio.music` 是 SME 唯一 façade。runtime API 通过 context/handle 绑定已有 production runtime，禁止静默分配第二个 transport；preview 多 context 必须独立分配，不能绑定同一 renderer 两次。
- `RenderSnapshot` 管理长寿命 desired state；`ScheduledCommandBlock` 管理一次执行的事件。固定 `command_id`/`plan_id`/`phase_id`/epoch 的判重职责，重复 snapshot 不能重发完成的 one-shot、transition 或 stinger。

### 统一时间、版本与终结契约

- 冻结 `RuntimeContextId`、`PlanId`、`PlanEpoch`、`TransportEpoch`、`DeviceEpoch`、`AssetGeneration`，不能复用一个 generation 数字表示所有失效域。
- `render_frame` 是已生成 PCM 的生产时间轴；`submitted_frames` 是已交给backend的frame计数，两者由pending PCM区间/flush记录关联；`delivered_frames`是可选设备已播放位置观测，必须带exact/estimated/unavailable与误差。无真实播放位置时delivered为unavailable，可另显示submitted proxy，不能冒充audible。
- `ControlAcceptedInput` 至少包含 `accepted_control_frame`、`control_tick`、`input_order` 和 payload；caller 的提交时间可作诊断，不可替代权威接受 frame。
- `PlanExecutionState` 与 `CancellationReceipt` 声明 prepared/published/acquired/partially_executed/complete 的处理分支；effective cancellation 由 render command 执行 gate 的 epoch 验证/命令 claim 顺序决定。TASK-002 冻结 gate、commit horizon 和 late 细节；本任务不实现调度。
- 冻结供 TASK-004 扩展的 `ReplayInputV2` envelope 与 `ScheduleTraceV2` schema 名称；版本号表示记录格式，不改变完整 SME v1 的发布范围。
- TASK-025 的基线输出必须明确队列排序的线性化点、one-shot terminal 标记保留期、snapshot acquire 最大重试/失败路径、render pin 取得/移交/释放契约；TASK-001 不重复修复或用未经验证的假设覆盖它们。

## 接口与数据契约
- ID hash：FNV-1a 64；空字符串禁止；collision 在 bank compiler 检测。
- `MusicRequest.request_id` 单调 `u64`，0 保留为 invalid。
- 所有公共 slice 的所有权必须写明 borrowed/owned 和有效期。
- 错误返回给调用线程；render thread 只产生数值 receipt/counter。

## 文件变更
- `src/music/api.zig`：新增唯一公共 façade。
- `src/music/{root,ids,errors,contract}.zig`：新增内部聚合与公共 contract。
- `src/bugu_audio.zig`：新增固定指向 `music/api.zig` 的 `music` namespace。
- `build_support/sme_steps.zig`：新增稳定 build/test extension。
- `build.zig`：调用 extension，不改变已有 commands。
- TASK-025 已建立的 `.github/workflows/` baseline workflow：在其原路径扩展 SME 测试；具体文件名以该任务交付为准，不另建重复 CI。
- `build_support/sme_tasks/`（新增，若 setup 统一另定 fragment 路径则同步）：固定 fragment namespace、命名与注册检测，TASK-001 独占聚合入口。
- `tests/sme/contract_test.zig`：类型、hash、handle/error 语义。

## 验证
### 自动化验证
- `zig build test`：现有测试与新增 contract tests 全通过。
- 编译一个只 import `bugu_audio.music` 的最小 test，证明无 miniaudio/gpu 类型泄漏。
- 在临时测试中新增一个故意失败的 `tests/sme/*.zig`，确认 `zig build test` 能发现失败；随后恢复临时文件。
### 手工验证
- 不需要。
### 边界与失败场景
- 空 ID、request_id=0、invalid handle、重复 ID 类型误用必须编译失败或返回明确错误。

## 完成定义
- [ ] 单一公共 contract 可编译并只由 `music/api.zig` 对外导出。
- [ ] `tests/sme/*.zig` 的注册规则已用故意失败测试证明有效。
- [ ] build seam 不改变现有 demos/tests；独立 fragments 不争改聚合入口，故意漏注册会被 CI 检测。
- [ ] 持续 CI 自本任务起运行当前 SME tests，并能随后续注册自动扩展，不等待最终 validation 任务。
- [ ] 全部后续任务引用的名字均已定义或明确标记为该任务新增。
- [ ] 没有空 runtime/stub 被当作成功路径。

### 补充完成定义
- [ ] production/legacy 双路径图、唯一 mixer/clock 所有者和 adapter seam 已由 compile-time contract 验证。
- [ ] TASK-025 的复现、RT retry/lease 审计工件已核对，未把疑点写成已确认结论。
- [ ] plan 生命周期、epoch、render/delivery 时间域和 replay v2 输入 envelope 已有类型/边界测试。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：依据 production runtime 代码校正规格，补充执行、取消、设备和证据契约；本次仅修订文档，未运行基线复现或实施代码。

## 风险与注意事项
过度提前冻结内部布局会阻塞实现。只冻结公共语义和 stable extension seam；内部 struct 保持私有。


