# TASK-006：实现 music virtual voice 与平台预算策略

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Mixer Policy/Runtime
- 评审角色：实时安全、预算策略、QA
- 工作量等级：`M`
- 证据路径：`docs/validation/sme/TASK-006/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-006/`（原始产物）
- 执行波次：6
- 硬依赖：TASK-004、TASK-005、TASK-011
- 协作关系：TASK-012 提供 layer target；TASK-014 管理 runtime；PlatformProfile 来自 TASK-003
- 预计改动范围：`src/mixer/virtual_voice.zig`（新增）、`src/mixer/music_group.zig`、`src/mixer/mixer.zig`、`tests/sme/virtual_voice_test.zig`

## 目标
实现不做 DSP 但保持 musical cursor/loop/automation/stream intent 的真实 virtual voice，并按平台 profile 执行保护、realize、virtualize 和 drop。

## 上下文
零 gain real voice 仍消耗 DSP，停止 layer 又会失去相位。SME v1 要求重新实体化时从 group 当前 frame 恢复。

## 前置条件
- atomic group 和 channel contract 已实现。
- trace/telemetry 可记录 state transition。
- TASK-011 的真实 `seek/prepare`、generation/job ticket、readiness snapshot 和 PCM ring 已完成；只用预加载 PCM 或 seek stub 不足以开始本任务的 streaming realize 验收。

## 实施范围
### 必须完成
- real/virtual/releasing/stolen 状态机。
- base/dialogue/stinger protection class。
- authored `drop_rank`、audibility metric、threshold/hysteresis；metric 必须明确使用的 gain/envelope/priority 输入、dB/linear 单位、平滑窗口和 tie-break。
- platform profile 的 real/virtual/group/stinger 上限，以及 resident/stream bytes、realize/virtualize 阈值与最小保持 frames；每个 release profile 必须有具体值和内存预算。
- virtual cursor、loop epoch、automation、stream prefetch intent 推进。
- realize 时 sample-accurate seek 并加入 group 当前 cursor。

### 明确不包含
- codec seek 实现；通过接口调用 TASK-011。
- intensity 如何产生 target；由 TASK-012 实现。

## 设计与执行细节
1. 预算决策仅在 control thread；render 执行已编译 state command。
2. required base layer 不可 drop；无法保留则整个 transition 推迟/失败。
3. optional layer 可 virtualize，再按 profile 明确 drop。
4. 同分 tie-break 使用 stable layer ID，保证 replay；排序 tuple 固定为 protection class、authored priority、smoothed audibility、drop rank、stable layer ID，并明确每项升/降序。
5. telemetry 区分 virtualized、realized、dropped、stolen。
6. virtual stream 的 seek intent 使用目标 `(generation, group, layer, loop_epoch, cursor, realize_frame)`；worker completion 必须经 TASK-011/TASK-004 记录并在 control 边界接受。realize 只在 real slot 和目标 frame 对应 PCM window 同时预留后原子提交。准备迟到则保留 virtual 并重新预测未来 group cursor，不能播放旧 seek 位置、追墙钟或先 real 后补数据。
7. 实体化前 group 已 loop/seek/pause、job 被取消或 generation 改变时丢弃旧 ticket；required layer 无法满足最小集合沿显式 transition failure/emergency 路径，optional layer 的 deferred/dropped 原因写 trace。

## 接口与数据契约
`PlatformProfile` 含 max real/virtual/groups/stingers、resident/stream bytes、audibility window、realize/virtualize threshold、hysteresis 和最小保持 frames；初始化验证 threshold 顺序与所有容量乘法。`VoiceBudgetExceeded` 必须带 reason enum 和所需/可用数量进入 trace。

## 文件变更
- 新增 virtualization module/tests。
- 修改 group/mixer 状态执行。

## 验证
### 自动化验证
- `zig build test`。
- release profile exact 值、budget 边界、audibility oracle、hysteresis、base protection、deterministic tie-break、virtual 100 bars 后 realize cursor 0 skew、seek failure。
- 真实长 Opus streaming 经至少 100 bars virtual 后 prepare/seek/realize，在完成早/晚、ring wrap、seek 后 loop、pause/resume、cancel/unload、worker completion 逆序时逐 sample 验证 realized cursor 与 group 0 skew；相同已记录 readiness/completion 输入重放相同实体化 frame。
### 手工验证
- 不需要。
### 边界与失败场景
- virtual capacity 也满；required layer 被错误 drop；generation 已回收。

## 完成定义
- [ ] 本任务已交付测试/fixture 通过 TASK-001 的稳定注册 seam 加入既有 `zig build test`/PR gate，证据随子交付持续产生，不等待 TASK-021 首次接入 CI。
- [ ] virtual voice 不执行 sample DSP但推进全部逻辑时间。
- [ ] realize 与 group cursor 对齐。
- [ ] profile/保护/drop 均有 trace。
- [ ] 资源不足不静默成功。
- [ ] release `PlatformProfile` 的具体预算、audibility 口径和 hysteresis 已冻结并写入 evidence。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐实际依赖、量化/输入契约、独立审查产物与持续 gate；仅修订任务文档，状态保持 `TODO`。

## 风险与注意事项
不要在 render thread计算 audibility 排序；避免 O(N log N) 和不可预测分配。


