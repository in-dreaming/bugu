# TASK-007：实现复杂 tempo/meter compiler 与 sample-accurate Clock

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Timing/Compiler
- 评审角色：确定性数值、音乐时间、QA
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-007/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-007/`（原始产物）
- 执行波次：4
- 硬依赖：TASK-002、TASK-003、TASK-004
- 协作关系：TASK-008/009/012/017 使用同一 grid/query library
- 预计改动范围：`src/music/clock.zig`、`tools/sme_compiler/tempo.zig`、`tests/sme/tempo_clock_test.zig`（新增）、MusicBank tempo tables

## 目标
支持 constant/linear_seconds tempo region、meter change、pickup、authored anchors 和 loop closure，生成整数 grid，并提供 frame/tick/beat/bar/cue 双向查询。

## 上下文
不能用游戏 delta 或每 quantum 浮点累加；tempo ramp 必须在 compiler 中确定性展开。

## 前置条件
- absolute render frame。
- MusicBank table extension registry。
- trace schema。

## 实施范围
### 必须完成
- PPQ/milli-BPM source model：v1 默认 PPQ=960 ticks/quarter-note；允许 24–9600 的 24 整数倍。`milli_bpm` 始终表示四分音符每分钟的千分之一，范围 1,000–1,000,000（1–1000 quarter-note BPM），不能随 meter denominator 改变单位。数值写入 source schema、compiler report 与 fixtures。
- `TempoRegion` constant/linear_seconds、`MeterChange`、sample anchor；`linear_seconds` 固定为 BPM 对 elapsed seconds 线性，禁止实现为对 ticks 线性。
- meter numerator 1–32，denominator 仅 1/2/4/8/16/32；每小节 ticks=`PPQ * 4 * numerator / denominator`，每个 denominator note ticks=`PPQ * 4 / denominator`。`beat_groups` 为正整数数组且总和为 numerator，决定 next_beat 的音乐 pulse；不得把 numerator 直接当四分音符拍数。
- compiler 生成 BeatGrid/BarGrid/TempoSpan；anchor error <1 sample，loop error=0。
- runtime bounded binary/index lookup。
- pause/resume/loop epoch 与 device discontinuity time semantics。
- strict-next beat/bar/cue behavior。

### 明确不包含
- transition rule/cue compatibility。
- runtime timestretch/pitchshift。

## 设计与执行细节
1. 定点/宽整数计算；检测 overflow/倒退/重复 frame。tempo region 编码安全上限 65,536、物化 grid entries 编码安全上限 16,777,216；这是本修订提出的格式上界，不是平台可用容量承诺。TASK-003/007须根据实际entry大小、索引和compiler/runtime峰值内存推导并测试更低或相等的profile有效上限，保存取值并在构建前拒绝超限；证明所有中间乘法用足够宽的 checked arithmetic 覆盖 24h 和 1e6 loop 测试，超限返回 `InvalidTempo`，不截断。实现精度必须由独立 oracle 证明，不能靠同一函数导出的 golden 自证。
2. meter change 只能在声明的合法 bar tick；pickup 单独表达 bar offset。简单 meter 默认 `[1,...,1]`；6/8、9/8、12/8 的 canonical default 分别为 `[3,3]`、`[3,3,3]`、`[3,3,3,3]`，compiler 必须把解析后的数组显式写入 IR/bank/report，不能只藏在 UI 里；非等分 meter 必须由作者显式给组，缺失报 `AmbiguousBeatGrouping`。6/8 `[3,3]` 在 120 quarter-note BPM 时，每 bar=72,000 frames、next_beat pulse=36,000 frames（48 kHz）；若作者写 `[1,1,1,1,1,1]`，pulse=12,000 frames，两者均合法且不能静默互换。
3. ramp span 的 beat frames 由 compiler materialize。设 quarter-note beat 数 `q=(end_tick-start_tick)/PPQ`，两端 BPM 为 `b0,b1`，time-linear span duration `T=120*q/(b0+b1)` 秒，`b(t)=b0+(b1-b0)*t/T`，累积 beats `q(t)=(b0*t+(b1-b0)*t*t/(2*T))/60`。按单调正根反求 beat/tick 对应 seconds；constant 分支用有理数，`b0==b1` 不走除零分支。compiler/runtime query 与 authoring graph 统一此定义。
4. 每个边界由从 span/anchor 原点计算的累计精确位置取最近 integer frame，正好半 sample 使用 ties-to-even；禁止逐拍四舍五入后累加。作者 anchor 的 frame 为权威，先以独立名义曲线检查每个 anchor 的误差严格 <1 sample；相邻 anchor 间将端点残差按未舍入 elapsed-time 比例确定性分配，再统一 rounding，anchor 必须 exact。无法在全部 anchors/单调 grid/容量约束下满足该规则时报 `AnchorMismatch`，不可任意拉伸容错。
5. loop end grid 必须与 loop start phase 闭合。存储一份 `[loop_start,loop_end)` 相位 grid，用整数 loop length 与 epoch 计算绝对 frame，不反复重新积分；重复或倒退的不同 musical grid 边界报错，等 frame 的同一语义边界去重保留 tags。
6. Clock 查询不分配，worst-case 有界；frame→tick 采用“该 frame 上不晚于它的最大 tick”floor 规则，strict-next beat/bar 查找使用 `boundary_frame > accepted_request_frame`，同时服从 scheduler 可提交 frontier。超过有效 segment 的查询明确返回范围错误。

## 接口与数据契约
`TempoMapId`、`TempoSpan`、`MusicalPosition { tick,bar,beat,subdivision }`。`beat` 是 meter `beat_groups` 的零基 pulse index；beat-duration/ramp 字段的 quarter-note 单位必须用 `quarter_beats` 明名，与 pulse index 分开。Tempo source header 显式携带 PPQ、BPM beat-unit=`quarter_note`、ramp-domain=`seconds`、rounding=`nearest_ties_even`；compiler 不接受 0、超范围或不能满足 grid/anchor 预算的 PPQ。失败：`InvalidTempo`、`InvalidMeter`、`AmbiguousBeatGrouping`、`AnchorMismatch`、`NonClosingLoop`。

## 文件变更
- 新增 clock/compiler/tests，以及独立参考 `tests/sme/reference/tempo_oracle.py`（计划新增、仅生成可审查 fixture，不进入 runtime；使用至少 80 位十进制精度）。golden fixture 附 source formula、精度、source hash、expected unrounded frames 与 rounded frames，不能调用 Zig compiler 的时间转换函数。
- 扩展 TASK-003 TempoTable validator，不创建第二 schema。

## 验证
### 自动化验证
- `zig build test`。
- 默认/最小/最大 PPQ、60/120/123.456 BPM、线性 accel/ritard、3/4→7/8、6/8 `[3,3]`/`[1,1,1,1,1,1]`、pickup、长达 24h、loop 1e6 epochs、边界前/上/后、malformed anchors。
- 60→120 BPM、4 quarter notes 的 time-linear ramp duration 必为 8/3 秒，48 kHz 末 frame=128,000；中间 beats 使用独立 ≥80 位 oracle，加入 ticks-linear 错误实现会产生不同结果的反例。
- ties-to-even 正负半 sample 残差、anchor 误差 0/0.999/1 sample、相邻 anchor 不可满足、跨 ramp 的 round-trip floor、meter denominator/bar 长度与 loop anchor exact；所有 integer schedule frames exact 比较，不仅统计平均误差。
### 手工验证
- 导出一份 grid CSV 检查；CSV 不是通过的唯一证据。
### 边界与失败场景
- BPM=0、denominator 非法、tick overflow、anchor non-monotonic、loop 不闭合。

## 完成定义
- [ ] 本任务已交付测试/fixture 通过 TASK-001 的稳定注册 seam 加入既有 `zig build test`/PR gate，证据随子交付持续产生，不等待 TASK-021 首次接入 CI。
- [ ] 全部 grid 只由 compiler 生成且重复构建一致。
- [ ] runtime 查询无浮点累积漂移。
- [ ] loop skew 0 frame。
- [ ] 错误 tempo map fail closed。
- [ ] PPQ/BPM/meter/grid 上限、quarter-note 单位、beat grouping、seconds-linear ramp、anchor 残差和 rounding 已冻结，compiler report 可审计实际取值。
- [ ] 独立高精度 oracle/手算 anchors 均通过，且错误分母、ticks-linear ramp 与逐拍 rounding 变异测试均被 gate 捕获。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐实际依赖、量化/输入契约、独立审查产物与持续 gate；仅修订任务文档，状态保持 `TODO`。

## 风险与注意事项
不要用近似“每拍 round”累积误差；误差必须在 anchor 区间内确定性分配。


