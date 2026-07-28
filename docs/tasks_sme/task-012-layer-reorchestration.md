# TASK-012：实现 Layer Controller 与完整重配器

## 元数据
- 状态：待实施
- 执行波次：4
- 硬依赖：TASK-004、TASK-005、TASK-006、TASK-007
- 协作关系：TASK-008 提供 state/context；TASK-013 提供 bus/effect targets；TASK-014 持有 controller
- 预计改动范围：`src/music/layers.zig`（新增）、`src/mixer/music_group.zig`、`tools/sme_compiler/layers.zig`、`tests/sme/layer_controller_test.zig`

## 目标
把 intensity/state/context/logic 输出编译为 sample/block-ramped layer target，覆盖 gain、active/virtual、variant、channel trim、filter、effect send、bus route 和保护优先级。

## 上下文
垂直分层不只是音量。离散 variant 只能在合法 cue 切换，多个规则写同一参数必须在构建期消歧。

## 前置条件
- atomic group、virtual voice、tempo clock、trace。
- Bus target 通过稳定 seam 表达，具体 DAG 由 TASK-013 完成。

## 实施范围
### 必须完成
- piecewise curve/LUT、attack/release/hysteresis。
- complete `LayerTarget` 与 conflict validator。
- continuous ramp 以 musical beat 或 frame 表达。
- discrete articulation/variant cue-bound switch。
- group/layer target command 编译。
- muted/virtual layer cursor 始终推进。

### 明确不包含
- Bus DSP 实现。
- Director rule evaluation。

## 设计与执行细节
1. 同一 target 多写：priority + authored order；未声明冲突构建失败。
2. NaN/Inf clamp/reject 规则固定。
3. ramp 穿越 tempo span 时通过 grid 分段，不用单一 BPM。
4. variant source 必须 layout/loop/cue 兼容。
5. target diff 只发布变化，避免 command flood。

## 接口与数据契约
`LayerTarget`、`LayerAutomationBlock`、`VariantSwitchPlan`。失败：invalid curve、conflicting writers、incompatible variant、budget failure。

## 文件变更
- 新增 layer controller/compiler/tests。
- group module增加 target apply seam。

## 验证
### 自动化验证
- `zig build test`。
- intensity 上下扫、hysteresis、tempo ramp attack/release、多 writer、variant cue、virtual realize、filter/send/bus target、NaN。
### 手工验证
- offline stem envelopes 与 layer trace 对齐。
### 边界与失败场景
- 0/1 point curve、instant ramp、cue 不可达、variant chunk 未准备。

## 完成定义
- [ ] 完整 target 字段均进入真实 scheduled command。
- [ ] 连续参数无 click/zipper，离散切换只在合法 cue。
- [ ] cursor skew 0。
- [ ] 冲突资产无法构建。

## 风险与注意事项
不要把设计师曲线硬编码在 Zig 分支；全部来自 bank。

