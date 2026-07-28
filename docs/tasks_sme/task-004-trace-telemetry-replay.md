# TASK-004：实现 SME trace、telemetry 与 deterministic replay contract

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Observability/Replay
- 评审角色：Runtime、QA、隐私
- 工作量等级：`M`
- 证据路径：`docs/validation/sme/TASK-004/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-004/`（原始产物）
- 执行波次：1
- 硬依赖：TASK-001
- 协作关系：所有 runtime 任务写本 contract；TASK-021 汇总验证
- 预计改动范围：`src/music/trace.zig`、`src/music/replay.zig`、`tests/sme/trace_test.zig`（新增）

## 目标
建立从 request、candidate、plan、stream、layer、bus 到 executed receipt 的统一结构化证据，使运行、offline 和 CI 可确定重放。

## 上下文
当前 telemetry 只有 engine counters，无法证明 state request 在哪个音乐边界执行，也无法诊断 selector/cue/fill/underrun。

## 前置条件
- TASK-001 的 IDs、request、receipt 和错误语义。

## 实施范围
### 必须完成
- 定义可嵌入 engine/mixer 的固定大小 render counters 与 receipt ring。
- control-side trace records：request、rule candidates、selector choice、plan、prefetch、group/layer、duck/sidechain、reload。
- 版本化 binary replay input 与 JSON/CSV export。
- 为每个 export 字段声明 `public`、`sensitive` 或 `local_only`，默认 exporter 只输出 `public`；路径归一化为 repo-relative 或 asset ID/hash。
- seed、bank build ID、generation、platform profile、request ordering 纳入 replay header。
- trace overflow 显式计数/错误；不得阻塞 render。

### 明确不包含
- 各子系统具体决策逻辑。
- GUI 绘制。
- 手写“示例 trace”作为通过证据。

## 设计与执行细节
1. render record 固定字段，无 string/allocator。
2. control thread 把 IDs 映射到字符串并序列化。
3. replay 比较 schedule records bit-identical；PCM 比较由 TASK-021 处理。
4. trace schema 版本独立于 MusicBank，但记录 bank version/hash。
5. p50/p95/p99/p999 在非实时线程聚合原始 samples。
6. schema 变更必须包含 version migration/rejection 测试；不得把用户名、机器名、绝对路径、环境变量值、设备序列号或私有 stem 文件名写入 deterministic fields。

## 接口与数据契约
至少包含 `request_frame/planned_frame/executed_frame`、from/to、source/fill/target、cue、selector epoch、result/reason、generation。Trace reason 使用 enum，不使用自由文本作为机器判据。Export header 只允许 `setup.md` 4.10 列出的环境字段，并携带 schema version 与字段分类版本。

## 文件变更
- 新增 trace/replay modules/tests。
- 本任务不修改 `Engine`；TASK-002/005/014 在各自集成点嵌入本任务类型，避免波次 1 共享文件冲突。

## 验证
### 自动化验证
- `zig build test`。
- 同输入两次 binary trace 相同；JSON round-trip；ring overflow；unknown trace version；乱序 request replay 拒绝。
- 使用包含绝对路径、用户名样式、机器名和设备序列号的输入执行 export，断言默认 JSON/CSV 不泄漏这些值；显式 local-only export 不得进入 CI artifact。
### 手工验证
- 不需要。
### 边界与失败场景
- trace sink 关闭不改变 runtime 决策。
- export I/O 失败不进入 render thread。

## 完成定义
- [ ] trace/replay schema 版本化且有 round-trip。
- [ ] render 写路径满足实时红线。
- [ ] overflow/disabled/error 均可观测。
- [ ] 后续任务无需自建日志格式。
- [ ] 字段分类、默认脱敏和公开 export allowlist 有 schema 与自动测试。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
不要把日志时间戳或线程调度抖动写入确定性比较字段。
