# TASK-014：集成完整 MusicRuntime 公共主链与生命周期

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Runtime Integration
- 评审角色：架构、实时安全、生命周期、QA
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-014/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-014/`（原始产物）
- 执行波次：9
- 硬依赖：TASK-004、TASK-008、TASK-009、TASK-011、TASK-012、TASK-013、TASK-026
- 协作关系：TASK-015/017 通过本任务稳定 extension seam 扩展；TASK-016 在其依赖完成后顺序接入 generation lifecycle；production `ControlRuntime`/`RuntimeRenderer` 集成、event adapter 与 `src/music/api.zig` runtime exports 由本任务所有
- 预计改动范围：`src/music/runtime.zig`、`src/music/save_state.zig`、`src/events/runtime_adapter.zig`（新增）、`src/music/api.zig`、`src/runtime/runtime.zig`、`src/device/device.zig`、`tests/sme/runtime_integration_test.zig`

## 目标
交付一个真实 `MusicRuntime`，把 request、Director、Planner、prefetch、Layer Controller、scheduler、mixer、receipt 和 trace 串为端到端播放链，并实现生命周期与 capture/restore。

## 上下文
TASK-026 已通过公共 production runtime + RuntimeOfflineBackend 建立最小真实垂直切片；本任务把它扩展为完整 MusicRuntime、生命周期和 capture/restore，不能另起 Engine-only 主链。现有 ControlRuntime 管理请求/snapshot，RuntimeRenderer 独占 Mixer，RuntimeMiniaudioBackend 与 RuntimeOfflineBackend 直接驱动它；新 runtime 在该链集成，不包含 authoring UI 或 hot reload 实现。

## 前置条件
- 所有硬依赖的公共 tests 通过。
- TASK-026 提供可执行 public integration fixture、真实 PCM/receipts 与 early ownership/lease 证据。
- 每个 ControlRuntime/RuntimeRenderer context 仅一个主 transport；legacy Engine 的兼容 surface 保持冻结。

## 实施范围
### 必须完成
- ControlRuntime-owned MusicRuntime 的 init/load/start/submit/poll/snapshot/pause/resume/stop/shutdown；RuntimeRenderer 独占唯一 mixer/scheduler frame。
- control tick 顺序与 bounded queues。
- committed/pending state，receipt 后提交。
- capture/restore：state、selector history、seed/epochs、transport/cue、build ID。
- device lost 默认 restart next legal bar/cue；显式 resume phase 条件。
- bank/stream/group lease 和 shutdown 安全。
- 在 TASK-001 固定的 `src/music/api.zig` 增加已实现 runtime exports；不改变 `src/bugu_audio.zig` 的 façade 指向。
- 冻结 API thread-affinity/ownership matrix 与 `MusicRuntimeSnapshotV1` version header；game/control/worker/render 每个调用的允许线程、借用期、queue-full 和 stale-handle 行为均逐项列出。
- 在 TASK-002 的 capacity profile 上冻结 game→control request queue、worker completion queue 和 snapshot/receipt capacity。

### 明确不包含
- stinger/acoustic mapping/hot reload/GUI。
- C ABI。

## 交付检查点

XL 工作必须先在任务内登记以下具名子交付物的 Owner、Reviewer、commit 和独立 evidence；每项均可单独审查，不能合并成“集成完成”一个检查点。

| 子交付物 | 输入 | 输出 | 独立验证与通过判据 |
|---|---|---|---|
| R14-A：冻结 production API/lifecycle | TASK-001 contract、TASK-025 baseline、TASK-026 公开切片 | `music/api.zig` runtime bindings、context/thread/ownership matrix、request/receipt lifecycle | public compile fixture、重复绑定/错误线程/queue full/stale handle/shutdown 拒绝；保持一个 renderer/mixer/transport |
| R14-B：接通完整控制与 SFX adapter | R14-A、Director/Planner/stream/layer/bus 模块 | `music/runtime.zig` control tick、`events/runtime_adapter.zig`、phase receipt/committed-state 更新 | RuntimeOfflineBackend 的 SFX+四 stem PCM/trace；两个 fill 的 stop/pause 后缀取消；无双 mixer、无 stale/重复执行 |
| R14-C：一致 capture/restore | R14-B execution fence、bank/selector/clock contract | `music/save_state.zig`、MusicRuntimeSnapshotV1 owned copy 和 restore re-anchor | 同 build 恢复 schedule/cursor 一致；wrong build/corrupt snapshot 拒绝；capture 与 fill execution 交错时不混合两个状态 |
| R14-D：恢复设备并收敛资源 | R14-B/C、scheduler gate、stream/lease 与 adapter pending PCM | device event/control recovery、device epoch flush、shutdown drain/retire | irregular callback pending 哨兵、lost/reopen/resume-policy、late worker、callback quiescent teardown；无旧 PCM 泄漏且所有 lease 清零 |

R14-A → R14-B → R14-C → R14-D 顺序合并；每项都运行 `zig build test` 中对应新增独立测试文件和已完成子交付物回归。四项 evidence 与当前 commit 一致、所有完成定义满足后，TASK-014 才可整体进入 `REVIEW`。

## 设计与执行细节
1. `accepted`、`planned`、`executed` 分离。
2. restore 仅 matching build ID 或 migration map；本任务先只 matching。
3. control tick 不直接修改 mixer hot data。
4. shutdown 拒绝新请求、release groups、取消 jobs、延迟回收 lease。
5. 新增显式 event adapter，将既有 event 资产/解析逻辑接入同一 ControlRuntime；SFX 和 SME 共用 RuntimeRenderer 的 mixer/bus/voice budget，不共享 music 状态图。冻结旧 EventRuntime(*Engine) 的即时语义，禁止将其原样并发调用宣称安全共存。

### Production 集成和 legacy adapter

1. `ControlRuntime.controlTick` 的扩展顺序固定：消费实际 render receipts/retire → 按 ReplayInputV2 tick/order 接受 device 与 worker completions、游戏输入 → 仲裁/clock/plan/readiness → 编译 layer/bus/group 命令 → 发布 immutable block/snapshot → 导出状态。所有阶段有单 tick 预算；不得在 callback 执行 controlTick。
2. MusicRuntime 不拥有第二个 mixer；RuntimeRenderer 中普通 SFX desired snapshot 和音乐 scheduled commands 必须统一 voice/bus arbitration，snapshot 同步不能删除、重启或抢占未属于自身的 music group。
3. event adapter 给出 public `reserve/post/update/stop/poll` 语义，将 legacy event/switch/RTPC 和 `SampleOwner` lease 映射到 production `InstanceHandle`；旧 VoiceHandle 不能直接强转。新 adapter 的 accepted/executed 区别、参数范围、queue full、stale handle 和 stop 范围在 API matrix 明示。
4. 既有 `Engine`/`EventRuntime` public 调用及旧 WAV bank fixtures 保持行为；新 sample 同时演示 adapter SFX 与 SME 经同一 RuntimeOfflineBackend 输出。禁止并行启动 legacy Engine backend 与 runtime backend 再把两路声卡输出当成同 mixer 证据。

### 生命周期、multi-fill 与取消

- pending state 可标 planned/published/acquired/partial；committed state 只由 target-entry phase 的成功执行 receipt 更新。进入第一段 fill 不等于已进入目标 state，source/fill transport 另行记录。
- pause：在 TASK-002 cancellation gate 使未执行后缀失效，等待实际 pause frame receipt 后冻结 music cursor；SFX 和 render clock 继续。resume 从已确认 group cursor/transport epoch 重建绝对计划，不能重新启用旧 epoch 的 fill/target 命令。
- stop：所有 music plan 后缀失效，已启动 source/fill/target group 在最早可执行 frame 短 ramp 释放；不停止无关 SFX。停止完成以 group completion/lease retire 收齐为准，accepted 不等于 Ready。
- reload seam：允许旧正在播放 group 保留 lease；TASK-016 通过相同 cancellation/receipt gate 实现 generation 切换。不能只删除 control pending plan，让已 acquire 的旧命令继续启动。
- captureState 在 Control 收到明确 render fence/receipt 后生成一致 owned copy，记录 committed/pending/phase、selector history、seed/epochs、group cursor、build ID。capture 不把发布快照当执行状态；restore 废弃历史绝对 frame 并从当前 context frontier 重新锚定，不倒退 render_frame。

### Device discontinuity 和 pending PCM

- RuntimeFixedQuantumAdapter 上报 `render_frame`、`commit_horizon`、`submitted_frames`、可选`delivered_frames`观测及quality/uncertainty、pending frame 区间/设备 epoch；driver 已接收 frames 不等同于物理扬声器已播放。request-to-submitted 与估计 audible latency 分列。
- device callback/notification 只写预分配事件和必要 atomics；Control 负责 lost/reopen/retry、状态机和合法 bar/cue 选择。不得在音频 callback 直接执行 blocking `ma_device_stop/uninit/open/start` 或等待 worker。
- lost/reopen 原子切换 device epoch；callback 已静止或在受控 epoch 边界后清空旧 pending PCM，并记录 discarded frames、最后可信 delivery/render frontier。新设备不交付旧 epoch PCM；render_frame 保持单调，丢弃区间不假装已交付。
- 默认 `restart_at_bar` 从最后 committed state 重新预取、选择合法 entry/bar/cue，再等待执行 receipt 后恢复 Playing；`resume_phase` 仅在保存 cursor、generation、stream/seek cache 和 channel/sample-rate contract 均可用时接受，否则明确拒绝并要求选恢复策略。
- 普通 music pause/stop/reload 不直接 flush 混合 SFX 的 pending PCM；已经 commit 的 render-ahead 有限尾部必须在 API 延迟说明和 trace 中可见。

### Lease 和 shutdown 顺序

1. 先停止接收新 game/event/music 请求；推进 plan/transport epoch 的失效 intent，禁止新 decode jobs。
2. Render 经 gate 停止 groups/SFX，已发布/acquired block、snapshot、voice 与 stream ring 的 lease 各自保持直到 terminal receipt/retire；late completion 不改新状态但仍执行唯一资源归还。
3. Worker 取消/完成由 Control 收敛；render 从不 join worker、free bank 或阻塞等待 receipt consumer。
4. Device 已丢失时不依赖未来 callback 才能 drain：确认 callback quiescent 后，由非实时 teardown 接管 retirement，禁止与 render 并发释放。
5. Control 确认 queues/receipts、instances、snapshot readers、render pins、plan/worker/generation leases 均归零后销毁；可返回 DrainPending 并由调用方继续泵 control，不伪报 Destroyed。

### 必须追加的集成矩阵

- 通过公共 RuntimeOfflineBackend 同时播放 adapter SFX 与四 stem music，断言同一 mixer/clock、两个 bus 均非静音、music pause/stop 不重启或停止 SFX。
- 一条含至少两段 fill 的真实路由，分别在 published、acquired、first-fill、second-fill、target-entry 后提交 stop/pause/reload intent；断言 receipt phase 状态、后缀失效、恢复重规划和零重复 terminal。
- variable callback 留有 pending PCM 时 lost/reopen，断言旧 device epoch PCM 不泄漏、render/submitted/pending/flush账目守恒和恢复策略由 Control 决定。
- snapshot publish 不前进的多次 render 中 one-shot 只结束一次；shutdown 交错 SFX、music、snapshot reader、late worker 与 device lost 后全部 lease 清零。

## 接口与数据契约
公共 API 使用 TASK-001 contract。`MusicRuntimeSnapshotV1` 含 schema version、byte size、bank build ID/generation、capture render frame 和 bounded table counts；snapshot 是 immutable owned copy，caller 不持有内部 slices。每个 API 在同一表中定义 allowed thread、ownership、queue-full、invalid/stale handle 与 shutdown 行为。tool-only seek 在 shipping mode 返回 `UnsupportedOperation`。

## 文件变更
- 新增 runtime/save_state/tests。
- `src/runtime/runtime.zig`：production ownership/integration；`src/device/device.zig`：device event、epoch flush/recovery；`src/events/runtime_adapter.zig`：显式 compatibility adapter。
- `src/music/api.zig` 增加 public exports，`src/bugu_audio.zig` 不再由本任务修改。
- `docs/design/sme-runtime-api-v1.md`：新增 API/thread/ownership/snapshot matrix。

## 验证
### 自动化验证
- `zig build test`。
- request->offline PCM/trace；explore/combat；rapid churn；pause/resume/stop；capture/restore；wrong build ID；device discontinuity；shutdown with active stream/group；legacy event coexist。
### 手工验证
- 不需要。
### 边界与失败场景
- queue full、no transition、target late、generation stale、restore corrupted。

## 完成定义
- [ ] 真实端到端链产生非静音 PCM 和 executed trace。
- [ ] 生命周期/所有权 tests 无 UAF/leak。
- [ ] capture/restore 确定。
- [ ] 公共 API 不泄漏内部/第三方类型。
- [ ] API thread/ownership matrix、snapshot header 与所有 queue capacity 已冻结并有失败测试。

### 补充完成定义
- [ ] 生产公共 runtime + RuntimeOffline/RuntimeMiniaudio 都接入 SME，未依赖 Engine-only 验收。
- [ ] adapter SFX+music 同 mixer 共存、budget/bus、pause/stop 与 shutdown lease 回归通过。
- [ ] multi-fill 全阶段取消/恢复、设备 pending PCM epoch flush 与 control recovery 均有实际 PCM/receipt 证据。
- [ ] 所有 lifecycle terminal 状态均由执行/回收证据驱动，旧 epoch receipt 不污染当前状态但能完成清理。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：依据 production runtime 代码校正规格，补充执行、取消、设备和证据契约；本次仅修订文档，未运行基线复现或实施代码。

## 风险与注意事项
本任务不能用直接 start voice 绕过 planner/scheduler 来制造 demo。



## 有界Observer基础输出
本任务拥有Control侧RuntimeObserverV1：从固定容量render receipt/telemetry读取，生成immutable owned-copy状态/trace快照；subscribe/poll/unsubscribe均非render操作，含schema/generation/sequence/drop计数、最大记录数/字节数和shutdown终止语义。015/016只通过稳定扩展字段提供stinger/reload状态，不建立第二observer。慢消费者/满队列丢弃明确可丢的debug快照并计数，不反压render、不丢scheduler资源回收receipt；disconnect/shutdown释放subscription，不泄露bank lease。019消费此基础并拥有opt-in工具连接/协议endpoint，网络或本地IPC序列化全部在独立非实时debug worker。新增tests/sme/observer_test.zig证明慢/断连/满buffer/重订阅/关闭不影响canonical schedule或callback预算。
