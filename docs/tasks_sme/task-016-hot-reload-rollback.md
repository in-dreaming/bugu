# TASK-016：实现 MusicBank hot reload、generation migration 与 rollback

## 元数据
- 状态：待实施
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
- stable ID migration map、selector history/committed state迁移。
- incompatible migration fail without changing active generation。
- bounded generation history和rollback。
- stale worker completion/receipt丢弃并计数。

### 明确不包含
- GUI 操作；TASK-018 调 API。
- 自动修复 ID 重命名；必须 migration map。

## 设计与执行细节
1. validate/build outside render。
2. publish frame 可选择安全 bar/cue；明确 immediate metadata-only 更新范围。
3. rollback 是另一次 generation publish，不复活已释放指针。
4. content hash 相同不创建新 generation。
5. capacity不足先拒绝 reload。

## 接口与数据契约
`hotReload(new_bank, MigrationMap, PublishPolicy)`、`rollbackGeneration(id)`。receipt 含 old/new hash/generation/result。失败保持原状态。

## 文件变更
- 修改 runtime/save/bank。
- 新增 reload tests。

## 验证
### 自动化验证
- `zig build test`。
- active group reload、pending plan reload、stream job late、ID rename map、missing state、same hash、history capacity、rollback、shutdown during reload。
### 手工验证
- 不需要。
### 边界与失败场景
- new bank corrupt、migration cycle、target cue missing、old lease long-lived。

## 完成定义
- [ ] reload失败不改变正在播放 generation。
- [ ] 旧 voice/stream无 UAF。
- [ ] migration/rollback trace完整。
- [ ] stale completions不污染新状态。

## 风险与注意事项
不得在 render thread释放 bank或等待旧 lease。
