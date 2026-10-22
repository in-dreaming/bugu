//! Production embedding runtime: bounded MPSC control, immutable snapshots,
//! generation-safe instances, and callback-local render state.

const std = @import("std");
const core = @import("../core/engine.zig");
const mixer = @import("../mixer/mixer.zig");
pub const scheduler = @import("sme-scheduler");
const music = @import("music");
pub const channel_layout = @import("sme-channels");
pub const music_group = mixer.music_group;
pub const streaming = @import("sme-streaming");
pub const virtual_voice = @import("sme-virtual-voice");
pub const bus_runtime = @import("sme-bus-runtime");
pub const duck_lifetime = bus_runtime.duck_lifetime;
pub const layer_runtime = @import("sme-layer-runtime");
pub const graph_clock_runtime = @import("sme-graph-clock-runtime");
pub const graph_clock = graph_clock_runtime.gc;
pub const layer_spans = @import("sme-layer-spans");
pub const source_continuity = @import("source_continuity.zig");
pub const resident_transaction = @import("resident_transaction.zig");
/// Separate bounded Control-producer metadata; not a recording/replay profile.
pub const capture_handoff_control = @import("sme-capture-handoff-control");
/// Separate opt-in partial order evidence, sharing the real role collector.
pub const capture_order = @import("sme-capture-order");
pub const live_semantic = @import("sme-live-semantic");
pub const control_frontier_witness = @import("control_frontier_witness.zig");
pub const stream_acceptance_witness = @import("stream_acceptance_witness.zig");
pub const render_causal_witness = @import("render_causal_witness.zig");
pub const owned_render_facts = @import("owned_render_facts.zig");
pub const readiness_witness = @import("readiness_witness.zig");
pub const readiness_attachment_bytes: usize = @sizeOf(?ControlRuntime.ReadinessBinding) + @sizeOf(?streaming.stream.readiness_observation.SupplySink) + @sizeOf(?streaming.stream.readiness_observation.LifecycleSink) + @sizeOf(?scheduler.ControlSink) + @sizeOf(bool);
pub const readiness_operation_scratch_bytes: usize = readiness_witness.scratch_bytes;
comptime {
    if (readiness_attachment_bytes > 512 or readiness_operation_scratch_bytes > 512) @compileError("Readiness attachment/scratch bound exceeded");
}
/// Target ABI subsets, not measured total stack/latency bounds.
pub const render_causal_attachment_bytes: usize = @sizeOf(?RuntimeRenderer.RenderCausalBinding) + @sizeOf(u64) + @sizeOf(bool);
pub const render_causal_operation_scratch_bytes: usize = @sizeOf(scheduler.render_observation.Sink) + @sizeOf(render_causal_witness.ResourceEvent) + @sizeOf(bool);
/// Separate opt-in host storage, not charged to Service.memory or the old
/// frontier Bridge. These are source-level payload byte counts, not measured
/// total stack bounds: compiler temporaries/call frames are not included.
pub const stream_acceptance_attachment_bytes: usize = @sizeOf(?ControlRuntime.StreamAcceptanceBinding) + @sizeOf(u64);
pub const stream_acceptance_operation_scratch_bytes: usize = @sizeOf(streaming.stream.observation.Acceptance) + @sizeOf(streaming.stream.observation.Visibility);
/// Fixed ControlRuntime subset, excluding separately allocated Bridge storage
/// and test-only hooks. This is accounting, not an additional allocation.
pub const control_frontier_attachment_bytes: usize = @sizeOf(?ControlRuntime.ControlFrontierBinding) + @sizeOf(u64);
/// Labeled host-only fixed subset, outside MusicRuntime retained-byte accounting.
pub const resident_transaction_host_bytes = @sizeOf(resident_transaction.Slot) + scheduler.default_profile.plan_capacity * (@sizeOf(u16) + scheduler.default_profile.phases_per_plan * @sizeOf(u64)) + scheduler.block_capacity * scheduler.commands_per_block * @sizeOf(bool) + @sizeOf(u64);
const max_logical_voices = mixer.max_logical_voices;

pub const command_capacity = 4096;
pub const reserved_command_capacity = 128;
pub const normal_command_capacity = command_capacity - reserved_command_capacity;
pub const max_control_drain = 512;
pub const max_instances = 1024;
pub const max_render_voices = mixer.max_real_voices;
pub const snapshot_count = 3;
pub const steal_fade_frames = 32;
pub const cleanup_ingress_capacity = scheduler.block_capacity;

pub const RuntimeError = core.BuguError || scheduler.Error || virtual_voice.Error || bus_runtime.Error || layer_runtime.Error || graph_clock_runtime.Error || source_continuity.Error || resident_transaction.Error || error{
    VoiceBudgetExceeded,
    TargetNotResident,
    CommandQueueFull,
    InstanceCapacity,
    StaleInstance,
    DuplicateInstance,
    ConcurrentControl,
    SnapshotBusy,
    RuntimeStopped,
    DrainPending,
};

pub const InstanceHandle = struct {
    index: u16,
    generation: u16,

    pub fn eql(a: InstanceHandle, b: InstanceHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

pub const play_custody = @import("play_custody.zig");
pub const PlayCustodyAnchor = play_custody.Anchor(SampleOwner);
const PlayToken = PlayCustodyAnchor.Token;

pub const SampleOwner = struct {
    /// Immutable before exposure. Source custody may belong to another runtime.
    play_custody: ?*PlayCustodyAnchor = null,
    stream_token: bool = false,
    samples: []const f32,
    references: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    retired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(samples: []const f32) RuntimeError!SampleOwner {
        if (samples.len == 0) return error.InvalidArgument;
        return .{ .samples = samples };
    }

    /// Stream reservation/snapshot token owns no ring PCM. Ring lifetime is
    /// carried separately by streaming.Source, so stale snapshot pins cannot
    /// retain an alias to recycled mutable stream samples.
    pub fn initStreamToken() SampleOwner {
        return .{ .samples = &.{0}, .stream_token = true };
    }

    pub fn retain(self: *SampleOwner) RuntimeError!void {
        if (self.retired.load(.acquire)) return error.InvalidState;
        return self.pin();
    }

    fn pin(self: *SampleOwner) RuntimeError!void {
        var current = self.references.load(.acquire);
        for (0..8) |_| {
            if (current == 0 or current == std.math.maxInt(u32)) break;
            current = self.references.cmpxchgStrong(current, current + 1, .acq_rel, .acquire) orelse return;
        }
        return error.InvalidState;
    }

    pub fn release(self: *SampleOwner) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
    }

    pub fn retire(self: *SampleOwner) void {
        if (!self.retired.swap(true, .acq_rel)) self.release();
    }

    pub fn referenceCount(self: *const SampleOwner) u32 {
        return self.references.load(.acquire);
    }

    pub fn canDestroy(self: *const SampleOwner) bool {
        return self.retired.load(.acquire) and self.referenceCount() == 0;
    }
};

pub const VoiceParams = struct {
    gain: f32 = 1,
    pitch: f32 = 1,
    priority: f32 = 1,
    bus: mixer.BusId = .sfx,
    loop: bool = false,
    pan: f32 = 0,
    lowpass_hz: f32 = 20_000,
    reverb_send: f32 = 0,
};

pub const PlayCommand = struct {
    // Runtime-owned fields: public ingress/preparation always replaces caller
    // values. Copying a command never acquires another physical role.
    custody: ?PlayToken = null,
    block_custody: ?PlayToken = null,
    instance: InstanceHandle,
    reservation: u64 = 0,
    owner: *SampleOwner,
    params: VoiceParams,
};

pub const UpdateCommand = struct {
    instance: InstanceHandle,
    reservation: u64 = 0,
    params: mixer.VoiceControlParams,
    ramp_frames: u32,
    /// Bound by Control for scheduled targets; prevents public-handle ABA.
    incarnation: ?u64 = null,
};

pub const StopCommand = struct {
    instance: InstanceHandle,
    reservation: u64 = 0,
    fade_frames: u32,
    incarnation: ?u64 = null,
};

pub const BusCommand = struct {
    bus: mixer.BusId,
    gain: f32,
    ramp_frames: u32,
};

pub const CommandKind = enum { play, update, bus, stop, shutdown, scheduled, invalidate };
pub const Command = union(CommandKind) {
    play: PlayCommand,
    update: UpdateCommand,
    bus: BusCommand,
    stop: StopCommand,
    shutdown: void,
    scheduled: scheduler.Handle,
    invalidate: scheduler.Handle,
};

pub const MusicGroupLayer = struct { owner: *SampleOwner, asset_frame_origin: u64 = 0, layout: channel_layout.ChannelLayout, sample_rate: u32 = 48_000, generation: u64, gain: f32 = 1, stream: ?streaming.Source = null, required: bool = true, optional_policy: music_group.OptionalPolicy = .drop_for_group_lifetime, authored: virtual_voice.Authored = .{}, initial_state: virtual_voice.State = .real, audibility_envelope: f32 = 1 };
pub const ResidentEmergency = struct { segment: u64, segment_frames: ?u64 = null, layout: channel_layout.ChannelLayout, layers: []const MusicGroupLayer, loop: ?music_group.Loop = null, gain: f32 = 1, ramp_frames: u32 = 0 };
pub const MusicGroupDesc = struct { segment: u64, segment_frames: ?u64 = null, generation: u64, layout: channel_layout.ChannelLayout, layers: []const MusicGroupLayer, loop: ?music_group.Loop = null, start_cursor: u64 = 0, start_loop_epoch: u64 = 0, gain: f32 = 1, ramp_frames: u32 = 0, emergency: ?ResidentEmergency = null };
pub const GroupHandle = music_group.Handle;
/// Caller-owned optional SPSC trace; overflow is explicitly incomplete evidence.
pub const MusicGroupTrace = music.trace.RenderRing;
pub const StreamingInputRing = music.trace.Ring(music.trace.Input, 256);
pub const StreamFault = struct { group: GroupHandle, segment: u64, emergency_segment: u64, generation: u64, frame: u64, cursor: u64, loop_epoch: u64, layer: u16, degraded: bool };

pub const GroupStartCommand = struct { group: GroupHandle, content_hash: [32]u8 = @splat(0), start_curve: music_group.GainCurve = .linear };
pub const GroupSeekCommand = struct { group: GroupHandle, cursor: u64 };
pub const GroupLoopCommand = struct { group: GroupHandle, loop: ?music_group.Loop };
pub const GroupGainCommand = struct { group: GroupHandle, gain: f32, ramp_frames: u32 };
/// Zero keeps the low-level group-only pause; nonzero advances the public transport.
pub const GroupPauseCommand = struct { group: GroupHandle, paused: bool, next_transport_epoch: u64 = 0, continuity: ?source_continuity.Handle = null, continuity_hash: [32]u8 = @splat(0) };
pub const GroupStopCommand = struct {
    group: GroupHandle,
    release_frames: u32,
    release_curve: music_group.GainCurve = .linear,
    /// Internal crossfade cleanup only: one source stop paired atomically with
    /// one ordinary, distinct target stop. Never grants another command access
    /// to a releasing or terminal group, nor permits a stale full handle.
    allow_crossfade_source_stop: bool = false,
};
pub const LayerChangeHandle = struct { index: u16, generation: u64 };
pub const GroupLayerCommand = struct { group: GroupHandle, change: LayerChangeHandle, content_hash: [32]u8 = @splat(0) };
pub const GroupLayerGainCommand = struct { group: GroupHandle, layer: u16, gain: f32, ramp_frames: u32, source_incarnation: u64 = 1 };
pub const Realization = struct { group: GroupHandle, layer: u16, ticket: virtual_voice.Ticket, stream: streaming.Handle };
const LayerChangeSlot = struct { occupied: bool = false, generation: u64 = 0, group: GroupHandle = .{ .index = 0, .generation = 0 }, change: music_group.LayerChange = undefined, from_state: virtual_voice.State = .virtual, scheduled: bool = false, references: u16 = 0, settled: bool = false, succeeded: bool = false, real_reserved: bool = false, virtual_reserved: bool = false, content_hash: [32]u8 = @splat(0) };
pub const MusicLayerObservation = struct { automation_generation: u64 = 0, automation_revision: u64 = 0, automation_elapsed: u64 = 0, automation_next_span: u32 = 0, automation_gain_upper_bound: f32 = 0, automation_suspended: bool = false, state: virtual_voice.State, gain: f32, stream_generation: u64, last_change_frame: u64, sample_reads: u64, route_bound: f64 = 1, detector_dependency: bool = false };
/// Copied final lifetime facts returned after successful physical group release.
pub const MusicGroupReleaseResult = struct {
    group: GroupHandle,
    bank_generation: u64,
    source_switch: ?music_group.SourceSwitch,
};
/// Profile-5 final fact copied from the existing terminal release result.
/// Control-only, bounded sink; no extra atomic read or Render-thread work.
pub const GroupSourceFinal = struct { group: GroupHandle, bank_generation: u64, published: bool };
pub const GroupSourceFinalSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, GroupSourceFinal) void };
/// Private owned Control producer. Scratch belongs to the registered fixed
/// consumer until its matching finish. Null means evidence loss only. This
/// table grants no old readiness-profile admission and performs no new reads.
pub const TestOwnedControlFacts = struct {
    context: *anyopaque,
    /// Original engine key, with producer attribution kept outside that key.
    begin_query: *const fn (*anyopaque, streaming.stream.readiness_observation.QueryKey) ?*streaming.stream.readiness_observation.QueryRead,
    /// The local Input is borrowed only until this callback returns.
    finish_query: *const fn (*anyopaque, ?*const music.trace.Input) void,
    begin_acquisition: *const fn (*anyopaque, readiness_witness.AcquisitionKind, scheduler.Handle, u16) ?*readiness_witness.Acquisition,
    finish_acquisition: *const fn (*anyopaque) void,
    begin_reconciliation: *const fn (*anyopaque, readiness_witness.ReconciliationKind) ?*readiness_witness.Reconciliation,
    finish_reconciliation: *const fn (*anyopaque) u64,
    begin_invalidation: *const fn (*anyopaque) ?*scheduler.render_observation.InvalidationPublication,
    finish_invalidation: *const fn (*anyopaque) void,
};
pub const MusicGroupObservation = struct { source_incarnation: u64 = 1, graph_generation: u64 = 0, frame: u64, group: GroupHandle, generation: u64, mutation_epoch: u64, transport_epoch: u64, cursor: u64, loop_epoch: u64, paused: bool, state: music_group.State, gain: f32, bus_gain: f32, loop: ?music_group.Loop, layers: [music_group.max_layers]MusicLayerObservation = undefined, layer_count: u16, virtualized: u64, realized: u64, dropped: u64, stolen: u64 };
const MusicObservationCell = struct { words: [19 + music_group.max_layers * 13]std.atomic.Value(u64) = @splat(.init(0)) };
pub const VoiceBudgetEvent = music.trace.schema.VoiceBudgetRecord;
pub const graph_source_tombstone_bytes = music_group.max_groups * @sizeOf(std.atomic.Value(u16));
pub const SourceBindingOwnership = struct {
    initial_stream_leases: u16 = 0,
    initial_retire_frame: ?u64 = null,
    current_continuity: ?source_continuity.Handle = null,
};
pub const source_binding_control_bytes = music_group.max_groups * @sizeOf(SourceBindingOwnership) + @sizeOf(?*source_continuity.Manager) + @sizeOf(std.atomic.Value(?*source_continuity.Manager));
pub const music_group_terminal_bytes = music_group.max_groups * @sizeOf(music_group.TerminalCell);
pub const music_group_terminal_render_bytes = music_group.max_groups * @sizeOf(music_group.TerminalWriter);
/// Fixed subsets of ControlRuntime/Mixer, not additional allocations.
pub const music_group_source_switch_bytes = music_group.max_groups * @sizeOf(music_group.SourceSwitchCell);
pub const music_group_source_switch_render_bytes = music_group.max_groups * (@sizeOf(music_group.SourceSwitchWriter) + @sizeOf(u64));
/// Copied immutable source metadata for a future coordinated public owner.
/// This is not a live cursor observation, an automation rebind, or a lease.
pub const MusicGroupSource = struct {
    group: GroupHandle,
    bank_generation: u64,
    source_incarnation: u64,
    segment: u64,
    frames: u64,
    layer_count: u16,
    sample_rate: u32,
    layout: channel_layout.ChannelLayout,
    loop: ?music_group.Loop,
    degraded: bool,
    layers: [music_group.max_layers]Layer = @splat(.{}),
    pub const Layer = struct { stable_layer_id: u64 = 0, asset_frame_origin: u64 = 0, asset_frames: u64 = 0, required: bool = false, streamed: bool = false };
};
const PreparedGroupSlot = struct {
    generation_credit: ?music.MusicRuntime.GroupGenerationCredit = null,
    generation_credit_releasing: bool = false, // serialized Control only
    // Each reserved play acquires at most one Render pin in this full slot
    // incarnation. Control cannot reuse the slot until all actual pins return.
    render_pins_started: std.atomic.Value(bool) = .init(false),
    render_pin_mask: std.atomic.Value(u16) = .init(0),
    occupied: bool = false,
    generation: u64 = 0,
    references: u16 = 0,
    /// Render publishes successful source replacement; Control only acquires.
    /// Sticky for this retained prepared-group generation, including override
    /// clearing back to the original source. Never a seek/pause mutation epoch.
    graph_source_replaced: std.atomic.Value(u16) = .init(0),
    source_ownership: SourceBindingOwnership = .{}, // Control only.
    terminal: music_group.TerminalCell = .{},
    source_switch: music_group.SourceSwitchCell = .{},
    start_scheduled: bool = false,
    content_hash: [32]u8 = @splat(0),
    prepared: music_group.Prepared = undefined,
    emergency: ?music_group.Prepared = null,
    emergency_owners: [music_group.max_layers]*SampleOwner = undefined,
    emergency_owner_count: u16 = 0,
    plays: [music_group.max_layers]PlayCommand = undefined,
    resident_bytes: u64 = 0,
    stinger_count: u16 = 0,
    voice_profile_hash: [32]u8 = @splat(0),
    audibility: [music_group.max_layers]virtual_voice.Audibility = @splat(.{}),
};

/// Concrete typed payload seam. Later group commands must extend this union and
/// its all-or-none preflight; they cannot acquire another mixer owner.
pub const BusGraphCommand = struct { graph: bus_runtime.Handle, content_hash: [32]u8 = @splat(0) };
/// A Control-only authorization to end one retained incarnation after a music
/// transport change. It never changes the immutable begin/terminal identity or
/// grants permission to a raw batch. The owner retains the real end acceptance
/// across retries; an earlier Position is not restamped with the retry tick.
pub const DuckCleanupAuthorization = struct {
    handle: duck_lifetime.Handle,
    transport_epoch: u64,
    device_epoch: u64,
    accepted: scheduler.trace.Position,

    fn validateBatch(self: DuckCleanupAuthorization, runtime: *ControlRuntime, batch_handle: bus_runtime.BatchHandle) RuntimeError!void {
        const manager = runtime.bus_manager orelse return error.StaleBatch;
        const batch = try manager.batch(batch_handle);
        const tracked = batch.tracked_duck orelse return error.InvalidDuckIdentity;
        if (tracked.kind != .end or !tracked.handle.eql(self.handle)) return error.InvalidDuckIdentity;
        const slot = try manager.ducks.get(self.handle);
        const original = slot.cell.identity;
        const end = slot.end_batch orelse return error.InvalidDuckIdentity;
        if (end.context != batch_handle.context or end.index != batch_handle.index or end.generation != batch_handle.generation or
            batch.graph.context != original.graph.context or batch.graph.index != original.graph.index or batch.graph.generation != original.graph.generation or
            batch.layer_source != null or batch.count != 1) return error.InvalidDuckIdentity;
        const operation = batch.operations[0];
        if (operation != .end_duck or operation.end_duck.bus != original.bus or operation.end_duck.id != original.dsp_id) return error.InvalidDuckIdentity;
    }

    pub fn validate(self: DuckCleanupAuthorization, tick: ControlRuntime.TickV1, batch: bus_runtime.BatchHandle, command: scheduler.CommandIdentity) RuntimeError!void {
        try tick.requirePhase(.prepare);
        try self.validateBatch(tick.runtime, batch);
        command.token.validate() catch return error.InvalidDuckIdentity;
        const owner = tick.runtime.music_runtime orelse return error.InvalidState;
        if (owner.control != tick.runtime or !owner.control_guard.load(.acquire) or owner.tick_scope == null or
            !std.meta.eql(owner.tick_scope.?, tick) or (owner.tick_entry != .preparing and owner.tick_entry != .prepared)) return error.InvalidState;
        const generation = owner.generation orelse return error.InvalidDuckIdentity;
        const original = (try tick.runtime.bus_manager.?.ducks.get(self.handle)).cell.identity;
        try original.validate();
        if (original.context != owner.config.context or original.bank_context != owner.config.context or original.bank_index != 0 or
            original.bank_handle_generation != owner.handle_incarnation or original.asset_generation != generation.runtime_generation or
            original.device_epoch != generation.transport.device_epoch or self.device_epoch != original.device_epoch or
            self.transport_epoch == 0 or self.transport_epoch != generation.transport.transport_epoch or
            command.token.context.value() != original.context or command.token.asset_generation.value() != original.asset_generation or
            command.token.transport_epoch.value() != self.transport_epoch) return error.InvalidDuckIdentity;
        const accepted = self.accepted;
        const begin = original.accepted;
        if (accepted.control_tick == 0 or accepted.control_tick < begin.control_tick or
            (accepted.control_tick == begin.control_tick and accepted.input_order < begin.input_order) or
            accepted.accepted_control_frame < begin.accepted_control_frame or accepted.accepted_control_frame > command.execute_frame or
            accepted.control_tick > tick.runtime.stream_control_tick or accepted.accepted_control_frame > tick.runtime.tick_v1.frame) return error.InvalidDuckIdentity;
        // Current-tick positions must already have been issued at the actual
        // accepted Render frontier. Older positions are retained owner inputs.
        if (accepted.control_tick == tick.runtime.stream_control_tick and
            (accepted.accepted_control_frame != tick.runtime.tick_v1.frame or accepted.input_order >= tick.runtime.stream_input_order)) return error.InvalidDuckIdentity;
    }
};
pub const BusBatchCommand = struct {
    batch: bus_runtime.BatchHandle,
    group: ?GroupHandle = null,
    content_hash: [32]u8 = @splat(0),
    duck_cleanup: ?DuckCleanupAuthorization = null,
};
pub const GroupBusRouteCommand = struct { group: GroupHandle, layer: u16, route: bus_runtime.RouteHandle, ramp_frames: u32 = 0, content_hash: [32]u8 = @splat(0), source_incarnation: u64 = 1 };
pub const GroupLayerAutomationCommand = struct { group: GroupHandle, program: layer_spans.ProgramHandle, expected_previous: ?layer_spans.ProgramHandle = null, content_hash: [32]u8 = @splat(0) };
pub const GroupLayerAutomationStopCommand = struct { group: GroupHandle, program: layer_spans.ProgramHandle, mode: enum(u8) { hold_current } = .hold_current, content_hash: [32]u8 = @splat(0) };
pub const GraphSourceProgramCommand = struct { group: GroupHandle, program: graph_clock.Handle, content_hash: [32]u8 = @splat(0), source_hash: [32]u8 = @splat(0) };
pub const GraphSourceProgramStopCommand = GraphSourceProgramCommand;
/// New in-memory tags are appended. Existing tag identities and wire schemas stay fixed.
pub const ScheduledPayload = union(enum) { play: PlayCommand, update: UpdateCommand, stop: StopCommand, bus: BusCommand, group_start: GroupStartCommand, group_seek: GroupSeekCommand, group_loop: GroupLoopCommand, group_gain: GroupGainCommand, group_stop: GroupStopCommand, group_layer: GroupLayerCommand, group_pause: GroupPauseCommand, group_layer_gain: GroupLayerGainCommand, graph_install: BusGraphCommand, graph_retire: BusGraphCommand, graph_targets: BusBatchCommand, group_bus_route: GroupBusRouteCommand, group_layer_automation: GroupLayerAutomationCommand, group_layer_automation_stop: GroupLayerAutomationStopCommand, graph_source_program: GraphSourceProgramCommand, graph_source_program_stop: GraphSourceProgramStopCommand, resident_capture: resident_transaction.Command, resident_restore: resident_transaction.Command };
pub const Scheduler = scheduler.Scheduler(ScheduledPayload);
pub const ScheduledCommand = Scheduler.Command;
pub const CancellationResult = struct { admission: scheduler.trace.Admission, receipt: scheduler.trace.ScheduleRecord };
pub const ScheduleResult = struct {
    disposition: music.PlanExecutionState,
    admission: ?scheduler.trace.Admission,
    cancellation: ?scheduler.trace.ScheduleRecord,
    receipts: [scheduler.commands_per_block]scheduler.trace.ScheduleRecord,
    count: u16,
};
const DeltaPayload = union(enum) {
    play: SnapshotVoice,
    update: struct { command: UpdateCommand, start_order: u64 },
    stop: struct { command: StopCommand, start_order: u64, group_reason: music_group.TerminalReason = .stopped },
    bus: BusCommand,
};
const RenderDelta = struct { sequence: u64, frame: u64, payload: DeltaPayload };

const QueueStage = enum { reserved, sequenced, published };
pub const IngressQueueStageForTesting = if (@import("builtin").is_test) QueueStage else void;
const QueueHook = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, QueueStage, Command) void,
};

const SequencedCommand = struct { sequence: u64, value: Command };

// A lane is a bounded unordered slot pool. Acceptance linearizes at the global
// fetchAdd AFTER a cell is claimed. Control searches for exactly its next ticket;
// a preempted producer therefore cannot hide an earlier ticket behind a FIFO head.
fn MpscRing(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Cell = struct {
            state: std.atomic.Value(u8) = .init(0), // free, claimed, published
            value: SequencedCommand = undefined,
        };
        cells: [capacity]Cell = [_]Cell{.{}} ** capacity,
        hint: std.atomic.Value(usize) = .init(0),
        occupied: std.atomic.Value(usize) = .init(0),
        test_hook: if (@import("builtin").is_test) ?QueueHook else void = if (@import("builtin").is_test) null else {},

        fn init() Self {
            return .{};
        }

        fn push(self: *Self, value: Command, counter: *std.atomic.Value(u64)) bool {
            const begin = self.hint.fetchAdd(1, .monotonic) % capacity;
            for (0..capacity) |offset| {
                const cell = &self.cells[(begin + offset) % capacity];
                if (cell.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) continue;
                _ = self.occupied.fetchAdd(1, .monotonic);
                self.hook(.reserved, value);
                cell.value = .{ .sequence = counter.fetchAdd(1, .monotonic), .value = value };
                self.hook(.sequenced, value);
                cell.state.store(2, .release);
                self.hook(.published, value);
                return true;
            }
            return false;
        }

        fn hook(self: *Self, stage: QueueStage, value: Command) void {
            if (@import("builtin").is_test) if (self.test_hook) |h| h.call(h.context, stage, value);
        }

        fn popSequence(self: *Self, expected: u64) ?SequencedCommand {
            for (&self.cells) |*cell| {
                if (cell.state.load(.acquire) != 2) continue;
                if (cell.value.sequence != expected) continue;
                const value = cell.value;
                _ = self.occupied.fetchSub(1, .monotonic);
                cell.state.store(0, .release);
                return value;
            }
            return null;
        }

        fn count(self: *const Self) usize {
            return self.occupied.load(.acquire);
        }
    };
}

const InstancePool = struct {
    const occupied: u32 = 1 << 31;
    const claiming: u32 = 1 << 30;
    next_identity: std.atomic.Value(u64) = .init(1),
    identities: [max_instances]std.atomic.Value(u64) = [_]std.atomic.Value(u64){.init(0)} ** max_instances,
    terminated: [max_instances]std.atomic.Value(u64) = [_]std.atomic.Value(u64){.init(0)} ** max_instances,
    slots: [max_instances]std.atomic.Value(u32) = init: {
        @setEvalBranchQuota(100_000);
        var values: [max_instances]std.atomic.Value(u32) = undefined;
        for (&values) |*value| value.* = std.atomic.Value(u32).init(0);
        break :init values;
    },

    fn reserve(self: *InstancePool) RuntimeError!InstanceHandle {
        for (&self.slots, 0..) |*slot, index| {
            const value = slot.load(.acquire);
            if (value & (occupied | claiming) != 0) continue;
            if (slot.cmpxchgStrong(value, claiming | value, .acq_rel, .acquire) != null) continue;
            var ticket = self.next_identity.load(.acquire);
            var reservation_id: ?u64 = null;
            for (0..8) |_| {
                if (ticket == 0 or ticket == std.math.maxInt(u64)) break;
                ticket = self.next_identity.cmpxchgStrong(ticket, ticket + 1, .acq_rel, .acquire) orelse {
                    reservation_id = ticket;
                    break;
                };
            }
            const id = reservation_id orelse {
                slot.store(value, .release);
                return error.InstanceCapacity;
            };
            const generation = nextGeneration(@truncate(value));
            self.identities[index].store(id, .release);
            slot.store(occupied | generation, .release);
            return .{ .index = @intCast(index), .generation = generation };
        }
        return error.InstanceCapacity;
    }

    fn identity(self: *const InstancePool, handle: InstanceHandle) RuntimeError!u64 {
        if (!self.current(handle)) return error.StaleInstance;
        const value = self.identities[handle.index].load(.acquire);
        if (!self.current(handle) or value == 0) return error.StaleInstance;
        return value;
    }
    fn matches(self: *const InstancePool, handle: InstanceHandle, value: u64) bool {
        return value != 0 and self.current(handle) and self.identities[handle.index].load(.acquire) == value;
    }

    fn terminate(self: *InstancePool, handle: InstanceHandle, reservation: u64) void {
        if (self.matches(handle, reservation)) self.terminated[handle.index].store(reservation, .release);
    }
    fn mayStart(self: *const InstancePool, handle: InstanceHandle, reservation: u64) bool {
        return self.matches(handle, reservation) and self.terminated[handle.index].load(.acquire) != reservation;
    }

    fn current(self: *const InstancePool, handle: InstanceHandle) bool {
        return self.currentObserved(handle, null);
    }
    fn currentObserved(self: *const InstancePool, handle: InstanceHandle, read: ?*readiness_witness.Reconciliation) bool {
        if (handle.index >= max_instances or handle.generation == 0) return false;
        const value = self.slots[handle.index].load(.acquire);
        if (read) |r| r.instance_state = value;
        return value == occupied | handle.generation;
    }

    fn release(self: *InstancePool, handle: InstanceHandle) void {
        self.releaseObserved(handle, null);
    }
    fn releaseObserved(self: *InstancePool, handle: InstanceHandle, read: ?*readiness_witness.Reconciliation) void {
        if (handle.index >= max_instances) return;
        const result = self.slots[handle.index].cmpxchgStrong(occupied | handle.generation, handle.generation, .acq_rel, .acquire);
        if (read) |r| {
            r.release_attempted = true;
            r.release_cas = result;
        }
    }

    fn liveCount(self: *const InstancePool) usize {
        var count: usize = 0;
        for (&self.slots) |*slot| count += @intFromBool(slot.load(.acquire) & occupied != 0);
        return count;
    }
};

const DesiredVoice = struct {
    custody: ?PlayToken = null,
    reservation: u64 = 0,
    active: bool = false,
    stopping: bool = false,
    instance: InstanceHandle = .{ .index = 0, .generation = 0 },
    owner: *SampleOwner = undefined,
    params: VoiceParams = .{},
    revision: u64 = 0,
    fade_frames: u32 = 0,
    start_order: u64 = 0,
    scheduled: bool = false,
    virtual_reserved: bool = false,
    start_order_known: bool = false,
};

pub const SnapshotVoice = struct {
    custody: ?PlayToken = null,
    reservation: u64 = 0,
    instance: InstanceHandle,
    owner: *SampleOwner,
    params: VoiceParams,
    revision: u64,
    stopping: bool,
    fade_frames: u32,
    start_order: u64 = 0,
};

pub const RenderSnapshot = struct {
    generation: u64 = 0,
    voices: [max_logical_voices]SnapshotVoice = undefined,
    voice_count: usize = 0,
    sfx_gain: f32 = 1,
    music_gain: f32 = 1,
    master_gain: f32 = 1,
    master_ramp_frames: u32 = 1,
    bus_revision: u64 = 0,
};

const SnapshotSlot = struct {
    pub const writing: u32 = 1 << 31;
    readers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    snapshot: RenderSnapshot = .{},
    // Plain fields belong solely to serialized Control, never readers/Render.
    credit_phase: enum { idle, acquiring, releasing } = .idle,
    generation_credits: [music.MusicRuntime.snapshot_credit_capacity]?music.MusicRuntime.SnapshotGenerationCredit = @splat(null),

    fn releaseOwners(self: *SnapshotSlot, runtime: *ControlRuntime) void {
        self.credit_phase = .releasing;
        for (self.snapshot.voices[0..self.snapshot.voice_count]) |voice| {
            releasePlayOwner(voice.owner, voice.custody);
            _ = runtime.counters.snapshot_pins.fetchSub(1, .monotonic);
        }
        self.snapshot.voice_count = 0;
        for (self.generation_credits) |credit| if (credit) |owned| {
            (runtime.music_runtime orelse unreachable).releaseSnapshotCredit(runtime, owned) catch unreachable;
        };
        self.credit_phase = .idle;
    }
};

pub const SnapshotLease = struct {
    runtime: *ControlRuntime,
    slot_index: u8,
    snapshot: *const RenderSnapshot,

    pub fn release(self: SnapshotLease) void {
        const previous = self.runtime.snapshots[self.slot_index].readers.fetchSub(1, .release);
        std.debug.assert(previous > 0);
    }
};

pub const CompletionReason = enum { finished, stopped, stolen, rejected };
pub const Completion = struct { instance: InstanceHandle, reason: CompletionReason };
const RenderCompletion = struct { instance: InstanceHandle, reason: CompletionReason, start_order: ?u64 = null };

fn SpscRing(comptime capacity: usize, comptime T: type) type {
    return struct {
        values: [capacity]T = undefined,
        write_position: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        read_position: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn push(self: *@This(), value: T) bool {
            return self.pushObserved(value, null, null, null);
        }
        fn pushObserved(self: *@This(), value: T, observed: ?*render_causal_witness.ResourceEvent, hooks: ?CausalReplayHooks, order: ?capture_order.Binding) bool {
            const write = self.write_position.load(.monotonic);
            if (order) |binding| binding.emitFor(.render, .runtime_completion_space, .before, null);
            if (hooks) |h| h.checkpoint(h.context, .{ .site = .completion_space, .edge = .before });
            const read = self.read_position.load(.acquire);
            if (order) |binding| binding.emitFor(.render, .runtime_completion_space, .after, read);
            if (hooks) |h| h.checkpoint(h.context, .{ .site = .completion_space, .edge = .after, .value = read });
            if (observed) |r| {
                r.queue_write = write;
                r.queue_read = read;
                r.queue_after = write;
            }
            if (write -% read == capacity) return false;
            self.values[write % capacity] = value;
            if (order) |binding| binding.emitFor(.render, .runtime_completion_enqueue, .before, write +% 1);
            if (hooks) |h| h.checkpoint(h.context, .{ .site = .completion_enqueue, .edge = .before, .value = write +% 1 });
            self.write_position.store(write +% 1, .release);
            if (order) |binding| binding.emitFor(.render, .runtime_completion_enqueue, .after, write +% 1);
            if (hooks) |h| h.checkpoint(h.context, .{ .site = .completion_enqueue, .edge = .after, .value = write +% 1 });
            if (observed) |r| r.queue_after = write +% 1;
            return true;
        }

        fn pop(self: *@This()) ?T {
            return self.popObserved(null, null, null);
        }
        fn popObserved(self: *@This(), observed: ?*readiness_witness.Reconciliation, hooks: ?CausalReplayHooks, order: ?capture_order.Binding) ?T {
            const read = self.read_position.load(.monotonic);
            if (order) |binding| binding.emitFor(.control, .runtime_completion_pop, .before, null);
            if (hooks) |h| h.checkpoint(h.context, .{ .site = .completion_pop, .edge = .before });
            const write = self.write_position.load(.acquire);
            if (order) |binding| binding.emitFor(.control, .runtime_completion_pop, .after, write);
            if (hooks) |h| h.checkpoint(h.context, .{ .site = .completion_pop, .edge = .after, .value = write });
            if (observed) |r| {
                r.read_position = read;
                r.write_position = write;
                r.cursor_after = read;
            }
            if (read == write) return null;
            const value = self.values[read % capacity];
            if (order) |binding| binding.emitFor(.control, .runtime_completion_return, .before, read +% 1);
            if (hooks) |h| h.checkpoint(h.context, .{ .site = .completion_return, .edge = .before, .value = read +% 1 });
            self.read_position.store(read +% 1, .release);
            if (order) |binding| binding.emitFor(.control, .runtime_completion_return, .after, read +% 1);
            if (hooks) |h| h.checkpoint(h.context, .{ .site = .completion_return, .edge = .after, .value = read +% 1 });
            if (observed) |r| {
                r.present = true;
                r.cursor_after = read +% 1;
            }
            return value;
        }

        fn peek(self: *@This()) ?T {
            const read = self.read_position.load(.monotonic);
            if (read == self.write_position.load(.acquire)) return null;
            return self.values[read % capacity];
        }

        fn count(self: *const @This()) usize {
            return self.write_position.load(.acquire) -% self.read_position.load(.acquire);
        }
    };
}

pub const RuntimeTelemetry = struct {
    accepted_commands: u64,
    rejected_commands: u64,
    queue_high_water: u32,
    live_instances: u32,
    snapshot_generation: u64,
    snapshot_pins: u32,
    render_pins: u32,
    completion_overflow: u64,
    stolen_instances: u64,
    snapshot_misses: u64 = 0,
    pin_misses: u64 = 0,
};

const RuntimeCounters = struct {
    accepted_commands: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_commands: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queue_high_water: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    snapshot_pins: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    render_pins: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    completion_overflow: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stolen_instances: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    snapshot_misses: std.atomic.Value(u64) = .init(0),
    pin_misses: std.atomic.Value(u64) = .init(0),
};

/// Test-only barrier stages for the two Control-side rate identity operations.
pub const VoiceBindingStage = enum { admission_claimed, renderer_claimed };
pub const VoiceBindingHook = struct { context: *anyopaque, call: *const fn (*anyopaque, VoiceBindingStage) void };

/// Test-only non-RT Control barriers. Never called from Render or an audio
/// callback. They run for the same admitted ticks with or without an observer.
pub const ControlFrontierStage = enum { after_collect, before_plan_horizon };
/// Separate early collection barrier keeps existing frontier hooks unchanged.
pub const ControlCollectionHook = struct { context: *anyopaque, call: *const fn (*anyopaque) void };
pub const ControlFrontierHook = struct { context: *anyopaque, call: *const fn (*anyopaque, ControlFrontierStage) void };
/// Installed exclusively by the bounded offline causal executor on its own
/// pristine owner. Never attached by live recording or a device callback.
pub const CausalReplaySite = enum { collection_frame, plan_phase, execution_receipt, schedule_admission, schedule_result, group_source_switch_read, schedule_release, terminal_scan, group_terminal_read, group_pin_read, group_pin_publish, group_pin_return, completion_space, completion_enqueue, completion_pop, completion_return, control_horizon, control_accept_frame, render_frame, group_desired_active, group_desired_start, group_desired_reservation, group_source_switch_final, control_collect_frame, render_commit_horizon, stream_stop_publish, readiness_outer_before, readiness_outer_after };
pub const CausalReplayPoint = struct { site: CausalReplaySite, edge: enum { before, after }, index: u64 = 0, generation: u64 = 0, value: u64 = 0 };
pub const CausalReplayHooks = struct { context: *anyopaque, checkpoint: *const fn (*anyopaque, CausalReplayPoint) void };

/// Exhaustive source-domain map. These codes are observation identifiers only;
/// neither this map nor any reserved code certifies full engine coverage.
fn captureOrderSite(site: CausalReplaySite) capture_order.Site {
    return switch (site) {
        .collection_frame => .runtime_collection_frame,
        .plan_phase => .runtime_plan_phase,
        .execution_receipt => .runtime_execution_receipt,
        .schedule_admission => .runtime_schedule_admission,
        .schedule_result => .runtime_schedule_result,
        .group_source_switch_read => .runtime_group_source_switch_read,
        .schedule_release => .runtime_schedule_release,
        .terminal_scan => .runtime_terminal_scan,
        .group_terminal_read => .runtime_group_terminal_read,
        .group_pin_read => .runtime_group_pin_read,
        .group_pin_publish => .runtime_group_pin_publish,
        .group_pin_return => .runtime_group_pin_return,
        .completion_space => .runtime_completion_space,
        .completion_enqueue => .runtime_completion_enqueue,
        .completion_pop => .runtime_completion_pop,
        .completion_return => .runtime_completion_return,
        .control_horizon => .runtime_control_horizon,
        .control_accept_frame => .runtime_control_accept_frame,
        .render_frame => .runtime_render_frame,
        .group_desired_active => .runtime_group_desired_active,
        .group_desired_start => .runtime_group_desired_start,
        .group_desired_reservation => .runtime_group_desired_reservation,
        .group_source_switch_final => .runtime_group_source_switch_final,
        .control_collect_frame => .runtime_control_collect_frame,
        .render_commit_horizon => .runtime_render_commit_horizon,
        .stream_stop_publish => .runtime_stream_stop_publish,
        .readiness_outer_before => .runtime_readiness_outer_before,
        .readiness_outer_after => .runtime_readiness_outer_after,
    };
}

fn captureOrderEdge(edge: @FieldType(CausalReplayPoint, "edge")) capture_order.Edge {
    return switch (edge) {
        .before => .before,
        .after => .after,
    };
}

/// The old offline point deliberately retains its u64/default-zero contract.
/// Absence in the new observer follows the actual site semantics, never value
/// equality: read-before has no observation, while an observed/stored zero is
/// present. group_pin_return's before value is the removed bit; its after value
/// is the actual fetchAnd result with that bit removed, not another atomic read.
fn captureOrderValue(point: CausalReplayPoint) ?u64 {
    return switch (point.site) {
        .collection_frame,
        .plan_phase,
        .execution_receipt,
        .schedule_admission,
        .schedule_result,
        .group_source_switch_read,
        .schedule_release,
        .terminal_scan,
        .group_terminal_read,
        .group_pin_read,
        .completion_space,
        .completion_pop,
        .control_horizon,
        .control_accept_frame,
        .group_desired_active,
        .group_desired_start,
        .group_desired_reservation,
        .group_source_switch_final,
        .control_collect_frame,
        .readiness_outer_before,
        .readiness_outer_after,
        => if (point.edge == .before) null else point.value,
        .group_pin_publish,
        .group_pin_return,
        .completion_enqueue,
        .completion_return,
        .render_frame,
        .render_commit_horizon,
        .stream_stop_publish,
        => point.value,
    };
}

/// Completion positions have no resource index/generation in the old point
/// contract. The explicit binding keeps the real producer role independent of
/// the ControlRuntime object which owns the completion storage.
fn completionOrderBinding(collector: ?*capture_order.RoleCollector) ?capture_order.Binding {
    return if (collector) |lane| .{ .collector = lane, .index = 0, .generation = 0 } else null;
}

pub const ControlRuntime = struct {
    pub const TickPhaseV1 = control_frontier_witness.Phase;
    const ControlFrontierBinding = struct {
        bridge: *control_frontier_witness.Bridge,
        session: control_frontier_witness.Session,
    };
    const StreamAcceptanceBinding = struct {
        bridge: *stream_acceptance_witness.Bridge,
        session: stream_acceptance_witness.Session,
    };
    const ReadinessBinding = struct {
        bridge: *readiness_witness.Bridge,
        session: readiness_witness.Session,
        renderer: *RuntimeRenderer,
        render_session: render_causal_witness.Session,
        frontier_session: control_frontier_witness.Session,
        acceptance_session: stream_acceptance_witness.Session,
        music_owner: *music.MusicRuntime,
        service: *streaming.Service,
    };
    const TickStateV1 = struct {
        active: std.atomic.Value(u64) = .init(0),
        thread: std.atomic.Value(std.Thread.Id) = .init(0),
        next: u64 = 1,
        frame: u64 = 0,
        phase: TickPhaseV1 = .idle,
        live_chronology: bool = false,
        live_acceptance_sink: ?LiveAcceptanceSinkV1 = null,
    };
    /// Immutable while attached; the host owns actual role/consumer quiescence
    /// and pinned lifetime. Defaults and old profiles never attach this observer.
    prerequisite_order: ?*capture_order.RoleCollector = null,
    /// Borrowed Render lane used only to bind retained terminal cells during
    /// Control preparation. Control never emits into this collector. Attachment
    /// and clearing require the same genuine role/consumer quiescence.
    prerequisite_terminal_order: ?*capture_order.RoleCollector = null,
    /// Immutable explicit Live semantic binding. Host owns genuine role exclusion.
    live_semantic_hooks: ?live_semantic.Binding = null,
    offline_causal_replay: ?CausalReplayHooks = null,
    public_causal_group_terminal_sink: ?music_group.TerminalPublicationSink = null,
    public_causal_group_source_final_sink: ?GroupSourceFinalSink = null,
    test_owned_control_facts: if (@import("builtin").is_test) ?TestOwnedControlFacts else void = if (@import("builtin").is_test) null else {},
    offline_causal_group_terminal: ?music_group.TerminalReplayHook = null,
    resident_transaction_slot: resident_transaction.Slot = .{},
    source_continuity_manager: ?*source_continuity.Manager = null,
    source_continuity_published: std.atomic.Value(?*source_continuity.Manager) = .init(null),
    graph_clock_manager: ?*graph_clock_runtime.Manager = null,
    graph_clock_manager_published: std.atomic.Value(?*graph_clock_runtime.Manager) = .init(null),
    layer_manager: ?*layer_runtime.Manager = null,
    layer_manager_published: std.atomic.Value(?*layer_runtime.Manager) = .init(null),
    /// Dedicated reserved lane: one outstanding exact-program stop per retained
    /// generation. Ordinary/emergency traffic cannot consume these credits.
    layer_stop_ingress: MpscRing(cleanup_ingress_capacity) = .{},
    bus_manager: ?*bus_runtime.Manager = null,
    /// Stable heap-backed storage; only the single RuntimeRenderer mutates it.
    /// Control must stay pinned and outlive that renderer. Initialization belongs
    /// only to the binding winner; Control never accesses DSP after binding.
    render_mixer: mixer.Mixer = undefined,
    renderer_sample_rate: std.atomic.Value(u32) = .init(0),
    voice_binding_active: std.atomic.Value(bool) = .init(false),
    voice_binding_test_hook: if (@import("builtin").is_test) ?VoiceBindingHook else void = if (@import("builtin").is_test) null else {},
    /// Exactly one public MusicRuntime is owned by this production context.
    music_runtime: ?*music.MusicRuntime = null,
    normal: MpscRing(normal_command_capacity) = MpscRing(normal_command_capacity).init(),
    reserved: MpscRing(reserved_command_capacity) = MpscRing(reserved_command_capacity).init(),
    next_sequence: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    next_control_sequence: u64 = 1,
    instances: InstancePool = .{},
    desired: [max_instances]DesiredVoice = [_]DesiredVoice{.{}} ** max_instances,
    active_count: usize = 0,
    accepting: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    shutdown_submitted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown_applied: bool = false,
    control_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    tick_v1: TickStateV1 = .{},
    // Serialized Control/lifecycle only. No Render-side pointer access.
    control_frontier_binding: ?ControlFrontierBinding = null,
    control_frontier_owner_identity: u64 = 0,
    stream_acceptance_binding: ?StreamAcceptanceBinding = null,
    stream_acceptance_owner_identity: u64 = 0,
    /// Host/Control lifecycle only; a closed Render observer still pins owners.
    render_causal_attached: bool = false,
    readiness_binding: ?ReadinessBinding = null,
    test_readiness_observation: if (@import("builtin").is_test) ?*streaming.stream.readiness_observation.QueryRead else void = if (@import("builtin").is_test) null else {},
    /// Passive actual-load test seam only; no production binding or value injection.
    test_live_readiness_checkpoint_hook: if (@import("builtin").is_test) ?CausalReplayHooks else void = if (@import("builtin").is_test) null else {},
    test_control_frontier_hook: if (@import("builtin").is_test) ?ControlFrontierHook else void = if (@import("builtin").is_test) null else {},
    /// Test-only workload pause after a completed real acceptance, never an output sink.
    test_after_live_acceptance: if (@import("builtin").is_test) ?TestAfterLiveAcceptance else void = if (@import("builtin").is_test) null else {},
    /// Passive test-only copy of the same initialized attempt. No result channel.
    test_live_acceptance_attempt: if (@import("builtin").is_test) ?TestLiveAcceptanceAttempt else void = if (@import("builtin").is_test) null else {},
    test_before_collection_hook: if (@import("builtin").is_test) ?ControlCollectionHook else void = if (@import("builtin").is_test) null else {},
    snapshots: [snapshot_count]SnapshotSlot = [_]SnapshotSlot{.{}} ** snapshot_count,
    published_slot: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    published_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    next_snapshot_generation: u64 = 1, // serialized Control; failed attempts never reuse IDs
    next_revision: u64 = 1,
    sfx_gain: f32 = 1,
    music_gain: f32 = 1,
    master_gain: f32 = 1,
    master_ramp_frames: u32 = 1,
    bus_revision: u64 = 1,
    render_completions: SpscRing(max_instances, RenderCompletion) = .{},
    reported_completions: SpscRing(max_instances, Completion) = .{},
    counters: RuntimeCounters = .{},
    scheduled: Scheduler = .{},
    prepared_groups: [music_group.max_groups]PreparedGroupSlot = @splat(.{}),
    next_group_generation: u64 = 1,
    deltas: SpscRing(scheduler.default_profile.immediate_capacity, RenderDelta) = .{},
    streaming_service: ?*streaming.Service = null,
    streaming_inputs: ?*StreamingInputRing = null,
    stream_faults: SpscRing(music_group.max_groups, StreamFault) = .{},
    stream_control_tick: u64 = 0,
    stream_input_order: u64 = 0,
    stream_input_overflow: u64 = 0,
    // Genuine accepted-fact failures, excluding optional host trace-ring loss.
    // The legacy aggregate above deliberately retains its old semantics.
    stream_input_evidence_failures: u64 = 0,
    stream_fault_overflow: std.atomic.Value(u64) = .init(0),
    voice_admission: ?virtual_voice.Admission = null,
    voice_context_id: u64 = 1,
    voice_input_order: u64 = 0,
    voice_event_observation_sequence: u64 = 0,
    music_observation_transport: std.atomic.Value(u64) = .init(1),
    music_observation_generation: std.atomic.Value(u64) = .init(1),
    layer_changes: [128]LayerChangeSlot = @splat(.{}),
    next_layer_change: u64 = 1,
    music_observation_sequence: std.atomic.Value(u64) = .init(0),
    music_observation_frame: std.atomic.Value(u64) = .init(0),
    music_observations: [music_group.max_groups]MusicObservationCell = @splat(.{}),
    voice_events: SpscRing(512, VoiceBudgetEvent) = .{},
    voice_event_overflow: u64 = 0,

    fn causalReplay(self: *const ControlRuntime, point: CausalReplayPoint) void {
        if (self.prerequisite_order) |order| order.pointFor(.control, captureOrderSite(point.site), captureOrderEdge(point.edge), point.index, point.generation, captureOrderValue(point));
        if (self.offline_causal_replay) |hooks| hooks.checkpoint(hooks.context, point);
        if (self.live_semantic_hooks) |hooks| {
            const cut: live_semantic.Point = .{ .role = .control, .site = captureOrderSite(point.site), .edge = captureOrderEdge(point.edge), .index = point.index, .generation = point.generation, .value = captureOrderValue(point) };
            if (live_semantic.allowedPoint(cut)) hooks.point(hooks.context, cut);
        }
    }
    /// Profile-8 only. Before is a valueless acquire endpoint; after carries
    /// the one actual load. The same Control lane and offline callback consume
    /// this exact point. Old Host/Live paths never gain new checkpoint tags.
    fn liveReadinessCheckpoint(self: *ControlRuntime, point: CausalReplayPoint) void {
        if (!self.tick_v1.live_chronology) return;
        self.causalReplay(point);
        if (@import("builtin").is_test) if (self.test_live_readiness_checkpoint_hook) |hook| hook.checkpoint(hook.context, point);
    }
    fn effectivePreparedSource(_: *ControlRuntime, slot: *PreparedGroupSlot, source_incarnation: u64) RuntimeError!*const music_group.Prepared {
        if (slot.source_switch.read()) |switched| {
            if (source_incarnation != 2 or switched.source_incarnation != source_incarnation) return error.UnsupportedLayerSource;
            return if (slot.emergency) |*emergency| emergency else error.InvalidState;
        }
        if (source_incarnation != 1) return error.UnsupportedLayerSource;
        return &slot.prepared;
    }
    pub fn layerProgramAnchor(self: *ControlRuntime, group: GroupHandle, frame: u64, context: u64, revision: u64, previous: ?layer_spans.ProgramHandle) RuntimeError!layer_spans.Anchor {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.layerProgramAnchorOwned(group, frame, context, revision, previous);
    }
    fn layerProgramAnchorOwned(self: *ControlRuntime, group: GroupHandle, frame: u64, context: u64, revision: u64, previous: ?layer_spans.ProgramHandle) RuntimeError!layer_spans.Anchor {
        return self.layerProgramAnchorForSourceOwned(group, 1, frame, context, revision, previous);
    }
    pub fn layerProgramAnchorForSource(self: *ControlRuntime, group: GroupHandle, source_incarnation: u64, frame: u64, context: u64, revision: u64, previous: ?layer_spans.ProgramHandle) RuntimeError!layer_spans.Anchor {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.layerProgramAnchorForSourceOwned(group, source_incarnation, frame, context, revision, previous);
    }
    fn layerProgramAnchorForSourceOwned(self: *ControlRuntime, group: GroupHandle, source_incarnation: u64, frame: u64, context: u64, revision: u64, previous: ?layer_spans.ProgramHandle) RuntimeError!layer_spans.Anchor {
        const slot = try self.preparedGroup(group);
        const effective = try self.effectivePreparedSource(slot, source_incarnation);
        const observed = try self.musicVoiceObservation(group);
        if (observed.source_incarnation != source_incarnation) return error.UnsupportedLayerSource;
        _ = try self.effectivePreparedSource(slot, source_incarnation);
        if (observed.state != .playing or observed.paused or frame < observed.frame or context == 0 or revision == 0) return error.InvalidState;
        const coordinate = try virtual_voice.predict(observed.cursor, observed.loop_epoch, effective.frames, if (observed.loop) |l| .{ .start = l.start, .end = l.end } else null, frame - observed.frame);
        return .{ .source_incarnation = source_incarnation, .context = context, .group = .{ .index = group.index, .generation = group.generation }, .bank_generation = observed.generation, .binding_revision = revision, .mutation_epoch = observed.mutation_epoch, .transport_epoch = observed.transport_epoch, .install_frame = frame, .cursor = coordinate.cursor, .loop_epoch = coordinate.loop_epoch, .source_frames = effective.frames, .sample_rate = effective.sample_rate, .channels = @intCast(effective.matrix.input.count), .loop = if (observed.loop) |l| .{ .start = l.start, .end = l.end } else null, .expected_previous = previous };
    }
    pub const LayerProgramRebase = struct {
        expected_previous: ?layer_spans.ProgramHandle = null,
        resume_group: bool = false,
        seek: ?u64 = null,
        loop_change: union(enum) { unchanged, clear, set: layer_spans.Loop } = .unchanged,
        next_transport_epoch: u64 = 0,
    };
    /// The caller must schedule matching group mutations followed by installation
    /// in one atomic phase. The anchor binds the post-transaction coordinate.
    pub fn layerProgramRebaseAnchor(self: *ControlRuntime, group: GroupHandle, frame: u64, context: u64, revision: u64, rebase: LayerProgramRebase) RuntimeError!layer_spans.Anchor {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.layerProgramRebaseAnchorOwned(group, frame, context, revision, rebase);
    }
    fn layerProgramRebaseAnchorOwned(self: *ControlRuntime, group: GroupHandle, frame: u64, context: u64, revision: u64, rebase: LayerProgramRebase) RuntimeError!layer_spans.Anchor {
        return self.layerProgramRebaseAnchorForSourceOwned(group, 1, frame, context, revision, rebase);
    }
    pub fn layerProgramRebaseAnchorForSource(self: *ControlRuntime, group: GroupHandle, source_incarnation: u64, frame: u64, context: u64, revision: u64, rebase: LayerProgramRebase) RuntimeError!layer_spans.Anchor {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.layerProgramRebaseAnchorForSourceOwned(group, source_incarnation, frame, context, revision, rebase);
    }
    fn layerProgramRebaseAnchorForSourceOwned(self: *ControlRuntime, group: GroupHandle, source_incarnation: u64, frame: u64, context: u64, revision: u64, rebase: LayerProgramRebase) RuntimeError!layer_spans.Anchor {
        const slot = try self.preparedGroup(group);
        const effective = try self.effectivePreparedSource(slot, source_incarnation);
        const observed = try self.musicVoiceObservation(group);
        if (observed.source_incarnation != source_incarnation) return error.UnsupportedLayerSource;
        _ = try self.effectivePreparedSource(slot, source_incarnation);
        if (observed.state != .playing or frame < observed.frame or context == 0 or revision == 0 or (observed.paused != rebase.resume_group)) return error.InvalidState;
        var mutation = observed.mutation_epoch;
        if (rebase.resume_group) mutation = std.math.add(u64, mutation, 1) catch return error.InvalidState;
        if (rebase.seek != null) mutation = std.math.add(u64, mutation, 1) catch return error.InvalidState;
        if (rebase.loop_change != .unchanged) mutation = std.math.add(u64, mutation, 1) catch return error.InvalidState;
        if (rebase.next_transport_epoch != 0 and (!rebase.resume_group or observed.transport_epoch == std.math.maxInt(u64) or rebase.next_transport_epoch != observed.transport_epoch + 1 or effective.hasStreams())) return error.InvalidState;
        const coordinate = try virtual_voice.predict(observed.cursor, observed.loop_epoch, effective.frames, if (observed.loop) |l| .{ .start = l.start, .end = l.end } else null, if (observed.paused) 0 else frame - observed.frame);
        const cursor = rebase.seek orelse coordinate.cursor;
        const loop: ?layer_spans.Loop = switch (rebase.loop_change) {
            .unchanged => if (observed.loop) |l| .{ .start = l.start, .end = l.end } else null,
            .clear => null,
            .set => |l| l,
        };
        if (cursor >= effective.frames or (loop != null and (loop.?.start >= loop.?.end or loop.?.end > effective.frames or cursor >= loop.?.end))) return error.InvalidArgument;
        if (effective.hasStreams() and (rebase.seek != null or rebase.loop_change != .unchanged)) return error.UnsupportedLayerSource;
        return .{ .source_incarnation = source_incarnation, .context = context, .group = .{ .index = group.index, .generation = group.generation }, .bank_generation = observed.generation, .binding_revision = revision, .mutation_epoch = mutation, .transport_epoch = if (rebase.next_transport_epoch == 0) observed.transport_epoch else rebase.next_transport_epoch, .install_frame = frame, .cursor = cursor, .loop_epoch = coordinate.loop_epoch, .source_frames = effective.frames, .sample_rate = effective.sample_rate, .channels = @intCast(effective.matrix.input.count), .loop = loop, .expected_previous = rebase.expected_previous };
    }
    pub fn prepareLayerProgramRebased(self: *ControlRuntime, allocator: std.mem.Allocator, desc: layer_spans.ProgramDesc, rebase: LayerProgramRebase) RuntimeError!layer_spans.ProgramHandle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareLayerProgramOwned(allocator, desc, rebase);
    }
    /// Deep-copy Control preparation. Gains never create a real voice or claim
    /// source readiness. Optional/virtual sources retain the genuine policy and
    /// realization path; admission consumes their conservative future gain bound.
    pub fn prepareLayerProgram(self: *ControlRuntime, allocator: std.mem.Allocator, desc: layer_spans.ProgramDesc) RuntimeError!layer_spans.ProgramHandle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareLayerProgramOwned(allocator, desc, null);
    }
    fn prepareLayerProgramOwned(self: *ControlRuntime, allocator: std.mem.Allocator, desc: layer_spans.ProgramDesc, rebase: ?LayerProgramRebase) RuntimeError!layer_spans.ProgramHandle {
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        try layer_spans.validate(desc);
        const anchor = desc.anchor;
        const group: GroupHandle = .{ .index = anchor.group.index, .generation = anchor.group.generation };
        const current = if (rebase) |r| try self.layerProgramRebaseAnchorForSourceOwned(group, anchor.source_incarnation, anchor.install_frame, anchor.context, anchor.binding_revision, r) else try self.layerProgramAnchorForSourceOwned(group, anchor.source_incarnation, anchor.install_frame, anchor.context, anchor.binding_revision, anchor.expected_previous);
        if (!std.meta.eql(current, anchor)) return error.InvalidLayerProgram;
        const prepared = try self.preparedGroup(group);
        const observed = try self.musicVoiceObservation(group);
        const effective = try self.effectivePreparedSource(prepared, anchor.source_incarnation);
        if (observed.source_incarnation != anchor.source_incarnation or observed.layer_count != effective.layer_count) return error.InvalidLayerProgram;
        for (desc.tracks) |track| {
            if (track.ordinal >= effective.layer_count) return error.InvalidLayerProgram;
            const layer = effective.layers[track.ordinal];
            if (layer.authored.layer_id != track.stable_layer_id) return error.InvalidLayerProgram;
            if (observed.layers[track.ordinal].state != .real and observed.layers[track.ordinal].state != .virtual) return error.UnsupportedLayerPolicy;
            if (observed.layers[track.ordinal].state == .virtual and self.voice_admission == null) return error.UnsupportedLayerPolicy;
        }
        // Include unexecuted raw writes, in either preparation order.
        for (&self.scheduled.slots) |*slot| {
            const state = slot.state.load(.acquire);
            if (state == .free or state == .terminal) continue;
            for (slot.block.commands[0..slot.block.count]) |command| if (command.payload == .group_layer_gain) {
                const raw = command.payload.group_layer_gain;
                if (raw.group.eql(group) and desc.target_mask & (@as(u16, 1) << @intCast(raw.layer)) != 0) return error.LayerProgramBusy;
            };
        }
        if (self.layer_manager == null) {
            self.layer_manager = try layer_runtime.Manager.create(allocator, @sizeOf(MpscRing(layer_spans.max_programs)) + music_group.max_groups * music_group.max_layers * (@sizeOf(?*layer_spans.RenderCursor) + @sizeOf(u64) + 6 * @sizeOf(std.atomic.Value(u64))) + @sizeOf(std.atomic.Value(?*layer_runtime.Manager)));
            self.layer_manager_published.store(self.layer_manager, .release);
        }
        try self.reserveLayerScheduleCapacity(0, 1);
        if (prepared.references == std.math.maxInt(u16)) return error.CommandQueueFull;
        const handle = try self.layer_manager.?.prepare(desc);
        prepared.references += 1; // Independent immutable group owner lease.
        return handle;
    }
    pub const LayerProgramUsage = struct { programs: usize, retained_tracks: usize, retained_spans: usize, metadata_bytes: usize, reserved_stop_credits: usize };
    /// Gain-program storage only, including its bounded bridge storage. This
    /// is not an aggregate PCM/stream/graph/whole-context admission claim.
    pub fn layerProgramUsage(self: *ControlRuntime) RuntimeError!LayerProgramUsage {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const manager = self.layer_manager orelse return .{ .programs = 0, .retained_tracks = 0, .retained_spans = 0, .metadata_bytes = 0, .reserved_stop_credits = 0 };
        var count: usize = 0;
        for (&manager.slots) |*slot| count += @intFromBool(slot.state.load(.acquire) != .free);
        return .{ .programs = count, .retained_tracks = manager.retained_tracks, .retained_spans = manager.retained_spans, .metadata_bytes = manager.retained_bytes, .reserved_stop_credits = manager.stopCredits() };
    }
    pub const LayerProgramObservation = struct { state: layer_runtime.State, program: layer_spans.ProgramHandle, content_hash: [32]u8, target_mask: u16, group: MusicGroupObservation };
    pub fn layerProgramObservation(self: *ControlRuntime, handle: layer_spans.ProgramHandle) RuntimeError!LayerProgramObservation {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.layerProgramObservationOwned(handle);
    }
    fn layerProgramObservationOwned(self: *ControlRuntime, handle: layer_spans.ProgramHandle) RuntimeError!LayerProgramObservation {
        const slot = try (self.layer_manager orelse return error.StaleLayerProgram).get(handle);
        const a = slot.desc.anchor;
        const observed = try self.musicVoiceObservation(.{ .index = a.group.index, .generation = a.group.generation });
        return .{ .state = slot.state.load(.acquire), .program = handle, .content_hash = slot.desc.content_hash, .target_mask = slot.desc.target_mask, .group = observed };
    }
    pub fn layerProgramResult(self: *ControlRuntime, handle: layer_spans.ProgramHandle) RuntimeError!?layer_runtime.Result {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.layerProgramResultOwned(handle);
    }
    fn layerProgramResultOwned(self: *ControlRuntime, handle: layer_spans.ProgramHandle) RuntimeError!?layer_runtime.Result {
        return (self.layer_manager orelse return error.StaleLayerProgram).observe(handle, self.scheduled.render_frame.load(.acquire));
    }
    pub fn releaseLayerProgram(self: *ControlRuntime, handle: layer_spans.ProgramHandle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.releaseLayerProgramOwned(handle);
    }
    fn releaseLayerProgramOwned(self: *ControlRuntime, handle: layer_spans.ProgramHandle) RuntimeError!void {
        const group = try (self.layer_manager orelse return error.StaleLayerProgram).release(handle, self.scheduled.render_frame.load(.acquire));
        self.prepared_groups[group.index].references -= 1;
    }
    /// Conservative capacity admission charges a potential new block, plan and
    /// fence independently. Retained completed install blocks still count.
    fn reserveLayerScheduleCapacity(self: *ControlRuntime, extra: usize, new_credits: usize) RuntimeError!void {
        const duck_credits = if (self.bus_manager) |manager| manager.ducks.stopCredits() else 0;
        if (self.layer_manager == null and self.graph_clock_manager == null and duck_credits == 0 and new_credits == 0) return;
        const credits = (if (self.layer_manager) |manager| manager.stopCredits() else 0) + (if (self.graph_clock_manager) |manager| manager.stopCredits() else 0) + duck_credits + new_credits;
        var blocks: usize = 0;
        var plans: usize = 0;
        var fences: usize = 0;
        for (&self.scheduled.slots) |*slot| blocks += @intFromBool(slot.state.load(.acquire) != .free);
        for (self.scheduled.plans) |plan| plans += @intFromBool(plan.active);
        for (self.scheduled.fences) |fence| fences += @intFromBool(fence.references != 0);
        if (blocks + credits + extra > scheduler.block_capacity or plans + credits + extra > scheduler.default_profile.plan_capacity or fences + credits + extra > scheduler.default_profile.epoch_fence_capacity) return error.LayerProgramBudgetExceeded;
    }
    fn exactLayerStop(commands: []const ScheduledCommand) ?layer_spans.ProgramHandle {
        if (commands.len != 1 or commands[0].payload != .group_layer_automation_stop) return null;
        return commands[0].payload.group_layer_automation_stop.program;
    }

    pub fn graphProgramAnchor(self: *ControlRuntime, group: GroupHandle, frame: u64, context: u64, revision: u64, rebase: ?LayerProgramRebase) RuntimeError!layer_spans.Anchor {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.graphProgramAnchorOwned(group, frame, context, revision, rebase);
    }
    fn graphProgramAnchorOwned(self: *ControlRuntime, group: GroupHandle, frame: u64, context: u64, revision: u64, rebase: ?LayerProgramRebase) RuntimeError!layer_spans.Anchor {
        if (rebase) |r| {
            if (r.expected_previous != null) return error.InvalidGraphProgram;
            return self.layerProgramRebaseAnchorOwned(group, frame, context, revision, r);
        }
        const prepared = try self.preparedGroup(group);
        const observed = try self.musicVoiceObservation(group);
        if (prepared.source_switch.read() != null) return error.UnsupportedGraphSourceHandoff;
        if (observed.state != .playing or frame < observed.frame or context == 0 or revision == 0) return error.InvalidState;
        const coordinate = try virtual_voice.predict(observed.cursor, observed.loop_epoch, prepared.prepared.frames, if (observed.loop) |l| .{ .start = l.start, .end = l.end } else null, if (observed.paused) 0 else frame - observed.frame);
        return .{ .context = context, .group = .{ .index = group.index, .generation = group.generation }, .bank_generation = observed.generation, .binding_revision = revision, .mutation_epoch = observed.mutation_epoch, .transport_epoch = observed.transport_epoch, .install_frame = frame, .cursor = coordinate.cursor, .loop_epoch = coordinate.loop_epoch, .source_frames = prepared.prepared.frames, .sample_rate = prepared.prepared.sample_rate, .channels = @intCast(prepared.prepared.matrix.input.count), .loop = if (observed.loop) |l| .{ .start = l.start, .end = l.end } else null };
    }
    pub const GraphProgramRequest = struct {
        graph: bus_runtime.Handle,
        group: GroupHandle,
        ordinal: u16,
        stable_layer_id: u64,
        anchor: layer_spans.Anchor,
        duration: graph_clock.contract.Duration,
        musical: ?graph_clock.clock.Map = null,
        targets: []const graph_clock.Write,
        previous: ?graph_clock.Handle = null,
        profile: graph_clock.Profile = .{},
        rebase: ?LayerProgramRebase = null,
    };
    pub fn prepareGraphSourceProgram(self: *ControlRuntime, allocator: std.mem.Allocator, request: GraphProgramRequest) RuntimeError!graph_clock.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        try request.profile.validate();
        const prepared = try self.preparedGroup(request.group);
        if (prepared.prepared.emergency != null) return error.InvalidLayerLane;
        if (request.ordinal >= prepared.prepared.layer_count or prepared.prepared.layers[request.ordinal].authored.layer_id != request.stable_layer_id) return error.InvalidGraphProgram;
        if (prepared.graph_source_replaced.load(.acquire) & (@as(u16, 1) << @intCast(request.ordinal)) != 0) return error.UnsupportedGraphSourceHandoff;
        const anchor = try self.graphProgramAnchorOwned(request.group, request.anchor.install_frame, request.anchor.context, request.anchor.binding_revision, request.rebase);
        if (!std.meta.eql(anchor, request.anchor)) return error.InvalidGraphProgram;
        const bus = self.bus_manager orelse return error.StaleGraph;
        try bus.validateGraphClockWrites(request.graph, layerGraphSource(request.group, request.ordinal), request.targets);
        const graph: graph_clock.GraphIdentity = .{ .context = request.graph.context, .index = request.graph.index, .generation = request.graph.generation };
        if (self.graph_clock_manager) |manager| try manager.validateReservation(graph, anchor.group, request.ordinal, request.targets, request.previous) else if (request.previous != null) return error.StaleGraphProgram;
        // Both preparation orders reject raw writers. Unreferenced batches may
        // exist, but their later scheduler admission repeats the conflict check.
        for (bus.batches) |maybe| if (maybe) |batch| {
            if (batch.references == 0 or !batch.graph.eql(request.graph)) continue;
            for (batch.operations[0..batch.count]) |op| if (op == .target) for (request.targets) |write| {
                if (bus_runtime.sameTarget(op.target.target, write.target)) return error.GraphProgramBusy;
            };
        };
        try self.reserveLayerScheduleCapacity(0, 1);
        if (prepared.references == std.math.maxInt(u16)) return error.CommandQueueFull;
        const graph_slot = try bus.get(request.graph);
        if (graph_slot.references == std.math.maxInt(u16)) return error.PreparedCapacity;
        if (self.graph_clock_manager == null) {
            const bridge = graph_source_tombstone_bytes + @sizeOf([graph_clock.max_programs]?mixer.GraphProgramBridge) + 2 * @sizeOf(?*graph_clock_runtime.Manager) + (@sizeOf(MpscRing(layer_spans.max_programs + graph_clock.max_programs)) - @sizeOf(MpscRing(layer_spans.max_programs)));
            self.graph_clock_manager = try graph_clock_runtime.Manager.create(allocator, bridge, request.profile);
            self.graph_clock_manager_published.store(self.graph_clock_manager, .release);
        }
        const manager = self.graph_clock_manager.?;
        var owned = try graph_clock.compile(allocator, graph, anchor, request.ordinal, request.stable_layer_id, request.duration, request.musical, request.targets, request.previous, request.profile, try manager.remainingProducerBytes(request.profile));
        defer owned.deinit();
        const physical_source = try self.currentGroupSource(prepared, request.ordinal);
        var source_binding: graph_clock_runtime.SourceBinding = .{};
        if (physical_source) |source| {
            const handle = (self.streaming_service orelse return error.InvalidState).handleForSource(source) catch return error.InvalidState;
            source_binding.handle = .{ .index = handle.index, .generation = handle.generation };
        }
        source_binding.hash = hashGraphSourceBinding(request.group, &prepared.prepared, request.ordinal, physical_source, source_binding);
        const handle = try manager.prepareSourceBound(owned.desc, source_binding);
        // Independent immutable source and graph leases cover pending, active,
        // terminal and predecessor references, beyond the scheduler block itself.
        prepared.references += 1;
        bus.retainGraph(request.graph) catch unreachable;
        return handle;
    }
    pub fn graphProgramUsage(self: *ControlRuntime) RuntimeError!?graph_clock_runtime.Usage {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return if (self.graph_clock_manager) |manager| manager.usage() else null;
    }
    pub fn graphProgramResult(self: *ControlRuntime, handle: graph_clock.Handle) RuntimeError!?graph_clock.Result {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return (self.graph_clock_manager orelse return error.StaleGraphProgram).observe(handle, self.scheduled.render_frame.load(.acquire));
    }
    pub fn releaseGraphSourceProgram(self: *ControlRuntime, handle: graph_clock.Handle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        try self.releaseGraphSourceProgramOwned(handle);
    }
    fn releaseGraphSourceProgramOwned(self: *ControlRuntime, handle: graph_clock.Handle) RuntimeError!void {
        const released = try (self.graph_clock_manager orelse return error.StaleGraphProgram).release(handle, self.scheduled.render_frame.load(.acquire));
        self.prepared_groups[released.group.index].references -= 1;
        self.bus_manager.?.releaseGraphReference(.{ .context = released.graph.context, .index = released.graph.index, .generation = released.graph.generation });
    }
    fn exactGraphStop(commands: []const ScheduledCommand) ?graph_clock.Handle {
        if (commands.len != 1 or commands[0].payload != .graph_source_program_stop) return null;
        return commands[0].payload.graph_source_program_stop.program;
    }
    fn graphRawConflict(self: *ControlRuntime, graph: bus_runtime.Handle, operations: []const bus_runtime.Operation) RuntimeError!void {
        const manager = self.graph_clock_manager orelse return;
        const identity: graph_clock.GraphIdentity = .{ .context = graph.context, .index = graph.index, .generation = graph.generation };
        for (operations) |op| if (op == .target and manager.conflicts(identity, op.target.target)) return error.GraphProgramBusy;
    }

    pub fn prepareBusGraph(self: *ControlRuntime, allocator: std.mem.Allocator, desc: bus_runtime.bg.BusGraphDesc, profile: bus_runtime.bg.Profile, adapters: bus_runtime.AdapterDesc) RuntimeError!bus_runtime.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareBusGraphOwned(allocator, desc, profile, adapters);
    }
    fn prepareBusGraphOwned(self: *ControlRuntime, allocator: std.mem.Allocator, desc: bus_runtime.bg.BusGraphDesc, profile: bus_runtime.bg.Profile, adapters: bus_runtime.AdapterDesc) RuntimeError!bus_runtime.Handle {
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        if (self.bus_manager == null) self.bus_manager = try bus_runtime.Manager.create(allocator);
        return self.bus_manager.?.prepareGraph(desc, profile, adapters);
    }
    pub fn prepareBusRoutes(self: *ControlRuntime, graph: bus_runtime.Handle, source: channel_layout.ChannelLayout, routes: []const bus_runtime.RouteDesc) RuntimeError!bus_runtime.RouteHandle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        return (self.bus_manager orelse return error.StaleGraph).prepareRoutes(graph, source, routes);
    }
    pub fn prepareBusTargetBatch(self: *ControlRuntime, graph: bus_runtime.Handle, operations: []const bus_runtime.Operation) RuntimeError!bus_runtime.BatchHandle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareBusTargetBatchOwned(graph, operations);
    }
    fn prepareBusTargetBatchOwned(self: *ControlRuntime, graph: bus_runtime.Handle, operations: []const bus_runtime.Operation) RuntimeError!bus_runtime.BatchHandle {
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        try self.graphRawConflict(graph, operations);
        return (self.bus_manager orelse return error.StaleGraph).prepareBatch(graph, operations);
    }
    /// Internal tracked preparation. Public request-ID reuse and ticket routing
    /// remain owned by the versioned music owner and are not enabled here.
    pub fn prepareTrackedDuck(self: *ControlRuntime, graph: bus_runtime.Handle, identity: duck_lifetime.Identity, target: bus_runtime.sc.DuckAutomationTarget) RuntimeError!bus_runtime.Manager.DuckLease {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareTrackedDuckOwned(graph, identity, target);
    }
    fn prepareTrackedDuckOwned(self: *ControlRuntime, graph: bus_runtime.Handle, identity: duck_lifetime.Identity, target: bus_runtime.sc.DuckAutomationTarget) RuntimeError!bus_runtime.Manager.DuckLease {
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        const manager = self.bus_manager orelse return error.StaleGraph;
        try self.reserveLayerScheduleCapacity(0, 1);
        return manager.prepareTrackedDuck(graph, identity, target);
    }
    pub fn consumeDuckTerminal(self: *ControlRuntime, handle: duck_lifetime.Handle) RuntimeError!?duck_lifetime.Terminal {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.consumeDuckTerminalOwned(handle);
    }
    fn consumeDuckTerminalOwned(self: *ControlRuntime, handle: duck_lifetime.Handle) RuntimeError!?duck_lifetime.Terminal {
        return (self.bus_manager orelse return error.StaleDuck).ducks.consume(handle, self.scheduled.render_frame.load(.acquire));
    }
    pub fn releaseTrackedDuck(self: *ControlRuntime, handle: duck_lifetime.Handle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.releaseTrackedDuckOwned(handle);
    }
    fn releaseTrackedDuckOwned(self: *ControlRuntime, handle: duck_lifetime.Handle) RuntimeError!void {
        try (self.bus_manager orelse return error.StaleDuck).releaseTrackedDuck(handle, self.scheduled.render_frame.load(.acquire));
    }
    fn trackedDuck(self: *ControlRuntime, payload: ScheduledPayload) RuntimeError!?bus_runtime.duck_runtime.Tracked {
        if (payload != .graph_targets) return null;
        return (try (self.bus_manager orelse return error.StaleBatch).batch(payload.graph_targets.batch)).tracked_duck;
    }
    fn exactDuckStop(self: *ControlRuntime, commands: []const ScheduledCommand) RuntimeError!bool {
        if (commands.len != 1) return false;
        const tracked = try self.trackedDuck(commands[0].payload) orelse return false;
        return tracked.kind == .end;
    }
    /// M3 source identity/ownership binding only. Graph ramps remain graph-frame
    /// clocks; this does not enable musical or paused-source-clock automation.
    pub fn prepareLayerGraphLane(self: *ControlRuntime, graph: bus_runtime.Handle, group: GroupHandle, layer: u16, bus: u32, targets: []const bus_runtime.bg.Target) RuntimeError!bus_runtime.LayerLane {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        const prepared = try self.preparedGroup(group);
        if (layer >= prepared.prepared.layer_count) return error.InvalidArgument;
        // M3 first slice owns one prepared logical layer. Emergency replacement
        // can change that layer during capture, after command preflight, and an
        // existing graph ramp would then affect fallback PCM. Until the real
        // replacement handoff exists, reject before claiming/allocating a lane.
        if (prepared.prepared.emergency != null) return error.InvalidLayerLane;
        const layout = prepared.prepared.matrix.input;
        return (self.bus_manager orelse return error.StaleGraph).prepareLayerLane(graph, layerGraphSource(group, layer), layout, bus, targets);
    }
    pub fn prepareLayerGraphTargetBatch(self: *ControlRuntime, graph: bus_runtime.Handle, group: GroupHandle, layer: u16, operations: []const bus_runtime.Operation) RuntimeError!BusBatchCommand {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        const prepared = try self.preparedGroup(group);
        if (layer >= prepared.prepared.layer_count) return error.InvalidArgument;
        try self.graphRawConflict(graph, operations);
        const batch = try (self.bus_manager orelse return error.StaleGraph).prepareLayerBatch(graph, layerGraphSource(group, layer), operations);
        return .{ .batch = batch, .group = group };
    }
    pub fn releaseBusGraph(self: *ControlRuntime, handle: bus_runtime.Handle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.releaseBusGraphOwned(handle);
    }
    fn releaseBusGraphOwned(self: *ControlRuntime, handle: bus_runtime.Handle) RuntimeError!void {
        try (self.bus_manager orelse return error.StaleGraph).releaseGraph(handle);
    }
    pub fn releaseBusRoutes(self: *ControlRuntime, handle: bus_runtime.RouteHandle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        try (self.bus_manager orelse return error.StaleRoute).releaseRoutes(handle);
    }
    pub fn releaseBusTargetBatch(self: *ControlRuntime, handle: bus_runtime.BatchHandle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.releaseBusTargetBatchOwned(handle);
    }
    fn releaseBusTargetBatchOwned(self: *ControlRuntime, handle: bus_runtime.BatchHandle) RuntimeError!void {
        try (self.bus_manager orelse return error.StaleBatch).releaseBatch(handle);
    }
    /// Component ledger only; no whole-context 32 MiB compliance claim.
    pub fn busResourceUsage(self: *ControlRuntime) RuntimeError!bus_runtime.Usage {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        var usage = if (self.bus_manager) |manager| manager.usage() else return .{};
        // Existing gain and graph ledgers charge 24 and 16 entries. This delta
        // is charged exactly once, independently of the number of duck slots.
        usage.retained_metadata_bytes += @sizeOf(MpscRing(cleanup_ingress_capacity)) - @sizeOf(MpscRing(layer_spans.max_programs + graph_clock.max_programs));
        return usage;
    }
    pub fn busObservation(self: *ControlRuntime, graph: bus_runtime.Handle, bus_id: u32) RuntimeError!bus_runtime.Observation {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return (self.bus_manager orelse return error.StaleGraph).observe(graph, bus_id);
    }
    fn retainBusPayload(self: *ControlRuntime, payload: ScheduledPayload) RuntimeError!void {
        switch (payload) {
            .graph_install, .graph_retire => |v| try self.bus_manager.?.retainGraph(v.graph),
            .graph_targets => |v| try self.bus_manager.?.retainBatch(v.batch),
            .group_bus_route => |v| try self.bus_manager.?.retainRoute(v.route),
            else => {},
        }
    }
    fn releaseBusPayload(self: *ControlRuntime, payload: ScheduledPayload) void {
        switch (payload) {
            .graph_install, .graph_retire => |v| self.bus_manager.?.releaseGraphReference(v.graph),
            .graph_targets => |v| self.bus_manager.?.releaseBatchReference(v.batch),
            .group_bus_route => |v| self.bus_manager.?.releaseRouteReference(v.route),
            else => {},
        }
    }
    pub fn init() ControlRuntime {
        return .{};
    }

    /// Preferred production construction: fixed storage lives at its final heap
    /// address and is initialized without a ControlRuntime-sized stack temporary.
    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*ControlRuntime {
        const self = try allocator.create(ControlRuntime);
        self.initInPlace();
        return self;
    }

    /// Host-exclusive, before any producer/callback can observe this storage.
    /// Queues, atomics, free slots and counters have zero as their initial bit
    /// representation; payload bytes are inaccessible until their release flag.
    pub fn initInPlace(self: *ControlRuntime) void {
        @memset(std.mem.asBytes(self), 0);
        self.tick_v1 = .{};
        self.next_sequence = .init(1);
        self.instances.next_identity = .init(1);
        self.next_control_sequence = 1;
        self.accepting = .init(true);
        self.next_snapshot_generation = 1;
        self.next_revision = 1;
        self.sfx_gain = 1;
        self.music_gain = 1;
        self.master_gain = 1;
        self.master_ramp_frames = 1;
        self.bus_revision = 1;
        self.scheduled.next_batch_id = 1;
        self.next_group_generation = 1;
        self.next_layer_change = 1;
        self.voice_admission = null;
        self.voice_context_id = 1;
        self.music_observation_transport = .init(1);
        self.music_observation_generation = .init(1);
        for (&self.scheduled.plans) |*plan| plan.readers = .init(@as(u32, 1) << 31);
        self.scheduled.transport_epoch = 1;
        self.scheduled.asset_generation = 1;
        for (&self.snapshots) |*slot| {
            slot.snapshot.sfx_gain = 1;
            slot.snapshot.music_gain = 1;
            slot.snapshot.master_gain = 1;
            slot.snapshot.master_ramp_frames = 1;
        }
        if (@import("builtin").is_test) {
            self.voice_binding_test_hook = null;
            self.normal.test_hook = null;
            self.reserved.test_hook = null;
            self.scheduled.test_hook = null;
        }
    }

    /// The successfully bound renderer's immutable output rate; null until its
    /// initialization is complete. Reading identity does not grant DSP access.
    pub fn rendererSampleRate(self: *const ControlRuntime) ?u32 {
        const rate = self.renderer_sample_rate.load(.acquire);
        return if (rate == 0) null else rate;
    }

    fn voiceBindingHook(self: *ControlRuntime, stage: VoiceBindingStage) void {
        if (@import("builtin").is_test) if (self.voice_binding_test_hook) |hook| hook.call(hook.context, stage);
    }

    /// Selection of both actual typed records. No key lookup or inferred authored
    /// settings; bank Platform wire stride is unchanged. Admission may race the
    /// fallible renderer constructor: one operation claims the binding guard,
    /// while the other returns ConcurrentControl without mutation for retry.
    pub fn admitVoiceCapacity(self: *ControlRuntime, platform: @import("sme-bank").schema.Platform, profile: ?virtual_voice.VoiceCapacityProfile) RuntimeError!void {
        return self.admitVoiceCapacityForContext(1, platform, profile);
    }
    pub fn admitVoiceCapacityForContext(self: *ControlRuntime, context: u64, platform: @import("sme-bank").schema.Platform, profile: ?virtual_voice.VoiceCapacityProfile) RuntimeError!void {
        if (context == 0) return error.InvalidArgument;
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (self.voice_binding_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.voice_binding_active.store(false, .release);
        self.voiceBindingHook(.admission_claimed);
        if (self.active_count != 0 or self.voice_admission != null) return error.InvalidState;
        const admission = try virtual_voice.admitWithPlatform(platform, profile);
        if (self.rendererSampleRate()) |rate| if (rate != admission.voice.sample_rate) return error.InvalidVoiceProfile;
        if (self.streaming_service) |service| if (service.profile.resident_limit_bytes != admission.voice.segment_resident_limit_bytes) return error.InvalidVoiceProfile;
        const previous_context = self.voice_context_id;
        self.voice_admission = admission;
        self.voice_context_id = context;
        errdefer {
            self.voice_admission = null;
            self.voice_context_id = previous_context;
        }
        if (self.streaming_service) |service| if (service.profile.allocation_budget_bytes > admission.voice.stream_budget_bytes) return self.voiceBudgetFailure(.stream_budget, service.profile.allocation_budget_bytes, admission.voice.stream_budget_bytes, 0, 0);
    }
    fn reservedRealCount(self: *const ControlRuntime) usize {
        var count: usize = 0;
        for (&self.desired) |*d| count += @intFromBool(d.active and !d.virtual_reserved);
        for (&self.prepared_groups) |*group| if (group.occupied and group.prepared.emergency_real_count != 0) {
            var active: usize = 0;
            var real: usize = 0;
            for (group.plays[0..group.prepared.voice_count]) |play| {
                const d = self.desired[play.instance.index];
                if (d.active and d.reservation == play.reservation) {
                    active += 1;
                    real += @intFromBool(!d.virtual_reserved);
                }
            }
            if (active != 0) count += group.prepared.emergency_real_count -| real;
        };
        for (&self.layer_changes) |*c| count += @intFromBool(c.occupied and c.real_reserved);
        return count;
    }
    fn reservedVirtualCount(self: *const ControlRuntime) usize {
        var count: usize = 0;
        for (&self.desired) |*d| count += @intFromBool(d.active and d.virtual_reserved);
        for (&self.layer_changes) |*c| count += @intFromBool(c.occupied and c.virtual_reserved);
        return count;
    }
    pub fn musicVoiceObservation(self: *const ControlRuntime, group: GroupHandle) RuntimeError!MusicGroupObservation {
        if (group.index >= self.music_observations.len) return error.InvalidArgument;
        const sequence = self.music_observation_sequence.load(.acquire);
        if (sequence & 1 != 0) return error.InvalidState;
        const frame = self.music_observation_frame.load(.acquire);
        const words = &self.music_observations[group.index].words;
        var raw: [19 + music_group.max_layers * 13]u64 = undefined;
        for (words, &raw) |*word, *value| value.* = word.load(.acquire);
        if (sequence != self.music_observation_sequence.load(.acquire) or frame != self.scheduled.render_frame.load(.acquire)) return error.InvalidState;
        if (raw[0] != group.generation or raw[8] > music_group.max_layers) return error.StaleInstance;
        var result: MusicGroupObservation = .{ .frame = frame, .group = group, .generation = raw[1], .mutation_epoch = raw[2], .transport_epoch = raw[12], .cursor = raw[3], .loop_epoch = raw[4], .paused = raw[5] != 0, .state = @enumFromInt(raw[6]), .gain = @bitCast(@as(u32, @truncate(raw[7]))), .bus_gain = @bitCast(@as(u32, @intCast(raw[7] >> 32))), .layer_count = @intCast(raw[8]), .loop = if (raw[9] != 0) .{ .start = raw[10], .end = raw[11] } else null, .virtualized = raw[13], .realized = raw[14], .dropped = raw[15], .stolen = raw[16], .graph_generation = raw[17], .source_incarnation = raw[18] };
        for (result.layers[0..result.layer_count], 0..) |*layer, i| {
            const at = 19 + i * 13;
            layer.* = .{ .state = @enumFromInt(raw[at]), .gain = @bitCast(@as(u32, @intCast(raw[at + 1]))), .stream_generation = raw[at + 2], .last_change_frame = raw[at + 3], .sample_reads = raw[at + 4], .route_bound = @bitCast(raw[at + 5]), .detector_dependency = raw[at + 6] != 0, .automation_generation = raw[at + 7], .automation_revision = raw[at + 8], .automation_elapsed = raw[at + 9], .automation_next_span = @intCast(raw[at + 10]), .automation_gain_upper_bound = @bitCast(@as(u32, @intCast(raw[at + 11]))), .automation_suspended = raw[at + 12] != 0 };
        }
        return result;
    }
    fn predictTicket(self: *ControlRuntime, group: GroupHandle, layer: u16, frame: u64) RuntimeError!virtual_voice.Ticket {
        const slot = try self.preparedGroup(group);
        if (slot.source_switch.read() != null) return error.UnsupportedLayerSource;
        const observed = try self.musicVoiceObservation(group);
        if (slot.source_switch.read() != null) return error.UnsupportedLayerSource;
        if (observed.state != .playing or observed.paused or layer >= observed.layer_count or frame < observed.frame) return error.InvalidState;
        const coordinate = try virtual_voice.predict(observed.cursor, observed.loop_epoch, slot.prepared.frames, if (observed.loop) |l| .{ .start = l.start, .end = l.end } else null, frame - observed.frame);
        return .{ .generation = observed.generation, .group = group.generation, .layer = slot.prepared.layers[layer].authored.layer_id, .mutation_epoch = observed.mutation_epoch, .transport_epoch = observed.transport_epoch, .cursor = coordinate.cursor, .loop_epoch = coordinate.loop_epoch, .realize_frame = frame };
    }
    /// Creates a fresh real streaming generation at a predicted musical
    /// coordinate. The virtual source is never reset or decoded to catch up.
    pub fn beginMusicRealize(self: *ControlRuntime, group: GroupHandle, layer: u16, asset: *streaming.Asset) (RuntimeError || streaming.stream.Error)!Realization {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const admission = self.voice_admission orelse return error.InvalidVoiceProfile;
        const slot = try self.preparedGroup(group);
        const service = self.streaming_service orelse return error.InvalidState;
        const observation = try self.musicVoiceObservation(group);
        if (slot.source_switch.read() != null) return error.UnsupportedLayerSource;
        if (layer >= slot.prepared.layer_count or observation.layers[layer].state != .virtual) return error.InvalidState;
        const old = (try self.currentGroupSource(slot, layer)) orelse return error.InvalidArgument;
        if (old.identity.asset != asset.sound.key.id or old.identity.frame_count != asset.sound.frames or old.identity.channels != asset.info.channels or !std.mem.eql(u8, &old.identity.encoded_hash, &asset.sound.audio_hash)) return error.InvalidArgument;
        const frame = @max(try self.earliestPlanFrame(), std.math.add(u64, observation.frame, admission.voice.realize_lead_frames) catch return error.InvalidArgument);
        const ticket = try self.predictTicket(group, layer, frame);
        const handle = try service.open(asset, .{ .generation = ticket.generation, .transport_epoch = ticket.transport_epoch, .group = ticket.group, .layer = ticket.layer, .start_cursor = try slot.prepared.layers[layer].assetFrame(ticket.cursor), .loop_epoch = ticket.loop_epoch, .loop = try slot.prepared.layers[layer].assetLoop(observation.loop), .priority = .virtual_soon_realize, .deadline_frame = frame, .operation = .seek });
        return .{ .group = group, .layer = layer, .ticket = ticket, .stream = handle };
    }
    pub const RepreparedRealization = struct { next: Realization, retired: streaming.Handle };
    /// Re-predict after a late or epoch-invalid completion. Old ownership is
    /// explicitly returned for worker/publication drain, never reset in place.
    pub fn reprepareMusicRealize(self: *ControlRuntime, previous: Realization, asset: *streaming.Asset) (RuntimeError || streaming.stream.Error)!RepreparedRealization {
        _ = try self.cancelMusicRealize(previous, null);
        return .{ .next = try self.beginMusicRealize(previous.group, previous.layer, asset), .retired = previous.stream };
    }
    /// A late/mutated/cancelled preparation stays virtual. Caller cancels and
    /// drains this generation, then calls beginMusicRealize for a fresh ticket.
    pub fn prepareMusicRealize(self: *ControlRuntime, realization: Realization, context: u64, control_epoch: u64) (RuntimeError || streaming.stream.Error)!LayerChangeHandle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const supply = self.streaming_service orelse return error.InvalidState;
        if (!try supply.canPrepareRealize(realization.stream)) {
            self.recordVoiceDeferral(realization.group, realization.ticket.layer, .unrealizable);
            return error.InvalidState;
        }
        const input = try self.streamReadinessOwned(realization.stream, context, control_epoch);
        if (!input.payload.readiness_snapshot.expected.ready) {
            self.recordVoiceDeferral(realization.group, realization.ticket.layer, .unrealizable);
            return error.TargetNotResident;
        }
        const service = self.streaming_service orelse return error.InvalidState;
        return self.prepareMusicLayerChangeOwned(realization.group, .{ .layer = realization.layer, .ticket = realization.ticket, .target = .real, .source = try service.renderSource(realization.stream) });
    }
    /// The caller supplies the actual realization schedule block when it was
    /// published. Existing scheduler receipts establish effective vs too late;
    /// low-level Service.cancel alone only stops future supply.
    pub fn cancelMusicRealize(self: *ControlRuntime, realization: Realization, block: ?scheduler.Handle) (RuntimeError || streaming.stream.Error)!?scheduler.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const service = self.streaming_service orelse return error.InvalidState;
        const opening = try service.openOptions(realization.stream);
        const t = realization.ticket;
        const group_slot = try self.preparedGroup(realization.group);
        if (realization.layer >= group_slot.prepared.layer_count) return error.InvalidArgument;
        const asset_cursor = try group_slot.prepared.layers[realization.layer].assetFrame(t.cursor);
        if (opening.generation != t.generation or opening.transport_epoch != t.transport_epoch or opening.group != t.group or opening.layer != t.layer or opening.start_cursor != asset_cursor or opening.loop_epoch != t.loop_epoch or opening.deadline_frame != t.realize_frame or t.group != realization.group.generation) return error.InvalidArgument;
        if (block) |handle| {
            const scheduled = try self.scheduled.getObserved(handle, null);
            var found = false;
            for (scheduled.block.commands[0..scheduled.block.count]) |command| if (command.payload == .group_layer) {
                const edit = try self.layerChange(command.payload.group_layer.change);
                if (edit.group.eql(realization.group) and std.meta.eql(edit.change.ticket, realization.ticket) and edit.change.source != null and edit.change.source.?.ring == try service.ringFor(realization.stream) and edit.change.source.?.identity.stream_generation == realization.stream.generation) found = true;
            };
            if (!found) return error.InvalidArgument;
            // Queue the canonical invalidation before stopping future supply.
            const invalidation = try self.cancelScheduleOwned(.{ .target = handle, .requested_frame = self.scheduled.render_frame.load(.acquire) });
            try service.cancel(realization.stream);
            return invalidation;
        }
        // An unscheduled ticket can be revoked locally; no Render owner sees it.
        for (&self.layer_changes) |*edit| if (edit.occupied and edit.group.eql(realization.group) and std.meta.eql(edit.change.ticket, realization.ticket) and edit.change.source != null and edit.change.source.?.ring == try service.ringFor(realization.stream) and edit.change.source.?.identity.stream_generation == realization.stream.generation) {
            if (edit.scheduled) return error.InvalidState;
            self.discardLayerChangeOwned(edit);
        };
        try service.cancel(realization.stream);
        return null;
    }
    pub fn prepareMusicLayerState(self: *ControlRuntime, group: GroupHandle, layer: u16, target: virtual_voice.State, frame: u64) RuntimeError!LayerChangeHandle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const ticket = try self.predictTicket(group, layer, frame);
        const admission = self.voice_admission orelse return error.InvalidVoiceProfile;
        return self.prepareMusicLayerChangeOwned(group, .{ .layer = layer, .ticket = ticket, .target = target, .release_frames = if (target == .real) 0 else admission.voice.release_frames });
    }
    pub fn prepareMusicLayerChange(self: *ControlRuntime, group: GroupHandle, change: music_group.LayerChange) RuntimeError!LayerChangeHandle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareMusicLayerChangeOwned(group, change);
    }
    fn prepareMusicLayerChangeOwned(self: *ControlRuntime, group: GroupHandle, change: music_group.LayerChange) RuntimeError!LayerChangeHandle {
        const admission = self.voice_admission orelse return error.InvalidVoiceProfile;
        const slot = try self.preparedGroup(group);
        const observed = try self.musicVoiceObservation(group);
        if (change.layer >= slot.prepared.layer_count or change.target == .releasing or change.release_frames > admission.voice.minimum_hold_frames) return error.InvalidState;
        if (change.ticket.realize_frame <= self.scheduled.commit_horizon.load(.acquire)) {
            self.recordVoiceDeferral(group, change.ticket.layer, .late_prepare);
            return error.InvalidState;
        }
        const predicted = try self.predictTicket(group, change.layer, change.ticket.realize_frame);
        if (!std.meta.eql(predicted, change.ticket)) {
            self.recordVoiceDeferral(group, change.ticket.layer, .stale_ticket);
            return error.InvalidState;
        }
        const layer = slot.prepared.layers[change.layer];
        const state = observed.layers[change.layer];
        if (state.state == .stolen or state.state == .releasing or state.state == change.target or change.ticket.realize_frame - state.last_change_frame < admission.voice.minimum_hold_frames) return error.InvalidState;
        if (change.target != .real and (layer.required or layer.authored.protection != .optional or state.detector_dependency)) return self.voiceBudgetFailure(.required_minimum, 1, 0, group.generation, change.ticket.layer);
        for (&self.layer_changes) |*pending| if (pending.occupied and pending.group.eql(group) and pending.change.layer == change.layer and !pending.settled) return error.InvalidState;
        if (change.target == .real) {
            if (self.reservedRealCount() >= admission.voice.max_real_voices) return self.voiceBudgetFailure(.real_capacity, self.reservedRealCount() + 1, admission.voice.max_real_voices, group.generation, change.ticket.layer);
            if (try self.currentGroupSource(slot, change.layer)) |old| {
                const source = change.source orelse return error.TargetNotResident;
                const service = self.streaming_service orelse return error.InvalidState;
                const stream_handle = service.handleForSource(source) catch return error.InvalidState;
                if (!(service.canPrepareRealize(stream_handle) catch return error.InvalidState)) return error.InvalidState;
                const readiness = try self.streamReadinessOwned(stream_handle, change.ticket.group, change.ticket.mutation_epoch);
                if (!readiness.payload.readiness_snapshot.expected.ready) {
                    self.recordVoiceDeferral(group, change.ticket.layer, .unrealizable);
                    return error.TargetNotResident;
                }
                if (!source.validate() or source.identity.stream_generation == old.identity.stream_generation or source.identity.asset != old.identity.asset or source.identity.asset_generation != predicted.generation or source.identity.start_cursor != (try layer.assetFrame(predicted.cursor)) or source.identity.start_loop_epoch != predicted.loop_epoch or source.identity.transport_epoch != predicted.transport_epoch or source.identity.frame_count != layer.asset_frames or source.identity.channels != slot.prepared.matrix.input.count or !std.mem.eql(u8, &source.identity.encoded_hash, &old.identity.encoded_hash) or !std.meta.eql(source.identity.loop, old.identity.loop)) return error.InvalidState;
            } else if (change.source != null) return error.InvalidArgument;
        } else {
            if (change.source != null) return error.InvalidArgument;
            if (change.target == .virtual and self.reservedVirtualCount() >= admission.voice.max_virtual_voices) return self.voiceBudgetFailure(.virtual_capacity, self.reservedVirtualCount() + 1, admission.voice.max_virtual_voices, group.generation, change.ticket.layer);
        }
        const index = for (&self.layer_changes, 0..) |*pending, i| {
            if (!pending.occupied) break i;
        } else return error.CommandQueueFull;
        if (self.next_layer_change == std.math.maxInt(u64)) return error.InvalidState;
        if (change.source) |source| try source.retain();
        const generation = self.next_layer_change;
        self.next_layer_change += 1;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(&admission.hash);
        inline for (@typeInfo(virtual_voice.Ticket).@"struct".fields) |field| hashInt(&hash, @field(change.ticket, field.name));
        hashInt(&hash, change.layer);
        hashInt(&hash, @intFromEnum(change.target));
        hashInt(&hash, change.release_frames);
        if (change.source) |source| {
            hashInt(&hash, source.identity.stream_generation);
            hash.update(&source.identity.profile_hash);
            hash.update(&source.identity.encoded_hash);
        }
        self.layer_changes[index] = .{ .occupied = true, .generation = generation, .group = group, .change = change, .from_state = state.state, .real_reserved = change.target == .real, .virtual_reserved = change.target == .virtual, .content_hash = hash.finalResult() };
        return .{ .index = @intCast(index), .generation = generation };
    }
    fn layerChange(self: *ControlRuntime, handle: LayerChangeHandle) RuntimeError!*LayerChangeSlot {
        if (handle.index >= self.layer_changes.len) return error.InvalidArgument;
        const slot = &self.layer_changes[handle.index];
        if (!slot.occupied or slot.generation != handle.generation) return error.StaleInstance;
        return slot;
    }
    pub fn discardMusicLayerChange(self: *ControlRuntime, handle: LayerChangeHandle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const change = try self.layerChange(handle);
        if (change.scheduled or change.references != 0) return error.DrainPending;
        self.discardLayerChangeOwned(change);
    }
    fn discardLayerChangeOwned(_: *ControlRuntime, change: *LayerChangeSlot) void {
        if (change.change.source) |source| {
            source.ring.stopped.store(true, .release);
            source.release();
        }
        change.* = .{};
    }
    fn reconcileLayerChanges(self: *ControlRuntime) void {
        for (&self.layer_changes) |*change| {
            if (!change.occupied or !change.settled) continue;
            const group_slot = self.preparedGroup(change.group) catch continue;
            const observation = self.musicVoiceObservation(change.group) catch continue;
            if (group_slot.source_switch.read()) |switched| {
                if (observation.frame <= switched.frame) continue;
                change.real_reserved = false;
                change.virtual_reserved = false;
                if (change.references == 0) self.discardLayerChangeOwned(change);
                continue;
            }
            const layer = observation.layers[change.change.layer];
            // A receipt is published at claim, before DSP completes. An older
            // completed observation cannot prove the newly leased source is
            // unused. Retain both reservation and lease through that frontier.
            if (change.succeeded and observation.frame <= change.change.ticket.realize_frame) continue;
            if (change.succeeded) {
                const desired = &self.desired[group_slot.plays[change.change.layer].instance.index];
                if (desired.active and desired.reservation == group_slot.plays[change.change.layer].reservation) desired.virtual_reserved = layer.state == .virtual;
            }
            change.real_reserved = false;
            if (!change.succeeded or layer.state != .releasing) change.virtual_reserved = false;
            const transition_pending = change.succeeded and layer.state == .releasing;
            const in_use = change.succeeded and observation.state != .finished and change.change.source != null and layer.stream_generation == change.change.source.?.identity.stream_generation and layer.state != .virtual and layer.state != .stolen;
            if (change.references == 0 and !in_use and !transition_pending) self.discardLayerChangeOwned(change);
        }
    }
    fn layerFutureGain(self: *ControlRuntime, group: GroupHandle, ordinal: usize, frame: u64, current: f32) f32 {
        var upper = current;
        const manager = self.layer_manager orelse return upper;
        for (&manager.slots) |*slot| {
            const state = slot.state.load(.acquire);
            if (state == .free) continue;
            const a = slot.desc.anchor;
            if (a.group.index != group.index or a.group.generation != group.generation) continue;
            if (state == .terminal and slot.result.release_frontier <= frame) continue;
            for (slot.desc.tracks) |track| if (track.ordinal == ordinal) {
                upper = @max(upper, @max(track.initial_prediction, track.final_target));
                if (track.spans.count != 0) upper = @max(upper, slot.desc.spans[track.spans.first].remaining_max);
            };
        }
        return upper;
    }
    /// Control compiles one deterministic ranking over all currently playing
    /// groups. Audibility comes from actual completed gain automation and a
    /// validated authored peak envelope, never virtual sample DSP.
    pub fn planMusicVoiceBudget(self: *ControlRuntime) RuntimeError!virtual_voice.Plan {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const admission = self.voice_admission orelse return error.InvalidVoiceProfile;
        var candidates: [virtual_voice.max_logical]virtual_voice.Candidate = undefined;
        var count: usize = 0;
        var music_real: usize = 0;
        const frame = self.scheduled.render_frame.load(.acquire);
        for (&self.prepared_groups, 0..) |*slot, group_index| {
            if (!slot.occupied or !slot.start_scheduled or slot.source_switch.read() != null) continue;
            const observed = self.musicVoiceObservation(.{ .index = @intCast(group_index), .generation = slot.generation }) catch |err| {
                if (err == error.StaleInstance) continue;
                return err;
            };
            if (observed.state != .playing or slot.source_switch.read() != null) continue;
            for (observed.layers[0..observed.layer_count], slot.prepared.layers[0..observed.layer_count], 0..) |layer, authored, i| {
                if (layer.state == .stolen) continue;
                if (count == candidates.len) return error.VoiceBudgetExceeded;
                const future_gain = self.layerFutureGain(.{ .index = @intCast(group_index), .generation = slot.generation }, i, observed.frame, layer.gain);
                const metric = if (observed.graph_generation != 0)
                    try bus_runtime.sampleComposed(&slot.audibility[i], admission.voice, frame, future_gain, observed.gain, observed.bus_gain, authored.audibility_envelope, layer.route_bound)
                else
                    try slot.audibility[i].sample(admission.voice, frame, future_gain, observed.gain, observed.bus_gain, authored.audibility_envelope);
                candidates[count] = .{ .authored = authored.authored, .instance_id = slot.generation, .state = layer.state, .audibility_q24 = metric, .last_change_frame = layer.last_change_frame, .required = authored.required or layer.detector_dependency };
                music_real += @intFromBool(layer.state == .real or layer.state == .releasing);
                count += 1;
            }
        }
        const occupied_other = self.reservedRealCount() -| music_real;
        const plan = try virtual_voice.plan(admission.voice, frame, candidates[0..count], @intCast(occupied_other));
        if (plan.failure) |failure| {
            std.debug.assert(self.voiceBudgetFailure(failure.reason, failure.required, failure.available, 0, 0) == error.VoiceBudgetExceeded);
        } else for (plan.decisions[0..plan.count]) |decision| {
            const candidate = for (candidates[0..count]) |c| {
                if (c.authored.layer_id == decision.layer_id and c.instance_id == decision.instance_id) break c;
            } else unreachable;
            var event = self.voiceEvent(decision.instance_id, decision.layer_id);
            event.from_state = @enumFromInt(@intFromEnum(decision.from));
            event.to_state = @enumFromInt(@intFromEnum(decision.to));
            event.reason = @enumFromInt(@intFromEnum(decision.reason));
            event.protection = @enumFromInt(@intFromEnum(candidate.authored.protection));
            event.authored_priority = candidate.authored.priority;
            event.drop_rank = candidate.authored.drop_rank;
            event.audibility_q24 = candidate.audibility_q24;
            event.required = decision.required;
            event.available = decision.available;
            self.recordVoiceEvent(event);
        }
        return plan;
    }
    fn voiceEvent(self: *ControlRuntime, group: u64, layer: u64) VoiceBudgetEvent {
        const admission = self.voice_admission.?;
        self.voice_event_observation_sequence = self.music_observation_sequence.load(.acquire);
        const frame = self.scheduled.render_frame.load(.acquire);
        return .{ .context = self.voice_context_id, .transport_epoch = self.music_observation_transport.load(.acquire), .asset_generation = self.music_observation_generation.load(.acquire), .frame = frame, .accepted_control_frame = frame, .control_tick = self.stream_control_tick, .input_order = self.voice_input_order, .profile = admission.voice.id, .profile_hash = admission.hash, .group = group, .layer = layer, .from_state = .real, .to_state = .real, .protection = .optional, .authored_priority = 0, .audibility_q24 = 0, .drop_rank = 0, .reason = .none, .required = 0, .available = 0 };
    }
    fn recordVoiceEvent(self: *ControlRuntime, event: VoiceBudgetEvent) void {
        self.voice_input_order +|= 1;
        if (self.voice_event_observation_sequence & 1 != 0 or self.voice_event_observation_sequence != self.music_observation_sequence.load(.acquire) or event.accepted_control_frame != self.music_observation_frame.load(.acquire) or event.accepted_control_frame != self.scheduled.render_frame.load(.acquire)) {
            self.voice_event_overflow +|= 1;
            return;
        }
        event.validate() catch {
            self.voice_event_overflow +|= 1;
            return;
        };
        if (!self.voice_events.push(event)) self.voice_event_overflow +|= 1;
    }
    fn recordVoiceDeferral(self: *ControlRuntime, group: GroupHandle, layer: u64, reason: virtual_voice.Reason) void {
        if (self.voice_admission == null or layer == 0) return;
        var event = self.voiceEvent(group.generation, layer);
        event.from_state = .virtual;
        event.to_state = .virtual;
        event.reason = @enumFromInt(@intFromEnum(reason));
        self.recordVoiceEvent(event);
    }
    fn voiceBudgetFailure(self: *ControlRuntime, reason: virtual_voice.Reason, required: u64, available: u64, group: u64, layer: u64) RuntimeError {
        if (self.voice_admission != null) {
            var event = self.voiceEvent(group, layer);
            event.reason = @enumFromInt(@intFromEnum(reason));
            event.required = required;
            event.available = available;
            self.recordVoiceEvent(event);
        }
        return error.VoiceBudgetExceeded;
    }
    pub fn requireVoiceTraceComplete(self: *const ControlRuntime) error{IncompleteTrace}!void {
        if (self.voice_admission == null or self.voice_event_overflow != 0) return error.IncompleteTrace;
    }
    pub fn pollVoiceBudgetEntry(self: *ControlRuntime) ?music.trace.ScheduleEntry {
        return if (self.voice_events.pop()) |event| .{ .voice_budget = event } else null;
    }
    pub fn pollVoiceBudgetEvent(self: *ControlRuntime) ?VoiceBudgetEvent {
        return self.voice_events.pop();
    }

    /// Attach a caller-owned bounded service before its worker/render users run.
    /// Control owns acceptance; the worker can only stage completions.
    pub fn attachStreaming(self: *ControlRuntime, service: *streaming.Service, inputs: ?*StreamingInputRing) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.attachStreamingOwned(service, inputs);
    }
    fn attachStreamingOwned(self: *ControlRuntime, service: *streaming.Service, inputs: ?*StreamingInputRing) RuntimeError!void {
        if (self.streaming_service != null or !self.accepting.load(.acquire)) return error.InvalidState;
        if (self.voice_admission) |admission| if (service.profile.allocation_budget_bytes > admission.voice.stream_budget_bytes) return self.voiceBudgetFailure(.stream_budget, service.profile.allocation_budget_bytes, admission.voice.stream_budget_bytes, 0, 0) else if (service.profile.resident_limit_bytes != admission.voice.segment_resident_limit_bytes) return error.InvalidVoiceProfile;
        service.attachRuntime() catch return error.InvalidState;
        self.streaming_service = service;
        service.initial_entry_owner = .{ .context = self, .validate = validateInitialEntryOwner };
        self.streaming_inputs = inputs;
    }
    fn validateInitialEntryOwner(raw: *anyopaque, service: *streaming.Service, serial: u64, request_id: u64, handle: streaming.Handle) streaming.stream.Error!streaming.stream.InitialEntryContextV1 {
        const control: *ControlRuntime = @ptrCast(@alignCast(raw));
        const tick: TickV1 = .{ .runtime = control, .serial = serial };
        tick.validateInitialEntryServiceV1(service, request_id, handle) catch return error.InvalidState;
        const owner = control.music_runtime.?;
        return .{ .position = .{ .accepted_control_frame = control.tick_v1.frame, .control_tick = control.stream_control_tick, .input_order = control.stream_input_order }, .context = owner.config.context, .control_epoch = owner.preparing.?.intent.request_epoch };
    }
    fn recordStreamingInputOwned(self: *ControlRuntime, input: music.trace.Input) void {
        if (self.music_runtime) |owner| owner.captureStreamingInputV1(self, input);
        if (self.streaming_inputs) |sink| if (!sink.push(input)) {
            self.stream_input_overflow +|= 1;
        };
    }
    fn acceptStreaming(self: *ControlRuntime) void {
        self.acceptStreamingAt(null);
    }
    fn acceptStreamingAt(self: *ControlRuntime, frame: ?u64) void {
        const service = self.streaming_service orelse return;
        if (service.replay_mode) return;
        self.acceptStreamVisibilityAt(frame);
        for (0..service.profile.completion_capacity) |_| {
            const position: scheduler.trace.Position = .{ .accepted_control_frame = frame orelse self.scheduled.render_frame.load(.acquire), .control_tick = self.stream_control_tick, .input_order = self.stream_input_order };
            if (self.scheduled.next_batch_id == std.math.maxInt(u64)) {
                self.stream_input_overflow +|= 1;
                self.stream_input_evidence_failures +|= 1;
                break;
            }
            const accepted = self.acceptStreamingOperation(service, position, self.scheduled.next_batch_id) catch {
                self.stream_input_overflow +|= 1;
                self.stream_input_evidence_failures +|= 1;
                break;
            } orelse break;
            self.scheduled.next_batch_id += 1;
            self.stream_input_order +|= 1;
            self.recordStreamingInputOwned(accepted.input);
        }
    }
    /// Call-scoped Control-only seam. Each attempt, including empty/deferred
    /// and failed attempts, emits once with its original returned error. The
    /// callback runs after successful frame adoption and input fan-out.
    /// It must not reenter, mutate engine state, allocate, wait, or throw.
    pub const LiveTickFailureOriginV1 = enum {
        collect_owner,
        accept_device,
        accept_replay,
        accept_drain,
        prepare_owner,
        prepare_failure_drain,
        prepare_success_drain,
        snapshot,
        accept_acquire,
        accept_sync,
        accept_live,
    };
    /// Synchronous copies at the real call sites. These callbacks are optional,
    /// observational only, and may never allocate, wait, perform IO or reenter.
    pub const LiveTickEventV1 = union(enum) {
        begin: struct { tick: u64, entry_frame: u64 },
        phase: TickPhaseV1,
        collect_returned: u64,
        prepare_returned: struct { frame: u64, value: music.MusicRuntime.LiveTickPreparationV1 },
        failure: struct { origin: LiveTickFailureOriginV1, reason: anyerror },
        snapshot: bool, // true is the reached prepare-failure recovery path
        publish_returned: u64,
        final_publish: struct { exit_phase: TickPhaseV1, frame: u64 },
        end: struct { frame: u64, failure: ?anyerror, preparation: music.MusicRuntime.LiveTickPreparationV1 },
    };
    pub const TestAfterLiveAcceptance = struct {
        context: *anyopaque,
        call: *const fn (*anyopaque, u64, u64) void,
    };
    pub const TestLiveAcceptanceAttempt = struct {
        context: *anyopaque,
        call: *const fn (*anyopaque, *const streaming.stream.LiveAcceptanceAttemptV1, u64, bool) void,
    };
    pub const LiveAcceptanceSinkV1 = struct {
        context: *anyopaque,
        emit: *const fn (*anyopaque, *const streaming.stream.LiveAcceptanceAttemptV1, u64) void,
        /// Actual acquired frame and derived effective frame stay distinct.
        frontier: ?*const fn (*anyopaque, TickPhaseV1, u64, u64) void = null,
        event: ?*const fn (*anyopaque, LiveTickEventV1) void = null,
        input: ?*const fn (*anyopaque, music.trace.Input) void = null,
    };
    fn observeLiveTickEventV1(self: *ControlRuntime, event: LiveTickEventV1) void {
        if (self.tick_v1.live_acceptance_sink) |sink| if (sink.event) |emit| emit(sink.context, event);
    }
    fn observeLiveTickFailureV1(self: *ControlRuntime, origin: LiveTickFailureOriginV1, reason: anyerror) void {
        self.observeLiveTickEventV1(.{ .failure = .{ .origin = origin, .reason = reason } });
    }
    fn acceptStreamingLiveAt(self: *ControlRuntime, owner: *music.MusicRuntime, scope: TickV1, sink: ?LiveAcceptanceSinkV1) !void {
        const service = self.streaming_service orelse return;
        if (service.replay_mode) return error.InvalidState;
        // Polls preceding acceptance keep their actual earlier position.
        self.acceptStreamVisibilityAt(self.tick_v1.frame);
        // One transient completed-DSP publication collision may be revisited
        // in this turn. Both calls consume the existing attempt budget; never
        // spin until success or reset this allowance after another acceptance.
        var retried_frontier = false;
        for (0..service.profile.completion_capacity) |_| {
            const position: scheduler.trace.Position = .{ .accepted_control_frame = self.tick_v1.frame, .control_tick = self.stream_control_tick, .input_order = self.stream_input_order };
            if (self.scheduled.next_batch_id == std.math.maxInt(u64)) {
                self.stream_input_overflow +|= 1;
                self.stream_input_evidence_failures +|= 1;
                break;
            }
            var attempt: streaming.stream.LiveAcceptanceAttemptV1 = undefined;
            // Capture the same call's result; never infer failure from a later
            // diagnostic read. This defer runs on every attempted operation.
            var acceptance_finished = false;
            defer {
                if (sink) |value| value.emit(value.context, &attempt, self.tick_v1.frame);
                if (@import("builtin").is_test) service.testRetryWorkload(.{ .after_attempt = .{ .attempt = &attempt, .effective_frame = self.tick_v1.frame, .finished = acceptance_finished } });
                // Service initializes attempt before every return, including
                // null/defer/error. This observer cannot supply engine values.
                if (@import("builtin").is_test) if (self.test_live_acceptance_attempt) |hook|
                    hook.call(hook.context, &attempt, self.tick_v1.frame, acceptance_finished);
                // The output-only Recorder callback has returned before this
                // explicit test workload seam can pause Control. Render never
                // waits here; neither callback can provide engine results.
                if (@import("builtin").is_test) if (acceptance_finished) if (self.test_after_live_acceptance) |hook|
                    hook.call(hook.context, position.control_tick, self.tick_v1.frame);
            }
            if (@import("builtin").is_test) service.testRetryWorkload(.{ .before_attempt = position });
            const accepted = service.acceptCompletedLiveV1(position, self.scheduled.next_batch_id, &attempt) catch {
                self.stream_input_overflow +|= 1;
                self.stream_input_evidence_failures +|= 1;
                break;
            } orelse {
                if (!retried_frontier) if (attempt.deferred) |deferred| switch (deferred.reason) {
                    .odd_sequence, .sequence_changed => {
                        retried_frontier = true;
                        // The iteration defer emits this failed real attempt
                        // before the next full Service call obtains a new cut.
                        continue;
                    },
                };
                break;
            };
            const actual = accepted.input.position;
            if (actual.control_tick != position.control_tick or actual.input_order != position.input_order or actual.accepted_control_frame < position.accepted_control_frame) {
                self.stream_input_overflow +|= 1;
                self.stream_input_evidence_failures +|= 1;
                return error.InvalidState;
            }
            self.tick_v1.frame = actual.accepted_control_frame;
            // Ownership/phase were checked before Service effects and remain
            // held. No observer can intervene before both owners are updated.
            try owner.syncLiveAcceptanceFrameV1(scope);
            self.scheduled.next_batch_id += 1;
            self.stream_input_order +|= 1;
            self.recordStreamingInputOwned(accepted.input);
            acceptance_finished = true;
        }
    }
    fn streamAcceptanceBinding(self: *ControlRuntime) ?StreamAcceptanceBinding {
        // Outside calls are not retroactively attached to an integrated tick.
        const serial = self.tick_v1.active.load(.acquire);
        if (serial == 0 or self.tick_v1.thread.load(.acquire) != std.Thread.getCurrentId()) return null;
        const binding = self.stream_acceptance_binding orelse return null;
        if (!binding.bridge.observing(binding.session, serial)) return null;
        return binding;
    }
    fn acceptStreamingOperation(self: *ControlRuntime, service: *streaming.Service, position: scheduler.trace.Position, batch_id: u64) streaming.stream.Error!?streaming.stream.Accepted {
        const binding = self.streamAcceptanceBinding() orelse return service.acceptCompletedWithBatch(position, batch_id);
        var evidence: streaming.stream.observation.Acceptance = undefined;
        // A swallowed Service error is still an observed failed operation, with
        // any preceding engine effects copied before the caller handles it.
        defer binding.bridge.observeAcceptance(binding.session, self.tick_v1.active.load(.acquire), self.tick_v1.phase, evidence);
        return service.acceptCompletedWithBatchObserved(position, batch_id, &evidence);
    }
    fn acceptStreamVisibility(self: *ControlRuntime) void {
        self.acceptStreamVisibilityAt(null);
    }
    fn acceptStreamVisibilityAt(self: *ControlRuntime, frame: ?u64) void {
        const service = self.streaming_service orelse return;
        if (service.replay_mode) return;
        for (0..service.profile.visibility_capacity) |_| {
            const binding = self.streamAcceptanceBinding();
            var evidence: streaming.stream.observation.Visibility = undefined;
            const admission = service.pollVisibilityObserved(if (binding != null) &evidence else null) orelse {
                if (binding) |value| {
                    // No new Render read: this empty opportunity is located at
                    // the admitted tick's existing frame and next input order.
                    const position: scheduler.trace.Position = .{ .accepted_control_frame = frame orelse self.tick_v1.frame, .control_tick = self.stream_control_tick, .input_order = self.stream_input_order };
                    value.bridge.observeVisibility(value.session, self.tick_v1.active.load(.acquire), self.tick_v1.phase, position, evidence);
                }
                break;
            };
            const input: music.trace.Input = .{ .position = .{ .accepted_control_frame = frame orelse self.scheduled.render_frame.load(.acquire), .control_tick = self.stream_control_tick, .input_order = self.stream_input_order }, .payload = .{ .admission = admission } };
            if (binding) |value| value.bridge.observeVisibility(value.session, self.tick_v1.active.load(.acquire), self.tick_v1.phase, input.position, evidence);
            self.stream_input_order +|= 1;
            self.recordStreamingInputOwned(input);
        }
    }
    pub fn streamReadiness(self: *ControlRuntime, handle: streaming.Handle, context: u64, control_epoch: u64) RuntimeError!music.trace.Input {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.streamReadinessOwned(handle, context, control_epoch);
    }
    fn streamReadinessOwned(self: *ControlRuntime, handle: streaming.Handle, context: u64, control_epoch: u64) RuntimeError!music.trace.Input {
        const service = self.streaming_service orelse return error.InvalidState;
        self.acceptStreamVisibility();
        return self.streamReadinessAtOwned(service, handle, context, control_epoch, self.scheduled.render_frame.load(.acquire));
    }
    fn streamReadinessAtOwned(self: *ControlRuntime, service: *streaming.Service, handle: streaming.Handle, context: u64, control_epoch: u64, frame: u64) RuntimeError!music.trace.Input {
        return self.streamReadinessAtOwnedWithLive(service, handle, context, control_epoch, frame, null);
    }
    fn streamReadinessAtOwnedWithLive(self: *ControlRuntime, service: *streaming.Service, handle: streaming.Handle, context: u64, control_epoch: u64, frame: u64, live: ?*?streaming.stream.LiveObservationDeferV1) RuntimeError!music.trace.Input {
        if (live) |value| value.* = null;
        const binding = self.activeReadinessBinding();
        const native: ?TestOwnedControlFacts = if (@import("builtin").is_test) self.test_owned_control_facts else null;
        const position: scheduler.trace.Position = .{ .accepted_control_frame = frame, .control_tick = self.stream_control_tick, .input_order = self.stream_input_order };
        var key: streaming.stream.readiness_observation.QueryKey = .{ .handle = handle, .context = context, .control_epoch = control_epoch, .position = position };
        const observed = if (native) |sink| sink.begin_query(sink.context, key) else if (binding) |value| blk: {
            value.bridge.context(self.tick_v1.phase, frame, self.stream_input_order);
            const result = value.bridge.beginQuery(key);
            key = value.bridge.queryKey();
            break :blk result;
        } else if (@import("builtin").is_test) self.test_readiness_observation else null;
        if (native != null or binding == null) if (observed) |value| {
            value.* = .{};
        };
        var output: ?*const music.trace.Input = null;
        defer if (native) |sink| {
            if (observed != null) sink.finish_query(sink.context, output);
        } else if (binding) |value| {
            if (observed != null) value.bridge.finishQuery(output);
        };

        errdefer |err| if (observed) |value| {
            value.error_code = @intFromError(err);
        };
        if (observed) |value| {
            value.saw(.order);
            value.order = self.stream_input_order;
        }
        if (self.stream_input_order == std.math.maxInt(u64)) return error.InvalidState;
        service.readinessHook(.before_outer_before, 0);
        self.liveReadinessCheckpoint(.{ .site = .readiness_outer_before, .edge = .before, .index = handle.index, .generation = handle.generation });
        const before = self.scheduled.render_frame.load(.acquire);
        self.liveReadinessCheckpoint(.{ .site = .readiness_outer_before, .edge = .after, .index = handle.index, .generation = handle.generation, .value = before });
        if (observed) |value| {
            value.saw(.outer_before);
            value.outer_before = before;
        }
        service.readinessHook(.after_outer_before, before);
        if (before != frame) {
            if (live) |value| value.* = .{ .reason = .frame_mismatch, .operation = .readiness_control_before, .handle = handle, .requested_frame = frame, .observed_frame = before };
            return error.InvalidState;
        }
        const public_replay = if (self.music_runtime) |owner| owner.streamReplayActiveV1() else false;
        if (public_replay) if (observed) |value| {
            value.representation_complete = false;
        };
        const input = if (live) |value|
            service.readinessLiveObservedV1(handle, position, context, control_epoch, if (native != null) observed else null, if (native != null) key else .{}, value) catch return error.InvalidState
        else if (public_replay)
            service.replayReadinessAt(handle, position, context, control_epoch, self.music_runtime.?.streamReplayInputV1(position) catch return error.InvalidState) catch return error.InvalidState
        else
            service.readinessObserved(handle, position, context, control_epoch, observed, key, if (native != null) null else if (binding) |value| value.bridge.measurementSource() else null) catch return error.InvalidState;
        self.liveReadinessCheckpoint(.{ .site = .readiness_outer_after, .edge = .before, .index = handle.index, .generation = handle.generation });
        const after = self.scheduled.render_frame.load(.acquire);
        self.liveReadinessCheckpoint(.{ .site = .readiness_outer_after, .edge = .after, .index = handle.index, .generation = handle.generation, .value = after });
        if (observed) |value| {
            value.saw(.outer_after);
            value.outer_after = after;
        }
        service.readinessHook(.after_outer_after, after);
        if (after != frame) {
            if (live) |value| value.* = .{ .reason = .frame_mismatch, .operation = .readiness_control_after, .handle = handle, .requested_frame = frame, .observed_frame = after };
            return error.InvalidState;
        }
        if (!service.replay_mode or public_replay) self.stream_input_order +|= 1;
        if (!service.replay_mode or public_replay) self.recordStreamingInputOwned(input);
        output = &input;
        return input;
    }
    fn activeReadinessBinding(self: *ControlRuntime) ?ReadinessBinding {
        const binding = self.readiness_binding orelse return null;
        if (self.tick_v1.active.load(.acquire) == 0 or binding.bridge.closed.load(.acquire)) return null;
        return binding;
    }
    fn reconciliationBinding(self: *ControlRuntime) ?ReadinessBinding {
        const configured = self.readiness_binding orelse return null;
        if (!configured.bridge.manifest.capture_reconciliation) return null;
        const binding = self.activeReadinessBinding() orelse return null;
        binding.bridge.current_control_epoch = if (binding.music_owner.generation) |generation| (if (generation.director) |director| director.request_epoch else 0) else 0;
        binding.bridge.context(self.tick_v1.phase, binding.music_owner.control_frame, self.stream_input_order);
        return binding;
    }
    fn beginReadinessReconciliation(self: *ControlRuntime, kind: readiness_witness.ReconciliationKind) ?*readiness_witness.Reconciliation {
        if (@import("builtin").is_test) if (self.test_owned_control_facts) |sink| return sink.begin_reconciliation(sink.context, kind);
        const binding = self.reconciliationBinding() orelse return null;
        return binding.bridge.beginReconciliation(kind);
    }
    fn finishReadinessReconciliation(self: *ControlRuntime, read: ?*readiness_witness.Reconciliation) u64 {
        if (read == null) return 0;
        if (@import("builtin").is_test) if (self.test_owned_control_facts) |sink| return sink.finish_reconciliation(sink.context);
        return self.readiness_binding.?.bridge.finishReconciliation();
    }
    fn observeSchedulerControl(raw: *anyopaque, value: scheduler.ControlObservation) void {
        const self: *ControlRuntime = @ptrCast(@alignCast(raw));
        const binding = self.reconciliationBinding() orelse return;
        binding.bridge.observeSchedulerControl(value);
    }
    fn observeStreamLifecycle(raw: *anyopaque, value: streaming.stream.readiness_observation.LifecycleRead) u64 {
        const self: *ControlRuntime = @ptrCast(@alignCast(raw));
        const binding = self.reconciliationBinding() orelse return 0;
        return binding.bridge.observeStreamLifecycle(value);
    }
    fn reconcileTerminalSchedules(self: *ControlRuntime) void {
        var read = self.beginReadinessReconciliation(.terminal_scan);
        for (&self.scheduled.slots, 0..) |*slot, i| {
            self.causalReplay(.{ .site = .terminal_scan, .edge = .before, .index = i });
            const state = slot.state.load(.acquire);
            self.causalReplay(.{ .site = .terminal_scan, .edge = .after, .index = i, .value = @intFromEnum(state) });
            if (read) |value| {
                const offset = value.scanned;
                value.states[offset / 2] |= @as(u8, @intFromEnum(state)) << @as(u3, @intCast((offset % 2) * 4));
                value.scanned += 1;
                if (state == .terminal) value.handle = .{ .index = @intCast(i), .generation = slot.generation };
            }
            if (state == .terminal) {
                _ = self.finishReadinessReconciliation(read);
                read = null;
                self.reconcileSchedule(slot);
                if (i + 1 < self.scheduled.slots.len) {
                    read = self.beginReadinessReconciliation(.terminal_scan);
                    if (read) |value| value.first_slot = @intCast(i + 1);
                }
            }
        }
        _ = self.finishReadinessReconciliation(read);
    }
    fn beginReadinessAcquisition(self: *ControlRuntime, kind: readiness_witness.AcquisitionKind, handle: scheduler.Handle, cursor: u16) ?*readiness_witness.Acquisition {
        if (@import("builtin").is_test) if (self.test_owned_control_facts) |sink| return sink.begin_acquisition(sink.context, kind, handle, cursor);
        // Detached and legacy readiness-only intervals keep their original
        // engine reads; enabled diagnostics retain the checked tick lifetime.
        const configured = self.readiness_binding orelse return null;
        if (!configured.bridge.manifest.capture_acquisitions) return null;
        const binding = self.activeReadinessBinding() orelse return null;
        binding.bridge.current_control_epoch = if (binding.music_owner.generation) |generation| (if (generation.director) |director| director.request_epoch else 0) else 0;
        binding.bridge.context(self.tick_v1.phase, binding.music_owner.control_frame, self.stream_input_order);
        return binding.bridge.beginAcquisition(kind, handle, cursor);
    }
    fn publishInvalidationOwned(self: *ControlRuntime, handle: scheduler.Handle, sequence: u64) RuntimeError!void {
        const configured = self.readiness_binding;
        const binding = if (configured != null and configured.?.bridge.manifest.capture_acquisitions) self.activeReadinessBinding() else null;
        const native: ?TestOwnedControlFacts = if (@import("builtin").is_test) self.test_owned_control_facts else null;
        const read = if (native) |sink| sink.begin_invalidation(sink.context) else if (binding) |value| blk: {
            value.bridge.current_control_epoch = if (value.music_owner.generation) |generation| (if (generation.director) |director| director.request_epoch else 0) else 0;
            value.bridge.context(self.tick_v1.phase, value.music_owner.control_frame, self.stream_input_order);
            break :blk value.bridge.beginInvalidationPublication();
        } else null;
        defer if (read != null) {
            if (native) |sink| sink.finish_invalidation(sink.context) else binding.?.bridge.finishInvalidationPublication();
        };
        errdefer |err| if (read) |value| {
            value.error_code = @intFromError(err);
        };
        try self.scheduled.publishInvalidationObserved(handle, sequence, read);
    }
    fn finishReadinessAcquisition(self: *ControlRuntime, read: ?*readiness_witness.Acquisition) void {
        if (read == null) return;
        if (@import("builtin").is_test) if (self.test_owned_control_facts) |sink| {
            sink.finish_acquisition(sink.context);
            return;
        };
        self.readiness_binding.?.bridge.finishAcquisition();
    }
    fn bindReadinessBlock(self: *ControlRuntime, read: ?*readiness_witness.Acquisition, slot: *const Scheduler.Slot) void {
        if (read) |value| {
            value.plan = .{ .index = slot.plan_index, .generation = self.scheduled.plans[slot.plan_index].generation };
            value.token = slot.block.commands[0].identity.token;
            value.batch_id = slot.block.id;
            value.content_hash = slot.block.content_hash;
        }
    }
    fn collectionFrameOwned(self: *ControlRuntime, kind: readiness_witness.AcquisitionKind) u64 {
        const read = self.beginReadinessAcquisition(kind, .{ .index = 0, .generation = 0 }, 0);
        defer self.finishReadinessAcquisition(read);
        self.causalReplay(.{ .site = .collection_frame, .edge = .before, .index = @intFromEnum(kind) });
        const frame = self.scheduled.render_frame.load(.acquire);
        self.causalReplay(.{ .site = .collection_frame, .edge = .after, .index = @intFromEnum(kind), .value = frame });
        if (read) |value| {
            value.observed = frame;
            value.reached = true;
            value.returned = true;
        }
        return frame;
    }
    fn beginReadinessSupply(raw: *anyopaque, kind: streaming.stream.readiness_observation.SupplyKind, handle: streaming.Handle, frame: ?u64, parent: u64) ?*streaming.stream.readiness_observation.SupplyRead {
        const self: *ControlRuntime = @ptrCast(@alignCast(raw));
        const binding = self.activeReadinessBinding() orelse return null;
        binding.bridge.current_control_epoch = if (binding.music_owner.generation) |generation| (if (generation.director) |director| director.request_epoch else 0) else 0;
        binding.bridge.context(self.tick_v1.phase, frame orelse self.tick_v1.frame, self.stream_input_order);
        const sink = binding.bridge.supplySink();
        return sink.begin(sink.context, kind, handle, frame, parent);
    }
    fn finishReadinessSupply(raw: *anyopaque) u64 {
        const self: *ControlRuntime = @ptrCast(@alignCast(raw));
        const binding = self.readiness_binding orelse return 0;
        const sink = binding.bridge.supplySink();
        return sink.finish(sink.context);
    }
    fn observeReadinessThroughput(raw: *anyopaque, fold: streaming.stream.readiness_observation.ThroughputFold) void {
        const self: *ControlRuntime = @ptrCast(@alignCast(raw));
        const binding = self.activeReadinessBinding() orelse return;
        binding.bridge.current_control_epoch = if (binding.music_owner.generation) |generation| (if (generation.director) |director| director.request_epoch else 0) else 0;
        binding.bridge.context(self.tick_v1.phase, self.tick_v1.frame, self.stream_input_order);
        const sink = binding.bridge.supplySink();
        sink.throughput(sink.context, fold);
    }
    /// Replay injects accepted facts through the same Control owner. Actual
    /// decoded staging PCM must already be prepared, but stays unpublished
    /// until this exact recorded frontier/tick/order.
    pub fn injectStreamReplay(self: *ControlRuntime, input: music.trace.Input) (RuntimeError || streaming.stream.Error)!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const service = self.streaming_service orelse return error.InvalidState;
        if (!service.replay_mode or input.payload != .worker or input.position.accepted_control_frame != self.scheduled.render_frame.load(.acquire) or input.position.control_tick != self.stream_control_tick or input.position.input_order != self.stream_input_order) return error.ReplayMismatch;
        if (self.scheduled.next_batch_id == std.math.maxInt(u64)) return error.InvalidState;
        try service.injectWithBatch(input, self.scheduled.next_batch_id);
        self.scheduled.next_batch_id += 1;
        self.stream_input_order += 1;
    }
    pub fn prepareStreamVisibilityReplay(self: *ControlRuntime, input: music.trace.Input) (RuntimeError || streaming.stream.Error)!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const service = self.streaming_service orelse return error.InvalidState;
        try service.prepareVisibilityReplay(input);
    }
    /// Match the Control acceptance position of an already recomputed render
    /// admission. It may describe an older render gate, never a guessed result.
    pub fn acceptStreamVisibilityReplay(self: *ControlRuntime, release: music.trace.replay.GateRelease) (RuntimeError || streaming.stream.Error)!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const service = self.streaming_service orelse return error.InvalidState;
        if (!service.replay_mode or release.position.accepted_control_frame != self.scheduled.render_frame.load(.acquire) or release.position.control_tick != self.stream_control_tick or release.position.input_order != self.stream_input_order) return error.ReplayMismatch;
        _ = try service.observedVisibility(release);
        const actual = service.pollVisibility() orelse return error.IncompleteTrace;
        if (actual.batch_id != release.batch_id or actual.gate != release.gate or actual.frame != release.frame or actual.gate_order != release.gate_order) return error.ReplayMismatch;
        self.stream_input_order += 1;
    }
    pub fn recomputeStreamReadiness(self: *ControlRuntime, position: scheduler.trace.Position, facts: scheduler.trace.readiness.Facts) (RuntimeError || streaming.stream.Error)!scheduler.trace.readiness.Projection {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const service = self.streaming_service orelse return error.InvalidState;
        if (!service.replay_mode or position.accepted_control_frame != self.scheduled.render_frame.load(.acquire) or position.control_tick != self.stream_control_tick or position.input_order != self.stream_input_order) return error.ReplayMismatch;
        const result = try service.recomputeReadiness(position, facts);
        self.stream_input_order += 1;
        return result;
    }
    pub fn requireStreamingTraceComplete(self: *const ControlRuntime) error{IncompleteTrace}!void {
        if (self.stream_input_overflow != 0 or self.stream_fault_overflow.load(.acquire) != 0) return error.IncompleteTrace;
        if (self.streaming_service) |service| if (service.visibility_discarded) return error.IncompleteTrace;
        const inputs = self.streaming_inputs orelse return error.IncompleteTrace;
        try inputs.requireComplete();
    }
    pub fn pollStreamFault(self: *ControlRuntime) ?StreamFault {
        return self.stream_faults.pop();
    }

    /// Single-Control preparation reserves all required voices and owner leases.
    /// The returned handle owns preparation storage until releaseMusicGroup.
    pub fn prepareMusicGroup(self: *ControlRuntime, desc: MusicGroupDesc, output: channel_layout.ChannelLayout, sample_rate: u32) RuntimeError!GroupHandle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareMusicGroupOwned(desc, output, sample_rate);
    }
    fn prepareMusicGroupOwned(self: *ControlRuntime, desc: MusicGroupDesc, output: channel_layout.ChannelLayout, sample_rate: u32) RuntimeError!GroupHandle {
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        if (desc.layers.len == 0 or desc.layers.len > music_group.max_layers) return error.InvalidArgument;
        const emergency_count = if (desc.emergency) |e| e.layers.len else 0;
        if (emergency_count > music_group.max_layers) return error.InvalidArgument;
        const reserve_count = @max(desc.layers.len, emergency_count);
        const profile = if (self.voice_admission) |admission| admission.voice else virtual_voice.releaseProfile();
        if (self.voice_admission != null and sample_rate != profile.sample_rate) return error.InvalidArgument;
        var virtual_count: usize = 0;
        var stingers: usize = 0;
        var resident_bytes: u64 = 0;
        for (desc.layers) |layer| {
            virtual_count += @intFromBool(layer.initial_state == .virtual);
            stingers += @intFromBool(layer.authored.protection == .stinger);
            if (layer.stream == null) resident_bytes = std.math.add(u64, resident_bytes, std.math.mul(u64, layer.owner.samples.len, 4) catch return error.InvalidArgument) catch return error.InvalidArgument;
        }
        if (self.voice_admission != null and resident_bytes > profile.segment_resident_limit_bytes) return self.voiceBudgetFailure(.resident_budget, resident_bytes, profile.segment_resident_limit_bytes, 0, 0);
        if (desc.emergency) |e| {
            var emergency_stingers: usize = 0;
            for (e.layers) |layer| {
                if (layer.initial_state != .real) return error.InvalidArgument;
                emergency_stingers += @intFromBool(layer.authored.protection == .stinger);
                resident_bytes = std.math.add(u64, resident_bytes, std.math.mul(u64, layer.owner.samples.len, 4) catch return error.InvalidArgument) catch return error.InvalidArgument;
            }
            stingers = @max(stingers, emergency_stingers);
        }
        const reserved_stingers = stingers;
        if (virtual_count != 0 and self.voice_admission == null) return error.InvalidVoiceProfile;
        // A larger emergency remains fully reserved, even when source layers
        // are virtual. Its guaranteed real minimum cannot be borrowed.
        if (self.reservedRealCount() + @max(reserve_count - virtual_count, emergency_count) > profile.max_real_voices) return self.voiceBudgetFailure(.real_capacity, self.reservedRealCount() + @max(reserve_count - virtual_count, emergency_count), profile.max_real_voices, 0, 0);
        if (self.reservedVirtualCount() + virtual_count > profile.max_virtual_voices) return self.voiceBudgetFailure(.virtual_capacity, self.reservedVirtualCount() + virtual_count, profile.max_virtual_voices, 0, 0);
        if (self.active_count + reserve_count > max_logical_voices) return self.voiceBudgetFailure(.virtual_capacity, self.active_count + reserve_count, max_logical_voices, 0, 0);
        var group_count: usize = 0;
        var resident_total = resident_bytes;
        for (&self.prepared_groups) |*slot| if (slot.occupied) {
            group_count += 1;
            resident_total = std.math.add(u64, resident_total, slot.resident_bytes) catch return error.InvalidArgument;
            stingers += slot.stinger_count;
        };
        if (group_count >= profile.max_groups) return self.voiceBudgetFailure(.group_capacity, group_count + 1, profile.max_groups, 0, 0);
        if (stingers > profile.max_stingers) return self.voiceBudgetFailure(.stinger_capacity, stingers, profile.max_stingers, 0, 0);
        if (self.voice_admission != null and resident_total > profile.resident_budget_bytes) return self.voiceBudgetFailure(.resident_budget, resident_total, profile.resident_budget_bytes, 0, 0);
        const index = for (&self.prepared_groups, 0..) |*slot, i| {
            if (!slot.occupied) break i;
        } else return error.VoiceBudgetExceeded;
        if (self.next_group_generation == std.math.maxInt(u64)) return error.InvalidState;
        var layers: [music_group.max_layers]music_group.Layer = undefined;
        var stream_handles: [music_group.max_layers]?streaming.Handle = @splat(null);
        for (desc.layers, 0..) |layer, i| {
            if (layer.stream) |source| {
                if (self.voice_admission != null) {
                    const service = self.streaming_service orelse return error.InvalidState;
                    stream_handles[i] = service.handleForSource(source) catch return error.InvalidState;
                }
                if (!layer.owner.stream_token) return error.InvalidArgument;
            }
            if (layer.stream == null and layer.owner.stream_token) return error.InvalidArgument;
            layers[i] = groupLayer(layer);
            if (layers[i].authored.layer_id == 0) layers[i].authored.layer_id = i + 1;
            for (layers[0..i]) |prior| if (prior.authored.layer_id == layers[i].authored.layer_id) return error.InvalidArgument;
        }
        var prepared = try music_group.Prepared.prepare(.{ .segment = desc.segment, .generation = desc.generation, .layout = desc.layout, .layers = layers[0..desc.layers.len], .segment_frames = desc.segment_frames, .loop = desc.loop, .start_cursor = desc.start_cursor, .start_loop_epoch = desc.start_loop_epoch, .gain = desc.gain, .ramp_frames = desc.ramp_frames }, output, sample_rate);
        prepared.voice_count = @intCast(reserve_count);
        prepared.emergency_real_count = @intCast(emergency_count);
        prepared.policy_managed = self.voice_admission != null;
        var emergency: ?music_group.Prepared = null;
        var emergency_owners: [music_group.max_layers]*SampleOwner = undefined;
        var emergency_retained: usize = 0;
        errdefer for (emergency_owners[0..emergency_retained]) |owner| owner.release();
        if (desc.emergency) |e| {
            // Resident leaf only: no stream, nested fallback, self-cycle, or
            // deferred preparation is allowed in the realtime recovery path.
            if (e.segment == desc.segment or e.layers.len == 0) return error.InvalidArgument;
            var emergency_bytes: u64 = 0;
            for (e.layers) |layer| {
                const bytes = std.math.mul(u64, layer.owner.samples.len, @sizeOf(f32)) catch return error.InvalidArgument;
                emergency_bytes = std.math.add(u64, emergency_bytes, bytes) catch return error.InvalidArgument;
            }
            const resident_limit = if (self.voice_admission != null) profile.segment_resident_limit_bytes else if (self.streaming_service) |service| service.profile.resident_limit_bytes else streaming.release_profile.resident_limit_bytes;
            if (emergency_bytes > resident_limit) return if (self.voice_admission != null) self.voiceBudgetFailure(.resident_budget, emergency_bytes, resident_limit, 0, 0) else error.InvalidArgument;
            for (e.layers, 0..) |layer, i| {
                if (layer.stream != null or layer.owner.stream_token) return error.InvalidArgument;
                layers[i] = groupLayer(layer);
            }
            emergency = try music_group.Prepared.prepare(.{ .segment = e.segment, .generation = desc.generation, .layout = e.layout, .layers = layers[0..e.layers.len], .segment_frames = e.segment_frames, .loop = e.loop, .gain = e.gain, .ramp_frames = e.ramp_frames }, output, sample_rate);
            for (e.layers, 0..) |layer, i| {
                try layer.owner.retain();
                emergency_owners[i] = layer.owner;
                emergency_retained += 1;
            }
        }
        var stream_leases: [music_group.max_layers]streaming.Source = undefined;
        var stream_count: usize = 0;
        errdefer for (stream_leases[0..stream_count]) |source| source.release();
        for (desc.layers, 0..) |layer, i| if (layer.stream) |source| {
            const read = self.beginReadinessReconciliation(.initial_stream_retain);
            defer _ = self.finishReadinessReconciliation(read);
            errdefer |err| if (read) |value| {
                value.error_code = @intFromError(err);
            };
            if (read) |value| {
                value.handle = .{ .index = @intCast(index), .generation = self.next_group_generation };
                value.stream = stream_handles[i] orelse .{ .index = 0, .generation = source.identity.stream_generation };
                value.stream_index_known = stream_handles[i] != null;
                value.ordinal = @intCast(i);
            }
            try source.retain();
            stream_leases[stream_count] = source;
            stream_count += 1;
            if (read) |value| value.returned = true;
        };
        var plays: [music_group.max_layers]PlayCommand = undefined;
        var reserved: usize = 0;
        errdefer for (plays[0..reserved]) |play| {
            play.owner.release();
            play.owner.release();
            self.instances.release(play.instance);
        };
        for (0..reserve_count) |i| {
            const layer = if (i < desc.layers.len) desc.layers[i] else desc.emergency.?.layers[i];
            const instance = try self.instances.reserve();
            layer.owner.retain() catch |err| {
                self.instances.release(instance);
                return err;
            };
            layer.owner.retain() catch |err| {
                layer.owner.release();
                self.instances.release(instance);
                return err;
            };
            plays[i] = .{ .instance = instance, .reservation = try self.instances.identity(instance), .owner = layer.owner, .params = .{ .bus = .music, .gain = layer.gain, .lowpass_hz = @as(f32, @floatFromInt(sample_rate)) / 2 } };
            reserved += 1;
            const read = self.beginReadinessReconciliation(.instance_prepare);
            if (read) |value| {
                value.handle = .{ .index = @intCast(index), .generation = self.next_group_generation };
                value.instance = .{ .index = instance.index, .generation = instance.generation };
                value.reservation = plays[i].reservation;
                value.ordinal = @intCast(i);
                value.returned = true;
            }
            _ = self.finishReadinessReconciliation(read);
        }
        const generation = self.next_group_generation;
        const group: GroupHandle = .{ .index = @intCast(index), .generation = generation };
        const generation_credit = if (self.music_runtime) |owner| try owner.acquirePreparedGroupCredit(self, group, desc) else null;
        // No fallible operation follows this authoritative ownership transfer.
        self.next_group_generation += 1;
        const slot = &self.prepared_groups[index];
        slot.* = .{ .occupied = true, .generation = generation, .generation_credit = generation_credit, .prepared = prepared, .plays = plays, .emergency = emergency, .emergency_owners = emergency_owners, .emergency_owner_count = @intCast(emergency_retained), .resident_bytes = resident_bytes, .stinger_count = @intCast(reserved_stingers), .voice_profile_hash = if (self.voice_admission) |admission| admission.hash else @splat(0) };
        slot.terminal.group = group;
        slot.terminal.prerequisite_order = if (self.prerequisite_terminal_order) |order| .{
            .collector = order,
            .index = group.index,
            .generation = group.generation,
        } else null;
        slot.terminal.causal_publication_sink = self.public_causal_group_terminal_sink;
        slot.terminal.offline_causal_replay = self.offline_causal_group_terminal;
        slot.source_switch.group = group;
        for (desc.layers, 0..) |layer, i| if (layer.stream != null) {
            slot.source_ownership.initial_stream_leases |= @as(u16, 1) << @intCast(i);
        };
        if (slot.emergency) |*resident| slot.prepared.emergency = resident;
        slot.content_hash = hashPreparedGroup(slot);
        for (plays[0..reserved], 0..) |play, i| {
            self.desired[play.instance.index] = .{ .active = true, .reservation = play.reservation, .scheduled = true, .virtual_reserved = i < prepared.layer_count and prepared.layers[i].initial_state == .virtual, .instance = play.instance, .owner = play.owner, .params = play.params, .revision = self.takeRevision() };
            self.active_count += 1;
        }
        const read = self.beginReadinessReconciliation(.group_prepare);
        if (read) |value| {
            value.handle = .{ .index = group.index, .generation = group.generation };
            value.bank_generation = desc.generation;
            value.voice_count = prepared.voice_count;
            value.returned = true;
        }
        _ = self.finishReadinessReconciliation(read);
        return .{ .index = @intCast(index), .generation = generation };
    }

    /// Control current physical binding; original sources become identity-only
    /// metadata once their separately accounted initial leases retire.
    fn currentGroupSource(self: *ControlRuntime, slot: *const PreparedGroupSlot, layer: usize) RuntimeError!?streaming.Source {
        if (slot.source_switch.read() != null) return error.UnsupportedLayerSource;
        if (layer >= slot.prepared.layer_count) return error.InvalidArgument;
        if (slot.source_ownership.current_continuity) |handle| return (try self.source_continuity_manager.?.get(handle)).desc.sources[layer];
        if (slot.prepared.layers[layer].stream != null and slot.source_ownership.initial_stream_leases & (@as(u16, 1) << @intCast(layer)) == 0) return error.InvalidState;
        return slot.prepared.layers[layer].stream;
    }
    pub const MusicContinuityRequest = struct {
        source_incarnation: u64 = 1,
        group: GroupHandle,
        paused: bool,
        next_transport_epoch: u64,
        expected_pause: ?music_group.ContinuityCoordinate = null,
        sources: []const ?streaming.Source = &.{},
    };
    pub fn prepareMusicContinuity(self: *ControlRuntime, allocator: std.mem.Allocator, request: MusicContinuityRequest) RuntimeError!source_continuity.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareMusicContinuityOwned(allocator, request);
    }
    fn prepareMusicContinuityOwned(self: *ControlRuntime, allocator: std.mem.Allocator, request: MusicContinuityRequest) RuntimeError!source_continuity.Handle {
        const slot = try self.preparedGroup(request.group);
        const effective = try self.effectivePreparedSource(slot, request.source_incarnation);
        const observed = try self.musicVoiceObservation(request.group);
        if (observed.source_incarnation != request.source_incarnation) return error.InvalidState;
        _ = try self.effectivePreparedSource(slot, request.source_incarnation);
        if (!self.accepting.load(.acquire) or observed.state != .playing or observed.paused == request.paused or
            observed.transport_epoch == std.math.maxInt(u64) or request.next_transport_epoch != observed.transport_epoch + 1 or
            slot.graph_source_replaced.load(.acquire) != 0 or slot.references == std.math.maxInt(u16)) return error.InvalidState;
        if (!request.paused) {
            const pause = request.expected_pause orelse return error.InvalidState;
            if (pause.source_incarnation != request.source_incarnation or !pause.paused or pause.transport_epoch != observed.transport_epoch or pause.cursor != observed.cursor or
                pause.loop_epoch != observed.loop_epoch or pause.mutation_epoch != observed.mutation_epoch or observed.frame < pause.frame or
                request.sources.len != effective.layer_count) return error.InvalidState;
        } else if (request.sources.len != 0 or request.expected_pause != null) return error.InvalidState;
        var desc: music_group.SourceContinuity = .{ .source_incarnation = request.source_incarnation, .group = request.group, .bank_generation = observed.generation, .old_transport_epoch = observed.transport_epoch, .new_transport_epoch = request.next_transport_epoch, .mutation_epoch = observed.mutation_epoch, .paused = request.paused, .cursor = observed.cursor, .loop_epoch = observed.loop_epoch, .layer_count = effective.layer_count };
        // Resident clock continuity has no physical Service lease. Streamed
        // layers still require the actual attached Service for every handle.
        const service = self.streaming_service;
        for (0..desc.layer_count) |i| {
            if (if (request.source_incarnation == 1) try self.currentGroupSource(slot, i) else @as(?streaming.Source, null)) |old| {
                desc.old_handles[i] = (service orelse return error.InvalidState).handleForSource(old) catch return error.InvalidState;
                if (observed.layers[i].stream_generation != old.identity.stream_generation) return error.InvalidState;
                desc.old_sources[i] = old.identity;
            }
            if (!request.paused) if (request.sources[i]) |fresh| {
                const layer = &effective.layers[i];
                if (desc.old_sources[i] == null or !music_group.sameAuthoredSource(desc.old_sources[i].?, fresh.identity) or
                    fresh.identity.start_cursor != try layer.assetFrame(observed.cursor) or fresh.identity.start_loop_epoch != observed.loop_epoch or
                    !std.meta.eql(fresh.identity.loop, try layer.assetLoop(observed.loop))) return error.InvalidState;
                desc.handles[i] = (service orelse return error.InvalidState).handleForSource(fresh) catch return error.InvalidState;
                desc.sources[i] = fresh;
            };
        }
        if (self.source_continuity_manager == null) {
            const manager = try allocator.create(source_continuity.Manager);
            manager.* = .{ .allocator = allocator };
            self.source_continuity_manager = manager;
            self.source_continuity_published.store(manager, .release);
        }
        const handle = try self.source_continuity_manager.?.prepareHashed(desc, hashSourceContinuity(&desc, slot.content_hash));
        slot.references += 1;
        return handle;
    }
    pub fn musicContinuityResult(self: *ControlRuntime, handle: source_continuity.Handle) RuntimeError!?music_group.ContinuityCoordinate {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return (self.source_continuity_manager orelse return error.StaleContinuity).result(handle);
    }
    pub fn releaseMusicContinuity(self: *ControlRuntime, handle: source_continuity.Handle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.releaseMusicContinuityOwned(handle);
    }
    fn releaseMusicContinuityOwned(self: *ControlRuntime, handle: source_continuity.Handle) RuntimeError!void {
        const manager = self.source_continuity_manager orelse return error.StaleContinuity;
        const slot = try manager.get(handle);
        const group = slot.desc.group;
        try manager.release(handle, self.scheduled.render_frame.load(.acquire));
        self.prepared_groups[group.index].references -= 1;
    }
    fn collectContinuityLeases(self: *ControlRuntime) void {
        const manager = self.source_continuity_manager orelse return;
        const completed = self.music_observation_frame.load(.acquire);
        if (completed != self.scheduled.render_frame.load(.acquire)) return;
        for (&self.prepared_groups) |*slot| {
            if (!slot.occupied) continue;
            if (slot.source_ownership.initial_retire_frame) |frame| if (completed > frame) {
                self.releaseInitialStreamLeases(slot);
                slot.source_ownership.initial_retire_frame = null;
            };
        }
        for (&manager.slots, 0..) |*slot, i| {
            if (slot.state.load(.acquire) != .executed or slot.retired_frame == null) continue;
            self.releaseMusicContinuityOwned(.{ .index = @intCast(i), .generation = slot.generation }) catch {};
        }
    }
    fn releaseInitialStreamLeases(self: *ControlRuntime, slot: *PreparedGroupSlot) void {
        for (slot.prepared.layers[0..slot.prepared.layer_count], 0..) |layer, i| {
            if (slot.source_ownership.initial_stream_leases & (@as(u16, 1) << @intCast(i)) == 0) continue;
            const source = layer.stream.?;
            const read = self.beginReadinessReconciliation(.initial_stream_return);
            if (read) |value| {
                value.handle = .{ .index = @intCast((@intFromPtr(slot) - @intFromPtr(&self.prepared_groups)) / @sizeOf(PreparedGroupSlot)), .generation = slot.generation };
                value.bank_generation = slot.prepared.generation;
                // The immutable generation identifies this stream; no new
                // Service scan is introduced merely to rediscover its index.
                value.stream = .{ .index = 0, .generation = source.identity.stream_generation };
                value.ordinal = @intCast(i);
            }
            self.causalReplay(.{ .site = .stream_stop_publish, .edge = .before, .generation = source.identity.stream_generation, .value = 1 });
            source.ring.stopped.store(true, .release);
            self.causalReplay(.{ .site = .stream_stop_publish, .edge = .after, .generation = source.identity.stream_generation, .value = 1 });
            source.release();
            if (read) |value| value.returned = true;
            _ = self.finishReadinessReconciliation(read);
        }
        slot.source_ownership.initial_stream_leases = 0;
    }

    fn groupLayer(layer: MusicGroupLayer) music_group.Layer {
        return .{ .samples = layer.owner.samples, .asset_frame_origin = layer.asset_frame_origin, .layout = layer.layout, .sample_rate = layer.sample_rate, .generation = layer.generation, .gain = layer.gain, .stream = layer.stream, .required = layer.required, .optional_policy = layer.optional_policy, .authored = layer.authored, .initial_state = layer.initial_state, .audibility_envelope = layer.audibility_envelope };
    }

    pub fn musicGroupSourceSwitch(self: *ControlRuntime, handle: GroupHandle) RuntimeError!?music_group.SourceSwitch {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.musicGroupSourceSwitchOwned(handle);
    }
    fn musicGroupSourceSwitchOwned(self: *ControlRuntime, handle: GroupHandle) RuntimeError!?music_group.SourceSwitch {
        const read = self.beginReadinessAcquisition(.source_switch, .{ .index = handle.index, .generation = handle.generation }, 0);
        defer self.finishReadinessAcquisition(read);
        errdefer |err| if (read) |value| {
            value.error_code = @intFromError(err);
        };
        const slot = try self.preparedGroup(handle);
        var published = false;
        self.causalReplay(.{ .site = .group_source_switch_read, .edge = .before, .index = handle.index, .generation = handle.generation });
        const result = slot.source_switch.readObserved(&published);
        self.causalReplay(.{ .site = .group_source_switch_read, .edge = .after, .index = handle.index, .generation = handle.generation, .value = @intFromBool(published) });
        if (read) |value| {
            value.observed = @intFromBool(published);
            value.reached = true;
            value.returned = result != null;
            if (result) |fact| {
                value.cell = .{ .source_switch = fact };
                value.result_id = fact.source_incarnation;
                value.effective_frame = fact.frame;
            }
        }
        return result;
    }
    pub fn musicGroupSource(self: *ControlRuntime, handle: GroupHandle) RuntimeError!MusicGroupSource {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.musicGroupSourceOwned(handle);
    }
    fn musicGroupSourceOwned(self: *ControlRuntime, handle: GroupHandle) RuntimeError!MusicGroupSource {
        const slot = try self.preparedGroup(handle);
        const switched = try self.musicGroupSourceSwitchOwned(handle);
        const prepared: *const music_group.Prepared = if (switched != null) (if (slot.emergency) |*emergency| emergency else return error.InvalidState) else &slot.prepared;
        var result: MusicGroupSource = .{ .group = handle, .bank_generation = prepared.generation, .source_incarnation = if (switched) |value| value.source_incarnation else 1, .segment = prepared.segment, .frames = prepared.frames, .layer_count = prepared.layer_count, .sample_rate = prepared.sample_rate, .layout = prepared.matrix.input, .loop = prepared.loop, .degraded = switched != null };
        for (prepared.layers[0..prepared.layer_count], result.layers[0..prepared.layer_count]) |layer, *out| {
            out.* = .{ .stable_layer_id = layer.authored.layer_id, .asset_frame_origin = layer.asset_frame_origin, .asset_frames = layer.asset_frames, .required = layer.required, .streamed = layer.stream != null };
        }
        return result;
    }
    /// Retire physical old-source leases only after an actual completed fallback
    /// observation and after every old continuity schedule has been acknowledged.
    pub fn retireMusicGroupSource(self: *ControlRuntime, group: GroupHandle, source_incarnation: u64) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.retireMusicGroupSourceOwned(group, source_incarnation);
    }
    fn retireMusicGroupSourceOwned(self: *ControlRuntime, group: GroupHandle, source_incarnation: u64) RuntimeError!void {
        const prepared = try self.preparedGroup(group);
        const switched = prepared.source_switch.read() orelse return error.InvalidState;
        if (source_incarnation != 1 or switched.original_source_incarnation != source_incarnation or switched.source_incarnation != 2) return error.InvalidState;
        const observed = try self.musicVoiceObservation(group);
        if (observed.source_incarnation != 2 or observed.frame <= switched.frame) return error.DrainPending;
        return self.retireMusicGroupSourceAtFrontierOwned(prepared, group, source_incarnation, observed.frame);
    }
    /// The caller proves either a completed actual fallback observation, or an
    /// exact durable group terminal with zero Render pins and completed boundary.
    fn retireMusicGroupSourceAtFrontierOwned(self: *ControlRuntime, prepared: *PreparedGroupSlot, group: GroupHandle, source_incarnation: u64, completed: u64) RuntimeError!void {
        const switched = prepared.source_switch.read() orelse return error.InvalidState;
        if (source_incarnation != 1 or switched.original_source_incarnation != source_incarnation or switched.source_incarnation != 2) return error.InvalidState;
        if (completed <= switched.frame) return error.DrainPending;
        if (self.source_continuity_manager) |manager| {
            for (&manager.slots) |*entry| {
                const state = entry.state.load(.acquire);
                if (state == .free or !entry.desc.group.eql(group) or entry.desc.source_incarnation != source_incarnation) continue;
                if (entry.schedule_ref or state == .bound) return error.DrainPending;
            }
            for (&manager.slots, 0..) |*entry, i| {
                const state = entry.state.load(.acquire);
                if (state == .free or !entry.desc.group.eql(group) or entry.desc.source_incarnation != source_incarnation) continue;
                const handle: source_continuity.Handle = .{ .index = @intCast(i), .generation = entry.generation };
                if (state == .executed) entry.retired_completed_frontier = completed;
                try self.releaseMusicContinuityOwned(handle);
                if (prepared.source_ownership.current_continuity) |current| {
                    if (std.meta.eql(current, handle)) prepared.source_ownership.current_continuity = null;
                }
            }
        }
        self.releaseInitialStreamLeases(prepared);
        prepared.source_ownership.initial_retire_frame = null;
    }
    pub fn musicGroupTerminal(self: *ControlRuntime, handle: GroupHandle) RuntimeError!?music_group.Terminal {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.musicGroupTerminalOwned(handle);
    }
    fn musicGroupTerminalOwned(self: *ControlRuntime, handle: GroupHandle) RuntimeError!?music_group.Terminal {
        const read = self.beginReadinessAcquisition(.group_terminal, .{ .index = handle.index, .generation = handle.generation }, 0);
        defer self.finishReadinessAcquisition(read);
        errdefer |err| if (read) |value| {
            value.error_code = @intFromError(err);
        };
        const slot = try self.preparedGroup(handle);
        var published = false;
        self.causalReplay(.{ .site = .group_terminal_read, .edge = .before, .index = handle.index, .generation = handle.generation });
        const result = slot.terminal.readObserved(&published);
        self.causalReplay(.{ .site = .group_terminal_read, .edge = .after, .index = handle.index, .generation = handle.generation, .value = @intFromBool(published) });
        if (read) |value| {
            value.observed = @intFromBool(published);
            value.reached = true;
            value.returned = result != null;
            if (result) |fact| {
                value.cell = .{ .group_terminal = fact };
                value.effective_frame = fact.boundary_frame;
            }
        }
        return result;
    }

    pub fn releaseMusicGroup(self: *ControlRuntime, handle: GroupHandle) RuntimeError!void {
        _ = try self.releaseMusicGroupWithResult(handle);
    }
    pub fn releaseMusicGroupWithResult(self: *ControlRuntime, handle: GroupHandle) RuntimeError!MusicGroupReleaseResult {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        self.consumeCompletions();
        return self.releaseMusicGroupWithResultOwned(handle);
    }

    fn releaseMusicGroupOwned(self: *ControlRuntime, handle: GroupHandle) RuntimeError!void {
        _ = try self.releaseMusicGroupWithResultOwned(handle);
    }
    fn releaseMusicGroupWithResultOwned(self: *ControlRuntime, handle: GroupHandle) RuntimeError!MusicGroupReleaseResult {
        var read = self.beginReadinessReconciliation(.group_release);
        defer _ = self.finishReadinessReconciliation(read);
        errdefer |err| if (read) |value| {
            value.error_code = @intFromError(err);
        };
        if (read) |value| value.handle = .{ .index = handle.index, .generation = handle.generation };
        const slot = try self.preparedGroup(handle);
        self.causalReplay(.{ .site = .group_pin_read, .edge = .before, .index = handle.index, .generation = handle.generation });
        const pins = slot.render_pin_mask.load(.acquire);
        self.causalReplay(.{ .site = .group_pin_read, .edge = .after, .index = handle.index, .generation = handle.generation, .value = pins });
        if (read) |value| {
            value.bank_generation = slot.prepared.generation;
            value.pin_mask = pins;
        }
        if (pins != 0) return error.DrainPending;
        var retired_frontier: ?u64 = null;
        if (slot.source_switch.read() != null or slot.source_ownership.current_continuity != null) {
            const completed = self.scheduled.render_frame.load(.acquire);
            if (slot.terminal.read()) |terminal| {
                // A zero-release stop and a new start can reuse the Render slot
                // within one phase, before any .finished observation is copied.
                // The retained terminal belongs to this exact Control lifetime.
                if (!terminal.group.eql(handle) or terminal.bank_generation != slot.prepared.generation or completed < terminal.boundary_frame) return error.DrainPending;
                retired_frontier = completed;
            } else {
                const observed = self.musicVoiceObservation(handle) catch return error.DrainPending;
                if (observed.state != .finished) return error.DrainPending;
                retired_frontier = observed.frame;
            }
        }
        const release_attempt = self.finishReadinessReconciliation(read);
        read = null;
        if (slot.source_switch.read() != null) {
            // Explicit whole-group release settles old-source descriptors even
            // when a later start has already reused the physical mixer slot.
            try self.retireMusicGroupSourceAtFrontierOwned(slot, handle, 1, retired_frontier.?);
        }
        if (slot.source_ownership.current_continuity) |current| {
            const entry = try self.source_continuity_manager.?.get(current);
            entry.retired_completed_frontier = retired_frontier.?;
            try self.releaseMusicContinuityOwned(current);
            slot.source_ownership.current_continuity = null;
        }
        read = self.beginReadinessReconciliation(.group_release);
        const references = slot.references;
        if (read) |value| {
            value.parent_attempt = release_attempt;
            value.handle = .{ .index = handle.index, .generation = handle.generation };
            value.references = references;
        }
        if (references != 0) return error.InvalidState;
        for (&self.layer_changes) |*change| if (change.occupied and change.group.eql(handle) and change.references != 0) return error.DrainPending;
        _ = self.finishReadinessReconciliation(read);
        read = null;
        for (slot.plays[0..slot.prepared.voice_count], 0..) |play, i| {
            const desired_read = self.beginReadinessReconciliation(.group_desired);
            defer _ = self.finishReadinessReconciliation(desired_read);
            self.causalReplay(.{ .site = .group_desired_active, .edge = .before, .index = play.instance.index, .generation = play.instance.generation });
            const state = self.desired[play.instance.index];
            self.causalReplay(.{ .site = .group_desired_active, .edge = .after, .index = play.instance.index, .generation = play.instance.generation, .value = @intFromBool(state.active) });
            self.causalReplay(.{ .site = .group_desired_start, .edge = .before, .index = handle.index, .generation = handle.generation });
            const start_scheduled = slot.start_scheduled;
            self.causalReplay(.{ .site = .group_desired_start, .edge = .after, .index = handle.index, .generation = handle.generation, .value = @intFromBool(start_scheduled) });
            if (desired_read) |value| {
                value.parent_attempt = release_attempt;
                value.handle = .{ .index = handle.index, .generation = handle.generation };
                value.instance = .{ .index = play.instance.index, .generation = play.instance.generation };
                value.reservation = play.reservation;
                value.ordinal = @intCast(i);
                value.start_scheduled = start_scheduled;
            }
            if (start_scheduled) {
                if (desired_read) |value| value.desired_active = state.active;
                if (state.active) {
                    self.causalReplay(.{ .site = .group_desired_reservation, .edge = .before, .index = play.instance.index, .generation = play.instance.generation });
                    const matches = state.reservation == play.reservation;
                    self.causalReplay(.{ .site = .group_desired_reservation, .edge = .after, .index = play.instance.index, .generation = play.instance.generation, .value = @intFromBool(matches) });
                    if (desired_read) |value| value.reservation_matches = matches;
                    if (matches) {
                        if (desired_read) |value| value.error_code = @intFromError(error.DrainPending);
                        return error.DrainPending;
                    }
                }
            }
        }
        if (slot.generation_credit) |credit| try (self.music_runtime orelse return error.InvalidState).closePreparedGroupController(self, credit);
        for (slot.plays[0..slot.prepared.voice_count]) |play| {
            const state = &self.desired[play.instance.index];
            if (!slot.start_scheduled and state.active and state.reservation == play.reservation) {
                releasePlayOwner(state.owner, state.custody);
                state.* = .{};
                self.active_count -= 1;
                self.instances.release(play.instance);
            }
            play.owner.release();
        }
        self.releaseInitialStreamLeases(slot);
        for (&self.layer_changes) |*change| if (change.occupied and change.group.eql(handle)) self.discardLayerChangeOwned(change);
        for (slot.emergency_owners[0..slot.emergency_owner_count]) |owner| owner.release();
        if (slot.generation_credit) |credit| {
            slot.generation_credit_releasing = true;
            // All physical obligations are returned; this is the last access
            // which can reach its Generation through these released resources.
            (self.music_runtime orelse unreachable).releasePreparedGroupCredit(self, credit) catch unreachable;
        }
        // The final pin acquire and all terminal/frontier/schedule checks above
        // precede this copy. An earlier caller-side read could miss a switch
        // published while a stop ramp was still returning its last Render pin.
        self.causalReplay(.{ .site = .group_source_switch_final, .edge = .before, .index = handle.index, .generation = handle.generation });
        const result: MusicGroupReleaseResult = .{ .group = handle, .bank_generation = slot.prepared.generation, .source_switch = slot.source_switch.read() };
        self.causalReplay(.{ .site = .group_source_switch_final, .edge = .after, .index = handle.index, .generation = handle.generation, .value = @intFromBool(result.source_switch != null) });
        if (self.public_causal_group_source_final_sink) |sink| sink.emit(sink.context, .{ .group = handle, .bank_generation = result.bank_generation, .published = result.source_switch != null });
        slot.* = .{};
        read = self.beginReadinessReconciliation(.group_release);
        if (read) |value| {
            value.parent_attempt = release_attempt;
            value.handle = .{ .index = handle.index, .generation = handle.generation };
            value.bank_generation = result.bank_generation;
            value.returned = true;
        }
        return result;
    }

    fn preparedGroup(self: *ControlRuntime, handle: GroupHandle) RuntimeError!*PreparedGroupSlot {
        if (handle.index >= self.prepared_groups.len) return error.InvalidArgument;
        const slot = &self.prepared_groups[handle.index];
        if (!slot.occupied or slot.generation != handle.generation) return error.StaleInstance;
        return slot;
    }

    pub fn prepareResidentCapture(self: *ControlRuntime, desc: resident_transaction.CaptureDesc) RuntimeError!resident_transaction.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareResidentTransactionOwned(.{ .capture = desc });
    }
    pub fn prepareResidentRestore(self: *ControlRuntime, desc: resident_transaction.RestoreDesc) RuntimeError!resident_transaction.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareResidentTransactionOwned(.{ .restore = desc });
    }
    fn prepareResidentTransactionOwned(self: *ControlRuntime, desc: resident_transaction.Descriptor) RuntimeError!resident_transaction.Handle {
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        const slot = &self.resident_transaction_slot;
        if (slot.state.load(.acquire) != .free) return error.ResidentTransactionBusy;
        if (slot.generation == std.math.maxInt(u64)) return error.InvalidState;
        const groups = switch (desc) {
            .capture => |v| v.groups,
            .restore => |v| v.old_groups,
        };
        const plan = switch (desc) {
            .capture => |v| v.plan,
            .restore => |v| v.old_plan,
        };
        const generation = switch (desc) {
            .capture => |v| v.bank_generation,
            .restore => |v| v.expectedBankGeneration(),
        };
        const epoch = switch (desc) {
            .capture => |v| v.transport_epoch,
            .restore => |v| v.expected_transport_epoch,
        };
        const profile = switch (desc) {
            .capture => |v| v.profile,
            .restore => |v| v.profile,
        };
        if (groups.count > groups.items.len or generation == 0 or epoch == 0) return error.InvalidArgument;
        if (desc == .restore and desc.restore.seek_guard != null and !streamPreviewSeekDescriptor(desc.restore)) return error.UnsupportedOperation;
        if (profile != .resident_v1) {
            // Only the dedicated restore profile grants cross-generation
            // stream authority. Existing snapshot profiles remain same-bank.
            if (profile == .stream_reload_v1) {
                if (desc != .restore or !streamReloadDescriptor(desc.restore)) return error.UnsupportedOperation;
            } else if (desc == .restore and desc.restore.bank_generation != generation) return error.UnsupportedOperation;
            if (profile == .stream_direct_v1 or profile == .stream_reload_v1) {
                if (groups.count > 1 or plan != null) return error.UnsupportedOperation;
                // Direct snapshots and reloads carry no pending transition or suffix.
                if (self.scheduled.hasRenderObligations()) return error.UnsupportedOperation;
            }
            if (self.bus_manager) |manager| for (manager.graphs) |entry| if (entry) |graph| {
                if (graph.active.load(.acquire)) return error.UnsupportedOperation;
            };
            if (self.layer_manager) |manager| for (&manager.slots) |*program| {
                const state = program.state.load(.acquire);
                if (state == .bound or state == .active) return error.UnsupportedOperation;
            };
            if (self.graph_clock_manager) |manager| for (&manager.slots) |*program| {
                const state = program.state.load(.acquire);
                if (state == .bound or state == .active) return error.UnsupportedOperation;
            };
        }
        if (plan) |handle| {
            const ledger = try self.scheduled.getPlan(handle);
            if (ledger.token.transport_epoch.value() != epoch or ledger.token.asset_generation.value() != generation) return error.InvalidState;
            if (profile == .stream_fill_v1) {
                const prefix = ledger.executed_count.load(.acquire);
                // A restored plan also includes its already-executed install.
                if (ledger.cancelled.load(.acquire) or ledger.total_phases == 0 or ledger.total_phases > 4 or ledger.command_count > 7 or ledger.prepared_phases != ledger.total_phases or prefix > ledger.total_phases or ledger.total_phases - prefix > 3) return error.UnsupportedOperation;
            }
        }
        for (groups.items[0..groups.count], 0..) |handle, i| {
            try self.validateResidentGroup(handle, generation, profile);
            if (profile == .stream_direct_v1 or profile == .stream_reload_v1) {
                const observed = try self.musicVoiceObservation(handle);
                const prepared = &(try self.preparedGroup(handle)).prepared;
                if (observed.state != .playing or observed.source_incarnation != 1 or observed.graph_generation != 0 or observed.layer_count != prepared.layer_count or observed.gain != prepared.gain or !std.meta.eql(observed.loop, prepared.loop)) return error.UnsupportedOperation;
                if (observed.transport_epoch != epoch) return error.InvalidState;
                if (profile == .stream_reload_v1 and (observed.paused or observed.mutation_epoch != 1)) return error.UnsupportedOperation;
                if (desc == .restore) if (desc.restore.seek_guard) |guard| {
                    if (!observed.group.eql(guard.outgoing) or observed.generation != generation or prepared.segment != guard.segment or
                        observed.paused or observed.source_incarnation != guard.source_incarnation or observed.mutation_epoch != guard.mutation_epoch or
                        prepared.loop == null or observed.cursor >= prepared.frames or observed.cursor >= prepared.loop.?.end) return error.InvalidState;
                };
                for (observed.layers[0..observed.layer_count], 0..) |layer, layer_index| {
                    if (layer.state != .real or layer.automation_generation != 0 or layer.gain != prepared.layers[layer_index].gain) return error.UnsupportedOperation;
                    if ((profile == .stream_reload_v1 or (desc == .restore and desc.restore.seek_guard != null)) and layer.stream_generation != prepared.layers[layer_index].stream.?.identity.stream_generation) return error.InvalidState;
                }
            }
            for (groups.items[0..i]) |prior| if (prior.eql(handle)) return error.InvalidArgument;
        }
        const plan_content_hash = if (profile == .stream_fill_v1) try self.validateStreamFillPlan(&groups, plan) else @as([32]u8, @splat(0));
        if (desc == .restore) {
            const v = desc.restore;
            if (v.bank_generation == 0) return error.InvalidArgument;
            if (epoch == std.math.maxInt(u64) or v.new_transport_epoch != epoch + 1 or (v.paused and v.replacement == null)) return error.InvalidArgument;
            if (v.install_frame < try self.earliestPlanFrame()) return error.LateCommand;
            if (v.replacement) |replacement| {
                try self.validateResidentGroup(replacement, v.bank_generation, profile);
                const prepared = try self.preparedGroup(replacement);
                // Restored steady DSP starts at its saved value; an authored
                // entry ramp would restart an envelope absent from this profile.
                if (prepared.prepared.ramp_frames != 0) return error.UnsupportedOperation;
                if (groups.contains(replacement) or prepared.start_scheduled or prepared.render_pins_started.load(.acquire)) return error.InvalidState;
                if (profile != .resident_v1) try self.validateStreamRestoreSources(prepared, &groups, v.new_transport_epoch);
                if (v.seek_guard != null) {
                    const outgoing = try self.preparedGroup(groups.items[0]);
                    if (!streamPreviewSeekPreparedMatches(v, &outgoing.prepared, &prepared.prepared)) return error.InvalidState;
                    if (!prepared.prepared.minimumPlayable(prepared.prepared.start_cursor, prepared.prepared.start_loop_epoch)) return error.TargetNotResident;
                    for (prepared.prepared.layers[0..prepared.prepared.layer_count]) |layer| {
                        if (!layer.stream.?.ready(layer.assetFrame(prepared.prepared.start_cursor) catch return error.InvalidState, prepared.prepared.start_loop_epoch)) return error.TargetNotResident;
                    }
                }
                if (profile == .stream_reload_v1) {
                    const outgoing = try self.preparedGroup(groups.items[0]);
                    if (!streamReloadCoordinates(v, &outgoing.prepared, &prepared.prepared)) return error.InvalidState;
                    if (!prepared.prepared.minimumPlayable(prepared.prepared.start_cursor, prepared.prepared.start_loop_epoch)) return error.TargetNotResident;
                    for (prepared.prepared.layers[0..prepared.prepared.layer_count]) |layer| {
                        if (!layer.stream.?.ready(layer.assetFrame(prepared.prepared.start_cursor) catch return error.InvalidState, prepared.prepared.start_loop_epoch)) return error.TargetNotResident;
                    }
                }
            }
            // Scheduled SFX and other independent scheduler work share the old
            // global epoch. Reject explicitly before retaining or publishing.
            for (&self.scheduled.slots) |*block| {
                const state = block.state.load(.acquire);
                if (state == .free or state == .terminal) continue;
                if (plan == null or block.plan_index != plan.?.index or self.scheduled.plans[block.plan_index].generation != plan.?.generation) return error.UnsupportedOperation;
                for (block.block.commands[0..block.block.count]) |command| {
                    // A profile-3 plan may retain a completed restore install;
                    // only its authenticated, unexecuted suffix is authority.
                    if (profile == .stream_fill_v1 and command.identity.phase_order < self.scheduled.plans[block.plan_index].executed_count.load(.acquire)) continue;
                    switch (command.payload) {
                        .group_start => |value| {
                            if (!groups.contains(value.group)) return error.UnsupportedOperation;
                        },
                        .group_stop => |value| {
                            if (!groups.contains(value.group)) return error.UnsupportedOperation;
                        },
                        else => return error.UnsupportedOperation,
                    }
                }
            }
            // An open multi-block plan can have no retained block between
            // parts. It is still scheduled authority and cannot be ignored.
            for (&self.scheduled.plans, 0..) |*ledger, index| {
                if (!ledger.active or ledger.cancelled.load(.acquire) or ledger.executed_count.load(.acquire) == ledger.total_phases) continue;
                if (plan == null or plan.?.index != index or plan.?.generation != ledger.generation) return error.UnsupportedOperation;
            }
            for (&self.scheduled.intents) |*intent| if (intent.state.load(.acquire) != 0 and intent.state.load(.acquire) != 3) return error.ResidentTransactionBusy;
        }
        if (plan) |handle| try self.scheduled.retainPlan(handle);
        // Every capacity check precedes ownership transfer.
        for (groups.items[0..groups.count]) |handle| self.prepared_groups[handle.index].references += 1;
        if (desc == .restore) {
            if (desc.restore.replacement) |handle| self.prepared_groups[handle.index].references += 1;
        }
        const next_generation = slot.generation + 1;
        slot.* = .{ .generation = next_generation, .desc = desc, .plan_content_hash = plan_content_hash, .result = .{ .kind = std.meta.activeTag(desc), .outcome = .rejected } };
        slot.content_hash = self.hashResidentDescriptor(slot);
        slot.state.store(.prepared, .release);
        return .{ .generation = next_generation };
    }
    fn validateResidentGroup(self: *ControlRuntime, handle: GroupHandle, generation: u64, profile: resident_transaction.Profile) RuntimeError!void {
        const group = try self.preparedGroup(handle);
        if (group.references == std.math.maxInt(u16)) return error.CommandQueueFull;
        if (group.prepared.generation != generation) return error.StaleAssetGeneration;
        if (!snapshotPreparedProfile(&group.prepared, profile) or group.graph_source_replaced.load(.acquire) != 0 or group.source_switch.read() != null) return error.UnsupportedOperation;
    }
    /// Profile 3 observes only a fully prepared, bounded hard-cut plan. The
    /// group set authenticates every old/future source, including unsounded
    /// windows; no unrelated scheduler authority may ride through the fence.
    fn validateStreamFillPlan(self: *ControlRuntime, groups: *const resident_transaction.GroupSet, plan: ?scheduler.Handle) RuntimeError![32]u8 {
        const prefix = if (plan) |handle| (try self.scheduled.getPlan(handle)).executed_count.load(.acquire) else 0;
        const total = if (plan) |handle| self.scheduled.plans[handle.index].total_phases else 0;
        if (total > 4 or prefix > total or total - prefix > 3) return error.UnsupportedOperation;
        var starts: [4]?GroupHandle = @splat(null);
        var stops: [4]?GroupHandle = @splat(null);
        var frames: [4]u64 = @splat(0);
        var phases: [4]std.crypto.hash.sha2.Sha256 = undefined;
        for (&phases) |*hash| hash.* = std.crypto.hash.sha2.Sha256.init(.{});
        for (&self.scheduled.slots) |*block| {
            const state = block.state.load(.acquire);
            if (state == .free) continue;
            const matches = plan != null and block.plan_index == plan.?.index and self.scheduled.plans[block.plan_index].generation == plan.?.generation;
            if (!matches) {
                if (state == .terminal) continue;
                return error.UnsupportedOperation;
            }
            for (block.block.commands[0..block.block.count]) |command| {
                const phase = command.identity.phase_order;
                if (phase < prefix) continue;
                if (phase >= total) return error.InvalidState;
                switch (command.payload) {
                    .group_start => |value| {
                        if (!groups.contains(value.group) or starts[phase] != null) return error.UnsupportedOperation;
                        if (stops[phase] != null and frames[phase] != command.identity.execute_frame) return error.UnsupportedOperation;
                        starts[phase] = value.group;
                    },
                    .group_stop => |value| {
                        if (!groups.contains(value.group) or value.release_frames != 0 or starts[phase] != null or stops[phase] != null) return error.UnsupportedOperation;
                        stops[phase] = value.group;
                    },
                    else => return error.UnsupportedOperation,
                }
                frames[phase] = command.identity.execute_frame;
                // Publication changes sequence numbers, never the authored
                // command authority sealed here. Exclude only that ticket.
                var normalized = command;
                normalized.sequence = 0;
                encodeCommands(&phases[phase], &.{normalized});
            }
        }
        for (&self.scheduled.plans, 0..) |*ledger, index| {
            if (!ledger.active or ledger.cancelled.load(.acquire) or ledger.executed_count.load(.acquire) == ledger.total_phases) continue;
            if (plan == null or plan.?.index != index or plan.?.generation != ledger.generation) return error.UnsupportedOperation;
        }
        for (&self.scheduled.intents) |*intent| {
            const state = intent.state.load(.acquire);
            if (state != 0 and state != 3) return error.ResidentTransactionBusy;
        }
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("STREAM-FILL-PENDING-PLAN-V1");
        hashInt(&hash, prefix);
        hashInt(&hash, total);
        for (prefix..total) |phase| {
            const started = starts[phase] orelse return error.UnsupportedOperation;
            if (phase > prefix) {
                if (stops[phase] == null or !stops[phase].?.eql(starts[phase - 1].?) or frames[phase] <= frames[phase - 1]) return error.UnsupportedOperation;
            }
            for (starts[prefix..phase]) |previous| if (started.eql(previous.?)) return error.UnsupportedOperation;
            hash.update(&phases[phase].finalResult());
        }
        return hash.finalResult();
    }
    /// All replacement windows and the bounded hard-cut suffix are checked
    /// before schedule ownership or publication. No partial restore is exposed.
    fn validateStreamFillSuffix(self: *ControlRuntime, commands: []const ScheduledCommand) RuntimeError!void {
        if (commands.len == 0 or commands.len > 7 or commands[0].payload != .resident_restore) return error.UnsupportedOperation;
        const desc = self.resident_transaction_slot.desc.restore;
        if (desc.paused and commands.len != 1) return error.UnsupportedOperation;
        var fresh_groups: resident_transaction.GroupSet = .{};
        if (desc.replacement) |handle| {
            fresh_groups.items[0] = handle;
            fresh_groups.count = 1;
        }
        var previous = desc.replacement;
        var previous_frame = desc.install_frame;
        var index: usize = 1;
        var phase: u32 = 1;
        while (index < commands.len) : (phase += 1) {
            if (phase > 3) return error.UnsupportedOperation;
            const first = commands[index].identity;
            if (first.phase_order != phase or first.execute_frame < previous_frame or (phase > 1 and first.execute_frame == previous_frame)) return error.UnsupportedOperation;
            if (previous) |handle| {
                if (commands[index].payload != .group_stop) return error.UnsupportedOperation;
                const stop = commands[index].payload.group_stop;
                if (!stop.group.eql(handle) or stop.release_frames != 0) return error.UnsupportedOperation;
                index += 1;
            }
            if (index == commands.len or commands[index].payload != .group_start) return error.UnsupportedOperation;
            const command = commands[index];
            if (command.identity.phase_order != phase or command.identity.execute_frame != first.execute_frame or command.identity.group_id != first.group_id or !std.meta.eql(command.identity.token, first.token)) return error.UnsupportedOperation;
            const handle = command.payload.group_start.group;
            if (desc.old_groups.contains(handle) or fresh_groups.contains(handle)) return error.InvalidState;
            try self.validateResidentGroup(handle, desc.bank_generation, .stream_fill_v1);
            const prepared = try self.preparedGroup(handle);
            if (prepared.start_scheduled or prepared.render_pins_started.load(.acquire)) return error.InvalidState;
            try self.validateStreamRestoreSources(prepared, &desc.old_groups, desc.new_transport_epoch);
            try self.validateStreamRestoreSources(prepared, &fresh_groups, desc.new_transport_epoch);
            fresh_groups.items[fresh_groups.count] = handle;
            fresh_groups.count += 1;
            previous = handle;
            previous_frame = first.execute_frame;
            index += 1;
        }
    }
    fn validateStreamRestoreSources(self: *ControlRuntime, replacement: *const PreparedGroupSlot, old_groups: *const resident_transaction.GroupSet, epoch: u64) RuntimeError!void {
        const service = self.streaming_service orelse return error.InvalidState;
        for (replacement.prepared.layers[0..replacement.prepared.layer_count], 0..) |layer, i| if (layer.stream) |fresh| {
            _ = service.handleForSource(fresh) catch return error.InvalidState;
            if (!freshSnapshotSource(&replacement.prepared, &layer, fresh, epoch)) return error.InvalidState;
            for (replacement.prepared.layers[0..i]) |prior| if (prior.stream) |source| {
                if (fresh.ring == source.ring) return error.InvalidState;
            };
            for (old_groups.items[0..old_groups.count]) |handle| {
                const old = try self.preparedGroup(handle);
                for (0..old.prepared.layer_count) |index| {
                    // Paused originals can be retired. Compare immutable
                    // identities without validating or dereferencing old PCM.
                    const source = if (old.source_ownership.current_continuity) |continuation|
                        (try self.source_continuity_manager.?.get(continuation)).desc.sources[index]
                    else
                        old.prepared.layers[index].stream;
                    if (source) |value| if (sameSnapshotWindow(fresh, value)) return error.InvalidState;
                }
            }
        };
    }
    fn hashResidentDescriptor(self: *ControlRuntime, slot: *const resident_transaction.Slot) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        if (slot.profile() == .resident_v1) {
            hash.update("RESIDENT-TRANSACTION-DESCRIPTOR-V1");
        } else {
            hash.update(switch (slot.profile()) {
                .stream_direct_v1 => "STREAM-DIRECT-TRANSACTION-DESCRIPTOR-V1",
                .stream_fill_v1 => "STREAM-FILL-TRANSACTION-DESCRIPTOR-V1",
                .stream_reload_v1 => "STREAM-RELOAD-TRANSACTION-DESCRIPTOR-V1",
                .resident_v1 => unreachable,
            });
            hashInt(&hash, @intFromEnum(slot.profile()));
        }
        if (slot.profile() == .stream_fill_v1) hash.update(&slot.plan_content_hash);
        hashInt(&hash, @intFromEnum(slot.desc));
        switch (slot.desc) {
            .capture => |v| {
                hashInt(&hash, v.bank_generation);
                hashInt(&hash, v.transport_epoch);
            },
            .restore => |v| {
                // Omission keeps the historical same-bank digest. Explicit
                // presence (even the same generation) is separately domain
                // bound, authenticating the descriptor's exact representation.
                if (v.expected_bank_generation) |generation| {
                    hash.update("EXPECTED-BANK-GENERATION-V1");
                    hashInt(&hash, generation);
                }
                if (v.profile == .stream_reload_v1) {
                    // Presence is sealed too: absent is not a promise of zero.
                    for ([_]?u64{ v.expected_outgoing_segment, v.expected_outgoing_cursor, v.expected_outgoing_loop_epoch }) |coordinate| {
                        hashInt(&hash, @intFromBool(coordinate != null));
                        if (coordinate) |n| hashInt(&hash, n);
                    }
                }
                if (v.seek_guard) |guard| {
                    // No absent marker: old restore descriptor bytes and hashes
                    // remain exact. Presence and every seek promise are sealed.
                    hash.update("STREAM-PREVIEW-SEEK-GUARD-V1");
                    for ([_]u64{ guard.outgoing.index, guard.outgoing.generation, guard.segment, guard.source_incarnation, guard.mutation_epoch }) |n| hashInt(&hash, n);
                }
                for ([_]u64{ v.bank_generation, v.expected_transport_epoch, v.new_transport_epoch, v.install_frame, @intFromBool(v.paused), @intFromBool(v.replacement != null) }) |n| hashInt(&hash, n);
                if (v.replacement) |handle| {
                    hashInt(&hash, handle.index);
                    hashInt(&hash, handle.generation);
                    hash.update(&self.prepared_groups[handle.index].content_hash);
                }
            },
        }
        hashInt(&hash, slot.groups().count);
        for (slot.groups().items[0..slot.groups().count]) |handle| {
            hashInt(&hash, handle.index);
            hashInt(&hash, handle.generation);
            hash.update(&self.prepared_groups[handle.index].content_hash);
        }
        hashInt(&hash, @intFromBool(slot.plan() != null));
        if (slot.plan()) |handle| {
            hashInt(&hash, handle.index);
            hashInt(&hash, handle.generation);
            const plan = &self.scheduled.plans[handle.index];
            for ([_]u64{ plan.token.context.value(), plan.token.plan_id.value(), plan.token.plan_epoch.value(), plan.total_phases }) |n| hashInt(&hash, n);
            if (slot.profile() == .stream_fill_v1) {
                // Fully prepared ledger metadata is immutable for this retained
                // lifetime, unlike executed prefix and retired block storage.
                for ([_]u64{ plan.prepared_phases, plan.command_count, plan.last_frame }) |n| hashInt(&hash, n);
                for (0..plan.total_phases) |phase| {
                    hashInt(&hash, plan.phase_ids[phase].value());
                    hashInt(&hash, plan.phase_groups[phase]);
                }
                for (plan.command_ids[0..plan.command_count]) |id| hashInt(&hash, id);
            }
        }
        return hash.finalResult();
    }
    pub fn residentTransactionHash(self: *ControlRuntime, handle: resident_transaction.Handle) RuntimeError![32]u8 {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return (try self.resident_transaction_slot.get(handle)).content_hash;
    }
    pub fn pollResidentTransaction(self: *ControlRuntime, handle: resident_transaction.Handle) RuntimeError!?resident_transaction.Result {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.pollResidentTransactionOwned(handle);
    }
    fn pollResidentTransactionOwned(self: *ControlRuntime, handle: resident_transaction.Handle) RuntimeError!?resident_transaction.Result {
        const slot = try self.resident_transaction_slot.get(handle);
        if (slot.block) |block| {
            self.scheduled.reconcilePrepared();
            try self.reconcileResidentCommand(try self.scheduled.getObserved(block, null), slot.command_index);
        }
        if (slot.state.load(.acquire) != .terminal) return null;
        return slot.result;
    }
    fn reconcileResidentCommand(self: *ControlRuntime, block: *Scheduler.Slot, index: usize) RuntimeError!void {
        if (block.transaction_reconciled[index]) return;
        const command = block.block.commands[index];
        const transaction = transactionCommand(command.payload) orelse return;
        if (block.published_receipts.load(.acquire) <= index) return;
        const slot = try self.resident_transaction_slot.get(transaction.transaction);
        const receipt = block.receipts[index];
        if (receipt.result == .success) {
            // Receipt publication precedes the durable transaction release.
            if (slot.state.load(.acquire) != .terminal) return;
        } else {
            slot.result = .{ .kind = std.meta.activeTag(slot.desc), .outcome = if (receipt.result == .cancelled) .cancelled else .rejected, .reason = receipt.reason, .frame = receipt.effective_frame };
            slot.state.store(.terminal, .release);
        }
        if (command.payload == .resident_restore and receipt.result != .success) if (slot.desc.restore.replacement) |handle| {
            self.rejectResidentStart(handle);
        };
        block.transaction_reconciled[index] = true;
        slot.block = null;
    }
    fn rejectResidentStart(self: *ControlRuntime, handle: GroupHandle) void {
        const group = &self.prepared_groups[handle.index];
        for (group.plays[0..group.prepared.voice_count]) |play| {
            const state = &self.desired[play.instance.index];
            if (state.active and state.scheduled and state.reservation == play.reservation) {
                releasePlayOwner(state.owner, state.custody);
                state.* = .{};
                self.active_count -= 1;
                self.finish(play.instance, .rejected);
            }
        }
    }
    pub fn acknowledgeResidentTransaction(self: *ControlRuntime, handle: resident_transaction.Handle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.acknowledgeResidentTransactionOwned(handle);
    }
    fn acknowledgeResidentTransactionOwned(self: *ControlRuntime, handle: resident_transaction.Handle) RuntimeError!void {
        _ = try self.pollResidentTransactionOwned(handle) orelse return error.DrainPending;
        const slot = try self.resident_transaction_slot.get(handle);
        if (slot.block != null) return error.DrainPending;
        if (slot.plan()) |plan| try self.scheduled.releasePlan(plan);
        for (slot.groups().items[0..slot.groups().count]) |group| self.prepared_groups[group.index].references -= 1;
        if (slot.desc == .restore) {
            if (slot.desc.restore.replacement) |group| self.prepared_groups[group.index].references -= 1;
        }
        slot.state.store(.free, .release);
    }
    pub fn cancelResidentTransaction(self: *ControlRuntime, handle: resident_transaction.Handle) RuntimeError!?scheduler.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.cancelResidentTransactionOwned(handle);
    }
    fn cancelResidentTransactionOwned(self: *ControlRuntime, handle: resident_transaction.Handle) RuntimeError!?scheduler.Handle {
        const slot = try self.resident_transaction_slot.get(handle);
        if (slot.state.load(.acquire) == .terminal) return null;
        if (slot.block) |block| return self.cancelScheduleOwned(.{ .target = block, .requested_frame = self.scheduled.render_frame.load(.acquire) });
        slot.result = .{ .kind = std.meta.activeTag(slot.desc), .outcome = .cancelled, .frame = self.scheduled.render_frame.load(.acquire) };
        slot.state.store(.terminal, .release);
        return null;
    }
    fn scheduledStart(self: *const ControlRuntime, payload: ScheduledPayload) ?GroupHandle {
        return switch (payload) {
            .group_start => |v| v.group,
            .resident_restore => self.resident_transaction_slot.desc.restore.replacement,
            else => null,
        };
    }

    fn scheduledPlays(self: *const ControlRuntime, payload: *const ScheduledPayload) []const PlayCommand {
        return switch (payload.*) {
            .play => |*play| @as(*const [1]PlayCommand, @ptrCast(play))[0..],
            .group_start => |start| self.prepared_groups[start.group.index].plays[0..self.prepared_groups[start.group.index].prepared.voice_count],
            .resident_restore => if (self.scheduledStart(payload.*)) |handle| self.prepared_groups[handle.index].plays[0..self.prepared_groups[handle.index].prepared.voice_count] else &.{},
            else => &.{},
        };
    }

    /// All schedule operations (including result cursors) are single-Control
    /// methods. Concurrent/reentrant calls reject with ConcurrentControl. Game
    /// producers continue to use the existing bounded submitPlay/Bus/Stop APIs.
    /// Pins every play payload and reserves its voice
    /// before a block becomes visible. A failed preparation restores every pin
    /// and reservation, including failures on the final command.
    pub fn prepareSchedule(self: *ControlRuntime, start: u64, end: u64, commands: []const ScheduledCommand) RuntimeError!scheduler.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareScheduleOwned(start, end, commands, null);
    }

    /// A versioned plan can span multiple immutable blocks. Declare its complete
    /// phase budget (1..64) on every part; append contiguous phase_order values,
    /// preserving nondecreasing frame order, and submit parts in that order.
    /// The plan ledger remains alive even after an early block is acknowledged.
    pub fn prepareSchedulePart(self: *ControlRuntime, start: u64, end: u64, commands: []const ScheduledCommand, total_phases: u16) RuntimeError!scheduler.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.prepareScheduleOwned(start, end, commands, total_phases);
    }

    fn prepareScheduleOwned(self: *ControlRuntime, start: u64, end: u64, commands: []const ScheduledCommand, total_phases: ?u16) RuntimeError!scheduler.Handle {
        return self.prepareScheduleOwnedWithLiveWitness(start, end, commands, total_phases, null);
    }
    fn prepareScheduleOwnedWithLiveWitness(self: *ControlRuntime, start: u64, end: u64, commands: []const ScheduledCommand, total_phases: ?u16, late: ?*?scheduler.LivePrepareLateV1) RuntimeError!scheduler.Handle {
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        if (commands.len == 0 or commands.len > scheduler.commands_per_block) return error.InvalidArgument;
        var transaction_count: usize = 0;
        const transaction_slot = &self.resident_transaction_slot;
        for (commands, 0..) |command, i| {
            if (transactionCommand(command.payload)) |value| {
                transaction_count += 1;
                const slot = try transaction_slot.get(value.transaction);
                if (slot.state.load(.acquire) != .prepared or transaction_count != 1 or i != 0 or command.identity.phase_order != 0) return error.InvalidState;
                // Admission advances a per-plan fence before phase execution.
                // A transaction must have fresh plan authority, never reuse an
                // observed/old plan's fence and invalidate it before preflight.
                if (command.identity.token.plan_id.value() <= self.scheduled.latest_plan_id) return error.InvalidState;
                if (slot.desc == .capture and commands.len != 1) return error.InvalidArgument;
                for (commands[1..]) |later| if (later.identity.group_id == command.identity.group_id) return error.InvalidArgument;
                const epoch = switch (slot.desc) {
                    .capture => |v| v.transport_epoch,
                    .restore => |v| v.new_transport_epoch,
                };
                const generation = switch (slot.desc) {
                    .capture => |v| v.bank_generation,
                    .restore => |v| v.bank_generation,
                };
                if (command.identity.token.transport_epoch.value() != epoch or command.identity.token.asset_generation.value() != generation) return error.InvalidState;
                if (slot.desc == .restore and slot.desc.restore.install_frame != command.identity.execute_frame) return error.InvalidArgument;
            }
        }
        if (transaction_slot.state.load(.acquire) != .free and (transaction_slot.profile() == .stream_direct_v1 or transaction_slot.profile() == .stream_reload_v1)) {
            // No caller may append a transition, automation, or independent
            // plan after the direct-profile admission check above.
            if (transaction_count != 1) return error.ResidentTransactionBusy;
            if (commands.len != 1 or (total_phases != null and total_phases.? != 1)) return error.UnsupportedOperation;
        }
        if (transaction_slot.state.load(.acquire) != .free and transaction_slot.profile() == .stream_fill_v1) {
            // Freeze the observed plan and publish restore+suffix in one block.
            // The bound remains three entries even after early transaction ack.
            if (transaction_count != 1) return error.ResidentTransactionBusy;
            if (total_phases != null) return error.UnsupportedOperation;
            if (transaction_slot.desc == .restore) try self.validateStreamFillSuffix(commands);
        }
        if (transaction_slot.state.load(.acquire) != .free and transaction_slot.desc == .restore) {
            // Cross-generation publication owns this immutable install block
            // exclusively until acknowledgement. A caller must not borrow its
            // future token to append foreign work before Control commits it.
            // Same-generation restore retains its established suffix support.
            if (transaction_slot.desc.restore.expectedBankGeneration() != transaction_slot.desc.restore.bank_generation and transaction_count == 0) return error.ResidentTransactionBusy;
            for (commands) |command| {
                if (command.payload == .resident_restore) continue;
                if (command.payload != .group_start and command.payload != .group_stop) return error.UnsupportedOperation;
                if (command.identity.token.transport_epoch.value() != transaction_slot.desc.restore.new_transport_epoch) return error.ResidentTransactionBusy;
                if (transaction_count == 0) {
                    const block = try self.scheduled.getObserved(transaction_slot.block orelse return error.ResidentTransactionBusy, null);
                    if (command.identity.token.plan_id != block.block.commands[0].identity.token.plan_id or command.identity.token.plan_epoch != block.block.commands[0].identity.token.plan_epoch) return error.ResidentTransactionBusy;
                }
            }
        }
        var starts: usize = 0;
        for (commands, 0..) |command, i| {
            if (self.voice_admission != null and command.identity.token.context.value() != self.voice_context_id) return error.InvalidArgument;
            try self.validateScheduledPayload(command.payload);
            if (command.payload == .group_stop and command.payload.group_stop.allow_crossfade_source_stop and !validCrossfadeStopPair(commands, command)) return error.InvalidArgument;
            if (payloadGroup(command.payload)) |group| for (commands[0..i]) |prior| {
                if (prior.payload == .group_pause and prior.payload.group_pause.continuity != null and prior.payload.group_pause.group.eql(group)) return error.InvalidState;
            };
            if (try self.trackedDuck(command.payload)) |tracked| {
                const manager = &self.bus_manager.?.ducks;
                try manager.validateBind(tracked);
                const identity = (try manager.get(tracked.handle)).cell.identity;
                if (command.payload.graph_targets.duck_cleanup) |authorization| {
                    // Only the live, already-owned MusicRuntime prepare session
                    // can authorize a current-epoch end of an older begin.
                    try authorization.validate(.{ .runtime = self, .serial = self.tick_v1.active.load(.acquire) }, command.payload.graph_targets.batch, command.identity);
                } else if (identity.accepted.accepted_control_frame > command.identity.execute_frame or identity.context != command.identity.token.context.value() or identity.asset_generation != command.identity.token.asset_generation.value() or identity.transport_epoch != command.identity.token.transport_epoch.value()) return error.InvalidDuckIdentity;
                for (commands[0..i]) |prior| if (try self.trackedDuck(prior.payload)) |other| if (other.handle.eql(tracked.handle)) return error.DuckBusy;
            }
            const group_ramp: u64 = switch (command.payload) {
                .group_start => |v| self.prepared_groups[v.group.index].prepared.ramp_frames,
                .group_gain => |v| v.ramp_frames,
                .group_stop => |v| v.release_frames,
                else => 0,
            };
            _ = std.math.add(u64, command.identity.execute_frame, group_ramp) catch return error.UnsafeFrameRange;
            if (self.scheduledStart(command.payload)) |start_group| {
                const group = try self.preparedGroup(start_group);
                if (group.start_scheduled) return error.DuplicateInstance;
                if (group.prepared.generation != command.identity.token.asset_generation.value()) return error.StaleAssetGeneration;
                for (commands[0..i]) |prior| if (self.scheduledStart(prior.payload)) |prior_group| if (prior_group.eql(start_group)) return error.DuplicateInstance;
            }
            if (command.payload == .group_pause) {
                const value = command.payload.group_pause;
                if (value.continuity) |handle| {
                    const continuation = try (self.source_continuity_manager orelse return error.StaleContinuity).get(handle);
                    const desc = &continuation.desc;
                    if (continuation.state.load(.acquire) != .prepared or !desc.group.eql(value.group) or desc.paused != value.paused or
                        desc.old_transport_epoch != command.identity.token.transport_epoch.value() or desc.new_transport_epoch != value.next_transport_epoch or
                        desc.bank_generation != command.identity.token.asset_generation.value()) return error.InvalidState;
                    for (commands[0..i]) |prior| if (payloadGroup(prior.payload)) |group| if (group.eql(value.group)) return error.InvalidState;
                }
            }
            if (command.payload == .group_layer) {
                const change = try self.layerChange(command.payload.group_layer.change);
                if (change.scheduled or !change.group.eql(command.payload.group_layer.group) or change.change.ticket.realize_frame != command.identity.execute_frame or change.change.ticket.transport_epoch != command.identity.token.transport_epoch.value() or change.change.ticket.generation != command.identity.token.asset_generation.value()) return error.InvalidState;
                for (commands[0..i]) |prior| if (prior.payload == .group_layer and std.meta.eql(prior.payload.group_layer.change, command.payload.group_layer.change)) return error.DuplicateInstance;
            }
            if (command.payload == .group_layer_automation) {
                const v = command.payload.group_layer_automation;
                const program = try self.layer_manager.?.get(v.program);
                const anchor = program.desc.anchor;
                var effective_transport = command.identity.token.transport_epoch.value();
                for (commands[0..i]) |prior| if (prior.payload == .group_pause and prior.payload.group_pause.group.eql(v.group) and prior.payload.group_pause.next_transport_epoch != 0) {
                    effective_transport = prior.payload.group_pause.next_transport_epoch;
                };
                if (program.state.load(.acquire) != .prepared or anchor.install_frame != command.identity.execute_frame or anchor.context != command.identity.token.context.value() or anchor.bank_generation != command.identity.token.asset_generation.value() or anchor.transport_epoch != effective_transport or !std.meta.eql(anchor.expected_previous, v.expected_previous)) return error.InvalidLayerProgram;
                for (commands[0..i]) |prior| if (prior.payload == .group_layer_automation and prior.payload.group_layer_automation.program.eql(v.program)) return error.DuplicateInstance;
            }
            if (command.payload == .graph_source_program) {
                const v = command.payload.graph_source_program;
                const program = try self.graph_clock_manager.?.get(v.program);
                const a = program.desc.progress.anchor;
                var effective_transport = command.identity.token.transport_epoch.value();
                for (commands[0..i]) |prior| if (prior.payload == .group_pause and prior.payload.group_pause.group.eql(v.group) and prior.payload.group_pause.next_transport_epoch != 0) {
                    effective_transport = prior.payload.group_pause.next_transport_epoch;
                };
                if (program.state.load(.acquire) != .prepared or a.install_frame != command.identity.execute_frame or a.context != command.identity.token.context.value() or a.bank_generation != command.identity.token.asset_generation.value() or a.transport_epoch != effective_transport) return error.InvalidGraphProgram;
                for (commands[0..i]) |prior| if (prior.payload == .graph_source_program and prior.payload.graph_source_program.program.eql(v.program)) return error.DuplicateInstance;
            }
            if (command.payload == .play) {
                const play = command.payload.play;
                if (self.desired[play.instance.index].active) return error.DuplicateInstance;
                for (commands[0..i]) |prior| if (prior.payload == .play and prior.payload.play.instance.eql(play.instance)) return error.DuplicateInstance;
                starts += 1;
            }
        }
        if (exactLayerStop(commands)) |program| {
            const slot = try self.layer_manager.?.get(program);
            if (slot.stop_pending or (!slot.stop_credit and slot.state.load(.acquire) != .terminal)) return error.LayerProgramBusy;
            // The pre-reserved credit pays for this one block/plan/fence.
            if (slot.state.load(.acquire) == .terminal) try self.reserveLayerScheduleCapacity(1, 0);
        } else if (exactGraphStop(commands)) |program| {
            const slot = try self.graph_clock_manager.?.get(program);
            if (slot.stop_pending or (!slot.stop_credit and slot.state.load(.acquire) != .terminal)) return error.GraphProgramBusy;
            if (slot.state.load(.acquire) == .terminal) try self.reserveLayerScheduleCapacity(1, 0);
        } else if (try self.exactDuckStop(commands)) {
            // Its already reserved common block/plan/fence credit pays here.
        } else {
            for (commands) |command| {
                if (try self.trackedDuck(command.payload)) |tracked| if (tracked.kind == .end) return error.DuckBusy;
                if (command.payload == .group_layer_automation_stop) return error.InvalidLayerProgram;
                if (command.payload == .graph_source_program_stop) return error.InvalidGraphProgram;
            }
            try self.reserveLayerScheduleCapacity(1, 0);
        }
        const real_limit = if (self.voice_admission) |a| a.voice.max_real_voices else max_render_voices;
        if (self.reservedRealCount() + starts > real_limit) return self.voiceBudgetFailure(.real_capacity, self.reservedRealCount() + starts, real_limit, 0, 0);
        var bound: [scheduler.commands_per_block]ScheduledCommand = undefined;
        @memcpy(bound[0..commands.len], commands);
        var producers: [scheduler.commands_per_block]?PlayCustodyAnchor.Producer = @splat(null);
        defer for (producers[0..commands.len]) |producer| if (producer) |guard| guard.leave();
        var pinned: usize = 0;
        errdefer for (bound[0..pinned]) |command| if (command.payload == .play) {
            releasePlayOwner(command.payload.play.owner, command.payload.play.block_custody);
            releasePlayOwner(command.payload.play.owner, command.payload.play.custody);
        };
        for (bound[0..commands.len], 0..) |*command, i| {
            if (command.payload == .play) {
                const play = &command.payload.play;
                play.custody = null;
                play.block_custody = null;
                if (play.owner.play_custody != null) play.reservation = try self.instances.identity(play.instance);
                const root = try self.retainPlayRoot(play.*);
                producers[i] = root.producer;
                play.custody = root.token;
                if (root.token != null) {
                    play.block_custody = pinPlayDerivative(play.owner, root.token, .prepared_block, playDestination(self, play.instance, play.reservation)) catch |err| {
                        releasePlayOwner(play.owner, root.token);
                        return err;
                    };
                } else play.owner.retain() catch |err| {
                    play.owner.release();
                    return err;
                };
            }
            pinned += 1;
        }
        const preparation_read = self.beginReadinessReconciliation(.schedule_prepare);
        if (preparation_read) |value| value.command_count = @intCast(commands.len);
        const preparation_attempt = self.finishReadinessReconciliation(preparation_read);
        var preparation_succeeded = false;
        // Observation cannot account for arbitrary rollback lifetimes in this
        // finite profile. Keep the existing error and every existing errdefer
        // in their original order, and reject the interval if preparation fails.
        defer if (!preparation_succeeded and preparation_attempt != 0) {
            self.readiness_binding.?.bridge.markIncomplete(.representation_bound);
        };
        var group_refs: usize = 0;
        errdefer for (commands[0..group_refs]) |command| {
            if (payloadGroup(command.payload)) |group_handle| self.prepared_groups[group_handle.index].references -= 1;
        };
        for (commands, 0..) |command, i| {
            if (payloadGroup(command.payload)) |handle| {
                const slot = try self.preparedGroup(handle);
                if (slot.references == std.math.maxInt(u16)) return error.CommandQueueFull;
                // Preserve the independent original increment read after its
                // capacity check; both the effect and witness use this value.
                const references = slot.references;
                slot.references = references + 1;
                const retain_read = self.beginReadinessReconciliation(.schedule_group_retain);
                if (retain_read) |value| {
                    value.parent_attempt = preparation_attempt;
                    value.handle = .{ .index = handle.index, .generation = handle.generation };
                    value.command_id = command.identity.command_id;
                    value.ordinal = @intCast(i);
                    value.input_ordinal = @intCast(i);
                    value.references = references;
                    value.references_after = references + 1;
                    value.returned = true;
                }
                _ = self.finishReadinessReconciliation(retain_read);
            }
            group_refs += 1;
        }
        var bus_refs: usize = 0;
        errdefer for (commands[0..bus_refs]) |command| self.releaseBusPayload(command.payload);
        for (commands) |command| {
            try self.retainBusPayload(command.payload);
            bus_refs += 1;
        }
        for (bound[0..commands.len]) |*command| switch (command.payload) {
            .resident_capture, .resident_restore => |*v| v.content_hash = self.resident_transaction_slot.content_hash,
            .graph_install, .graph_retire => |*v| v.content_hash = (try self.bus_manager.?.get(v.graph)).content_hash,
            .graph_targets => |*v| v.content_hash = (try self.bus_manager.?.batch(v.batch)).content_hash,
            .graph_source_program, .graph_source_program_stop => |*v| {
                const program = try self.graph_clock_manager.?.get(v.program);
                v.content_hash = program.desc.content_hash;
                v.source_hash = program.source_binding.hash;
            },
            .group_pause => |*v| if (v.continuity) |handle| {
                v.continuity_hash = (try self.source_continuity_manager.?.get(handle)).content_hash;
            },
            .group_bus_route => |*v| v.content_hash = (try self.bus_manager.?.route(v.route)).content_hash,
            .group_layer => |*v| v.content_hash = self.layer_changes[v.change.index].content_hash,
            .group_start => |*v| v.content_hash = self.prepared_groups[v.group.index].content_hash,
            .group_layer_automation => |*v| v.content_hash = (try self.layer_manager.?.get(v.program)).desc.content_hash,
            .group_layer_automation_stop => |*v| v.content_hash = (try self.layer_manager.?.get(v.program)).desc.content_hash,
            .play => |*v| {
                const current = try self.instances.identity(v.instance);
                if (v.custody != null and v.reservation != current) return error.StaleInstance;
                v.reservation = current;
            },
            .stop => |*v| {
                v.reservation = try self.instances.identity(v.instance);
                const state = self.desired[v.instance.index];
                v.incarnation = if (state.active and state.start_order_known) state.start_order else null;
            },
            .update => |*v| {
                v.reservation = try self.instances.identity(v.instance);
                const state = self.desired[v.instance.index];
                v.incarnation = if (state.active and state.start_order_known) state.start_order else null;
            },
            else => {},
        };
        const hash = hashScheduledBlock(start, end, bound[0..commands.len]);
        const handle = if (commands.len == 1 and commands[0].payload == .resident_capture) capture: {
            const fence_end = std.math.add(u64, start, 1) catch return error.UnsafeFrameRange;
            if (start != commands[0].identity.execute_frame or end != fence_end or total_phases != null) return error.InvalidArgument;
            break :capture try self.scheduled.prepareObservationFence(start, bound[0..commands.len], hash);
        } else if (late) |witness|
            try self.scheduled.prepareWithLateWitnessV1(start, end, bound[0..commands.len], hash, witness)
        else
            try self.scheduled.prepare(start, end, bound[0..commands.len], hash, total_phases);
        const schedule_slot = try self.scheduled.getObserved(handle, null);
        for (schedule_slot.block.commands[0..schedule_slot.block.count], 0..) |command, i| if (transactionCommand(command.payload) != null) {
            self.resident_transaction_slot.block = handle;
            self.resident_transaction_slot.command_index = @intCast(i);
            self.resident_transaction_slot.state.store(.bound, .release);
            if (self.scheduledStart(command.payload)) |group| self.prepared_groups[group.index].start_scheduled = true;
        };
        for (bound[0..commands.len]) |command| if (self.trackedDuck(command.payload) catch unreachable) |tracked| {
            const token = command.identity.token;
            self.bus_manager.?.ducks.bind(tracked, .{ .command_id = command.identity.command_id, .plan_id = token.plan_id.value(), .plan_epoch = token.plan_epoch.value(), .phase_id = token.phase_id.value(), .phase_order = command.identity.phase_order, .execute_frame = command.identity.execute_frame });
        };
        for (bound[0..commands.len]) |command| switch (command.payload) {
            .group_layer_automation => |v| self.layer_manager.?.bindInstall(v.program, .{ .plan_id = command.identity.token.plan_id.value(), .plan_epoch = command.identity.token.plan_epoch.value(), .command_id = command.identity.command_id, .phase_id = command.identity.token.phase_id.value(), .phase_order = command.identity.phase_order, .admitted_epoch = &self.scheduled.fences[schedule_slot.fence_index].admitted_epoch }),
            .group_layer_automation_stop => |v| self.layer_manager.?.bindStop(v.program),
            .graph_source_program => |v| self.graph_clock_manager.?.bindInstall(v.program, .{ .plan_epoch = command.identity.token.plan_epoch.value(), .admitted_epoch = &self.scheduled.fences[schedule_slot.fence_index].admitted_epoch }),
            .graph_source_program_stop => |v| self.graph_clock_manager.?.bindStop(v.program),
            else => {},
        };
        for (bound[0..commands.len]) |command| if (command.payload == .group_pause) {
            if (command.payload.group_pause.continuity) |continuation| self.source_continuity_manager.?.bind(continuation);
        };
        for (bound[0..commands.len]) |command| if (command.payload == .group_layer) {
            const change = &self.layer_changes[command.payload.group_layer.change.index];
            change.scheduled = true;
            change.references += 1;
        };
        for (bound[0..commands.len]) |command| if (self.scheduledStart(command.payload)) |start_group| {
            self.prepared_groups[start_group.index].start_scheduled = true;
        };
        for (bound[0..commands.len]) |command| if (command.payload == .play) {
            const play = command.payload.play;
            self.desired[play.instance.index] = .{ .active = true, .reservation = play.reservation, .scheduled = true, .instance = play.instance, .owner = play.owner, .custody = play.custody, .params = play.params, .revision = self.takeRevision() };
            self.active_count += 1;
        };
        if (preparation_attempt != 0) {
            // Publish only real successful preparation bindings. Each original
            // retain is connected to the sorted immutable block command lifetime.
            for (schedule_slot.block.commands[0..schedule_slot.block.count], 0..) |command, i| if (payloadGroup(command.payload)) |group| {
                const bind_read = self.beginReadinessReconciliation(.schedule_group_bind);
                if (bind_read) |value| {
                    value.parent_attempt = preparation_attempt;
                    value.handle = .{ .index = group.index, .generation = group.generation };
                    value.block = handle;
                    value.command_id = command.identity.command_id;
                    value.ordinal = @intCast(i);
                    value.input_ordinal = command.ordinal;
                    value.returned = true;
                }
                _ = self.finishReadinessReconciliation(bind_read);
            };
            const prepared_read = self.beginReadinessReconciliation(.schedule_prepare);
            if (prepared_read) |value| {
                value.parent_attempt = preparation_attempt;
                value.handle = handle;
                value.block = handle;
                value.command_count = schedule_slot.block.count;
                value.returned = true;
            }
            _ = self.finishReadinessReconciliation(prepared_read);
        }
        preparation_succeeded = true;
        return handle;
    }

    pub fn submitSchedule(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.submitScheduleOwned(handle);
    }
    fn submitScheduleOwned(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!void {
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        const slot = try self.scheduled.getObserved(handle, null);
        const plan = &self.scheduled.plans[slot.plan_index];
        if (plan.cancelled.load(.acquire) or plan.queued_phases != slot.first_phase) return error.InvalidState;
        if (slot.state.cmpxchgStrong(.prepared, .queued, .acq_rel, .acquire) != null) return error.InvalidState;
        slot.queue_refs = 1;
        const submission = if (exactLayerStop(slot.block.commands[0..slot.block.count]) != null or exactGraphStop(slot.block.commands[0..slot.block.count]) != null or try self.exactDuckStop(slot.block.commands[0..slot.block.count])) self.submitLayerStop(handle) else self.submit(.{ .scheduled = handle }, false);
        submission catch |err| {
            slot.queue_refs = 0;
            slot.state.store(.prepared, .release);
            return err;
        };
        plan.queued_phases += slot.phase_count;
    }

    /// Accepted does not mean effective. Only the render-produced intent receipt
    /// establishes which phase claim won. Prepared cancellation is local.
    pub fn cancelSchedule(self: *ControlRuntime, value: scheduler.Invalidation) RuntimeError!?scheduler.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);

        return self.cancelScheduleOwned(value);
    }
    fn cancelScheduleOwned(self: *ControlRuntime, value: scheduler.Invalidation) RuntimeError!?scheduler.Handle {
        const observed_frame = self.scheduled.render_frame.load(.acquire);
        if (value.requested_frame > observed_frame) return error.InvalidArgument;
        const target_slot: ?*Scheduler.Slot = if (value.plan_target == null) try self.scheduled.getObserved(value.target, null) else null;
        if (target_slot != null and try self.scheduled.localCancellationAllowed(value.target)) {
            try self.scheduled.cancelPrepared(value.target, value.requested_frame, observed_frame);
            return null;
        }
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        hashInt(&h, value.target.generation);
        hashInt(&h, @as(u64, value.target.index));
        hashInt(&h, value.requested_frame);
        hashInt(&h, value.next_transport_epoch);
        hashInt(&h, value.next_asset_generation);
        hashInt(&h, @as(u64, @intFromBool(value.emergency_stop_music)));
        hashInt(&h, @intFromBool(value.plan_target != null));
        if (value.plan_target) |target| {
            hashInt(&h, target.index);
            hashInt(&h, target.generation);
        }
        var hash: [32]u8 = undefined;
        h.final(&hash);
        const handle = try self.scheduled.prepareInvalidation(value, hash);
        self.submit(.{ .invalidate = handle }, true) catch |err| {
            if (target_slot) |slot| slot.invalidation_refs -= 1;
            const intent = &self.scheduled.intents[handle.index];
            self.scheduled.plans[intent.plan_index].intent_refs -= 1;
            intent.state.store(0, .release);
            return err;
        };
        return handle;
    }

    pub fn schedulePlan(self: *ControlRuntime, block: scheduler.Handle) RuntimeError!scheduler.Handle {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.scheduled.planHandle(block);
    }
    pub fn pollPlanPhase(self: *ControlRuntime, handle: scheduler.Handle, cursor: *u16) RuntimeError!?music.PhaseReceipt {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.pollPlanPhaseOwned(handle, cursor);
    }
    fn pollPlanPhaseOwned(self: *ControlRuntime, handle: scheduler.Handle, cursor: *u16) RuntimeError!?music.PhaseReceipt {
        const read = self.beginReadinessAcquisition(.plan_phase, handle, cursor.*);
        defer self.finishReadinessAcquisition(read);
        errdefer |err| if (read) |value| {
            value.error_code = @intFromError(err);
        };
        const plan = try self.scheduled.getPlan(handle);
        if (read) |value| {
            value.plan = handle;
            value.token = plan.token;
        }
        self.causalReplay(.{ .site = .plan_phase, .edge = .before, .index = handle.index, .generation = handle.generation });
        const count = plan.executed_count.load(.acquire);
        self.causalReplay(.{ .site = .plan_phase, .edge = .after, .index = handle.index, .generation = handle.generation, .value = count });
        if (read) |value| {
            value.observed = count;
            value.reached = true;
        }
        if (cursor.* >= count) return null;
        var token = plan.token;
        token.phase_id = plan.phase_ids[cursor.*];
        const result: music.PhaseReceipt = .{ .token = token, .outcome = .executed, .effective_frame = plan.executed_frames[cursor.*] };
        cursor.* += 1;
        if (read) |value| {
            value.token = result.token;
            value.cursor_after = cursor.*;
            value.returned = true;
            value.result_id = result.token.phase_id.value();
            value.effective_frame = result.effective_frame;
        }
        return result;
    }

    /// Live observation, safe while Render appends later immutable records.
    /// The caller keeps a per-block cursor; observing never frees the block.
    /// Control-owner reconciliation point, not a pure getter: acquiring an M2
    /// installation receipt releases that successor's predecessor reservation.
    /// The normal Control serialization guard applies; Render never calls this.
    pub fn pollExecutionReceipt(self: *ControlRuntime, handle: scheduler.Handle, cursor: *u16) RuntimeError!?scheduler.trace.ScheduleRecord {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.pollExecutionReceiptOwned(handle, cursor);
    }
    fn pollExecutionReceiptOwned(self: *ControlRuntime, handle: scheduler.Handle, cursor: *u16) RuntimeError!?scheduler.trace.ScheduleRecord {
        const read = self.beginReadinessAcquisition(.execution_receipt, handle, cursor.*);
        defer self.finishReadinessAcquisition(read);
        errdefer |err| if (read) |value| {
            value.error_code = @intFromError(err);
        };
        const slot = try self.scheduled.getObserved(handle, if (read) |value| &value.validation_state else null);
        self.bindReadinessBlock(read, slot);
        self.causalReplay(.{ .site = .execution_receipt, .edge = .before, .index = handle.index, .generation = handle.generation });
        const count = slot.published_receipts.load(.acquire);
        self.causalReplay(.{ .site = .execution_receipt, .edge = .after, .index = handle.index, .generation = handle.generation, .value = count });
        if (read) |value| {
            value.observed = count;
            value.reached = true;
        }
        if (cursor.* >= count) return null;
        const record = slot.receipts[cursor.*];
        const command = slot.block.commands[cursor.*];
        if (command.payload == .group_layer_automation) self.layer_manager.?.reconcileInstall(command.payload.group_layer_automation.program);
        if (command.payload == .graph_source_program) self.graph_clock_manager.?.reconcileInstall(command.payload.graph_source_program.program);
        cursor.* += 1;
        if (read) |value| {
            value.cursor_after = cursor.*;
            value.returned = true;
            value.result_id = record.command_id;
            value.effective_frame = record.effective_frame;
        }
        return record;
    }

    pub fn scheduleAdmission(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!?scheduler.trace.Admission {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.scheduleAdmissionOwned(handle);
    }
    fn scheduleAdmissionOwned(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!?scheduler.trace.Admission {
        const read = self.beginReadinessAcquisition(.schedule_admission, handle, 0);
        defer self.finishReadinessAcquisition(read);
        errdefer |err| if (read) |value| {
            value.error_code = @intFromError(err);
        };
        const slot = try self.scheduled.getObserved(handle, if (read) |value| &value.validation_state else null);
        self.bindReadinessBlock(read, slot);
        self.causalReplay(.{ .site = .schedule_admission, .edge = .before, .index = handle.index, .generation = handle.generation });
        const state = slot.state.load(.acquire);
        self.causalReplay(.{ .site = .schedule_admission, .edge = .after, .index = handle.index, .generation = handle.generation, .value = @intFromEnum(state) });
        if (read) |value| {
            value.observed = @intFromEnum(state);
            value.reached = true;
        }
        if (state == .prepared or state == .queued or state == .published) return null;
        const result = slot.admission;
        if (read) |value| if (result) |admission| {
            value.returned = true;
            value.result_id = admission.gate;
            value.effective_frame = admission.frame;
        };
        return result;
    }

    /// Control-owner observation and reconciliation, not a pure getter.
    /// Acquiring a terminal block also drops any M2 successor reservation on
    /// its predecessor. It does not release either program, group, or block;
    /// explicit release APIs still require their own completed-frontier checks.
    pub fn scheduleResult(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!?ScheduleResult {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.scheduleResultOwned(handle);
    }
    fn scheduleResultOwned(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!?ScheduleResult {
        const read = self.beginReadinessAcquisition(.schedule_result, handle, 0);
        defer self.finishReadinessAcquisition(read);
        errdefer |err| if (read) |value| {
            value.error_code = @intFromError(err);
        };
        const slot = try self.scheduled.getObserved(handle, if (read) |value| &value.validation_state else null);
        self.bindReadinessBlock(read, slot);
        self.causalReplay(.{ .site = .schedule_result, .edge = .before, .index = handle.index, .generation = handle.generation });
        const state = slot.state.load(.acquire);
        self.causalReplay(.{ .site = .schedule_result, .edge = .after, .index = handle.index, .generation = handle.generation, .value = @intFromEnum(state) });
        if (read) |value| {
            value.observed = @intFromEnum(state);
            value.reached = true;
        }
        if (state != .terminal) return null;
        for (slot.block.commands[0..slot.block.count]) |command| if (command.payload == .group_layer_automation) self.layer_manager.?.reconcileInstall(command.payload.group_layer_automation.program);
        for (slot.block.commands[0..slot.block.count]) |command| if (command.payload == .graph_source_program) self.graph_clock_manager.?.reconcileInstall(command.payload.graph_source_program.program);
        if (read) |value| {
            value.returned = true;
            value.result_count = slot.receipt_count;
        }
        return .{ .disposition = slot.disposition, .admission = slot.admission, .cancellation = slot.cancellation, .receipts = slot.receipts, .count = slot.receipt_count };
    }

    /// Control acknowledgement returns capacity and releases block-only leases.
    /// Executed voices keep independent desired/render pins until completion.
    pub fn releaseSchedule(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.releaseScheduleOwned(handle);
    }

    fn releaseScheduleOwned(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!void {
        self.scheduled.reconcilePrepared();
        var read = self.beginReadinessReconciliation(.schedule_release);
        defer _ = self.finishReadinessReconciliation(read);
        errdefer |err| if (read) |value| {
            value.error_code = @intFromError(err);
        };
        if (read) |value| value.handle = handle;
        const slot = try self.scheduled.getObserved(handle, if (read) |value| &value.validation_state else null);
        self.causalReplay(.{ .site = .schedule_release, .edge = .before, .index = handle.index, .generation = handle.generation });
        const state = slot.state.load(.acquire);
        self.causalReplay(.{ .site = .schedule_release, .edge = .after, .index = handle.index, .generation = handle.generation, .value = @intFromEnum(state) });
        if (read) |value| value.terminal_state = state;
        if (state != .terminal) return error.InvalidState;
        const invalidation_refs = slot.invalidation_refs;
        if (read) |value| value.invalidation_refs = invalidation_refs;
        if (invalidation_refs != 0) return error.InvalidState;
        const queue_refs = slot.queue_refs;
        if (read) |value| value.queue_refs = queue_refs;
        if (queue_refs != 0) return error.InvalidState;
        const release_attempt = self.finishReadinessReconciliation(read);
        read = null;
        for (slot.block.commands[0..slot.block.count], 0..) |command, i| if (command.payload == .group_layer_automation) {
            if (slot.receipts[i].result != .success) self.layer_manager.?.rejectInstall(command.payload.group_layer_automation.program, slot.receipts[i].effective_frame);
            try self.layer_manager.?.canReleaseInstall(command.payload.group_layer_automation.program, self.scheduled.render_frame.load(.acquire));
        };
        for (slot.block.commands[0..slot.block.count], 0..) |command, i| if (command.payload == .graph_source_program) {
            if (slot.receipts[i].result != .success) self.graph_clock_manager.?.rejectInstall(command.payload.graph_source_program.program, slot.receipts[i].effective_frame);
            try self.graph_clock_manager.?.canReleaseInstall(command.payload.graph_source_program.program, self.scheduled.render_frame.load(.acquire));
        };
        for (slot.block.commands[0..slot.block.count], 0..) |command, i| if (try self.trackedDuck(command.payload)) |tracked| if (tracked.kind == .begin) {
            const cell = &(try self.bus_manager.?.ducks.get(tracked.handle)).cell;
            if (slot.receipts[i].result != .success and cell.state.load(.acquire) == .bound) cell.publish(.begin_rejected, slot.receipts[i].effective_frame, slot.receipts[i].effective_frame);
            if (cell.observe(self.scheduled.render_frame.load(.acquire)) == null) return error.DuckDrainPending;
        };
        for (slot.block.commands[0..slot.block.count], 0..) |command, i| if (transactionCommand(command.payload) != null) {
            try self.reconcileResidentCommand(slot, i);
            if (!slot.transaction_reconciled[i]) return error.DrainPending;
        };
        self.reconcileSchedule(slot);
        for (slot.block.commands[0..slot.block.count], 0..) |command, i| {
            if (try self.trackedDuck(command.payload)) |tracked| self.bus_manager.?.ducks.releaseCommand(tracked, slot.receipts[i].result == .success, slot.receipts[i].effective_frame);
            switch (command.payload) {
                .group_layer_automation => |v| self.layer_manager.?.releaseCommand(v.program, false),
                .group_layer_automation_stop => |v| self.layer_manager.?.releaseCommand(v.program, true),
                .graph_source_program => |v| self.graph_clock_manager.?.releaseCommand(v.program, false),
                .graph_source_program_stop => |v| self.graph_clock_manager.?.releaseCommand(v.program, true),
                else => {},
            }
            self.releaseBusPayload(command.payload);
            if (command.payload == .group_layer) self.layer_changes[command.payload.group_layer.change.index].references -= 1;
            if (command.payload == .play) releasePlayOwner(command.payload.play.owner, command.payload.play.block_custody);
            if (payloadGroup(command.payload)) |group_handle| {
                const resource_read = self.beginReadinessReconciliation(.schedule_group_return);
                const group = &self.prepared_groups[group_handle.index];
                const references = group.references;
                if (resource_read) |value| {
                    value.parent_attempt = release_attempt;
                    value.handle = .{ .index = group_handle.index, .generation = group_handle.generation };
                    value.block = handle;
                    value.command_id = command.identity.command_id;
                    value.input_ordinal = command.ordinal;
                    value.references = references;
                    value.ordinal = @intCast(i);
                }
                group.references = references - 1;
                if (resource_read) |value| {
                    value.references_after = references - 1;
                    value.returned = true;
                }
                _ = self.finishReadinessReconciliation(resource_read);
            }
        }
        for (slot.block.commands[0..slot.block.count], 0..) |command, i| if (command.payload == .group_pause) {
            if (command.payload.group_pause.continuity) |continuation| {
                const manager = self.source_continuity_manager.?;
                const entry = try manager.get(continuation);
                const succeeded = slot.receipts[i].result == .success;
                manager.acknowledge(continuation, succeeded);
                if (succeeded and !entry.desc.paused) {
                    const group = &self.prepared_groups[entry.desc.group.index];
                    // An original resume may finish before the fallback switch
                    // but be acknowledged afterward. Keep its lease for explicit
                    // old-source retirement; never re-adopt it as current.
                    const switched = group.source_switch.read();
                    if (switched == null or entry.desc.source_incarnation == switched.?.source_incarnation) {
                        if (group.source_ownership.current_continuity) |prior| {
                            const old = try manager.get(prior);
                            if (old.desc.source_incarnation == entry.desc.source_incarnation) try manager.retire(prior, entry.coordinate.frame);
                        } else if (entry.desc.source_incarnation == 1) group.source_ownership.initial_retire_frame = entry.coordinate.frame;
                        group.source_ownership.current_continuity = continuation;
                    }
                } else {
                    if (succeeded) entry.retired_frame = entry.coordinate.frame;
                    if (!succeeded) try self.releaseMusicContinuityOwned(continuation);
                }
            }
        };
        try self.scheduled.acknowledge(handle);
        self.reconcileLayerChanges();
        self.collectContinuityLeases();
    }

    fn reconcileSchedule(self: *ControlRuntime, slot: *Scheduler.Slot) void {
        if (slot.reconciled) return;
        for (slot.block.commands[0..slot.block.count], 0..) |command, i| if (self.trackedDuck(command.payload) catch unreachable) |tracked| if (tracked.kind == .begin and slot.receipts[i].result != .success) {
            const cell = &(self.bus_manager.?.ducks.get(tracked.handle) catch unreachable).cell;
            if (cell.state.load(.acquire) == .bound) cell.publish(.begin_rejected, slot.receipts[i].effective_frame, slot.receipts[i].effective_frame);
        };
        for (slot.block.commands[0..slot.block.count]) |command| if (command.payload == .group_layer_automation) self.layer_manager.?.reconcileInstall(command.payload.group_layer_automation.program);
        for (slot.block.commands[0..slot.block.count]) |command| if (command.payload == .graph_source_program) self.graph_clock_manager.?.reconcileInstall(command.payload.graph_source_program.program);
        for (slot.block.commands[0..slot.block.count], 0..) |command, i| if (command.payload == .group_layer_automation and slot.receipts[i].result != .success) {
            self.layer_manager.?.rejectInstall(command.payload.group_layer_automation.program, slot.receipts[i].effective_frame);
        };
        for (slot.block.commands[0..slot.block.count], 0..) |command, i| if (command.payload == .graph_source_program and slot.receipts[i].result != .success) {
            self.graph_clock_manager.?.rejectInstall(command.payload.graph_source_program.program, slot.receipts[i].effective_frame);
        };
        for (slot.block.commands[0..slot.block.count], 0..) |*command, i| {
            if (transactionCommand(command.payload) != null) continue;
            for (self.scheduledPlays(&command.payload)) |play| {
                if (slot.receipts[i].result != .success) {
                    const state = &self.desired[play.instance.index];
                    if (state.active and state.scheduled and state.instance.eql(play.instance) and state.reservation == play.reservation) {
                        releasePlayOwner(state.owner, state.custody);
                        state.* = .{};
                        self.active_count -= 1;
                        self.finish(play.instance, .rejected);
                    }
                }
            }
        }
        for (slot.block.commands[0..slot.block.count], 0..) |command, i| if (command.payload == .group_layer) {
            const change = &self.layer_changes[command.payload.group_layer.change.index];
            change.settled = true;
            change.succeeded = slot.receipts[i].result == .success;
            if (!change.succeeded) {
                change.real_reserved = false;
                change.virtual_reserved = false;
            }
            var event = self.voiceEvent(change.group.generation, change.change.ticket.layer);
            event.frame = slot.receipts[i].effective_frame;
            event.sequence = command.sequence;
            event.transport_epoch = command.identity.token.transport_epoch.value();
            event.asset_generation = command.identity.token.asset_generation.value();
            event.from_state = @enumFromInt(@intFromEnum(change.from_state));
            event.to_state = if (change.succeeded) @enumFromInt(@intFromEnum(change.change.target)) else event.from_state;
            event.reason = if (change.succeeded) .none else if (slot.receipts[i].reason == .late) .late_prepare else if (slot.receipts[i].reason == .target_not_resident) .unrealizable else .stale_ticket;
            self.recordVoiceEvent(event);
        };
        slot.reconciled = true;
    }

    pub fn cancellationResult(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!?CancellationResult {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        return self.cancellationResultOwned(handle);
    }

    fn cancellationResultOwned(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!?CancellationResult {
        var read = self.beginReadinessAcquisition(.cancellation_result, handle, 0);
        defer self.finishReadinessAcquisition(read);
        errdefer |err| if (read) |value| {
            value.error_code = @intFromError(err);
        };
        if (read) |value| value.cell = .{ .cancellation = .{} };
        if (handle.index >= scheduler.emergency_capacity) return error.InvalidState;
        const intent = &self.scheduled.intents[handle.index];
        // Preserve the original generation-before-state short circuit and its
        // two independent acquires, even when they see different publications.
        if (intent.generation != handle.generation) return error.InvalidState;
        const first_state = intent.state.load(.acquire);
        if (read) |value| value.cell.cancellation.first_state = first_state;
        if (first_state == 0) return error.InvalidState;
        if (read) |value| {
            value.plan = .{ .index = intent.plan_index, .generation = self.scheduled.plans[intent.plan_index].generation };
            value.token = intent.token;
            value.batch_id = intent.batch_id;
            value.content_hash = intent.content_hash;
            value.cell.cancellation.target = .{ .index = intent.value.target.index, .generation = intent.value.target.generation };
        }
        const state = intent.state.load(.acquire);
        if (read) |value| {
            value.cell.cancellation.second_state = state;
            value.observed = state;
            value.reached = true;
        }
        if (state != 3) return null;
        const result: CancellationResult = .{ .admission = intent.admission.?, .receipt = intent.receipt.? };
        if (read) |value| {
            // Copy the genuine acquired result before any reference release.
            value.cell.cancellation.receipt = scheduler.render_observation.TooLateReceipt.from(result.receipt);
            value.result_id = @intFromEnum(result.receipt.kind);
            value.effective_frame = result.receipt.effective_frame;
            value.result_count = @intCast(result.receipt.executed_prefix_count);
        }
        if (intent.target_has_slot) {
            const slot = try self.scheduled.getObserved(intent.value.target, if (read) |value| &value.validation_state else null);
            std.debug.assert(slot.invalidation_refs != 0);
            slot.invalidation_refs -= 1;
        }
        const plan = &self.scheduled.plans[intent.plan_index];
        std.debug.assert(plan.intent_refs != 0);
        plan.intent_refs -= 1;
        intent.state.store(0, .release);
        if (self.scheduled.control_sink != null) {
            // The result and intent references are already returned. Close
            // this single scratch record before nested observed plan reaping.
            if (read) |value| {
                value.returned = true;
                value.cell.cancellation.released = true;
            }
            self.finishReadinessAcquisition(read);
            read = null;
        }
        self.scheduled.reapPlan(plan);
        if (read) |value| {
            value.returned = true;
            value.cell.cancellation.released = true;
        }
        return result;
    }

    /// Earliest uncommitted Render frontier for a non-mutating ordered fence.
    pub fn residentCaptureFrame(self: *const ControlRuntime) RuntimeError!u64 {
        return self.scheduled.commit_horizon.load(.acquire);
    }

    pub fn earliestPlanFrame(self: *const ControlRuntime) RuntimeError!u64 {
        // This existing read helper is also callable outside an integrated tick.
        // Check atomic scope/thread first, before any plain observer/phase read.
        // Such outside calls stay uncovered; they are never attached to a tick.
        const serial = self.tick_v1.active.load(.acquire);
        const in_tick = serial != 0 and self.tick_v1.thread.load(.acquire) == std.Thread.getCurrentId();
        if (in_tick) self.controlFrontierHook(.before_plan_horizon);
        self.causalReplay(.{ .site = .control_horizon, .edge = .before });
        const horizon = self.scheduled.commit_horizon.load(.acquire);
        self.causalReplay(.{ .site = .control_horizon, .edge = .after, .value = horizon });
        const result = std.math.add(u64, horizon, scheduler.default_profile.min_plan_lead_frames + scheduler.default_profile.late_race_budget_frames) catch {
            if (in_tick) self.observeControlPlanFrontier(serial, horizon, null);
            return error.UnsafeFrameRange;
        };
        if (in_tick) self.observeControlPlanFrontier(serial, horizon, result);
        return result;
    }
    fn observeControlPlanFrontier(self: *const ControlRuntime, serial: u64, horizon: u64, result: ?u64) void {
        if (self.control_frontier_binding) |binding| binding.bridge.observePlan(binding.session, serial, self.tick_v1.phase, horizon, scheduler.default_profile.min_plan_lead_frames, scheduler.default_profile.late_race_budget_frames, result);
    }
    fn controlFrontierHook(self: *const ControlRuntime, stage: ControlFrontierStage) void {
        if (@import("builtin").is_test) if (self.test_control_frontier_hook) |hook| hook.call(hook.context, stage);
    }

    /// Host lifecycle: no simultaneous consumer/request/lifecycle caller, and
    /// stable owner/Bridge storage. The Control guard excludes active producer
    /// calls. Render may continue; its witness has separate quiescence rules.
    pub fn attachControlFrontierWitness(self: *ControlRuntime, bridge: *control_frontier_witness.Bridge, interval_id: u64) !control_frontier_witness.Session {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (self.control_frontier_binding != null or self.tick_v1.active.load(.acquire) != 0) return error.InvalidState;
        const owner = self.music_runtime orelse return error.InvalidState;
        if (!owner.usesIntegratedTickV1()) return error.InvalidState;
        if (try bridge.continuousSession()) |continuous| try capture_handoff_control.validateAttachment(continuous, .frontier, interval_id);
        if (self.stream_acceptance_binding) |peer| try capture_handoff_control.validatePeers(try bridge.continuousSession(), try peer.bridge.continuousSession());
        if (self.control_frontier_owner_identity == 0) self.control_frontier_owner_identity = try control_frontier_witness.allocateOwnerIdentity();
        const session = try bridge.attachAtBoundary(self, self.control_frontier_owner_identity, interval_id);
        self.control_frontier_binding = .{ .bridge = bridge, .session = session };
        return session;
    }
    /// A real idle Control boundary, including when no subsequent tick occurs.
    /// Closure is not detachment and does not release any owner lifetime.
    pub fn closeControlFrontierWitness(self: *ControlRuntime, session: control_frontier_witness.Session) !void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (self.tick_v1.active.load(.acquire) != 0) return error.InvalidState;
        if (self.readiness_binding != null) return error.DrainPending;
        const binding = self.control_frontier_binding orelse return error.InvalidState;
        if (!std.meta.eql(binding.session, session)) return error.StaleSession;
        try binding.bridge.closeAtBoundary(session, self);
    }
    /// Requires host consumer/request exclusion as well as the acquired Control
    /// guard. All events must be drained and closure acknowledged before reuse.
    pub fn detachControlFrontierWitness(self: *ControlRuntime, session: control_frontier_witness.Session) !void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (self.tick_v1.active.load(.acquire) != 0) return error.InvalidState;
        if (self.render_causal_attached or self.readiness_binding != null) return error.DrainPending;
        const binding = self.control_frontier_binding orelse return error.InvalidState;
        if (!std.meta.eql(binding.session, session)) return error.StaleSession;
        try binding.bridge.detachAtBoundary(session, self);
        self.control_frontier_binding = null;
    }

    /// Host lifecycle: no simultaneous consumer/request/lifecycle caller, and
    /// stable owner/Bridge storage. The Control guard excludes active producer
    /// calls. Render may continue; its witness has separate quiescence rules.
    pub fn attachStreamAcceptanceWitness(self: *ControlRuntime, bridge: *stream_acceptance_witness.Bridge, interval_id: u64) !stream_acceptance_witness.Session {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (self.stream_acceptance_binding != null or self.tick_v1.active.load(.acquire) != 0) return error.InvalidState;
        const owner = self.music_runtime orelse return error.InvalidState;
        if (!owner.usesIntegratedTickV1()) return error.InvalidState;
        if (try bridge.continuousSession()) |continuous| try capture_handoff_control.validateAttachment(continuous, .acceptance, interval_id);
        if (self.control_frontier_binding) |peer| try capture_handoff_control.validatePeers(try bridge.continuousSession(), try peer.bridge.continuousSession());
        if (self.stream_acceptance_owner_identity == 0) self.stream_acceptance_owner_identity = try stream_acceptance_witness.allocateOwnerIdentity();
        const session = try bridge.attachAtBoundary(self, self.stream_acceptance_owner_identity, interval_id);
        self.stream_acceptance_binding = .{ .bridge = bridge, .session = session };
        return session;
    }
    /// A real idle Control boundary, including when no subsequent tick occurs.
    /// Closure is not detachment and does not release any owner lifetime.
    pub fn closeStreamAcceptanceWitness(self: *ControlRuntime, session: stream_acceptance_witness.Session) !void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (self.tick_v1.active.load(.acquire) != 0) return error.InvalidState;
        if (self.readiness_binding != null) return error.DrainPending;
        const binding = self.stream_acceptance_binding orelse return error.InvalidState;
        if (!std.meta.eql(binding.session, session)) return error.StaleSession;
        try binding.bridge.closeAtBoundary(session, self);
    }
    /// Requires host consumer/request exclusion as well as the acquired Control
    /// guard. All events must be drained and closure acknowledged before reuse.
    pub fn detachStreamAcceptanceWitness(self: *ControlRuntime, session: stream_acceptance_witness.Session) !void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (self.tick_v1.active.load(.acquire) != 0) return error.InvalidState;
        if (self.render_causal_attached or self.readiness_binding != null) return error.DrainPending;
        const binding = self.stream_acceptance_binding orelse return error.InvalidState;
        if (!std.meta.eql(binding.session, session)) return error.StaleSession;
        try binding.bridge.detachAtBoundary(session, self);
        self.stream_acceptance_binding = null;
    }

    /// Internal finite join: genuine renderer quiescence, idle Control, exact
    /// current peers and Music/Service owners. No host-supplied identity hashes.
    pub fn attachReadinessWitness(self: *ControlRuntime, bridge: *readiness_witness.Bridge, renderer: *RuntimeRenderer, token: RuntimeRenderer.DeviceQuiescence, interval_id: u64) !readiness_witness.Session {
        if (@import("builtin").is_test) if (self.test_owned_control_facts != null) return error.InvalidState;
        try renderer.validateDeviceQuiescence(token);
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        if (self.readiness_binding != null or self.tick_v1.active.load(.acquire) != 0 or renderer.runtime != self) return error.InvalidState;
        const owner = self.music_runtime orelse return error.InvalidState;
        if (owner.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer owner.control_guard.store(false, .release);
        if (owner.control != self or owner.renderer != renderer or !owner.usesIntegratedTickV1() or owner.control_torn_down) return error.InvalidState;
        const generation = owner.generation orelse return error.InvalidState;
        const service = self.streaming_service orelse return error.InvalidState;
        if (generation.service != service or service.replay_mode or service.readiness_attached or service.readiness_supply_sink != null or service.readiness_lifecycle_sink != null or self.scheduled.control_sink != null) return error.InvalidState;
        const f = self.control_frontier_binding orelse return error.InvalidState;
        const a = self.stream_acceptance_binding orelse return error.InvalidState;
        const r = renderer.render_causal_binding orelse return error.InvalidState;
        if (f.session.interval_id != interval_id or a.session.interval_id != interval_id or r.session.interval_id != interval_id or r.music_owner != owner) return error.StaleSession;
        try capture_handoff_control.validatePeers(try bridge.continuousSession(), try f.bridge.continuousSession());
        try capture_handoff_control.validatePeers(try bridge.continuousSession(), try a.bridge.continuousSession());
        try capture_handoff_control.validatePeers(try bridge.continuousSession(), try r.bridge.continuousSession());
        if (try bridge.continuousSession()) |continuous| try capture_handoff_control.validateAttachment(continuous, .readiness, interval_id);
        const fs = try f.bridge.status(f.session);
        const as = try a.bridge.status(a.session);
        const rs = try r.bridge.status(r.session);
        if (fs.closed or fs.incomplete or as.closed or as.incomplete or rs.closed or rs.incomplete) return error.InvalidState;
        const fpeer: readiness_witness.Peer = .{ .incarnation = f.session.incarnation, .generation = f.session.generation, .owner_identity = f.session.owner_identity, .interval_id = interval_id };
        const apeer: readiness_witness.Peer = .{ .incarnation = a.session.incarnation, .generation = a.session.generation, .owner_identity = a.session.owner_identity, .interval_id = interval_id };
        if (!std.meta.eql(r.bridge.manifest.control_frontier, fpeer) or !std.meta.eql(r.bridge.manifest.stream_acceptance, apeer)) return error.StaleSession;
        const call = renderer.callObservation();
        if (call.exhausted or call.sequence & 1 != 0) return error.InvalidState;
        const manifest: readiness_witness.Manifest = .{ .interval_id = interval_id, .control_frontier = fpeer, .stream_acceptance = apeer, .render_incarnation = r.session.incarnation, .render_generation = r.session.generation, .renderer_identity = r.session.renderer_identity, .music_handle_incarnation = owner.handle_incarnation, .music_context = owner.config.context, .transport_epoch = self.scheduled.transport_epoch, .asset_generation = self.scheduled.asset_generation, .bank_hash = generation.loaded.content_hash, .profile_hash = service.profile.hash(), .initial_frame = renderer.renderFrame(), .initial_gate = self.scheduled.gate_number, .initial_call_sequence = call.sequence, .initial_observation_sequence = service.observation_sequence.load(.acquire) };
        const session = try bridge.attachAtBoundary(self, manifest, f.bridge, a.bridge);
        self.readiness_binding = .{ .bridge = bridge, .session = session, .renderer = renderer, .render_session = r.session, .frontier_session = f.session, .acceptance_session = a.session, .music_owner = owner, .service = service };
        service.readiness_attached = true;
        if (service.profile.max_streams > 64 or service.profile.job_capacity > 256) bridge.markIncomplete(.representation_bound);
        return session;
    }
    fn validateReadinessPeers(self: *ControlRuntime, binding: ReadinessBinding) !void {
        if (self.music_runtime != binding.music_owner or self.streaming_service != binding.service or binding.renderer.runtime != self or binding.music_owner.renderer != binding.renderer or binding.music_owner.control != self) return error.StaleSession;
        const f = self.control_frontier_binding orelse return error.StaleSession;
        const a = self.stream_acceptance_binding orelse return error.StaleSession;
        const r = binding.renderer.render_causal_binding orelse return error.StaleSession;
        if (!std.meta.eql(f.session, binding.frontier_session) or !std.meta.eql(a.session, binding.acceptance_session) or !std.meta.eql(r.session, binding.render_session) or r.music_owner != binding.music_owner) return error.StaleSession;
        try capture_handoff_control.validatePeers(try binding.bridge.continuousSession(), try f.bridge.continuousSession());
        try capture_handoff_control.validatePeers(try binding.bridge.continuousSession(), try a.bridge.continuousSession());
        try capture_handoff_control.validatePeers(try binding.bridge.continuousSession(), try r.bridge.continuousSession());
        const fs = try f.bridge.status(f.session);
        const as = try a.bridge.status(a.session);
        const rs = try r.bridge.status(r.session);
        if (fs.closed or fs.incomplete or as.closed or as.incomplete or rs.closed or rs.incomplete) binding.bridge.markIncomplete(.interrupted);
    }
    pub fn closeReadinessWitness(self: *ControlRuntime, session: readiness_witness.Session, renderer: *RuntimeRenderer, token: RuntimeRenderer.DeviceQuiescence) !void {
        try renderer.validateDeviceQuiescence(token);
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const binding = self.readiness_binding orelse return error.InvalidState;
        if (!std.meta.eql(binding.session, session) or renderer != binding.renderer) return error.StaleSession;
        if (self.tick_v1.active.load(.acquire) != 0 or binding.service.readiness_supply_sink != null or binding.service.readiness_lifecycle_sink != null or self.scheduled.control_sink != null) return error.InvalidState;
        if (binding.music_owner.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer binding.music_owner.control_guard.store(false, .release);
        try self.validateReadinessPeers(binding);
        const call = renderer.callObservation();
        if (call.exhausted) binding.bridge.markIncomplete(.counter_exhausted);
        try binding.bridge.closeAtBoundary(session, self, renderer.renderFrame(), call.sequence, self.scheduled.gate_number, binding.service.observation_sequence.load(.acquire));
    }
    pub fn detachReadinessWitness(self: *ControlRuntime, session: readiness_witness.Session) !void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const binding = self.readiness_binding orelse return error.InvalidState;
        if (!std.meta.eql(binding.session, session)) return error.StaleSession;
        if (self.tick_v1.active.load(.acquire) != 0 or binding.service.readiness_supply_sink != null or binding.service.readiness_lifecycle_sink != null or self.scheduled.control_sink != null) return error.InvalidState;
        if (binding.music_owner.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer binding.music_owner.control_guard.store(false, .release);
        try self.validateReadinessPeers(binding);
        try binding.bridge.detachAtBoundary(session, self);
        binding.service.readiness_attached = false;
        self.readiness_binding = null;
    }

    fn validateScheduledPayload(self: *ControlRuntime, payload: ScheduledPayload) RuntimeError!void {
        switch (payload) {
            .resident_capture, .resident_restore => |v| {
                const slot = try self.resident_transaction_slot.get(v.transaction);
                if (slot.state.load(.acquire) != .prepared or (payload == .resident_capture) != (slot.desc == .capture)) return error.InvalidState;
            },
            .graph_install, .graph_retire => |v| {
                _ = try (self.bus_manager orelse return error.StaleGraph).get(v.graph);
            },
            .graph_source_program, .graph_source_program_stop => |v| {
                const original = try self.preparedGroup(v.group);
                const program = try (self.graph_clock_manager orelse return error.StaleGraphProgram).get(v.program);
                if (payload == .graph_source_program and original.graph_source_replaced.load(.acquire) & (@as(u16, 1) << @intCast(program.desc.progress.tracks[0].ordinal)) != 0) return error.UnsupportedGraphSourceHandoff;
                const a = program.desc.progress.anchor;
                if (a.group.index != v.group.index or a.group.generation != v.group.generation) return error.InvalidGraphProgram;
                const state = program.state.load(.acquire);
                if (payload == .graph_source_program_stop and state != .active and state != .terminal) return error.InvalidGraphProgram;
            },
            .graph_targets => |v| {
                const batch = try (self.bus_manager orelse return error.StaleBatch).batch(v.batch);
                // Reject raw/begin authorization before capacity reservation,
                // retains, batch binding or any scheduler mutation.
                if (v.duck_cleanup) |authorization| try authorization.validateBatch(self, v.batch);
                try self.graphRawConflict(batch.graph, batch.operations[0..batch.count]);
                if (batch.layer_source) |source| {
                    const group = v.group orelse return error.InvalidLayerLane;
                    if (group.index != source.group_index or group.generation != source.group_generation) return error.InvalidLayerLane;
                    const effective = try self.musicGroupSourceOwned(group);
                    if (source.source_incarnation != effective.source_incarnation or source.layer >= effective.layer_count) return error.InvalidLayerLane;
                } else if (v.group != null) return error.InvalidLayerLane;
            },
            .group_bus_route => |v| {
                const group = try self.preparedGroup(v.group);
                const manager = self.bus_manager orelse return error.StaleRoute;
                const route = try manager.route(v.route);
                const source = try self.musicGroupSourceOwned(v.group);
                if (v.source_incarnation != source.source_incarnation) return error.InvalidState;
                try manager.validateLayerRoute(v.route, layerGraphSourceAt(v.group, v.layer, v.source_incarnation), v.ramp_frames);
                if (v.layer >= source.layer_count or v.ramp_frames > 480000 or !channel_layout.ChannelLayout.eql(source.layout, route.prepared.source_layout)) return error.InvalidArgument;
                if (!source.degraded) if (group.prepared.emergency) |emergency| if (!channel_layout.ChannelLayout.eql(emergency.matrix.input, route.prepared.source_layout)) return error.InvalidArgument;
            },
            .play => |v| {
                if (!self.instances.current(v.instance)) return error.StaleInstance;
                try validateVoiceParams(v.params);
                if (v.owner.samples.len == 0 or v.owner.stream_token) return error.InvalidArgument;
            },
            .stop => |v| if (!self.instances.current(v.instance)) return error.StaleInstance,
            .update => |v| {
                if (!self.instances.current(v.instance)) return error.StaleInstance;
                inline for (.{ v.params.gain, v.params.pan, v.params.lowpass_hz, v.params.pitch_ratio, v.params.reverb_send }) |o| if (o) |x| if (!finite(x)) return error.InvalidArgument;
            },
            .bus => |v| if (!finite(v.gain) or v.gain < 0 or v.gain > 4) return error.InvalidArgument,
            .group_start => |start| {
                const slot = try self.preparedGroup(start.group);
                if (!validStartCurve(start.start_curve, slot.prepared.ramp_frames)) return error.InvalidArgument;
                for (slot.plays[0..slot.prepared.voice_count]) |play| if (!self.instances.mayStart(play.instance, play.reservation)) return error.StaleInstance;
            },
            .group_seek => |v| {
                const slot = try self.preparedGroup(v.group);
                const source = try self.musicGroupSourceOwned(v.group);
                const effective = try self.effectivePreparedSource(slot, source.source_incarnation);
                if (effective.hasStreams()) return error.InvalidState;
                if (v.cursor >= effective.frames) return error.InvalidArgument;
            },
            .group_loop => |v| {
                const slot = try self.preparedGroup(v.group);
                const source = try self.musicGroupSourceOwned(v.group);
                const effective = try self.effectivePreparedSource(slot, source.source_incarnation);
                if (effective.hasStreams()) return error.InvalidState;
                if (v.loop) |loop| if (loop.start >= loop.end or loop.end > effective.frames) return error.InvalidArgument;
            },
            .group_gain => |v| {
                _ = try self.preparedGroup(v.group);
                if (!finite(v.gain) or v.gain < 0 or v.gain > 4) return error.InvalidArgument;
            },
            .group_layer => |v| {
                const change = try self.layerChange(v.change);
                if (!change.group.eql(v.group)) return error.InvalidArgument;
            },
            .group_pause => |v| {
                _ = try self.preparedGroup(v.group);
            },
            .group_layer_automation => |v| {
                _ = try self.preparedGroup(v.group);
                const program = try (self.layer_manager orelse return error.StaleLayerProgram).get(v.program);
                if (program.desc.anchor.group.index != v.group.index or program.desc.anchor.group.generation != v.group.generation) return error.InvalidLayerProgram;
            },
            .group_layer_automation_stop => |v| {
                _ = try self.preparedGroup(v.group);
                const program = try (self.layer_manager orelse return error.StaleLayerProgram).get(v.program);
                const state = program.state.load(.acquire);
                if ((state != .active and state != .terminal) or program.desc.anchor.group.index != v.group.index or program.desc.anchor.group.generation != v.group.generation) return error.InvalidLayerProgram;
            },
            .group_layer_gain => |v| {
                const source = try self.musicGroupSourceOwned(v.group);
                if (v.source_incarnation != source.source_incarnation) return error.InvalidState;
                if (v.layer >= source.layer_count or !finite(v.gain) or v.gain < 0 or v.gain > 4) return error.InvalidArgument;
                if (self.layer_manager) |manager| for (&manager.slots) |*program| {
                    const state = program.state.load(.acquire);
                    if (state != .free and state != .terminal and program.desc.anchor.group.index == v.group.index and program.desc.anchor.group.generation == v.group.generation and program.desc.target_mask & (@as(u16, 1) << @intCast(v.layer)) != 0) return error.LayerProgramBusy;
                };
            },
            .group_stop => |v| {
                _ = try self.preparedGroup(v.group);
                if (!validReleaseCurve(v.release_curve, v.release_frames)) return error.InvalidArgument;
            },
        }
    }

    fn delta(self: *ControlRuntime, sequence: u64, payload: DeltaPayload) void {
        // Control reserves a full shutdown fanout before popping ingress.
        const pushed = self.deltas.push(.{ .sequence = sequence, .frame = self.scheduled.commit_horizon.load(.acquire), .payload = payload });
        std.debug.assert(pushed);
    }

    /// Actual monotonic reservation identity frontier, including reservations
    /// subsequently released after a failed submission. The bounded public
    /// recorder uses this owned numeric observation to reject foreign identity
    /// mutations; it never resets or supplies reservation identities.
    pub fn instanceReservationFrontier(self: *const ControlRuntime) u64 {
        return self.instances.next_identity.load(.acquire);
    }

    pub fn reserveInstance(self: *ControlRuntime) RuntimeError!InstanceHandle {
        try self.rejectCausalForeignIngress();
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        const instance = try self.instances.reserve();
        if (!self.accepting.load(.acquire)) {
            self.instances.release(instance);
            return error.RuntimeStopped;
        }
        return instance;
    }

    /// One normal-ingress transaction for adapters. No reserved instance escapes
    /// on validation/owner/queue failure, and accepted playback retains its PCM.
    pub fn submitNewPlay(self: *ControlRuntime, owner: *SampleOwner, params: VoiceParams) RuntimeError!InstanceHandle {
        try self.rejectCausalForeignIngress();
        const instance = try self.reserveInstance();
        errdefer self.instances.release(instance);
        try self.submitPlay(.{ .instance = instance, .owner = owner, .params = params });
        return instance;
    }
    pub fn submitPlay(self: *ControlRuntime, play: PlayCommand) RuntimeError!void {
        try self.rejectCausalForeignIngress();
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        if (!self.instances.current(play.instance)) return error.StaleInstance;
        if (play.owner.stream_token) return error.InvalidArgument;
        try validateVoiceParams(play.params);
        var bound = play;
        bound.custody = null;
        bound.block_custody = null;
        if (play.owner.play_custody == null) {
            // Compatibility-frozen unregistered path and validation ordering.
            try play.owner.retain();
            errdefer play.owner.release();
            bound.reservation = try self.instances.identity(play.instance);
            try self.submit(.{ .play = bound }, false);
            return;
        }
        bound.reservation = try self.instances.identity(play.instance);
        const acquired = try self.retainPlayRoot(bound);
        defer if (acquired.producer) |producer| producer.leave();
        bound.custody = acquired.token;
        errdefer releasePlayOwner(bound.owner, bound.custody);
        try self.submit(.{ .play = bound }, false);
    }

    const RootPlay = struct { token: ?PlayToken, producer: ?PlayCustodyAnchor.Producer };
    fn retainPlayRoot(self: *ControlRuntime, play: PlayCommand) RuntimeError!RootPlay {
        const anchor = play.owner.play_custody orelse {
            try play.owner.retain();
            return .{ .token = null, .producer = null };
        };
        const producer = anchor.enter() catch |err| return playCustodyError(err);
        errdefer producer.leave();
        const reserved = producer.reserve(play.owner, .{ .control = self, .instance_index = play.instance.index, .instance_generation = play.instance.generation, .reservation = play.reservation }) catch |err| return playCustodyError(err);
        play.owner.retain() catch |err| {
            reserved.cancel();
            return err;
        };
        return .{ .token = reserved.publish(), .producer = producer };
    }

    pub fn submitUpdate(self: *ControlRuntime, update: UpdateCommand) RuntimeError!void {
        try self.rejectCausalForeignIngress();
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        if (!self.instances.current(update.instance)) return error.StaleInstance;
        inline for (.{ update.params.gain, update.params.pan, update.params.lowpass_hz, update.params.pitch_ratio, update.params.reverb_send }) |optional| if (optional) |value| if (!finite(value)) return error.InvalidArgument;
        var bound = update;
        bound.reservation = try self.instances.identity(update.instance);
        try self.submit(.{ .update = bound }, false);
    }

    pub fn submitBus(self: *ControlRuntime, bus: BusCommand) RuntimeError!void {
        try self.rejectCausalForeignIngress();
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        if (!finite(bus.gain) or bus.gain < 0 or bus.gain > 4) return error.InvalidArgument;
        try self.submit(.{ .bus = bus }, false);
    }

    pub fn submitStop(self: *ControlRuntime, stop: StopCommand) RuntimeError!void {
        try self.rejectCausalForeignIngress();
        if (!self.instances.current(stop.instance)) return error.StaleInstance;
        var bound = stop;
        bound.reservation = try self.instances.identity(stop.instance);
        try self.submit(.{ .stop = bound }, true);
    }

    pub fn submitShutdown(self: *ControlRuntime) RuntimeError!void {
        try self.rejectCausalForeignIngress();
        self.accepting.store(false, .release);
        if (self.shutdown_submitted.swap(true, .acq_rel)) return;
        self.submit(.{ .shutdown = {} }, true) catch |err| {
            self.shutdown_submitted.store(false, .release);
            return err;
        };
    }

    pub fn stopAccepting(self: *ControlRuntime) void {
        self.rejectCausalForeignIngress() catch return;
        self.accepting.store(false, .release);
    }

    fn rejectCausalForeignIngress(self: *ControlRuntime) RuntimeError!void {
        if (self.music_runtime) |owner| if (owner.causal_sink) |sink| {
            sink.invalidate(sink.context);
            return error.InvalidState;
        };
    }
    fn submit(self: *ControlRuntime, command: Command, use_reserved: bool) RuntimeError!void {
        if (self.music_runtime) |owner| if (!owner.causalLowerCommandAllowedV1(self, command)) return error.InvalidState;
        const pushed = if (use_reserved) self.reserved.push(command, &self.next_sequence) else self.normal.push(command, &self.next_sequence);
        if (!pushed) {
            _ = self.counters.rejected_commands.fetchAdd(1, .monotonic);
            return error.CommandQueueFull;
        }
        _ = self.counters.accepted_commands.fetchAdd(1, .monotonic);
        self.recordHighWater();
    }

    fn submitLayerStop(self: *ControlRuntime, handle: scheduler.Handle) RuntimeError!void {
        if (!self.layer_stop_ingress.push(.{ .scheduled = handle }, &self.next_sequence)) return error.CommandQueueFull;
        _ = self.counters.accepted_commands.fetchAdd(1, .monotonic);
        self.recordHighWater();
    }
    fn recordHighWater(self: *ControlRuntime) void {
        const count: u32 = @intCast(@min(command_capacity, self.normal.count() + self.reserved.count()));
        var current = self.counters.queue_high_water.load(.monotonic);
        while (count > current) current = self.counters.queue_high_water.cmpxchgWeak(current, count, .monotonic, .monotonic) orelse return;
    }

    /// A scoped, checked capability for the already-owned Control tick. It is
    /// invalid outside that tick, on another thread, or after the next serial.
    /// Host schedule methods keep their existing independent guard behavior.
    pub const TickV1 = struct {
        runtime: *ControlRuntime,
        serial: u64,
        pub fn validate(self: TickV1) RuntimeError!void {
            if (self.serial == 0 or self.runtime.tick_v1.active.load(.acquire) != self.serial or self.runtime.tick_v1.thread.load(.acquire) != std.Thread.getCurrentId()) return error.InvalidState;
        }
        pub fn requirePhase(self: TickV1, phase: TickPhaseV1) RuntimeError!void {
            try self.validate();
            if (self.runtime.tick_v1.phase != phase) return error.InvalidState;
        }
        /// The active mode is a scoped fact, not a caller-supplied boolean.
        pub fn liveChronologyTickV1(self: TickV1) RuntimeError!bool {
            try self.validate();
            if (self.runtime.tick_v1.phase != .collect and self.runtime.tick_v1.phase != .accept) return error.InvalidState;
            return self.runtime.tick_v1.live_chronology;
        }
        pub fn observeLiveFrontierV1(self: TickV1, observed: u64, effective: u64) RuntimeError!void {
            if (!try self.liveChronologyTickV1()) return;
            if (self.runtime.tick_v1.live_acceptance_sink) |sink| if (sink.frontier) |emit|
                emit(sink.context, self.runtime.tick_v1.phase, observed, effective);
        }
        /// The owner calls this only from its already-guarded retained-Input
        /// fanout. No observer-only atomics or other shared reads are added.
        pub fn observeLiveInputV1(self: TickV1, value: music.trace.Input) void {
            if (self.runtime.tick_v1.live_acceptance_sink) |sink| if (sink.input) |emit| emit(sink.context, value);
        }
        /// Read-only capability for the new entry; callers cannot assign a
        /// frame through this seam. Ordinary ticks are deliberately rejected.
        pub fn liveAcceptanceFrameV1(self: TickV1) RuntimeError!u64 {
            try self.requirePhase(.accept);
            if (!self.runtime.tick_v1.live_chronology) return error.InvalidState;
            return self.runtime.tick_v1.frame;
        }
        fn requireWorkPhase(self: TickV1) RuntimeError!void {
            try self.validate();
            if (self.runtime.tick_v1.phase != .collect and self.runtime.tick_v1.phase != .prepare) return error.InvalidState;
        }
        pub fn position(self: TickV1, frame: u64) RuntimeError!scheduler.trace.Position {
            try self.validate();
            if (self.runtime.tick_v1.phase != .collect and self.runtime.tick_v1.phase != .accept and self.runtime.tick_v1.phase != .prepare) return error.InvalidState;
            const result: scheduler.trace.Position = .{ .accepted_control_frame = frame, .control_tick = self.runtime.stream_control_tick, .input_order = self.runtime.stream_input_order };
            self.runtime.stream_input_order += 1;
            return result;
        }
        /// The Music collector's actual frame acquire, observed in the same
        /// joined interval as its independent receipt and durable-cell reads.
        pub fn collectionFrame(self: TickV1, kind: readiness_witness.AcquisitionKind) RuntimeError!u64 {
            try self.requirePhase(.collect);
            switch (kind) {
                .collect_frame, .receipts_frame, .phase_frame => {},
                else => return error.InvalidArgument,
            }
            return self.runtime.collectionFrameOwned(kind);
        }
        /// Initial owner adoption only; later live replacement needs an
        /// execution-fenced protocol, not this context attachment operation.
        pub fn attachStreaming(self: TickV1, service: *streaming.Service, inputs: ?*StreamingInputRing) RuntimeError!void {
            try self.requirePhase(.collect);
            return self.runtime.attachStreamingOwned(service, inputs);
        }
        /// Receipt acquisition for the public streamed profile's bounded merge.
        /// Positions are assigned only after all actual admissions are acquired.
        pub fn pollStreamVisibility(self: TickV1) RuntimeError!?music.trace.schema.Admission {
            try self.requirePhase(.collect);
            const service = self.runtime.streaming_service orelse return error.InvalidState;
            return service.pollVisibility();
        }
        /// Exact recorded acceptance under the already-owned Control guard.
        /// Worker has genuinely decoded into bounded staging before this tick.
        pub fn acceptStreamReplay(self: TickV1, input: music.trace.Input) !void {
            try self.requirePhase(.accept);
            const control = self.runtime;
            const service = control.streaming_service orelse return error.InvalidState;
            const accepted_position: scheduler.trace.Position = .{ .accepted_control_frame = control.tick_v1.frame, .control_tick = control.stream_control_tick, .input_order = control.stream_input_order };
            if (!service.replay_mode or input.payload != .worker or !std.meta.eql(input.position, accepted_position)) return error.ReplayMismatch;
            const worker = input.payload.worker;
            try music.trace.replay.verifyJobDescriptor(worker, try service.computedJobDescriptor(worker.job));
            if (worker.state == .ready) try music.trace.replay.verifyPcm(worker, try service.preparePcm(worker));
            if (control.scheduled.next_batch_id == std.math.maxInt(u64)) return error.InvalidState;
            const accepted = try service.acceptReplayWithBatch(input, control.scheduled.next_batch_id);
            control.scheduled.next_batch_id += 1;
            control.stream_input_order += 1;
            control.recordStreamingInputOwned(accepted.input);
        }
        /// Checked collector access is prepare-only. It cannot acquire a second
        /// Control guard or manufacture a newer readiness frontier mid-tick.
        pub fn readinessService(self: TickV1) RuntimeError!*streaming.Service {
            try self.requirePhase(.prepare);
            return self.runtime.streaming_service orelse error.InvalidState;
        }
        pub fn streamReadiness(self: TickV1, handle: streaming.Handle, context: u64, control_epoch: u64) RuntimeError!music.trace.Input {
            const service = try self.readinessService();
            return self.runtime.streamReadinessAtOwned(service, handle, context, control_epoch, self.runtime.tick_v1.frame);
        }
        pub fn streamReadinessLiveV1(self: TickV1, handle: streaming.Handle, context: u64, control_epoch: u64, deferred: *?streaming.stream.LiveObservationDeferV1) RuntimeError!music.trace.Input {
            deferred.* = null;
            const service = try self.readinessService();
            return self.runtime.streamReadinessAtOwnedWithLive(service, handle, context, control_epoch, self.runtime.tick_v1.frame, deferred);
        }
        pub fn validateInitialEntryV1(self: TickV1, request_id: u64, handle: streaming.Handle) RuntimeError!void {
            try self.requirePhase(.prepare);
            const owner = self.runtime.music_runtime orelse return error.InvalidState;
            owner.validateInitialEntryV1(self, request_id, handle) catch return error.InvalidState;
        }
        pub fn validateInitialEntryServiceV1(self: TickV1, service: *streaming.Service, request_id: u64, handle: streaming.Handle) RuntimeError!void {
            try self.validateInitialEntryV1(request_id, handle);
            if (self.runtime.streaming_service != service) return error.InvalidState;
        }
        pub fn prefetchInitialEntryV1(self: TickV1, request_id: u64, handle: streaming.Handle, policy_frame: u64) !?u64 {
            try self.validateInitialEntryV1(request_id, handle);
            if (policy_frame != self.runtime.tick_v1.frame) return error.InvalidState;
            const service = try self.readinessService();
            return service.prefetchInitialEntryV1(self.serial, request_id, handle, policy_frame);
        }
        /// Source coordinates cannot advance before the first group submission.
        /// Keep the genuine Control position; do not pretend Render was frozen.
        pub fn streamReadinessInitialEntryV1(self: TickV1, request_id: u64, handle: streaming.Handle, context: u64, control_epoch: u64) RuntimeError!music.trace.Input {
            try self.validateInitialEntryV1(request_id, handle);
            const control = self.runtime;
            const owner = control.music_runtime.?;
            if (context != owner.config.context or control_epoch != owner.preparing.?.intent.request_epoch or control.stream_input_order == std.math.maxInt(u64)) return error.InvalidState;
            const service = try self.readinessService();
            const position_value: scheduler.trace.Position = .{ .accepted_control_frame = control.tick_v1.frame, .control_tick = control.stream_control_tick, .input_order = control.stream_input_order };
            const input = service.readinessInitialEntryV1(self.serial, request_id, handle, position_value, context, control_epoch) catch return error.InvalidState;
            control.stream_input_order += 1;
            control.recordStreamingInputOwned(input);
            return input;
        }
        /// Existing M2 controller adapter. All preparation stays in this live
        /// owner's prepare phase; acquired observations/releases may be read in
        /// either work phase. No public Control guard is suspended or reentered.
        pub fn musicVoiceObservation(self: TickV1, group: GroupHandle) RuntimeError!MusicGroupObservation {
            try self.requireWorkPhase();
            return self.runtime.musicVoiceObservation(group);
        }
        pub fn earliestPlanFrame(self: TickV1) RuntimeError!u64 {
            try self.requireWorkPhase();
            return self.runtime.earliestPlanFrame();
        }
        /// Internal numeric observation of the collector's exact existing read.
        /// Invalid diagnostic calls cannot change an engine outcome.
        pub fn observeControlCollectionV1(self: TickV1, frame: u64) void {
            self.requirePhase(.collect) catch return;
            if (self.runtime.control_frontier_binding) |binding| binding.bridge.observeFrame(binding.session, self.serial, .collect_frame, .collect, frame);
        }
        pub fn layerProgramAnchorForSource(self: TickV1, group: GroupHandle, source_incarnation: u64, frame: u64, context: u64, revision: u64, previous: ?layer_spans.ProgramHandle) RuntimeError!layer_spans.Anchor {
            try self.requirePhase(.prepare);
            return self.runtime.layerProgramAnchorForSourceOwned(group, source_incarnation, frame, context, revision, previous);
        }
        pub fn layerProgramAnchor(self: TickV1, group: GroupHandle, frame: u64, context: u64, revision: u64, previous: ?layer_spans.ProgramHandle) RuntimeError!layer_spans.Anchor {
            try self.requirePhase(.prepare);
            return self.runtime.layerProgramAnchorOwned(group, frame, context, revision, previous);
        }
        pub fn layerProgramRebaseAnchorForSource(self: TickV1, group: GroupHandle, source_incarnation: u64, frame: u64, context: u64, revision: u64, rebase: LayerProgramRebase) RuntimeError!layer_spans.Anchor {
            try self.requirePhase(.prepare);
            return self.runtime.layerProgramRebaseAnchorForSourceOwned(group, source_incarnation, frame, context, revision, rebase);
        }
        pub fn layerProgramRebaseAnchor(self: TickV1, group: GroupHandle, frame: u64, context: u64, revision: u64, rebase: LayerProgramRebase) RuntimeError!layer_spans.Anchor {
            try self.requirePhase(.prepare);
            return self.runtime.layerProgramRebaseAnchorOwned(group, frame, context, revision, rebase);
        }
        pub fn prepareLayerProgram(self: TickV1, allocator: std.mem.Allocator, desc: layer_spans.ProgramDesc) RuntimeError!layer_spans.ProgramHandle {
            try self.requirePhase(.prepare);
            return self.runtime.prepareLayerProgramOwned(allocator, desc, null);
        }
        pub fn prepareLayerProgramRebased(self: TickV1, allocator: std.mem.Allocator, desc: layer_spans.ProgramDesc, rebase: LayerProgramRebase) RuntimeError!layer_spans.ProgramHandle {
            try self.requirePhase(.prepare);
            return self.runtime.prepareLayerProgramOwned(allocator, desc, rebase);
        }
        pub fn layerProgramObservation(self: TickV1, handle: layer_spans.ProgramHandle) RuntimeError!LayerProgramObservation {
            try self.requireWorkPhase();
            return self.runtime.layerProgramObservationOwned(handle);
        }
        pub fn layerProgramResult(self: TickV1, handle: layer_spans.ProgramHandle) RuntimeError!?layer_runtime.Result {
            try self.requireWorkPhase();
            return self.runtime.layerProgramResultOwned(handle);
        }
        pub fn releaseLayerProgram(self: TickV1, handle: layer_spans.ProgramHandle) RuntimeError!void {
            try self.requireWorkPhase();
            return self.runtime.releaseLayerProgramOwned(handle);
        }
        pub fn prepareMusicContinuity(self: TickV1, allocator: std.mem.Allocator, request: MusicContinuityRequest) RuntimeError!source_continuity.Handle {
            try self.requirePhase(.prepare);
            return self.runtime.prepareMusicContinuityOwned(allocator, request);
        }
        pub fn musicContinuityResult(self: TickV1, handle: source_continuity.Handle) RuntimeError!?music_group.ContinuityCoordinate {
            try self.requireWorkPhase();
            return (self.runtime.source_continuity_manager orelse return error.StaleContinuity).result(handle);
        }
        pub fn releaseMusicContinuity(self: TickV1, handle: source_continuity.Handle) RuntimeError!void {
            try self.requireWorkPhase();
            return self.runtime.releaseMusicContinuityOwned(handle);
        }
        pub fn prepareMusicGroup(self: TickV1, desc: MusicGroupDesc, output: channel_layout.ChannelLayout, sample_rate: u32) RuntimeError!GroupHandle {
            try self.requirePhase(.prepare);
            return self.runtime.prepareMusicGroupOwned(desc, output, sample_rate);
        }
        pub fn retireMusicGroupSource(self: TickV1, group: GroupHandle, source_incarnation: u64) RuntimeError!void {
            try self.requireWorkPhase();
            return self.runtime.retireMusicGroupSourceOwned(group, source_incarnation);
        }
        pub fn musicGroupSourceSwitch(self: TickV1, handle: GroupHandle) RuntimeError!?music_group.SourceSwitch {
            try self.requireWorkPhase();
            return self.runtime.musicGroupSourceSwitchOwned(handle);
        }
        pub fn musicGroupSource(self: TickV1, handle: GroupHandle) RuntimeError!MusicGroupSource {
            try self.requireWorkPhase();
            return self.runtime.musicGroupSourceOwned(handle);
        }
        pub fn musicGroupTerminal(self: TickV1, handle: GroupHandle) RuntimeError!?music_group.Terminal {
            try self.requireWorkPhase();
            return self.runtime.musicGroupTerminalOwned(handle);
        }
        pub fn releaseMusicGroup(self: TickV1, handle: GroupHandle) RuntimeError!void {
            _ = try self.releaseMusicGroupWithResult(handle);
        }
        pub fn releaseMusicGroupWithResult(self: TickV1, handle: GroupHandle) RuntimeError!MusicGroupReleaseResult {
            try self.requireWorkPhase();
            return self.runtime.releaseMusicGroupWithResultOwned(handle);
        }
        /// The graph keeps the same ownership and quiescent Render preflight;
        /// this wrapper only avoids re-entering the live Control guard.
        pub fn prepareBusGraph(self: TickV1, allocator: std.mem.Allocator, desc: bus_runtime.bg.BusGraphDesc, profile: bus_runtime.bg.Profile, adapters: bus_runtime.AdapterDesc) RuntimeError!bus_runtime.Handle {
            try self.requirePhase(.prepare);
            return self.runtime.prepareBusGraphOwned(allocator, desc, profile, adapters);
        }
        pub fn releaseBusGraph(self: TickV1, handle: bus_runtime.Handle) RuntimeError!void {
            try self.requireWorkPhase();
            return self.runtime.releaseBusGraphOwned(handle);
        }
        /// Control acquires only the graph's explicit published active flag.
        /// It never inspects mutable Render graph/voice internals.
        pub fn graphActive(self: TickV1, handle: bus_runtime.Handle) RuntimeError!bool {
            try self.requireWorkPhase();
            return (try (self.runtime.bus_manager orelse return error.StaleGraph).get(handle)).active.load(.acquire);
        }
        /// Uses the current checked Control owner; never re-enters its guard.
        /// Generic bus ownership and actual graph/duck limits remain enforced.
        pub fn prepareBusTargetBatch(self: TickV1, graph: bus_runtime.Handle, operations: []const bus_runtime.Operation) RuntimeError!bus_runtime.BatchHandle {
            try self.requirePhase(.prepare);
            return self.runtime.prepareBusTargetBatchOwned(graph, operations);
        }
        pub fn releaseBusTargetBatch(self: TickV1, handle: bus_runtime.BatchHandle) RuntimeError!void {
            try self.requireWorkPhase();
            return self.runtime.releaseBusTargetBatchOwned(handle);
        }
        pub fn prepareTrackedDuck(self: TickV1, graph: bus_runtime.Handle, identity: duck_lifetime.Identity, target: bus_runtime.sc.DuckAutomationTarget) RuntimeError!bus_runtime.Manager.DuckLease {
            try self.requirePhase(.prepare);
            return self.runtime.prepareTrackedDuckOwned(graph, identity, target);
        }
        pub fn consumeDuckTerminal(self: TickV1, handle: duck_lifetime.Handle) RuntimeError!?duck_lifetime.Terminal {
            try self.requireWorkPhase();
            return self.runtime.consumeDuckTerminalOwned(handle);
        }
        pub fn releaseTrackedDuck(self: TickV1, handle: duck_lifetime.Handle) RuntimeError!void {
            try self.requireWorkPhase();
            return self.runtime.releaseTrackedDuckOwned(handle);
        }
        pub fn residentCaptureFrame(self: TickV1) RuntimeError!u64 {
            try self.requireWorkPhase();
            return self.runtime.residentCaptureFrame();
        }
        pub fn prepareResidentCapture(self: TickV1, desc: resident_transaction.CaptureDesc) RuntimeError!resident_transaction.Handle {
            try self.requirePhase(.prepare);
            return self.runtime.prepareResidentTransactionOwned(.{ .capture = desc });
        }
        pub fn prepareResidentRestore(self: TickV1, desc: resident_transaction.RestoreDesc) RuntimeError!resident_transaction.Handle {
            try self.requirePhase(.prepare);
            return self.runtime.prepareResidentTransactionOwned(.{ .restore = desc });
        }
        pub fn residentTransactionHash(self: TickV1, handle: resident_transaction.Handle) RuntimeError![32]u8 {
            try self.requireWorkPhase();
            return (try self.runtime.resident_transaction_slot.get(handle)).content_hash;
        }
        pub fn pollResidentTransaction(self: TickV1, handle: resident_transaction.Handle) RuntimeError!?resident_transaction.Result {
            try self.requireWorkPhase();
            return self.runtime.pollResidentTransactionOwned(handle);
        }
        pub fn acknowledgeResidentTransaction(self: TickV1, handle: resident_transaction.Handle) RuntimeError!void {
            try self.requireWorkPhase();
            return self.runtime.acknowledgeResidentTransactionOwned(handle);
        }
        pub fn cancelResidentTransaction(self: TickV1, handle: resident_transaction.Handle) RuntimeError!?scheduler.Handle {
            try self.requireWorkPhase();
            return self.runtime.cancelResidentTransactionOwned(handle);
        }
        pub fn prepareSchedule(self: TickV1, start: u64, end: u64, commands: []const ScheduledCommand) RuntimeError!scheduler.Handle {
            try self.requirePhase(.prepare);
            return self.runtime.prepareScheduleOwned(start, end, commands, null);
        }
        /// Single-group emergency Stop payload only, with no submitted block
        /// or parts. Music additionally verifies exact initial-source lineage
        /// and excludes boundary/continuity before consuming the late witness.
        pub fn prepareLiveStopV1(self: TickV1, start: u64, end: u64, command: ScheduledCommand, late: *?scheduler.LivePrepareLateV1) RuntimeError!scheduler.Handle {
            late.* = null;
            try self.requirePhase(.prepare);
            if (command.payload != .group_stop or command.payload.group_stop.allow_crossfade_source_stop or
                command.payload.group_stop.release_frames != scheduler.default_profile.emergency_ramp_frames)
                return error.InvalidArgument;
            return self.runtime.prepareScheduleOwnedWithLiveWitness(start, end, &.{command}, null, late);
        }
        /// Internal live cold-start seam: one unpublished linear group start.
        /// Music owns the narrower initial four-stream lineage validation.
        pub fn prepareLiveColdStartV1(self: TickV1, start: u64, end: u64, command: ScheduledCommand, late: *?scheduler.LivePrepareLateV1) RuntimeError!scheduler.Handle {
            late.* = null;
            try self.requirePhase(.prepare);
            if (command.payload != .group_start or command.payload.group_start.start_curve != .linear or
                command.identity.phase_order != 0 or command.identity.execute_frame != start or
                start == std.math.maxInt(u64) or end != start + 1) return error.InvalidArgument;
            return self.runtime.prepareScheduleOwnedWithLiveWitness(start, end, &.{command}, null, late);
        }
        pub fn submitSchedule(self: TickV1, handle: scheduler.Handle) RuntimeError!void {
            try self.requirePhase(.prepare);
            return self.runtime.submitScheduleOwned(handle);
        }
        pub fn cancelSchedule(self: TickV1, value: scheduler.Invalidation) RuntimeError!?scheduler.Handle {
            try self.requirePhase(.prepare);
            return self.runtime.cancelScheduleOwned(value);
        }
        pub fn releaseSchedule(self: TickV1, handle: scheduler.Handle) RuntimeError!void {
            try self.requireWorkPhase();
            return self.runtime.releaseScheduleOwned(handle);
        }
        pub fn schedulePlan(self: TickV1, handle: scheduler.Handle) RuntimeError!scheduler.Handle {
            try self.requirePhase(.prepare);
            return self.runtime.scheduled.planHandle(handle);
        }
        pub fn pollPlanPhase(self: TickV1, handle: scheduler.Handle, cursor: *u16) RuntimeError!?music.PhaseReceipt {
            try self.requireWorkPhase();
            return self.runtime.pollPlanPhaseOwned(handle, cursor);
        }
        pub fn pollExecutionReceipt(self: TickV1, handle: scheduler.Handle, cursor: *u16) RuntimeError!?scheduler.trace.ScheduleRecord {
            try self.requireWorkPhase();
            return self.runtime.pollExecutionReceiptOwned(handle, cursor);
        }
        pub fn scheduleAdmission(self: TickV1, handle: scheduler.Handle) RuntimeError!?scheduler.trace.Admission {
            try self.requireWorkPhase();
            return self.runtime.scheduleAdmissionOwned(handle);
        }
        pub fn scheduleResult(self: TickV1, handle: scheduler.Handle) RuntimeError!?ScheduleResult {
            try self.requireWorkPhase();
            return self.runtime.scheduleResultOwned(handle);
        }
        pub fn cancellationResult(self: TickV1, handle: scheduler.Handle) RuntimeError!?CancellationResult {
            try self.requireWorkPhase();
            return self.runtime.cancellationResultOwned(handle);
        }
    };

    /// Explicit integrated driver. A versioned owner configured for this driver
    /// cannot also use the legacy split controlTick/pumpResidentV1 path.
    /// Both owners stay guarded throughout retire -> accept -> plan -> publish.
    pub fn controlTickV1(self: *ControlRuntime, limit: usize) !usize {
        return (self.music_runtime orelse return error.InvalidState).controlTickV1(limit);
    }
    pub fn controlTickLiveV1(self: *ControlRuntime, limit: usize) !music.MusicRuntime.LiveControlTickOutcomeV1 {
        return (self.music_runtime orelse return error.InvalidState).controlTickLiveV1(limit);
    }
    /// Called only inside the bound MusicRuntime's Control guard. This checked
    /// ownership seam keeps both legacy public guards active for the whole tick.
    pub fn withMusicTickV1(self: *ControlRuntime, owner: *music.MusicRuntime, limit: usize) !usize {
        return (try self.withMusicTickOwnedV1(owner, limit, false, false, null)).drained;
    }
    pub fn withMusicTickLiveV1(self: *ControlRuntime, owner: *music.MusicRuntime, limit: usize) !music.MusicRuntime.LiveControlTickOutcomeV1 {
        try owner.validateLiveTickModeV1();
        return self.withMusicTickOwnedV1(owner, limit, true, false, null);
    }
    /// New opt-in integration seam. Existing Host and Live drivers never call
    /// this entry. Profile qualification/admission remains separate work.
    pub fn withMusicTickLiveChronologyV1(self: *ControlRuntime, owner: *music.MusicRuntime, limit: usize, sink: ?LiveAcceptanceSinkV1) !music.MusicRuntime.LiveControlTickOutcomeV1 {
        try owner.validateLiveTickModeV1();
        return self.withMusicTickOwnedV1(owner, limit, true, true, sink);
    }
    /// Shutdown/unload uses the original cleanup preparation under the new
    /// chronology, rather than requiring a lagging scheduler read to catch up.
    pub fn withMusicTickChronologyCleanupV1(self: *ControlRuntime, owner: *music.MusicRuntime, limit: usize, sink: ?LiveAcceptanceSinkV1) !music.MusicRuntime.LiveControlTickOutcomeV1 {
        try owner.validateChronologyCleanupV1();
        return self.withMusicTickOwnedV1(owner, limit, false, true, sink);
    }
    /// Separate internal joined fixture entry. Ordinary Live validators remain
    /// strict. The exact permit reaches this layer only through actual owner entry.
    pub const JoinedTickTests = if (@import("builtin").is_test) struct {
        pub fn call(self: *ControlRuntime, owner: *music.MusicRuntime, request_value: music.MusicRuntime.FinalizationTests.TickRequest) !music.MusicRuntime.LiveControlTickOutcomeV1 {
            return callOwned(self, owner, request_value, false);
        }
        pub fn hostCall(self: *ControlRuntime, owner: *music.MusicRuntime, request_value: music.MusicRuntime.FinalizationTests.TickRequest) !music.MusicRuntime.LiveControlTickOutcomeV1 {
            return callOwned(self, owner, request_value, true);
        }
        fn callOwned(self: *ControlRuntime, owner: *music.MusicRuntime, request_value: music.MusicRuntime.FinalizationTests.TickRequest, comptime host: bool) !music.MusicRuntime.LiveControlTickOutcomeV1 {
            if (request_value.owner != owner or self.music_runtime != owner or request_value.session.adapter == null or
                request_value.session.adapter.?.tick_kind != (if (host) .independent_host else .serialized)) return error.InvalidState;
            try request_value.session.enterTickControl(request_value, self);
            if (host) try music.MusicRuntime.FinalizationTests.validateHostTickProfile(owner, request_value.session, request_value.mode) else try music.MusicRuntime.FinalizationTests.validateTickProfile(owner, request_value.session, request_value.mode);
            return switch (request_value.mode) {
                .playback => self.withMusicTickOwnedV1(owner, request_value.limit, true, true, request_value.sink),
                .cleanup => self.withMusicTickOwnedV1(owner, request_value.limit, false, true, request_value.sink),
            };
        }
    } else struct {};
    fn prepareMusicTickV1(owner: *music.MusicRuntime, scope: TickV1, frame: u64, comptime live: bool) !music.MusicRuntime.LiveTickPreparationV1 {
        if (live) return owner.prepareControlTickLiveV1(scope, frame);
        try owner.prepareControlTickV1(scope, frame);
        return .{};
    }
    fn withMusicTickOwnedV1(self: *ControlRuntime, owner: *music.MusicRuntime, limit: usize, comptime live: bool, comptime live_chronology: bool, sink: ?LiveAcceptanceSinkV1) !music.MusicRuntime.LiveControlTickOutcomeV1 {
        if (self.music_runtime != owner) return error.InvalidState;
        if (!live_chronology and owner.live_chronology_frontier != null) return error.InvalidMode;
        try owner.validateControlTickV1(self);
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        const serial = self.tick_v1.next;
        const next = try std.math.add(u64, serial, 1);
        const tick = try std.math.add(u64, self.stream_control_tick, 1);
        self.tick_v1.live_chronology = live_chronology;
        self.tick_v1.live_acceptance_sink = sink;
        defer {
            self.tick_v1.live_acceptance_sink = null;
            self.tick_v1.live_chronology = false;
        }
        self.tick_v1.next = next;
        self.stream_control_tick = tick;
        self.stream_input_order = 0;
        self.tick_v1.thread.store(std.Thread.getCurrentId(), .release);
        self.tick_v1.active.store(serial, .release);
        defer self.tick_v1.active.store(0, .release);
        const scope: TickV1 = .{ .runtime = self, .serial = serial };
        const frontier_binding = self.control_frontier_binding;
        const acceptance_binding = self.stream_acceptance_binding;
        const readiness_binding = self.readiness_binding;
        var tick_error: ?anyerror = null;
        var live_preparation: music.MusicRuntime.LiveTickPreparationV1 = .{};
        var return_path: control_frontier_witness.ReturnPath = .ordinary;
        // Runs before token expiry and Control guard release on every path.
        defer {
            const exit_phase = self.tick_v1.phase;
            self.tick_v1.phase = .publish;
            owner.publishControlTickV1(scope) catch unreachable;
            self.observeLiveTickEventV1(.{ .final_publish = .{ .exit_phase = exit_phase, .frame = owner.control_frame } });
            self.observeLiveTickEventV1(.{ .end = .{ .frame = owner.control_frame, .failure = tick_error, .preparation = live_preparation } });
            if (readiness_binding) |binding| {
                binding.service.readiness_supply_sink = null;
                binding.service.readiness_lifecycle_sink = null;
                self.scheduled.control_sink = null;
                binding.bridge.context(.publish, self.tick_v1.frame, self.stream_input_order);
                binding.bridge.endTick(tick_error);
            }
            if (frontier_binding) |binding| binding.bridge.endTickObserved(binding.session, serial, exit_phase, tick_error, return_path);
            if (acceptance_binding) |binding| binding.bridge.endTick(binding.session, serial, exit_phase, tick_error);
            self.tick_v1.phase = .idle;
        }
        // Registered after the publication defer so the original returned error
        // is captured first, including errors after partial real tick work.
        errdefer |err| tick_error = err;
        self.observeLiveTickEventV1(.{ .begin = .{ .tick = tick, .entry_frame = owner.control_frame } });
        self.tick_v1.phase = .collect;
        self.observeLiveTickEventV1(.{ .phase = .collect });
        if (frontier_binding) |binding| binding.bridge.beginTick(binding.session, serial, tick);
        if (acceptance_binding) |binding| binding.bridge.beginTick(binding.session, serial, tick);
        if (readiness_binding) |binding| {
            self.validateReadinessPeers(binding) catch binding.bridge.markIncomplete(.interrupted);
            binding.bridge.beginTick(serial, tick);
            binding.service.readiness_supply_sink = .{ .context = self, .begin = beginReadinessSupply, .finish = finishReadinessSupply, .throughput = observeReadinessThroughput };
            if (binding.bridge.manifest.capture_reconciliation) {
                binding.service.readiness_lifecycle_sink = .{ .context = self, .emit = observeStreamLifecycle };
                self.scheduled.control_sink = .{ .context = self, .emit = observeSchedulerControl };
            }
        }
        if (@import("builtin").is_test) if (self.test_before_collection_hook) |hook| hook.call(hook.context);
        self.consumeCompletions();
        self.scheduled.reconcilePrepared();
        self.reconcileTerminalSchedules();
        self.reconcileLayerChanges();
        self.collectContinuityLeases();
        owner.collectControlTickV1(scope) catch |err| {
            self.observeLiveTickFailureV1(.collect_owner, err);
            return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
        };
        self.observeLiveTickEventV1(.{ .collect_returned = owner.control_frame });
        self.controlFrontierHook(.after_collect);
        // Phase acquisition may observe a newer completed frame; acceptance
        // uses the common completed frontier sampled after that acquisition.
        self.tick_v1.phase = .accept;
        self.observeLiveTickEventV1(.{ .phase = .accept });
        self.causalReplay(.{ .site = .control_accept_frame, .edge = .before });
        const acquired_accept_frame = owner.acquireAcceptanceFrameV1(scope) catch |err| {
            self.observeLiveTickFailureV1(.accept_acquire, err);
            return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
        };
        self.tick_v1.frame = acquired_accept_frame.effective;
        self.causalReplay(.{ .site = .control_accept_frame, .edge = .after, .value = acquired_accept_frame.observed });
        if (frontier_binding) |binding| binding.bridge.observeFrame(binding.session, serial, .accept_frame, .accept, acquired_accept_frame.observed);
        if (live_chronology) owner.syncLiveAcceptanceFrameV1(scope) catch |err| {
            // The acquired cut is real even if owner synchronization fails.
            // Preserve it without rereading Render or fabricating owner adoption.
            if (sink) |value| if (value.frontier) |emit|
                emit(value.context, .accept, acquired_accept_frame.observed, acquired_accept_frame.effective);
            self.observeLiveTickFailureV1(.accept_sync, err);
            return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
        };
        scope.observeLiveFrontierV1(acquired_accept_frame.observed, acquired_accept_frame.effective) catch |err| {
            self.observeLiveTickFailureV1(.accept_sync, err);
            return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
        };
        owner.acceptDeviceControlTickV1(scope) catch |err| {
            self.observeLiveTickFailureV1(.accept_device, err);
            return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
        };
        if (live_chronology) {
            self.acceptStreamingLiveAt(owner, scope, sink) catch |err| {
                self.observeLiveTickFailureV1(.accept_live, err);
                return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
            };
        } else if (owner.streamReplayActiveV1()) owner.acceptStreamReplayTickV1(scope) catch |err| {
            self.observeLiveTickFailureV1(.accept_replay, err);
            return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
        } else self.acceptStreamingAt(self.tick_v1.frame);
        const budget = @min(limit, max_control_drain);
        var drained = self.drainCommandsOwned(budget) catch |err| {
            self.observeLiveTickFailureV1(.accept_drain, err);
            return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
        };
        self.tick_v1.phase = .prepare;
        self.observeLiveTickEventV1(.{ .phase = .prepare });
        const preparation = prepareMusicTickV1(owner, scope, self.tick_v1.frame, live) catch |err| {
            self.observeLiveTickFailureV1(.prepare_owner, err);
            // A music planning failure must not strand SFX accepted earlier in
            // this tick. Preserve that actual publication before returning it.
            _ = self.drainCommandsOwned(budget - drained) catch |drain_error| {
                self.observeLiveTickFailureV1(.prepare_failure_drain, drain_error);
                return @as(@TypeOf(drain_error)!music.MusicRuntime.LiveControlTickOutcomeV1, drain_error);
            };
            self.tick_v1.phase = .publish;
            self.observeLiveTickEventV1(.{ .phase = .publish });
            self.publishSnapshot() catch |snapshot_error| {
                self.observeLiveTickFailureV1(.snapshot, snapshot_error);
                return @as(@TypeOf(snapshot_error)!music.MusicRuntime.LiveControlTickOutcomeV1, snapshot_error);
            };
            self.observeLiveTickEventV1(.{ .snapshot = true });
            // Only this reached return retains the original preparation error.
            // Either fallible publication step above may return its own error;
            // those paths keep .ordinary and cannot impersonate this witness.
            return_path = .prepare_failure_after_control_publication;
            // Keep the original inferred error set while making the error
            // union explicit for the captured errdefer on this return path.
            return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
        };
        live_preparation = preparation;
        self.observeLiveTickEventV1(.{ .prepare_returned = .{ .frame = self.tick_v1.frame, .value = preparation } });
        // Newly prepared music shares the same ordinary/reserved sequence and
        // remaining bounded publication budget with SFX; no bypass publication.
        drained += self.drainCommandsOwned(budget - drained) catch |err| {
            self.observeLiveTickFailureV1(.prepare_success_drain, err);
            return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
        };
        self.tick_v1.phase = .publish;
        self.observeLiveTickEventV1(.{ .phase = .publish });
        self.publishSnapshot() catch |err| {
            self.observeLiveTickFailureV1(.snapshot, err);
            return @as(@TypeOf(err)!music.MusicRuntime.LiveControlTickOutcomeV1, err);
        };
        self.observeLiveTickEventV1(.{ .snapshot = false });
        self.observeLiveTickEventV1(.{ .publish_returned = self.tick_v1.frame });
        // Only reached after normal publication succeeds. A later drain or
        // snapshot error has its own return path and overrides any deferral.
        return .{ .drained = drained, .deferred = preparation.deferred, .stop_deferred = preparation.stop_deferred, .cold_start_deferred = preparation.cold_start_deferred };
    }

    pub fn controlTick(self: *ControlRuntime, limit: usize) RuntimeError!usize {
        if (self.music_runtime) |owner| if (owner.usesIntegratedTickV1()) return error.InvalidState;
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        self.consumeCompletions();
        self.stream_control_tick +|= 1;
        self.stream_input_order = 0;
        self.acceptStreaming();
        self.scheduled.reconcilePrepared();
        for (&self.scheduled.slots) |*slot| if (slot.state.load(.acquire) == .terminal) self.reconcileSchedule(slot);
        self.reconcileLayerChanges();
        const drained = try self.drainCommandsOwned(limit);
        try self.publishSnapshot();
        return drained;
    }

    fn drainCommandsOwned(self: *ControlRuntime, limit: usize) RuntimeError!usize {
        var drained: usize = 0;
        while (drained < @min(limit, max_control_drain)) : (drained += 1) {
            if (self.deltas.count() > scheduler.default_profile.immediate_capacity - @max(max_render_voices, self.active_count) - 2) break;
            const item = self.normal.popSequence(self.next_control_sequence) orelse
                self.reserved.popSequence(self.next_control_sequence) orelse
                self.layer_stop_ingress.popSequence(self.next_control_sequence) orelse break;
            self.next_control_sequence +%= 1;
            self.apply(item.value, item.sequence) catch |err| switch (err) {
                error.StaleInstance, error.DuplicateInstance => {
                    _ = self.counters.rejected_commands.fetchAdd(1, .monotonic);
                    continue;
                },
                else => return err,
            };
        }
        return drained;
    }

    fn apply(self: *ControlRuntime, command: Command, sequence: u64) RuntimeError!void {
        switch (command) {
            .play => |play| {
                if (!self.instances.current(play.instance) or (play.reservation != 0 and !self.instances.matches(play.instance, play.reservation))) {
                    releasePlayOwner(play.owner, play.custody);
                    return error.StaleInstance;
                }
                const state = &self.desired[play.instance.index];
                if (state.active) {
                    releasePlayOwner(play.owner, play.custody);
                    return error.DuplicateInstance;
                }
                if (self.shutdown_applied) {
                    releasePlayOwner(play.owner, play.custody);
                    self.finish(play.instance, .rejected);
                    return;
                }
                if (self.reservedRealCount() >= (if (self.voice_admission) |a| a.voice.max_real_voices else max_render_voices)) {
                    const victim = self.findVictim(play.params.priority) orelse {
                        releasePlayOwner(play.owner, play.custody);
                        self.finish(play.instance, .rejected);
                        return;
                    };
                    const old = self.desired[victim];
                    self.delta(sequence, .{ .stop = .{ .command = .{ .instance = old.instance, .reservation = old.reservation, .fade_frames = steal_fade_frames }, .start_order = old.start_order } });
                    releasePlayOwner(old.owner, old.custody);
                    self.desired[victim] = .{};
                    self.instances.release(old.instance);
                    self.reportCompletion(.{ .instance = old.instance, .reason = .stolen });
                    _ = self.counters.stolen_instances.fetchAdd(1, .monotonic);
                    self.active_count -= 1;
                }
                state.* = .{ .active = true, .reservation = if (play.reservation != 0) play.reservation else try self.instances.identity(play.instance), .instance = play.instance, .owner = play.owner, .custody = play.custody, .params = play.params, .revision = self.takeRevision(), .start_order = sequence, .start_order_known = true };
                self.active_count += 1;
                // The ingress pin becomes desired ownership. Journal adds its
                // own pin, independent of snapshot replacement and one-shot end.
                const journal = pinPlayDerivative(play.owner, play.custody, .journal, playDestination(self, play.instance, state.reservation)) catch |err| {
                    state.* = .{};
                    self.active_count -= 1;
                    releasePlayOwner(play.owner, play.custody);
                    self.finish(play.instance, .rejected);
                    return err;
                };
                self.delta(sequence, .{ .play = .{ .reservation = state.reservation, .instance = play.instance, .owner = play.owner, .custody = journal, .params = play.params, .revision = state.revision, .stopping = false, .fade_frames = 0, .start_order = sequence } });
            },
            .update => |update| {
                if (update.reservation != 0 and !self.instances.matches(update.instance, update.reservation)) return error.StaleInstance;
                const state = try self.stateFor(update.instance);
                if (state.stopping) return;
                applyUpdate(&state.params, update.params);
                state.revision = self.takeRevision();
                state.fade_frames = update.ramp_frames;
                self.delta(sequence, .{ .update = .{ .command = update, .start_order = state.start_order } });
            },
            .bus => |bus| {
                switch (bus.bus) {
                    .sfx => self.sfx_gain = bus.gain,
                    .music => self.music_gain = bus.gain,
                    .master => {
                        self.master_gain = bus.gain;
                        self.master_ramp_frames = @max(bus.ramp_frames, 1);
                    },
                }
                self.bus_revision = self.takeRevision();
                self.delta(sequence, .{ .bus = bus });
            },
            .stop => |stop| {
                if (stop.reservation != 0 and !self.instances.matches(stop.instance, stop.reservation)) return error.StaleInstance;
                const state = self.stateFor(stop.instance) catch |err| {
                    if (!self.instances.current(stop.instance)) return err;
                    self.finish(stop.instance, .stopped);
                    return;
                };
                state.stopping = true;
                state.fade_frames = @max(stop.fade_frames, 1);
                state.revision = self.takeRevision();
                self.delta(sequence, .{ .stop = .{ .command = stop, .start_order = state.start_order } });
            },
            .scheduled => |handle| {
                const slot = try self.scheduled.getObserved(handle, null);
                slot.queue_refs = 0;
                if (slot.state.load(.acquire) == .terminal) return;
                if (self.scheduled.plans[slot.plan_index].cancelled.load(.acquire)) {
                    self.scheduled.abortQueued(slot, self.scheduled.commit_horizon.load(.acquire));
                    return;
                }
                for (slot.block.commands[0..slot.block.count]) |*scheduled_command| {
                    for (self.scheduledPlays(&scheduled_command.payload)) |play| {
                        const state = &self.desired[play.instance.index];
                        if (state.active and state.instance.eql(play.instance) and state.reservation == play.reservation) {
                            state.start_order = sequence;
                            state.start_order_known = true;
                        }
                    }
                }
                for (slot.block.commands[0..slot.block.count]) |*scheduled_command| {
                    scheduled_command.sequence = sequence;
                    switch (scheduled_command.payload) {
                        .stop => |*v| {
                            const state = self.desired[v.instance.index];
                            if (v.incarnation == null and state.active and state.start_order_known and state.reservation == v.reservation) v.incarnation = state.start_order;
                        },
                        .update => |*v| {
                            const state = self.desired[v.instance.index];
                            if (v.incarnation == null and state.active and state.start_order_known and state.reservation == v.reservation) v.incarnation = state.start_order;
                        },
                        else => {},
                    }
                }
                slot.block.content_hash = hashScheduledBlock(slot.block.start_frame, slot.block.end_frame, slot.block.commands[0..slot.block.count]);
                try self.scheduled.publish(handle, sequence);
                if (self.music_runtime) |owner| owner.capturePublishedScheduleV1(self, &slot.block);
            },
            .invalidate => |handle| {
                const intent = &self.scheduled.intents[handle.index];
                var hash = std.crypto.hash.sha2.Sha256.init(.{});
                encodeIntent(&hash, intent.token, intent.value, sequence);
                hash.final(&intent.content_hash);
                try self.publishInvalidationOwned(handle, sequence);
                if (self.music_runtime) |owner| owner.capturePublishedInvalidationV1(self, intent);
            },
            .shutdown => {
                self.shutdown_applied = true;
                const frame = self.scheduled.render_frame.load(.acquire);
                for (&self.scheduled.slots, 0..) |*slot, i| if (slot.state.load(.acquire) == .prepared and try self.scheduled.localCancellationAllowed(.{ .index = @intCast(i), .generation = slot.generation })) {
                    try self.scheduled.cancelPrepared(.{ .index = @intCast(i), .generation = slot.generation }, frame, frame);
                    self.reconcileSchedule(slot);
                };
                self.scheduled.shutdown_requested.store(true, .release);
                self.accepting.store(false, .release);
                for (&self.desired, 0..) |*state, index| {
                    if (state.active) {
                        state.stopping = true;
                        state.fade_frames = 1;
                        state.revision = self.takeRevision();
                        self.delta(sequence, .{ .stop = .{ .command = .{ .instance = state.instance, .reservation = state.reservation, .fade_frames = 1 }, .start_order = state.start_order, .group_reason = .shutdown } });
                    } else {
                        const slot = self.instances.slots[index].load(.acquire);
                        if (slot & InstancePool.occupied != 0) self.finish(.{ .index = @intCast(index), .generation = @truncate(slot) }, .stopped);
                    }
                }
            },
        }
    }

    fn stateFor(self: *ControlRuntime, handle: InstanceHandle) RuntimeError!*DesiredVoice {
        if (!self.instances.current(handle)) return error.StaleInstance;
        const state = &self.desired[handle.index];
        if (!state.active or !state.instance.eql(handle)) return error.StaleInstance;
        return state;
    }

    fn legacyBusBit(bus: mixer.BusId) u8 {
        return switch (bus) {
            .sfx => 1,
            .music => 2,
            .master => 4,
        };
    }

    fn bindingDetectorMask(binding: *const bus_runtime.Binding) u8 {
        var mask: u8 = 0;
        inline for (.{ mixer.BusId.sfx, mixer.BusId.music, mixer.BusId.master }) |bus| {
            if (binding.legacyDetectorDependency(switch (bus) {
                .sfx => .sfx,
                .music => .music,
                .master => .master,
            })) mask |= legacyBusBit(bus);
        }
        return mask;
    }

    /// Control-only conservative reservation, not a claim of DSP activation.
    /// Submitted graph-install blocks retain their generation-safe graph lease
    /// through acknowledgement. Unsubmitted prepared blocks reserve nothing.
    fn legacyDetectorMask(self: *const ControlRuntime) u8 {
        const manager = self.bus_manager orelse return 0;
        var mask: u8 = 0;
        // Scan pending before active. A terminal acquire observes the preceding
        // Render install (active release), so that transition cannot lose both
        // protections. Control alone recycles slots/graphs and invokes this scan.
        for (&self.scheduled.slots) |*slot| {
            switch (slot.state.load(.acquire)) {
                .free, .prepared, .terminal => continue,
                .queued, .published, .acquired, .partially_executed => {},
            }
            // Commands and Binding metadata are immutable to Render; existing
            // command leases pin the exact generation even if it becomes terminal.
            for (slot.block.commands[0..slot.block.count]) |command| {
                if (command.payload == .graph_install) {
                    const graph = manager.get(command.payload.graph_install.graph) catch unreachable;
                    mask |= bindingDetectorMask(&graph.binding);
                }
            }
        }
        for (manager.graphs) |maybe| if (maybe) |graph| {
            if (graph.active.load(.acquire)) mask |= bindingDetectorMask(&graph.binding);
        };
        return mask;
    }

    fn findVictim(self: *const ControlRuntime, incoming_priority: f32) ?usize {
        const protected_buses = self.legacyDetectorMask();
        var victim: ?usize = null;
        for (&self.desired, 0..) |*state, index| if (state.active and !state.stopping and !state.scheduled and protected_buses & legacyBusBit(state.params.bus) == 0) {
            if (victim == null or weaker(state.*, self.desired[victim.?])) victim = index;
        };
        if (victim) |index| if (incoming_priority <= self.desired[index].params.priority) return null;
        return victim;
    }

    fn takeRevision(self: *ControlRuntime) u64 {
        defer self.next_revision +%= 1;
        if (self.next_revision == 0) self.next_revision = 1;
        return self.next_revision;
    }

    fn consumeCompletions(self: *ControlRuntime) void {
        while (true) {
            var read = self.beginReadinessReconciliation(.completion_pop);
            defer _ = self.finishReadinessReconciliation(read);
            const completion = self.render_completions.popObserved(read, self.offline_causal_replay, completionOrderBinding(self.prerequisite_order)) orelse break;
            if (read) |value| {
                value.instance = .{ .index = completion.instance.index, .generation = completion.instance.generation };
                value.start_order = completion.start_order;
                value.completion_reason = @intFromEnum(completion.reason);
            }
            const current = self.instances.currentObserved(completion.instance, read);
            if (read) |value| value.instance_current = current;
            if (!current) continue;
            const state = &self.desired[completion.instance.index];
            const active = state.active;
            if (read) |value| value.desired_active = active;
            if (!active) continue;
            const matches = state.instance.eql(completion.instance);
            if (read) |value| value.instance_matches = matches;
            if (!matches) continue;
            if (completion.start_order) |order| {
                const desired_order = state.start_order;
                if (read) |value| value.desired_start_order = desired_order;
                if (desired_order != order) continue;
            }
            if (read) |value| value.reservation = state.reservation;
            releasePlayOwner(state.owner, state.custody);
            state.* = .{};
            self.active_count -= 1;
            self.instances.releaseObserved(completion.instance, read);
            if (read) |value| value.returned = true;
            _ = self.finishReadinessReconciliation(read);
            read = null;
            self.reportCompletion(.{ .instance = completion.instance, .reason = completion.reason });
        }
    }

    fn finish(self: *ControlRuntime, instance: InstanceHandle, reason: CompletionReason) void {
        self.instances.release(instance);
        self.reportCompletion(.{ .instance = instance, .reason = reason });
    }

    // Render-only callers supply their own lane explicitly. This object owns
    // queue storage, but its prerequisite_order belongs exclusively to Control.
    fn pushRenderCompletion(self: *ControlRuntime, completion: RenderCompletion, order: ?capture_order.Binding) bool {
        return self.pushRenderCompletionObserved(completion, null, order);
    }
    fn pushRenderCompletionObserved(self: *ControlRuntime, completion: RenderCompletion, observed: ?*render_causal_witness.ResourceEvent, order: ?capture_order.Binding) bool {
        if (self.render_completions.pushObserved(completion, observed, self.offline_causal_replay, order)) return true;
        _ = self.counters.completion_overflow.fetchAdd(1, .monotonic);
        return false;
    }

    fn reportCompletion(self: *ControlRuntime, completion: Completion) void {
        if (self.music_runtime) |owner| owner.captureSfxCompletionV1(self, completion);
        // Compatibility: host observations may overflow, but render lifecycle
        // acknowledgements above are retried until Control receives them.
        if (!self.reported_completions.push(completion)) _ = self.counters.completion_overflow.fetchAdd(1, .monotonic);
    }

    fn publishSnapshot(self: *ControlRuntime) RuntimeError!void {
        if (self.next_snapshot_generation == std.math.maxInt(u64)) return error.InvalidState;
        const current = self.published_slot.load(.acquire);
        var selected: ?u8 = null;
        for (0..snapshot_count) |offset| {
            const index: u8 = @intCast((@as(usize, current) + 1 + offset) % snapshot_count);
            if (index != current and self.snapshots[index].readers.cmpxchgStrong(0, SnapshotSlot.writing, .acq_rel, .acquire) == null) {
                selected = index;
                break;
            }
        }
        const index = selected orelse return error.SnapshotBusy;
        const slot = &self.snapshots[index];
        defer slot.readers.store(0, .release);
        slot.releaseOwners(self);
        const generation = self.next_snapshot_generation;
        self.next_snapshot_generation += 1;
        slot.snapshot = .{ .generation = generation, .sfx_gain = self.sfx_gain, .music_gain = self.music_gain, .master_gain = self.master_gain, .master_ramp_frames = self.master_ramp_frames, .bus_revision = self.bus_revision };
        slot.credit_phase = .acquiring;
        errdefer slot.releaseOwners(self);
        for (&self.desired) |*state| if (state.active) {
            const snapshot_pin = pinPlayDerivative(state.owner, state.custody, play_custody.snapshotRole(index) catch unreachable, playDestination(self, state.instance, state.reservation)) catch return error.InvalidState;
            if (self.music_runtime) |owner| owner.acquireSnapshotCredit(self, index, state.owner) catch |err| {
                releasePlayOwner(state.owner, snapshot_pin);
                return err;
            };
            _ = self.counters.snapshot_pins.fetchAdd(1, .monotonic);
            slot.snapshot.voices[slot.snapshot.voice_count] = .{ .reservation = state.reservation, .instance = state.instance, .owner = state.owner, .custody = snapshot_pin, .params = state.params, .revision = state.revision, .stopping = state.stopping, .fade_frames = state.fade_frames, .start_order = state.start_order };
            slot.snapshot.voice_count += 1;
        };
        slot.credit_phase = .idle;
        self.published_generation.store(slot.snapshot.generation, .release);
        self.published_slot.store(index, .release);
    }

    // Non-callback compatibility API. RuntimeRenderer uses the bounded try path.
    pub fn acquireSnapshot(self: *ControlRuntime) SnapshotLease {
        while (true) if (self.tryAcquireSnapshot()) |lease| return lease;
    }

    fn tryAcquireSnapshot(self: *ControlRuntime) ?SnapshotLease {
        for (0..snapshot_count) |_| {
            const index = self.published_slot.load(.acquire);
            const slot = &self.snapshots[index];
            const readers = slot.readers.load(.acquire);
            if (readers >= SnapshotSlot.writing - 1) continue;
            if (slot.readers.cmpxchgStrong(readers, readers + 1, .acquire, .monotonic) != null) continue;
            if (index != self.published_slot.load(.acquire)) {
                _ = slot.readers.fetchSub(1, .release);
                continue;
            }
            // Writer exclusion makes even an index ABA safe: either version is
            // immutable until this acquired reader releases its lease.
            return .{ .runtime = self, .slot_index = index, .snapshot = &slot.snapshot };
        }
        return null;
    }

    pub fn pollCompletion(self: *ControlRuntime) ?Completion {
        return self.reported_completions.pop();
    }

    pub fn telemetry(self: *const ControlRuntime) RuntimeTelemetry {
        return .{ .accepted_commands = self.counters.accepted_commands.load(.monotonic), .rejected_commands = self.counters.rejected_commands.load(.monotonic), .queue_high_water = self.counters.queue_high_water.load(.monotonic), .live_instances = @intCast(self.instances.liveCount()), .snapshot_generation = self.published_generation.load(.acquire), .snapshot_pins = self.counters.snapshot_pins.load(.monotonic), .render_pins = self.counters.render_pins.load(.monotonic), .completion_overflow = self.counters.completion_overflow.load(.monotonic), .stolen_instances = self.counters.stolen_instances.load(.monotonic), .snapshot_misses = self.counters.snapshot_misses.load(.monotonic), .pin_misses = self.counters.pin_misses.load(.monotonic) };
    }

    /// Control owner only (or host-quiesced), including scheduler obligations.
    pub fn drainStatus(self: *const ControlRuntime) RuntimeError!void {
        if (self.resident_transaction_slot.state.load(.acquire) != .free) return error.DrainPending;
        if (self.normal.count() != 0 or self.reserved.count() != 0 or self.layer_stop_ingress.count() != 0 or self.instances.liveCount() != 0 or self.counters.render_pins.load(.acquire) != 0 or self.scheduled.hasRenderObligations()) return error.DrainPending;
        if (self.layer_manager) |manager| if (manager.hasRenderObligations()) return error.DrainPending;
        if (self.graph_clock_manager) |manager| if (manager.hasRenderObligations()) return error.DrainPending;
        if (self.bus_manager) |manager| if (!manager.ducks.empty()) return error.DrainPending;
        if (self.bus_manager) |manager| for (manager.graphs) |entry| if (entry) |slot| {
            if (slot.active.load(.acquire)) return error.DrainPending;
        };
    }

    pub fn destroy(self: *ControlRuntime) RuntimeError!void {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        // Diagnostic closure alone never grants permission to free a live
        // binding. The host must close, drain and explicitly detach it first.
        if (self.control_frontier_binding != null or self.stream_acceptance_binding != null or self.render_causal_attached or self.readiness_binding != null) return error.DrainPending;

        self.stopAccepting();
        self.consumeCompletions();
        self.scheduled.reconcilePrepared();
        for (&self.scheduled.slots) |*slot| if (slot.state.load(.acquire) == .terminal) self.reconcileSchedule(slot);
        if (self.resident_transaction_slot.state.load(.acquire) != .free) {
            const handle: resident_transaction.Handle = .{ .generation = self.resident_transaction_slot.generation };
            if (self.resident_transaction_slot.state.load(.acquire) == .prepared) _ = try self.cancelResidentTransactionOwned(handle);
            if (try self.pollResidentTransactionOwned(handle) != null) try self.acknowledgeResidentTransactionOwned(handle);
        }
        try self.drainStatus();
        // Destruction is an explicit host-quiesced receipt drain. Refuse live
        // publications, but reclaim already terminal payloads exactly once.
        for (&self.scheduled.intents, 0..) |*intent, i| if (intent.state.load(.acquire) == 3) {
            _ = try self.cancellationResultOwned(.{ .index = @intCast(i), .generation = intent.generation });
        };
        for (&self.scheduled.slots, 0..) |*slot, i| if (slot.state.load(.acquire) == .terminal) {
            try self.releaseScheduleOwned(.{ .index = @intCast(i), .generation = slot.generation });
        };
        for (&self.scheduled.slots) |*slot| if (slot.state.load(.acquire) != .free) return error.DrainPending;
        for (&self.scheduled.intents) |*intent| if (intent.state.load(.acquire) != 0) return error.DrainPending;
        for (&self.scheduled.plans) |*plan| if (plan.active) return error.DrainPending;
        if (self.layer_manager) |manager| {
            for (&manager.slots, 0..) |*slot, i| if (slot.state.load(.acquire) != .free) {
                const group = try manager.release(.{ .context = slot.desc.anchor.context, .index = @intCast(i), .generation = slot.generation }, self.scheduled.render_frame.load(.acquire));
                self.prepared_groups[group.index].references -= 1;
            };
            try manager.deinit();
            self.layer_manager = null;
            self.layer_manager_published.store(null, .release);
        }
        if (self.graph_clock_manager) |manager| {
            // Release successors first so predecessor reservations unwind.
            var remaining: usize = graph_clock.max_programs;
            while (remaining > 0) : (remaining -= 1) {
                var changed = false;
                for (&manager.slots, 0..) |*slot, i| if (slot.state.load(.acquire) != .free and slot.references == 0) {
                    try self.releaseGraphSourceProgramOwned(.{ .context = slot.desc.progress.anchor.context, .index = @intCast(i), .generation = slot.generation });
                    changed = true;
                };
                if (!changed) break;
            }
            try manager.deinit();
            self.graph_clock_manager = null;
            self.graph_clock_manager_published.store(null, .release);
        }
        for (&self.prepared_groups, 0..) |*group, index| if (group.occupied) {
            try self.releaseMusicGroupOwned(.{ .index = @intCast(index), .generation = group.generation });
        };
        if (self.source_continuity_manager) |manager| {
            for (&manager.slots, 0..) |*slot, i| if (slot.state.load(.acquire) != .free) {
                try self.releaseMusicContinuityOwned(.{ .index = @intCast(i), .generation = slot.generation });
            };
            self.source_continuity_published.store(null, .release);
            self.source_continuity_manager = null;
            manager.allocator.destroy(manager);
        }
        // Host-quiesced destruction may discard unneeded bus/stop observations;
        // no live instance or renderer pin remains at this point.
        while (self.deltas.pop()) |d| if (d.payload == .play) releasePlayOwner(d.payload.play.owner, d.payload.play.custody);
        for (&self.snapshots) |*slot| {
            if (slot.readers.load(.acquire) != 0) return error.DrainPending;
            slot.releaseOwners(self);
        }
        while (self.pollCompletion() != null) {}
        if (self.counters.snapshot_pins.load(.acquire) != 0) return error.DrainPending;
        if (self.bus_manager) |manager| {
            try manager.deinit();
            self.bus_manager = null;
        }
        if (self.streaming_service) |service| {
            service.discardVisibilityQuiescent() catch return error.DrainPending;
            service.detachRuntimeQuiescent() catch return error.DrainPending;
            self.streaming_service = null;
        }
    }
};

const GroupRenderPin = struct {
    context: u64,
    runtime_generation: u64,
    group: GroupHandle,
    play_index: u8,
    instance: InstanceHandle,
    reservation: u64,
    start_order: u64,
    generation_credit: ?music.MusicRuntime.GroupGenerationCredit,
};

const RenderVoice = struct {
    custody: ?PlayToken = null,
    reservation: u64 = 0,
    group_pin: ?GroupRenderPin = null,
    active: bool = false,
    instance: InstanceHandle = .{ .index = 0, .generation = 0 },
    handle: mixer.VoiceHandle = .{ .index = 0, .generation = 0 },
    owner: *SampleOwner = undefined,
    revision: u64 = 0,
    stopping: bool = false,
    start_order: u64 = 0,
    bus: mixer.BusId = .sfx,
};

const TerminalVoice = struct { valid: bool = false, generation: u16 = 0, start_order: u64 = 0 };

pub const RuntimeRenderer = struct {
    /// A host token is issued only by an exclusive, non-waiting claim after the
    /// backend has stopped its callbacks. A concurrent Render entrant fails
    /// closed to silence; neither side waits for the other.
    pub const DeviceQuiescence = struct { renderer: *const RuntimeRenderer, context: *const ControlRuntime, incarnation: u64 };
    pub const DeviceRegistrationHook = struct { context: *anyopaque, call: *const fn (*anyopaque) void };
    /// Exact result of the original Render entry CAS. Null means acquired;
    /// a value is the actual rejected state. Never reload device_access here.
    /// The immutable context is Render-owned through real callback joins.
    pub const TestRenderAdmission = struct { frame_count: u32, channels: u16, adapter: bool, cas_observed: ?u8 };
    pub const TestRenderAdmissionHook = struct { context: *anyopaque, call: *const fn (*anyopaque, TestRenderAdmission) void };
    /// Test observation only at the real post-completion/pre-pin-return boundary.
    /// Production has no hook storage, waiting or alternate release behavior.
    pub const GroupReleaseObservation = GroupRenderPin;
    pub const GroupReleaseHook = struct { context: *anyopaque, call: *const fn (*anyopaque, GroupReleaseObservation) void };
    pub const PlayReleaseObservation = struct { token: PlayToken, instance: InstanceHandle, reservation: u64, start_order: u64 };
    pub const PlayReleaseHook = struct { context: *anyopaque, call: *const fn (*anyopaque, PlayReleaseObservation) void };
    pub const CallObservation = struct { sequence: u64, exhausted: bool };
    pub const RenderCausalBinding = struct {
        bridge: *render_causal_witness.Bridge,
        session: render_causal_witness.Session,
        /// Live validation only; never copied to Event/Manifest/Terminal.
        music_owner: *music.MusicRuntime,
    };
    /// Immutable while attached; the host owns actual role/consumer quiescence
    /// and pinned lifetime. Defaults and old profiles never attach this observer.
    prerequisite_order: ?*capture_order.RoleCollector = null,
    /// Immutable explicit Live semantic binding. Host owns genuine role exclusion.
    live_semantic_hooks: ?live_semantic.Binding = null,
    offline_causal_replay: ?CausalReplayHooks = null,
    render_causal_binding: ?RenderCausalBinding = null,
    render_causal_owner_identity: u64 = 0,
    device_access: std.atomic.Value(u8) = .init(0), // idle / Render / quiescent host / registration
    device_quiescence_incarnation: u64 = 0, // written only while holding device_access
    device_quiescence_active: std.atomic.Value(u64) = .init(0),
    test_device_registration_hook: if (@import("builtin").is_test) ?DeviceRegistrationHook else void = if (@import("builtin").is_test) null else {},
    test_render_admission_hook: if (@import("builtin").is_test) ?TestRenderAdmissionHook else void = if (@import("builtin").is_test) null else {},
    test_owned_render_facts: if (@import("builtin").is_test) ?owned_render_facts.Hook else void = if (@import("builtin").is_test) null else {},
    test_owned_render_stage: if (@import("builtin").is_test) render_causal_witness.CallSubstage else void = if (@import("builtin").is_test) .before_gate else {},
    device_callbacks_active: std.atomic.Value(bool) = .init(false),
    test_group_release_hook: if (@import("builtin").is_test) ?GroupReleaseHook else void = if (@import("builtin").is_test) null else {},
    test_play_release_hook: if (@import("builtin").is_test) ?PlayReleaseHook else void = if (@import("builtin").is_test) null else {},
    bus_graph: ?bus_runtime.Handle = null,
    runtime: *ControlRuntime,
    mixer: *mixer.Mixer,
    telemetry: core.TelemetryCounters = .{},
    voices: [max_logical_voices]RenderVoice = [_]RenderVoice{.{}} ** max_logical_voices,
    last_bus_revision: u64 = 0,
    music_trace: ?*MusicGroupTrace = null,
    terminal: [max_instances]TerminalVoice = [_]TerminalVoice{.{}} ** max_instances,
    group_bindings: [music_group.max_groups]?struct { control: GroupHandle, render: music_group.Handle, has_streams: bool, context: u64, transport_epoch: u64, sequence: u64 } = @splat(null),
    stream_visibility_error: bool = false,
    stream_starvation: music.trace.metrics.Counter = .{ .support = .init(.invalid) },
    // Observation only, not a lock: the host still owns one serialized Render
    // caller. Odd means a render call is active. Exhaustion is permanent and
    // fail-closed, so wrap cannot alias an earlier complete capture.
    call_sequence: std.atomic.Value(u64) = .init(0),
    call_sequence_exhausted: std.atomic.Value(bool) = .init(false),

    fn causalReplay(self: *RuntimeRenderer, point: CausalReplayPoint) void {
        if (self.prerequisite_order) |order| order.pointFor(.render, captureOrderSite(point.site), captureOrderEdge(point.edge), point.index, point.generation, captureOrderValue(point));
        if (self.offline_causal_replay) |hooks| hooks.checkpoint(hooks.context, point);
        if (self.live_semantic_hooks) |hooks| {
            const cut: live_semantic.Point = .{ .role = .render, .site = captureOrderSite(point.site), .edge = captureOrderEdge(point.edge), .index = point.index, .generation = point.generation, .value = captureOrderValue(point) };
            if (live_semantic.allowedPoint(cut)) hooks.point(hooks.context, cut);
        }
    }
    fn ownedRenderFacts(self: *const RuntimeRenderer) ?owned_render_facts.Hook {
        if (comptime @import("builtin").is_test) return self.test_owned_render_facts;
        return null;
    }
    fn ownedRenderStage(self: *RuntimeRenderer, stage: render_causal_witness.CallSubstage) void {
        if (comptime @import("builtin").is_test) self.test_owned_render_stage = stage;
    }
    fn ownedResource(self: *RuntimeRenderer, value: render_causal_witness.ResourceEvent) void {
        if (comptime @import("builtin").is_test) if (self.test_owned_render_facts) |hook| {
            var copied = value;
            copied.substage = self.test_owned_render_stage;
            hook.event(.{ .resource = copied });
        };
    }
    pub fn init(runtime: *ControlRuntime, sample_rate: u32) RuntimeRenderer {
        var result: RuntimeRenderer = undefined;
        result.initInPlace(runtime, sample_rate);
        return result;
    }

    pub fn initWithLayout(runtime: *ControlRuntime, sample_rate: u32, layout: channel_layout.ChannelLayout) RuntimeError!RuntimeRenderer {
        var result: RuntimeRenderer = undefined;
        try result.initWithLayoutInPlace(runtime, sample_rate, layout);
        return result;
    }

    /// Host-exclusive construction at the renderer's final address. Prefer
    /// this form on bounded stacks; the compatible by-value wrappers may need
    /// multiple renderer-sized Debug return temporaries.
    pub fn initInPlace(self: *RuntimeRenderer, runtime: *ControlRuntime, sample_rate: u32) void {
        self.initWithLayoutInPlace(runtime, sample_rate, channel_layout.stereo) catch @panic("invalid or already-bound RuntimeRenderer");
    }

    /// All fallible checks precede output or DSP mutation. The existing binding
    /// guard still serializes this constructor with voice-profile admission.
    pub fn initWithLayoutInPlace(self: *RuntimeRenderer, runtime: *ControlRuntime, sample_rate: u32, layout: channel_layout.ChannelLayout) RuntimeError!void {
        // A second renderer would silently erase active DSP and its leases.
        // Bind once per Control lifetime; no callback ever initializes storage.
        try layout.validate();
        if (sample_rate == 0) return error.InvalidArgument;
        // This guard is separate from control_active: ordinary Control ticks may
        // overlap initial renderer construction without a spurious rejection.
        if (runtime.voice_binding_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer runtime.voice_binding_active.store(false, .release);
        runtime.voiceBindingHook(.renderer_claimed);
        if (runtime.rendererSampleRate() != null) return error.InvalidState;
        if (runtime.voice_admission) |admission| if (sample_rate != admission.voice.sample_rate) return error.InvalidArgument;
        runtime.render_mixer.initInPlace(sample_rate, layout) catch unreachable;
        const defaults: RuntimeRenderer = .{ .runtime = undefined, .mixer = undefined };
        @memcpy(std.mem.asBytes(self), std.mem.asBytes(&defaults));
        self.runtime = runtime;
        self.mixer = &runtime.render_mixer;
        runtime.renderer_sample_rate.store(sample_rate, .release);
    }

    pub fn musicGroup(self: *RuntimeRenderer, handle: GroupHandle) ?*music_group.MusicVoiceGroup {
        if (handle.index >= self.group_bindings.len) return null;
        const binding = self.group_bindings[handle.index] orelse return null;
        if (!binding.control.eql(handle)) return null;
        return self.mixer.groupFor(binding.render);
    }

    pub fn renderFrame(self: *const RuntimeRenderer) u64 {
        return self.runtime.scheduled.render_frame.load(.acquire);
    }

    pub fn callObservation(self: *const RuntimeRenderer) CallObservation {
        return .{ .sequence = self.call_sequence.load(.acquire), .exhausted = self.call_sequence_exhausted.load(.acquire) };
    }

    /// First narrow binding: serialized direct Render only. Host must exclude
    /// unregistered direct/adapter calls, consumers and requests across lifecycle.
    /// Registered callbacks are rejected until explicit detach. No callback
    /// session/quantum binding is claimed by this API.
    pub fn attachRenderCausalWitness(self: *RuntimeRenderer, bridge: *render_causal_witness.Bridge, token: DeviceQuiescence, interval_id: u64) !render_causal_witness.Session {
        try self.validateDeviceQuiescence(token);
        if (self.ownedRenderFacts() != null) return error.InvalidState;
        if (self.runtime.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.runtime.control_active.store(false, .release);
        if (self.render_causal_binding != null or self.runtime.render_causal_attached or self.runtime.tick_v1.active.load(.acquire) != 0 or interval_id == 0) return error.InvalidState;
        const owner = self.runtime.music_runtime orelse return error.InvalidState;
        if (owner.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer owner.control_guard.store(false, .release);
        if (!owner.usesIntegratedTickV1() or owner.control != self.runtime or owner.renderer != self or owner.control_torn_down) return error.InvalidState;
        const frontier = self.runtime.control_frontier_binding orelse return error.InvalidState;
        const acceptance = self.runtime.stream_acceptance_binding orelse return error.InvalidState;
        if (frontier.session.interval_id != interval_id or acceptance.session.interval_id != interval_id) return error.InvalidState;
        try capture_handoff_control.validatePeers(try bridge.continuousSession(), try frontier.bridge.continuousSession());
        try capture_handoff_control.validatePeers(try bridge.continuousSession(), try acceptance.bridge.continuousSession());
        if (try bridge.continuousSession()) |continuous| try capture_handoff_control.validateAttachment(continuous, .render, interval_id);
        const frontier_status = try frontier.bridge.status(frontier.session);
        const acceptance_status = try acceptance.bridge.status(acceptance.session);
        if (frontier_status.closed or frontier_status.incomplete or acceptance_status.closed or acceptance_status.incomplete) return error.InvalidState;
        const call = self.callObservation();
        if (call.exhausted or call.sequence & 1 != 0) return error.InvalidState;
        if (self.render_causal_owner_identity == 0) self.render_causal_owner_identity = try render_causal_witness.allocateOwnerIdentity();
        const manifest: render_causal_witness.Manifest = .{
            .interval_id = interval_id,
            .renderer_identity = self.render_causal_owner_identity,
            .control_frontier = .{ .incarnation = frontier.session.incarnation, .generation = frontier.session.generation, .owner_identity = frontier.session.owner_identity, .interval_id = frontier.session.interval_id },
            .stream_acceptance = .{ .incarnation = acceptance.session.incarnation, .generation = acceptance.session.generation, .owner_identity = acceptance.session.owner_identity, .interval_id = acceptance.session.interval_id },
            .music_handle_incarnation = owner.handle_incarnation,
            .music_context = owner.config.context,
            .sample_rate = self.mixer.sample_rate,
            .channels = self.mixer.output_layout.count,
            .initial_frame = self.renderFrame(),
            .initial_call_sequence = call.sequence,
            .initial_gate = self.runtime.scheduled.gate_number,
            .transport_epoch = self.runtime.scheduled.transport_epoch,
            .asset_generation = self.runtime.scheduled.asset_generation,
        };
        const session = try bridge.attachQuiescent(self, manifest);
        self.render_causal_binding = .{ .bridge = bridge, .session = session, .music_owner = owner };
        self.runtime.render_causal_attached = true;
        return session;
    }
    /// Fallback when no next call will acknowledge stop. Requires the same
    /// host exclusion as attach; closing does not detach/free any owner.
    pub fn closeRenderCausalWitness(self: *RuntimeRenderer, token: DeviceQuiescence, session: render_causal_witness.Session) !void {
        try self.validateDeviceQuiescence(token);
        if (self.runtime.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.runtime.control_active.store(false, .release);
        if (self.runtime.readiness_binding != null) return error.DrainPending;
        const binding = self.render_causal_binding orelse return error.InvalidState;
        if (!std.meta.eql(binding.session, session) or self.runtime.music_runtime != binding.music_owner) return error.StaleSession;
        if (binding.music_owner.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer binding.music_owner.control_guard.store(false, .release);
        if (self.runtime.tick_v1.active.load(.acquire) != 0) return error.InvalidState;
        const call = self.callObservation();
        if (call.exhausted) binding.bridge.markIncomplete(.counter_exhausted);
        try binding.bridge.closeQuiescent(session, self, self.renderFrame(), call.sequence, self.runtime.scheduled.gate_number);
    }
    pub fn detachRenderCausalWitness(self: *RuntimeRenderer, token: DeviceQuiescence, session: render_causal_witness.Session) !void {
        try self.validateDeviceQuiescence(token);
        if (self.runtime.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.runtime.control_active.store(false, .release);
        if (self.runtime.readiness_binding != null) return error.DrainPending;
        const binding = self.render_causal_binding orelse return error.InvalidState;
        if (!std.meta.eql(binding.session, session) or self.runtime.music_runtime != binding.music_owner) return error.StaleSession;
        if (binding.music_owner.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer binding.music_owner.control_guard.store(false, .release);
        if (self.runtime.tick_v1.active.load(.acquire) != 0) return error.InvalidState;
        try binding.bridge.detachQuiescent(session, self);
        self.render_causal_binding = null;
        self.runtime.render_causal_attached = false;
    }
    fn causalIncomplete(self: *RuntimeRenderer, failure: render_causal_witness.Failure) void {
        if (self.render_causal_binding) |binding| if (!binding.bridge.closed.load(.acquire)) binding.bridge.markIncomplete(failure);
    }

    /// Host only. Stop/uninit the device (or serialize the offline caller) first.
    /// A lost flag alone does not establish quiescence. The claim additionally
    /// rejects overlap with an already running Render invocation.
    pub fn acquireDeviceQuiescence(self: *RuntimeRenderer) RuntimeError!DeviceQuiescence {
        if (self.device_callbacks_active.load(.acquire)) return error.DrainPending;
        if (self.device_access.cmpxchgStrong(0, 2, .acq_rel, .acquire) != null) return error.DrainPending;
        errdefer self.device_access.store(0, .release);
        if (self.device_callbacks_active.load(.acquire)) return error.DrainPending;
        if (self.device_quiescence_incarnation == std.math.maxInt(u64)) return error.InvalidState;
        self.device_quiescence_incarnation += 1;
        self.device_quiescence_active.store(self.device_quiescence_incarnation, .release);
        return .{ .renderer = self, .context = self.runtime, .incarnation = self.device_quiescence_incarnation };
    }
    /// Backend start owns this registration before asking the driver to call.
    /// Merely observing a gap between live callbacks cannot mint a host token.
    pub fn registerDeviceCallbacks(self: *RuntimeRenderer) core.BuguError!void {
        if (self.device_access.cmpxchgStrong(0, 3, .acq_rel, .acquire) != null) return error.InvalidState;
        defer self.device_access.store(0, .release);
        if (@import("builtin").is_test) if (self.test_device_registration_hook) |hook| hook.call(hook.context);
        if (self.render_causal_binding != null) return error.InvalidState; // direct-only causal binding
        if (self.device_callbacks_active.swap(true, .acq_rel)) return error.InvalidState;
    }
    /// Backend only, after successful stop/uninit has joined all callbacks.
    pub fn unregisterDeviceCallbacksQuiescent(self: *RuntimeRenderer) void {
        self.device_callbacks_active.store(false, .release);
    }
    pub fn validateDeviceQuiescence(self: *const RuntimeRenderer, token: DeviceQuiescence) RuntimeError!void {
        if (token.renderer != self or token.context != self.runtime or token.incarnation == 0 or token.incarnation != self.device_quiescence_active.load(.acquire) or self.device_access.load(.acquire) != 2) return error.InvalidState;
    }
    pub fn releaseDeviceQuiescence(self: *RuntimeRenderer, token: DeviceQuiescence) RuntimeError!void {
        try self.validateDeviceQuiescence(token);
        // Only one holder can retire a transferred token, even if two host
        // callers accidentally attempt release concurrently. Invalidate before
        // opening the renderer to registration or another quiescence claim.
        if (self.device_quiescence_active.cmpxchgStrong(token.incarnation, 0, .acq_rel, .acquire) != null) return error.InvalidState;
        self.device_access.store(0, .release);
    }
    /// Actual discontinuity fence. The same scheduler creates the cancellation
    /// records and the same mixer creates group terminals. No fabricated phase,
    /// elapsed sample, second mixer, allocation, or SFX reset occurs here.
    pub fn deviceLossFenceQuiescent(self: *RuntimeRenderer, token: DeviceQuiescence, owner: *music.MusicRuntime) RuntimeError!?resident_transaction.Physical {
        try self.validateDeviceQuiescence(token);
        if (self.runtime.music_runtime != owner or !owner.control_guard.load(.acquire)) return error.InvalidState;
        const local_control = owner.tick_scope == null;
        if (local_control and self.runtime.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer if (local_control) self.runtime.control_active.store(false, .release);
        self.causalIncomplete(.unsupported_epoch);
        const frame = self.renderFrame();
        const physical = if (owner.active_group) |handle| self.physicalResident(handle) else null;
        const schedule = &self.runtime.scheduled;
        schedule.beginGate(frame);
        var owned_plans: [scheduler.default_profile.plan_capacity]bool = @splat(false);
        // Exact owner ledgers cover a plan between its blocks; actual immutable
        // group payloads cover layer-controller plans owned by this same owner.
        for (&schedule.plans, 0..) |*plan, index| {
            if (!plan.active) continue;
            const handle: scheduler.Handle = .{ .index = @intCast(index), .generation = plan.generation };
            var owned = owner.ownsDevicePlanV1(handle);
            if (!owned) for (&schedule.slots) |*slot| {
                if (slot.state.load(.acquire) == .free or slot.plan_index != index) continue;
                for (slot.block.commands[0..slot.block.count]) |command| if (payloadGroup(command.payload)) |group| {
                    if (group.index < owner.group_generation_credits.len) if (owner.group_generation_credits[group.index]) |credit| {
                        if (credit.group.eql(group)) owned = true;
                    };
                };
            };
            if (owned) {
                owned_plans[index] = true;
                schedule.claimExecution();
                try schedule.cancelDevicePlanAtGate(handle, frame);
            }
        }
        schedule.rejectDeviceIntentsAtGate(&owned_plans, frame);
        for (owner.group_generation_credits) |credit| if (credit) |value| {
            if (self.musicGroup(value.group)) |group| {
                group.detachAutomation(null, .group_stopped, frame);
                self.mixer.detachGroupGraphPrograms(group.handle, .group_stopped, frame);
            }
            self.stopResidentGroupValidated(value.group, frame);
        };
        self.checkLayerPrograms(frame);
        self.checkGraphPrograms(frame);
        self.publishMusicObservations(frame);
        self.collectFinished();
        return physical;
    }

    pub fn render(self: *RuntimeRenderer, output: []f32, frame_count: u32, channels: u16) void {
        self.renderEntered(output, frame_count, channels, false);
    }
    /// Exact adapter entry marker. The initial direct-only causal observer
    /// rejects this lane; old callback observers retain their own semantics.
    pub fn renderFromAdapter(self: *RuntimeRenderer, output: []f32, frame_count: u32, channels: u16) void {
        self.renderEntered(output, frame_count, channels, true);
    }
    fn renderEntered(self: *RuntimeRenderer, output: []f32, frame_count: u32, channels: u16, adapter: bool) void {
        const admission = self.device_access.cmpxchgStrong(0, 1, .acquire, .monotonic);
        if (@import("builtin").is_test) if (self.test_render_admission_hook) |hook|
            hook.call(hook.context, .{ .frame_count = frame_count, .channels = channels, .adapter = adapter, .cas_observed = admission });
        if (admission != null) {
            @memset(output, 0);
            return;
        }
        defer self.device_access.store(0, .release);
        if (adapter) self.causalIncomplete(.unsupported_adapter);
        self.renderOwned(output, frame_count, channels);
    }
    /// Non-realtime teardown takes over the SAME Render implementation after
    /// genuine callback quiescence. Generated samples must be accounted as
    /// discarded by the device adapter; they are never submitted to a driver.
    pub fn renderShutdownQuiescent(self: *RuntimeRenderer, token: DeviceQuiescence, output: []f32, frame_count: u32, channels: u16) RuntimeError!void {
        try self.validateDeviceQuiescence(token);
        if (!self.runtime.scheduled.shutdown_requested.load(.acquire)) return error.InvalidState;
        self.causalIncomplete(.unsupported_shutdown);
        self.renderOwned(output, frame_count, channels);
    }
    fn renderOwned(self: *RuntimeRenderer, output: []f32, frame_count: u32, channels: u16) void {
        const sequence = self.call_sequence.load(.monotonic);
        const observable = sequence & 1 == 0 and sequence <= std.math.maxInt(u64) - 2 and !self.call_sequence_exhausted.load(.monotonic);
        if (observable) self.call_sequence.store(sequence + 1, .release) else self.call_sequence_exhausted.store(true, .release);
        // Includes validation/error returns; no callback path leaves an active
        // observation behind. No allocation, waiting, or completed-frame change.
        var causal: ?*render_causal_witness.Bridge = null;
        var causal_frame: u64 = 0;
        var causal_complete = false;
        var causal_error: u32 = 0;
        const native = self.ownedRenderFacts();
        var native_frame: ?u64 = null;
        var native_error: ?anyerror = null;
        if (native != null) self.ownedRenderStage(.before_gate);
        defer {
            if (observable) self.call_sequence.store(sequence + 2, .release);
            if (causal) |bridge| bridge.endCall(causal_frame, causal_complete, causal_error, if (observable) sequence + 2 else sequence);
            if (native) |hook| hook.event(.{ .call_end = .{ .sequence = if (observable) sequence + 2 else sequence, .frame = native_frame, .completed = causal_complete, .err = native_error } });
        }
        if (channels != self.mixer.output_layout.count or output.len != @as(usize, frame_count) * channels or frame_count == 0) {
            native_error = error.InvalidArgument;
            if (native) |hook| hook.event(.{ .call_begin = .{ .sequence = if (observable) sequence + 1 else sequence, .observable = observable, .requested_frames = frame_count, .channels = channels, .valid = false, .frame = null } });
            if (self.render_causal_binding) |binding| {
                causal_frame = binding.bridge.frame; // last actual completed boundary; no operational reload
                if (binding.bridge.beginCall(if (observable) sequence + 1 else sequence, causal_frame, frame_count, channels, false, observable)) causal = binding.bridge;
                causal_error = @intFromError(error.InvalidArgument);
            }
            @memset(output, 0);
            return;
        }
        // Acquire is bounded and still exercises immutable snapshot lifetime.
        // Playback is exclusively journal/block driven, never replayed from a
        // potentially stale desired snapshot.
        if (self.runtime.tryAcquireSnapshot()) |lease| lease.release() else _ = self.runtime.counters.snapshot_misses.fetchAdd(1, .monotonic);
        const schedule = &self.runtime.scheduled;
        var frame = self.renderFrame();
        causal_frame = frame;
        native_frame = frame;
        if (native) |hook| hook.event(.{ .call_begin = .{ .sequence = if (observable) sequence + 1 else sequence, .observable = observable, .requested_frames = frame_count, .channels = channels, .valid = true, .frame = frame } });
        if (self.render_causal_binding) |binding| {
            if (binding.bridge.beginCall(if (observable) sequence + 1 else sequence, frame, frame_count, channels, true, observable)) causal = binding.bridge;
        }
        const end = std.math.add(u64, frame, frame_count) catch {
            causal_error = @intFromError(error.UnsafeFrameRange);
            native_error = error.UnsafeFrameRange;
            @memset(output, 0);
            return;
        };
        var offset: usize = 0;
        while (frame < end) {
            self.collectFinished();
            schedule.beginGate(frame);
            if (native != null) self.ownedRenderStage(.in_gate);
            if (self.runtime.streaming_service) |service| {
                service.beginRenderGate(schedule.gate_number, frame);
                const replay_mode = service.replay_mode;
                if (native) |hook| hook.event(.{ .gate_begin = .{ .at = .{ .gate = schedule.gate_number, .frame = frame, .order = schedule.gate_order }, .mode = if (replay_mode) .replay else .live } });
                if (causal) |bridge| bridge.beginGate(schedule.gate_number, frame, if (replay_mode) .replay else .live);
                if (!replay_mode) {
                    const frontier_observation = if (causal) |bridge| bridge.reserveFrontier() else null;
                    var native_frontier: owned_render_facts.stream_observation.Frontier = undefined;
                    const reached_frontier = frontier_observation orelse (if (native != null) &native_frontier else null);
                    const frontier = service.publicationFrontierObserved(reached_frontier);
                    if (native) |hook| hook.event(.{ .frontier = .{ .at = .{ .gate = schedule.gate_number, .frame = frame, .order = schedule.gate_order }, .value = reached_frontier.?.* } });
                    if (frontier_observation != null) causal.?.finishFrontier();
                    for (0..service.profile.visibility_capacity) |_| {
                        const attempt = if (causal) |bridge| bridge.reserveStreamAttempt(schedule.gate_order) else null;
                        var native_attempt: owned_render_facts.stream_observation.Attempt = undefined;
                        const reached_attempt = attempt orelse (if (native != null) &native_attempt else null);
                        const result = service.admitPublicationObserved(frontier, schedule.gate_number, frame, schedule.gate_order, reached_attempt) catch |err| {
                            if (native) |hook| hook.event(.{ .stream_attempt = .{ .at = .{ .gate = schedule.gate_number, .frame = frame, .order = schedule.gate_order }, .value = reached_attempt.?.*, .err = err } });
                            if (attempt != null) causal.?.finishStreamAttempt(true);
                            self.stream_visibility_error = true;
                            break;
                        };
                        if (native) |hook| hook.event(.{ .stream_attempt = .{ .at = .{ .gate = schedule.gate_number, .frame = frame, .order = schedule.gate_order }, .value = reached_attempt.?.*, .err = null } });
                        if (attempt != null) causal.?.finishStreamAttempt(false);
                        _ = result orelse break;
                        schedule.gate_order += 1;
                    }
                } else {
                    for (0..service.profile.visibility_capacity) |_| {
                        _ = service.admitReplayPublication(schedule.gate_number, frame, schedule.gate_order) catch {
                            self.stream_visibility_error = true;
                            break;
                        } orelse break;
                        schedule.gate_order += 1;
                    }
                }
            } else {
                if (causal) |bridge| bridge.beginGate(schedule.gate_number, frame, .absent);
                if (native) |hook| hook.event(.{ .gate_begin = .{ .at = .{ .gate = schedule.gate_number, .frame = frame, .order = schedule.gate_order }, .mode = .absent } });
            }
            self.processInvalidations(frame, .before_scan, 0);
            var scan_sink: scheduler.render_observation.Sink = undefined;
            var native_scan: owned_render_facts.Scan = undefined;
            if (causal) |bridge| scan_sink = bridge.scanSink() else if (native) |hook| {
                native_scan = .{ .hook = hook };
                scan_sink = native_scan.sink();
            }
            schedule.acquirePublishedObserved(frame, if (causal != null or native != null) &scan_sink else null);
            self.processInvalidations(frame, .after_scan, 0);
            self.checkLayerPrograms(frame);
            self.checkGraphPrograms(frame);
            var operation: usize = 0;
            while (operation < scheduler.default_profile.immediate_capacity + scheduler.default_profile.command_capacity) : (operation += 1) {
                // Cancellation/claim is serialized by this render owner. The
                // test seam runs before the system lane and then before claim.
                schedule.hook(.before_group);
                self.processInvalidations(frame, .pre_claim, operation);
                self.checkLayerPrograms(frame);
                self.checkGraphPrograms(frame);
                const due = schedule.nextDue(frame);
                const immediate = self.runtime.deltas.peek();
                if (immediate != null) if (causal) |bridge| bridge.markIncomplete(.unsupported_immediate);
                const take_immediate = if (immediate) |d| choose: {
                    if (d.frame > frame) break :choose false;
                    const slot = due orelse break :choose true;
                    const command = slot.block.commands[slot.next_command];
                    // A retained journal head may be older than this gate after
                    // bounded pin/completion pressure. Frames still precede tickets.
                    break :choose d.frame < command.identity.execute_frame or (d.frame == command.identity.execute_frame and scheduler.serialBefore(d.sequence, command.sequence));
                } else false;
                if (take_immediate) {
                    schedule.claimExecution();
                    if (!self.executeDelta(immediate.?, frame)) break;
                    _ = self.runtime.deltas.pop();
                    schedule.hook(.after_group);
                    continue;
                }
                if (due) |slot| {
                    const group = Scheduler.group(slot);
                    schedule.claimExecution();
                    const token = group[0].identity.token;
                    if (self.music_trace) |sink| for (group) |command| {
                        if (scheduledGainCurve(command.payload) != .linear or command.payload == .graph_source_program or command.payload == .graph_source_program_stop or (command.payload == .graph_targets and (self.runtime.bus_manager.?.batch(command.payload.graph_targets.batch) catch unreachable).tracked_duck != null)) sink.incomplete.store(true, .release);
                    };
                    const identity_reason = if (group.len == 1 and group[0].payload == .resident_restore)
                        self.residentIdentityReason(group[0])
                    else if (token.transport_epoch.value() != schedule.transport_epoch)
                        scheduler.trace.Reason.stale_epoch
                    else if (token.asset_generation.value() != schedule.asset_generation)
                        scheduler.trace.Reason.stale_asset_generation
                    else
                        scheduler.trace.Reason.none;
                    const reason: scheduler.trace.Reason = if (group[0].identity.execute_frame < frame) .late else if (identity_reason != .none) identity_reason else if (token.plan_epoch.value() != schedule.fences[slot.fence_index].admitted_epoch.load(.acquire)) .stale_epoch else if (group[0].identity.phase_order != schedule.plans[slot.plan_index].executed_count.load(.acquire)) .invalid_state else self.executeGroup(group);
                    if (reason != .none) for (group) |command| if (command.payload == .group_layer_automation) {
                        const program = self.runtime.layer_manager_published.load(.acquire).?.get(command.payload.group_layer_automation.program) catch unreachable;
                        for (program.desc.tracks, 0..) |_, i| self.traceLayerAutomation(program, i, .rejected_install, frame);
                    };
                    schedule.finishGroup(slot, frame, reason);
                    self.finishResidentPhase(group, reason);
                    schedule.hook(.after_group);
                    continue;
                }
                break;
            }
            var next = schedule.nextFrame(@min(end, frame +| scheduler.default_profile.max_commit_span_frames));
            if (next <= frame) next = @min(end, frame + 1);
            // Exclusive commitment precedes DSP generation. An arriving cancel
            // is bounded by this span and cannot retract its mixed SFX PCM.
            self.causalReplay(.{ .site = .render_commit_horizon, .edge = .before, .value = next });
            schedule.commit_horizon.store(next, .release);
            self.causalReplay(.{ .site = .render_commit_horizon, .edge = .after, .value = next });
            schedule.hook(.before_span);
            const count: u32 = @intCast(next - frame);
            const samples = @as(usize, count) * channels;
            const span_at: owned_render_facts.Position = .{ .gate = schedule.gate_number, .frame = frame, .order = schedule.gate_order };
            const selection = if (native) |hook| owned_render_facts.beginSpan(hook, self.mixer, &self.group_bindings, span_at, next, channels) else owned_render_facts.Selection{};
            self.mixer.renderSpanAt(output[offset..][0..samples], count, channels, &self.telemetry, frame);
            if (native) |hook| owned_render_facts.endSpan(hook, selection, span_at, next);
            if (self.runtime.layer_manager_published.load(.acquire) != null) for (0..layer_spans.max_programs) |i| self.publishLayerTerminal(i);
            self.collectStreamFaults();
            offset += samples;
            frame = next;
            if (self.runtime.streaming_service) |service| service.endRenderSpan(frame);
            if (self.bus_graph) |graph| self.runtime.bus_manager.?.publish(graph, frame);
            self.publishMusicObservations(frame);
            const shutdown = schedule.shutdown_requested.load(.acquire);
            if (shutdown) if (causal) |bridge| bridge.markIncomplete(.unsupported_shutdown);
            if (shutdown and self.activeVoiceCount() == 0) self.retireBusGraph(next);
            self.causalReplay(.{ .site = .render_frame, .edge = .before, .value = frame });
            schedule.render_frame.store(frame, .release);
            self.causalReplay(.{ .site = .render_frame, .edge = .after, .value = frame });
            if (self.runtime.streaming_service) |service| service.frontierHook(.after_runtime_frame, frame);
            if (causal) |bridge| bridge.endGate(frame, schedule.gate_order);
            if (native) |hook| {
                hook.event(.{ .gate_end = .{ .gate = schedule.gate_number, .frame = frame, .order = schedule.gate_order } });
                self.ownedRenderStage(.after_gate);
            }
            native_frame = frame;
            causal_frame = frame;
            self.collectFinished();
        }
        causal_complete = true;
    }

    fn traceLayerAutomation(self: *RuntimeRenderer, slot: *const layer_runtime.Slot, index: usize, operation: music.trace.schema.LayerAutomationOperation, frame: u64) void {
        const sink = self.music_trace orelse return;
        const anchor = slot.desc.anchor;
        const track = slot.desc.tracks[index];
        const binding = slot.binding.?;
        const terminal = if (operation == .terminal) slot.cursors[index].terminal else null;
        const group = self.musicGroup(.{ .index = anchor.group.index, .generation = anchor.group.generation });
        const gain_bits = if (terminal) |t| t.gain_bits else if (group) |g| @as(u32, @bitCast(g.layers[track.ordinal].gain_current)) else @as(u32, @bitCast(track.initial_prediction));
        _ = sink.push(.{ .layer_automation = .{
            .operation = operation,
            .context = anchor.context,
            .group = anchor.group.generation,
            .stable_layer_id = track.stable_layer_id,
            .ordinal = track.ordinal,
            .program_generation = slot.generation,
            .content_hash = slot.desc.content_hash,
            .profile_hash = slot.profile_hash,
            .command_id = binding.command_id,
            .plan_id = binding.plan_id,
            .plan_epoch = binding.plan_epoch,
            .phase_id = binding.phase_id,
            .phase_order = binding.phase_order,
            .transport_epoch = anchor.transport_epoch,
            .asset_generation = anchor.bank_generation,
            .binding_revision = anchor.binding_revision,
            .planned_frame = anchor.install_frame,
            .actual_frame = if (terminal) |t| t.frame else frame,
            .source_start_cursor = anchor.cursor,
            .source_start_loop_epoch = anchor.loop_epoch,
            .elapsed_source_frames = if (terminal) |t| t.elapsed_source_frames else 0,
            .source_endpoint = track.source_endpoint,
            .duration_domain = @intFromEnum(track.domain),
            .duration_numerator = track.duration_numerator,
            .duration_denominator = track.duration_denominator,
            .endpoint_rounding = @intFromEnum(track.endpoint_rounding),
            .gain_bits = gain_bits,
            .final_gain_bits = @bitCast(track.final_target),
            .terminal_reason = if (terminal) |t| @intFromEnum(t.reason) else if (operation == .rejected_install) @intFromEnum(layer_spans.TerminalReason.install_rejected) else 0,
            .release_frontier = if (terminal) |t| t.release_frontier else frame,
            .audible = if (terminal) |t| t.audible else false,
        } });
    }
    fn publishLayerTerminal(self: *RuntimeRenderer, index: usize) void {
        const manager = self.runtime.layer_manager_published.load(.acquire).?;
        const slot = &manager.slots[index];
        if (slot.state.load(.acquire) != .active) return;
        for (slot.cursors[0..slot.desc.tracks.len]) |cursor| if (cursor.terminal == null) return;
        for (slot.desc.tracks, 0..) |_, i| self.traceLayerAutomation(slot, i, .terminal, 0);
        manager.publishTerminal(index); // Last access; Control may reclaim later.
    }
    fn checkLayerPrograms(self: *RuntimeRenderer, frame: u64) void {
        const manager = self.runtime.layer_manager_published.load(.acquire) orelse return;
        const schedule = &self.runtime.scheduled;
        for (&manager.slots, 0..) |*slot, i| {
            if (slot.state.load(.acquire) != .active) continue;
            const a = slot.desc.anchor;
            const group = self.musicGroup(.{ .index = a.group.index, .generation = a.group.generation });
            const reason: ?layer_spans.TerminalReason = if (schedule.shutdown_requested.load(.acquire)) .shutdown else if (slot.binding.?.admitted_epoch.load(.acquire) != slot.binding.?.plan_epoch) .plan_epoch_invalidated else if (schedule.transport_epoch != slot.effective_transport_epoch) .transport_invalidated else if (schedule.asset_generation != a.bank_generation) .asset_invalidated else if (group == null or group.?.state == .finished) .group_ended else if (group.?.state != .playing) .group_stopped else if (group.?.mutation_epoch != slot.effective_mutation_epoch or group.?.generation != a.bank_generation) .source_replaced else null;
            if (reason) |why| {
                if (group) |g| g.detachAutomation(.{ .context = a.context, .index = @intCast(i), .generation = slot.generation }, why, frame);
                // A missing group can only follow a group detach; never invent
                // completion for a pointer that could still be in a mixer slot.
            }
            self.publishLayerTerminal(i);
        }
    }
    /// Pending installs bind an immutable admitted physical identity hash. The
    /// original PreparedLayer supplies authored metadata only after transfer.
    fn graphProgramPreparedSourceMatches(self: *RuntimeRenderer, handle: GroupHandle, current: *const music_group.MusicVoiceGroup, program: *const graph_clock_runtime.Slot) bool {
        if (handle.index >= self.runtime.prepared_groups.len) return false;
        const original = &self.runtime.prepared_groups[handle.index];
        const ordinal = program.desc.progress.tracks[0].ordinal;
        if (!original.occupied or original.generation != handle.generation or current.prepared != &original.prepared or ordinal >= current.layer_count or ordinal >= original.prepared.layer_count) return false;
        if (original.graph_source_replaced.load(.acquire) & (@as(u16, 1) << @intCast(ordinal)) != 0) return false;
        if (current.layers[ordinal].prepared != &original.prepared.layers[ordinal]) return false;
        const actual = hashGraphSourceBinding(handle, &original.prepared, ordinal, current.layers[ordinal].stream(), program.source_binding);
        return std.mem.eql(u8, &actual, &program.source_binding.hash);
    }
    fn checkLayerContinuity(self: *RuntimeRenderer, handle: GroupHandle, current: *const music_group.MusicVoiceGroup, desc: *const music_group.SourceContinuity) bool {
        const manager = self.runtime.layer_manager_published.load(.acquire) orelse return true;
        for (&manager.slots) |*slot| {
            if (slot.state.load(.acquire) != .active) continue;
            const anchor = slot.desc.anchor;
            if (anchor.group.index != handle.index or anchor.group.generation != handle.generation) continue;
            if (anchor.source_incarnation != desc.source_incarnation or slot.effective_transport_epoch != desc.old_transport_epoch or slot.effective_mutation_epoch != desc.mutation_epoch) return false;
            for (slot.desc.tracks, 0..) |track, i| {
                if (track.ordinal >= current.layer_count) return false;
                // Completed/superseded tracks have already detached their
                // cursor. Other tracks in this same program may still advance.
                if (slot.cursors[i].terminal == null and current.layers[track.ordinal].automation != &slot.cursors[i]) return false;
            }
        }
        return true;
    }
    fn checkGraphPrograms(self: *RuntimeRenderer, frame: u64) void {
        const manager = self.runtime.graph_clock_manager_published.load(.acquire) orelse return;
        for (&manager.slots, 0..) |*slot, i| {
            if (slot.state.load(.acquire) != .active) continue;
            // No bounded canonical replay record exists for these new programs
            // yet. An attached sink must report incomplete, never fabricate a
            // legacy gain/graph-frame event or change the live DSP decision.
            if (self.music_trace) |sink| sink.incomplete.store(true, .release);
            const a = slot.desc.progress.anchor;
            const group = self.musicGroup(.{ .index = a.group.index, .generation = a.group.generation });
            const schedule = &self.runtime.scheduled;
            const reason: ?graph_clock.Reason = if (schedule.shutdown_requested.load(.acquire)) .shutdown else if (slot.binding.?.admitted_epoch.load(.acquire) != slot.binding.?.plan_epoch) .plan_invalidated else if (self.mixer.graphProgramTransportEpoch(.{ .context = a.context, .index = @intCast(i), .generation = slot.generation }) != schedule.transport_epoch) .transport_invalidated else if (schedule.asset_generation != a.bank_generation) .asset_invalidated else if (group == null or group.?.state == .finished) .group_ended else if (group.?.state != .playing) .group_stopped else if (self.runtime.prepared_groups[a.group.index].graph_source_replaced.load(.acquire) & (@as(u16, 1) << @intCast(slot.desc.progress.tracks[0].ordinal)) != 0 or !self.mixer.graphProgramSourceMatches(.{ .context = a.context, .index = @intCast(i), .generation = slot.generation }, group.?)) .source_replaced else null;
            if (reason) |why| self.mixer.detachGraphProgram(.{ .context = a.context, .index = @intCast(i), .generation = slot.generation }, why, frame, frame);
        }
    }
    fn publishMusicObservations(self: *RuntimeRenderer, frame: u64) void {
        _ = self.runtime.music_observation_sequence.fetchAdd(1, .acq_rel);
        for (self.group_bindings, 0..) |maybe, i| {
            const binding = maybe orelse continue;
            const group = self.mixer.groupFor(binding.render) orelse continue;
            const words = &self.runtime.music_observations[i].words;
            const header = [_]u64{ binding.control.generation, group.generation, group.mutation_epoch, group.cursor, group.loop_epoch, @intFromBool(group.paused), @intFromEnum(group.state), @as(u64, @as(u32, @bitCast(group.gain_current))) | (@as(u64, @as(u32, @bitCast(self.mixer.music_gain))) << 32), group.layer_count, @intFromBool(group.loop != null), if (group.loop) |l| l.start else 0, if (group.loop) |l| l.end else 0, self.runtime.scheduled.transport_epoch, group.virtualized, group.realized, group.dropped, group.stolen, if (self.bus_graph) |h| h.generation else 0, group.source_incarnation };
            for (header, 0..) |value, j| words[j].store(value, .release);
            for (group.layers[0..group.layer_count], 0..) |layer, j| {
                const at = 19 + j * 13;
                const values = [_]u64{ @intFromEnum(layer.state), @as(u32, @bitCast(layer.gain_current)), if (group.state == .finished) 0 else if (layer.stream()) |source| source.identity.stream_generation else 0, layer.last_change_frame, layer.sample_reads, @as(u64, @bitCast(self.mixer.groupLayerRouteBound(group.handle, @intCast(j)))), @intFromBool(self.mixer.groupLayerDetectorDependency(group.handle, @intCast(j))), if (layer.automation) |cursor| cursor.program.generation else 0, if (layer.automation) |cursor| cursor.binding_revision else 0, if (layer.automation) |cursor| cursor.elapsed else 0, if (layer.automation) |cursor| cursor.next_span else 0, @as(u32, @bitCast(if (layer.automation) |cursor| cursor.remainingGain(layer.gain_current) else layer.gain_current)), @intFromBool(group.paused) };
                for (values, 0..) |value, k| words[at + k].store(value, .release);
            }
        }
        self.runtime.music_observation_transport.store(self.runtime.scheduled.transport_epoch, .release);
        self.runtime.music_observation_generation.store(self.runtime.scheduled.asset_generation, .release);
        self.runtime.music_observation_frame.store(frame, .release);
        _ = self.runtime.music_observation_sequence.fetchAdd(1, .release);
    }

    pub fn releaseStreamVisibility(self: *RuntimeRenderer, release: music.trace.replay.GateRelease) (RuntimeError || streaming.stream.Error)!music.trace.replay.GateObservation {
        const service = self.runtime.streaming_service orelse return error.InvalidState;
        if (!service.replay_mode or self.stream_visibility_error) return error.ReplayMismatch;
        return service.observedVisibility(release);
    }
    fn processInvalidations(self: *RuntimeRenderer, frame: u64, phase: scheduler.InvalidationPhase, iteration: u64) void {
        const schedule = &self.runtime.scheduled;
        schedule.markInvalidationPass(frame, phase, iteration);
        const native = self.ownedRenderFacts();
        const position: owned_render_facts.InvalidationPosition = .{ .at = .{ .gate = schedule.gate_number, .frame = frame, .order = schedule.gate_order }, .phase = phase, .iteration = iteration };
        var shutdown_observed = false;
        schedule.shutdownAtGateObserved(frame, if (self.render_causal_binding != null or native != null) &shutdown_observed else null);
        if (native) |hook| hook.event(.{ .shutdown_pass = .{ .at = position, .any_shutdown = shutdown_observed } });
        if (shutdown_observed) self.causalIncomplete(.unsupported_shutdown);
        const observer = if (self.render_causal_binding) |binding| (if (binding.bridge.manifest.capture_terminal_invalidations) binding.bridge else null) else null;
        for (0..scheduler.emergency_capacity) |_| {
            const poll = if (observer) |bridge| bridge.reserveInvalidationPoll(schedule.gate_order) else null;
            var native_poll: scheduler.render_observation.InvalidationPoll = undefined;
            const reached_poll = poll orelse (if (native != null) &native_poll else null);
            const next = schedule.nextInvalidationObserved(reached_poll);
            if (native) |hook| hook.event(.{ .invalidation_poll = .{ .at = .{ .at = .{ .gate = schedule.gate_number, .frame = frame, .order = schedule.gate_order }, .phase = phase, .iteration = iteration }, .value = reached_poll.?.* } });
            if (poll != null) observer.?.finishInvalidationPoll();
            const intent = next orelse break;
            if (observer == null) self.causalIncomplete(.unsupported_invalidation);
            if (intent.value.emergency_stop_music) for (&self.voices) |*voice| {
                if (!voice.active or voice.bus != .music) continue;
                self.mixer.stopVoiceAt(voice.handle, scheduler.default_profile.emergency_ramp_frames, frame, .stopped) catch {};
                voice.stopping = true;
            };
            schedule.claimExecution();
            const result = if (observer) |bridge| bridge.reserveInvalidationResult(schedule.gate_order) else null;
            var native_result: scheduler.render_observation.InvalidationResult = undefined;
            const reached_result = result orelse (if (native != null) &native_result else null);
            schedule.applyInvalidationObserved(intent, frame, reached_result);
            if (native) |hook| hook.event(.{ .invalidation_result = .{ .at = .{ .at = .{ .gate = schedule.gate_number, .frame = frame, .order = schedule.gate_order }, .phase = phase, .iteration = iteration }, .value = reached_result.?.* } });
            // apply copied everything before finishIntent exposed reclamation.
            // The support verdict uses those actual operands, never a precheck.
            if (result) |read| observer.?.finishInvalidationResult(read.supported);
        }
    }

    fn executeDelta(self: *RuntimeRenderer, delta_command: RenderDelta, frame: u64) bool {
        switch (delta_command.payload) {
            .play => |wanted| {
                if (!self.mixer.canStartLegacyVoice(wanted.params.bus, wanted.params.reverb_send)) {
                    if (!self.runtime.pushRenderCompletion(.{ .instance = wanted.instance, .reason = .rejected, .start_order = wanted.start_order }, completionOrderBinding(self.prerequisite_order))) return false;
                    self.markTerminal(wanted.instance, wanted.start_order);
                    releasePlayOwner(wanted.owner, wanted.custody);
                    return true;
                }
                const terminal = self.terminal[wanted.instance.index];
                if (terminal.valid and terminal.generation == wanted.instance.generation and terminal.start_order == wanted.start_order) {
                    releasePlayOwner(wanted.owner, wanted.custody);
                    return true;
                }
                switch (self.start(wanted)) {
                    .retry => return false,
                    .rejected => {
                        // Permanent custody failure cannot become a voice on a
                        // later callback. Admit a real completion before moving
                        // the journal head or returning its actual PCM role.
                        // Full completion capacity retains this exact journal
                        // owner for retry, without a second physical release.
                        if (!self.runtime.pushRenderCompletion(.{ .instance = wanted.instance, .reason = .rejected, .start_order = wanted.start_order }, completionOrderBinding(self.prerequisite_order))) return false;
                        self.markTerminal(wanted.instance, wanted.start_order);
                    },
                    .started => {},
                }
                releasePlayOwner(wanted.owner, wanted.custody);
            },
            .update => |v| if (self.find(v.command.instance, v.start_order)) |voice| {
                if (voice.stopping) return true;
                self.mixer.updateVoice(voice.handle, v.command.params, v.command.ramp_frames) catch {};
            },
            .stop => |v| {
                self.runtime.instances.terminate(v.command.instance, v.command.reservation);
                if (self.find(v.command.instance, v.start_order)) |voice| {
                    self.mixer.stopVoiceAt(voice.handle, v.command.fade_frames, frame, v.group_reason) catch {};
                    voice.stopping = true;
                } else {
                    const terminal = self.terminal[v.command.instance.index];
                    if (terminal.valid and terminal.generation == v.command.instance.generation and terminal.start_order == v.start_order) return true;
                    if (!self.runtime.pushRenderCompletion(.{ .instance = v.command.instance, .reason = .stopped, .start_order = v.start_order }, completionOrderBinding(self.prerequisite_order))) return false;
                    self.markTerminal(v.command.instance, v.start_order);
                }
            },
            .bus => |bus| self.executeBus(bus),
        }
        return true;
    }

    fn retireBusGraph(self: *RuntimeRenderer, frame: u64) void {
        const handle = self.bus_graph orelse return;
        const slot = self.runtime.bus_manager.?.get(handle) catch unreachable;
        self.mixer.detachAllGraphPrograms(.graph_retired, frame);
        self.mixer.unbindGraph() catch unreachable;
        slot.graph.detachTrackedDucks(frame);
        self.bus_graph = null;
        // Last access before Control may observe inactive and reclaim the graph.
        slot.active.store(false, .release);
    }
    fn preflightBusGroup(self: *RuntimeRenderer, commands: []const ScheduledCommand) scheduler.trace.Reason {
        var active = self.bus_graph;
        var trial: bus_runtime.Trial = undefined;
        var have_trial = false;
        if (active) |handle| {
            trial = bus_runtime.Trial.init((self.runtime.bus_manager.?.get(handle) catch return .invalid_handle).graph);
            have_trial = true;
        }
        for (commands, 0..) |command, i| {
            switch (command.payload) {
                .graph_install => |v| {
                    if (i != 0 or active != null or self.activeVoiceCount() != 0 or self.runtime.scheduled.shutdown_requested.load(.acquire)) return .invalid_state;
                    const manager = self.runtime.bus_manager orelse return .invalid_handle;
                    const slot = manager.get(v.graph) catch return .invalid_handle;
                    if (slot.activated or slot.active.load(.acquire) or self.mixer.sample_rate != 48000 or !channel_layout.ChannelLayout.eql(slot.catalog.output_layout, self.mixer.output_layout)) return .invalid_state;
                    self.mixer.validateGraphBinding(&slot.binding) catch return .invalid_state;
                    active = v.graph;
                    trial = bus_runtime.Trial.init(slot.graph);
                    have_trial = true;
                },
                .graph_retire => |v| {
                    if (commands.len != 1 or active == null or !active.?.eql(v.graph) or self.activeVoiceCount() != 0) return .invalid_state;
                    active = null;
                },
                .graph_source_program => |v| {
                    if (!have_trial or active == null) return .invalid_state;
                    const clocks = self.runtime.graph_clock_manager_published.load(.acquire) orelse return .invalid_handle;
                    const program = clocks.get(v.program) catch return .invalid_handle;
                    const g = program.desc.graph;
                    if (g.context != active.?.context or g.index != active.?.index or g.generation != active.?.generation) return .invalid_state;
                    const manager = self.runtime.bus_manager.?;
                    const ordinal = program.desc.progress.tracks[0].ordinal;
                    const lane = manager.layerLane(active.?, layerGraphSource(v.group, ordinal)) catch return .invalid_state;
                    const route = manager.route(lane.route) catch return .invalid_handle;
                    const current = self.musicGroup(v.group) orelse return .invalid_handle;
                    var routed = self.mixer.groupLayerUsesRoutes(current.handle, ordinal, &route.prepared);
                    for (commands[0..i]) |prior| if (prior.payload == .group_bus_route) {
                        const r = prior.payload.group_bus_route;
                        if (r.group.eql(v.group) and r.layer == ordinal) routed = std.meta.eql(r.route, lane.route) and r.ramp_frames == 0;
                    };
                    if (!routed) return .invalid_state;
                    const graph = (manager.get(active.?) catch return .invalid_handle).graph;
                    for (program.desc.targets) |write| {
                        _ = graph.sourceClockValue(write.target) catch return .invalid_state;
                        for (trial.seen[0..trial.seen_count]) |prior| if (bus_runtime.sameTarget(prior, write.target)) return .invalid_state;
                        if (trial.seen_count == trial.seen.len) return .invalid_state;
                        trial.seen[trial.seen_count] = write.target;
                        trial.seen_count += 1;
                    }
                },
                .graph_source_program_stop => {},
                .graph_targets => |v| {
                    if (!have_trial or active == null) return .invalid_state;
                    const manager = self.runtime.bus_manager.?;
                    const batch = manager.batch(v.batch) catch return .invalid_handle;
                    if (batch.layer_source) |source| {
                        const handle = v.group orelse return .invalid_handle;
                        const lane = manager.layerLane(active.?, source) catch return .invalid_state;
                        const route = manager.route(lane.route) catch return .invalid_handle;
                        var routed = false;
                        var paused = false;
                        if (self.musicGroup(handle)) |group| {
                            if (source.source_incarnation != group.source_incarnation) return .stale_epoch;
                            paused = group.paused;
                            routed = self.mixer.groupLayerUsesRoutes(group.handle, source.layer, &route.prepared);
                        }
                        for (commands[0..i]) |prior| {
                            if (prior.payload == .group_bus_route) {
                                const r = prior.payload.group_bus_route;
                                if (r.group.eql(handle) and r.layer == source.layer) routed = r.route.index == lane.route.index and r.route.generation == lane.route.generation and r.route.context == lane.route.context and r.ramp_frames == 0;
                            }
                            if (prior.payload == .group_pause and prior.payload.group_pause.group.eql(handle)) paused = prior.payload.group_pause.paused;
                        }
                        if (!routed or paused) return .invalid_state;
                    }
                    manager.preflightBatch(v.batch, active.?, &trial) catch return .invalid_state;
                },
                .group_bus_route => |v| {
                    const manager = self.runtime.bus_manager orelse return .invalid_handle;
                    const route = manager.route(v.route) catch return .invalid_handle;
                    manager.validateLayerRoute(v.route, layerGraphSourceAt(v.group, v.layer, v.source_incarnation), v.ramp_frames) catch return .invalid_state;
                    if (active == null or !active.?.eql(route.graph)) return .invalid_state;
                    for (commands[0..i]) |prior| if (prior.payload == .group_bus_route and prior.payload.group_bus_route.group.eql(v.group) and prior.payload.group_bus_route.layer == v.layer) return .invalid_state;
                    if (self.musicGroup(v.group)) |group| {
                        if (group.source_incarnation != v.source_incarnation) return .stale_epoch;
                        self.mixer.validateGroupLayerRoutes(group.handle, v.layer, &route.prepared) catch return .invalid_state;
                    } else {
                        var starts = false;
                        for (commands[0..i]) |prior| if (prior.payload == .group_start and prior.payload.group_start.group.eql(v.group)) {
                            starts = true;
                        };
                        if (!starts) return .invalid_handle;
                        if (v.source_incarnation != 1) return .stale_epoch;
                    }
                },
                .update => |v| {
                    if (active) |handle| {
                        const binding = &(self.runtime.bus_manager.?.get(handle) catch return .invalid_handle).binding;
                        if (v.params.reverb_send) |send| if (send > 0 and binding.reverb == null) return .invalid_state;
                    }
                },
                .group_layer => |v| {
                    const change = self.runtime.layerChange(v.change) catch return .invalid_handle;
                    if (change.change.target != .real) if (self.musicGroup(change.group)) |group| {
                        if (self.mixer.groupLayerDetectorDependency(group.handle, change.change.layer)) return .invalid_state;
                    };
                },
                .play => |v| {
                    if (active) |handle| {
                        const binding = &(self.runtime.bus_manager.?.get(handle) catch return .invalid_handle).binding;
                        const permitted = switch (v.params.bus) {
                            .sfx => binding.sfx != null,
                            .music => binding.legacy_music != null,
                            .master => binding.master != null,
                        };
                        if (!permitted or (v.params.reverb_send > 0 and binding.reverb == null)) return .invalid_state;
                    }
                },
                .group_start => |v| if (active != null) {
                    const slot = self.runtime.preparedGroup(v.group) catch return .invalid_handle;
                    if (slot.prepared.matrix.input.kind == .explicit_mask) return .invalid_state;
                    const binding = &(self.runtime.bus_manager.?.get(active.?) catch return .invalid_handle).binding;
                    for (channel_layout.canonical_layouts, 0..) |layout, layout_index| if (channel_layout.ChannelLayout.eql(layout, slot.prepared.matrix.input)) {
                        if (binding.detector_dependencies[layout_index]) {
                            if (slot.prepared.hasVirtual()) return .invalid_state;
                            for (slot.prepared.layers[0..slot.prepared.layer_count]) |layer| if (layer.stream) |source| {
                                const asset_frame = layer.assetFrame(slot.prepared.start_cursor) catch return .target_not_resident;
                                if (!source.ready(asset_frame, slot.prepared.start_loop_epoch)) return .target_not_resident;
                            };
                        }
                    };
                    if (slot.prepared.emergency) |emergency| if (emergency.matrix.input.kind == .explicit_mask) return .invalid_state;
                },
                else => {},
            }
        }
        return .none;
    }
    fn executeBus(self: *RuntimeRenderer, bus: BusCommand) void {
        if (bus.bus == .master) self.mixer.setMasterGain(bus.gain, bus.ramp_frames) else self.mixer.setBusGain(bus.bus, bus.gain);
    }

    fn executeGroup(self: *RuntimeRenderer, commands: []const ScheduledCommand) scheduler.trace.Reason {
        if (self.music_trace) |sink| for (commands) |command| switch (command.payload) {
            .group_bus_route => |value| if (value.source_incarnation != 1) {
                sink.incomplete.store(true, .release);
            },
            .group_layer_gain => |value| if (value.source_incarnation != 1) {
                sink.incomplete.store(true, .release);
            },
            .group_start => |value| if (value.start_curve != .linear) {
                sink.incomplete.store(true, .release);
            },
            .group_stop => |value| if (value.allow_crossfade_source_stop or value.release_curve != .linear) {
                sink.incomplete.store(true, .release);
            },
            else => {},
        };
        const reason = self.executeGroupValidated(commands);
        self.traceBusCommands(commands, reason);
        return reason;
    }
    fn traceBusCommands(self: *RuntimeRenderer, commands: []const ScheduledCommand, reason: scheduler.trace.Reason) void {
        const sink = self.music_trace orelse return;
        const manager = self.runtime.bus_manager orelse return;
        for (commands) |command| {
            const token = command.identity.token;
            const graph_handle: bus_runtime.Handle = switch (command.payload) {
                .graph_install, .graph_retire => |v| v.graph,
                .graph_targets => |v| (manager.batch(v.batch) catch continue).graph,
                .group_bus_route => |v| (manager.route(v.route) catch continue).graph,
                else => continue,
            };
            const graph = manager.get(graph_handle) catch continue;
            var record: music.trace.schema.BusEvent = .{
                .context = token.context.value(),
                .transport_epoch = token.transport_epoch.value(),
                .asset_generation = token.asset_generation.value(),
                .command_id = command.identity.command_id,
                .plan_id = token.plan_id.value(),
                .plan_epoch = token.plan_epoch.value(),
                .phase_id = token.phase_id.value(),
                .phase_order = command.identity.phase_order,
                .sequence = command.sequence,
                .planned_frame = command.identity.execute_frame,
                .executed_frame = command.identity.execute_frame,
                .graph_generation = graph_handle.generation,
                .graph_hash = graph.content_hash,
                .operation = .install,
                .result = if (reason == .none) .success else .rejected,
                .reason = reason,
            };
            switch (command.payload) {
                .graph_install => _ = sink.push(.{ .bus = record }),
                .graph_retire => {
                    record.operation = .retire;
                    _ = sink.push(.{ .bus = record });
                },
                .group_bus_route => |v| {
                    const route = manager.route(v.route) catch unreachable;
                    record.operation = .layer_route;
                    record.artifact_generation = v.route.generation;
                    record.artifact_hash = route.content_hash;
                    record.group = v.group.generation;
                    record.layer = v.layer;
                    record.ramp_frames = v.ramp_frames;
                    _ = sink.push(.{ .bus = record });
                },
                .graph_targets => |v| {
                    const batch = manager.batch(v.batch) catch unreachable;
                    record.artifact_generation = v.batch.generation;
                    record.artifact_hash = batch.content_hash;
                    record.operation_count = batch.count;
                    if (batch.layer_source) |source| {
                        record.group = source.group_generation;
                        record.layer = source.layer;
                    }
                    for (batch.operations[0..batch.count], 0..) |operation, i| {
                        var item = record;
                        item.operation_index = @intCast(i);
                        switch (operation) {
                            .target => |write| {
                                item.operation = .target;
                                item.target = switch (write.target) {
                                    inline else => |_, tag| @field(music.trace.schema.BusTarget, @tagName(tag)),
                                };
                                switch (write.target) {
                                    .channel_gain => |target| {
                                        item.object = target.bus;
                                        item.auxiliary = target.channel;
                                    },
                                    .prepared_route => |target| {
                                        item.object = target.group;
                                        item.auxiliary = target.edge;
                                    },
                                    inline else => |id| item.object = id,
                                }
                                item.value_bits = @bitCast(write.value);
                                item.ramp_frames = write.ramp_frames;
                            },
                            .begin_duck => |duck| {
                                item.operation = .duck_begin;
                                item.object = duck.bus;
                                item.duck_id = duck.target.id;
                                item.value_bits = @bitCast(duck.target.reduction_db);
                                item.priority = duck.target.priority;
                                item.authored_order = duck.target.authored_order;
                                item.attack_frames = duck.target.attack_frames;
                                item.hold_frames = duck.target.hold_frames;
                                item.release_frames = duck.target.release_frames;
                            },
                            .end_duck => |duck| {
                                item.operation = .duck_end;
                                item.object = duck.bus;
                                item.duck_id = duck.id;
                            },
                        }
                        _ = sink.push(.{ .bus = item });
                    }
                },
                else => unreachable,
            }
        }
    }
    fn physicalResident(self: *RuntimeRenderer, handle: GroupHandle) ?resident_transaction.Physical {
        const group = self.musicGroup(handle) orelse return null;
        if (group.state == .free or group.state == .finished) return null;
        return .{ .group = handle, .source_incarnation = group.source_incarnation, .segment = group.segment, .cursor = group.cursor, .loop_epoch = group.loop_epoch, .paused = group.paused, .mutation_epoch = group.mutation_epoch };
    }
    /// The sole permission for a target-generation/target-epoch command to run
    /// against source scheduler identities. Everything here is bounded metadata;
    /// no PCM hashing, cancellation, pin transfer or group mutation is permitted.
    fn residentIdentityReason(self: *RuntimeRenderer, command: ScheduledCommand) scheduler.trace.Reason {
        const value = transactionCommand(command.payload) orelse return .none;
        const slot = self.runtime.resident_transaction_slot.get(value.transaction) catch return .invalid_handle;
        if (slot.state.load(.acquire) != .bound or !std.mem.eql(u8, &slot.content_hash, &value.content_hash)) return .invalid_state;
        if ((slot.desc == .restore) != (command.payload == .resident_restore)) return .invalid_state;
        if (slot.groups().count > slot.groups().items.len) return .invalid_state;
        // Validate all handles before re-hashing the descriptor's fixed-size
        // identity metadata. Referenced immutable group hashes are cached.
        for (slot.groups().items[0..slot.groups().count]) |handle| _ = self.runtime.preparedGroup(handle) catch return .invalid_handle;
        if (slot.desc == .restore) if (slot.desc.restore.replacement) |handle| {
            _ = self.runtime.preparedGroup(handle) catch return .invalid_handle;
        };
        if (slot.plan()) |handle| {
            if (handle.index >= self.runtime.scheduled.plans.len) return .invalid_handle;
            const plan = &self.runtime.scheduled.plans[handle.index];
            if (plan.generation != handle.generation or plan.transaction_refs == 0) return .invalid_handle;
            // Preparation cannot authorize capturing a suffix which an ordered
            // Render cancellation has since revoked. Restores still replace
            // the old plan, and the earlier profiles retain their semantics.
            if (slot.profile() == .stream_fill_v1 and slot.desc == .capture and plan.cancelled.load(.acquire)) return .unsupported_operation;
            if (slot.profile() == .stream_fill_v1 and (plan.total_phases == 0 or plan.total_phases > 4 or plan.command_count > 7 or plan.prepared_phases != plan.total_phases or plan.executed_count.load(.acquire) > plan.total_phases)) return .invalid_state;
        }
        const hash = self.runtime.hashResidentDescriptor(slot);
        if (!std.mem.eql(u8, &hash, &value.content_hash)) return .invalid_state;
        const epoch = switch (slot.desc) {
            .capture => |v| v.transport_epoch,
            .restore => |v| v.expected_transport_epoch,
        };
        const generation = switch (slot.desc) {
            .capture => |v| v.bank_generation,
            .restore => |v| v.expectedBankGeneration(),
        };
        if (self.runtime.scheduled.transport_epoch != epoch) return .stale_epoch;
        if (self.runtime.scheduled.asset_generation != generation) return .stale_asset_generation;
        const token = command.identity.token;
        switch (slot.desc) {
            .capture => |desc| {
                if (token.transport_epoch.value() != epoch) return .stale_epoch;
                if (token.asset_generation.value() != desc.bank_generation) return .stale_asset_generation;
            },
            .restore => |desc| {
                if (desc.install_frame != command.identity.execute_frame or epoch == std.math.maxInt(u64) or desc.new_transport_epoch != epoch + 1 or token.transport_epoch.value() != desc.new_transport_epoch) return .invalid_state;
                if (desc.bank_generation == 0 or token.asset_generation.value() != desc.bank_generation) return .stale_asset_generation;
                if (desc.replacement) |handle| {
                    if (self.runtime.prepared_groups[handle.index].prepared.generation != desc.bank_generation) return .stale_asset_generation;
                }
            },
        }
        if (slot.plan()) |handle| {
            const plan = &self.runtime.scheduled.plans[handle.index];
            if (plan.token.transport_epoch.value() != epoch) return .stale_epoch;
            if (plan.token.asset_generation.value() != generation) return .stale_asset_generation;
        }
        for (slot.groups().items[0..slot.groups().count]) |handle| if (self.runtime.prepared_groups[handle.index].prepared.generation != generation) return .stale_asset_generation;
        return .none;
    }
    fn preflightResident(self: *RuntimeRenderer, command: ScheduledCommand) scheduler.trace.Reason {
        const identity_reason = self.residentIdentityReason(command);
        if (identity_reason != .none) return identity_reason;
        const slot = &self.runtime.resident_transaction_slot;
        const epoch = switch (slot.desc) {
            .capture => |v| v.transport_epoch,
            .restore => |v| v.expected_transport_epoch,
        };
        const cross_generation = slot.desc == .restore and slot.desc.restore.expectedBankGeneration() != slot.desc.restore.bank_generation;
        const seek = slot.desc == .restore and slot.desc.restore.seek_guard != null;
        if (seek and !streamPreviewSeekDescriptor(slot.desc.restore)) return .unsupported_operation;
        const stream_profile = slot.profile() != .resident_v1;
        if (stream_profile) {
            if (self.bus_graph != null) return .unsupported_operation;
            if (slot.profile() == .stream_reload_v1) {
                if (slot.desc != .restore or !streamReloadDescriptor(slot.desc.restore)) return .unsupported_operation;
            } else if (cross_generation) return .unsupported_operation;
            if ((slot.profile() == .stream_direct_v1 or slot.profile() == .stream_reload_v1) and (slot.groups().count > 1 or slot.plan() != null)) return .unsupported_operation;
            // Prepared Control intents are not Render authority. The existing
            // ordered processInvalidations gate arbitrates published cancels
            // before phase claims; an unpublished or unrelated intent cannot
            // veto an otherwise valid restore through a speculative scan.
            if (self.runtime.layer_manager_published.load(.acquire)) |manager| for (&manager.slots) |*program| {
                const state = program.state.load(.acquire);
                if (state == .bound or state == .active) return .unsupported_operation;
            };
            if (self.runtime.graph_clock_manager_published.load(.acquire)) |manager| for (&manager.slots) |*program| {
                const state = program.state.load(.acquire);
                if (state == .bound or state == .active) return .unsupported_operation;
            };
        }
        var sounding: usize = 0;
        for (self.group_bindings) |maybe| if (maybe) |binding| {
            const group = self.mixer.groupFor(binding.render) orelse continue;
            if (group.state == .free or group.state == .finished) continue;
            if (!slot.groups().contains(binding.control)) return .invalid_state;
            if (group.state != .playing or group.source_incarnation != 1 or group.prepared.hasVirtual() or group.degraded) return .unsupported_operation;
            if (stream_profile) {
                const original = &self.runtime.prepared_groups[binding.control.index];
                if (!snapshotPreparedProfile(group.prepared, slot.profile()) or original.graph_source_replaced.load(.acquire) != 0 or original.source_switch.read() != null) return .unsupported_operation;
            } else if (group.prepared.hasStreams()) return .unsupported_operation;
            for (group.layers[0..group.layer_count]) |layer| if (layer.automation != null or layer.state != .real or (stream_profile and layer.source_override != null)) return .unsupported_operation;
            if (cross_generation and (group.paused or group.mutation_epoch != 1)) return .unsupported_operation;
            if (slot.profile() == .stream_reload_v1) {
                const desc = slot.desc.restore;
                // The outgoing clock must reach the frozen promise exactly.
                // This precedes every stop, epoch replacement and source pin.
                if (!streamReloadPhysicalMatches(desc, group)) return .invalid_state;
            }
            if (seek and (!binding.control.eql(slot.desc.restore.seek_guard.?.outgoing) or !streamPreviewSeekPhysicalMatches(slot.desc.restore, group))) return .invalid_state;
            if (slot.desc == .capture or cross_generation or stream_profile) {
                // First-profile snapshots restore authored steady gains and
                // loop bounds. A completed raw mutation is still unsupported;
                // do not silently serialize only its cursor then lose its DSP.
                // Cross-generation replacement has the same steady-profile
                // restriction; legacy same-generation restores are unchanged.
                // Ramp endpoints assign the exact authored target f32, so no
                // tolerance or arithmetic approximation is needed here.
                if (group.ramp_remaining != 0 or group.gain_current != group.prepared.gain or !std.meta.eql(group.loop, group.prepared.loop)) return .unsupported_operation;
                for (group.layers[0..group.layer_count]) |layer| if (layer.ramp_remaining != 0 or layer.gain_current != layer.prepared.gain) return .unsupported_operation;
            }
            if (binding.transport_epoch != epoch) return .stale_epoch;
            sounding += 1;
        };
        if (sounding > 1) return .invalid_state;
        if (cross_generation and sounding != 1) return .unsupported_operation;
        // Ordinary restore may replace Ready or a source that has ended. Seek
        // must still own its one live source at this exact execution gate.
        if (seek and sounding != 1) return .invalid_state;
        for (self.voices) |voice| if (voice.active and voice.bus == .music and !self.mixer.isGroupVoice(voice.handle) and self.mixer.isVoiceActive(voice.handle)) return .invalid_state;
        if (slot.desc == .restore) {
            const desc = slot.desc.restore;
            if (desc.install_frame != command.identity.execute_frame or desc.new_transport_epoch != command.identity.token.transport_epoch.value()) return .invalid_state;
            if (self.runtime.graph_clock_manager_published.load(.acquire)) |manager| for (&manager.slots) |*program| if (program.state.load(.acquire) == .active) return .invalid_state;
            if (desc.replacement) |handle| {
                const replacement = self.runtime.preparedGroup(handle) catch return .invalid_handle;
                if (!self.mixer.canStartGroup(&replacement.prepared)) return .voice_budget_exceeded;
                if (replacement.prepared.start_cursor >= replacement.prepared.frames or (replacement.prepared.loop != null and replacement.prepared.start_cursor >= replacement.prepared.loop.?.end)) return .invalid_state;
                if (stream_profile) {
                    if (!snapshotPreparedProfile(&replacement.prepared, slot.profile()) or replacement.prepared.ramp_frames != 0 or replacement.graph_source_replaced.load(.acquire) != 0 or replacement.source_switch.read() != null) return .unsupported_operation;
                    if (slot.profile() == .stream_reload_v1) {
                        const outgoing = self.runtime.preparedGroup(desc.old_groups.items[0]) catch return .invalid_handle;
                        if (!streamReloadCoordinates(desc, &outgoing.prepared, &replacement.prepared)) return .invalid_state;
                        if (!replacement.prepared.minimumPlayable(replacement.prepared.start_cursor, replacement.prepared.start_loop_epoch)) return .target_not_resident;
                    }
                    if (seek) {
                        const outgoing = self.runtime.preparedGroup(desc.seek_guard.?.outgoing) catch return .invalid_handle;
                        if (!streamPreviewSeekPreparedMatches(desc, &outgoing.prepared, &replacement.prepared)) return .invalid_state;
                        if (!replacement.prepared.minimumPlayable(replacement.prepared.start_cursor, replacement.prepared.start_loop_epoch)) return .target_not_resident;
                    }
                    for (replacement.prepared.layers[0..replacement.prepared.layer_count], 0..) |layer, i| {
                        const fresh = layer.stream orelse return .unsupported_operation;
                        if (!freshSnapshotSource(&replacement.prepared, &layer, fresh, desc.new_transport_epoch)) return .invalid_state;
                        if ((slot.profile() == .stream_reload_v1 or seek) and !fresh.ready(layer.assetFrame(replacement.prepared.start_cursor) catch return .invalid_state, replacement.prepared.start_loop_epoch)) return .target_not_resident;
                        for (replacement.prepared.layers[0..i]) |prior| if (prior.stream) |source| {
                            if (fresh.ring == source.ring) return .invalid_state;
                        };
                        for (desc.old_groups.items[0..desc.old_groups.count]) |old_handle| if (self.musicGroup(old_handle)) |old| {
                            for (old.layers[0..old.layer_count]) |*old_layer| if (old_layer.stream()) |source| {
                                if (sameSnapshotWindow(fresh, source)) return .invalid_state;
                            };
                        };
                    }
                }
            }
        }
        return .none;
    }
    fn sampleResidentResult(self: *RuntimeRenderer, slot: *resident_transaction.Slot, frame: u64) void {
        const schedule = &self.runtime.scheduled;
        slot.result = .{ .kind = std.meta.activeTag(slot.desc), .outcome = .executed, .frame = frame, .gate = schedule.gate_number, .execution_ordinal = schedule.execution_ordinal, .previous_bank_generation = schedule.asset_generation, .previous_transport_epoch = schedule.transport_epoch, .bank_generation = schedule.asset_generation, .transport_epoch = schedule.transport_epoch };
        if (slot.plan()) |handle| {
            const plan = &schedule.plans[handle.index];
            const prefix = plan.executed_count.load(.acquire);
            slot.result.executed_prefix_count = prefix;
            @memcpy(slot.result.executed_frames[0..prefix], plan.executed_frames[0..prefix]);
            @memcpy(slot.result.executed_ordinals[0..prefix], plan.executed_ordinals[0..prefix]);
        }
        for (slot.groups().items[0..slot.groups().count]) |handle| if (self.physicalResident(handle)) |physical| {
            slot.result.physical = physical;
        };
    }
    fn stopResidentGroupValidated(self: *RuntimeRenderer, handle: GroupHandle, frame: u64) void {
        const group = self.musicGroup(handle) orelse return;
        if (group.state == .finished or group.state == .free) return;
        group.stopAt(0, frame, .stopped);
        for (&self.voices) |*voice| {
            if (!voice.active or !self.mixer.isGroupVoice(voice.handle)) continue;
            if (self.mixer.voices[voice.handle.index].group.?.eql(group.handle)) {
                self.runtime.instances.terminate(voice.instance, voice.reservation);
                voice.stopping = true;
            }
        }
        self.mixer.finishStoppedGroup(group.handle);
    }
    /// The phase receipt is authoritative and is release-published first.
    /// This is the final Render access to this generation-safe transaction slot.
    fn finishResidentPhase(self: *RuntimeRenderer, commands: []const ScheduledCommand, reason: scheduler.trace.Reason) void {
        if (reason != .none) return; // Failed/cancelled receipts are reconciled by Control.
        for (commands) |command| if (transactionCommand(command.payload) != null) {
            self.runtime.resident_transaction_slot.state.store(.terminal, .release);
        };
    }

    fn executeGroupValidated(self: *RuntimeRenderer, commands: []const ScheduledCommand) scheduler.trace.Reason {
        // Validate the complete curve contract before any group, owner pin,
        // graph or resident transaction can be mutated by this atomic phase.
        for (commands) |command| switch (command.payload) {
            .group_start => |value| {
                const slot = self.runtime.preparedGroup(value.group) catch return .invalid_handle;
                if (!validStartCurve(value.start_curve, slot.prepared.ramp_frames)) return .invalid_state;
            },
            .group_stop => |value| {
                if (!validReleaseCurve(value.release_curve, value.release_frames)) return .invalid_state;
                if (value.allow_crossfade_source_stop and !validCrossfadeStopPair(commands, command)) return .invalid_state;
            },
            else => {},
        };
        for (commands) |command| if (transactionCommand(command.payload) != null) {
            if (commands.len != 1) return .invalid_state;
            const resident_reason = self.preflightResident(command);
            if (resident_reason != .none) return resident_reason;
        };
        const bus_reason = self.preflightBusGroup(commands);
        if (bus_reason != .none) return bus_reason;
        // A 16-stem payload consumes one command but all 16 real voice/owner pins.
        // No mutation precedes validation of the entire atomic scheduler group.
        var free: usize = 0;
        for (&self.voices) |*voice| if (!voice.active) {
            free += 1;
        };
        var starts: usize = 0;
        var real_starts: usize = 0;
        var new_groups: usize = 0;
        const GroupTrial = struct { handle: GroupHandle, cursor: u64, frames: u64, loop: ?music_group.Loop, stopped: bool, paused: bool = false, layer_change: bool = false, mutation_epoch: u64 = 1, loop_epoch: u64 = 0, transport_epoch: u64 = 1, automation: bool = false, continuity: bool = false };
        var trials: [scheduler.commands_per_group]GroupTrial = undefined;
        var trial_count: usize = 0;
        for (commands, 0..) |*command, command_index| {
            if (command.payload == .play) real_starts += 1;
            if (self.runtime.scheduledStart(command.payload)) |handle| real_starts += self.runtime.prepared_groups[handle.index].prepared.realCount();
            if (command.payload == .play and self.bus_graph != null and !self.mixer.canStartLegacyVoice(command.payload.play.params.bus, command.payload.play.params.reverb_send)) return .invalid_state;
            if (command.payload == .play and self.bus_graph == null and self.mixer.legacy_route == null) return .invalid_state;
            for (self.runtime.scheduledPlays(&command.payload)) |play| {
                starts += 1;
                if (!self.runtime.instances.mayStart(play.instance, play.reservation)) return .invalid_handle;
                const terminal = self.terminal[play.instance.index];
                if (terminal.valid and terminal.generation == play.instance.generation and terminal.start_order == command.sequence) return .invalid_handle;
                if (self.findInstance(play.instance) != null) return .invalid_handle;
            }
            if (command.payload == .group_layer_automation_stop) {
                const program = (self.runtime.layer_manager_published.load(.acquire) orelse return .invalid_handle).get(command.payload.group_layer_automation_stop.program) catch return .invalid_handle;
                if (program.state.load(.acquire) == .terminal) continue;
            }
            if (command.payload == .graph_source_program_stop) {
                const program = (self.runtime.graph_clock_manager_published.load(.acquire) orelse return .invalid_handle).get(command.payload.graph_source_program_stop.program) catch return .invalid_handle;
                if (program.state.load(.acquire) == .terminal) continue;
            }
            if (self.runtime.scheduledStart(command.payload) orelse payloadGroup(command.payload)) |handle| {
                const slot = self.runtime.preparedGroup(handle) catch return .invalid_handle;
                var trial_index: ?usize = null;
                for (trials[0..trial_count], 0..) |trial, i| if (trial.handle.eql(handle)) {
                    trial_index = i;
                    break;
                };
                if (self.runtime.scheduledStart(command.payload) != null) {
                    if (trial_index != null) return .invalid_state;
                    if (slot.render_pins_started.load(.acquire) or slot.render_pin_mask.load(.acquire) != 0) return .invalid_state;
                    if (!channel_layout.ChannelLayout.eql(slot.prepared.matrix.output, self.mixer.output_layout) or slot.prepared.sample_rate != self.mixer.sample_rate) return .invalid_state;
                    if (slot.prepared.generation != command.identity.token.asset_generation.value()) return .stale_asset_generation;
                    for (slot.prepared.layers[0..slot.prepared.layer_count]) |layer| if (layer.stream) |source| {
                        if (source.identity.transport_epoch != command.identity.token.transport_epoch.value()) return .stale_epoch;
                    };
                    if (!slot.prepared.minimumPlayable(slot.prepared.start_cursor, slot.prepared.start_loop_epoch)) return .target_not_resident;
                    if (self.musicGroup(handle)) |existing| if (existing.state == .playing or existing.state == .releasing) return .invalid_state;
                    trial_index = trial_count;
                    trial_count += 1;
                    trials[trial_index.?] = .{ .handle = handle, .cursor = slot.prepared.start_cursor, .frames = slot.prepared.frames, .loop = slot.prepared.loop, .stopped = false };
                    new_groups += 1;
                } else if (trial_index == null) {
                    const crossfade_source_stop = command.payload == .group_stop and command.payload.group_stop.allow_crossfade_source_stop;
                    const current = self.musicGroup(handle);
                    if (crossfade_source_stop and (current == null or current.?.state == .finished)) {
                        // A Render slot can already belong to another group.
                        // Only the retained exact Control incarnation's actual
                        // terminal publication authorizes this source no-op.
                        const terminal = slot.terminal.read() orelse return .invalid_handle;
                        if (!terminal.group.eql(handle) or terminal.bank_generation != slot.prepared.generation or terminal.bank_generation != command.identity.token.asset_generation.value()) return .invalid_handle;
                        continue;
                    }
                    const active = current orelse return .invalid_handle;
                    if (active.state != .playing and !(crossfade_source_stop and active.state == .releasing)) return .invalid_state;
                    trial_index = trial_count;
                    trial_count += 1;
                    trials[trial_index.?] = .{ .handle = handle, .cursor = active.cursor, .frames = active.frames, .loop = active.loop, .stopped = false, .paused = active.paused, .mutation_epoch = active.mutation_epoch, .loop_epoch = active.loop_epoch, .transport_epoch = command.identity.token.transport_epoch.value() };
                }
                const trial = &trials[trial_index.?];
                if (trial.stopped or trial.layer_change or trial.automation or trial.continuity) return .invalid_state;
                switch (command.payload) {
                    .group_seek => |v| {
                        if ((if (self.musicGroup(handle)) |current| current.prepared else &slot.prepared).hasStreams()) return .invalid_state;
                        if (v.cursor >= (if (trial.loop) |loop| loop.end else trial.frames)) return .invalid_state;
                        if (trial.mutation_epoch == std.math.maxInt(u64)) return .invalid_state;
                        trial.mutation_epoch += 1;
                        trial.cursor = v.cursor;
                    },
                    .group_loop => |v| {
                        if ((if (self.musicGroup(handle)) |current| current.prepared else &slot.prepared).hasStreams()) return .invalid_state;
                        if (v.loop) |loop| if (loop.start >= loop.end or loop.end > trial.frames or trial.cursor >= loop.end) return .invalid_state;
                        if (trial.mutation_epoch == std.math.maxInt(u64)) return .invalid_state;
                        trial.mutation_epoch += 1;
                        trial.loop = v.loop;
                    },
                    .group_layer => |v| {
                        // Layer replacements cannot share their atomic phase
                        // with mutations of the same group's musical timeline.
                        for (commands[0..command_index]) |prior| if (payloadGroup(prior.payload)) |prior_handle| if (prior_handle.eql(handle)) return .invalid_state;
                        const change = self.runtime.layerChange(v.change) catch return .invalid_handle;
                        const current = self.musicGroup(handle) orelse return .invalid_handle;
                        if (current.paused or current.mutation_epoch != change.change.ticket.mutation_epoch or current.loop_epoch != change.change.ticket.loop_epoch or current.cursor != change.change.ticket.cursor) return .stale_epoch;
                        if (!current.checkChange(change.change, command.identity.execute_frame, command.identity.token.transport_epoch.value())) return .target_not_resident;
                        if (change.change.target == .real) real_starts += 1;
                        trial.layer_change = true;
                    },
                    .group_pause => |v| {
                        if (trial.paused == v.paused) return .invalid_state;
                        if (v.continuity) |continuation| {
                            const entry = (self.runtime.source_continuity_published.load(.acquire) orelse return .invalid_handle).get(continuation) catch return .invalid_handle;
                            const current = self.musicGroup(v.group) orelse return .invalid_handle;
                            if (entry.state.load(.acquire) != .bound or !entry.desc.group.eql(v.group) or entry.desc.paused != v.paused or
                                entry.desc.new_transport_epoch != v.next_transport_epoch or !std.mem.eql(u8, &entry.content_hash, &v.continuity_hash)) return .invalid_state;
                            var required_mask: u16 = 0;
                            for (0..current.layer_count) |i| if (self.mixer.groupLayerDetectorDependency(current.handle, @intCast(i))) {
                                required_mask |= @as(u16, 1) << @intCast(i);
                            };
                            if (!current.checkSourceContinuity(&entry.desc, trial.transport_epoch, required_mask) or
                                !self.mixer.checkGroupGraphContinuity(current, &entry.desc) or !self.checkLayerContinuity(v.group, current, &entry.desc)) return .target_not_resident;
                            trial.continuity = true;
                        } else if (v.next_transport_epoch != 0 and ((if (self.musicGroup(handle)) |current| current.prepared else &slot.prepared).hasStreams() or command.identity.token.transport_epoch.value() == std.math.maxInt(u64) or v.next_transport_epoch != command.identity.token.transport_epoch.value() + 1)) return .invalid_state;
                        if (trial.mutation_epoch == std.math.maxInt(u64)) return .invalid_state;
                        trial.mutation_epoch += 1;
                        if (v.next_transport_epoch != 0) trial.transport_epoch = v.next_transport_epoch;
                        trial.paused = v.paused;
                    },
                    .graph_source_program => |v| {
                        const manager = self.runtime.graph_clock_manager_published.load(.acquire) orelse return .invalid_handle;
                        const program = manager.get(v.program) catch return .invalid_handle;
                        const a = program.desc.progress.anchor;
                        const current = self.musicGroup(handle) orelse return .invalid_handle;
                        if (!std.mem.eql(u8, &program.source_binding.hash, &v.source_hash) or !self.graphProgramPreparedSourceMatches(handle, current, program)) return .stale_epoch;
                        if (program.state.load(.acquire) != .bound or a.cursor != trial.cursor or a.loop_epoch != trial.loop_epoch or a.mutation_epoch != trial.mutation_epoch or a.transport_epoch != trial.transport_epoch or a.bank_generation != current.generation or a.source_frames != trial.frames or !std.meta.eql(a.loop, if (trial.loop) |l| @as(?layer_spans.Loop, .{ .start = l.start, .end = l.end }) else null) or !std.mem.eql(u8, &program.desc.content_hash, &v.content_hash)) return .stale_epoch;
                        if (program.desc.previous) |previous| {
                            const prior = manager.get(previous) catch return .invalid_handle;
                            const state = prior.state.load(.acquire);
                            if (state != .active and state != .terminal) return .invalid_state;
                        }
                        trial.automation = true;
                    },
                    .graph_source_program_stop => |v| {
                        const program = (self.runtime.graph_clock_manager_published.load(.acquire) orelse return .invalid_handle).get(v.program) catch return .invalid_handle;
                        if (program.state.load(.acquire) != .active or !std.mem.eql(u8, &program.desc.content_hash, &v.content_hash)) return .invalid_state;
                        trial.automation = true;
                    },
                    .group_layer_automation => |v| {
                        const manager = self.runtime.layer_manager_published.load(.acquire) orelse return .invalid_handle;
                        const program = manager.get(v.program) catch return .invalid_handle;
                        const a = program.desc.anchor;
                        const current = self.musicGroup(handle) orelse return .invalid_handle;
                        if (current.source_incarnation != a.source_incarnation or a.sample_rate != current.prepared.sample_rate or a.channels != current.prepared.matrix.input.count) return .stale_epoch;
                        if (program.state.load(.acquire) != .bound or trial.paused or a.cursor != trial.cursor or a.loop_epoch != trial.loop_epoch or a.mutation_epoch != trial.mutation_epoch or a.transport_epoch != trial.transport_epoch or a.bank_generation != current.generation or a.source_frames != trial.frames or !std.meta.eql(a.loop, if (trial.loop) |l| @as(?layer_spans.Loop, .{ .start = l.start, .end = l.end }) else null) or !std.mem.eql(u8, &program.desc.content_hash, &v.content_hash)) return .stale_epoch;
                        for (program.desc.tracks) |track| {
                            if (track.ordinal >= current.layer_count or current.layers[track.ordinal].prepared.authored.layer_id != track.stable_layer_id) return .stale_epoch;
                            const layer = current.layers[track.ordinal];
                            // A legacy raw ramp can have accumulated outside its
                            // authored range. Never reseed or partially install
                            // an M2 program from that actual Render value.
                            if (!std.math.isFinite(layer.gain_current) or layer.gain_current < 0 or layer.gain_current > 4) return .invalid_state;
                            if (layer.automation) |cursor| {
                                if (v.expected_previous == null or !cursor.program.eql(v.expected_previous.?)) return .invalid_state;
                            } else if (v.expected_previous) |previous| {
                                const prior = manager.get(previous) catch return .invalid_handle;
                                var completed_track = prior.state.load(.acquire) == .terminal;
                                if (prior.state.load(.acquire) == .active) for (prior.cursors[0..prior.desc.tracks.len]) |cursor| if (cursor.track.ordinal == track.ordinal and cursor.terminal != null) {
                                    completed_track = true;
                                };
                                if (!completed_track) return .invalid_state;
                            }
                            if (layer.state != .real and layer.state != .virtual) return .invalid_state;
                        }
                        trial.automation = true;
                    },
                    .group_layer_automation_stop => |v| {
                        const program = (self.runtime.layer_manager_published.load(.acquire) orelse return .invalid_handle).get(v.program) catch return .invalid_handle;
                        if (program.state.load(.acquire) != .active or !std.mem.eql(u8, &program.desc.content_hash, &v.content_hash)) return .invalid_state;
                        trial.automation = true;
                    },
                    .group_layer_gain => |v| {
                        if (self.musicGroup(handle)) |current| {
                            if (current.source_incarnation != v.source_incarnation) return .stale_epoch;
                            if (v.layer >= current.layer_count or current.layers[v.layer].automation != null) return .invalid_state;
                        } else if (v.source_incarnation != 1) return .stale_epoch;
                    },
                    .group_stop => trial.stopped = true,
                    else => {},
                }
            }
            switch (command.payload) {
                .update => |v| {
                    if (groupStopped(commands[0..command_index], v.instance)) return .invalid_state;
                    if (self.findBound(v.instance, v.incarnation, v.reservation)) |voice| if (voice.stopping or self.mixer.isGroupVoice(voice.handle)) return .invalid_state;
                    if (self.findBound(v.instance, v.incarnation, v.reservation) == null and !groupStarts(commands[0..command_index], v.instance)) return .invalid_handle;
                },
                .stop => |v| {
                    if (groupStopped(commands[0..command_index], v.instance)) return .invalid_state;
                    if (self.findBound(v.instance, v.incarnation, v.reservation)) |voice| if (self.mixer.isGroupVoice(voice.handle)) return .invalid_state;
                    if (self.findBound(v.instance, v.incarnation, v.reservation) == null and !groupStarts(commands[0..command_index], v.instance)) return .invalid_handle;
                },
                else => {},
            }
        }
        var free_groups: usize = 0;
        for (&self.mixer.groups) |*group| if (group.state == .free or group.state == .finished) {
            free_groups += 1;
        };
        if (starts > free or starts > self.mixer.freeLogicalCount() or real_starts > self.mixer.freeVoiceCount() or new_groups > free_groups) return .voice_budget_exceeded;
        var pinned: [max_logical_voices]Pinned = undefined;
        var pinned_count: usize = 0;
        for (commands) |*command| for (self.runtime.scheduledPlays(&command.payload)) |play| {
            const custody = pinPlayDerivative(play.owner, play.block_custody, .render, playDestination(self.runtime, play.instance, play.reservation)) catch {
                for (pinned[0..pinned_count]) |pin| releasePlayOwner(pin.owner, pin.custody);
                _ = self.runtime.counters.pin_misses.fetchAdd(1, .monotonic);
                return .target_not_resident;
            };
            pinned[pinned_count] = .{ .owner = play.owner, .custody = custody };
            pinned_count += 1;
        };
        var pin_cursor: usize = 0;
        for (commands) |command| {
            switch (command.payload) {
                .graph_install => |v| {
                    const slot = self.runtime.bus_manager.?.get(v.graph) catch unreachable;
                    self.mixer.bindGraphPrepared(&slot.binding) catch unreachable;
                    slot.origin = command.identity.execute_frame;
                    slot.activated = true;
                    self.bus_graph = v.graph;
                    slot.active.store(true, .release);
                    self.runtime.bus_manager.?.publish(v.graph, command.identity.execute_frame);
                },
                .graph_retire => self.retireBusGraph(command.identity.execute_frame),
                .graph_targets => |v| self.runtime.bus_manager.?.applyBatchAt(v.batch, command.identity.execute_frame),
                .group_bus_route => |v| {
                    const route = self.runtime.bus_manager.?.route(v.route) catch unreachable;
                    const group = self.musicGroup(v.group).?;
                    self.mixer.applyGroupLayerRoutesValidated(group.handle, v.layer, &route.prepared, v.ramp_frames);
                },
                .play => |play| {
                    const voice = for (&self.voices) |*v| {
                        if (!v.active) break v;
                    } else unreachable;
                    const handle = self.mixer.startSampleVoiceReserved(.{ .samples = play.owner.samples, .gain = play.params.gain, .pitch = play.params.pitch, .priority = play.params.priority, .bus = play.params.bus, .loop = play.params.loop, .pan = play.params.pan, .lowpass_hz = play.params.lowpass_hz, .reverb_send = play.params.reverb_send }, &self.telemetry);
                    voice.* = .{ .active = true, .reservation = play.reservation, .instance = play.instance, .owner = play.owner, .custody = pinned[pin_cursor].custody, .handle = handle, .start_order = command.sequence, .bus = play.params.bus };
                    pin_cursor += 1;
                    _ = self.runtime.counters.render_pins.fetchAdd(1, .monotonic);
                },
                .update => |v| {
                    const voice = self.findBound(v.instance, v.incarnation, v.reservation).?;
                    self.mixer.updateVoice(voice.handle, v.params, v.ramp_frames) catch unreachable;
                },
                .stop => |v| {
                    const voice = self.findBound(v.instance, v.incarnation, v.reservation).?;
                    self.runtime.instances.terminate(v.instance, v.reservation);
                    self.mixer.stopVoice(voice.handle, v.fade_frames) catch unreachable;
                    voice.stopping = true;
                },
                .bus => |v| self.executeBus(v),
                .group_start => |group_start| self.commitResidentStart(command, group_start.group, pinned[0..pinned_count], &pin_cursor),
                .resident_capture => {
                    self.sampleResidentResult(&self.runtime.resident_transaction_slot, command.identity.execute_frame);
                },
                .resident_restore => {
                    const transaction = &self.runtime.resident_transaction_slot;
                    self.sampleResidentResult(transaction, command.identity.execute_frame);
                    const desc = transaction.desc.restore;
                    // Every identity, cursor, layout, capacity and owner-pin
                    // check has succeeded. This whole replacement cannot fail.
                    for (desc.old_groups.items[0..desc.old_groups.count]) |handle| self.stopResidentGroupValidated(handle, command.identity.execute_frame);
                    self.causalIncomplete(.unsupported_epoch);
                    self.runtime.scheduled.replaceResidentEpoch(desc.old_plan, desc.bank_generation, desc.new_transport_epoch, command.identity.execute_frame);
                    transaction.result.physical = null;
                    if (desc.replacement) |handle| {
                        self.commitResidentStart(command, handle, pinned[0..pinned_count], &pin_cursor);
                        const installed = self.musicGroup(handle).?;
                        if (desc.profile != .resident_v1) {
                            // Pause the newly installed, still-pinned windows.
                            // This is a real source-clock mutation; the result
                            // publishes its cursor, loop and mutation together.
                            if (desc.paused) installed.pause(true) catch unreachable;
                        } else installed.paused = desc.paused;
                        transaction.result.physical = self.physicalResident(handle);
                    }
                    transaction.result.transport_epoch = desc.new_transport_epoch;
                    transaction.result.bank_generation = desc.bank_generation;
                },
                .group_layer => |v| {
                    const change = &self.runtime.layer_changes[v.change.index];
                    const group = self.musicGroup(v.group).?;
                    // A residency/audibility state change is not a source
                    // incarnation. Only an admitted replacement Source stops
                    // the old clock until the explicit handoff exists.
                    if (change.change.source != null) {
                        // This is the no-fail phase commit boundary, after all
                        // admission/preflight checks. Failed replacement phases
                        // never poison the original-source ownership lease.
                        _ = self.runtime.prepared_groups[v.group.index].graph_source_replaced.fetchOr(@as(u16, 1) << @intCast(change.change.layer), .release);
                        self.mixer.detachLayerGraphPrograms(group.handle, change.change.layer, .source_replaced, command.identity.execute_frame);
                    }
                    group.changeLayer(&change.change, command.identity.execute_frame);
                    self.mixer.syncGroupVoices(group);
                },
                .graph_source_program => |v| {
                    if (self.music_trace) |sink| sink.incomplete.store(true, .release);
                    self.mixer.installGraphProgram(self.runtime.graph_clock_manager_published.load(.acquire).?, v.program, self.musicGroup(v.group).?, command.identity.execute_frame);
                },
                .graph_source_program_stop => |v| {
                    if (self.music_trace) |sink| sink.incomplete.store(true, .release);
                    self.mixer.detachGraphProgram(v.program, .stopped, command.identity.execute_frame, command.identity.execute_frame);
                },
                .group_layer_automation => |v| {
                    const group = self.musicGroup(v.group).?;
                    if (v.expected_previous) |previous| group.detachAutomation(previous, .superseded, command.identity.execute_frame);
                    const manager = self.runtime.layer_manager_published.load(.acquire).?;
                    if (v.expected_previous) |previous| self.publishLayerTerminal(previous.index);
                    const program = manager.install(v.program);
                    group.attachAutomation(program.cursors[0..program.desc.tracks.len]);
                    for (program.desc.tracks, 0..) |_, i| self.traceLayerAutomation(program, i, .install, command.identity.execute_frame);
                },
                .group_layer_automation_stop => |v| {
                    if (self.musicGroup(v.group)) |group| group.detachAutomation(v.program, .stopped, command.identity.execute_frame);
                    self.publishLayerTerminal(v.program.index);
                },
                .group_layer_gain => |v| self.musicGroup(v.group).?.layerGain(v.layer, v.gain, v.ramp_frames),
                .group_seek => |v| {
                    const group = self.musicGroup(v.group).?;
                    group.detachAutomation(null, .source_replaced, command.identity.execute_frame);
                    self.mixer.detachGroupGraphPrograms(group.handle, .clock_discontinuity, command.identity.execute_frame);
                    group.seek(v.cursor) catch unreachable;
                },
                .group_loop => |v| {
                    const group = self.musicGroup(v.group).?;
                    group.detachAutomation(null, .source_replaced, command.identity.execute_frame);
                    self.mixer.detachGroupGraphPrograms(group.handle, .clock_discontinuity, command.identity.execute_frame);
                    group.setLoop(v.loop) catch unreachable;
                },
                .group_gain => |v| self.musicGroup(v.group).?.ramp(v.gain, v.ramp_frames),
                .group_pause => |v| {
                    const group = self.musicGroup(v.group).?;
                    if (v.continuity) |handle| {
                        const manager = self.runtime.source_continuity_published.load(.acquire).?;
                        const entry = manager.get(handle) catch unreachable;
                        self.mixer.commitGroupGraphContinuity(group, &entry.desc);
                        const coordinate = group.commitSourceContinuity(&entry.desc, command.identity.execute_frame);
                        if (self.runtime.layer_manager_published.load(.acquire)) |layers| for (&layers.slots) |*program| {
                            if (program.state.load(.acquire) != .active) continue;
                            const anchor = program.desc.anchor;
                            if (anchor.group.index != v.group.index or anchor.group.generation != v.group.generation) continue;
                            program.effective_transport_epoch = coordinate.transport_epoch;
                            program.effective_mutation_epoch = coordinate.mutation_epoch;
                        };
                        if (self.music_trace) |sink| {
                            // Preserve unsupported/legacy evidence loss. Only
                            // the attached profile-4 recorder has captured this
                            // descriptor through its real schedule admission.
                            const recorded = if (self.runtime.music_runtime) |owner|
                                owner.recordsSourceContinuityV1(self.runtime, sink, entry.desc.source_incarnation)
                            else
                                false;
                            if (!recorded) sink.incomplete.store(true, .release);
                        }
                        manager.executed(handle, coordinate);
                    } else {
                        group.detachAutomation(null, .paused, command.identity.execute_frame);
                        group.pause(v.paused) catch unreachable;
                    }
                    if (v.next_transport_epoch != 0) {
                        self.causalIncomplete(.unsupported_epoch);
                        self.runtime.scheduled.transport_epoch = v.next_transport_epoch;
                        self.group_bindings[v.group.index].?.transport_epoch = v.next_transport_epoch;
                    }
                },
                .group_stop => |v| {
                    // The complete atomic group was preflighted above. A
                    // terminal source is deliberately untouched, especially
                    // when its old Render slot has been reused.
                    const current = self.musicGroup(v.group);
                    if (v.allow_crossfade_source_stop and (current == null or current.?.state == .finished)) continue;
                    const group = current.?;
                    group.detachAutomation(null, .group_stopped, command.identity.execute_frame);
                    self.mixer.detachGroupGraphPrograms(group.handle, .group_stopped, command.identity.execute_frame);
                    // Cleanup may shorten an existing outgoing fade, never
                    // extend the source beyond its admitted release endpoint.
                    const release_frames = if (v.allow_crossfade_source_stop and group.state == .releasing) @min(v.release_frames, group.ramp_remaining) else v.release_frames;
                    group.stopAtCurve(.stopped, if (group.paused) 0 else release_frames, command.identity.execute_frame, v.release_curve);
                    for (&self.voices) |*voice| {
                        if (!voice.active or !self.mixer.isGroupVoice(voice.handle)) continue;
                        if (self.mixer.voices[voice.handle.index].group.?.eql(group.handle)) {
                            self.runtime.instances.terminate(voice.instance, voice.reservation);
                            voice.stopping = true;
                        }
                    }
                    self.mixer.finishStoppedGroup(group.handle);
                },
            }
            if (command.payload != .group_bus_route and command.payload != .graph_source_program and command.payload != .graph_source_program_stop) {
                if (payloadGroup(command.payload)) |handle| self.traceMusicGroup(command, handle);
            }
        }
        return .none;
    }

    const Pinned = struct { owner: *SampleOwner, custody: ?PlayToken };
    fn commitResidentStart(self: *RuntimeRenderer, command: ScheduledCommand, handle: GroupHandle, pinned: []const Pinned, pin_cursor: *usize) void {
        const slot = &self.runtime.prepared_groups[handle.index];
        // The successful all-command preflight above acquired every
        // actual owner pin. This one-shot marker enforces the bit
        // multiplicity independently of Control duplicate checks.
        std.debug.assert(!slot.render_pins_started.load(.acquire));
        const mask: u16 = @intCast((@as(u32, 1) << @as(u5, @intCast(slot.prepared.voice_count))) - 1);
        const pin_publication: render_causal_witness.ResourceEvent = .{ .kind = .group_pin_publish, .group_index = handle.index, .group_generation = handle.generation, .bank_generation = slot.prepared.generation, .context = command.identity.token.context.value(), .start_order = command.sequence, .mask_after = mask };
        slot.render_pins_started.store(true, .release);
        self.causalReplay(.{ .site = .group_pin_publish, .edge = .before, .index = handle.index, .generation = handle.generation, .value = mask });
        slot.render_pin_mask.store(mask, .release);
        self.causalReplay(.{ .site = .group_pin_publish, .edge = .after, .index = handle.index, .generation = handle.generation, .value = mask });
        if (self.render_causal_binding) |binding| binding.bridge.observeResource(pin_publication);
        self.ownedResource(pin_publication);
        const result = self.mixer.startMusicGroupReserved(&slot.prepared, command.identity.execute_frame, handle.generation);
        // resident_restore keeps its existing linear prepared-start behavior.
        if (command.payload == .group_start) self.mixer.groupFor(result.group).?.setStartCurve(command.payload.group_start.start_curve);
        self.mixer.groupFor(result.group).?.terminal.cell = &slot.terminal;
        self.mixer.groupFor(result.group).?.source_switch.cell = &slot.source_switch;
        self.group_bindings[handle.index] = .{ .control = handle, .render = result.group, .has_streams = slot.prepared.hasStreams(), .context = command.identity.token.context.value(), .transport_epoch = command.identity.token.transport_epoch.value(), .sequence = command.sequence };
        for (slot.plays[0..slot.prepared.voice_count], 0..) |play, layer| {
            const voice = for (&self.voices) |*v| {
                if (!v.active) break v;
            } else unreachable;
            voice.* = .{ .active = true, .reservation = play.reservation, .instance = play.instance, .owner = play.owner, .custody = pinned[pin_cursor.*].custody, .handle = result.voices[layer], .start_order = command.sequence, .bus = .music, .group_pin = .{ .context = command.identity.token.context.value(), .runtime_generation = slot.prepared.generation, .group = handle, .play_index = @intCast(layer), .instance = play.instance, .reservation = play.reservation, .start_order = command.sequence, .generation_credit = slot.generation_credit } };
            pin_cursor.* += 1;
            _ = self.runtime.counters.render_pins.fetchAdd(1, .monotonic);
        }
    }

    fn traceMusicGroup(self: *RuntimeRenderer, command: ScheduledCommand, handle: GroupHandle) void {
        const sink = self.music_trace orelse return;
        const group = self.musicGroup(handle) orelse return;
        const token = command.identity.token;
        const frame = command.identity.execute_frame;
        const ramp_frames: u32 = switch (command.payload) {
            .group_start => group.prepared.ramp_frames,
            .group_gain => |v| v.ramp_frames,
            .group_stop => |v| v.release_frames,
            else => 0,
        };
        var record: scheduler.trace.ScheduleRecord = .{ .kind = .group, .context = token.context.value(), .command_id = command.identity.command_id, .planned_frame = frame, .executed_frame = frame, .effective_frame = frame, .sequence = command.sequence, .plan_id = token.plan_id.value(), .phase_id = token.phase_id.value(), .phase_order = command.identity.phase_order, .plan_epoch = token.plan_epoch.value(), .transport_epoch = token.transport_epoch.value(), .asset_generation = group.generation, .source_segment = group.segment, .group = handle.generation, .cursor = group.cursor, .ramp_start = frame, .ramp_end = frame + ramp_frames, .value_q16 = @intFromFloat(group.gain_target * 65536), .result = .success };
        _ = sink.push(.{ .event = record });
        const slot = &self.runtime.prepared_groups[handle.index];
        record.kind = .layer;
        for (slot.plays[0..slot.prepared.layer_count], slot.prepared.layers[0..slot.prepared.layer_count]) |play, layer| {
            record.layer = play.reservation;
            record.value_q16 = @intFromFloat(group.gain_target * layer.gain * 65536);
            _ = sink.push(.{ .event = record });
        }
    }

    fn findBound(self: *RuntimeRenderer, instance: InstanceHandle, incarnation: ?u64, reservation: u64) ?*RenderVoice {
        const order = incarnation orelse return null;
        const voice = self.find(instance, order) orelse return null;
        return if (voice.reservation == reservation and self.mixer.isVoiceActive(voice.handle)) voice else null;
    }

    fn findInstance(self: *RuntimeRenderer, instance: InstanceHandle) ?*RenderVoice {
        for (&self.voices) |*voice| if (voice.active and voice.instance.eql(instance) and self.mixer.isVoiceActive(voice.handle)) return voice;
        return null;
    }

    const StartResult = enum { started, retry, rejected };
    fn start(self: *RuntimeRenderer, wanted: SnapshotVoice) StartResult {
        // Control already selected and faded a victim. Logical spare slots do
        // not authorize a second Render-side steal while that real slot fades.
        if (self.mixer.freeVoiceCount() == 0) return .retry;
        const slot = for (&self.voices) |*voice| if (!voice.active) break voice else continue else return .retry;
        const render_pin = switch (classifyPlayDerivative(wanted.owner, wanted.custody, .render, playDestination(self.runtime, wanted.instance, wanted.reservation))) {
            .pinned => |pin| pin,
            .transient => {
                _ = self.runtime.counters.pin_misses.fetchAdd(1, .monotonic);
                return .retry;
            },
            .permanent => {
                _ = self.runtime.counters.pin_misses.fetchAdd(1, .monotonic);
                return .rejected;
            },
        };
        const handle = self.mixer.startSampleVoiceWithHandle(.{ .samples = wanted.owner.samples, .gain = wanted.params.gain, .pitch = wanted.params.pitch, .priority = wanted.params.priority, .bus = wanted.params.bus, .loop = wanted.params.loop, .pan = wanted.params.pan, .lowpass_hz = wanted.params.lowpass_hz, .reverb_send = wanted.params.reverb_send }, &self.telemetry) catch {
            releasePlayOwner(wanted.owner, render_pin);
            return .retry;
        };
        _ = self.runtime.counters.render_pins.fetchAdd(1, .monotonic);
        slot.* = .{ .active = true, .reservation = wanted.reservation, .instance = wanted.instance, .handle = handle, .owner = wanted.owner, .custody = render_pin, .revision = wanted.revision, .start_order = wanted.start_order, .bus = wanted.params.bus };
        return .started;
    }

    fn find(self: *RuntimeRenderer, instance: InstanceHandle, start_order: u64) ?*RenderVoice {
        for (&self.voices) |*voice| if (voice.active and voice.instance.eql(instance) and voice.start_order == start_order) return voice;
        return null;
    }

    fn collectStreamFaults(self: *RuntimeRenderer) void {
        for (self.group_bindings) |maybe| if (maybe) |binding| {
            const group = self.mixer.groupFor(binding.render) orelse continue;
            if (!binding.has_streams) continue;
            if (group.underrun_frame) |frame| {
                if (group.fault_reported) continue;
                group.fault_reported = true;
                self.stream_starvation.observe(1);
                const fault: StreamFault = .{ .group = binding.control, .segment = group.original_segment, .emergency_segment = if (group.degraded) group.segment else 0, .generation = group.generation, .frame = frame, .cursor = group.underrun_cursor, .loop_epoch = group.underrun_loop_epoch, .layer = group.failed_layer, .degraded = group.degraded };
                if (!self.runtime.stream_faults.push(fault)) _ = self.runtime.stream_fault_overflow.fetchAdd(1, .monotonic);
                if (self.music_trace) |sink| {
                    if (group.degraded) sink.incomplete.store(true, .release);
                    _ = sink.push(.{ .event = .{ .kind = .group, .context = binding.context, .transport_epoch = binding.transport_epoch, .asset_generation = group.generation, .sequence = binding.sequence, .effective_frame = frame, .executed_frame = frame, .source_segment = group.original_segment, .target_segment = fault.emergency_segment, .group = binding.control.generation, .layer = group.failed_layer + 1, .cursor = fault.cursor, .result = if (group.degraded) .degraded else .rejected, .reason = .stream_underrun } });
                }
            } else if (group.state == .playing or group.state == .releasing) self.stream_starvation.observe(0);
        };
    }

    fn collectFinished(self: *RuntimeRenderer) void {
        for (&self.voices) |*voice| if (voice.active and !self.mixer.isVoiceActive(voice.handle)) {
            const reason: CompletionReason = if (voice.stopping) .stopped else .finished;
            self.markTerminal(voice.instance, voice.start_order);
            // Full queue keeps the actual owner pin, copied incarnation and
            // group bit intact. A later attempt cannot release the owner twice.
            // Copy the entire lifetime before completion can let Control
            // reclaim desired ownership, and before the final pin is returned.
            var resource: render_causal_witness.ResourceEvent = .{ .kind = .completion_enqueue, .instance_index = voice.instance.index, .instance_generation = voice.instance.generation, .reservation = voice.reservation, .start_order = voice.start_order, .completion_reason = @intFromEnum(reason) };
            if (voice.group_pin) |pin| {
                resource.group_index = pin.group.index;
                resource.group_generation = pin.group.generation;
                resource.bank_generation = pin.runtime_generation;
                resource.context = pin.context;
                resource.play_index = pin.play_index;
            }
            const observer = if (self.render_causal_binding) |binding| (if (binding.bridge.manifest.capture_reconciliation) binding.bridge else null) else null;
            if (!self.runtime.pushRenderCompletionObserved(.{ .instance = voice.instance, .reason = reason, .start_order = voice.start_order }, if (observer != null or self.ownedRenderFacts() != null) &resource else null, completionOrderBinding(self.prerequisite_order))) continue;
            if (observer) |bridge| bridge.observeResource(resource);
            self.ownedResource(resource);
            var group_mask: ?*std.atomic.Value(u16) = null;
            var group_bit: u16 = 0;
            if (voice.group_pin) |pin| {
                const slot = &self.runtime.prepared_groups[pin.group.index];
                group_bit = @as(u16, 1) << @intCast(pin.play_index);
                std.debug.assert(slot.occupied and slot.generation == pin.group.generation and slot.prepared.generation == pin.runtime_generation and
                    pin.play_index < slot.prepared.voice_count and voice.instance.eql(pin.instance) and voice.reservation == pin.reservation and voice.start_order == pin.start_order);
                std.debug.assert(slot.plays[pin.play_index].owner == voice.owner and std.meta.eql(slot.generation_credit, pin.generation_credit));
                if (pin.generation_credit) |credit| std.debug.assert(credit.context == pin.context and credit.runtime_generation == pin.runtime_generation and credit.group.eql(pin.group));
                std.debug.assert(slot.render_pin_mask.load(.acquire) & group_bit != 0);
                group_mask = &slot.render_pin_mask;
                if (comptime @import("builtin").is_test) if (self.test_group_release_hook) |hook| hook.call(hook.context, pin);
            }
            if (comptime @import("builtin").is_test) if (voice.custody) |token| if (self.test_play_release_hook) |hook| hook.call(hook.context, .{ .token = token, .instance = voice.instance, .reservation = voice.reservation, .start_order = voice.start_order });
            releasePlayOwner(voice.owner, voice.custody);
            _ = self.runtime.counters.render_pins.fetchSub(1, .monotonic);
            voice.* = .{};
            // FINAL prepared-slot/owner access. Control may now return its exact
            // generation credit and reuse the slot. Only copied scalar values
            // are inspected afterward; no owner metadata is read after release.
            if (group_mask) |mask| {
                self.causalReplay(.{ .site = .group_pin_return, .edge = .before, .index = resource.group_index, .generation = resource.group_generation, .value = group_bit });
                const previous = mask.fetchAnd(~group_bit, .release);
                self.causalReplay(.{ .site = .group_pin_return, .edge = .after, .index = resource.group_index, .generation = resource.group_generation, .value = previous & ~group_bit });
                std.debug.assert(previous & group_bit != 0);
                // Only the copied scalars and the actual RMW result survive
                // this final release; never consult the prepared slot again.
                resource.kind = .group_pin_return;
                resource.mask_before = previous;
                resource.mask_after = previous & ~group_bit;
                if (observer) |bridge| bridge.observeResource(resource);
                self.ownedResource(resource);
            }
        };
    }

    fn markTerminal(self: *RuntimeRenderer, instance: InstanceHandle, start_order: u64) void {
        const previous = self.terminal[instance.index];
        // An older stolen voice can finish its fade after a reused index has
        // already finished. Never replace that newer incarnation's tombstone.
        if (previous.valid and @as(i64, @bitCast(start_order -% previous.start_order)) < 0) return;
        self.terminal[instance.index] = .{ .valid = true, .generation = instance.generation, .start_order = start_order };
    }

    pub fn activeVoiceCount(self: *const RuntimeRenderer) usize {
        var count: usize = 0;
        for (&self.voices) |*voice| count += @intFromBool(voice.active and self.mixer.isVoiceActive(voice.handle));
        return count;
    }
};

fn playCustodyError(err: anyerror) RuntimeError {
    return switch (err) {
        error.AcquisitionClosed => error.RuntimeStopped,
        error.CapacityExceeded => error.CommandQueueFull,
        else => error.InvalidState,
    };
}
fn releasePlayOwner(owner: *SampleOwner, token: ?PlayToken) void {
    if (token) |owned| {
        // Source generation may be freed after this final returned publication.
        const returned = owned.releasePhysical();
        std.debug.assert(returned);
    } else owner.release();
}
fn playDestination(control: *ControlRuntime, instance: InstanceHandle, reservation: u64) play_custody.Destination {
    return .{ .control = control, .instance_index = instance.index, .instance_generation = instance.generation, .reservation = reservation };
}
// Error origin matters: InvalidState from the bounded physical pin CAS can
// recover, while exhausted/stale custody cannot. Preserve the legacy error
// surface for existing Control/scheduled callers; only immediate Render start
// consumes the richer internal classification to choose retry vs completion.
const PlayDerivativeResult = union(enum) {
    pinned: ?PlayToken,
    transient: RuntimeError,
    permanent: RuntimeError,
};
fn classifyPlayDerivative(owner: *SampleOwner, token: ?PlayToken, role: play_custody.Role, destination: play_custody.Destination) PlayDerivativeResult {
    if (token) |parent| {
        if (!parent.matches(owner, destination)) return .{ .permanent = error.InvalidState };
        const reservation = parent.reserveDerivative(role) catch |err| return switch (err) {
            error.IdentityExhausted, error.InvalidToken => .{ .permanent = playCustodyError(err) },
            else => .{ .transient = playCustodyError(err) },
        };
        owner.pin() catch |err| {
            reservation.cancel();
            return .{ .transient = err };
        };
        return .{ .pinned = reservation.publish() };
    }
    owner.pin() catch |err| return .{ .transient = err };
    return .{ .pinned = null };
}
fn pinPlayDerivative(owner: *SampleOwner, token: ?PlayToken, role: play_custody.Role, destination: play_custody.Destination) RuntimeError!?PlayToken {
    switch (classifyPlayDerivative(owner, token, role, destination)) {
        .pinned => |pin| return pin,
        .transient, .permanent => |err| return err,
    }
}

fn applyUpdate(params: *VoiceParams, update: mixer.VoiceControlParams) void {
    if (update.gain) |value| params.gain = std.math.clamp(value, 0, 4);
    if (update.pan) |value| params.pan = std.math.clamp(value, -1, 1);
    if (update.lowpass_hz) |value| params.lowpass_hz = value;
    if (update.pitch_ratio) |value| params.pitch = std.math.clamp(value, 0.01, 8);
    if (update.reverb_send) |value| params.reverb_send = std.math.clamp(value, 0, 1);
}

fn validateVoiceParams(params: VoiceParams) RuntimeError!void {
    inline for (.{ params.gain, params.pitch, params.priority, params.pan, params.lowpass_hz, params.reverb_send }) |value| if (!finite(value)) return error.InvalidArgument;
    if (params.gain < 0 or params.gain > 4 or params.pitch < 0.01 or params.pitch > 8 or params.priority < 0 or params.priority > 1 or params.pan < -1 or params.pan > 1 or params.lowpass_hz < 20 or params.reverb_send < 0 or params.reverb_send > 1) return error.InvalidArgument;
}

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

fn snapshotContains(snapshot: *const RenderSnapshot, instance: InstanceHandle, start_order: u64) bool {
    for (snapshot.voices[0..snapshot.voice_count]) |voice| if (voice.instance.eql(instance) and voice.start_order == start_order) return true;
    return false;
}

fn weaker(a: DesiredVoice, b: DesiredVoice) bool {
    if (a.params.priority != b.params.priority) return a.params.priority < b.params.priority;
    if (a.start_order != b.start_order) return @as(i64, @bitCast(a.start_order -% b.start_order)) > 0;
    if (a.instance.index != b.instance.index) return a.instance.index > b.instance.index;
    return a.instance.generation > b.instance.generation;
}

fn nextGeneration(current: u16) u16 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

const StressContext = struct {
    runtime: *ControlRuntime,
    producers_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    render_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn stressProducer(context: *StressContext, producer: u32) void {
    for (0..1000) |index| {
        const gain = @as(f32, @floatFromInt((index + producer) % 4)) * 0.25;
        while (true) {
            context.runtime.submitBus(.{ .bus = if (producer & 1 == 0) .sfx else .music, .gain = gain, .ramp_frames = 8 }) catch |err| switch (err) {
                error.CommandQueueFull => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => {
                    context.failed.store(true, .release);
                    return;
                },
            };
            break;
        }
    }
    _ = context.producers_done.fetchAdd(1, .release);
}

fn stressControl(context: *StressContext) void {
    while (context.producers_done.load(.acquire) != 4 or context.runtime.normal.count() != 0 or context.runtime.reserved.count() != 0) {
        _ = context.runtime.controlTick(max_control_drain) catch |err| switch (err) {
            error.SnapshotBusy => continue,
            else => {
                context.failed.store(true, .release);
                return;
            },
        };
        std.Thread.yield() catch {};
    }
    context.render_stop.store(true, .release);
}

fn stressRender(context: *StressContext) void {
    var renderer = RuntimeRenderer.init(context.runtime, 48_000);
    var output: [2]f32 = undefined;
    while (!context.render_stop.load(.acquire)) renderer.render(&output, 1, 2);
}

/// Focused external test roots call these explicitly; imported-module test
/// blocks are not registered by Zig. No callable surface exists in production.
pub const PrerequisiteOrderTests = if (@import("builtin").is_test) struct {
    pub fn mapping() !void {
        try prerequisiteOrderMappingTest();
    }
    pub fn completionOutcomes() !void {
        try prerequisiteCompletionOutcomesTest();
    }
    pub fn completionFailure() !void {
        try prerequisiteCompletionFailureTest();
    }
} else void;

test "runtime prerequisite order exhaustively maps source sites and preserves zero presence" {
    try prerequisiteOrderMappingTest();
}

test "runtime prerequisite completion order keeps actual Render and Control full empty outcomes" {
    try prerequisiteCompletionOutcomesTest();
}

test "runtime prerequisite completion failure never changes queue results" {
    try prerequisiteCompletionFailureTest();
}

fn prerequisiteOrderMappingTest() !void {
    inline for (std.meta.fields(CausalReplaySite)) |field| {
        const source: CausalReplaySite = @enumFromInt(field.value);
        try std.testing.expectEqual(@field(capture_order.Site, "runtime_" ++ field.name), captureOrderSite(source));
        // Every existing after point has an actual observation or operand.
        try std.testing.expectEqual(@as(?u64, 0), captureOrderValue(.{ .site = source, .edge = .after }));
    }
    inline for (.{ CausalReplaySite.collection_frame, .plan_phase, .execution_receipt, .schedule_admission, .schedule_result, .group_source_switch_read, .schedule_release, .terminal_scan, .group_terminal_read, .group_pin_read, .completion_space, .completion_pop, .control_horizon, .control_accept_frame, .group_desired_active, .group_desired_start, .group_desired_reservation, .group_source_switch_final, .control_collect_frame, .readiness_outer_before, .readiness_outer_after }) |site| {
        // Even a nonzero legacy placeholder cannot turn a before-read into a
        // value observation: presence is a site contract, not a zero heuristic.
        try std.testing.expectEqual(@as(?u64, null), captureOrderValue(.{ .site = site, .edge = .before, .value = 17 }));
        try std.testing.expectEqual(@as(?u64, 17), captureOrderValue(.{ .site = site, .edge = .after, .value = 17 }));
    }
    inline for (.{ CausalReplaySite.group_pin_publish, .group_pin_return, .completion_enqueue, .completion_return, .render_frame, .render_commit_horizon, .stream_stop_publish }) |site| {
        try std.testing.expectEqual(@as(?u64, 0), captureOrderValue(.{ .site = site, .edge = .before }));
        try std.testing.expectEqual(@as(?u64, 17), captureOrderValue(.{ .site = site, .edge = .before, .value = 17 }));
    }
    try std.testing.expectEqual(capture_order.Edge.before, captureOrderEdge(.before));
    try std.testing.expectEqual(capture_order.Edge.after, captureOrderEdge(.after));
    try std.testing.expect(completionOrderBinding(null) == null);
}

const CompletionOrderExpected = struct { site: capture_order.Site, edge: capture_order.Edge, value: ?u64 };
fn expectCompletionOrder(lane: *capture_order.RoleCollector, role: capture_order.Role, points: []const CompletionOrderExpected) !void {
    const begin = lane.pop().?;
    try std.testing.expectEqual(capture_order.Kind.begin, begin.kind);
    try std.testing.expectEqual(role, begin.role);
    for (points, 0..) |expected, i| {
        const point = lane.pop().?;
        try std.testing.expectEqual(capture_order.Kind.point, point.kind);
        try std.testing.expectEqual(role, point.role);
        try std.testing.expectEqual(@as(u64, i + 2), point.sequence);
        try std.testing.expectEqual(@as(u64, i + 2), point.point_ordinal);
        try std.testing.expectEqual(@as(u64, 1), point.operation);
        try std.testing.expectEqual(@as(?capture_order.Site, expected.site), point.site);
        try std.testing.expectEqual(expected.edge, point.edge);
        try std.testing.expectEqual(@as(u64, 0), point.index);
        try std.testing.expectEqual(@as(u64, 0), point.generation);
        try std.testing.expectEqual(expected.value, point.value);
    }
    const end = lane.pop().?;
    try std.testing.expectEqual(capture_order.Kind.end, end.kind);
    try std.testing.expectEqual(role, end.role);
    try std.testing.expectEqual(@as(u64, points.len + 2), end.point_count);
    try std.testing.expect(lane.pop() == null);
    try std.testing.expect(!lane.incomplete());
}

fn prerequisiteCompletionOutcomesTest() !void {
    if (!capture_order.supported_target) return error.SkipZigTest;
    var render: capture_order.Storage(16) = .{};
    var control: capture_order.Storage(16) = .{};
    try render.initInPlace(.render);
    try control.initInPlace(.control);
    var queue: SpscRing(1, u8) = .{};
    render.collector.begin(1);
    try std.testing.expect(queue.pushObserved(19, null, null, completionOrderBinding(&render.collector)));
    try std.testing.expect(!queue.pushObserved(27, null, null, completionOrderBinding(&render.collector)));
    render.collector.end(0);
    control.collector.begin(1);
    try std.testing.expectEqual(@as(?u8, 19), queue.popObserved(null, null, completionOrderBinding(&control.collector)));
    try std.testing.expect(queue.popObserved(null, null, completionOrderBinding(&control.collector)) == null);
    control.collector.end(0);
    try expectCompletionOrder(&render.collector, .render, &.{
        .{ .site = .runtime_completion_space, .edge = .before, .value = null },
        .{ .site = .runtime_completion_space, .edge = .after, .value = 0 },
        .{ .site = .runtime_completion_enqueue, .edge = .before, .value = 1 },
        .{ .site = .runtime_completion_enqueue, .edge = .after, .value = 1 },
        .{ .site = .runtime_completion_space, .edge = .before, .value = null },
        .{ .site = .runtime_completion_space, .edge = .after, .value = 0 },
    });
    try expectCompletionOrder(&control.collector, .control, &.{
        .{ .site = .runtime_completion_pop, .edge = .before, .value = null },
        .{ .site = .runtime_completion_pop, .edge = .after, .value = 1 },
        .{ .site = .runtime_completion_return, .edge = .before, .value = 1 },
        .{ .site = .runtime_completion_return, .edge = .after, .value = 1 },
        .{ .site = .runtime_completion_pop, .edge = .before, .value = null },
        .{ .site = .runtime_completion_pop, .edge = .after, .value = 1 },
    });
}

fn prerequisiteCompletionFailureTest() !void {
    if (!capture_order.supported_target) return error.SkipZigTest;
    // Capacity exhaustion is permanent even after the original queue operation
    // completes. Ordinary push/pop remain unobserved compatibility paths.
    var full: capture_order.Storage(1) = .{};
    try full.initInPlace(.render);
    full.collector.begin(1);
    var queue: SpscRing(1, u8) = .{};
    try std.testing.expect(queue.pushObserved(19, null, null, completionOrderBinding(&full.collector)));
    try std.testing.expect(!queue.pushObserved(27, null, null, completionOrderBinding(&full.collector)));
    try std.testing.expectEqual(capture_order.Failure.queue_full, full.collector.failureValue());
    try std.testing.expectEqual(@as(?u8, 19), queue.pop());
    try std.testing.expect(queue.push(31));
    try std.testing.expectEqual(@as(?u8, 31), queue.pop());
    full.collector.end(0);
    try std.testing.expectEqual(capture_order.Failure.queue_full, full.collector.failureValue());
    try std.testing.expectEqual(capture_order.Kind.begin, full.collector.pop().?.kind);
    try std.testing.expect(full.collector.pop() == null);

    var wrong_role: capture_order.Storage(8) = .{};
    try wrong_role.initInPlace(.control);
    wrong_role.collector.begin(1);
    try std.testing.expect(queue.pushObserved(41, null, null, completionOrderBinding(&wrong_role.collector)));
    try std.testing.expectEqual(capture_order.Failure.role_mismatch, wrong_role.collector.failureValue());
    try std.testing.expectEqual(@as(?u8, 41), queue.pop());
    try std.testing.expectEqual(capture_order.Kind.begin, wrong_role.collector.pop().?.kind);
    try std.testing.expect(wrong_role.collector.pop() == null);
}

test "reserved commands survive normal queue saturation and preserve sequence" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const stopped = try runtime.reserveInstance();
    try runtime.submitBus(.{ .bus = .sfx, .gain = 0.5, .ramp_frames = 1 });
    for (1..normal_command_capacity) |_| try runtime.submitBus(.{ .bus = .music, .gain = 0.75, .ramp_frames = 1 });
    try std.testing.expectError(error.CommandQueueFull, runtime.submitBus(.{ .bus = .master, .gain = 1, .ramp_frames = 1 }));
    try runtime.submitStop(.{ .instance = stopped, .fade_frames = 1 });
    try runtime.submitShutdown();
    while (runtime.normal.count() + runtime.reserved.count() > 0) _ = try runtime.controlTick(max_control_drain);
    try std.testing.expect(runtime.telemetry().queue_high_water == normal_command_capacity + 2);
    runtime.instances.release(stopped);
    try runtime.destroy();
}

test "sample owner remains pinned through snapshot and render retirement" {
    const samples = [_]f32{ 0.25, -0.25, 0.5, -0.5 };
    var owner = try SampleOwner.init(&samples);
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const instance = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{} });
    _ = try runtime.controlTick(max_control_drain);
    owner.retire();
    try std.testing.expect(!owner.canDestroy());
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [32]f32 = undefined;
    renderer.render(&output, 16, 2);
    _ = try runtime.controlTick(max_control_drain);
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "generation-safe single stop rejects stale reuse" {
    const samples = [_]f32{1} ** 64;
    var owner = try SampleOwner.init(&samples);
    defer if (!owner.retired.load(.acquire)) owner.retire();
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const first = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = first, .owner = &owner, .params = .{ .loop = true } });
    _ = try runtime.controlTick(max_control_drain);
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [32]f32 = undefined;
    renderer.render(&output, 16, 2);
    try runtime.submitStop(.{ .instance = first, .fade_frames = 1 });
    _ = try runtime.controlTick(max_control_drain);
    renderer.render(&output, 16, 2);
    _ = try runtime.controlTick(max_control_drain);
    const completion = runtime.pollCompletion();
    try std.testing.expect(completion != null);
    try std.testing.expect(completion.?.instance.eql(first));
    try std.testing.expectEqual(CompletionReason.stopped, completion.?.reason);
    const second = try runtime.reserveInstance();
    try std.testing.expect(first.index == second.index and first.generation != second.generation);
    try std.testing.expectError(error.StaleInstance, runtime.submitStop(.{ .instance = first, .fade_frames = 1 }));
    runtime.instances.release(second);
    owner.retire();
}

test "concurrent producers control and render preserve bounded snapshots" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    var context: StressContext = .{ .runtime = runtime };
    var producers: [4]std.Thread = undefined;
    for (&producers, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, stressProducer, .{ &context, @as(u32, @intCast(index)) });
    const control_thread = try std.Thread.spawn(.{}, stressControl, .{&context});
    const render_thread = try std.Thread.spawn(.{}, stressRender, .{&context});
    for (producers) |thread| thread.join();
    control_thread.join();
    render_thread.join();
    try std.testing.expect(!context.failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 4000), runtime.telemetry().accepted_commands);
    try std.testing.expect(runtime.telemetry().snapshot_generation > 0);
    try runtime.destroy();
}

test "control voice policy deterministically rejects and steals beyond 64" {
    const samples = [_]f32{ 0.25, -0.25 } ** 128;
    var owner = try SampleOwner.init(&samples);
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    for (0..max_render_voices) |_| {
        const instance = try runtime.reserveInstance();
        try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{ .loop = true, .priority = 0.5 } });
    }
    const rejected = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = rejected, .owner = &owner, .params = .{ .loop = true, .priority = 0.25 } });
    const strongest = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = strongest, .owner = &owner, .params = .{ .loop = true, .priority = 1 } });
    _ = try runtime.controlTick(max_control_drain);
    const first = runtime.pollCompletion();
    const second = runtime.pollCompletion();
    try std.testing.expect(first != null and first.?.instance.eql(rejected) and first.?.reason == .rejected);
    try std.testing.expect(second != null and second.?.reason == .stolen);
    try std.testing.expectEqual(@as(u32, max_render_voices), runtime.telemetry().live_instances);
    try std.testing.expectEqual(@as(u64, 1), runtime.telemetry().stolen_instances);

    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    try runtime.submitShutdown();
    _ = try runtime.controlTick(max_control_drain);
    renderer.render(&output, 256, 2);
    _ = try runtime.controlTick(max_control_drain);
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "repeated shutdown and destroy are idempotent with all counters retired" {
    const samples = [_]f32{ 0.1, -0.1 } ** 32;
    for (0..32) |_| {
        var owner = try SampleOwner.init(&samples);
        const runtime = try ControlRuntime.create(std.testing.allocator);
        defer std.testing.allocator.destroy(runtime);
        const instance = try runtime.reserveInstance();
        try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{ .loop = true } });
        _ = try runtime.controlTick(max_control_drain);
        var renderer = RuntimeRenderer.init(runtime, 48_000);
        var output: [64]f32 = undefined;
        renderer.render(&output, 32, 2);
        try runtime.submitShutdown();
        try runtime.submitShutdown();
        _ = try runtime.controlTick(max_control_drain);
        renderer.render(&output, 32, 2);
        _ = try runtime.controlTick(max_control_drain);
        owner.retire();
        owner.retire();
        try runtime.destroy();
        try runtime.destroy();
        const telemetry = runtime.telemetry();
        try std.testing.expectEqual(@as(u32, 0), telemetry.live_instances);
        try std.testing.expectEqual(@as(u32, 0), telemetry.snapshot_pins);
        try std.testing.expectEqual(@as(u32, 0), telemetry.render_pins);
        try std.testing.expect(owner.canDestroy());
    }
}

const ForcedProducer = struct {
    runtime: *ControlRuntime,
    stage: QueueStage,
    paused: std.atomic.Value(bool) = .init(false),
    unpause: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn hook(raw: *anyopaque, stage: QueueStage, command: Command) void {
        const self: *ForcedProducer = @ptrCast(@alignCast(raw));
        if (command != .bus or command.bus.gain != 0.25 or stage != self.stage) return;
        self.paused.store(true, .release);
        while (!self.unpause.load(.acquire)) std.atomic.spinLoopHint();
    }

    fn run(self: *ForcedProducer) void {
        self.runtime.submitBus(.{ .bus = .sfx, .gain = 0.25, .ramp_frames = 1 }) catch {
            self.failed.store(true, .release);
        };
    }
};

test "TASK-025 forced reserve inversion drains accepted commands" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    var context: ForcedProducer = .{ .runtime = runtime, .stage = .reserved };
    runtime.normal.test_hook = .{ .context = &context, .call = ForcedProducer.hook };
    const producer = try std.Thread.spawn(.{}, ForcedProducer.run, .{&context});
    while (!context.paused.load(.acquire)) std.atomic.spinLoopHint();
    runtime.submitBus(.{ .bus = .sfx, .gain = 0.75, .ramp_frames = 1 }) catch |err| {
        context.unpause.store(true, .release);
        producer.join();
        return err;
    };
    context.unpause.store(true, .release);
    producer.join();
    try std.testing.expect(!context.failed.load(.acquire));
    var drained: usize = 0;
    for (0..4) |_| drained += try runtime.controlTick(max_control_drain);
    try std.testing.expectEqual(@as(usize, 2), drained);
    // The producer paused BEFORE ticket assignment is accepted second, despite
    // claiming the first physical slot. Its value must be applied last.
    try std.testing.expectEqual(@as(f32, 0.25), runtime.sfx_gain);
    try runtime.destroy();
}

test "TASK-025 short one-shot renders once without control tick" {
    const samples = [_]f32{1} ** 4;
    var owner = try SampleOwner.init(&samples);
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const instance = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{} });
    _ = try runtime.controlTick(max_control_drain);
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    var audible = false;
    for (output) |sample| audible = audible or sample != 0;
    try std.testing.expect(audible);
    for (0..4) |_| {
        renderer.render(&output, 256, 2);
        for (output) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    }
    try std.testing.expectEqual(@as(usize, 1), runtime.render_completions.count());
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expectEqual(CompletionReason.finished, runtime.pollCompletion().?.reason);
    try std.testing.expect(runtime.pollCompletion() == null);
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "TASK-025 stop before first render releases instance" {
    const samples = [_]f32{1} ** 4;
    var owner = try SampleOwner.init(&samples);
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const instance = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{} });
    try runtime.submitStop(.{ .instance = instance, .fade_frames = 1 });
    _ = try runtime.controlTick(max_control_drain);
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expectEqual(@as(u32, 0), runtime.telemetry().live_instances);
    try std.testing.expectEqual(CompletionReason.stopped, runtime.pollCompletion().?.reason);
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

const MatrixProducer = struct {
    runtime: *ControlRuntime,
    command: Command,
    reserved: bool,
    failed: std.atomic.Value(bool) = .init(false),
    fn run(self: *MatrixProducer) void {
        self.runtime.submit(self.command, self.reserved) catch {
            self.failed.store(true, .release);
        };
    }
};

test "TASK-025 four producers every pause stage mixed lanes and ticket wrap" {
    for ([_]QueueStage{ .reserved, .sequenced, .published }) |stage| {
        for ([_]bool{ false, true }) |mixed| {
            for ([_]u64{ 1, std.math.maxInt(u64) - 1 }) |first_sequence| {
                const runtime = try ControlRuntime.create(std.testing.allocator);
                defer std.testing.allocator.destroy(runtime);
                runtime.next_sequence.store(first_sequence, .monotonic);
                runtime.next_control_sequence = first_sequence;
                runtime.normal.hint.store(std.math.maxInt(usize), .monotonic);
                runtime.reserved.hint.store(std.math.maxInt(usize), .monotonic);
                var context: ForcedProducer = .{ .runtime = runtime, .stage = stage };
                runtime.normal.test_hook = .{ .context = &context, .call = ForcedProducer.hook };
                const paused = try std.Thread.spawn(.{}, ForcedProducer.run, .{&context});
                while (!context.paused.load(.acquire)) std.atomic.spinLoopHint();
                var contexts: [3]MatrixProducer = undefined;
                var threads: [3]std.Thread = undefined;
                for (&contexts, &threads, 0..) |*producer, *thread, index| {
                    const reserved = mixed and index % 2 == 0;
                    producer.* = .{ .runtime = runtime, .reserved = reserved, .command = if (reserved)
                        .{ .stop = .{ .instance = try runtime.reserveInstance(), .fade_frames = 1 } }
                    else
                        .{ .bus = .{ .bus = .music, .gain = @as(f32, @floatFromInt(index + 1)), .ramp_frames = 1 } } };
                    thread.* = try std.Thread.spawn(.{}, MatrixProducer.run, .{producer});
                }
                for (threads) |thread| thread.join();
                // A producer paused after ticket assignment blocks that ticket,
                // but not one paused before assignment or after publication.
                const before = try runtime.controlTick(max_control_drain);
                context.unpause.store(true, .release);
                paused.join();
                try std.testing.expectEqual(@as(usize, if (stage == .sequenced) 0 else if (stage == .reserved) 3 else 4), before);
                var drained = before;
                for (0..4) |_| drained += try runtime.controlTick(max_control_drain);
                try std.testing.expectEqual(@as(usize, 4), drained);
                try std.testing.expectEqual(first_sequence +% 4, runtime.next_control_sequence);
                try std.testing.expectEqual(@as(usize, 0), runtime.normal.count() + runtime.reserved.count());
                for (&contexts) |*producer| try std.testing.expect(!producer.failed.load(.acquire));
                try std.testing.expect(!context.failed.load(.acquire));
                try runtime.destroy();
            }
        }
    }
}

test "TASK-025 render completion saturation retries without restart or lost pin" {
    const samples = [_]f32{1} ** 4;
    var owner = try SampleOwner.init(&samples);
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const instance = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{} });
    _ = try runtime.controlTick(max_control_drain);
    // Fill with stale generations: this models delayed receipts from retired
    // incarnations, and forces the production push path's backpressure branch.
    for (0..max_instances) |_| try std.testing.expect(runtime.render_completions.push(.{ .instance = .{ .index = 0, .generation = 0 }, .reason = .finished }));
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    try std.testing.expectEqual(@as(u32, 1), runtime.telemetry().render_pins);
    for (0..4) |_| {
        renderer.render(&output, 256, 2);
        for (output) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    }
    try std.testing.expectEqual(@as(usize, max_instances), runtime.render_completions.count());
    _ = try runtime.controlTick(max_control_drain);
    renderer.render(&output, 256, 2);
    try std.testing.expectEqual(@as(u32, 0), runtime.telemetry().render_pins);
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expectEqual(CompletionReason.finished, runtime.pollCompletion().?.reason);
    try std.testing.expect(runtime.pollCompletion() == null);
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "TASK-025 host completion saturation preserves lifecycle and reports loss" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    for (0..max_instances + 4) |_| {
        const instance = try runtime.reserveInstance();
        try runtime.submitStop(.{ .instance = instance, .fade_frames = 1 });
        _ = try runtime.controlTick(max_control_drain);
    }
    try std.testing.expectEqual(@as(usize, max_instances), runtime.reported_completions.count());
    try std.testing.expectEqual(@as(u32, 0), runtime.telemetry().live_instances);
    try std.testing.expectEqual(@as(u64, 4), runtime.telemetry().completion_overflow);
    var count: usize = 0;
    while (runtime.pollCompletion()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, max_instances), count);
    try runtime.destroy();
}

test "TASK-025 snapshot writer contention and owner pin saturation are bounded" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [2]f32 = .{ 99, 99 };
    runtime.snapshots[0].readers.store(SnapshotSlot.writing, .release);
    renderer.render(&output, 1, 2);
    try std.testing.expectEqual(@as(u64, 1), runtime.telemetry().snapshot_misses);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0 }, &output);
    runtime.snapshots[0].readers.store(0, .release);
    const samples = [_]f32{1} ** 4;
    var owner = try SampleOwner.init(&samples);
    owner.references.store(std.math.maxInt(u32), .release);
    try std.testing.expectError(error.InvalidState, owner.pin());
    owner.references.store(0, .release);
    try std.testing.expectError(error.InvalidState, owner.pin());
    try runtime.destroy();
}

test "TASK-025 generation wraps past zero and old completion cannot kill reuse" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    runtime.instances.slots[0].store(std.math.maxInt(u16), .release);
    const instance = try runtime.reserveInstance();
    try std.testing.expectEqual(@as(u16, 1), instance.generation);
    try runtime.submitStop(.{ .instance = instance, .fade_frames = 1 });
    _ = try runtime.controlTick(max_control_drain);
    _ = runtime.pollCompletion();
    const next = try runtime.reserveInstance();
    try std.testing.expect(runtime.render_completions.push(.{ .instance = instance, .reason = .finished }));
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expect(runtime.instances.current(next));
    try runtime.submitStop(.{ .instance = next, .fade_frames = 1 });
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expect(runtime.pollCompletion().?.instance.eql(next));
    try std.testing.expect(runtime.pollCompletion() == null);
    try runtime.destroy();
}

test "TASK-025 shutdown rejects late accepted play and drains reserved identities" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const instance = try runtime.reserveInstance();
    var owner = try SampleOwner.init(&.{1});
    try runtime.submitShutdown();
    // Force the admission race: retain+enqueue happens after an earlier public
    // accepting check but behind shutdown's ticket.
    try owner.retain();
    try runtime.submit(.{ .play = .{ .instance = instance, .owner = &owner, .params = .{} } }, false);
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expectEqual(@as(u32, 0), runtime.telemetry().live_instances);
    try std.testing.expectEqual(@as(usize, 1), runtime.reported_completions.count());
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "TASK-025 delayed same-generation receipt cannot retire a new incarnation" {
    const samples = [_]f32{1} ** 16;
    var owner = try SampleOwner.init(&samples);
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const old = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = old, .owner = &owner, .params = .{} });
    _ = try runtime.controlTick(max_control_drain);
    const old_order = runtime.desired[old.index].start_order;
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    _ = try runtime.controlTick(max_control_drain);
    _ = runtime.pollCompletion();
    // Model a full 16-bit generation cycle while the renderer was delayed.
    // The public handle aliases, but the private command incarnation does not.
    runtime.instances.slots[old.index].store(std.math.maxInt(u16), .release);
    const fresh = try runtime.reserveInstance();
    try std.testing.expect(fresh.eql(old));
    try runtime.submitPlay(.{ .instance = fresh, .owner = &owner, .params = .{ .loop = true } });
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expect(runtime.desired[fresh.index].start_order != old_order);
    try std.testing.expect(runtime.render_completions.push(.{ .instance = old, .reason = .finished, .start_order = old_order }));
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expect(runtime.instances.current(fresh));
    renderer.render(&output, 256, 2);
    try std.testing.expectEqual(@as(usize, 1), renderer.activeVoiceCount());
    try runtime.submitShutdown();
    _ = try runtime.controlTick(max_control_drain);
    renderer.render(&output, 256, 2);
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expect(runtime.pollCompletion().?.instance.eql(fresh));
    try std.testing.expect(runtime.pollCompletion() == null);
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "TASK-025 leased snapshot owners cannot be rewritten while readers remain" {
    const samples = [_]f32{1} ** 4;
    var owner = try SampleOwner.init(&samples);
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const instance = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{} });
    _ = try runtime.controlTick(max_control_drain);
    const first = runtime.acquireSnapshot();
    const first_generation = first.snapshot.generation;
    _ = try runtime.controlTick(max_control_drain);
    const second = runtime.acquireSnapshot();
    _ = try runtime.controlTick(max_control_drain);
    owner.retire();
    try std.testing.expectError(error.SnapshotBusy, runtime.controlTick(max_control_drain));
    try std.testing.expectEqual(first_generation, first.snapshot.generation);
    try std.testing.expect(!owner.canDestroy());
    first.release();
    second.release();
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    _ = try runtime.controlTick(max_control_drain);
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "TASK-025 stopped unstarted voice retries a saturated render receipt queue" {
    var owner = try SampleOwner.init(&.{1});
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const instance = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{} });
    try runtime.submitStop(.{ .instance = instance, .fade_frames = 1 });
    _ = try runtime.controlTick(max_control_drain);
    for (0..max_instances) |_| try std.testing.expect(runtime.render_completions.push(.{ .instance = .{ .index = 0, .generation = 0 }, .reason = .finished }));
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    try std.testing.expectEqual(@as(usize, 0), renderer.activeVoiceCount());
    for (output) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    _ = try runtime.controlTick(max_control_drain);
    for (0..4) |_| renderer.render(&output, 256, 2);
    try std.testing.expectEqual(@as(usize, 1), runtime.render_completions.count());
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expectEqual(CompletionReason.stopped, runtime.pollCompletion().?.reason);
    try std.testing.expect(runtime.pollCompletion() == null);
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "TASK-025 playing steal completes each incarnation once across sequence wrap" {
    var owner = try SampleOwner.init(&([_]f32{1} ** 64));
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    runtime.next_sequence.store(std.math.maxInt(u64) - 31, .monotonic);
    runtime.next_control_sequence = std.math.maxInt(u64) - 31;
    var newest: InstanceHandle = undefined;
    for (0..max_render_voices) |_| {
        newest = try runtime.reserveInstance();
        try runtime.submitPlay(.{ .instance = newest, .owner = &owner, .params = .{ .loop = true, .priority = 0.5 } });
    }
    _ = try runtime.controlTick(max_control_drain);
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    const strongest = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = strongest, .owner = &owner, .params = .{ .loop = true, .priority = 1 } });
    _ = try runtime.controlTick(max_control_drain);
    const stolen = runtime.pollCompletion().?;
    try std.testing.expectEqual(CompletionReason.stolen, stolen.reason);
    try std.testing.expect(stolen.instance.eql(newest));
    renderer.render(&output, 256, 2);
    _ = try runtime.controlTick(max_control_drain);
    renderer.render(&output, 256, 2);
    try std.testing.expectEqual(@as(usize, max_render_voices), renderer.activeVoiceCount());
    try runtime.submitShutdown();
    _ = try runtime.controlTick(max_control_drain);
    renderer.render(&output, 256, 2);
    _ = try runtime.controlTick(max_control_drain);
    var seen = [_]bool{false} ** max_instances;
    var count: usize = 0;
    while (runtime.pollCompletion()) |completion| {
        try std.testing.expectEqual(CompletionReason.stopped, completion.reason);
        try std.testing.expect(!seen[completion.instance.index]);
        try std.testing.expect(!completion.instance.eql(stolen.instance));
        seen[completion.instance.index] = true;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, max_render_voices), count);
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "TASK-025 older stolen fade cannot overwrite reused index terminal" {
    var owner = try SampleOwner.init(&([_]f32{1} ** 4));
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const old = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = old, .owner = &owner, .params = .{ .loop = true, .priority = 0.1 } });
    _ = try runtime.controlTick(max_control_drain);
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    // Force the legal slot layout left when earlier-index voices have finished:
    // old voice occupies the final renderer slot; newly started short voice uses
    // the first. Completion collection will observe the new finish BEFORE old.
    renderer.voices[max_render_voices - 1] = renderer.voices[0];
    renderer.voices[0] = .{};
    for (1..max_render_voices) |_| {
        const other = try runtime.reserveInstance();
        try runtime.submitPlay(.{ .instance = other, .owner = &owner, .params = .{ .loop = true, .priority = 0.5 } });
    }
    const incoming = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = incoming, .owner = &owner, .params = .{ .loop = true, .priority = 1 } });
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expect(runtime.pollCompletion().?.instance.eql(old));
    const fresh = try runtime.reserveInstance();
    try std.testing.expectEqual(old.index, fresh.index);
    try runtime.submitPlay(.{ .instance = fresh, .owner = &owner, .params = .{ .priority = 1 } });
    _ = try runtime.controlTick(max_control_drain);
    renderer.render(&output, 256, 2);
    const order = runtime.desired[fresh.index].start_order;
    try std.testing.expectEqual(order, renderer.terminal[fresh.index].start_order);
    try std.testing.expectEqual(fresh.generation, renderer.terminal[fresh.index].generation);
    const receipts = runtime.render_completions.count();
    for (0..4) |_| renderer.render(&output, 256, 2);
    try std.testing.expectEqual(receipts, runtime.render_completions.count());
    _ = try runtime.controlTick(max_control_drain);
    try runtime.submitShutdown();
    _ = try runtime.controlTick(max_control_drain);
    renderer.render(&output, 256, 2);
    _ = try runtime.controlTick(max_control_drain);
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "TASK-025 late duplicate play after shutdown preserves active lifecycle" {
    var owner = try SampleOwner.init(&([_]f32{1} ** 8));
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const instance = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{ .loop = true } });
    _ = try runtime.controlTick(max_control_drain);
    var renderer = RuntimeRenderer.init(runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    try runtime.submitShutdown();
    // Simulate a duplicate submitPlay whose initial accepting check happened
    // before shutdown, but whose enqueue was delayed behind shutdown's ticket.
    try owner.retain();
    try runtime.submit(.{ .play = .{ .instance = instance, .owner = &owner, .params = .{} } }, false);
    _ = try runtime.controlTick(max_control_drain);
    try std.testing.expect(runtime.instances.current(instance));
    try std.testing.expect(runtime.pollCompletion() == null);
    renderer.render(&output, 256, 2);
    _ = try runtime.controlTick(max_control_drain);
    const completion = runtime.pollCompletion().?;
    try std.testing.expect(completion.instance.eql(instance));
    try std.testing.expectEqual(CompletionReason.stopped, completion.reason);
    try std.testing.expect(runtime.pollCompletion() == null);
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "snapshot descriptor keeps resident digests and domain-separates stream profile" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    var slot: resident_transaction.Slot = .{ .desc = .{ .capture = .{ .bank_generation = 7, .transport_epoch = 3 } } };
    const capture_expected = [_]u8{ 0x68, 0x2f, 0x6e, 0xfe, 0x61, 0xa7, 0x83, 0x1b, 0xeb, 0xa3, 0x33, 0xaa, 0x6d, 0x0c, 0x5e, 0x60, 0xab, 0xab, 0x2f, 0xc8, 0x01, 0xa4, 0x7f, 0x69, 0xf5, 0x25, 0xe0, 0xd7, 0xd5, 0x43, 0x45, 0xc7 };
    try std.testing.expectEqualSlices(u8, &capture_expected, &runtime.hashResidentDescriptor(&slot));
    slot.desc.capture.profile = .stream_direct_v1;
    const direct_capture = [_]u8{ 0xe2, 0xe8, 0x46, 0x45, 0x1a, 0xdb, 0xa7, 0xbc, 0x96, 0xd9, 0xe2, 0xc4, 0xf6, 0xcd, 0x2f, 0x57, 0xff, 0xd6, 0x0c, 0x54, 0x79, 0xe7, 0x19, 0x21, 0xe2, 0x5e, 0x28, 0xeb, 0xfe, 0xf0, 0x42, 0x63 };
    try std.testing.expectEqualSlices(u8, &direct_capture, &runtime.hashResidentDescriptor(&slot));
    slot.desc.capture.profile = .stream_fill_v1;
    const fill_capture = runtime.hashResidentDescriptor(&slot);
    try std.testing.expect(!std.mem.eql(u8, &fill_capture, &capture_expected));
    try std.testing.expect(!std.mem.eql(u8, &fill_capture, &direct_capture));
    slot.plan_content_hash[0] = 1;
    try std.testing.expect(!std.mem.eql(u8, &fill_capture, &runtime.hashResidentDescriptor(&slot)));
    slot.desc = .{ .restore = .{ .bank_generation = 7, .expected_transport_epoch = 3, .new_transport_epoch = 4, .install_frame = 128 } };
    const restore_expected = [_]u8{ 0x2a, 0xdf, 0xcf, 0xa3, 0xd8, 0xc4, 0x99, 0x7e, 0xf5, 0x91, 0x1f, 0x1c, 0xd3, 0xe6, 0x38, 0xf2, 0x37, 0xf4, 0x00, 0x69, 0xdd, 0xea, 0xc6, 0x85, 0x0c, 0x1b, 0x95, 0xb9, 0x60, 0x49, 0x89, 0x9d };
    try std.testing.expectEqualSlices(u8, &restore_expected, &runtime.hashResidentDescriptor(&slot));
    slot.desc.restore.profile = .stream_direct_v1;
    const direct_restore = [_]u8{ 0x4a, 0xfa, 0x7a, 0xa9, 0x90, 0x14, 0xef, 0x00, 0x4e, 0x88, 0x71, 0x2a, 0x44, 0xa8, 0x84, 0xd2, 0x73, 0xde, 0xb5, 0x2d, 0xca, 0x4d, 0xa6, 0x9f, 0xf6, 0x73, 0x7a, 0x39, 0xce, 0x41, 0x0a, 0x46 };
    try std.testing.expectEqualSlices(u8, &direct_restore, &runtime.hashResidentDescriptor(&slot));
    slot.desc.restore.profile = .stream_fill_v1;
    try std.testing.expect(!std.mem.eql(u8, &restore_expected, &runtime.hashResidentDescriptor(&slot)));
    try std.testing.expect(!std.mem.eql(u8, &direct_restore, &runtime.hashResidentDescriptor(&slot)));
    try runtime.destroy();
}

test "direct stream transaction rejects suffix multiple groups and cross generation before retention" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    try std.testing.expectError(error.UnsupportedOperation, runtime.prepareResidentCapture(.{ .profile = .stream_direct_v1, .bank_generation = 7, .transport_epoch = 3, .plan = .{ .index = 0, .generation = 1 } }));
    try std.testing.expectError(error.UnsupportedOperation, runtime.prepareResidentCapture(.{ .profile = .stream_direct_v1, .bank_generation = 7, .transport_epoch = 3, .groups = .{ .count = 2 } }));
    try std.testing.expectError(error.UnsupportedOperation, runtime.prepareResidentRestore(.{ .profile = .stream_direct_v1, .bank_generation = 8, .expected_bank_generation = 7, .expected_transport_epoch = 3, .new_transport_epoch = 4, .install_frame = 128 }));
    try std.testing.expectEqual(resident_transaction.State.free, runtime.resident_transaction_slot.state.load(.acquire));
    const ready = try runtime.prepareResidentCapture(.{ .profile = .stream_direct_v1, .bank_generation = 7, .transport_epoch = 3 });
    try std.testing.expectEqual(resident_transaction.Profile.stream_direct_v1, runtime.resident_transaction_slot.profile());
    _ = try runtime.cancelResidentTransaction(ready);
    try runtime.acknowledgeResidentTransaction(ready);
    try runtime.destroy();
}

test "stream fill pending plan digest binds bounded hard cuts independent of publication tickets" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    const handles = [_]GroupHandle{ .{ .index = 0, .generation = 1 }, .{ .index = 1, .generation = 2 }, .{ .index = 2, .generation = 3 }, .{ .index = 3, .generation = 4 } };
    const groups: resident_transaction.GroupSet = .{ .items = handles, .count = 4 };
    const token: music.PhaseToken = .{ .context = @enumFromInt(1), .transport_epoch = @enumFromInt(3), .plan_id = @enumFromInt(5), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(1), .asset_generation = @enumFromInt(7) };
    const ledger = &runtime.scheduled.plans[0];
    ledger.* = .{ .active = true, .generation = 9, .token = token, .total_phases = 3, .prepared_phases = 3, .command_count = 6, .last_frame = 384 };
    const block = &runtime.scheduled.slots[0];
    block.* = .{ .plan_index = 0, .block = .{ .id = 1, .content_hash = @splat(0), .start_frame = 128, .end_frame = 385, .count = 6 } };
    block.state.store(.prepared, .release);
    for (0..3) |phase| {
        var identity: scheduler.CommandIdentity = .{ .command_id = phase * 2 + 1, .token = token, .phase_order = @intCast(phase), .execute_frame = (phase + 1) * 128, .group_id = phase + 1 };
        identity.token.phase_id = @enumFromInt(phase + 1);
        ledger.phase_ids[phase] = identity.token.phase_id;
        ledger.phase_groups[phase] = identity.group_id;
        block.block.commands[phase * 2] = .{ .identity = identity, .payload = .{ .group_stop = .{ .group = handles[phase], .release_frames = 0 } } };
        identity.command_id += 1;
        block.block.commands[phase * 2 + 1] = .{ .identity = identity, .payload = .{ .group_start = .{ .group = handles[phase + 1] } } };
        ledger.command_ids[phase * 2] = phase * 2 + 1;
        ledger.command_ids[phase * 2 + 1] = phase * 2 + 2;
    }
    const plan: scheduler.Handle = .{ .index = 0, .generation = 9 };
    const original = try runtime.validateStreamFillPlan(&groups, plan);
    for (block.block.commands[0..6]) |*command| command.sequence = 55;
    try std.testing.expectEqualSlices(u8, &original, &try runtime.validateStreamFillPlan(&groups, plan));
    block.block.commands[2].identity.execute_frame += 1;
    block.block.commands[3].identity.execute_frame += 1;
    const shifted = try runtime.validateStreamFillPlan(&groups, plan);
    try std.testing.expect(!std.mem.eql(u8, &original, &shifted));
    block.block.commands[2].payload.group_stop.release_frames = 1;
    try std.testing.expectError(error.UnsupportedOperation, runtime.validateStreamFillPlan(&groups, plan));
    block.block.commands[2].payload.group_stop.release_frames = 0;
    block.block.commands[3].payload.group_start.group.generation += 1;
    try std.testing.expectError(error.UnsupportedOperation, runtime.validateStreamFillPlan(&groups, plan));
    block.block.commands[3].payload.group_start.group = handles[2];
    ledger.total_phases = 5;
    try std.testing.expectError(error.UnsupportedOperation, runtime.validateStreamFillPlan(&groups, plan));
    ledger.total_phases = 3;
    const descriptor: resident_transaction.Slot = .{ .desc = .{ .capture = .{ .profile = .stream_fill_v1, .bank_generation = 7, .transport_epoch = 3, .plan = plan } }, .plan_content_hash = shifted };
    const authenticated = runtime.hashResidentDescriptor(&descriptor);
    ledger.phase_groups[1] += 1;
    try std.testing.expect(!std.mem.eql(u8, &authenticated, &runtime.hashResidentDescriptor(&descriptor)));
    // Metadata-only fixture: no submitted schedule, stream lease, or owner pin.
}

test "stream fill transaction admits ready capture but keeps cross-bank and foreign work guards" {
    const runtime = try ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(runtime);
    try std.testing.expectError(error.UnsupportedOperation, runtime.prepareResidentRestore(.{ .profile = .stream_fill_v1, .bank_generation = 8, .expected_bank_generation = 7, .expected_transport_epoch = 3, .new_transport_epoch = 4, .install_frame = 128 }));
    const ticket = try runtime.prepareResidentCapture(.{ .profile = .stream_fill_v1, .bank_generation = 7, .transport_epoch = 3 });
    const command: ScheduledCommand = .{ .identity = .{ .command_id = 1, .token = .{ .context = @enumFromInt(1), .transport_epoch = @enumFromInt(3), .plan_id = @enumFromInt(1), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(1), .asset_generation = @enumFromInt(7) }, .phase_order = 0, .execute_frame = 128, .group_id = 1 }, .payload = .{ .group_start = .{ .group = .{ .index = 0, .generation = 1 } } } };
    try std.testing.expectError(error.ResidentTransactionBusy, runtime.prepareSchedule(128, 129, &.{command}));
    _ = try runtime.cancelResidentTransaction(ticket);
    try runtime.acknowledgeResidentTransaction(ticket);
    try std.testing.expectEqual(resident_transaction.State.free, runtime.resident_transaction_slot.state.load(.acquire));
    try runtime.destroy();
}

test "stream snapshot windows preserve source origin loop epoch freshness and ordinary readiness" {
    var pcm: [16]f32 = @splat(0);
    var ring: streaming.Ring = .{ .generation = 9, .pcm = &pcm, .channels = 2, .capacity_frames = 8, .start_cursor = 12, .start_loop_epoch = 3, .frames = 100, .loop = .{ .start = 10, .end = 18 } };
    const source: streaming.Source = .{ .ring = &ring, .identity = .{ .asset = 2, .asset_generation = 7, .transport_epoch = 4, .stream_generation = 9, .profile_id = 1, .profile_hash = @splat(0), .encoded_hash = @splat(0), .start_cursor = 12, .start_loop_epoch = 3, .frame_count = 100, .channels = 2, .minimum_playable_frames = 2, .loop = .{ .start = 10, .end = 18 } } };
    var prepared = try music_group.Prepared.prepare(.{ .segment = 1, .generation = 7, .layout = channel_layout.stereo, .layers = &.{.{ .stream = source, .samples = &.{}, .asset_frame_origin = 10, .layout = channel_layout.stereo, .generation = 7 }}, .segment_frames = 8, .loop = .{ .start = 0, .end = 8 }, .start_cursor = 2, .start_loop_epoch = 3 }, channel_layout.stereo, 48_000);
    try std.testing.expect(snapshotPreparedProfile(&prepared, .stream_direct_v1));
    try std.testing.expect(snapshotPreparedProfile(&prepared, .stream_fill_v1));
    prepared.ramp_frames = 16;
    try std.testing.expect(!snapshotPreparedProfile(&prepared, .stream_fill_v1));
    try std.testing.expect(snapshotPreparedProfile(&prepared, .stream_direct_v1));
    prepared.ramp_frames = 0;
    try std.testing.expect(!snapshotPreparedProfile(&prepared, .resident_v1));
    try std.testing.expect(freshSnapshotSource(&prepared, &prepared.layers[0], source, 4));
    try std.testing.expect(!freshSnapshotSource(&prepared, &prepared.layers[0], source, 3));
    try std.testing.expect(!prepared.minimumPlayable(2, 3));
    try ring.publish(&.{ 0.25, 0.25, 0.5, 0.5 });
    try std.testing.expect(prepared.minimumPlayable(2, 3));
    try std.testing.expect(!prepared.minimumPlayable(2, 2));
    var recycled = source;
    recycled.identity.stream_generation += 1;
    try std.testing.expect(sameSnapshotWindow(source, source));
    try std.testing.expect(!sameSnapshotWindow(source, recycled));
    var group = music_group.MusicVoiceGroup.start(.{ .index = 0, .generation = 1 }, &prepared, 128);
    try group.pause(true);
    try std.testing.expect(group.paused);
    try std.testing.expectEqual(@as(u64, 2), group.cursor);
    try std.testing.expectEqual(@as(u64, 3), group.loop_epoch);
    try std.testing.expectEqual(@as(u64, 2), group.mutation_epoch);
    ring.consume();
    try std.testing.expect(!freshSnapshotSource(&prepared, &prepared.layers[0], source, 4));
    prepared.layers[0].stream = null;
    try std.testing.expect(!snapshotPreparedProfile(&prepared, .stream_direct_v1));
}

/// Narrow test-root entry points for private lower-gate regressions. No helper
/// or mutation surface exists in non-test builds.
pub const stream_reload_testing = if (@import("builtin").is_test) struct {
    pub fn expectHistoricalHashesUnchanged() !void {
        const runtime = try ControlRuntime.create(std.testing.allocator);
        defer std.testing.allocator.destroy(runtime);
        // Pinned pre-reload digests. The new standalone root executes these
        // directly rather than relying on dependency-local test discovery.
        const captures = [_][]const u8{
            "682f6efe61a7831beba333aa6d0c5e60abab2fc801a47f69f525e0d7d54345c7",
            "e2e846451adba7bc96d9e2c4f6cd2f57ffd60c5479e71921e25e28ebfef04263",
            "0dc393f40cd7e9b0a20f7b2658c156138b82a3764383912be9287398cb0b6648",
        };
        const restores = [_][]const u8{
            "2adfcfa3d8c4997ef5911f1cd3e638f237f40069ddeac6850c1b95b96049899d",
            "4afa7aa99014ef004e88712a44a884d273deb52dca4da69ff6737a39ce410a46",
            "642bef9d7c6632537d7ff4ab1af8ea54f244f4141a52779e852c6a5356c910f0",
        };
        for ([_]resident_transaction.Profile{ .resident_v1, .stream_direct_v1, .stream_fill_v1 }, 0..) |profile, i| {
            var legacy: resident_transaction.Slot = .{ .desc = .{ .capture = .{ .profile = profile, .bank_generation = 7, .transport_epoch = 3 } } };
            try std.testing.expectEqualStrings(captures[i], &std.fmt.bytesToHex(runtime.hashResidentDescriptor(&legacy), .lower));
            legacy.desc = .{ .restore = .{ .profile = profile, .bank_generation = 7, .expected_transport_epoch = 3, .new_transport_epoch = 4, .install_frame = 128 } };
            try std.testing.expectEqualStrings(restores[i], &std.fmt.bytesToHex(runtime.hashResidentDescriptor(&legacy), .lower));
        }
        var slot: resident_transaction.Slot = .{ .desc = .{ .restore = .{ .bank_generation = 8, .expected_bank_generation = 7, .expected_transport_epoch = 3, .new_transport_epoch = 4, .install_frame = 128 } } };
        for ([_]resident_transaction.Profile{ .resident_v1, .stream_direct_v1, .stream_fill_v1 }) |profile| {
            slot.desc.restore.profile = profile;
            slot.desc.restore.expected_outgoing_segment = null;
            slot.desc.restore.expected_outgoing_cursor = null;
            slot.desc.restore.expected_outgoing_loop_epoch = null;
            const historical = runtime.hashResidentDescriptor(&slot);
            slot.desc.restore.expected_outgoing_segment = 11;
            slot.desc.restore.expected_outgoing_cursor = 0;
            slot.desc.restore.expected_outgoing_loop_epoch = 1;
            try std.testing.expectEqualSlices(u8, &historical, &runtime.hashResidentDescriptor(&slot));
            slot.desc.restore.profile = .stream_reload_v1;
            try std.testing.expect(!std.mem.eql(u8, &historical, &runtime.hashResidentDescriptor(&slot)));
        }
        const sealed = runtime.hashResidentDescriptor(&slot);
        slot.desc.restore.expected_outgoing_segment = 12;
        try std.testing.expect(!std.mem.eql(u8, &sealed, &runtime.hashResidentDescriptor(&slot)));
        slot.desc.restore.expected_outgoing_segment = 11;
        slot.desc.restore.expected_outgoing_cursor = 1;
        try std.testing.expect(!std.mem.eql(u8, &sealed, &runtime.hashResidentDescriptor(&slot)));
        slot.desc.restore.expected_outgoing_cursor = null;
        try std.testing.expect(!std.mem.eql(u8, &sealed, &runtime.hashResidentDescriptor(&slot)));
        slot.desc.restore.expected_outgoing_cursor = 0;
        slot.desc.restore.expected_outgoing_loop_epoch = 2;
        try std.testing.expect(!std.mem.eql(u8, &sealed, &runtime.hashResidentDescriptor(&slot)));
        try runtime.destroy();
    }

    pub fn expectCoordinateAndFreshnessGuards() !void {
        // Metadata-only negative unit fixture. No PCM is published and no schedule
        // is admitted; this cannot stand in for the real V2 provider acceptance run.
        var pcm: [8][16]f32 = @splat(@splat(0));
        var rings: [8]streaming.Ring = undefined;
        var sources: [8]streaming.Source = undefined;
        var layers: [8]music_group.Layer = undefined;
        for (&rings, &sources, &layers, &pcm, 0..) |*ring, *source, *layer, *buffer, i| {
            const generation: u64 = if (i < 4) 7 else 8;
            ring.* = .{ .generation = i + 1, .pcm = buffer, .channels = 2, .capacity_frames = 8, .start_cursor = 12, .start_loop_epoch = 3, .frames = 100, .loop = .{ .start = 10, .end = 18 } };
            source.* = .{ .ring = ring, .identity = .{ .asset = i % 4 + 1, .asset_generation = generation, .transport_epoch = if (i < 4) 3 else 4, .stream_generation = i + 1, .profile_id = 1, .profile_hash = @splat(0), .encoded_hash = @splat(0), .start_cursor = 12, .start_loop_epoch = 3, .frame_count = 100, .channels = 2, .minimum_playable_frames = 2, .loop = .{ .start = 10, .end = 18 } } };
            layer.* = .{ .stream = source.*, .samples = &.{}, .asset_frame_origin = 10, .layout = channel_layout.stereo, .generation = generation };
        }
        const outgoing = try music_group.Prepared.prepare(.{ .segment = 11, .generation = 7, .layout = channel_layout.stereo, .layers = layers[0..4], .segment_frames = 8, .loop = .{ .start = 0, .end = 8 }, .start_cursor = 2, .start_loop_epoch = 3 }, channel_layout.stereo, 48_000);
        var replacement = try music_group.Prepared.prepare(.{ .segment = 12, .generation = 8, .layout = channel_layout.stereo, .layers = layers[4..8], .segment_frames = 8, .loop = .{ .start = 0, .end = 8 }, .start_cursor = 2, .start_loop_epoch = 3 }, channel_layout.stereo, 48_000);
        const old_handle: GroupHandle = .{ .index = 0, .generation = 1 };
        var groups: resident_transaction.GroupSet = .{};
        groups.items[0] = old_handle;
        groups.count = 1;
        var desc: resident_transaction.RestoreDesc = .{ .profile = .stream_reload_v1, .bank_generation = 8, .expected_bank_generation = 7, .expected_transport_epoch = 3, .new_transport_epoch = 4, .install_frame = 128, .old_groups = groups, .replacement = .{ .index = 1, .generation = 1 }, .expected_outgoing_segment = 11, .expected_outgoing_cursor = 2, .expected_outgoing_loop_epoch = 3 };
        var physical = music_group.MusicVoiceGroup.start(old_handle, &outgoing, 0);
        try std.testing.expect(snapshotPreparedProfile(&outgoing, .stream_reload_v1));
        try std.testing.expect(snapshotPreparedProfile(&replacement, .stream_reload_v1));
        try std.testing.expect(streamReloadCoordinates(desc, &outgoing, &replacement));
        try std.testing.expect(streamReloadPhysicalMatches(desc, &physical));
        try std.testing.expect(!replacement.minimumPlayable(2, 3));
        desc.expected_outgoing_cursor = 3;
        try std.testing.expect(!streamReloadCoordinates(desc, &outgoing, &replacement));
        try std.testing.expect(!streamReloadPhysicalMatches(desc, &physical));
        desc.expected_outgoing_cursor = 2;
        desc.expected_outgoing_loop_epoch = 4;
        try std.testing.expect(!streamReloadCoordinates(desc, &outgoing, &replacement));
        try std.testing.expect(!streamReloadPhysicalMatches(desc, &physical));
        desc.expected_outgoing_loop_epoch = 3;
        desc.expected_outgoing_segment = 12;
        try std.testing.expect(!streamReloadCoordinates(desc, &outgoing, &replacement));
        try std.testing.expect(!streamReloadPhysicalMatches(desc, &physical));
        desc.expected_outgoing_segment = 11;
        physical.mutation_epoch = 2;
        try std.testing.expect(!streamReloadPhysicalMatches(desc, &physical));
        physical.mutation_epoch = 1;
        replacement.layers[0].stream = sources[0];
        try std.testing.expect(!streamReloadCoordinates(desc, &outgoing, &replacement));
        replacement.layers[0].stream = sources[4];
        replacement.layers[0].stream.?.identity.stream_generation += 1;
        try std.testing.expect(!freshSnapshotSource(&replacement, &replacement.layers[0], replacement.layers[0].stream.?, 4));
        replacement.layers[0].stream = sources[4];
        try std.testing.expect(!freshSnapshotSource(&replacement, &replacement.layers[0], sources[4], 3));
        replacement.layer_count = 3;
        try std.testing.expect(!snapshotPreparedProfile(&replacement, .stream_reload_v1));
        replacement.layer_count = 4;
        replacement.layers[0].stream = null;
        try std.testing.expect(!snapshotPreparedProfile(&replacement, .stream_reload_v1));
        try std.testing.expectEqual(music_group.State.playing, physical.state);
        try std.testing.expectEqual(@as(u64, 2), physical.cursor);
        try std.testing.expectEqual(@as(u64, 3), physical.loop_epoch);
    }
} else struct {};

/// Seek is a same-generation replacement of one exact live source. It cannot
/// borrow Ready/Paused restore permission or reload's cross-generation promise.
fn streamPreviewSeekDescriptor(desc: resident_transaction.RestoreDesc) bool {
    const guard = desc.seek_guard orelse return false;
    return desc.profile == .stream_direct_v1 and desc.bank_generation != 0 and desc.bank_generation == desc.expectedBankGeneration() and
        desc.old_groups.count == 1 and desc.old_groups.items[0].eql(guard.outgoing) and guard.outgoing.generation != 0 and
        desc.old_plan == null and desc.replacement != null and !desc.replacement.?.eql(guard.outgoing) and !desc.paused and
        guard.segment != 0 and guard.source_incarnation == 1 and guard.mutation_epoch != 0;
}
/// The fresh window changes only the segment-local coordinate and transport
/// epoch. Every stem remains the same authored source on a distinct live ring.
fn streamPreviewSeekPreparedMatches(desc: resident_transaction.RestoreDesc, outgoing: *const music_group.Prepared, replacement: *const music_group.Prepared) bool {
    if (!streamPreviewSeekDescriptor(desc)) return false;
    const guard = desc.seek_guard.?;
    if (outgoing.segment != guard.segment or replacement.segment != guard.segment or outgoing.generation != desc.bank_generation or replacement.generation != desc.bank_generation or
        outgoing.frames != replacement.frames or outgoing.sample_rate != replacement.sample_rate or outgoing.loop == null or !std.meta.eql(outgoing.loop, replacement.loop) or
        outgoing.gain != replacement.gain or outgoing.layer_count == 0 or outgoing.layer_count > 4 or outgoing.layer_count != replacement.layer_count or
        replacement.start_cursor >= outgoing.frames or replacement.start_cursor >= outgoing.loop.?.end or replacement.start_loop_epoch != 0) return false;
    for (outgoing.layers[0..outgoing.layer_count], replacement.layers[0..replacement.layer_count]) |old, fresh| {
        const old_source = old.stream orelse return false;
        const new_source = fresh.stream orelse return false;
        if (old.gain != fresh.gain or old.asset_frame_origin != fresh.asset_frame_origin or old.asset_frames != fresh.asset_frames or
            !std.meta.eql(old.authored, fresh.authored) or old.required != fresh.required or old.initial_state != .real or fresh.initial_state != .real or
            !music_group.sameAuthoredSource(old_source.identity, new_source.identity)) return false;
        for (outgoing.layers[0..outgoing.layer_count]) |prior| if (new_source.ring == (prior.stream orelse return false).ring) return false;
    }
    return true;
}
fn streamPreviewSeekPhysicalMatches(desc: resident_transaction.RestoreDesc, outgoing: *const music_group.MusicVoiceGroup) bool {
    if (!streamPreviewSeekDescriptor(desc)) return false;
    const guard = desc.seek_guard.?;
    if (outgoing.state != .playing or outgoing.paused or outgoing.degraded or outgoing.underrun_frame != null or outgoing.optional_dropped != 0 or
        outgoing.generation != desc.bank_generation or outgoing.segment != guard.segment or outgoing.source_incarnation != guard.source_incarnation or outgoing.mutation_epoch != guard.mutation_epoch or
        outgoing.loop == null or outgoing.cursor >= outgoing.frames or outgoing.cursor >= outgoing.loop.?.end or outgoing.layer_count == 0 or outgoing.layer_count > 4) return false;
    // A Playing label alone is insufficient at the last valid sample boundary.
    // Check exact next-sample availability without reading/consuming PCM, so an
    // empty/stale old source cannot be relabeled as a successful audition.
    for (outgoing.layers[0..outgoing.layer_count]) |layer| {
        const source = layer.stream() orelse return false;
        if (!source.validate()) return false;
        const read = source.ring.consumed.load(.acquire);
        const coordinate = source.ring.coordinate(read) orelse return false;
        if (coordinate.cursor != (layer.prepared.assetFrame(outgoing.cursor) catch return false) or coordinate.loop_epoch != outgoing.loop_epoch or source.ring.renderProduced() <= read) return false;
    }
    return true;
}

/// Narrow hash inspection only, absent from non-test builds.
pub const preview_seek_testing = if (@import("builtin").is_test) struct {
    pub fn descriptorHash(runtime: *ControlRuntime, slot: *const resident_transaction.Slot) [32]u8 {
        return runtime.hashResidentDescriptor(slot);
    }
} else struct {};

/// Reload is a single cross-generation install, never capture or suffix work.
fn streamReloadDescriptor(desc: resident_transaction.RestoreDesc) bool {
    return desc.profile == .stream_reload_v1 and desc.bank_generation != 0 and desc.expectedBankGeneration() != 0 and
        desc.bank_generation != desc.expectedBankGeneration() and desc.old_groups.count == 1 and desc.old_plan == null and
        desc.replacement != null and !desc.paused and desc.expected_outgoing_segment != null and desc.expected_outgoing_segment.? != 0 and
        desc.expected_outgoing_cursor != null and desc.expected_outgoing_loop_epoch != null;
}
/// Candidate and outgoing groups share one coordinate system. Source media and
/// mapped segment/layer/sound IDs may differ; steady gains and origins may not.
fn streamReloadCoordinates(desc: resident_transaction.RestoreDesc, outgoing: *const music_group.Prepared, replacement: *const music_group.Prepared) bool {
    if (!streamReloadDescriptor(desc) or outgoing.segment != desc.expected_outgoing_segment.? or
        outgoing.frames != replacement.frames or outgoing.sample_rate != replacement.sample_rate or
        outgoing.loop == null or !std.meta.eql(outgoing.loop, replacement.loop) or outgoing.gain != replacement.gain or
        outgoing.layer_count != 4 or replacement.layer_count != 4 or
        replacement.start_cursor != desc.expected_outgoing_cursor.? or replacement.start_loop_epoch != desc.expected_outgoing_loop_epoch.?) return false;
    if (replacement.start_cursor >= outgoing.frames or replacement.start_cursor >= outgoing.loop.?.end) return false;
    for (outgoing.layers[0..4], replacement.layers[0..4]) |old, fresh| {
        if (old.gain != fresh.gain or old.asset_frame_origin != fresh.asset_frame_origin or old.asset_frames != fresh.asset_frames) return false;
        const source = fresh.stream orelse return false;
        for (outgoing.layers[0..4]) |prior| {
            // A playing reload source cannot already be a recycled slot. New
            // incarnation numbers do not authorize reuse of its consuming ring.
            if (source.ring == (prior.stream orelse return false).ring) return false;
        }
    }
    return true;
}
fn streamReloadPhysicalMatches(desc: resident_transaction.RestoreDesc, outgoing: *const music_group.MusicVoiceGroup) bool {
    return streamReloadDescriptor(desc) and outgoing.generation == desc.expectedBankGeneration() and
        outgoing.segment == desc.expected_outgoing_segment.? and outgoing.cursor == desc.expected_outgoing_cursor.? and
        outgoing.loop_epoch == desc.expected_outgoing_loop_epoch.? and !outgoing.paused and
        outgoing.source_incarnation == 1 and outgoing.mutation_epoch == 1;
}
/// Profile checks use only immutable preparation metadata. Stream reload is
/// exactly four real looping stems and carries no entry envelope or fallback.
fn snapshotPreparedProfile(prepared: *const music_group.Prepared, profile: resident_transaction.Profile) bool {
    if (prepared.hasVirtual() or prepared.emergency != null) return false;
    if (profile == .resident_v1) return !prepared.hasStreams();
    if (prepared.layer_count == 0 or ((profile == .stream_fill_v1 or profile == .stream_reload_v1) and prepared.ramp_frames != 0)) return false;
    if (profile == .stream_reload_v1 and (prepared.layer_count != 4 or prepared.voice_count != 4 or prepared.loop == null)) return false;
    for (prepared.layers[0..prepared.layer_count]) |layer| {
        if (layer.stream == null or layer.initial_state != .real) return false;
    }
    return true;
}
/// A retired physical slot may be recycled with a fresh generation. Pointer
/// equality alone would incorrectly reject restore after settled stream pause.
fn sameSnapshotWindow(a: streaming.Source, b: streaming.Source) bool {
    return a.ring == b.ring and a.identity.stream_generation == b.identity.stream_generation;
}
/// Fresh windows begin at the saved musical coordinate under the replacement
/// epoch. Neither decoder state nor an already-consumed ring can be restored.
/// Readiness itself remains the ordinary final scheduledStart preflight.
fn freshSnapshotSource(prepared: *const music_group.Prepared, layer: *const music_group.PreparedLayer, source: streaming.Source, epoch: u64) bool {
    return source.validate() and source.identity.asset_generation == prepared.generation and
        source.identity.transport_epoch == epoch and source.identity.start_cursor == (layer.assetFrame(prepared.start_cursor) catch return false) and
        source.identity.start_loop_epoch == prepared.start_loop_epoch and std.meta.eql(source.identity.loop, layer.assetLoop(prepared.loop) catch return false) and
        source.ring.consumed.load(.acquire) == 0;
}

fn hashSourceIdentity(h: anytype, id: streaming.SourceIdentity) void {
    for ([_]u64{ id.asset, id.asset_generation, id.transport_epoch, id.stream_generation, id.profile_id, id.start_cursor, id.start_loop_epoch, id.frame_count, id.channels, id.minimum_playable_frames, @intFromBool(id.loop != null) }) |value| hashInt(h, value);
    h.update(&id.profile_hash);
    h.update(&id.encoded_hash);
    if (id.loop) |loop| {
        hashInt(h, loop.start);
        hashInt(h, loop.end);
    }
}
fn hashGraphSourceBinding(handle: GroupHandle, prepared: *const music_group.Prepared, ordinal: u16, source: ?streaming.Source, binding: graph_clock_runtime.SourceBinding) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("GRAPH-SOURCE-BINDING-V1");
    const layer = &prepared.layers[ordinal];
    for ([_]u64{ handle.index, handle.generation, prepared.generation, prepared.segment, ordinal, layer.authored.layer_id, layer.asset_frame_origin, layer.asset_frames, prepared.frames }) |value| hashInt(&h, value);
    hashInt(&h, @intFromBool(source != null));
    if (source) |value| hashSourceIdentity(&h, value.identity);
    hashInt(&h, @intFromBool(binding.handle != null));
    if (binding.handle) |value| {
        hashInt(&h, value.index);
        hashInt(&h, value.generation);
    }
    return h.finalResult();
}
fn hashSourceContinuity(desc: *const music_group.SourceContinuity, group_hash: [32]u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("SOURCE-CONTINUITY-DESCRIPTOR-V1");
    if (desc.source_incarnation != 1) {
        h.update("SOURCE-INCARNATION-V1");
        hashInt(&h, desc.source_incarnation);
    }
    h.update(&group_hash);
    for ([_]u64{ desc.group.index, desc.group.generation, desc.bank_generation, desc.old_transport_epoch, desc.new_transport_epoch, desc.mutation_epoch, @intFromBool(desc.paused), desc.cursor, desc.loop_epoch, desc.layer_count }) |value| hashInt(&h, value);
    for (0..desc.layer_count) |i| {
        hashInt(&h, @intFromBool(desc.old_sources[i] != null));
        if (desc.old_sources[i]) |id| hashSourceIdentity(&h, id);
        if (desc.old_handles[i]) |handle| {
            hashInt(&h, handle.index);
            hashInt(&h, handle.generation);
        }
        hashInt(&h, @intFromBool(desc.sources[i] != null));
        if (desc.sources[i]) |source| hashSourceIdentity(&h, source.identity);
        if (desc.handles[i]) |handle| {
            hashInt(&h, handle.index);
            hashInt(&h, handle.generation);
        }
    }
    return h.finalResult();
}

fn hashPreparedGroup(slot: *const PreparedGroupSlot) [32]u8 {
    if (!slot.prepared.hasSourceWindows() and !slot.prepared.hasStreams() and slot.emergency == null and std.mem.allEqual(u8, &slot.voice_profile_hash, 0) and slot.prepared.start_loop_epoch == 0) return hashResidentGroupLegacy(slot);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    hashPreparedMusic(&h, &slot.prepared);
    if (!std.mem.allEqual(u8, &slot.voice_profile_hash, 0) or slot.prepared.start_loop_epoch != 0) {
        h.update("VOICE-GROUP-V1");
        h.update(&slot.voice_profile_hash);
        hashInt(&h, slot.prepared.start_loop_epoch);
        for (slot.prepared.layers[0..slot.prepared.layer_count]) |layer| {
            hashInt(&h, layer.authored.layer_id);
            hashInt(&h, @intFromEnum(layer.authored.protection));
            hashInt(&h, layer.authored.priority);
            hashInt(&h, layer.authored.drop_rank);
            hashInt(&h, @intFromEnum(layer.initial_state));
            hashFloat(&h, layer.audibility_envelope);
        }
    }
    for (slot.plays[0..slot.prepared.voice_count]) |play| {
        hashInt(&h, play.instance.index);
        hashInt(&h, play.instance.generation);
        hashInt(&h, play.reservation);
    }
    hashInt(&h, @intFromBool(slot.emergency != null));
    if (slot.emergency) |*emergency| hashPreparedMusic(&h, emergency);
    var result: [32]u8 = undefined;
    h.final(&result);
    return result;
}
fn hashPreparedMusic(h: anytype, p: *const music_group.Prepared) void {
    // Default full-asset descriptors keep their exact historical digest. The
    // window domain binds original storage coordinates without slicing owners.
    if (p.hasSourceWindows()) {
        h.update("ASSET-WINDOW-V1");
        for (p.layers[0..p.layer_count]) |layer| {
            hashInt(h, layer.asset_frame_origin);
            hashInt(h, layer.asset_frames);
        }
    }
    for ([_]u64{ p.segment, p.generation, p.layer_count, p.voice_count, p.frames, p.start_cursor, p.ramp_frames, p.matrix.id, p.matrix.input.count, p.matrix.input.mask, p.matrix.output.count, p.matrix.output.mask, @intFromBool(p.loop != null) }) |value| hashInt(h, value);
    hashFloat(h, p.gain);
    if (p.loop) |loop| {
        hashInt(h, loop.start);
        hashInt(h, loop.end);
    }
    for (p.matrix.coefficients) |row| for (row) |value| hashFloat(h, value);
    for (p.layers[0..p.layer_count]) |layer| {
        hashFloat(h, layer.gain);
        hashInt(h, p.sample_rate);
        hashInt(h, @intFromBool(layer.required));
        hashInt(h, @intFromEnum(layer.optional_policy));
        hashInt(h, @intFromBool(layer.stream != null));
        if (layer.stream) |source| {
            const id = source.identity;
            for ([_]u64{ id.asset, id.asset_generation, id.transport_epoch, id.stream_generation, id.profile_id, id.start_cursor, id.start_loop_epoch, id.frame_count, id.channels, id.minimum_playable_frames, @intFromBool(id.loop != null) }) |value| hashInt(h, value);
            h.update(&id.profile_hash);
            h.update(&id.encoded_hash);
            if (id.loop) |loop| {
                hashInt(h, loop.start);
                hashInt(h, loop.end);
            }
        } else {
            hashInt(h, layer.samples.len);
            for (layer.samples) |sample| hashFloat(h, sample);
        }
    }
}

fn hashResidentGroupLegacy(slot: *const PreparedGroupSlot) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const p = &slot.prepared;
    for ([_]u64{ p.segment, p.generation, p.layer_count, p.frames, p.start_cursor, p.ramp_frames, p.matrix.id, p.matrix.input.count, p.matrix.input.mask, p.matrix.output.count, p.matrix.output.mask, @intFromBool(p.loop != null) }) |value| hashInt(&h, value);
    hashFloat(&h, p.gain);
    if (p.loop) |loop| {
        hashInt(&h, loop.start);
        hashInt(&h, loop.end);
    }
    for (p.matrix.coefficients) |row| for (row) |value| hashFloat(&h, value);
    for (slot.plays[0..p.layer_count], p.layers[0..p.layer_count]) |play, layer| {
        hashInt(&h, play.instance.index);
        hashInt(&h, play.instance.generation);
        hashInt(&h, play.reservation);
        hashFloat(&h, layer.gain);
        hashInt(&h, p.sample_rate);
        hashInt(&h, layer.samples.len);
        for (layer.samples) |sample| hashFloat(&h, sample);
    }
    var result: [32]u8 = undefined;
    h.final(&result);
    return result;
}

fn transactionCommand(payload: ScheduledPayload) ?resident_transaction.Command {
    return switch (payload) {
        .resident_capture, .resident_restore => |value| value,
        else => null,
    };
}
fn payloadGroup(payload: ScheduledPayload) ?GroupHandle {
    return switch (payload) {
        .group_start => |v| v.group,
        .group_seek => |v| v.group,
        .group_loop => |v| v.group,
        .group_gain => |v| v.group,
        .group_stop => |v| v.group,
        .group_layer => |v| v.group,
        .group_pause => |v| v.group,
        .group_layer_gain => |v| v.group,
        .group_bus_route => |v| v.group,
        .graph_targets => |v| v.group,
        .group_layer_automation => |v| v.group,
        .group_layer_automation_stop => |v| v.group,
        .graph_source_program, .graph_source_program_stop => |v| v.group,
        else => null,
    };
}

fn groupStopped(commands: []const ScheduledCommand, instance: InstanceHandle) bool {
    for (commands) |command| if (command.payload == .stop and command.payload.stop.instance.eql(instance)) return true;
    return false;
}
fn groupStarts(commands: []const ScheduledCommand, instance: InstanceHandle) bool {
    for (commands) |command| if (command.payload == .play and command.payload.play.instance.eql(instance)) return true;
    return false;
}
fn hashInt(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}
fn hashFloat(hash: anytype, value: f32) void {
    hashInt(hash, @as(u64, @as(u32, @bitCast(value))));
}
fn encodeCommands(h: anytype, commands: []const ScheduledCommand) void {
    hashInt(h, commands.len);
    for (commands) |command| {
        const id = command.identity;
        const token = id.token;
        for ([_]u64{ id.command_id, token.context.value(), token.transport_epoch.value(), token.plan_id.value(), token.plan_epoch.value(), token.phase_id.value(), token.asset_generation.value(), id.execute_frame, id.group_id, id.phase_order, command.sequence, command.ordinal, @intFromEnum(command.payload) }) |value| hashInt(h, value);
        switch (command.payload) {
            .resident_capture, .resident_restore => |v| {
                hashInt(h, v.transaction.generation);
                h.update(&v.content_hash);
            },
            .graph_install, .graph_retire => |v| {
                hashInt(h, v.graph.index);
                hashInt(h, v.graph.generation);
                h.update(&v.content_hash);
            },
            .graph_targets => |v| {
                hashInt(h, v.batch.index);
                hashInt(h, v.batch.generation);
                h.update(&v.content_hash);
                if (v.group) |group| {
                    hashInt(h, 0x4c41594552475250);
                    hashInt(h, group.index);
                    hashInt(h, group.generation);
                }
            },
            .group_bus_route => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashInt(h, v.layer);
                hashInt(h, v.route.index);
                hashInt(h, v.route.generation);
                hashInt(h, v.ramp_frames);
                h.update(&v.content_hash);
                if (v.source_incarnation != 1) {
                    h.update("GROUP-SOURCE-INCARNATION-V1");
                    hashInt(h, v.source_incarnation);
                }
            },
            .play => |v| {
                hashInt(h, v.instance.index);
                hashInt(h, v.instance.generation);
                hashInt(h, v.reservation);
                inline for (.{ v.params.gain, v.params.pitch, v.params.priority, v.params.pan, v.params.lowpass_hz, v.params.reverb_send }) |x| hashFloat(h, x);
                hashInt(h, @intFromEnum(v.params.bus));
                hashInt(h, @intFromBool(v.params.loop));
                hashInt(h, v.owner.samples.len);
                for (v.owner.samples) |sample| hashFloat(h, sample);
            },
            .update => |v| {
                hashInt(h, v.instance.index);
                hashInt(h, v.instance.generation);
                hashInt(h, v.reservation);
                hashInt(h, v.ramp_frames);
                hashInt(h, @intFromBool(v.incarnation != null));
                if (v.incarnation) |order| hashInt(h, order);
                inline for (.{ v.params.gain, v.params.pan, v.params.lowpass_hz, v.params.pitch_ratio, v.params.reverb_send }) |x| {
                    hashInt(h, @intFromBool(x != null));
                    if (x) |f| hashFloat(h, f);
                }
            },
            .stop => |v| {
                hashInt(h, v.instance.index);
                hashInt(h, v.instance.generation);
                hashInt(h, v.reservation);
                hashInt(h, v.fade_frames);
                hashInt(h, @intFromBool(v.incarnation != null));
                if (v.incarnation) |order| hashInt(h, order);
            },
            .bus => |v| {
                hashInt(h, @intFromEnum(v.bus));
                hashFloat(h, v.gain);
                hashInt(h, v.ramp_frames);
            },
            .group_start => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                h.update(&v.content_hash);
            },
            .group_seek => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashInt(h, v.cursor);
            },
            .group_loop => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashInt(h, @intFromBool(v.loop != null));
                if (v.loop) |loop| {
                    hashInt(h, loop.start);
                    hashInt(h, loop.end);
                }
            },
            .group_gain => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashFloat(h, v.gain);
                hashInt(h, v.ramp_frames);
            },
            .group_layer => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashInt(h, v.change.index);
                hashInt(h, v.change.generation);
                h.update(&v.content_hash);
            },
            .group_pause => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashInt(h, @intFromBool(v.paused));
                if (v.next_transport_epoch != 0) hashInt(h, v.next_transport_epoch);
                if (v.continuity) |handle| {
                    h.update("SOURCE-CONTINUITY-COMMAND-V1");
                    hashInt(h, handle.index);
                    hashInt(h, handle.generation);
                    h.update(&v.continuity_hash);
                }
            },
            .group_layer_gain => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashInt(h, v.layer);
                hashFloat(h, v.gain);
                hashInt(h, v.ramp_frames);
                if (v.source_incarnation != 1) {
                    h.update("GROUP-SOURCE-INCARNATION-V1");
                    hashInt(h, v.source_incarnation);
                }
            },
            .group_layer_automation => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashInt(h, v.program.context);
                hashInt(h, v.program.index);
                hashInt(h, v.program.generation);
                hashInt(h, @intFromBool(v.expected_previous != null));
                if (v.expected_previous) |p| {
                    hashInt(h, p.context);
                    hashInt(h, p.index);
                    hashInt(h, p.generation);
                }
                h.update(&v.content_hash);
            },
            .group_layer_automation_stop => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashInt(h, v.program.context);
                hashInt(h, v.program.index);
                hashInt(h, v.program.generation);
                hashInt(h, @intFromEnum(v.mode));
                h.update(&v.content_hash);
            },
            .graph_source_program, .graph_source_program_stop => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashInt(h, v.program.context);
                hashInt(h, v.program.index);
                hashInt(h, v.program.generation);
                h.update(&v.content_hash);
                h.update("GRAPH-SOURCE-BINDING-V1");
                h.update(&v.source_hash);
            },
            .group_stop => |v| {
                hashInt(h, v.group.index);
                hashInt(h, v.group.generation);
                hashInt(h, v.release_frames);
            },
        }
    }
    var cleanup_count: u64 = 0;
    for (commands) |command| if (command.payload == .graph_targets and command.payload.graph_targets.duck_cleanup != null) {
        cleanup_count += 1;
    };
    // Preserve every legacy byte when absent. The optional extension is a
    // versioned, counted trailer, never an unframed suffix between commands.
    if (cleanup_count != 0) {
        h.update("DUCK-CLEANUP-AUTHORIZATION-V1");
        hashInt(h, cleanup_count);
        for (commands, 0..) |command, index| {
            if (command.payload != .graph_targets) continue;
            if (command.payload.graph_targets.duck_cleanup) |authorization| {
                for ([_]u64{ index, authorization.handle.context, authorization.handle.index, authorization.handle.generation, authorization.transport_epoch, authorization.device_epoch, authorization.accepted.accepted_control_frame, authorization.accepted.control_tick, authorization.accepted.input_order }) |value| hashInt(h, value);
            }
        }
    }
    var crossfade_stop_count: u64 = 0;
    for (commands) |command| if (command.payload == .group_stop and command.payload.group_stop.allow_crossfade_source_stop) {
        crossfade_stop_count += 1;
    };
    if (crossfade_stop_count != 0) {
        h.update("CROSSFADE-SOURCE-STOP-V1");
        hashInt(h, crossfade_stop_count);
        for (commands, 0..) |command, index| if (command.payload == .group_stop and command.payload.group_stop.allow_crossfade_source_stop) {
            hashInt(h, index);
        };
    }
    var curve_count: u64 = 0;
    for (commands) |command| if (scheduledGainCurve(command.payload) != .linear) {
        curve_count += 1;
    };
    // Command-only curves never change Prepared or any legacy linear byte.
    // Count and index every nonlinear command so neither position nor direction
    // can alias another schedule, including fail-closed unknown enum values.
    if (curve_count != 0) {
        h.update("GROUP-GAIN-CURVES-V1");
        hashInt(h, curve_count);
        for (commands, 0..) |command, index| {
            const curve = scheduledGainCurve(command.payload);
            if (curve == .linear) continue;
            hashInt(h, index);
            hashInt(h, @intFromEnum(curve));
        }
    }
}

fn scheduledGainCurve(payload: ScheduledPayload) music_group.GainCurve {
    return switch (payload) {
        .group_start => |value| value.start_curve,
        .group_stop => |value| value.release_curve,
        else => .linear,
    };
}

fn validStartCurve(curve: music_group.GainCurve, frames: u32) bool {
    return switch (curve) {
        .linear => true,
        .equal_power_in => frames != 0,
        else => false,
    };
}

fn validReleaseCurve(curve: music_group.GainCurve, frames: u32) bool {
    return switch (curve) {
        .linear => true,
        .equal_power_out => frames != 0,
        else => false,
    };
}

/// The permission is meaningful only inside this exact atomic stop pair.
/// Scheduler admission separately establishes sorted/contiguous group bounds.
fn validCrossfadeStopPair(commands: []const ScheduledCommand, source: ScheduledCommand) bool {
    const source_stop = source.payload.group_stop;
    var members: usize = 0;
    var permissions: usize = 0;
    var target: ?GroupHandle = null;
    for (commands) |command| {
        if (command.identity.group_id != source.identity.group_id) continue;
        if (command.identity.execute_frame != source.identity.execute_frame or command.identity.phase_order != source.identity.phase_order or !std.meta.eql(command.identity.token, source.identity.token) or command.payload != .group_stop) return false;
        members += 1;
        const stop = command.payload.group_stop;
        if (stop.release_curve != .linear) return false;
        if (stop.allow_crossfade_source_stop) {
            permissions += 1;
        } else target = stop.group;
    }
    return members == 2 and permissions == 1 and target != null and !source_stop.group.eql(target.?);
}

fn hashScheduledBlock(start: u64, end: u64, commands: []const ScheduledCommand) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    hashInt(&h, start);
    hashInt(&h, end);
    encodeCommands(&h, commands);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return digest;
}
const CanonicalBuffer = struct {
    bytes: []u8,
    used: usize = 0,
    overflow: bool = false,
    fn update(self: *@This(), bytes: []const u8) void {
        if (self.overflow or bytes.len > self.bytes.len - self.used) {
            self.overflow = true;
            return;
        }
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }
};
/// Control-only canonical bytes consumed by Replay Driver. These are the exact
/// bytes hashed by preparation, excluding native padding and pointer values.
pub fn encodeScheduledBlock(block: *const Scheduler.Block, buffer: []u8) RuntimeError![]const u8 {
    var sink: CanonicalBuffer = .{ .bytes = buffer };
    hashInt(&sink, block.start_frame);
    hashInt(&sink, block.end_frame);
    encodeCommands(&sink, block.commands[0..block.count]);
    if (sink.overflow) return error.InvalidArgument;
    return buffer[0..sink.used];
}
fn encodeIntent(sink: anytype, token: music.PhaseToken, value: scheduler.Invalidation, sequence: u64) void {
    for ([_]u64{ token.context.value(), token.plan_id.value(), token.plan_epoch.value(), token.transport_epoch.value(), token.asset_generation.value(), value.requested_frame, value.next_transport_epoch, value.next_asset_generation, @intFromBool(value.emergency_stop_music), sequence }) |v| hashInt(sink, v);
}
/// Immutable logical target and exact queue ticket, never a slot address/index.
pub fn encodeInvalidationBatch(intent: *const Scheduler.Intent, buffer: []u8) RuntimeError![]const u8 {
    var sink: CanonicalBuffer = .{ .bytes = buffer };
    encodeIntent(&sink, intent.token, intent.value, intent.sequence);
    if (sink.overflow) return error.InvalidArgument;
    return buffer[0..sink.used];
}

fn layerGraphSource(group: GroupHandle, layer: u16) bus_runtime.LayerSource {
    return layerGraphSourceAt(group, layer, 1);
}
fn layerGraphSourceAt(group: GroupHandle, layer: u16, source_incarnation: u64) bus_runtime.LayerSource {
    return .{ .group_index = group.index, .group_generation = group.generation, .layer = layer, .source_incarnation = source_incarnation };
}
