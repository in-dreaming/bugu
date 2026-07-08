# Bugu 音频引擎任务总览

状态：Draft v0.1  
最后更新：2026-07-08  
使用方式：agent pick 任务前，先读 docs/tasks/asetup.md，再读本文件，再读具体任务文件。

最近审查：[task-review-2026-07-07.md](task-review-2026-07-07.md)

## 1. 当前总体进度

| 阶段 | 状态 | 说明 |
|---|---|---|
| 任务系统建立 | DONE | 已创建 asetup、总览和 T001-T013 任务文件。 |
| 核心调研 | TODO | 需要补齐后端、codec、声学传播、参考中间件对比。 |
| 核心架构设计 | TODO | 需要固化线程模型、Zig API、可选 C ABI、模块边界、实时安全 contract。 |
| P0 运行时实现 | TODO | Zig 实现的设备 backend、mixer、voice、bus、asset MVP；三方依赖必须 submodule。 |
| 空间音频基线 | TODO | attenuation、cone、Doppler、HRTF 之前的基础 3D。 |
| 复合声学传播 | TODO | acoustic scene、voxel、materials、CPU propagation MVP。 |
| GPU propagation | TODO | CPU correctness 之后再做 GPU compute / ray query 设计和 spike。 |
| 验证与调试 | TODO | 自动化测试、profile、debug visualization、场景矩阵；可视化必须使用 in-dreaming/gpu。 |

## 2. Critical Path

优先级从高到低：

1. T001：后端、decoder、codec 选型补充调研。
2. T002：实时运行时 contract 与线程模型设计。
3. T003：Zig API、可选 C ABI 与模块边界设计。
4. T004：P0 Zig 设备后端实现。
5. T005：Mixer、Voice、Bus core 实现。
6. T006：Asset import、decode、Bank MVP。
7. T007：Event、Parameter、State、Switch runtime。
8. T008：基础空间化 attenuation、cone、Doppler。
9. T009：Acoustic scene、voxel、materials、portal 设计。
10. T010：CPU 复合声学传播 MVP。
11. T011：AcousticResponse 到 mixer 的映射。
12. T012：验证、profile、debug visualization。
13. T013：GPU propagation 设计与 spike。
14. T014：Runtime acoustic effects integration。
15. T015：Event-driven acoustic runtime integration。
16. T016：Effect bus abstraction。

## 3. 任务列表

| ID | 状态 | 任务 | 类型 | 依赖 | 产物 |
|---|---|---|---|---|---|
| T001 | DONE | [后端、decoder、codec 选型补充调研](T001-backend-decoder-codec-research.md) | Research | 无 | [调研文档、推荐矩阵、ADR 输入](../research/audio-backend-decoder-codec.md) |
| T002 | DONE | [实时运行时 contract 与线程模型设计](T002-realtime-runtime-contract.md) | Design | T001 可并行 | [线程模型、队列、snapshot、红线](../design/audio-runtime-contract.md) |
| T003 | DONE | [Zig API、可选 C ABI 与模块边界设计](T003-zig-api-module-boundaries.md) | Design | T002 | [API 草案、模块依赖图、生命周期](../design/audio-zig-api.md) |
| T004 | DONE | [P0 Zig 设备后端实现](T004-zig-p0-backend.md) | Implementation | T002,T003 | Zig miniaudio/offline backend、fixed quantum tone demo、submodule |
| T005 | DONE | [Mixer、Voice、Bus core 实现](T005-mixer-voice-bus-core.md) | Implementation | T002,T003,T004 | fixed quantum mixer、64 voice pool、SFX/Music/Master bus、telemetry |
| T006 | DONE | [Asset import、Decode、Bank MVP](T006-asset-decode-bank-mvp.md) | Implementation | T001,T003,T005 | WAV/PCM importer、TOML manifest、float32 blob、preload Bank |
| T007 | DONE | [Event、Parameter、State、Switch runtime](T007-event-parameter-runtime.md) | Design+Implementation | T003,T005,T006 | post_event -> event resolve -> sample voice, random/switch/RTPC |
| T008 | DONE | [基础空间音频：attenuation、cone、Doppler](T008-spatial-baseline.md) | Design+Implementation | T005,T007 | AttenuationProfile、cone、Doppler、pan/filter/pitch demo |
| T009 | DONE | [Acoustic scene、voxel、materials、portal 设计](T009-acoustic-scene-voxel-materials.md) | Research+Design | T008 | [声学场景表示和数据结构](../design/acoustic-scene.md) |
| T010 | DONE | [CPU 复合声学传播 MVP](T010-cpu-acoustic-propagation-mvp.md) | Implementation | T009 | CPU solver、AcousticResponse、[six-scene snapshot](../validation/acoustic-t010-response-snapshot.json) |
| T011 | DONE | [AcousticResponse 到 mixer 的映射](T011-acoustic-response-mixer-mapping.md) | Design+Implementation | T010,T005 | AcousticSnapshot mapping、mixer delayed layers、[mapping snapshot](../validation/acoustic-t011-mapping-snapshot.json) |
| T012 | DONE | [验证、profile、debug visualization](T012-validation-profile-debug.md) | Validation+Tooling | T004-T011 | [测试矩阵/profile/debug 计划](../validation/audio-validation-plan.md)、validation-report |
| T013 | DONE | [GPU propagation 设计与 spike](T013-gpu-propagation-design-spike.md) | Research+Prototype | T010,T012 | [GPU acoustic propagation design](../design/gpu-acoustic-propagation.md)、[validated GPU spike](../validation/gpu-acoustic-spike-report.txt) |
| T014 | DONE | [Runtime acoustic effects integration](T014-runtime-acoustic-effects.md) | Implementation | T011,T012,T013 | VoiceHandle/update、real reverb send、[effects snapshot](../validation/acoustic-t014-effects-snapshot.txt) |
| T015 | DONE | [Event-driven acoustic runtime integration](T015-event-driven-acoustic-runtime.md) | Implementation | T007,T010,T011,T014 | `postAcousticEvent`、`AcousticEventInstance.update`、[event acoustic snapshot](../validation/acoustic-t015-event-runtime-snapshot.txt) |
| T016 | DONE | [Effect bus abstraction](T016-effect-bus-abstraction.md) | Implementation | T005,T014,T015 | fixed `EffectBuses`、public controls、[effect bus snapshot](../validation/acoustic-t016-effect-bus-snapshot.txt) |

## 4. 任务依赖图

文本依赖：

- T001 可与 T002 并行。
- T003 依赖 T002 的线程与生命周期结论。
- T004 依赖 T003 的 device API。
- T005 依赖 T004 提供 callback 输出路径。
- T006 依赖 T005 的 voice 数据需求和 T001 的 codec 结论。
- T007 依赖 T006 的 SoundEntry 和 T005 的 voice handle。
- T008 依赖 T007 能触发 3D sound。
- T009 依赖 T008 的空间参数模型。
- T010 依赖 T009 的 acoustic scene。
- T011 依赖 T010 的 AcousticResponse 和 T005 的 mixer。
- T012 可从 T004 开始逐步补，最终覆盖 T011。
- T013 必须在 T010 CPU correctness 成立后开始。
- T014 依赖 T011 snapshot mapping，并将 acoustic layer 参数接入真实 mixer effect path。
- T015 依赖 T007 event runtime 和 T014 voice update path，将 posted event 返回的 handles 接入 acoustic snapshot 更新。
- T016 依赖 T014/T015 的 reverb send 使用者，将 ad hoc reverb delay line 固化为 effect bus abstraction。

## 5. 当前建议 pick

如果是第一个 agent，建议从 T001 或 T002 开始：

- 偏调研能力：pick T001。
- 偏架构能力：pick T002。
- 偏实现能力：等 T002/T003 完成后再 pick T004。

## 6. 新增硬约束

- Bugu 必须用 Zig 实现。任务中出现 C API 时，应理解为“可选 C ABI 导出层”，不是引擎主体实现语言。
- 三方库必须通过 git submodule 引入。
- 如果使用 SDL，必须使用 https://github.com/in-dreaming/SDL.git 的 enjin/gpu/main 分支。
- 如果 demo 或工具需要可视化，必须使用 https://github.com/in-dreaming/gpu RHI。

## 7. 完整性与防 mock gate

任何实现任务要从 REVIEW 进入 DONE，必须满足：

1. 真实代码路径执行过，不能只是 stub、mock、固定返回值或设计文档。
2. Evidence 中有执行命令、输入、输出摘要、失败/限制说明。
3. 如果用了 fallback，必须说明 fallback 是否被该任务验收标准允许；不允许则不能 DONE。
4. 没有违反 Zig、submodule、SDL fork、in-dreaming/gpu、实时安全红线。
5. docs/tasks/asetup.md 中新增的公共事实已经同步。
6. T012 的验证计划或记录能追踪该任务的关键验收项。

## 8. Fallback 策略总览

| 场景 | 允许 fallback | 不能做 |
|---|---|---|
| 无音频设备或 CI 环境 | Null/Offline backend 真实生成 PCM/WAV；设备 backend 验收仍需真实设备记录 | 空 callback 返回成功 |
| SDL 不可用 | 回到 miniaudio 或 native backend；若任务要求 SDL 则标 BLOCKED | 使用 upstream SDL 替代 in-dreaming/SDL |
| in-dreaming/gpu 不可用 | 输出非可视化 JSON/CSV/profile；可视化实现任务标 BLOCKED/REVIEW | 使用其他 RHI/窗口库 |
| GPU tracing 不可用 | CPU propagation backend | 私接 DXR/Vulkan/Metal 绕过 in-dreaming/gpu |
| codec 未接入 | 明确只支持 PCM/WAV 子集 | 假装支持 streaming/seek |
| acoustic solver 不完整 | 降级到 direct + penetration 等明确子集 | 按场景名硬编码 AcousticResponse |

## 9. 需求到任务追踪

| 核心需求 | 覆盖任务 | 完整性检查 |
|---|---|---|
| Zig 主体实现 | T003-T011 | build.zig、Zig modules、无 C/C++ 主体实现 |
| 第三方 submodule | T001、T004、T006、T012、T013 | .gitmodules、固定 URL/branch/commit、build.zig 接入 |
| SDL fork/branch | T001、T004 | 只允许 in-dreaming/SDL.git enjin/gpu/main |
| 可视化走 in-dreaming/gpu | T012、T013 | 无其他 RHI/窗口库 |
| 实时安全 | T002、T004、T005、T011 | audio render thread 无 alloc/lock/I/O/GPU wait |
| 自研 mixer | T005 | backend callback 调 mixer，非直接 sine |
| 真实 asset pipeline | T006 | 读取真实 WAV/PCM，生成 metadata/blob |
| 事件驱动 | T007 | post_event 驱动 voice，不直接操作内部 voice |
| 基础 3D | T008 | transform -> attenuation/cone/Doppler 参数 |
| 复合声学传播 | T009-T011 | voxel/material/portal -> AcousticResponse -> mixer |
| GPU 是加速不是主路径 | T013 | CPU correctness 先成立，GPU 不输出 PCM |
| 验证/profile | T012 | 测试矩阵、p99/p999、dropout、声学 case |
| 真实 runtime effects | T014 | AcousticSnapshot -> VoiceHandle/update -> delayed layers/reverb send -> offline render telemetry |
| 事件驱动 acoustic runtime | T015 | post_event -> sample voice handles -> AcousticSnapshot update -> offline render telemetry |
| effect bus abstraction | T016 | voice sends -> fixed effect bus -> return bus -> master telemetry |

## 10. 更新规则

任何任务完成后必须：

1. 更新本文件中的状态。
2. 在对应任务文件中更新 Activity Log。
3. 如果出现新公共事实，更新 docs/tasks/asetup.md。
4. 如果产出新设计文档，在本文件产物列补链接。
5. 如果任务范围改变，写明原因，不要静默扩展。
