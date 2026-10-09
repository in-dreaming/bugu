# TASK-016：实现 MusicBank hot reload、generation migration 与 rollback

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Asset/Runtime Lifetime
- 评审角色：并发所有权、streaming、QA
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-016/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-016/`（原始产物）
- 执行波次：11
- 硬依赖：TASK-003、TASK-004、TASK-011、TASK-014、TASK-015
- 协作关系：TASK-017 可在上一波次完成；TASK-018 使用本任务 live tuning API
- 预计改动范围：`src/music/runtime.zig`、`src/music/save_state.zig`、`src/assets/music_bank.zig`、`tests/sme/hot_reload_test.zig`

## 目标
在旧 groups/streams 安全持有 generation lease 时原子发布新 bank，迁移 stable IDs/状态/历史，并可回滚到上一 validated generation。

## 上下文
简单替换 sample pointers 会造成 UAF；已有 transition plan 也可能引用旧 table layout。

## 前置条件
- immutable MusicBank generation。
- MusicRuntime ownership/save state。
- stream job cancellation 与 ReplayInputV2 completion trace。
- TASK-002 render gate/commit horizon/epoch receipt；TASK-014 production RuntimeRenderer、device epoch 和 shutdown lease seam。

## 实施范围
### 必须完成
- load/validate new generation 后 atomic publish。
- prepared/published/acquired/partial old plan 的取消/replan；执行点 epoch barrier 生效后禁止旧后缀启动，old playing group lease 到 release。
- versioned `MigrationMapV1`：from/to bank build ID、state/segment/selector ID maps、selector history conversion policy、required capability bits 与 map content hash；selector history/committed state 只能按该 map 迁移。
- incompatible migration fail without changing active generation。
- `GenerationRetentionProfile` 中的 generation history capacity、最大 retained bytes/leases 与 rollback retention；容量不足在 publish 前失败。
- stale worker completion/receipt 不得改变新状态，但必须消费其资源归还/旧 generation 清理责任并计数；禁止直接丢弃造成 lease 泄漏。

### 明确不包含
- GUI 操作；TASK-018 调 API。
- 自动修复 ID 重命名；必须 migration map。

## 设计与执行细节
1. validate/build outside render。
2. publish frame 可选择安全 bar/cue；Control 指针发布不是音乐切换完成，render gate/执行 receipt 才提交 active generation。immediate metadata-only 更新仅限不改变已计划媒体、时钟/路由/逻辑/布局的字段，并列出 allowlist。
3. rollback 是另一次 generation publish，不复活已释放指针。
4. content hash 相同不创建新 generation。
5. migration map 必须无环、source/target 唯一、build ID 精确匹配且 hash 校验通过；未知 map version 或丢失 required mapping 时保持当前 generation。
6. generation history 只按显式 capacity/retention 驱逐；仍有 lease 的 generation 不可驱逐，不能依赖时间或 GC 猜测。
7. capacity不足先拒绝 reload。

### 跨发布/执行边界的 reload transaction

- `prepare`：Worker 加载/校验新 bank、migration map、prefetch 最小集合；Control 预留 retention/command/receipt capacity 和两代 lease。失败不发布候选、不修改当前 active generation。
- `publish_candidate`：仅令 validated generation 可被未来命令引用；原 generation 的 active/playing 定义不变。为事务分配 reload transaction ID 与新 plan/transport epoch，记录旧 plan 已完成的 phase 前缀。
- `activate`：同一 render gate 中按稳定顺序使旧 plan 未执行后缀失效，再在合法 frame 执行新 generation/group 命令；渲染前再次验证 plan epoch、transport epoch 和 asset generation。已经 acquire 的旧 block 也必须通过该 gate，不能只在 publish 时检查 generation。
- `commit`：Control 消费 activation receipt 后更新 active generation/committed state 与迁移后的 selector history。若旧 plan 已进入 fill，receipt 保留实际 fill/cursor；不能假设还处于原 source 或目标已完成。
- `abort/rollback`：commit 前的 validation/readiness/capacity 失败保持旧 active generation；若 render 已执行一部分事务，必须按 receipt 实际状态进入显式 recovery/rollback，不承诺撤销已生成 PCM。rollback 重新验证 retained generation 与 readiness，以新的 monotonic generation/transaction 身份走相同流程。

### 引用安全和取消验证

- lease 覆盖 Control plan、已发布 block、已 acquire snapshot/block、playing/virtual group、每个 voice、stream job/ring/cache、capture/restore、rollback history；列举取得、移交、terminal disposition、回收线程，禁止只有 voice 持 lease。
- generation/history 满时先预检再发布；旧 plan 取消成功不等于旧 generation 可销毁，仍需所有 reader/worker/PCM owner 引用释放。旧 epoch receipt 仍能归还它拥有的 lease，但不能提交新状态或释放别人的 generation。
- stop/pause/reload/rollback 同 tick 时使用 ReplayInputV2 系统优先级与 input order；每个事务有唯一 terminal receipt。内容 hash 相同的 reload 不制造 generation 或 epoch churn。
- pending PCM 来自已经 commit 的混合输出，正常 reload 不 flush；device lost 引发的 flush 走 TASK-014 device epoch 流程，不能复用 asset generation 当作设备 epoch。
- 强制暂停 Render 于 acquire 后、phase gate 前、首 fill 后、次 fill 后、target-entry 后；分别 reload、rollback、stop/pause during reload，证明 stale suffix 不执行、active generation 提交时点正确、retained lease 恰好释放一次。
- 模拟 receipt/full queue、迟到且旧 epoch 的 decoded PCM、reopen 与 reload 同时发生；断言新状态不污染、资源可回收、失败 trace 完整。

## 接口与数据契约
`hotReload(new_bank, MigrationMapV1, PublishPolicy)`、`rollbackGeneration(id)`。`MigrationMapV1` 是 versioned、length-delimited、content-hashed 的 owned value；`GenerationRetentionProfile` 明确 count/bytes/lease 上限和驱逐顺序。receipt 含 old/new hash/generation、transaction/epoch、executed phase set/result；activation 前失败保持原 active 状态，activation 后故障按实际 receipt 进入显式 recovery/rollback，不伪称已播放声音可撤销。

## 文件变更
- 修改 runtime/save/bank。
- 新增 reload tests。

## 验证
### 自动化验证
- `zig build test`。
- active group reload、pending plan reload、stream job late、ID rename map、map hash/build ID/version 错误、migration cycle、missing state、same hash、count/bytes/lease capacity、deterministic eviction、rollback、shutdown during reload。
### 手工验证
- 不需要。
### 边界与失败场景
- new bank corrupt、migration cycle、target cue missing、old lease long-lived。

## 完成定义
- [ ] reload失败不改变正在播放 generation。
- [ ] 旧 voice/stream无 UAF。
- [ ] migration/rollback trace完整。
- [ ] stale completions不污染新状态。
- [ ] `MigrationMapV1` 格式和 generation retention/eviction policy 已冻结并有兼容性测试。

### 补充完成定义
- [ ] reload 的 prepare/candidate/activate/commit/abort 分界及 partial execution 恢复有失败测试。
- [ ] 已 published/acquired 旧计划在 render 执行 gate 拒绝 stale epoch；多 fill 后缀取消真实通过。
- [ ] stale receipt/completion 既不提交状态也不泄漏资源，所有 generation lease 类别有回收证据。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：依据 production runtime 代码校正规格，补充执行、取消、设备和证据契约；本次仅修订文档，未运行基线复现或实施代码。

## 风险与注意事项
不得在 render thread释放 bank或等待旧 lease。

