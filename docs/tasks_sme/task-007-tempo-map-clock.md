# TASK-007：实现复杂 tempo/meter compiler 与 sample-accurate Clock

## 元数据
- 状态：待实施
- 执行波次：2
- 硬依赖：TASK-002、TASK-003、TASK-004
- 协作关系：TASK-008/009/012/017 使用同一 grid/query library
- 预计改动范围：`src/music/clock.zig`、`tools/sme_compiler/tempo.zig`、`tests/sme/tempo_clock_test.zig`（新增）、MusicBank tempo tables

## 目标
支持 constant/linear tempo region、meter change、pickup、authored anchors 和 loop closure，生成整数 grid，并提供 frame/tick/beat/bar/cue 双向查询。

## 上下文
不能用游戏 delta 或每 quantum 浮点累加；tempo ramp 必须在 compiler 中确定性展开。

## 前置条件
- absolute render frame。
- MusicBank table extension registry。
- trace schema。

## 实施范围
### 必须完成
- PPQ/milli-BPM source model。
- `TempoRegion` constant/linear、`MeterChange`、sample anchor。
- compiler 生成 BeatGrid/BarGrid/TempoSpan；anchor error <1 sample，loop error=0。
- runtime bounded binary/index lookup。
- pause/resume/loop epoch 与 device discontinuity time semantics。
- strict-next beat/bar/cue behavior。

### 明确不包含
- transition rule/cue compatibility。
- runtime timestretch/pitchshift。

## 设计与执行细节
1. 定点/宽整数计算；检测 overflow/倒退/重复 frame。
2. meter change 只能在声明的合法 tick；pickup 单独表达 bar offset。
3. ramp span 的 beat frames 由 compiler materialize。
4. loop end grid 必须与 loop start phase 闭合。
5. Clock 查询不分配，worst-case 有界。

## 接口与数据契约
`TempoMapId`、`TempoSpan`、`MusicalPosition { tick,bar,beat,subdivision }`。失败：`InvalidTempo`、`InvalidMeter`、`AnchorMismatch`、`NonClosingLoop`。

## 文件变更
- 新增 clock/compiler/tests。
- 扩展 TASK-003 TempoTable validator，不创建第二 schema。

## 验证
### 自动化验证
- `zig build test`。
- 60/120/123.456 BPM、线性 accel/ritard、3/4→7/8、pickup、长达 24h、loop 1e6 epochs、边界前/上/后、malformed anchors。
### 手工验证
- 导出一份 grid CSV 检查；CSV 不是通过的唯一证据。
### 边界与失败场景
- BPM=0、denominator 非法、tick overflow、anchor non-monotonic、loop 不闭合。

## 完成定义
- [ ] 全部 grid 只由 compiler 生成且重复构建一致。
- [ ] runtime 查询无浮点累积漂移。
- [ ] loop skew 0 frame。
- [ ] 错误 tempo map fail closed。

## 风险与注意事项
不要用近似“每拍 round”累积误差；误差必须在 anchor 区间内确定性分配。

