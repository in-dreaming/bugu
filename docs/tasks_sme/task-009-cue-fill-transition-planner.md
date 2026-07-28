# TASK-009：实现 Entry/Exit Cue、Fill Route 与 Transition Planner

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Runtime Planner
- 评审角色：音乐系统、确定性求解、QA
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-009/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-009/`（原始产物）
- 执行波次：4
- 硬依赖：TASK-003、TASK-004、TASK-007、TASK-008
- 协作关系：TASK-011 提供 resident 查询；TASK-014 执行 plan；TASK-017 复用 solver
- 预计改动范围：`src/music/planner.zig`、`tools/sme_compiler/transitions.zig`、`tests/sme/planner_test.zig`（新增）

## 目标
联合求解 source exit、tail/overlap、零到多个 fill segments 和 target entry，生成完整、有界、可预取的绝对 frame `TransitionPlan`。

## 上下文
Crossfade 不能掩盖 tempo/meter/phrase 不兼容。和声兼容由作者标签和 compiler 邻接表决定，不做运行时音频分析。

## 前置条件
- target segment 已由 Director/Selector 解析。
- tempo grid 和 MusicBank cue/fill tables 可用。

## 实施范围
### 必须完成
- cue kind/beat role/harmony/phrase/energy/tail/min lead。
- compatibility constraint 与预计算合法邻接。
- sync：immediate/next beat/next bar/next matching cue/segment end/authored exit。
- multi-segment FillRoute，无无进展环。
- 稳定评分：先过滤 hard constraints，再按 `(sync_penalty, readiness_penalty, authored_rank, audible_frame, source_cue_id, fill_route_id, target_cue_id, target_segment_id)` 字典序升序选择；每项的计算单位和 authored rank 唯一来源写入 schema。
- `BoundedTransitionPhases` 和所需 chunk set。
- cancel/replan/stale generation。

### 明确不包含
- 实际 I/O、voice/group 执行。
- 自动分析调性。

## 设计与执行细节
1. compiler 证明 route 最终可到 target。
2. planner 的 candidate、fill route length、phase 和 required chunk 上限由 bank/profile 固定，超限构建失败；不得运行时截断候选后继续成功。
3. target 未 resident 时调用 readiness interface，不猜测 I/O。
4. committed state 在 target entry receipt 后更新。
5. hard cut 必须是 authored rule。

## 接口与数据契约
`TransitionPlan` 包含 plan/request IDs、source/fill/target/cues、execute/start/end frames、phases、tempo spans、generation、chunks。失败：`TransitionNotFound`、`TargetNotResident`、`UnsupportedCapability`。

## 文件变更
- 新增 planner/compiler/tests。
- 扩展 MusicBank transition/cue/fill validators。

## 验证
### 自动化验证
- `zig build test`。
- 同 tempo、变 tempo、变 meter、0/1/N fill、tail overlap、无兼容 cue、route cycle、对评分 tuple 每一列分别构造 tie-break fixture、late readiness、cancel/replan。
### 手工验证
- 导出 plan timeline 检查；不代替断言。
### 边界与失败场景
- cue 在 loop 外、fill 无 exit、phase 超上限、generation 变化。

## 完成定义
- [ ] 规划结果确定且包含完整 phase/chunk 信息。
- [ ] 不兼容 transition 明确失败。
- [ ] multi-fill 无即时事件拼接。
- [ ] trace 可解释每个候选被过滤或在 canonical score tuple 的哪一列败选。
- [ ] candidate/route/phase/chunk 上限已冻结且超限 fail closed。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
不要让 planner 读取文件或等待 worker；它只消费 readiness snapshot。

