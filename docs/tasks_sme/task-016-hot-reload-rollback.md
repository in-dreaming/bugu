# TASK-016：实现 MusicBank hot reload、generation migration 与 rollback

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Asset/Runtime Lifetime
- 评审角色：并发所有权、streaming、QA
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-016/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-016/`（原始产物）
- 执行波次：7
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
- stream job cancellation与trace。

## 实施范围
### 必须完成
- load/validate new generation 后 atomic publish。
- old plan cancel/replan；old playing group lease 到 release。
- versioned `MigrationMapV1`：from/to bank build ID、state/segment/selector ID maps、selector history conversion policy、required capability bits 与 map content hash；selector history/committed state 只能按该 map 迁移。
- incompatible migration fail without changing active generation。
- `GenerationRetentionProfile` 中的 generation history capacity、最大 retained bytes/leases 与 rollback retention；容量不足在 publish 前失败。
- stale worker completion/receipt丢弃并计数。

### 明确不包含
- GUI 操作；TASK-018 调 API。
- 自动修复 ID 重命名；必须 migration map。

## 设计与执行细节
1. validate/build outside render。
2. publish frame 可选择安全 bar/cue；明确 immediate metadata-only 更新范围。
3. rollback 是另一次 generation publish，不复活已释放指针。
4. content hash 相同不创建新 generation。
5. migration map 必须无环、source/target 唯一、build ID 精确匹配且 hash 校验通过；未知 map version 或丢失 required mapping 时保持当前 generation。
6. generation history 只按显式 capacity/retention 驱逐；仍有 lease 的 generation 不可驱逐，不能依赖时间或 GC 猜测。
7. capacity不足先拒绝 reload。

## 接口与数据契约
`hotReload(new_bank, MigrationMapV1, PublishPolicy)`、`rollbackGeneration(id)`。`MigrationMapV1` 是 versioned、length-delimited、content-hashed 的 owned value；`GenerationRetentionProfile` 明确 count/bytes/lease 上限和驱逐顺序。receipt 含 old/new hash/generation/result；失败保持原状态。

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

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
不得在 render thread释放 bank或等待旧 lease。
