# TASK-023：完成 SME release packaging、legacy迁移与用户文档

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Release/Developer Experience
- 评审角色：Package、迁移、文档、QA
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-023/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-023/`（原始产物）
- 执行波次：17
- 硬依赖：TASK-017、TASK-018、TASK-019、TASK-020、TASK-021、TASK-022
- 协作关系：`src/bugu_audio.zig`和build/package surface最终所有者；TASK-024审查本产物
- 预计改动范围：`build.zig`、`build.zig.zon`（若 package 尚未存在则新增）、`build_support/sme_steps.zig`、`src/bugu_audio.zig`、`tools/package_sme.ps1`（新增）、`tools/validate_sme_docs.ps1`（新增）、`docs/sme/`（新增）、`README.md`

## 目标
交付可被游戏团队安装、构建、集成、制作资产、迁移legacy音乐、运行工具和排障的完整v1 package。

## 上下文
源码和tests存在不等于可交付。当前API/asset/device仍标prototype；SME必须明确支持矩阵、ownership和实际命令。

## 前置条件
- 完整validation、device/stress通过。
- CLI/GUI/debug/demo稳定。

## 实施范围
### 必须完成
- release package 固定根布局：`build.zig`/`build.zig.zon`、`src/` runtime、`bin/` compiler/authoring/debugger、`schemas/`、`examples/`、`docs/`、`licenses/`、`manifest.json`；目录缺失或多出未清单文件均失败。
- public Zig API surface收口与compile-only consumer sample。
- legacy event/music bus与WAV bank迁移指南和工具命令。
- production runtime integration、ownership/threading、save/reload、执行/取消 receipt、render/delivery 时间域和 error troubleshooting。
- authoring、tempo/cue/fill/layer/sidechain/streaming教程。
- platform/codec/channel/device/toolchain矩阵。
- validation/release命令与已知限制。
- README链接与版本标识。

### 明确不包含
- C ABI，除非另有已批准 ADR。
- 声称未验证的平台。

## 交付检查点

XL 工作先登记以下具名子交付物的 Owner、Reviewer、commit 和独立 evidence；不得只提交一份“文档完成”摘要。

| 子交付物 | 输入 | 输出 | 独立验证与通过判据 |
|---|---|---|---|
| R23-A：构建可安装 package | 已通过 qualification 前置的 runtime/tools、build fragments | package script、固定 layout、manifest schema/allowlist、public consumer | clean checkout 构建；每个文件 hash/version/license 有记录，额外文件拒绝；公开 production runtime SFX+music consumer 可运行 |
| R23-B：验证 legacy 显式迁移 | R23-A、TASK-014 event adapter、旧 event/WAV fixture、compiler diagnostics | `docs/sme/migration.md`、迁移命令/不可转换项诊断、legacy 与新 API 映射 sample | 旧 Engine/EventRuntime 行为不变；新 adapter 句柄/receipt/lease 测试通过；缺 tempo/cue 明确拒绝而不猜测 |
| R23-C：执行用户文档命令 | R23-A/B、compiler/GUI/debugger/public runtime、ReplayInputV2 | quick-start/runtime-integration/authoring/troubleshooting/support 文档、命令清单与校验脚本 | 从 clean package 执行 build/preview/replay/错误探针；shared SFX+music、取消/device 恢复示例与实际 API 一致，无内部 imports |
| R23-D：核对 release 标识与许可 | R23-A/B/C evidence、设备/codec/channel 支持矩阵、第三方 commits/license | README、release manifest、版本/hash/license/support 摘要 | 逐项比对 artifact 与 manifest；无未验证平台声明、私有路径/数据泄漏、未清单文件；完整 docs command gate 通过 |

R23-A → R23-B → R23-C → R23-D 顺序合并；每个子交付物单独审查输入/输出/命令与结果，四项全部通过且 evidence 指向当前 commit 后才可进入 `REVIEW`。

## 设计与执行细节
1. `tools/package_sme.ps1` 从 clean checkout 构建到 `zig-out/sme-package/`，先创建 manifest allowlist，再拒绝任何未列入 manifest 的文件；不依赖本机 cache 或绝对路径。
2. submodule init和MSVC/GPU要求明确。
3. `tools/validate_sme_docs.ps1` 从文档中维护的命令清单执行 quick start、build、validate、preview、package consumer 和 troubleshooting probes；任何命令漂移使 gate 非 0。
4. migration不自动猜tempo/cue；无法转换项明确诊断。
5. 旧 Engine/EventRuntime/WAV 路径继续可用且兼容冻结，不称其为 SME 功能；production SFX+SME 共存必须使用 TASK-014 显式 event adapter。

### 必须写清的集成与迁移边界

- quick start 首例必须是 public production Runtime context：ControlRuntime 拥有 MusicRuntime，RuntimeRenderer 独占 mixer/scheduler/render_frame，RuntimeOfflineBackend/RuntimeMiniaudioBackend 驱动 renderer。不能只写 Engine 初始化后提交 music 而实际 backend 绕过该 Engine。
- `runtime-integration.md` 给出 Game/Control/Worker/Render API matrix、单 mixer/clock、SFX adapter、group/bank/stream/snapshot lease 和 shutdown drain 的可执行完整例子；multi-device/author preview 明确使用独立 context，不能共享 renderer。
- `migration.md` 并列旧 EventRuntime(*Engine) 与新 event adapter，说明 handle/receipt/queue-full/borrowed PCM ownership 映射。保留旧行为回归，不将即时 Engine API 偷换为异步提交；调用方必须显式迁移。
- 明确 accepted/planned/published/acquired/executed/cancellation_effective 的区别、commit horizon、短 ramp stop、multi-fill 已执行前缀和 pause/resume 重规划；“取消成功”不能描述尚未得到 render receipt 的请求。
- 描述 `render_frame`、backend handoff的`submitted_frames`、可选played观测`delivered_frames`及quality/误差、pending PCM 和 device epoch；stop/pause 在已 commit buffer 后才可生效，设备丢失会明确 flush 未交付区间并由 Control 恢复。不能承诺撤回驱动已收样本或把 render-ahead 当实际 audible 进度。
- `troubleshooting.md` 提供 ReplayInputV2 导出/重放的实际命令：记录 accepted control frame/tick/order、worker readiness、device events、profile/hash；说明 canonical schedule 跨平台比较与 PCM/timing 非 canonical 数据的差异，旧 request-only trace 的拒绝/有限迁移规则。
- 支持矩阵引用真实 callback/timing/counter producer 与 fault-injection/8 小时 evidence，未验证/unsupported 指标和平台明确标注；不把缺失计量点的零值包装为性能保证。

### Package consumer 额外失败用例

- 从 clean package 仅靠公开 imports 同时播放 SFX+music，验证一个 mixer/context 的 bus 输出、music stop 不停 SFX、两者 shutdown 后 lease 清零；禁止依赖源码内部 import 或直接 mixer 操作。
- 保留 legacy Engine/EventRuntime/WAV consumer；编译/运行结果与旧 contract 一致。错误混接旧 handle、新 runtime 或重复绑定 renderer 必须拒绝。
- package 文档示例重放多 fill 取消、失配 build ID、device pending flush、late worker completion；所有 command/version/schema 与 manifest 对齐，缺 readiness/device 输入不能误判 replay PASS。

## 接口与数据契约
`manifest.json` 固定列 schema/API/tool versions、Zig minimum version、submodule commits、supported targets、package-relative path、artifact kind、bytes、SHA-256、license ID 和 executable bit；manifest 自身有 schema version，路径按 Unicode/大小写冲突规则校验。

## 文件变更
- `tools/package_sme.ps1`、`tools/validate_sme_docs.ps1` 与固定 `zig-out/sme-package/` layout。
- `docs/sme/quick-start.md`、`runtime-integration.md`、`authoring-guide.md`、`migration.md`、`troubleshooting.md`、`support-matrix.md`。
- README。

## 验证
### 自动化验证
- clean package build。
- consumer sample 仅使用 public imports，通过 ControlRuntime/RuntimeRenderer + RuntimeOfflineBackend 同时运行 adapter SFX 与 SME，生成非静音 PCM/真实执行 receipt；再运行 RuntimeMiniaudioBackend smoke。
- CLI/GUI/debug/demo从package运行。
- docs command script执行。
### 手工验证
- 新目录按quick start完成project build和offline preview。
### 边界与失败场景
- missing submodule、unsupported platform、旧bank、schema mismatch、无GPU/无device。

## 完成定义
- [ ] clean consumer无需源码内部路径。
- [ ] 固定 package layout 中每个文件均由 manifest 覆盖，hash/license/version 完整且无额外文件。
- [ ] 文档命令由 `tools/validate_sme_docs.ps1` 从 clean package 实际执行。
- [ ] 文档命令与实际surface一致。
- [ ] 支持/限制无夸大。

### 补充完成定义
- [ ] quick start 和 clean consumer 走公开 production runtime/backend；legacy migration 说明 adapter 和所有权而非只改名称。
- [ ] 取消/commit horizon、ReplayInputV2、render-ahead/device flush 和真实测量覆盖进入可执行文档校验。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：依据 production runtime 代码校正规格，补充执行、取消、设备和证据契约；本次仅修订文档，未运行基线复现或实施代码。

## 风险与注意事项
不要把内部测试fixture当作用户资产模板；模板必须最小、合法、可说明。

