# T005 Mixer、Voice、Bus core 实现

状态：TODO  
类型：Implementation  
优先级：P0  
依赖：T002，T003，T004  
预计产物：固定 quantum mixer、voice pool、simple bus、测试 demo。

## 1. 背景

Mixer core 是引擎心脏。P0 目标不是音质极致，而是稳定、可测、实时安全。

## 2. 必读

- docs/tasks/asetup.md
- docs/design/audio-engine-design.md 第 5、6、12、14 节
- T002、T003、T004 产物

## 3. 实现范围

必须实现：

- fixed quantum mixer，默认 256 frames，内部 float32。
- Voice pool，至少 64 real voices。
- Voice state：Free、Starting、Real、Virtual、Releasing、Stolen、Paused。
- mono input 到 stereo output。
- gain ramp，避免 click。
- simple bus：SFX、Music、Master 至少三类。
- simple limiter 或 clipping counter。
- telemetry：active voices、virtual voices、stolen voices、peak、RMS、mixer time。

## 4. 不需要实现

- 完整 Bus DAG。
- HRTF。
- 复杂 effect chain。
- streaming decode。
- acoustic propagation。

## 5. 验收标准

- 可同时播放 64 个 test voices，无明显爆音。
- 超过 voice limit 时触发可解释的 stealing 策略。
- 所有热路径无动态分配。
- gain ramp 能避免 start/stop click。
- telemetry 可从非 audio thread 查询。
- demo 证明 backend callback 调用 mixer，而不是直接生成 sine。
- Evidence 必须包含真实 sample buffer 的 peak/RMS、voice count、steal count、mixer time 记录。
- 至少一个测试必须离线渲染固定输入并比较输出摘要，避免“听起来可以”成为唯一证据。

## 6. 测试场景

- 1 voice sine。
- 64 voices 不同频率和 gain。
- 128 voice requests，确认 stealing。
- 快速 start/stop 1000 次。
- master volume ramp。

## 6.1 禁止 mock

- 不能用预混好的 wav 或固定数组冒充 mixer 输出。
- 不能只更新 telemetry 而不生成 sample。
- voice stealing 必须基于 voice state/priority/audibility 数据，不能按调用次数硬编码。

## 7. Activity Log

- 2026-07-07：任务创建。
