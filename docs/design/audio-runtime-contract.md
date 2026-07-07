# Bugu 实时音频运行时 Contract

状态：Draft v0.1  
日期：2026-07-08  
任务：T002 实时运行时 contract 与线程模型设计  
依赖：docs/tasks/asetup.md、docs/design/audio-engine-design.md 第 4、5、10、11、12 节

## 1. 目标

本文定义 Bugu P0-P3 共用的实时运行时 contract。后续 T003-T011 必须以这里的线程边界、所有权规则和实时安全规则为准。

核心原则：

- Audio Render Thread 只渲染已准备好的不可变数据，不分配、不加锁、不做 I/O、不等待 GPU 或 worker。
- Audio Control Thread 是运行时状态的唯一写入者，负责解析命令、推进 voice 状态、消费 worker/propagation 结果，并发布 RenderSnapshot。
- Game Thread、Worker Thread、Propagation backend 只能通过有界队列或不可变 buffer 与 Audio Control Thread 交换数据。
- 所有进入 Audio Render Thread 的结构都必须是预分配、不可变、生命周期明确的数据。

## 2. 线程模型

| 线程 | 职责 | 可以写入 | 禁止 |
|---|---|---|---|
| Game Thread | post event、set RTPC/state/switch、加载/卸载 bank 请求、listener/emitter transform 更新 | AudioCommandQueue | 直接修改 voice、bus、bank runtime 状态 |
| Audio Control Thread | 消费命令、更新 voice/bus/event 状态、消费 worker completion、消费 AcousticResponseBuffer、构建 snapshot | RuntimeState、inactive RenderSnapshot buffer、TelemetryCounters control 侧字段 | 等待 audio callback、阻塞式等待 GPU fence |
| Audio Render Thread / Device Callback | 按 backend 请求帧数拉取固定 quantum mixer 输出 | 输出 PCM buffer、render 侧少量 atomic telemetry | alloc、lock、I/O、日志格式化、GPU wait、复杂共享结构写入 |
| Worker Threads | decode、stream I/O、bank compile/load 辅助、HRTF/IR 预处理 | WorkerCompletionQueue、worker-owned scratch | 直接写 RuntimeState 或 RenderSnapshot |
| Propagation Backend Thread / GPU Thread | CPU/GPU acoustic propagation、scene extraction 后台处理 | AcousticResponseBuffer completion | 直接写 mixer 参数或阻塞 audio render |

Audio Control Thread 是所有跨线程结果进入音频运行时的汇合点。Audio Render Thread 不消费 Game/Worker/GPU 队列，只消费当前 RenderSnapshot 和可选的固定容量 render-local queues。

## 3. 跨线程数据流

| 数据流 | Producer | Consumer | 载体 | 所有权与生命周期 |
|---|---|---|---|---|
| Game -> Control | Game Thread | Audio Control Thread | AudioCommandQueue，MPSC，有界 ring | command payload 必须值语义或引用稳定 bank handle；入队失败返回 backpressure |
| Worker -> Control | Worker Threads | Audio Control Thread | WorkerCompletionQueue，MPSC，有界 ring | completion 拥有 decoded chunk/bank blob handle；Control 接收后转入 RuntimeState |
| Propagation -> Control | CPU/GPU propagation | Audio Control Thread | AcousticResponseBuffer 双/三缓冲 + completion queue | backend 写入 inactive response buffer；Control 只在 completion 后读取 |
| Control -> Render | Audio Control Thread | Audio Render Thread | RenderSnapshot + SnapshotSwap，双/三缓冲 | Control 构建 inactive snapshot 后原子发布；Render 持有一份只读指针直到 callback/quantum 完成 |
| Render -> Control/Tools | Audio Render Thread | Audio Control Thread 或 profiler | TelemetryCounters，atomic counters | Render 只做原子递增/存储数值；Control 低频采样并格式化 |

所有队列必须有固定容量。容量不足时，Producer 不得阻塞 Audio Render Thread；Game/Worker 可以收到明确错误或丢弃低优先级命令，Control 记录 telemetry。

## 4. 接口草案

以下是语义草案，不要求作为最终 Zig 语法直接落地。T003 应把这些概念转成 Zig-first API。

### 4.1 AudioCommand

```zig
const AudioCommandTag = enum {
    play_event,
    stop_voice,
    set_rtpc,
    set_state,
    set_switch,
    set_listener_transform,
    set_emitter_transform,
    load_bank,
    unload_bank,
    hot_reload_bank,
    shutdown,
};

const AudioCommand = struct {
    seq: u64,
    tag: AudioCommandTag,
    frame_hint: u64,
    payload: union(AudioCommandTag) {
        play_event: PlayEventCommand,
        stop_voice: StopVoiceCommand,
        set_rtpc: SetRtpcCommand,
        set_state: SetStateCommand,
        set_switch: SetSwitchCommand,
        set_listener_transform: TransformCommand,
        set_emitter_transform: TransformCommand,
        load_bank: BankLoadCommand,
        unload_bank: BankUnloadCommand,
        hot_reload_bank: BankHotReloadCommand,
        shutdown: void,
    },
};
```

规则：

- command 不持有可变外部指针。
- 字符串、路径、authoring metadata 不进入 Audio Render Thread；Control 侧解析后转成 id/handle。
- Game Thread 连续提交大量 command 时，queue 满返回 `error.AudioCommandQueueFull`，调用方可重试或丢弃非关键事件。

### 4.2 AudioCommandQueue

```zig
const AudioCommandQueue = struct {
    capacity: usize,
    write_index: AtomicU32,
    read_index: AtomicU32,
    slots: []AudioCommand,

    pub fn tryPush(self: *AudioCommandQueue, command: AudioCommand) QueueError!void;
    pub fn drain(self: *AudioCommandQueue, out: []AudioCommand) usize;
};
```

P0 可以使用全局 MPSC queue。若 lock-free MPSC 初版风险过高，允许 Game Thread 使用非 render 侧 mutex 保护 push，但 Audio Render Thread 不得接触该 mutex。Control drain 在固定预算内执行，超出预算的 command 留到下一 tick。

### 4.3 RenderSnapshot

```zig
const RenderSnapshot = struct {
    generation: u64,
    sample_rate: u32,
    quantum_frames: u32,
    output_channels: u16,
    voice_table: []const RenderVoice,
    bus_table: []const RenderBus,
    bus_order: []const BusId,
    automation_blocks: []const AutomationBlock,
    acoustic: *const AcousticSnapshot,
    bank_refs: []const BankRuntimeRef,
};
```

规则：

- snapshot 发布后不可变。
- snapshot 内引用的 bank/runtime blob 必须 ref-count 或 epoch pin，直到没有 Render Thread 使用旧 snapshot。
- snapshot 只包含 render hot path 必需字段；debug name、source path、复杂 authoring data 保留在 Control/Tools 侧。

### 4.4 SnapshotSwap

```zig
const SnapshotSwap = struct {
    active_index: AtomicU32,
    buffers: [3]RenderSnapshotBuffer,
    retired_generations: AtomicU64,

    pub fn beginBuild(self: *SnapshotSwap) *RenderSnapshotBuilder;
    pub fn publish(self: *SnapshotSwap, built: *RenderSnapshotBuilder) void;
    pub fn acquireForRender(self: *SnapshotSwap) *const RenderSnapshot;
    pub fn releaseFromRender(self: *SnapshotSwap, generation: u64) void;
};
```

推荐三缓冲：

- active：Render 当前可读。
- build：Control 正在写。
- retired：等待 render generation 越过后回收。

Audio Render Thread 的 acquire/release 只能做原子读写和 bounded 操作。内存回收由 Control Thread 根据 generation/epoch 延迟执行。

### 4.5 WorkerCompletionQueue

```zig
const WorkerCompletionTag = enum {
    decoded_chunk_ready,
    bank_blob_ready,
    bank_load_failed,
    stream_underrun,
    hrtf_block_ready,
    ir_block_ready,
};

const WorkerCompletion = struct {
    seq: u64,
    tag: WorkerCompletionTag,
    owner_bank: BankHandle,
    payload: WorkerCompletionPayload,
};
```

Worker 完成结果只进入 Control Thread。Render Thread 看到的是 Control 已整合进 snapshot 的 decode buffer handle、stream ring 状态或预处理 DSP data。

### 4.6 AcousticSnapshot

```zig
const AcousticSnapshot = struct {
    generation: u64,
    source_responses: []const AcousticVoiceResponse,
    listener_response: ListenerAcousticResponse,
    fallback_mode: AcousticFallbackMode,
    confidence: f32,
};

const AcousticVoiceResponse = struct {
    voice_id: VoiceId,
    direct_gain: f32,
    direct_delay_frames: u32,
    direct_lpf_hz: f32,
    transmission_gain: f32,
    transmission_lpf_hz: f32,
    diffraction_gain: f32,
    reverb_send: f32,
    openness: f32,
    confidence: f32,
};
```

Propagation backend 输出的是 AcousticResponseBuffer，不直接输出 PCM。Control Thread 将最新完整 response 转成 AcousticSnapshot；如果结果晚一帧或缺失，沿用上一份 snapshot 并降低 confidence 或进入 fallback mode。

### 4.7 TelemetryCounters

```zig
const TelemetryCounters = struct {
    rendered_callbacks: AtomicU64,
    rendered_frames: AtomicU64,
    underrun_count: AtomicU64,
    dropout_count: AtomicU64,
    callback_over_budget_count: AtomicU64,
    max_callback_nanos: AtomicU64,
    command_queue_full_count: AtomicU64,
    worker_completion_drop_count: AtomicU64,
    acoustic_stale_frame_count: AtomicU64,
    snapshot_generation: AtomicU64,
};
```

Render Thread 只允许更新简单 atomic counter。格式化、histogram 构建、p99/p999 汇总、日志输出全部由 Control/Tools 线程完成。

## 5. Fixed Quantum 与 Backend Callback 适配

Bugu mixer 固定 quantum，P0 默认 256 frames，P2 可支持 128 frames。设备 callback 请求帧数可能不是 quantum 的整数倍，因此 backend adapter 使用预分配 FIFO：

1. callback 请求 `N` frames。
2. 从 render FIFO 拷贝已有 frames 到 output。
3. FIFO 不足时，循环调用 `mixer.renderQuantum(snapshot, scratch_quantum)` 生成固定 quantum，并写入 FIFO。
4. output 填满后返回。

实时约束：

- FIFO、scratch quantum、channel conversion buffer 在 device start 前预分配。
- callback 内不扩容、不打开设备、不记录格式化日志。
- 如果 mixer 超预算或 FIFO underrun，输出真实 silence/ramp-to-zero fallback，并记录 atomic underrun/dropout counter；不能空 callback 返回成功后假装有音频。

## 6. 生命周期与状态机

### 6.1 Runtime Start

1. Game Thread 创建 Engine。
2. Engine 预分配 command queue、completion queue、snapshot buffers、render FIFO、voice pool、bus pool、telemetry。
3. 启动 Audio Control Thread。
4. 启动 backend device；device callback 只拿到 BackendRenderContext。
5. Control 发布初始空 RenderSnapshot。

### 6.2 Device Lost / Reopen

状态机：

| 状态 | 说明 |
|---|---|
| Running | 正常输出 |
| DeviceLost | backend 报告设备断开；Render 停止被调用或输出 offline/silence |
| Reopening | Control Thread 尝试重开设备并重建 backend adapter buffers |
| OfflineFallback | 无设备或 CI 环境下，offline backend 继续生成真实 PCM/WAV buffer |
| Running | 新设备成功后发布新的 backend format snapshot |
| Failed | 重试失败，返回明确错误并保留 runtime 可 shutdown |

Render Thread 不负责重开设备。device lost 事件由 backend/control 侧处理，旧 snapshot 在无 callback 时自然退休。

### 6.3 Bank Hot Reload / Unload

- Game Thread 提交 hot_reload_bank 或 unload_bank command。
- Worker 加载/编译新 bank blob，completion 给 Control。
- Control 在安全点创建新 immutable bank runtime blob，并发布引用新 blob 的 snapshot。
- 旧 voice 继续持有旧 BankRuntimeRef，直到自然结束或显式 fade out。
- 旧 bank 引用计数归零且不再被 snapshot generation pin 住后，Control 侧释放。
- Render Thread 不读取路径、不打开文件、不解析 manifest。

### 6.4 Shutdown

1. Game Thread 提交 shutdown command，并停止提交新 command。
2. Control 将 runtime 状态切到 Draining，拒绝新 play event，允许 stop/fade。
3. Control 发布 shutdown snapshot 或 silence snapshot。
4. 后端停止 device callback。
5. Control 等待 worker/propagation 非 render 线程退出。
6. Control 回收 snapshot、bank、queue、backend adapter 内存。

Audio Render Thread 不参与 join，不等待 worker，不释放复杂资源。

## 7. Fallback 边界

| 场景 | 允许行为 | 状态与证据 |
|---|---|---|
| 无音频设备/CI | Offline backend 使用同一 mixer/render path 生成真实 PCM/WAV buffer | 可作为自动化证据；设备 backend 任务仍需区分真实设备证据 |
| callback underrun | 输出真实 silence 或短 ramp-to-zero，并增加 underrun/dropout counter | 不能空函数 success |
| propagation result missing | 沿用上一份 AcousticSnapshot；连续缺失后使用 distance + simple occlusion fallback | 记录 stale frame count 和 fallback mode |
| GPU result 晚到 | Control 下一 tick 消费；Render 不等待 fence | acoustic_stale_frame_count 增加 |
| worker decode 晚到 | voice 保持 virtual/paused/prebuffering 或播放已预取 buffer；不得在 Render Thread 解码 | stream underrun counter |
| device lost | Control 进入 DeviceLost/Reopening/OfflineFallback | 记录状态转换 |

## 8. 验收场景

### 8.1 连续 post 1000 个 play event

Game Thread 调用 `tryPush`。queue 容量内的 command 被 Control 分批 drain，超过容量返回 queue full。Control 在每个 tick 内按预算解析事件并创建 voice request。Render Thread 只在下一份 snapshot 看到已准备好的 RenderVoice，不接触 command queue。

### 8.2 callback 一次请求非固定帧数

Backend adapter 使用 render FIFO 衔接任意 `N` frames 与固定 quantum。所有 FIFO memory 预分配。callback 内只执行 bounded copy 和必要数量的 quantum render。

### 8.3 streaming worker 解码完成

Worker 把 decoded chunk handle 推入 WorkerCompletionQueue。Control 消费后更新 stream buffer state，并在下一份 snapshot 中暴露给 Render。Render 只读取已就绪 buffer。

### 8.4 GPU/CPU propagation 结果晚一帧

Control 未收到新 AcousticResponseBuffer 时沿用上一份 AcousticSnapshot。若连续超时，进入 AcousticFallbackMode，使用 T008 空间参数和 simple occlusion 的已准备结果。Render 不等待 propagation。

### 8.5 Bank 热更新时旧 voice 仍在播放

新 bank 以新 immutable blob 发布。旧 voice 和旧 snapshot pin 旧 bank blob；旧 voice 结束后释放引用。Control 负责延迟回收，Render 不释放 bank。

### 8.6 设备断开并重开

backend/control 侧进入 DeviceLost/Reopening。Control 保持 runtime state，可选择 offline render 继续生成 PCM 证据。新设备成功后，Control 发布包含新 format/latency 的 snapshot，并重建 backend adapter FIFO。

### 8.7 游戏退出

shutdown command 使 Control 停止接收新 play event，发布 silence/shutdown snapshot，停止 backend，再 join worker/propagation/control 线程。Render Thread 不做 join 或复杂析构。

## 9. 测试与证据要求

T004 起应逐步提供这些证据，供 T012 汇总：

- render callback 审计：静态检查 callback 调用链不含 allocator、mutex、file I/O、GPU wait、printf/log format。
- queue 压测：1000 个 play event，记录 accepted/rejected/drained 数量和 command_queue_full_count。
- variable callback test：用离线 backend 请求 1、127、256、300、513 frames，验证输出 frame count、peak/RMS 和无越界。
- snapshot swap test：Control 高频 publish，Render 高频 acquire/release，验证 generation 单调、无 use-after-free。
- propagation stale test：模拟 AcousticResponseBuffer 缺失 1、2、N 帧，验证 fallback_mode 和 stale counter。
- bank hot reload test：旧 voice 持旧 bank 播放，新事件使用新 bank，旧 bank 延迟释放。
- shutdown test：重复 start/stop，确认 worker/control/backend 线程退出，Render 不执行阻塞析构。

自动化允许使用 offline backend 生成真实 PCM buffer；真实设备相关 evidence 必须在 T004 设备任务中单独记录。

## 10. 对后续任务的影响

- T003 必须把本文概念固化为 Zig 模块、public API 和可选 C ABI 边界。
- T004 backend 只能调用固定 quantum adapter 和 mixer render，不得直接生成 sine 作为最终 backend path。
- T005 mixer 的 voice/bus hot data 必须进入 RenderSnapshot，不得从共享 RuntimeState 动态读取。
- T006 asset/bank 加载必须通过 worker completion 和 immutable bank blob 进入 runtime。
- T010/T011 propagation 输出必须经过 AcousticResponseBuffer -> Audio Control -> AcousticSnapshot -> RenderSnapshot，不得直接写 mixer 参数。
- T012 应使用本文第 9 节作为 evidence schema 的起点。
