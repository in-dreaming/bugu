# TASK-019：实现 in-dreaming/gpu SME runtime 可视调试器

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：GPU Debug Tooling
- 评审角色：Observability、GPU、实时安全
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-019/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-019/`（原始产物）
- 执行波次：9
- 硬依赖：TASK-015、TASK-018
- 协作关系：读取TASK-004 trace和runtime snapshots；不得修改authoring project语义
- 预计改动范围：`tools/sme_debug/`（新增）、`build_support/sme_steps.zig`、`zig-out/sme-validation/TASK-019/runtime-debug-smoke.json`

## 目标
交付连接运行中MusicRuntime或replay trace的调试器，显示transport、state/candidates、transition phases、layers、Bus/sidechain、stream和generation。

## 上下文
作者应用面向资产编辑；runtime debugger面向运行诊断，职责分开。两者可复用GPU adapter和只读widget，但debugger不能编辑或隐式修复bank。

## 前置条件
- authoring UI基础/GPU路径通过。
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

1. versioned snapshot/trace view model 与 live handshake 通过 schema/protocol review。
2. offline replay、live transport/state/layer/bus/stream/generation panels 逐组通过 headless smoke。
3. GPU shell、断连/溢出/版本不兼容诊断与 artifact schema 通过 tooling/QA review。
4. 以上检查点全部有当前 commit 证据后才可整体进入 `REVIEW`。

## 设计与执行细节
1. 只消费 versioned snapshot/trace，不能读内部 mutable pointers。Live handshake 固定交换 protocol major/minor、snapshot/trace schema versions、bank build ID/generation、capability bits、max message bytes 和 session nonce；major/capability 不兼容立即拒绝。
2. UI采样慢不得反压audio/control。
3. dropped records/trace overflow明显显示。
4. replay与live采用同一view model。
5. headless trace仍是correctness source。

## 接口与数据契约
`SmeDebugSnapshotV1` 是 length-delimited 只读 owned copy；live protocol 使用 request/response sequence 和 bounded message size。失败码至少区分 `ConnectionRefused`、`HandshakeTimeout`、`ProtocolVersionMismatch`、`SnapshotVersionMismatch`、`UnsupportedCapability`、`MessageTooLarge`、`RuntimeClosed`。新增 build steps `sme-debug-build` 与 `sme-debug-smoke`。

## 文件变更
- 新增 debug tool/build helper 与 `zig-out/sme-validation/TASK-019/runtime-debug-smoke.json`；脱敏摘要写入 TASK-019 evidence。

## 验证
### 自动化验证
- `zig build sme-debug-smoke`加载TASK-020前置最小fixture/replay（若TASK-020尚未完成，使用TASK-017测试fixture）。
- handshake major/minor/capability、snapshot version、message size、timeout、overflow、disconnect、runtime closed、replay EOF。
### 手工验证
- live运行中触发state/fill/stinger/duck/reload，观察对应panel。
### 边界与失败场景
- runtime关闭、trace版本旧、GPU设备丢失、UI帧率低。

## 完成定义
- [ ] 必需视图均由真实trace/snapshot驱动。
- [ ] 工具不影响audio timing。
- [ ] live/replay结果一致。
- [ ] 使用 in-dreaming/gpu。
- [ ] Live handshake/snapshot version、消息上限和全部连接失败码已冻结并有 smoke assertions。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
不要为可视效果向runtime增加非实时安全查询。
