# TASK-006：实现 music virtual voice 与平台预算策略

## 元数据
- 状态：待实施
- 执行波次：3
- 硬依赖：TASK-004、TASK-005
- 协作关系：TASK-012 提供 layer target；TASK-014 管理 runtime；PlatformProfile 来自 TASK-003
- 预计改动范围：`src/mixer/virtual_voice.zig`（新增）、`src/mixer/music_group.zig`、`src/mixer/mixer.zig`、`tests/sme/virtual_voice_test.zig`

## 目标
实现不做 DSP 但保持 musical cursor/loop/automation/stream intent 的真实 virtual voice，并按平台 profile 执行保护、realize、virtualize 和 drop。

## 上下文
零 gain real voice 仍消耗 DSP，停止 layer 又会失去相位。SME v1 要求重新实体化时从 group 当前 frame 恢复。

## 前置条件
- atomic group 和 channel contract 已实现。
- trace/telemetry 可记录 state transition。

## 实施范围
### 必须完成
- real/virtual/releasing/stolen 状态机。
- base/dialogue/stinger protection class。
- authored `drop_rank`、audibility threshold/hysteresis。
- platform profile 的 real/virtual/group/stinger 上限。
- virtual cursor、loop epoch、automation、stream prefetch intent 推进。
- realize 时 sample-accurate seek 并加入 group 当前 cursor。

### 明确不包含
- codec seek 实现；通过接口调用 TASK-011。
- intensity 如何产生 target；由 TASK-012 实现。

## 设计与执行细节
1. 预算决策仅在 control thread；render 执行已编译 state command。
2. required base layer 不可 drop；无法保留则整个 transition 推迟/失败。
3. optional layer 可 virtualize，再按 profile 明确 drop。
4. 同分 tie-break 使用 stable layer ID，保证 replay。
5. telemetry 区分 virtualized、realized、dropped、stolen。

## 接口与数据契约
`PlatformProfile` 含 max real/virtual/groups/stingers、resident/stream bytes。`VoiceBudgetExceeded` 必须带 reason enum 和所需/可用数量进入 trace。

## 文件变更
- 新增 virtualization module/tests。
- 修改 group/mixer 状态执行。

## 验证
### 自动化验证
- `zig build test`。
- budget 边界、hysteresis、base protection、deterministic tie-break、virtual 100 bars 后 realize cursor 0 skew、seek failure。
### 手工验证
- 不需要。
### 边界与失败场景
- virtual capacity 也满；required layer 被错误 drop；generation 已回收。

## 完成定义
- [ ] virtual voice 不执行 sample DSP但推进全部逻辑时间。
- [ ] realize 与 group cursor 对齐。
- [ ] profile/保护/drop 均有 trace。
- [ ] 资源不足不静默成功。

## 风险与注意事项
不要在 render thread计算 audibility 排序；避免 O(N log N) 和不可预测分配。

