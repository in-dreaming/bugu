# TASK-004：实现 SME trace、telemetry 与 deterministic replay contract

## 元数据
- 状态：待实施
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

## 接口与数据契约
至少包含 `request_frame/planned_frame/executed_frame`、from/to、source/fill/target、cue、selector epoch、result/reason、generation。Trace reason 使用 enum，不使用自由文本作为机器判据。

## 文件变更
- 新增 trace/replay modules/tests。
- 本任务不修改 `Engine`；TASK-002/005/014 在各自集成点嵌入本任务类型，避免波次 1 共享文件冲突。

## 验证
### 自动化验证
- `zig build test`。
- 同输入两次 binary trace 相同；JSON round-trip；ring overflow；unknown trace version；乱序 request replay 拒绝。
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

## 风险与注意事项
不要把日志时间戳或线程调度抖动写入确定性比较字段。
