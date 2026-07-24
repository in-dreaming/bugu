# TASK-008：实现 bounded logic、Music Director 与 SegmentSelector

## 元数据
- 状态：待实施
- 执行波次：3
- 硬依赖：TASK-003、TASK-004、TASK-007
- 协作关系：TASK-009 消费 transition intent；TASK-014 持有 director；TASK-017 复用 compiler
- 预计改动范围：`src/music/logic.zig`、`selector.zig`、`director.zig`、`tools/sme_compiler/logic.zig`、`tests/sme/director_test.zig`（新增）

## 目标
把 state/parameter/context 请求确定性解析为唯一 transition intent 和 target segment，支持优先级、hold/cooldown、sequence、weighted、shuffle、no-repeat 和 saveable history。

## 上下文
现有 EventRuntime 只有一个 switch/RTPC 即时 play，不能承担音乐图、历史或边界计划。

## 前置条件
- MusicBank state/selector/logic tables。
- Clock 提供 bar/beat。
- trace/replay contract。

## 实施范围
### 必须完成
- 无递归、无副作用的 bounded stack bytecode compiler/evaluator。
- state request priority、last-wins、minimum hold、cooldown、hysteresis。
- fixed/sequence/weighted random/shuffle bag/no-repeat/history-aware selector。
- seed + stable selector ID + epoch 的确定随机。
- candidate/rejection/selection trace。
- snapshot/restore 所需 director/selector state model。

### 明确不包含
- cue/fill 具体执行 frame。
- mixer/stream 操作。

## 设计与执行细节
1. program 固定 instruction/stack 上限，load 时验证类型和 stack。
2. 多 rule tie-break：priority、specificity、authored order。
3. empty pool 返回显式 fallback/error。
4. parameter clamp、attack/release target 由 data 声明。
5. selector history 在 bank hot reload 时使用 stable ID migration。

## 接口与数据契约
输出 `TransitionIntent { request_id, from, to, selector, resolved_segment, priority }`。accepted 不改变 committed state；执行 receipt 后才提交。

## 文件变更
- 新增 logic/selector/director/compiler/tests。
- 扩展 MusicBank validators。

## 验证
### 自动化验证
- `zig build test`。
- opcode/type/stack 上限、优先级、hold/cooldown、rapid churn、每类 selector、seed replay、history capture/restore、empty pool。
### 手工验证
- 不需要。
### 边界与失败场景
- NaN parameter、unknown context、program 无终止、总权重 0、no-repeat window 大于 pool。

## 完成定义
- [ ] 同输入/seed/history 产生相同 intent。
- [ ] committed/pending state 语义正确。
- [ ] 所有候选和淘汰原因可追踪。
- [ ] evaluator 无动态分配/脚本回调。

## 风险与注意事项
Director 在 control thread 运行；不得直接 start voice 或读取 mixer 内部状态。

