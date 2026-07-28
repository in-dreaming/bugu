# Bugu Sequence Music Engine 架构

状态：Architecture v1.0（范围冻结；实现未开始）
日期：2026-07-24
范围：Bugu 自适应音乐子系统（下文简称 SME）
输入：`docs/research/kcd.md`、`docs/research/kcd.sme.md`
上位约束：`docs/tasks/asetup.md`、`docs/design/audio-engine-design.md`、`docs/design/audio-runtime-contract.md`

## 0. 结论与决策

Bugu 不集成、移植或仿制 KCD 使用的闭源 Sequence Music Engine 产品。Bugu 在现有 Zig mixer、event runtime、asset bank 和 offline validation 之上，自研一个数据驱动的自适应音乐控制层，吸收以下设计原则：

- 水平重排序：按音乐结构在 segment 之间切换；
- 垂直分层：同一主题的多个 stem 共享时间轴并独立自动化；
- 音乐时间同步：切换发生在明确的 beat、bar、segment end 或 authored cue；
- 作曲期元数据：tempo、拍号、loop、cue、layer 和 transition 均由资产声明；
- 游戏状态驱动：离散的 music state 与连续的 intensity 分工，不把游戏规则硬编码进 mixer；
- 可验证性：同一输入序列产生确定的调度决策、transition trace 和 offline render。

SME 是 L9/L8 的音乐导演与资源子系统，不替换下层组件：

- 不替换 Bugu mixer；
- 不替换 miniaudio/device backend；
- 不让 event runtime 负责音乐结构规划；
- 不把声学传播 solver 接入音乐调度热路径；
- 不在 audio render thread 解析状态图、查询资产、分配内存或等待 I/O。

首个可交付版本称为 **SME v1**。v1 是完整产品能力集合，不是 MVP 或能力切片。它必须同时包含：复杂 tempo map 与拍号变化、beat/bar/cue/segment 同步、authored entry/exit cue、fill segment、多 stem 重排序与重配器、状态/参数/逻辑表达式、stinger、真实 sidechain ducking、版本化 bank、立体声/多声道与生产 codec、流式加载、热更新、作者工具、实时与离线验证、trace/profile 和可视调试。任何一项缺失时，整体状态只能是 `IN_PROGRESS` 或 `BLOCKED`，不能发布为 SME v1。

实现可以按依赖分批落地，但不存在“v1 核心版”和“以后补全版”两套验收口径。本文出现的所有 SME 能力均属于同一个 v1 release gate；分阶段只用于安排工程顺序，不缩小最终范围。

`docs/research/kcd.sme.md` 曾推荐先交付固定 tempo 的简化方案。该建议是研究阶段的风险评估，不再是 v1 范围依据；本文以当前“v1 必须完整”的产品决策覆盖该建议，但保留其“复用 Bugu 底座、不接入闭源产品、验证优先”的架构结论。

## 1. 文档权威性与现状边界

两份研究文档负责解释来源、行业参考和方案评估；本文负责规定 Bugu 的实现边界。研究描述与本文冲突时，以本文和上位实时 contract 为准。

截至本文日期，仓库已有能力与 SME 目标之间的边界如下。

| 能力 | 当前仓库事实 | SME 所需增量 |
|---|---|---|
| 固定 quantum | `EngineConfig.quantum_frames` 默认 256，内部 48 kHz float32 | 建立单调递增的绝对 render frame 时钟，并支持 quantum 内 sample offset |
| Voice | 64 个 real voices、稳定 handle、loop、gain ramp、pitch、release | 同步 voice group、原子启动、组内统一 seek/stop、音乐 voice 预算策略 |
| Event | random、switch、单 RTPC、即时 play/stop | 独立 Music Director、状态图、逻辑表达式、请求仲裁和 sample-accurate 边界调度 |
| Bus/effect | `sfx`/`music`/`master` 标签、固定 reverb send/return | 音乐组自动化、dialogue detector、真实 sidechain compressor 和可审计 ducking |
| Bank | 未版本化 TOML manifest + 预加载单声道 float32 blob | 版本化 music metadata、channel layout、tempo/cue/fill、codec/seek/chunk 和 streaming |
| Backend | miniaudio device + offline render | 不变；SME 只消费 engine clock 和 mixer command contract |
| Validation | unit tests、offline WAV、文本报告、CPU/GPU 显式 gate | transition/layer trace、golden schedule、长时同步与 underrun gate |
| 声学 | CPU reference、GPU spike、`AcousticResponse` 到 mixer 映射 | 可选低频控制输入；不得直接驱动 music state 或阻塞调度 |

以下能力当前**尚未存在**，因此任何仅调用现有 `startSampleVoiceWithHandle` 的实现都不能宣称 SME 已完成：

- 多 stem 的同一绝对 sample frame 原子启动；
- beat/bar 音乐时钟；
- 延后到未来音乐边界执行的 sample-accurate transition 调度；
- stream cache、seek table 和音乐流式播放；
- 版本化 music bank schema；
- dialogue sidechain compressor；
- Music Director 的公开 API、生命周期和 telemetry。

## 2. 目标、非目标与质量属性

### 2.1 目标

SME 的目标是让游戏用少量稳定接口表达“音乐想去哪里”，由引擎决定“何时以及如何安全抵达”：

1. 游戏提交离散 `MusicStateId`、连续参数和瞬时 stinger 请求；
2. Music Director 根据状态图与优先级选择目标主题；
3. Transition Planner 在音乐时间轴上找到合法边界；
4. Layer Controller 对同步 stems 做原子启动、淡入淡出和强度映射；
5. mixer 在已计划的绝对 render frame 执行有界命令；
6. offline backend 可以逐帧复现相同决策和 PCM。

设计必须满足：

- Zig-first，核心实现不得下沉到 C/C++；
- 数据驱动，设计师可调规则不硬编码在 Zig 分支中；
- 音频线程无分配、无锁、无 I/O、无日志、无 GPU wait；
- 决策确定性可配置且可测试；
- 旧 bank 与普通 event playback 继续可用；
- 缺少 SME 元数据时明确报错或走显式 legacy 路径，不静默猜测；
- 任何 fallback 都是有能力边界的真实降级实现。

### 2.2 非目标

SME v1 的非目标只限于不属于自适应音乐产品本身的能力：

- 取代 Cubase、Sibelius 等 DAW/谱面软件完成录音、编曲、混音或音频波形编辑；
- 自动作曲、生成式音乐或 MIDI/VST 实时演奏；
- 运行时凭音频内容“猜测”调性与和声；兼容性必须由作者标注并由编译器校验；
- sample-level GPU mixer；
- 将空间声学结果当作唯一的音乐状态来源；
- 网络同步音乐或多人确定性时钟。

SME v1 **包含**专用 authoring application，但它负责状态图、tempo map、cue、fill、layer、transition、逻辑条件、预览、校验和 bank 构建，不复制 DAW 的素材制作能力。Streaming、virtual voice、Bus DAG、sidechain、图形化调试和完整资产管线不是非目标，也不得作为外部前置条件留给未知后续版本。

### 2.3 质量属性优先级

从高到低：

1. 无 dropout、爆音和线程阻塞；
2. stem 相位与音乐边界正确；
3. 可复现、可观测、可诊断；
4. 状态响应及时且不抖动；
5. 资产制作与迭代成本可控；
6. 复杂音乐表达能力。

当资源不足时，SME 应降低音乐复杂度，而不是破坏实时安全或同步正确性。

## 3. 总体架构与模块边界

```text
Game / Script
  │  setState / setParameter / triggerStinger
  ▼
MusicFacade (public Zig API)
  │  bounded commands
  ▼
Music Director ─────────────── Music Runtime Data
  │ resolve target              ├─ StateGraph
  │                             ├─ Theme/Segment/Layer tables
  ▼                             ├─ Transition rules
Transition Planner ◄────────────└─ Tempo/Cue metadata
  │ absolute-frame plan
  ├──────────────► Prefetch Coordinator ─► Worker / I/O
  ▼
Layer Controller
  │ scheduled group commands
  ▼
Audio Control → immutable ScheduledCommandBlock
  ▼
Mixer / Voice Pool / Music Bus
  ▼
Device Backend or Offline Render

Trace sinks consume control-thread decisions; they never run in render callback.
Acoustic Runtime may publish a bounded control parameter; it does not own the graph.
```

### 3.1 `music/api.zig`：公共门面

职责：

- 创建和销毁 `MusicRuntime`；
- 挂载/卸载已编译的 `MusicBank`;
- 接收 state、parameter、stinger、pause、resume、stop 请求；
- 暴露只读状态与 telemetry；
- 校验 handle、生命周期和调用线程。

它不暴露 mixer voice handle。游戏持有 `MusicRuntimeHandle`、`MusicInstanceHandle` 或稳定的 ID，具体 stem voice 由 Layer Controller 所有。

### 3.2 `music/director.zig`：状态解析与仲裁

职责：

- 保存当前状态、目标状态、参数快照和请求代数；
- 根据数据化规则选择 theme/segment；
- 处理优先级、最短驻留时间、冷却时间和迟滞；
- 合并过期请求，生成单个确定的 transition intent；
- 管理 dialogue duck、pause/resume 和 stop 的高层语义。

Director 只在 Audio Control Thread 更新。它不操作 PCM、不读取文件、不直接遍历 mixer voices。

### 3.3 `music/clock.zig`：音乐时间

职责：

- 将 engine 绝对 render frame 映射为 beat/bar/segment-local frame；
- 在固定 BPM/拍号下计算下一个合法边界；
- 为 planner 提供纯函数式时间查询；
- 对 pause、device discontinuity、offline render 定义一致语义。

音频硬件/render frame 是唯一权威时钟。游戏帧时间、墙钟和 `delta_ms` 不得用于决定实际切换 sample。

### 3.4 `music/planner.zig`：转换计划

职责：

- 查找 `from -> to` 规则；
- 解析同步策略和 fade 时长；
- 选择目标 segment 入口；
- 计算绝对执行 frame、source exit frame 和 target start frame；
- 检查目标数据是否已 resident；
- 产生不可变 `TransitionPlan`。

Planner 不允许在目标资产未准备好时生成一个必然 underrun 的计划。

### 3.5 `music/layers.zig`：同步层控制

职责：

- 创建与销毁 `MusicVoiceGroup`；
- 保证 stems 共享 segment cursor、loop epoch 和 scheduled start frame；
- 把 intensity 曲线编译为每层 gain target；
- 执行 group crossfade、ducking gain 和 release；
- 在 voice 预算不足时执行声明式降级策略；
- 汇总 layer telemetry。

### 3.6 `music/assets.zig` 与资产编译器

职责：

- 解析 source manifest；
- 校验 tempo、拍号、长度、loop、cue 与所有 stem 对齐；
- 生成稳定 ID、版本化 metadata 和运行时友好的 flat tables；
- 检测不可达 state、缺失 transition、无进展 fallback 环和无效 fallback；
- 生成 waveform/trace 所需的非运行时调试信息；
- 生成 stream chunk、sample-accurate seek table、codec priming 补偿和 prefetch 信息。

运行时不解析面向作者的字符串表达式。条件表达式在编译期转为有界 bytecode、小 LUT 或 flat rule table。

### 3.7 `tools/sme_authoring`：作者工具

SME v1 必须交付可实际制作、检查和预览完整音乐 bank 的作者工具，而不只是一份手写 manifest。工具主体使用 Zig；图形界面与波形/时间线/状态图可视化使用 `in-dreaming/gpu`。

职责：

- 导入 DAW/Sibelius 工作流导出的 stems 与标记文件；
- 编辑多段 tempo map、拍号变化、entry/exit cue 和 fill segment；
- 编辑 state graph、逻辑表达式、优先级、迟滞、transition 与 fallback；
- 编辑 layer/intensity 曲线、bus、sidechain、stinger 和 acoustic mapping；
- sample-accurate 对齐检查、loop/click 检查、loudness/peak 扫描和 codec preview；
- 用与 runtime 相同的 Music Director/Planner 做实时或 offline preview；
- 显示不可达状态、歧义规则、无进展环、缺失 cue、无法满足的兼容性和预算超限；
- 调用确定性的 bank compiler，输出 build report、依赖图与内容 hash；
- 连接运行时执行 live tuning/hot reload，并保留 generation/rollback；
- 导入、导出可代码审查的文本源格式，不把二进制工程文件作为唯一真相。

工具不得拥有另一套 transition 语义。预览、编译和 runtime 必须共享同一 schema、rule evaluator、tempo/cue 算法与 validation library。

### 3.8 与现有模块的关系

| 现有模块 | SME 依赖方式 | 禁止耦合 |
|---|---|---|
| `core/engine.zig` | 提供绝对 render frame、scheduled command 提交和 telemetry 聚合 | Director 直接访问 `Engine.mixer` |
| `mixer/mixer.zig` | 执行 sample-offset command、voice group render、music bus automation | mixer 解析 state graph 或资产字符串 |
| `assets/bank.zig` | 共享 bank 生命周期、sample/blob 所有权和 ID 规则 | 将 music schema 塞入未版本化 `[[sounds]]` 并默默忽略字段 |
| `events/runtime.zig` | 可由普通 event 触发 music API；stinger 可复用声音解析 | 用 `postEvent` 的即时 voice 启动冒充 beat 同步 |
| `acoustic/acoustic.zig` | 可发布经平滑/量化的可选 music parameter | solver 直接切 theme 或更改 music voice |
| `device/device.zig` | 继续驱动 fixed-quantum render | SME 依赖具体 backend 或设备墙钟 |

## 4. 核心语义

### 4.1 State、Theme、Segment、Layer

- **Music State**：游戏语义，如 `explore`、`tension`、`combat`、`dialogue`。同一时刻只有一个主状态生效。
- **Theme**：可被多个 state 选择的音乐作品/配器集合。
- **Segment**：Theme 中可独立循环或跳转的时间片段。
- **Layer/Stem**：共享 segment 时间轴的音频层。
- **Intensity**：`0.0...1.0` 的连续控制量，只改变当前主题内部的层和参数，默认不触发主状态切换。
- **Stinger**：一次性音乐强调事件。它不改变主状态，必须声明是否与 beat/bar 同步以及是否占用保护 voice。

State 与 intensity 必须正交。例如 `combat` 是离散状态，敌人数量映射为 combat intensity；不能为每一个强度等级复制一套硬编码 state。

### 4.2 请求模型与仲裁

游戏提交的是意图，不是立即播放命令：

```zig
pub const MusicRequest = union(enum) {
    set_state: struct {
        state: MusicStateId,
        priority: u8,
        request_id: u64,
    },
    set_parameter: struct {
        parameter: MusicParameterId,
        value: f32,
    },
    set_context: struct {
        key: MusicContextId,
        value: MusicContextValue,
    },
    trigger_stinger: StingerId,
    begin_duck: DuckRequest,
    end_duck: DuckRequestId,
    seek_preview: struct {
        segment: SegmentId,
        cue: ?CueId,
        frame: ?u64,
    },
    pause,
    resume,
    stop: MusicStopMode,
};
```

`seek_preview` 只允许 authoring/offline/debug context；shipping game context 返回 `UnsupportedOperation`，避免游戏逻辑绕开状态图。公共 `MusicRuntime` 至少提供 `loadBank`、`unloadBank`、`start`、`submit`、`pollReceipt`、`snapshot`、`captureState`、`restoreState`、`hotReload`、`rollbackGeneration` 和 `shutdown`。持久状态包含 committed/pending state、selector history、seed/epochs、transport/cue 和 bank build ID；restore 只能在匹配或具备显式 migration map 的 bank 上执行。所有调用都定义线程、所有权、队列满和 stale handle 语义。

Director 在每个 control tick 消费请求并应用以下确定性规则：

1. `stop`、设备生命周期事件和显式 pause 具有系统优先级；
2. 高优先级 state 覆盖低优先级 state；
3. 相同优先级采用最后请求，但保留单调 `request_id`；
4. 已被更新请求替代、尚未执行的 transition plan 必须取消或重算；
5. `minimum_hold_bars` 和 `cooldown_bars` 防止边界附近抖动；
6. 参数变化先 clamp，再按声明的 attack/release 平滑；
7. 随机变体若启用，必须使用显式 seed，并把选择写入 trace。

不存在匹配规则时返回结构化错误或使用资产显式声明的 fallback rule。不得隐式选择第一个 theme。

### 4.3 状态图

SME v1 使用有向图：

```zig
pub const MusicTransitionRule = struct {
    from: MusicStateId,
    to: MusicStateId,
    condition_program: LogicProgramId,
    sync: TransitionSync,
    fade_beats: FixedBeat,
    minimum_hold_bars: u16 = 0,
    priority: u8 = 0,
    target: SegmentSelectorId,
    source_exit_selector: CueSelector,
    fill: ?FillRouteId = null,
    target_entry_selector: CueSelector,
    compatibility: CompatibilityConstraint,
    fallback: TransitionFallback = .reject,
};
```

编译器必须检查：

- ID 唯一且所有引用可解析；
- 初始 state 存在；
- 必需状态从初始 state 可达；
- 同一 `from/to/priority` 不存在歧义规则；
- fade 不超过资产允许范围；
- fallback 指向真实可播放 segment；
- transition 的 exit/fill/entry 路径在 tempo、拍号、兼容标签和资产驻留约束下至少存在一个合法解；
- 逻辑表达式只读取已声明的 state/parameter/context，不含无界循环、动态调用或副作用。

### 4.4 逻辑表达式

完整 SME 需要根据区域、任务、战斗阶段、时间、随机去重历史和连续参数选择音乐。作者表达式在构建期编译为有界栈式 bytecode：

```zig
pub const LogicOp = enum {
    push_bool,
    push_number,
    load_state,
    load_parameter,
    load_context,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_op,
    or_op,
    not_op,
    in_range,
};
```

每个 program 有固定最大指令数和栈深。运行时无字符串查找、分配、递归和脚本回调。若多个规则同时成立，按 `priority -> specificity -> authored_order` 确定唯一结果，并把候选与淘汰原因写入 trace。

### 4.5 Segment 选择与去重复

Theme/state 不必永久绑定一个 segment。`SegmentSelector` 支持：

- fixed；
- authored sequence；
- weighted random；
- shuffle bag；
- no-repeat window；
- condition-filtered pool；
- history-aware continuation。

Selector 的所有候选、权重、历史窗口和 exhaustion 行为由 bank 声明。随机策略使用 runtime seed + selector stable ID + selection epoch 派生确定性序列；选择历史属于 `MusicRuntime` snapshot，参与 save/restore、offline replay 和 hot reload migration。候选池为空时执行显式 fallback 或返回错误，不回退到第一个 segment。

## 5. Sample-accurate Tempo Map 与音乐时钟

### 5.1 权威时间域

所有时刻使用从 engine start 起单调递增的 `u64 render_frame` 表示。固定 tempo 区间内：

```text
frames_per_beat = sample_rate * 60 / bpm
frames_per_bar  = frames_per_beat * numerator
```

SME v1 必须支持：

- 任意数量的 tempo region；
- region 内固定 BPM、线性渐快/渐慢和 authored beat anchors；
- 合法 bar 边界上的拍号变化；
- pickup/anacrusis、非整小节 segment 起点；
- cue 的 sample-frame 与 musical-position 双重锚定；
- loop 回绕后完全相同的 beat grid。

作者侧 tempo 数据使用定点数：

```zig
pub const TempoRegion = struct {
    start_tick: u64,
    end_tick: u64,
    start_milli_bpm: u32,
    end_milli_bpm: u32,
    curve: TempoCurve, // constant / linear
};

pub const MeterChange = struct {
    at_tick: u64,
    numerator: u8,
    denominator: u8,
};
```

Bank compiler 不让 render thread 对 tempo ramp 做数值积分。它以固定 PPQ 和确定性定点算法预编译：

- `BeatGrid[]`：每个 beat/subdivision 对应的 segment sample frame；
- `BarGrid[]`：bar index、meter 和 sample frame；
- `TempoSpan[]`：用于 frame、tick、beat、bar 双向查询的有界区间；
- `CueTable[]`：最终 sample frame、musical tick 与兼容标签。

作者提供的 sample anchor 是最终权威；编译器必须检查相邻 anchor 的单调性、tempo 曲线误差和 loop 闭合，并将累计误差限制在配置阈值内。任何无法闭合或会产生重复/倒退 frame 的 tempo map 构建失败。运行时只做整数查表、二分或预建索引，不能每个 quantum 用 `f32` 累加 beat phase。

### 5.2 Segment 时间域

每个运行中的 group 保存：

- `start_render_frame`；
- `segment_frame`；
- `loop_epoch`；
- `tempo_map_id` 与当前 span/grid index；
- `loop_start_frame`、`loop_end_frame`；
- `paused_frame`（若暂停）；
- 当前 beat/bar 索引。

所有 stems 必须从相同的 `segment_frame` 读取。单层 muted 只影响 gain，不停止其逻辑 cursor；重新淡入时不得从头开始。

### 5.3 同步策略

```zig
pub const TransitionSync = enum {
    immediate,
    next_beat,
    next_bar,
    next_matching_cue,
    segment_end,
    authored_exit_cue,
};
```

语义：

- `immediate`：不是“当前游戏调用栈立即执行”，而是最早可安全提交的 render frame；紧急 stop 仍应用短 ramp；
- `next_beat`：当前 frame 之后的严格下一个 beat；
- `next_bar`：当前 frame 之后的严格下一个 bar；
- `next_matching_cue`：满足 transition selector 与 compatibility constraint 的下一个 cue；
- `segment_end`：当前 loop epoch 的结束边界，不回绕后再等待；
- `authored_exit_cue`：从合法 exit cue 集合按 selector、最早可达时间、兼容度和 authored tie-break 选择。

如果请求恰好发生在边界上，是否使用当前边界必须统一。SME v1 选择“严格下一个边界”，避免 control-thread 到 render-thread 传播延迟造成偶发一拍差异。紧急系统命令例外。

### 5.4 Quantum 内执行

仅在 quantum 边界启动 voices 无法满足一般 BPM 的 sample 对齐。mixer 必须支持命令携带：

```zig
pub const ScheduledMusicCommand = struct {
    execute_frame: u64,
    sequence: u64,
    payload: MusicRenderCommand,
};
```

render callback 对当前 `[quantum_start, quantum_end)` 内的命令按 `(execute_frame, sequence)` 排序后的预编译顺序执行，并把 quantum 分成有界子区间。命令块由 control thread 预构建，render thread 不排序、不分配。

同一 transition 的 stop/start/layer automation 使用相同 `execute_frame` 和一个原子 command group。若整组命令无法进入固定容量 block，整组拒绝并增加 telemetry；不得只启动一部分 stem。

## 6. Transition Planner

### 6.1 计划结构

```zig
pub const TransitionPlan = struct {
    plan_id: u64,
    request_id: u64,
    from_state: MusicStateId,
    to_state: MusicStateId,
    source_group: ?MusicVoiceGroupId,
    target_segment: SegmentId,
    source_exit_cue: ?CueId,
    fill_route: ?FillRouteId,
    target_entry_cue: CueId,
    execute_frame: u64,
    target_start_frame: u64,
    fill_start_frame: ?u64,
    fill_end_frame: ?u64,
    phases: BoundedTransitionPhases, // source tail / overlaps / N fills / target
    fade_frames: u32,
    sync: TransitionSync,
    source_tempo_span: TempoSpanId,
    target_tempo_span: TempoSpanId,
    asset_generation: u32,
    required_chunks: BoundedChunkSet,
};
```

`asset_generation` 防止 hot reload 后旧计划引用新布局。执行前 generation 不匹配时，control thread 取消并重算。

### 6.2 规划步骤

1. Director 产生 transition intent；
2. 查找唯一 transition rule；
3. Logic evaluator 过滤条件并确定 transition；
4. Segment Selector 基于条件、seed 和选择历史解析唯一 target segment；
5. Clock 从 source tempo map 枚举合法 beat/bar/exit cue；
6. Cue matcher 联合求解 source exit、optional fill route、target entry；
7. 校验 compatibility tag、tempo/meter handoff、tail/overlap 和 crossfade window；
8. Prefetch Coordinator 判断 source tail、fill 和 target 所有必需 chunks 是否可用；
9. 若赶不上边界，根据规则选择下一个合法边界或显式 fallback；
10. Layer Controller 预留 source/fill/target voice slots 与 command capacity；
11. 生成不可变 plan 并发布；
12. render thread 按计划阶段在绝对 frame 原子执行；
13. control thread 收到最终 target entry 执行回执后提交当前状态。

“当前 state”只有在 render 执行回执后才改变；已规划但未执行的状态称为 `pending_state`。

### 6.3 Crossfade

Crossfade 是两个 group 在同一时间域的 gain automation，不是两个不对齐 loop 的任意淡化：

- source 从当前 segment cursor 继续播放并淡出；
- target 在计划入口按绝对 frame 启动并淡入；
- v1 默认使用 equal-power 或资产声明的线性曲线；
- fade 时长以 beat 表达，编译/规划时转 frames；
- source 仅在 ramp 完成后释放；
- target stem 相位必须先对齐，再应用各层 gain。

来源与目标 BPM 或拍号不同时，Planner 必须按作者数据使用 fill、tail overlap、tempo handoff cue 或显式 hard cut 路径。不能临时 pitch-shift 整个作品或用任意 crossfade 掩盖不兼容。

### 6.4 Entry/Exit Cue、Fill 与兼容性求解

SME v1 的完整转换路径是：

```text
source exit cue → source tail/overlap → optional fill route → target entry cue
```

```zig
pub const MusicCue = struct {
    id: CueId,
    kind: CueKind, // entry / exit / both / stinger / fill_entry / fill_exit
    sample_frame: u64,
    musical_tick: u64,
    beat_role: BeatRole,
    harmony_tag: HarmonyTagId,
    phrase_tag: PhraseTagId,
    energy_tag: EnergyTagId,
    tail_frames: u32,
    min_lead_frames: u32,
};

pub const FillRoute = struct {
    id: FillRouteId,
    segments: []const SegmentId,
    entry_selector: CueSelector,
    exit_selector: CueSelector,
    compatibility: CompatibilityConstraint,
};
```

Planner 联合选择 `(source_exit, fill_route, target_entry)`，按以下稳定顺序评分：

1. 满足 transition condition 和 hard compatibility constraint；
2. 满足请求的 sync/beat role；
3. 资产已 resident 或能在 lead time 内完成 prefetch；
4. authored preference；
5. 从当前 frame 到可听切换的最短延迟；
6. cue ID 作为最终稳定 tie-break。

和声兼容不是运行时音频分析。作者工具要求 cue 标注调性/和声功能或自定义 compatibility tag，compiler 预计算合法邻接表，Planner 只查询有界表。Fill route 可以包含多个 segment，但必须有固定最大长度、无无进展环，并在 bank 构建时证明最终能进入 target。

Fill 支持自身 tempo map、layers、stinger 和 tail。每一阶段都使用绝对 frame scheduler；source、fill、target 的交接以及重叠窗口均写入同一个 `TransitionPlan`，不得拆成互不关联的即时事件。

## 7. 垂直分层与 Voice Group

### 7.1 原子组

```zig
pub const MusicVoiceGroup = struct {
    id: MusicVoiceGroupId,
    segment: SegmentId,
    start_render_frame: u64,
    segment_cursor: u64,
    loop_epoch: u64,
    layer_handles: BoundedLayerHandles,
    state: GroupState,
};
```

一组 layer 的硬性条件：

- 相同 sample rate；
- 相同 frame count 或显式一致的 loop range；
- 相同 tempo、拍号与首拍；
- 相同 channel layout contract；
- 无编码器延迟差，或已在导入期补偿；
- loop 前后保持 sample 对齐；
- group start/seek/stop 是原子命令。

资产编译器必须用 frame 级校验拒绝不对齐 stems。运行时不做“差不多对齐”的修复。

### 7.2 Intensity 映射

每层用已编译曲线把 intensity 和其他声明参数映射为重配器目标：

```zig
pub const LayerIntensityCurve = struct {
    points: []const CurvePoint, // 编译后为固定上限 flat slice/LUT
    attack_beats: FixedBeat,
    release_beats: FixedBeat,
};
```

完整 layer target 包含 gain、active/virtual 策略、pan/channel trim、filter、effect send、bus route、articulation/variant selector 和保护优先级。所有可连续参数使用 sample/block ramp；离散 variant 只能在该 layer 声明的合法 cue 切换。重配器可以由 intensity、state、context 和 logic program 共同驱动，但编译器必须证明同一参数不存在未定义的多写冲突。

典型配置：

- base layer 始终可闻；
- pulse/ostinato 在中强度淡入；
- percussion 在高阈值进入；
- climax/choir 仅在上段强度进入。

阈值必须有迟滞或连续 ramp，避免参数在边界抖动时反复启停。所有 layer cursor 始终推进；低于 audibility threshold 的 layer 进入真实 virtual voice 状态，不执行 sample DSP，但继续推进 tempo-aware cursor、stream/seek 意图、loop epoch 和 automation。重新实体化时必须从 group 当前 sample frame 恢复，stem skew 为 0。Virtual voice 是 SME v1 的必需依赖，不能用“零 gain real voice”长期替代。

### 7.3 Voice 预算与降级

Music voice 与 SFX 共用 voice manager 时，必须有显式、可配置且可 profile 的平台预算。v1 不把作品能力硬编码为四层；bank compiler 根据目标平台 profile 校验：

- 每个 theme 的最大主 layers、辅助 layers 和 virtual layers；
- transition/fill 期间允许并存的最大 groups；
- stinger 使用独立上限；
- 音乐关键 base layer 受保护；
- 可选 layers 按资产声明的 `drop_rank` 降级。

降级必须按整个 layer 的既定优先级执行。禁止：

- 随机丢 stem；
- 让一组 stems 在不同 frame 启动；
- voice 不足时静默成功；
- 偷掉 base layer 后仍报告 transition 完成。

若最小可播放集合无法预留，Planner 将计划推迟到下一边界，或执行资产显式声明的单一 fallback mix。fallback mix 必须是真实资产并经过同样的同步校验。

## 8. Music Bank 与资产契约

### 8.1 与现有 Bank 的关系

SME 必须建立单一、版本化、可校验的 compiled bank contract。面向作者的文本源和中间缓存可以拆文件，但运行时加载的 music metadata、seek/chunk 表与音频 blob 必须由同一次确定性构建产生，共享 build ID/content hash。不得用松散伴随 metadata 作为 v1 runtime contract。

v1 compiled bank 逻辑结构：

```text
BankHeader(version, build_id, sample_rate)
StringTable
SoundTable
MusicStateTable
MusicParameterTable
MusicContextTable
ThemeTable
SegmentTable
SegmentSelectorTable
LayerTable
TransitionTable
TempoTable
CueTable
FillRouteTable
StingerTable
LogicProgramTable
CurveTable
BusGraphTable
SidechainPresetTable
AcousticMusicProfileTable
PlatformProfileTable
CodecTable
StreamChunkTable
SeekTable
BlobData
```

Header 必须包含 capability bits。loader 遇到未知必需能力、较新 major version 或越界引用时失败，不忽略。

### 8.2 作者源数据

源 manifest 的概念结构：

```toml
schema = "bugu.music.source/v1"
sample_rate = 48000

[[states]]
id = "explore"
theme = "overworld"

[[themes]]
id = "overworld"
initial_segment = "explore_loop"

[[segments]]
id = "explore_loop"
loop_frames = [0, 384000]
tempo_map = "explore_tempo"

[[tempo_maps]]
id = "explore_tempo"
ppq = 960

[[tempo_maps.regions]]
start_tick = 0
end_tick = 15360
start_bpm = 120.0
end_bpm = 132.0
curve = "linear"

[[tempo_maps.meters]]
at_tick = 0
value = [4, 4]

[[segments.cues]]
id = "explore_exit_dominant"
kind = "exit"
tick = 14400
harmony = "dominant"
phrase = "open"

[[segments.layers]]
id = "strings"
source = "music/explore_strings.wav"
base_gain_db = 0.0
drop_rank = 0

[[segments.layers]]
id = "percussion"
source = "music/explore_percussion.wav"
base_gain_db = -3.0
drop_rank = 2

[[transitions]]
from = "explore"
to = "combat"
sync = "next_bar"
fade_beats = 2.0
target = { fixed_segment = "combat_loop" }
source_exit = { harmony = "dominant" }
fill = "explore_to_combat_fill"
target_entry = { harmony = "tonic" }
condition = "threat >= 0.65 && dialogue == false"

[[fill_routes]]
id = "explore_to_combat_fill"
segments = ["combat_pickup"]
```

该示例只说明结构，不冻结文本格式。真正的 ABI 是编译后的 bank schema。

### 8.3 导入与校验

资产编译必须检查：

- 输入编码和 channel layout 在支持矩阵内；
- 所有素材转换到 bank sample rate；
- stem 开头、长度、loop range 精确一致；
- loop 点是合法 sample frame，且边界无明显 DC discontinuity；
- BPM/拍号能把声明的 bar/beat 映射到合法 frame；
- transition 的 source/target/fill tempo map、cue 与 compatibility contract 存在合法路径；
- peak、true peak、RMS 和 integrated loudness 数据存在；
- ID hash 冲突被检测；
- state graph 和 fallback 完整；
- 估算 preload/stream memory 与 voice 上限；
- tempo map、cue、fill、logic program、codec、seek 与 chunk 表交叉引用完整；
- build report 证明所有必需的 v1 capability bits 已生成。

过零点可以用于减少 click，但它不是音乐同步正确性的替代。loop 首尾连续性还需要相位、尾音和混响设计；必要时由作者提供独立 loop/crossfade 区。

### 8.4 Channel 与编码

当前 `SoundEntry.samples` 是单声道 float32，不能满足成品管弦乐 stem 的一般需求。SME v1 统一 `ChannelLayout` contract，至少支持：

- mono、interleaved stereo、5.1 与 7.1；
- 声道 mask、顺序和 downmix/upmix matrix；
- mixer 对 stereo music voice 的 render 路径；
- 编码器 delay/padding 的导入期补偿；
- PCM 与至少一种适合长音乐的生产 streaming codec；
- decoder/codec 作为 git submodule，通过 Zig adapter 隔离；
- 每个 codec 的 sample-accurate seek、loop、priming 和跨平台一致性测试。

预加载 PCM 可用于单元测试和短 stinger，但不能作为长音乐运行时的发布替代路径。

### 8.5 Streaming 与预取

SME v1 的长音乐 stems 必须流式加载。运行时结构：

- 每个 layer 有独立 decode cursor，共享 group logical cursor；
- chunk 边界和 seek point 在导入期生成；
- Worker Thread 执行文件 I/O/解码；
- Prefetch Coordinator 维护高低水位；
- render thread 只消费预分配 PCM ring；
- group 只有在最小可播放 layer 集均 ready 后才能启动；
- 任一必需 layer underrun 时记录 group underrun，不让其余 layer 悄悄继续造成配器缺失。

SME v1 必须同时验证持续流播、seek、loop、transition 并发预取、低水位恢复和设备抖动场景。预加载模式只适用于标记为 resident 的短资产；任何 music segment 超过 resident size gate 时，bank compiler 必须强制生成 streaming descriptor。

## 9. 线程、所有权与生命周期

### 9.1 线程职责

| 线程 | SME 职责 |
|---|---|
| Game Thread | 提交有界意图；读取上一周期状态/telemetry |
| Audio Control Thread | Director、Clock 查询、Planner、prefetch 决策、layer 自动化编译、trace |
| Worker/I/O Thread | bank load、decode、stream chunk、校验和非实时分析 |
| Audio Render Thread | 消费 immutable command block、推进 group cursor、mix、写原子计数 |
| GPU/Acoustic Thread | 可选产生声学参数；永不成为音乐时钟或 render 依赖 |

### 9.2 跨线程通道

```text
Game -> Control: bounded MPSC MusicRequestQueue
Worker -> Control: bounded completion queue
Control -> Render: double/triple-buffered immutable ScheduledCommandBlock
Render -> Control: bounded execution receipt + atomic telemetry
```

队列满时返回 `QueueFull` 并计数。不得覆盖未消费的关键状态请求。连续 parameter update 可按 parameter ID 合并，只保留最新值。

### 9.3 所有权

- `MusicBank` 拥有 metadata、曲线、字符串和 blob/stream descriptors；
- `MusicRuntime` 持有 bank generation 引用、Director、Planner、Clock 和 groups；
- `MusicVoiceGroup` 持有逻辑 layer handles，不拥有 sample memory；
- voice 对 bank generation 保持强引用或等价 lease；
- hot reload 发布新 generation，旧 generation 直到所有 plan/group/voice 释放后销毁；
- render command 只能引用在整个执行窗口内稳定的索引或 generation handle。

### 9.4 生命周期

```text
Uninitialized
  -> LoadingBank
  -> Ready
  -> Starting
  -> Playing <-> Paused
  -> Stopping
  -> Ready
  -> ShuttingDown
  -> Destroyed
```

- `LoadingBank` 失败不改变当前可播放 generation；
- `Starting` 只有在第一组原子命令执行回执后进入 `Playing`；
- `Paused` 默认冻结 music clock 和 group cursor，设备仍可渲染其他 bus；
- device lost 时记录 discontinuity。恢复策略必须由调用者选择 `resume_phase` 或 `restart_at_bar`，不能依据墙钟猜测；
- shutdown 先拒绝新请求，再 release groups，等待非实时所有权回收；render thread 不阻塞等待 worker。

## 10. Ducking、Stinger 与声学输入

### 10.1 Dialogue ducking 与 Sidechain

SME v1 同时提供两种明确区分的 ducking：

1. **State/automation ducking**：剧情或 UI 提交 duck request，按 priority、目标 dB、attack、hold、release 生成 music bus 自动化；
2. **Signal sidechain ducking**：Dialogue Bus 的 detector envelope 驱动 Music Bus compressor，支持 threshold、ratio、knee、attack、release、lookahead 上限和 makeup gain。

完整路径依赖预编译 Bus DAG：

```text
Dialogue Bus ─► Sidechain Detector ─┐
                                   ├─► Music Compressor ─► Music Bus output
Music Voice Groups ────────────────┘
```

约束：

- detector/compressor 状态在初始化或 bank load 时预分配；
- render thread 只处理固定节点与 block-local 参数；
- 多个 automation duck request 按资产声明的 combine mode 合并；
- automation 与 signal sidechain 的总衰减有明确 clamp；
- ducking 不改变 music state、clock 或 segment cursor；
- telemetry 分别报告 automation gain、detector envelope、compressor gain reduction；
- offline render 必须用真实 dialogue PCM 驱动 sidechain 验证，不能以固定 gain ramp 冒充。

### 10.2 Stinger

Stinger 必须声明：

- `immediate`、`next_beat` 或 `next_bar`；
- 是否 duck 主音乐；
- voice priority 和最大并发；
- 是否允许被重复触发；
- 超时策略：drop、replace 或推迟。

Stinger 走同一绝对 frame scheduler，但不加入主状态图。

### 10.3 Acoustic-to-music

声学系统只能通过明确 profile 输出低频、平滑、可审计的音乐参数，例如 openness 或 room size。约束：

- 先在 control thread clamp、平滑、限速和量化；
- 默认只影响 layer gain、filter 或 reverb send；
- 不直接切换主 state；
- GPU 结果迟到时保留上一值或使用 CPU 结果；
- 缺失声学数据不影响音乐 clock 和 transition 正确性；
- 映射规则属于 music asset/profile，不硬编码在 solver。

## 11. 错误、Fallback 与恢复

### 11.1 错误类别

至少需要：

```zig
pub const MusicError = error {
    InvalidState,
    InvalidHandle,
    InvalidBankVersion,
    UnsupportedCapability,
    InvalidMusicGraph,
    InvalidTempo,
    MisalignedStems,
    TransitionNotFound,
    TargetNotResident,
    VoiceBudgetExceeded,
    CommandQueueFull,
    StaleAssetGeneration,
    StreamUnderrun,
};
```

错误必须同时进入调用结果和结构化 telemetry/trace；音频线程只写固定字段计数，不格式化文本。

### 11.2 允许的 fallback

- SME feature 关闭时，调用者显式选择 legacy event + music bus 普通播放；
- GPU/声学参数不可用时，不使用该可选控制输入；
- 某个非必需 stream layer 解码失败时，按资产 `drop_rank` 移除该层并保留可验证的最小配器集合；
- 必需 stream 无法读取时，切换到资产显式声明且已预取的 resident emergency segment，并报告 degraded 状态；
- 可选 layer voice 不足时，按资产 `drop_rank` 使用已验证的最小 layer 集；
- 目标未及时 resident 时，按规则推迟到下一个 beat/bar；
- 指定的 fallback segment 是真实、已校验、可播放的资产。

### 11.3 不允许的 fallback

- transition 找不到时选择表中第一项；
- 固定计时器或游戏帧近似 beat；
- 分别即时启动多个 stems；
- 缺 layer 时返回 success 且不记录；
- stream underrun 时填充伪造音乐或调用外部播放器；
- 固定 scene/state 名返回预设音乐结果；
- GPU、I/O 或锁进入 render callback；
- 不支持 tempo map 时静默按第一 BPM 播放。

## 12. Telemetry、Trace 与调试

### 12.1 Runtime telemetry

SME 至少暴露：

- 当前/目标/pending state；
- 当前 theme、segment、bar、beat、loop epoch；
- active groups、active/virtual/dropped music layers；
- transition requested/planned/executed/cancelled/late 数；
- request-to-plan 与 request-to-audible 延迟；
- scheduled command queue high-water mark/overflow；
- voice reservation failures；
- prefetch miss、stream underrun、最低 buffer 水位；
- stem skew 最大 frames（目标必须为 0）；
- bank generation 与 hot reload count；
- duck gain 和 active duck sources；
- planner/control/render p50/p95/p99/p999 时间（非 render 线程聚合）。

### 12.2 Transition trace

每条 trace 记录固定结构：

```text
request_id, plan_id, from_state, to_state,
request_frame, planned_frame, executed_frame,
sync, source_segment, target_segment,
asset_generation, result, reason
```

Layer trace 记录 group/layer 的 start frame、cursor、target gain、ramp start/end、stop frame 和 drop reason。

offline 与 realtime 使用同一 trace schema。文本/JSON 序列化发生在非实时线程。

### 12.3 可视化

SME v1 作者工具和运行时调试视图必须显示 state graph、tempo/meter timeline、entry/exit cue、fill route、当前 transport、下一 transition、候选求解结果、layer/bus meters、sidechain gain reduction、stream 水位和 trace timeline。依照仓库约束，图形化工具使用 `in-dreaming/gpu`；headless CI 同时保留 JSON/CSV 输出。可视化不是替代 correctness trace，但它本身属于 v1 交付物。

## 13. 验证与验收

### 13.1 单元测试

- 固定 BPM 下 beat/bar frame 计算长期无漂移；
- 多 tempo region、线性 ritardando/accelerando、拍号变化、pickup 和 loop 回绕的 grid 无漂移；
- 请求恰在边界前、边界上、边界后时结果一致；
- quantum 内 command offset 正确；
- 同 frame 命令的 sequence 稳定；
- state graph 校验覆盖缺引用、歧义、不可达；正常音乐状态环必须允许，无进展 fallback 环必须拒绝；
- stems 长度、loop、sample rate、channel layout 不一致时拒绝；
- intensity curve、attack/release、迟滞正确；
- hot reload generation 失配取消旧 plan；
- queue 满、voice 不足、目标不 resident 返回明确错误。
- cue compatibility、fill 多段路由和稳定 tie-break 正确；
- logic bytecode 的上限、类型、优先级和确定性正确；
- sequence、weighted random、shuffle bag、no-repeat 和 history restore 的选择结果确定；
- streaming seek/priming/loop 与 PCM reference 的 sample cursor 一致；
- sidechain detector/compressor 的 attack/release 与 gain reduction 正确；

### 13.2 集成测试

最小真实链路必须是：

```text
MusicRequest
 -> Director
 -> TransitionPlan
 -> ScheduledCommandBlock
 -> Mixer voices
 -> Offline PCM/WAV + trace
```

必须覆盖：

1. `explore -> combat -> explore` 的 next-bar 切换；
2. 同主题 4 层 intensity 往返，所有 cursor 始终一致；
3. crossfade 同时存在 source/target 两组，结束后旧组释放；
4. 变 tempo、变拍号的 source 经 fill route 进入 target entry cue；
5. dialogue automation duck 与真实 PCM sidechain 均不改变音乐 transport；
6. stinger 在 immediate/beat/bar 边界触发并遵守并发/替换策略；
7. 长音乐通过真实 codec/stream cache 连续播放、seek、loop 和 transition；
8. authoring tool 创建、校验、preview、编译 bank，runtime 加载同一 build ID；
9. rapid state churn 被仲裁且不产生过期 transition；
10. stop/pause/resume/device discontinuity；
11. real/virtual voice 切换、voice budget 降级与无法满足最小集合；
12. bank hot reload 时旧 group 安全播放到释放且可 rollback；
13. capture/restore 后 state、selector history、seed 和 cue transport 连续，错误 build ID 被拒绝；
14. 至少 8 小时 realtime/offline 压力运行无 stem skew、underrun、dropout 或泄漏；
15. 相同 seed、bank 和请求 trace 两次渲染得到相同 schedule；允许 PCM 浮点比较使用明确容差。

### 13.3 通过标准

SME v1 只有同时满足以下条件才可称为实现：

- 所有状态切换的 `executed_frame` 等于计划边界；
- 同一 group 所有必需 stems 的 start frame 和 cursor skew 为 0；
- nominal 场景 command overflow、stream underrun、dropout 为 0；
- tempo map、entry/exit cue、fill、逻辑表达式、stinger、重配器和 sidechain 的矩阵全部通过；
- production codec、streaming、seek、loop、prefetch 和 emergency segment 路径通过；
- authoring application 能完成创建、校验、预览、构建、live tuning 与 hot reload；
- `in-dreaming/gpu` 调试视图与 headless trace 对同一运行时状态一致；
- offline WAV 非静音、无非预期 clipping；
- trace 来源于真实 runtime，不是手写样例；
- `zig build test` 与扩展后的 `tools/run_validation.ps1` 通过；
- real-time audit 未发现 render path 分配、锁、I/O、日志或 wait；
- 文档明确报告 streaming、channel、codec、tempo/cue/fill 和 voice budget 的实际能力；
- 不使用 stub、外部播放器、固定场景结果或 silent fallback。

只完成状态结构、伪代码或普通 event crossfade，不满足上述定义。

## 14. SME v1 完整实施图与依赖

M0-M5 是同一个 v1 的内部集成批次，不是多个产品版本。只有 M0-M5 全部完成、全量 gate 通过，才允许标记 SME v1 DONE 或发布。任何中间批次只能用于开发验证。

```text
M0 Contract freeze
 ├─ versioned IDs/schema/capability bits
 ├─ absolute render frame + sample-offset command contract
 └─ MusicRuntime ownership/API
        │
M1 Deterministic transport
 ├─ complete tempo/meter map clock
 ├─ state graph/director/planner
 ├─ bounded logic evaluator
 └─ offline schedule/cue solver trace
        │
M2 Real synchronized playback
 ├─ atomic MusicVoiceGroup
 ├─ mono/stereo/5.1/7.1 channel contract
 ├─ beat/bar/cue/end transitions
 ├─ entry/exit/fill routes
 └─ layer intensity/reorchestration + crossfade
        │
M3 Asset and production path
 ├─ complete compiled music tables
 ├─ production codec/channel conversion
 ├─ streaming/prefetch/seek
 ├─ hot reload generations
 └─ failure tests and memory gates
        │
M4 Integration quality
 ├─ automation + real sidechain ducking
 ├─ stingers + virtual music voices
 ├─ acoustic mapping（输入可选，能力必需）
 ├─ stress/RT audit/device smoke
 └─ telemetry/trace
        │
M5 Authoring and release closure
 ├─ in-dreaming/gpu authoring application
 ├─ graph/timeline/cue/fill editing and preview
 ├─ live tuning/hot reload/rollback
 ├─ in-dreaming/gpu runtime visual debugger
 └─ full realtime/offline/CI release matrix
```

关键依赖：

- M1 依赖 engine 暴露稳定绝对 render frame；
- M2 依赖 mixer 的 quantum 内 scheduled command 与原子 voice group；
- 成品 stem 依赖 channel layout/stereo path；
- M3 streaming 依赖真实 worker/I/O 与预分配 ring buffer；
- sidechain compressor 依赖 Bus DAG/effect contract；
- authoring/可视化依赖 `in-dreaming/gpu`，并与 headless correctness gate 同时验收；
- M5 必须使用 M0-M4 的真实 runtime/compiler，不得另写 preview mock。

每个批次都应先增加自动验证，再扩大能力。M0/M1 通过不代表音频同步播放完成，M2 通过不代表 production streaming 完成，M3/M4 通过不代表 authoring/product workflow 完成。只有完整 v1 release matrix 可以关闭任务。

## 15. ADR

### ADR-SME-001：自研 Zig Music Director

决定：在 Bugu 内实现 Music Director，不引入闭源 SME 或新的高层音频中间件。

理由：保持 Zig-first、可审计、可验证，并复用现有 mixer/event/bank。

### ADR-SME-002：硬件 render frame 是唯一音乐时钟

决定：transition 基于绝对 sample frame，不基于游戏 delta time 或墙钟。

理由：避免漂移，并使 device 与 offline backend 行为一致。

### ADR-SME-003：SME 位于控制层，mixer 只执行计划

决定：状态图、规则和资产选择在 Audio Control Thread；render thread 只执行不可变、有界命令。

理由：维持实时安全和模块所有权。

### ADR-SME-004：SME v1 是完整能力版本

决定：v1 同时支持复杂 tempo/meter map、beat/bar/cue/end 同步、entry/exit、fill、逻辑表达式、完整重配器、streaming、sidechain 和 authoring workflow；不存在功能延期到未定义后续版本的发布路径。

理由：资产、调度、streaming 和作者工作流彼此构成完整产品 contract。只交付固定 tempo 核心会固化错误 schema，并无法满足新的产品计划。

### ADR-SME-005：同步 stem 使用原子 Voice Group

决定：同一 segment 的必需 layers 必须同 frame 启动、共享 cursor，并作为一组预留/失败。

理由：独立即时 voice 无法保证相位与音乐结构正确。

### ADR-SME-006：物理声学是可选控制输入

决定：AcousticResponse 可经 profile 映射为音乐参数，但不拥有 state graph，也不进入 render 调度依赖。

理由：保留 Bugu 差异化能力，同时避免 GPU/solver 时序破坏音乐正确性。

### ADR-SME-007：版本化 music bank，不扩散未版本化 manifest

决定：音乐元数据必须进入带版本和 capability bits 的编译资产契约。

理由：SME 对跨表引用、时间和同步的要求无法依靠宽松字段解析安全演进。

## 16. v1 已冻结的实现选择

为避免完整功能再次被实现阶段的局部选择延期，v1 冻结以下 contract：

1. 每个 `Engine` 拥有一个主 `MusicRuntime` 和一个主 transport；作者预览或多设备场景通过独立 `Engine` context 隔离，不在同一 mixer 内创建竞争时钟。
2. Music request 使用独立的 bounded control queue；最终渲染命令编译进引擎统一 `ScheduledCommandBlock`，与 voice/bus 命令共享绝对 frame 排序。
3. `ChannelLayout` 支持 mono、stereo、5.1、7.1 和显式 channel mask；未知布局加载失败。
4. Resident PCM 与 Ogg Opus 是 v1 必需格式。`libopus`、`libogg` 以 git submodule 引入，Zig adapter 负责 demux/decode、pre-skip、end padding 和 sample-accurate seek。增加其他 codec 不得改变 Music Bank 语义。
5. Music/SFX voice 预算由 platform profile 编译进 bank；base music layer 和 dialogue 属于保护类，可选 music layer 按 `drop_rank` virtualize，所有抢占都写 trace。
6. Pause 默认冻结 transport/cursor；device lost 后默认从最后 committed state 的下一个合法 bar/cue 重新进入。API 可显式请求 `resume_phase`，但必须在 stream/cache 仍有效时才允许。
7. 作者源格式采用版本化、可 diff 的 TOML project + 独立音频文件；`tools/sme_authoring` 与 CLI compiler 读写同一 schema，compiled binary bank 是唯一 runtime 输入。
8. Bank 采用 `major.minor` schema：major 不兼容即拒绝，minor 通过 capability bits 前向检查。公共 ID 延续 FNV-1a 64 并在构建时检测冲突；整包使用 SHA-256 content hash 与单调 generation。
9. 调度 trace 必须跨平台 bit-identical；同 backend/target 的 offline PCM 以逐 sample `1e-6` 绝对误差和汇总 peak/RMS 容差校验，不把跨 SIMD/backend PCM bit-identical 作为错误承诺。
10. v1 同时交付 Bus DAG、state automation ducking 与真实 signal sidechain compressor；两者使用独立 telemetry，不得互相冒充。
11. 完整 authoring 与调试 UI 使用 `in-dreaming/gpu`；headless CLI/compiler/validator 不依赖 GPU，并与 UI 共享核心库。
12. v1 release 必须完成 M0-M5。feature flag 只能控制运行时启用，不得用于发布一个缺表、缺 codec、缺 streaming、缺 sidechain 或缺作者工具的“精简 v1”。

这些选择若需改变，必须新增 ADR 并同步 schema、runtime、authoring、validation 和迁移策略；单个实现任务不得自行偏离。

## 17. 来源与关联文档

- `docs/research/kcd.md`：KCD 自适应音乐理念、水平重排序、垂直分层、entry/exit、fill、创作资产工作流。
- `docs/research/kcd.sme.md`：Bugu 现状评估、三方案比较以及采用收敛版 Music Director 的推荐。
- `docs/design/audio-engine-design.md`：L0-L9、mixer、bank、event、bus、线程与实时安全总设计。
- `docs/design/audio-runtime-contract.md`：control/render/worker 所有权和 immutable snapshot/queue contract。
- `docs/design/audio-zig-api.md`：Zig-first 公共 API 与模块边界。
- `docs/tasks/asetup.md`：第三方、语言、fallback、anti-mock 和可视化硬约束。
- `docs/product-readiness-roadmap.md`：当前 prototype 限制与发布 gate。
