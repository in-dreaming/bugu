# TASK-014：集成完整 MusicRuntime 公共主链与生命周期

## 元数据
- 状态：待实施
- 执行波次：5
- 硬依赖：TASK-004、TASK-008、TASK-009、TASK-011、TASK-012、TASK-013
- 协作关系：TASK-015/016/017 通过本任务稳定 extension seam 并行；`Engine`/公共导出由本任务所有
- 预计改动范围：`src/music/runtime.zig`、`src/music/save_state.zig`（新增）、`src/core/engine.zig`、`src/bugu_audio.zig`、`tests/sme/runtime_integration_test.zig`

## 目标
交付一个真实 `MusicRuntime`，把 request、Director、Planner、prefetch、Layer Controller、scheduler、mixer、receipt 和 trace 串为端到端播放链，并实现生命周期与 capture/restore。

## 上下文
各前置任务提供组件但不能各自宣称 SME 可播放。本任务是首次端到端 runtime integration，不包含 authoring UI 或 hot reload。

## 前置条件
- 所有硬依赖的公共 tests 通过。
- Engine 仍保持一个主 transport。

## 实施范围
### 必须完成
- Engine-owned runtime init/load/start/submit/poll/snapshot/pause/resume/stop/shutdown。
- control tick 顺序与 bounded queues。
- committed/pending state，receipt 后提交。
- capture/restore：state、selector history、seed/epochs、transport/cue、build ID。
- device lost 默认 restart next legal bar/cue；显式 resume phase 条件。
- bank/stream/group lease 和 shutdown 安全。
- public `bugu_audio.music` exports。

### 明确不包含
- stinger/acoustic mapping/hot reload/GUI。
- C ABI。

## 设计与执行细节
1. `accepted`、`planned`、`executed` 分离。
2. restore 仅 matching build ID 或 migration map；本任务先只 matching。
3. control tick 不直接修改 mixer hot data。
4. shutdown 拒绝新请求、release groups、取消 jobs、延迟回收 lease。
5. legacy event runtime 与 SME 可同 engine 工作且不共享状态图。

## 接口与数据契约
公共 API 使用 TASK-001 contract。snapshot 是 immutable copy；caller 不持有内部 slices。tool-only seek 在 shipping mode 返回 `UnsupportedOperation`。

## 文件变更
- 新增 runtime/save_state/tests。
- engine ownership/public exports。

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

## 风险与注意事项
本任务不能用直接 start voice 绕过 planner/scheduler 来制造 demo。

