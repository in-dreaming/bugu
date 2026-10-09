# TASK-019：实现 in-dreaming/gpu SME runtime 可视调试器

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：GPU Debug Tooling
- 评审角色：Observability、GPU、实时安全
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-019/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-019/`（原始产物）
- 执行波次：13
- 硬依赖：TASK-015、TASK-018、TASK-027
- 协作关系：读取TASK-004 trace和runtime snapshots；不得修改authoring project语义
- 预计改动范围：`tools/sme_debug/`（新增）、`build_support/sme_steps.zig`、`zig-out/sme-validation/TASK-019/runtime-debug-smoke.json`

## 目标
交付连接运行中MusicRuntime或replay trace的调试器，显示transport、state/candidates、transition phases、layers、Bus/sidechain、stream和generation。

## 上下文
作者应用面向资产编辑；runtime debugger面向运行诊断，职责分开。两者可复用GPU adapter和只读widget，但debugger不能编辑或隐式修复bank。

## 前置条件
- TASK-027 的窗口/input/text/focus capability 和 TASK-018 已审查的只读 widget/GPU 路径通过；不得另外造一套输入或 RHI。
- stinger/duck/acoustic trace字段存在。

## 实施范围
### 必须完成
- live snapshot/trace接入与offline replay打开。
- tempo/meter/cue transport、committed/pending state。
- candidate rejection、selector history、source/fill/target phases。
- group/layer real/virtual/drop、gain/filter/send。
- bus meters、detector envelope、gain reduction。
- stream watermarks/prefetch/decode/underrun。
- generation/hot reload/rollback timeline。
- automated replay smoke。

### 明确不包含
- 修改runtime状态的cheat controls。
- authoring编辑。

## 交付检查点

- `T019-A / BoundedDebugProtocol`：输入为TASK-004 versioned trace、TASK-014/015/016 runtime snapshot 与 bounded observer seam；产物为 `tools/sme_debug/protocol.zig`、`view_model.zig`（计划新增）、handshake/snapshot/trace schema golden 与 owned-copy receiver；独立测试 length/version/capability/sequence/limit/timeout/closure，malformed 输入 fail closed。
- `T019-B / ReplayStateInspector`：输入为T019-A view model、TASK-017 真实 preview/replay 输入与 trace；产物为 replay reader 和 transport/state/selector/candidate/layer/stream/generation view model；独立测试从真实 trace 重建状态、accepted request/readiness/worker/device 输入可区分、overflow/gap/EOF、不完整录制拒绝“确定性通过”。
- `T019-C / LiveGpuPanels`：输入为T019-A live receiver、T019-B replay model、TASK-027/TASK-018 GPU/input widgets；产物为复用 TASK-027/TASK-018 基础的 GPU panels、live/replay 统一模型、bus/sidechain meters 与 timeline；测试同一 sequence 的 live/replay 字段相同、UI 慢帧/断连不反压 runtime、真实 GPU 绘制 smoke。
- `T019-D / DebuggerRecoveryEvidence`：输入为T019-C 可运行调试器、T019-A 协议失败 fixtures 和脱敏 schema；产物为版本化 `runtime-debug-smoke.json`、disconnect/reconnect/GPU-loss 诊断与只读权限审查；测试错误显示、限流/overflow 计数、runtime shutdown、恢复后 generation 对齐和脱敏 artifacts。
- 顺序 A→B/C→D；每片独立 commit/Reviewer/commands/artifact hash，全部通过后才可整体进入 `REVIEW`。

## 设计与执行细节
1. 只消费 versioned snapshot/trace，不能读内部 mutable pointers。Live handshake 固定交换 protocol major/minor、snapshot/trace schema versions、bank build ID/generation、capability bits、max message bytes 和 session nonce；major/capability 不兼容立即拒绝。
2. UI采样慢不得反压audio/control。
3. dropped records/trace overflow明显显示。
4. replay与live采用同一view model。
5. headless trace仍是correctness source。
6. Timeline 必须分别显示 request 的 accepted frame、计划/执行 frame、worker completion/readiness 的 accepted frame、device discontinuity/恢复策略和 callback quantum 数据；replay 不把 recorded commands 当输入再次“播放成功”，而应显示 TASK-004 决策重算对比结果。缺失/丢记录时标为 incomplete，不隐藏 overflow。

## 接口与数据契约
`SmeDebugSnapshotV1` 是 length-delimited 只读 owned copy；live protocol 使用 request/response sequence 和 bounded message size。失败码至少区分 `ConnectionRefused`、`HandshakeTimeout`、`ProtocolVersionMismatch`、`SnapshotVersionMismatch`、`UnsupportedCapability`、`MessageTooLarge`、`RuntimeClosed`。新增 build steps `sme-debug-build` 与 `sme-debug-smoke`。

## 文件变更
- 新增 debug tool/build helper 与 `zig-out/sme-validation/TASK-019/runtime-debug-smoke.json`；脱敏摘要写入 TASK-019 evidence。

## 验证
### 自动化验证
- 新增 `zig build sme-debug-smoke` 加载 TASK-017 的真实 preview fixture/replay；TASK-020 完成后再纳入更完整 demo，不能把尚未完成的后置任务当本任务前置。
- handshake major/minor/capability、snapshot version、message size、timeout、overflow、disconnect、runtime closed、replay EOF。
### 手工验证
- live运行中触发state/fill/stinger/duck/reload，观察对应panel。
### 边界与失败场景
- runtime关闭、trace版本旧、GPU设备丢失、UI帧率低。

## 完成定义
- [ ] 本任务已交付 headless model/protocol tests 通过 TASK-001 稳定注册 seam 加入既有 `zig build test`/PR gate；GPU/input smoke 在具备条件的受管 runner 显式持续执行并单独报告，证据随子交付产生，不等待 TASK-021 首次接入 CI。
- [ ] 必需视图均由真实trace/snapshot驱动。
- [ ] 工具不影响audio timing。
- [ ] live/replay结果一致。
- [ ] 使用 in-dreaming/gpu。
- [ ] Live handshake/snapshot version、消息上限和全部连接失败码已冻结并有 smoke assertions。
- [ ] 真实 accepted-frame 外部输入与重算/执行输出在 timeline 可分辨，incomplete replay 不被报告为一致。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐实际依赖、量化/输入契约、独立审查产物与持续 gate；仅修订任务文档，状态保持 `TODO`。

## 风险与注意事项
不要为可视效果向runtime增加非实时安全查询。


## Host端Debug Bridge所有权
TASK-014交付RuntimeObserverV1有界owned-copy publication；本任务新增 `src/music/debug_bridge.zig`（opt-in build，默认关闭）拥有host侧非实时transport endpoint、handshake/length/version/timeout与subscription生命周期，tools/sme_debug拥有client。明确transport选择和默认仅本机连接，远端连接需显式配置；不让endpoint线程读Mixer内部或阻塞render。断连/slow client/恶意超长包/版本错/shutdown时释放observer与buffers，允许丢debug数据但不能丢资源回收receipt；断言开启/关闭/慢client时canonical schedule一致且callback无额外wait/allocation。
