# TASK-002：实现绝对 render-frame scheduler 与原子 command block

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Core/Realtime Scheduler
- 评审角色：Mixer、设备、实时安全
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-002/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-002/`（原始产物）
- 执行波次：3
- 硬依赖：TASK-001、TASK-004
- 协作关系：TASK-005/007/011/013/014 消费本任务 contract；`src/runtime/runtime.zig` 的 scheduler execution seam 由本任务先修改
- 预计改动范围：`src/runtime/runtime.zig`、`src/device/device.zig`、`src/mixer/mixer.zig`、`src/music/scheduler.zig`（新增）、`tests/sme/scheduler_test.zig`（新增）；legacy `src/core/engine.zig` 仅兼容回归

## 目标
使 control side 可以提交按绝对 `u64 render_frame` 排序的有界命令组，mixer 在 quantum 内精确 sample offset 执行，并返回实际 frame receipt。

## 上下文
当前 production 已有 bounded MPSC、ControlRuntime、immutable RenderSnapshot、RuntimeRenderer 和 runtime backends，但尚无 future-frame command block。RuntimeRenderer 自有 Mixer，legacy Engine 是另一条路径；只改 Engine 不会覆盖 production。仅在 quantum 边界启动无法满足任意 BPM；逐 stem 即时启动也不原子。

## 前置条件
- TASK-001 提供 request/receipt/error/handle 契约。
- TASK-004 提供 ScheduleTraceV2、execution/cancellation receipt 编码、指标 producer/overflow 契约；TASK-025 的强制交错与 RT 审计准入已通过。
- 明确 RuntimeFixedQuantumAdapter 的 quantum、pending PCM 和不规则 callback 行为；保留旧 FixedQuantumAdapter 的兼容回归。

## 实施范围
### 必须完成
- 建立单调绝对 render frame，设备与 offline 共用。
- 实现固定容量 `ScheduledCommandBlock` 和原子 command group。
- control side 预排序 `(execute_frame, sequence)`；render 不排序/分配。
- quantum 内按命令 frame 切分有界 render spans。
- 支持 prepared、published、acquired、partially_executed、complete 全阶段取消判定；在 render command gate 验证 epoch，拒绝 stale command，产出 execution/cancellation receipt。
- queue/block high-water、overflow、late command telemetry。
- 冻结 `SchedulerCapacityProfile`：request/command/receipt capacity、每 block/group 命令上限、emergency lane、允许的最小 plan lead 与 late 判定预算；所有单位为 frames 或 entry count。

### 明确不包含
- 音乐 clock、state/planner。
- voice group 具体命令；只提供 typed payload seam。
- worker I/O 或 codec。

## 设计与执行细节
1. block 覆盖明确 `[start_frame,end_frame)`；只接受窗口内或未来 block 命令。
2. 同 group 全部命令容量预检成功后一次发布；失败不部分写入。
3. late command 默认拒绝并 receipt=`late`；紧急 stop 走独立 bounded emergency lane 和最短 ramp。
4. production RuntimeFixedQuantumAdapter 以唯一 RuntimeRenderer 时钟渲染，非固定 callback 不改变 schedule；单独维护 submitted_frames、可选delivered_frames观测、pending PCM frame 区间与 device epoch。
5. counter 使用 atomics；详细 reason 在 control side 格式化。
6. 默认 capacity 必须由静态内存占用计算和 queue-full 压力测试共同证明；不得使用可增长容器或隐藏常量。TASK-014 只能在同一 profile 上补 game/control request queue 字段。

### 唯一生产执行路径

`ControlRuntime -> immutable RenderSnapshot + ScheduledCommandBlock -> RuntimeRenderer -> 唯一 Mixer -> RuntimeOfflineBackend/RuntimeMiniaudioBackend`。Control 只构建计划与不可变块；Render 是唯一 command execution 和 cursor 写者。SFX、music、bus 共用这一 mixer 和 `(execute_frame, sequence)` 顺序，禁止调用 `Engine.render` 绕过 production block 消费路径来证明 scheduler。

### 取消、commit horizon 与线性化

| Plan 状态 | 必须行为 |
|---|---|
| prepared | 尚无 render 可见命令，Control 本地取消，释放 reservation/lease，记录 terminal receipt |
| published | 发布 immutable block 后不得原地擦写；提交 bounded invalidation intent，只有 render gate 接受后才报告 cancellation effective |
| acquired | 已 acquire 的 block 仍逐原子 command group 检查 plan/transport epoch；持有 snapshot lease 不构成执行许可 |
| partially_executed | 保留已执行 phase 的事实和 group lease，取消尚未 claim 的后缀，终态为 `superseded_after_partial`；stop/pause/reload 由独立新 epoch 命令完成收尾/冻结/迁移 |
| complete | 回执 already-complete/too-late；不能伪造 cancelled 或回滚已输出样本 |

1. Render 在每个原子 group 执行前的有界 gate，先处理同 frame system lane invalidation（优先于普通阶段），再校验 epoch 并 claim 命令；普通命令仍按 `(execute_frame, sequence)` 排序；这三个动作由唯一 render owner 串行化。取消与 command claim 的顺序是线性化顺序，不是控制线程发布时刻，也不是 acquire 时刻。跨 producer 的 intent 序号按 TASK-025 准入契约产生。
2. 已 claim 的同 frame group 不可被中途拆开；gate 之后到达的取消在下一 gate 生效，并明确回报已执行前缀。Control 只能返回 accepted，等待 receipt 后才能宣告“已取消”。不得用一次普通 atomic load 后的无保护窗口承诺取消与执行互斥。
3. `commit_horizon` 是独占上界：小于它的 frames 已生成或已经过 gate 成为不可撤销的有界 render span；它不是 published block end。`render_frame <= commit_horizon`，同一时刻最大 ahead span 由 profile 冻结。Control 规划窗口与 emergency latency 使用读到的 horizon、最小 lead 和 race budget；真正过晚的命令仍明确拒绝。
4. 无命令时也按 `max_commit_span_frames` 切分处理 invalidation，避免大 callback 或远期 block 阻塞紧急停止。所有 retry、扫描、phase 数量和 receipts 都有固定上限；receipt capacity 必须预留终结记录或进入显式 fail-closed 状态，不能丢失唯一回收凭据。
5. 原子发布保证同组 admission 全有或全无；跨多个 fill 的 plan 可合法处于 partially_executed。每个 phase 的实际 frame/epoch 保留，不能把全 plan 原子执行误解为跨时间撤销已经播放的 fill。
6. render 仅做固定代价 lease handoff/retire 通知；完成、取消、stale、queue-full、receipt overflow 均必须有可回收闭环。render 不因最后一个 ref 变零而 free bank/PCM，不等待 Control/Worker。

### 不规则 callback 与已生成 PCM

- `render_frame` 按实际 mixer 生成 frames 推进；`submitted_frames` 按交给 backend 的 frames 推进；`delivered_frames`只表示设备已播放位置观测，带exact/estimated/unavailable和误差，不能用submitted代替。一次请求 1 frame 可能生成 256 并留下 255 pending，禁止把已生成全部 frame 报为已经交付。
- pending PCM 标记 `[first_render_frame,end_render_frame)` 与 `device_epoch`；实际 flush 记录丢弃 frame 区间和数量。设备 lost/reopen 的 epoch 切换接口必须能拒绝旧 pending PCM；TASK-014 负责 control recovery。
- 音乐 pause/stop/reload 不能删除已经混入 SFX 的 pending PCM 来假装零延迟：以最早未 commit frame 执行，并单独报告 render-ahead 带来的 delivery 延迟。已送到驱动的 buffer 不可声称可撤回。

### 强制交错与故障验证

- 复用 TASK-025 结果：队列 reservation 后延迟 sequence 分配、normal/reserved 双 lane 交错、one-shot 结束而 Control 暂停、snapshot publish/acquire 竞争。疑点只在测试真实复现后标为缺陷并关联修复。
- 注入取消在 prepare 后、publish 后、acquire 后、group claim 前/后、第一/第二 fill 后及 complete 后；对 stop、pause、reload 分别断言后缀无 stale start、已执行 phase 不被抹除、所有 lease 恰好释放一次。本任务以真实 mixer 脉冲 payload 的有界三阶段 fixture 验证 scheduler，不依赖尚未实现的 planner；真实 authored 多 fill 路由由 TASK-009/014/016 做集成复验。
- 注入 receipt ring 满、snapshot acquire 重试上限、owner pin contention、worker late，验证无自旋等待、无 UAF/duplicate completion，计数与终结 disposition 一致。
- variable callback fixture 使用 1/127/256/300/513 frames，验证 render/submitted/pending/flushed账目守恒（delivered观测不参与简单守恒）、span 切分不改 schedule、flush 不交付旧 epoch 样本。

## 接口与数据契约
`ScheduledMusicCommand { command_id, plan_id, plan_epoch, transport_epoch, asset_generation, phase_id, execute_frame:u64, sequence:u64, group_id:u64, payload }`。`SchedulerCapacityProfile` 必须显式携带所有容量、lead/late frames 与 emergency ramp frames；初始化时验证相互约束和乘法溢出。
`ExecutionReceipt` 必须含上述身份、planned/executed frame、phase_id、result/reason；`CancellationReceipt` 含 requested/effective frame、cancelled suffix、已执行 phase 集、commit horizon 和 terminal disposition。
`CommandQueueFull`、`InvalidState`、`StaleAssetGeneration` 语义不得合并。

## 文件变更
- `src/music/scheduler.zig`：新增 queue/block/receipt。
- `src/runtime/runtime.zig`：ControlRuntime 发布/回收 blocks，RuntimeRenderer 独占绝对 frame、执行 gate、Mixer 与 receipt；不把 legacy Engine 设为新所有者。
- `src/device/device.zig`：RuntimeFixedQuantumAdapter 的 render/submitted accounting、pending epoch/flush seam；TASK-014 后续接入设备恢复策略。
- `src/mixer/mixer.zig`：quantum span 执行 seam。
- `tests/sme/scheduler_test.zig`：确定性、原子性、offset。

## 验证
### 自动化验证
- `zig build test`。
- 覆盖 quantum 首/中/尾 frame、同 frame sequence、跨 quantum、queue full、原子 group 容量不足、late command、callback 非固定 frame。
- 对 release 默认 profile 断言 capacity 数值、静态字节占用、high-water 和 late budget，并把结果写入 TASK-002 evidence。
### 手工验证
- 不需要。
### 边界与失败场景
- `u64` 接近 wrap 时初始化拒绝不安全 duration。
- publish 与 render 交错不得读取半写 block。

## 完成定义
- [ ] offline 实测脉冲出现在计划 sample。
- [ ] 同 frame 原子 group 永不部分执行；跨 frame 多 phase plan 的已执行前缀被准确回执，未执行后缀可取消。
- [ ] render path 无 alloc/lock/log/I/O。
- [ ] 现有 voice/demo 行为回归通过。
- [ ] release 默认 `SchedulerCapacityProfile` 的值、单位、内存占用与 late 判据已冻结并有测试。

### 补充完成定义
- [ ] production RuntimeOfflineBackend 的 sample-offset 测试真实通过，Engine-only 测试不能替代。
- [ ] prepared/published/acquired/partial/complete 的取消 race 矩阵有独立 receipt/PCM oracle。
- [ ] commit horizon、最大 cancel latency、bounded retry 与 lease 回收上限已量化并有强制交错测试。
- [ ] render-ahead/delivery/pending/flush 账目可对齐，未用 delivered frame 代替 render clock。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：依据 production runtime 代码校正规格，补充执行、取消、设备和证据契约；本次仅修订文档，未运行基线复现或实施代码。

## 风险与注意事项
不要为了 scheduler 把 Music Director 放进 render thread；payload 只表达已经规划好的 bounded 操作。



## Replay admission gate补充
renderer以固定receipt记录每batch真正可见/接纳的gate序号/frame、batch ID/hash、observed commit_horizon、stable order及admitted/late/rejected disposition。该外部调度事实进入ReplayInputV2，而不是可选publication诊断。Replay以同一gate释放重新计算出的真实batch再执行epoch/phase裁决；禁止直接重放executed/cancelled结果绕过scheduler。强制在Control acceptance后延迟publication，分别制造cancel先到/后到，验证记录重放保留各自winner；缺gate记录拒绝production replay。
