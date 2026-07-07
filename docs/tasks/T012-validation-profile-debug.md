# T012 验证、profile、debug visualization

状态：DONE  
类型：Validation+Tooling  
优先级：P1/P2  
依赖：T004-T011 可逐步补齐  
预计产物：[测试矩阵/profile/debug 计划](../validation/audio-validation-plan.md)、profile 工具、基于 in-dreaming/gpu 的 debug visualization 方案。

## 1. 背景

音频 bug 很容易变成“感觉不对”。本任务要建立可重复的验证体系，覆盖稳定性、实时安全、声学 case 和性能。

本任务是持续 gate：从 T004 开始，每个实现任务都必须留下可被本任务收集的 Evidence。T012 不是最后补一篇文档就结束。

## 2. 必读

- docs/tasks/asetup.md
- docs/design/audio-engine-design.md 第 13、14、15、16 节
- 已完成的 T004-T011 产物

## 3. 验证范围

必须覆盖：

- backend start/stop/device lost。
- mixer real/virtual voice 压力。
- stream buffer underrun。
- event random/state/switch。
- attenuation/cone/Doppler。
- acoustic propagation 六个核心场景。
- audio render thread 最大耗时、p99、p999。
- dropout/underrun 计数。

## 4. Debug visualization

如果实现任何可视化 demo 或工具，必须使用 https://github.com/in-dreaming/gpu 作为 RHI 层，并通过 git submodule 引入。不得临时引入其他渲染、窗口或可视化框架。纯文本日志、CSV、JSON profile 不受此限制。

至少设计或实现：

- active/virtual/stolen voices。
- bus meter。
- stream buffer 水位。
- listener/emitter/cone。
- acoustic voxel。
- direct、penetration、reflection、escape rays。
- portal/opening。
- AcousticResponse 曲线和 confidence。

## 5. 验收标准

- 输出 docs/validation/audio-validation-plan.md。
- 每个测试有明确通过/失败标准。
- 有一套最小自动化或可重复手工步骤。
- profile 不破坏 audio render thread 实时安全。
- 至少覆盖 T010 的六个声学 case。
- 如包含可视化，明确 in-dreaming/gpu 的 submodule 路径、build.zig 接入方式和最小渲染管线。
- 明确哪些测试可在无音频设备 CI 中跑，哪些必须本地真实设备跑。
- 明确如何判定 mock/stub/fallback 不能通过 DONE。

## 5.1 防 mock 检查清单

- 测试必须验证真实 sample buffer、metadata、event chain 或 AcousticResponse，而不是只检查函数返回 success。
- profile 数字必须来自真实计数器或计时器，不能手写。
- 可视化如果只是设计文档，应标明尚未实现；不能把设计图当运行截图。

## 6. Activity Log

- 2026-07-07：任务创建。
- 2026-07-08：开始实现；已阅读 `docs/tasks/asetup.md`、T012 文件、`docs/design/audio-engine-design.md` 第 13-16 节和 T004-T011 任务证据。
- 2026-07-08：新增 [audio-validation-plan.md](../validation/audio-validation-plan.md)，定义自动化命令、测试矩阵、T010 六个声学场景 pass/fail、profile 规则、CI/本地设备拆分、mock/fallback gate 和未来 in-dreaming/gpu 可视化接入方案。
- 2026-07-08：新增 `examples/validation_report.zig` 与 `zig build validation-report`，输出真实 mixer telemetry、render p50/p99/p999、stolen/clipping/peak/RMS 和六个 acoustic case 的 response/mapping 摘要。
- 2026-07-08：验证命令：`zig build test` 通过；`zig build validation-report` 通过。样例输出保存到 [t012-validation-report-sample.txt](../validation/t012-validation-report-sample.txt)，本次报告显示 96 voice stress -> active=64、stolen=32、clipping=0，并覆盖 open_air/thick_wall/wall_hole/door_open/cave/open_field。
- 2026-07-08：限制：T012 未实现图形可视化；计划明确未来如果实现必须通过 `third_party/in_dreaming_gpu` submodule 和 `build.zig` 接入，当前仅提供文本/JSON debug，不声称有运行截图。
