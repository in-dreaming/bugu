# Bugu 任务规划审查报告

日期：2026-07-07  
范围：docs/tasks/asetup.md、docs/tasks/tasks.md、T001-T013  
审查目标：检查任务是否明确、是否可能导致方向偏移、fallback 是否安全、完整性是否可追踪、是否可能诱导 mock/fake 实现。

## 1. 总体结论

任务拆分的主线是合理的：

- 先调研和 runtime contract。
- 再 Zig API 和 backend。
- 再 mixer、asset、event、spatial baseline。
- 再 acoustic scene、CPU propagation、AcousticResponse mapping。
- 最后验证体系和 GPU spike。

但初版存在几类风险：

1. 部分实现任务容易用 stub 或固定数据“跑通”。
2. fallback 没有统一定义，容易把降级方案伪装成完成。
3. T004-T011 的 Evidence 要求不够硬，容易只写“完成”。
4. T012 容易被当作最后补文档，而不是持续 gate。
5. T010/T011 最容易偏移成按场景名硬编码 AcousticResponse 或 mixer 参数。
6. T013 如果 RHI 能力不足，可能诱导绕过 in-dreaming/gpu 私接平台 API。

本次已直接修正任务文档，新增全局 fallback、禁止 mock 完成、Evidence 和完整性 gate。

## 2. 已修正的问题

### 2.1 Fallback 规则不明确

已在 docs/tasks/asetup.md 增加“Fallback 规则”：

- 允许真实降级实现，例如 offline backend 生成 PCM/WAV、GPU 不可用时走 CPU propagation。
- 禁止空函数 success、固定常量、按场景名硬编码、外部播放器冒充、非 submodule 依赖。
- 只能完成 fallback 时，状态最多 REVIEW，除非任务验收明确允许该 fallback 作为 DONE。

### 2.2 Mock/fake 实现风险

已在 docs/tasks/asetup.md 增加“禁止 mock 完成”：

- backend 必须走真实 backend 或真实 offline render。
- mixer 必须产生真实 sample buffer。
- asset 必须读取真实音频文件。
- event 必须走 post_event 到 voice 的真实链路。
- spatial 必须从 transform 计算。
- acoustic propagation 必须从 voxel/material/portal 计算。
- GPU spike 必须走 in-dreaming/gpu 真实 API 或明确阻塞。

### 2.3 总览缺少 gate

已在 docs/tasks/tasks.md 增加：

- “完整性与防 mock gate”。
- “Fallback 策略总览”。
- “需求到任务追踪”矩阵。

### 2.4 高风险任务补强

已补强：

- T004：真实设备 backend 才能满足播放验收；offline backend 只能作为 CI fallback。
- T005：必须提供真实 sample buffer 的 peak/RMS、voice count、steal count、mixer time。
- T006：必须读取真实 WAV，生成真实 metadata/manifest/blob。
- T007：必须证明 post_event -> event resolve -> voice request -> mixer/voice 状态变化。
- T008：必须提供 transform -> gain/pan/filter/pitch 数值轨迹。
- T009：必须产出 T010 可直接使用的最小 test scene 数据格式。
- T010：禁止按场景名硬编码 AcousticResponse；必须从 scene/voxel/material/portal 输入计算。
- T011：禁止按场景名手写 mixer 参数；必须经 AcousticSnapshot。
- T012：声明为持续 gate，不是末尾补文档。
- T013：RHI 能力不足时必须输出 capability gap，不能绕过 in-dreaming/gpu。

## 3. 逐项审查

| 任务 | 明确性 | 偏移风险 | Mock 风险 | 本次处理 |
|---|---|---|---|---|
| T001 | 较明确 | 中：可能调研 upstream SDL | 低 | 强化 SDL fork/branch、submodule、fallback 决策、版本来源 |
| T002 | 明确 | 低 | 低 | 增加 fallback backend/device lost/GPU missing 边界 |
| T003 | 明确 | 中：可能回到 C-first | 低 | 强化 Zig-first、可选 C ABI、build.zig、adapter 边界 |
| T004 | 中 | 中：可能绑死第三方 backend | 高 | 增加真实设备验收、offline fallback 限制、禁止空 callback |
| T005 | 中 | 中：可能只做 sine mixer | 高 | 增加真实 sample/telemetry/evidence、防预混数据 |
| T006 | 中 | 中：可能绕过 Bank | 高 | 增加真实 WAV、metadata/blob、禁止 runtime 直接读源 wav |
| T007 | 中 | 中：可能直接调 voice | 高 | 增加 event chain evidence、State/Switch/RTPC 未实现不得 DONE |
| T008 | 中 | 中：可能手写曲线 | 中 | 增加 transform 数值轨迹和禁止手填 pan/gain |
| T009 | 较明确 | 中：可能退化为 mesh raycast | 低 | 增加最小 test scene、声学专用数据要求 |
| T010 | 中 | 高：可能硬编码六场景 | 高 | 增加禁止场景名硬编码、输入输出 snapshot 证据 |
| T011 | 中 | 高：可能绕过 snapshot | 高 | 增加 AcousticSnapshot 强制路径、禁止按场景写参数 |
| T012 | 中 | 中：可能最后补文档 | 中 | 改成持续 gate，增加 CI/真实设备区分和防 mock 清单 |
| T013 | 中 | 中：可能绕过 RHI | 高 | 增加 in-dreaming/gpu capability gate 和真实 dispatch/probe evidence |

## 4. 剩余风险

### 4.1 当前任务还没有实际源码结构

目前仓库主要是文档。T003 应尽快定义 Zig 模块树、build.zig 结构和 third_party_adapters 目录，否则 T004/T005 容易各自发明结构。

建议：优先做 T002 和 T003，再开始实现。

### 4.2 T001 与 ADR-003 存在轻微张力

asetup 中 ADR-003 仍写 P0 使用 miniaudio backend；但新约束允许如果使用 SDL，则必须使用 in-dreaming/SDL。T001 需要确认 P0 是否仍 miniaudio。若不是，必须更新 ADR-003。

建议：T001 产出后同步更新 ADR。

### 4.3 T012 应尽早启动

虽然 T012 依赖 T004-T011 可逐步补齐，但验证计划应尽早创建。否则前面任务的 Evidence 格式会各写各的。

建议：T012 可以拆出 T012a“验证框架与 Evidence schema”，与 T004 并行。

### 4.4 CPU acoustic MVP 仍有复杂度风险

T010 范围虽然写了 MVP，但 direct、penetration、escape、reflection、portal 同时做仍可能偏大。

建议：T010 实施时分两个 PR/子任务：

1. T010a direct + penetration + 3-band material。
2. T010b portal + escape + single-bounce reflection。

### 4.5 可视化和 GPU 依赖外部 RHI 状态

in-dreaming/gpu 能力未知。T012/T013 已要求 capability gap，但后续可能需要新增 RHI 调研任务。

建议：若 T013 前发现 RHI 文档不足，新增 T013a in-dreaming/gpu capability research。

## 5. 后续建议

推荐下一步：

1. 先做 T001，明确 miniaudio / in-dreaming SDL / codec / submodule 方案。
2. 并行做 T002，固化实时 contract。
3. 做 T003，定义 Zig 模块树和 build.zig。
4. 提前启动 T012 的 Evidence schema，避免 T004 开始后证据格式混乱。

## 6. 审查判定

当前 docs/tasks 已达到“可由 agent 接手”的最低标准，但正式实现前仍建议先完成 T001-T003。

不得直接从 T010/T013 开始；那会绕过底层 contract 和 CPU correctness，导致声学系统漂移。

