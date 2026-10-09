# TASK-004：实现 SME trace、telemetry 与 deterministic replay contract

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Observability/Replay
- 评审角色：Runtime、QA、隐私
- 工作量等级：`M`
- 证据路径：`docs/validation/sme/TASK-004/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-004/`（原始产物）
- 执行波次：2
- 硬依赖：TASK-001
- 协作关系：所有 runtime 任务写本 contract；TASK-021 汇总验证
- 预计改动范围：`src/music/trace.zig`、`src/music/replay.zig`、`tests/sme/trace_test.zig`（新增）

## 目标
建立从 request、candidate、plan、stream、layer、bus 到 executed receipt 的统一结构化证据，使运行、offline 和 CI 可确定重放。

## 上下文
当前 production 有 ControlRuntime queue/snapshot/lease counters，RuntimeRenderer 另有 core.TelemetryCounters；Mixer 写 rendered_frames/quantums、peak/RMS 和 mixer_time_nanos，但当前 `nowNanos()` 只在 Windows 查询性能计数，其他平台返回 0；该字段不能直接作为跨平台有效 timing。device adapter 写 callback_count，但现有代码并未形成 callback duration、dropout、stream underrun 的完整 producer 证据。声明字段为 0 不证明无错误；SME 还缺少决策、执行、readiness 与设备时间线。

## 前置条件
- TASK-001 的 IDs、request、receipt 和错误语义。

## 实施范围
### 必须完成
- 定义可嵌入 production ControlRuntime/RuntimeRenderer/Mixer 的固定大小 counters 与 receipt ring，保留 legacy telemetry 兼容视图。
- control-side trace records：request、rule candidates、selector choice、plan、prefetch、group/layer、duck/sidechain、reload。
- `ReplayInputV2`、`ScheduleTraceV2` 版本化 binary 格式与 JSON/CSV export；版本化输入必须覆盖控制接受时间、worker readiness 和 device discontinuity。
- 为每个 export 字段声明 `public`、`sensitive` 或 `local_only`，默认 exporter 只输出 `public`；路径归一化为 repo-relative 或 asset ID/hash。
- seed、bank build ID/hash、generation、sample rate、quantum、capacity/platform profile、整数规则版本、初始 save-state hash 纳入 replay header；control tick/input ordering 纳入逐事件记录。
- trace overflow 显式计数/错误；不得阻塞 render。

### 明确不包含
- 各子系统具体决策逻辑。
- GUI 绘制。
- 手写“示例 trace”作为通过证据。

## 设计与执行细节
1. render record 固定字段，无 string/allocator。
2. control thread 把 IDs 映射到字符串并序列化。
3. replay 比较 canonical schedule records 跨平台 bit-identical；PCM 比较由 TASK-021 处理，使用明确同 backend/target 容差。原始 wall-clock diagnostics 和硬件 timing 不参与 schedule bytes。
4. trace schema 版本独立于 MusicBank，但记录 bank version/hash。
5. p50/p95/p99/p999 在非实时线程聚合原始 samples。
6. schema 变更必须包含 version migration/rejection 测试；不得把用户名、机器名、绝对路径、环境变量值、设备序列号或私有 stem 文件名写入 deterministic fields。

### Replay v2 输入必须完整

1. request envelope 记录 `request_id`、producer/order、`accepted_control_frame`、`control_tick`、`input_order`、规范化 payload。接受 frame 是 Control 在其 tick 接受输入时观察的 render frontier；提交墙钟或 API enqueue 时刻只作诊断，不改变接受 oracle。
2. Worker event 记录 job/asset/generation/transport epoch、operation（prefetch/decode/seek）、ready/not-ready/failed/cancelled、可用 PCM frame 区间/数量、内容 hash、接受 tick/frame/order。Planner 的 resident/readiness 决定与 completion 接受的先后必须能复现。
3. Device event 记录 lost/reopen/reopen_failed、device epoch、render/submitted frontier和可选delivered观测/质量/误差、pending flush 区间、恢复 policy 与 result；必要的 budget pressure、voice reservation admission 和明确外部 acoustic 输入也必须记录为有界输入，不能在 replay 时重新采样不可控状态。
4. replay 在记录的接受 tick 注入上述外部事实，仍运行真实 Director/Planner/Scheduler/RuntimeRenderer。需要 PCM 时使用真实 decoder/worker 预先取得并校验内容，在记录的 ready tick 才释放 readiness；禁止以机器当次 I/O 快慢重新决定计划，或把固定成功结果冒充 decoder。
5. 无 worker/device/readiness 事实的旧格式只允许显式迁移到其可证明覆盖的 resident/no-discontinuity 子集；production replay 缺字段、内容 hash 不匹配或版本未知均明确拒绝，不能静默补 ready=true。

### Canonical schedule 与可观测性分层

- `ScheduleTraceV2` 明确字段宽度、little-endian encoding、enum code、schema version、稳定 ID 表示、整数 frame/tick、同 frame sequence 和 phase 顺序；禁止直接 dump Zig struct、padding、pointer、平台 size_t 或 map iteration order。
- 决策涉及的 parameter/automation 值在 ingress 以冻结 fixed-point/量化规则规范化，拒绝 NaN/Inf；cross-platform tie-break 不读取墙钟、地址、线程 ID 或未记录的 host completion 顺序。PCM 与 profiler 浮点/时钟数据单独保存。
- request trace 分开 enqueue observation、accepted_control_frame、planned、published/acquired诊断及必需renderer admission gate输入、executed、cancel requested/effective；含 plan/phase、plan_epoch/transport_epoch、asset generation、commit horizon、result/reason。partial plan 的事实不能压成一个 cancelled 布尔值。
- Schedule replay 不以 snapshot publish 的 host 时间决定执行；trace sink disabled/overflow 不改变实时决策。但证据丢失时报告 `trace_incomplete`，不得继续给出 determinism/stress PASS。

### 指标 producer、单位与正向自检

| 指标 | 必须指定的 producer/计量点 |
|---|---|
| callback duration/deadline miss | RuntimeMiniaudio callback 入口/出口的经审计单调时钟；duration 纳秒、deadline 为该 callback frame_count/sample_rate |
| render/control/planner time | 各实际执行区域的 enter/exit，原始 sample 固定 ring，非实时聚合；sample_count 必须大于零 |
| rendered/submitted/pending/flushed + delivered observation | RuntimeRenderer、RuntimeFixedQuantumAdapter 各自写者，按 frame 和 epoch 记录，不混淆 hardware playback |
| `stream_starvation` | render 取必需 PCM 不足的实际分支，附 group/layer/generation/缺失 frames；与设备端 underrun 分开 |
| `callback_deadline_miss` | 实测 callback duration 超过 frame_count/sample_rate 预算的分支，不能当作已证实 physical glitch |
| `backend_reported_underrun` | backend/driver 明确报告的 underrun，缺此能力时标 unsupported |
| `physical_glitch` | loopback/外部录音等独立观测的实际输出缺陷；软件 counters 不生成这一事实 |
| command/receipt/completion/trace overflow | 对应 bounded channel 的实际拒绝/丢失分支；不同原因不合并 |
| cancellation/stale/retry/lease | render gate、snapshot acquire/pin fallback、retire/reclaim 实际路径，包含有效计量样本数与高水位 |

- 每个指标 descriptor 含 owner、unit、scope、reset epoch、support/validity、sample_count、溢出行为；未接通 producer 使用 `unsupported`/`invalid`，不能发布正常 0。
- 正向 fault injection 是指标 gate：故意拖慢 callback、制造 stream 空 ring、塞满各 queue、注入 stale epoch/flush；断言匹配计数增加且报告失败。timing 同时用已知有界工作负载校验非零样本和单位；不得直接写 counter 后声称 producer 工作。
- TASK-004 提供测试 harness 与 schema；TASK-002/011/014 负责在真实路径接线，TASK-021 汇总短测试，TASK-022 必须先通过这些自检才允许启动 8 小时 qualification。

### 本任务准入与后续接线边界

本任务只依赖 TASK-001/基线，交付 codec、schema、canonical 黄金向量、bounded ring、注入驱动和 metric descriptor/有效性测试。固定编码向量仅证明序列化，不可作为音乐运行证据。真实 Director/Planner/streaming/设备消费者由 TASK-002/011/014 接入，TASK-026 和 TASK-021 使用本格式执行真实 replay；不得反向等待这些任务才冻结 schema，造成隐含依赖环。

## 接口与数据契约
至少包含 `accepted_control_frame/planned_frame/executed_frame`、from/to、source/fill/target、cue、selector epoch、result/reason、generation。Trace reason 使用 enum，不使用自由文本作为机器判据。Export header 只允许 `setup.md` 4.10 列出的环境字段，并携带 schema version 与字段分类版本。

## 文件变更
- 新增 trace/replay modules/tests。
- 本任务不修改 `src/runtime/runtime.zig`、`src/device/device.zig` 或 legacy `Engine`；TASK-002/005/011/014 在各自集成点嵌入本任务类型。测试使用本任务的 schema/ring/injection harness，避免隐含共享文件依赖。

## 验证
### 自动化验证
- `zig build test`。
- 本任务执行 ReplayInputV2/ScheduleTraceV2 跨平台编码黄金向量、JSON round-trip、ring overflow、unknown version、重复/乱序 tick-order 拒绝和注入排序测试。后续真实 runtime 同输入重复/跨平台 canonical schedule bytes 相同由 TASK-026/021 复验；只保存 request 列表不满足 production replay。
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

### 补充完成定义
- [ ] 完整 ReplayInputV2 可表达并按确定顺序注入 I/O readiness/device 事件，真实 replay 消费者接线归属明确；旧请求-only 输入不会被误标为 production replay。
- [ ] canonical bytes 的跨平台字段、定点规则、稳定排序和版本拒绝有黄金向量。
- [ ] 每个 gate 指标 descriptor 明确实际 producer 接线 Owner、有效性/样本数与 fault-injection oracle；本任务验证缺失 producer 的测量为 invalid/unsupported、不能通过门禁，下游在各自准入测试实测 producer。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：依据 production runtime 代码校正规格，补充执行、取消、设备和证据契约；本次仅修订文档，未运行基线复现或实施代码。

## 风险与注意事项
不要把日志时间戳或线程调度抖动写入确定性比较字段。


## Renderer admission输入闭环
ReplayInputV2还必须包含command/invalidation batch的admission/visibility gate输入：稳定batch ID和内容hash、render gate序号与frame、observed commit_horizon、admitted/late/rejected、同gate顺序。Control接受与Render可见之间的延迟不由accepted_control_frame唯一决定，故不能只记录Control/worker/device事件。TASK-002是producer，TASK-026/021集成验证；本任务交付schema/codec/driver与golden，无隐含反向依赖。Replay在对应gate放行重新计算的真实batch，epoch校验和phase outcome仍由scheduler执行，不把executed/cancelled结果伪装输入。强制两种publication延迟形成不同live cancel winner，再跨Windows/Linux重放各自日志，winner及canonical schedule须一致；缺gate/错hash/late disposition不可静默补齐。
