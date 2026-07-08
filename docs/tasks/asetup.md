# Bugu 音频引擎任务公共上下文

状态：Draft v0.1  
最后更新：2026-07-07  
用途：任何 agent 在 pick docs/tasks 下的任务前，必须先读本文件和 docs/tasks/tasks.md。

## 1. 项目目标

Bugu 是一个游戏音频引擎。当前重点不是做一个简单播放器，而是设计并逐步实现完整的游戏音频运行时：

- 自研 mixer core、voice manager、bus graph、event runtime。
- 短期使用 miniaudio 或 SDL3 Audio 作为设备后端过渡，长期实现 native backend；若选择 SDL，必须使用 in-dreaming/SDL.git enjin/gpu/main。
- SDL_sound 只作为可选 decoder 或导入工具链，不作为底层音频引擎。
- Bugu 必须使用 Zig 实现；C/C++ 只能作为第三方库源码或平台 API 绑定存在，不能成为引擎主体实现语言。
- 所有第三方库必须通过 git submodule 引入，不允许直接复制源码、不允许 vendored zip、不允许包管理器隐式拉取后不入库。
- 如果使用 SDL，必须使用 https://github.com/in-dreaming/SDL.git 的 enjin/gpu/main 分支，不允许直接使用 upstream SDL 作为实现依赖。
- 如果 demo 或工具需要可视化，必须使用 https://github.com/in-dreaming/gpu 这个 RHI 层，不允许临时引入其他渲染/窗口可视化框架。
- 空间音频不是简单的距离衰减和 HRTF，而要支持复合声学传播：墙、洞、门、窗、移动障碍、山洞、开阔地、材质穿透、反射、衍射、混响和环境声泄露。
- 光锥 sounds 的正确理解是 Acoustic Propagation Solver，不是单纯的声源 culling。

## 2. 必读文档

任务开始前必须阅读：

1. docs/tasks/asetup.md
2. docs/tasks/tasks.md
3. 当前任务文件
4. 与任务相关的设计章节：
   - docs/design/audio-engine-design.md
   - docs/research/1.md，仅当需要追溯旧调研时读取

如果任务涉及外部库、API 或现代工具状态，必须核验官方资料或权威来源，并把关键链接写入任务产物。

## 3. 当前高层决策

| 编号 | 决策 |
|---|---|
| ADR-001 | 自研 mixer、Voice manager、Bus graph、Event runtime。 |
| ADR-002 | SDL_sound 仅作为可选 decoder，不进入设备后端设计。 |
| ADR-003 | P0 使用 miniaudio backend 快速打通设备输出。 |
| ADR-004 | 光锥 sounds 是声学传播 solver，不是声源筛选器。 |
| ADR-004b | CPU/GPU propagation backend 输出 AcousticResponse，不直接输出 PCM。 |
| ADR-005 | 距离、cone、air absorption、focus、reverb send、priority、occlusion 归入统一 Attenuation Profile。 |
| ADR-006 | Bugu 引擎主体必须用 Zig 实现；公共 API 优先 Zig-first，必要时提供 C ABI 导出层。 |
| ADR-007 | 第三方依赖必须通过 git submodule 引入。 |
| ADR-008 | 若使用 SDL，只能使用 in-dreaming/SDL.git 的 enjin/gpu/main 分支。 |
| ADR-009 | 可视化 demo/tool 必须使用 in-dreaming/gpu RHI。 |

任何任务如果需要推翻这些决策，不能直接改实现。必须先新增或修改 ADR，并在 docs/tasks/tasks.md 标记为 Blocked: needs design decision。

## 4. 术语约定

| 术语 | 含义 |
|---|---|
| Real voice | 真实参与 DSP 和 mixer 的 voice。 |
| Virtual voice | 只推进时间和事件状态，不生成 sample 的逻辑 voice。 |
| Audio render thread | 设备 callback 或音频渲染线程，必须实时安全。 |
| Audio control thread | 解析事件、更新 voice 状态、消费 worker/GPU 结果的控制线程。 |
| Acoustic scene | 专供声学传播使用的场景表示，不等同于渲染三角网格。 |
| Acoustic voxel grid | 声学体素网格，用于快速估计空气、固体、洞口、薄墙、材质厚度。 |
| Portal/opening | 门、窗、洞、走廊口、山洞出口等声学耦合点。 |
| AcousticResponse | 声学 solver 输出给 mixer 的响应，包括 direct、transmission、diffraction、reflection、reverb、ambient 等参数。 |
| AcousticSnapshot | 音频线程可安全读取的不可变声学状态快照。 |

## 5. 实时安全红线

Audio render thread 禁止：

- 动态分配内存。
- mutex、condition variable、blocking wait。
- 文件 I/O。
- GPU fence wait。
- 日志格式化和 printf。
- 懒加载资产。
- 调用未审计的第三方复杂逻辑。
- 修改复杂共享结构。

Audio render thread 允许：

- 读取不可变 snapshot。
- 固定容量无锁队列。
- 固定容量对象池。
- bounded loop。
- SIMD DSP。
- 写入少量原子 telemetry counter。

## 6. 推荐实现顺序

不要先做 GPU。推荐顺序：

1. Runtime contracts：线程模型、命令队列、snapshot、实时安全规则。
2. Zig API、可选 C ABI 和模块边界。
3. miniaudio P0 backend。
4. Mixer、Voice、Bus、基础 DSP。
5. Asset import、decode、Bank MVP。
6. Event、RTPC、State、Switch。
7. 基础 3D attenuation、cone、Doppler。
8. Acoustic scene、voxel、materials、portal。
9. CPU acoustic propagation MVP。
10. AcousticResponse 到 mixer 的映射。
11. 验证、profile、debug visualization；任何可视化必须使用 in-dreaming/gpu。
12. GPU propagation 设计和 spike。

## 7. 任务状态协议

docs/tasks/tasks.md 是总览。每个任务文件也有状态字段。状态只允许：

- TODO：未开始。
- IN_PROGRESS：正在做。
- BLOCKED：被明确条件阻塞。
- REVIEW：产物完成，等待检查。
- DONE：验收标准全部满足。

开始任务时：

1. 在 docs/tasks/tasks.md 中把任务状态改为 IN_PROGRESS。
2. 在任务文件的 Activity Log 增加一条开始记录。

完成任务时：

1. 确认任务的 Acceptance Criteria 全部满足。
2. 更新任务文件的 Deliverables、Evidence、Activity Log。
3. 更新 docs/tasks/tasks.md 的状态、产物链接、后续任务。
4. 如果产生了新的公共约束、ADR、术语或实现事实，更新本文件。

## 8. 任务产物要求

调研任务必须输出：

- 结论。
- 对比表。
- 推荐方案。
- 风险和反例。
- 来源链接。
- 对后续任务的影响。

设计任务必须输出：

- 明确模块边界。
- 数据结构或接口草案。
- 线程和生命周期说明。
- 错误处理策略。
- 验收用例。

实现任务必须输出：

- 可编译或可运行代码。
- 最小 demo 或测试。
- profile 或日志证据。
- 不破坏实时安全红线。

验证任务必须输出：

- 测试矩阵。
- 自动化脚本或手工步骤。
- 通过/失败标准。
- 回归记录方式。

## 8.1 Fallback 规则

Fallback 只能是“真实的降级实现”，不能是 mock、stub 或硬编码结果。

允许的 fallback：

- 设备不可用时，提供 Null/Offline backend 生成真实 PCM buffer 或 WAV 文件，用于 CI 和自动化测试。
- GPU 不可用时，使用 CPU acoustic propagation backend。
- 可视化不可用时，输出 JSON/CSV/profile 文本；但如果任务要求“可视化实现”，仍不能用其他 RHI 代替 in-dreaming/gpu。
- codec 暂未接入时，只支持明确声明的 PCM/WAV 子集，并在 manifest/文档里限制输入格式。

不允许的 fallback：

- 用空函数返回 success。
- 用固定常量冒充测量结果。
- 用 scenario id 硬编码 acoustic response。
- 用 sleep、随机数或日志文本冒充实时处理。
- 用外部播放器、系统命令或非 Bugu mixer 冒充音频链路。
- 用非 submodule 的临时下载依赖完成构建。

如果任务只能完成 fallback：

1. 状态最多只能到 REVIEW，除非任务验收标准明确允许该 fallback 作为 DONE。
2. 必须在任务文件 Evidence 写明 fallback 的触发条件、覆盖范围和缺口。
3. 必须在 docs/tasks/tasks.md 记录后续补齐任务或阻塞条件。

## 8.2 禁止 mock 完成

实现任务标记 DONE 前，必须证明产物跑过真实代码路径：

- backend 任务必须调用真实设备 backend，或在无设备环境下调用真实 offline render backend 生成 PCM；不能只构造对象。
- mixer 任务必须产生真实 sample buffer，并有 peak/RMS 或 sample diff 证据。
- asset 任务必须读取真实音频文件并生成真实 metadata/blob。
- event 任务必须通过 event runtime 驱动 voice 创建或停止，不能直接调用 voice 内部函数冒充。
- spatial 任务必须从 listener/emitter transform 计算参数，不能手填预期 pan/gain。
- acoustic propagation 任务必须从 voxel/material/portal 数据计算 AcousticResponse，不能按场景名返回常量。
- GPU spike 必须通过 in-dreaming/gpu 的真实 API 路径；如果 RHI 能力不足，输出阻塞/设计结论，不得私接其他图形 API 冒充。

每个实现任务必须在 Evidence 中列出：

- 执行命令。
- 输入数据。
- 输出摘要。
- 失败时的错误信息或缺口。
- 与验收标准的逐项对应。

## 9. 防偏航规则

- 不要把 SDL_sound 写成底层音频后端。
- 不要把光锥 sounds 简化成声源排序系统。
- 不要让音频线程等待 GPU 或 I/O。
- 不要绕开 AcousticResponse 直接把传播 solver 绑进 mixer 热路径。
- 不要在未完成 CPU correctness 前先做 GPU 加速。
- 不要把设计师可调参数硬编码在 Zig 逻辑里。
- 不要用 C/C++ 实现 Bugu 引擎主体；如果必须绑定 C 库，隔离在 Zig adapter 中。
- 不要直接使用 upstream SDL；如果选择 SDL，必须使用 in-dreaming/SDL.git enjin/gpu/main。
- 不要引入非 submodule 的第三方源码或隐式依赖。
- 不要为可视化 demo 临时使用其他 RHI/窗口渲染层；必须接 in-dreaming/gpu。
- 不要用渲染 mesh 直接替代 acoustic scene；声学需要材质、厚度、洞口、动态层和 probe。
- 不要用 mock/stub/fake result 把任务标记为 DONE；不完整实现必须留在 TODO、IN_PROGRESS、BLOCKED 或 REVIEW。
- 不要把 fallback 当主路径写进架构；fallback 必须标注触发条件和后续补齐任务。

## 10. 当前仓库事实

截至 2026-07-07：

- README.md 很短，仅声明 Bugu 是 sound engine。
- docs/research/1.md 是初步大调研，部分内容需要以后逐步校正。
- docs/design/audio-engine-design.md 是当前主设计文档，已经包含修正后的复合声学传播方向。
- docs/tasks 由本任务创建，用于后续 agent pick-up。
- 额外补充硬约束：Bugu 用 Zig 实现；三方依赖用 git submodule；SDL 依赖固定为 in-dreaming/SDL.git enjin/gpu/main；可视化固定使用 in-dreaming/gpu RHI。

## 11. 如果上下文不足怎么办

优先读取 docs/design/audio-engine-design.md 对应章节。仍不足时：

1. 在任务文件 Activity Log 记录缺口。
2. 做最小范围调研。
3. 如果影响架构决策，先产出 ADR 草案，不要直接实现。
4. 如果只是实现细节，可做明确假设并在任务文件 Evidence 中写清楚。

## 12. 本轮任务审查结论

2026-07-07 审查后新增要求：

- 所有任务必须区分真实实现、fallback 和 mock；mock 不得通过验收。
- 实现任务必须提供 Evidence，不再只写“完成”。
- T004、T005、T006、T007、T008、T010、T011、T013 是最容易出现假实现的任务，验收时必须逐条核对真实数据路径。
- T012 应作为持续 gate，而不是最后才做的文档任务；从 T004 起每个实现任务都应留下可被 T012 收集的验证证据。
- T015 public fact, 2026-07-08: event runtime supports `postAcousticEvent`, returning an event-owned `AcousticEventInstance`; later acoustic snapshot updates must go through `AcousticEventInstance.update` or an equivalent control-thread API that calls public `Engine.updateVoice`, not direct mixer voice hot-data mutation.
