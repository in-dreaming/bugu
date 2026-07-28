# TASK-009：实现 Entry/Exit Cue、Fill Route 与 Transition Planner

## 元数据
- 状态：待实施
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
- 稳定评分：hard constraints、sync、resident feasibility、authored preference、latency、cue ID。
- `BoundedTransitionPhases` 和所需 chunk set。
- cancel/replan/stale generation。

### 明确不包含
- 实际 I/O、voice/group 执行。
- 自动分析调性。

## 设计与执行细节
1. compiler 证明 route 最终可到 target。
2. planner 枚举上限由 bank/profile 固定，超限构建失败。
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
- 同 tempo、变 tempo、变 meter、0/1/N fill、tail overlap、无兼容 cue、route cycle、相同评分 tie-break、late readiness、cancel/replan。
### 手工验证
- 导出 plan timeline 检查；不代替断言。
### 边界与失败场景
- cue 在 loop 外、fill 无 exit、phase 超上限、generation 变化。

## 完成定义
- [ ] 规划结果确定且包含完整 phase/chunk 信息。
- [ ] 不兼容 transition 明确失败。
- [ ] multi-fill 无即时事件拼接。
- [ ] trace 可解释候选与选择。

## 风险与注意事项
不要让 planner 读取文件或等待 worker；它只消费 readiness snapshot。

