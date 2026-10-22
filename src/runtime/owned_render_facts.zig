//! Private fixed-Host Render facts. Callbacks are passive, bounded, and owned
//! by this actual Render producer. Every pointer is callback-scoped; consumers
//! copy before returning. No old direct-only Bridge/session is enabled here.
const std = @import("std");
const mixer = @import("../mixer/mixer.zig");
const group = mixer.music_group;
const stream = @import("sme-streaming");
const scheduler = @import("sme-scheduler");
const witness = @import("render_causal_witness.zig");
pub const stream_observation = stream.stream.render_observation;
pub const scheduler_observation = scheduler.render_observation;

pub const Position = struct { gate: u64, frame: u64, order: u32 };
pub const InvalidationPosition = struct { at: Position, phase: scheduler.InvalidationPhase, iteration: u64 };
pub const Event = union(enum) {
    call_begin: struct { sequence: u64, observable: bool, requested_frames: u32, channels: u16, valid: bool, frame: ?u64 },
    /// renderOwned returns void. err is its reached argument/range diagnostic
    /// cause, not a returned error union; those branches cannot qualify success.
    call_end: struct { sequence: u64, frame: ?u64, completed: bool, err: ?anyerror },
    gate_begin: struct { at: Position, mode: witness.StreamMode },
    gate_end: Position,
    frontier: struct { at: Position, value: stream_observation.Frontier },
    stream_attempt: struct { at: Position, value: stream_observation.Attempt, err: ?anyerror },
    scan_chunk: scheduler_observation.ScanChunk,
    /// This is the original helper's aggregate reached-true result, NOT a
    /// substitute for every individual shutdown acquire inside the helper.
    shutdown_pass: struct { at: InvalidationPosition, any_shutdown: bool },
    invalidation_poll: struct { at: InvalidationPosition, value: scheduler_observation.InvalidationPoll },
    invalidation_result: struct { at: InvalidationPosition, value: scheduler_observation.InvalidationResult },
    resource: witness.ResourceEvent,
};

pub const Gains = struct {
    current: u32,
    target: u32,
    step: u32,
    pub fn from(current: f32, target: f32, step: f32) Gains {
        return .{ .current = @bitCast(current), .target = @bitCast(target), .step = @bitCast(step) };
    }
};
pub const RingBegin = struct {
    generation: u64,
    channels: u8,
    capacity_frames: u32,
    start_cursor: u64,
    start_loop_epoch: u64,
    frames: u64,
    loop: ?stream.Loop,
    gated: bool,
    /// Boundary copies of values written only by this Render producer. No
    /// produced/stopped/reference load is performed to construct these facts.
    consumed: u64,
    visible_produced: u64,
};
pub const LayerBegin = struct {
    ordinal: u16,
    source: ?stream.SourceIdentity,
    ring: ?RingBegin,
    asset_frame_origin: u64,
    asset_frames: u64,
    required: bool,
    optional_policy: group.OptionalPolicy,
    initial_state: @FieldType(group.PreparedLayer, "initial_state"),
    state: @FieldType(group.LayerRuntime, "state"),
    source_override: bool,
    continuity_source: bool,
    automation: bool,
    release_target: @FieldType(group.LayerRuntime, "release_target"),
    release_remaining: u32,
    release_total: u32,
    gains: Gains,
    ramp_remaining: u32,
    last_change_frame: u64,
    sample_reads: u64,
};
pub const GroupState = struct {
    render: group.Handle,
    segment: u64,
    generation: u64,
    source_incarnation: u64,
    state: group.State,
    paused: bool,
    start_render_frame: u64,
    timeline_frames: u64,
    rendered_frames: u64,
    cursor: u64,
    loop_epoch: u64,
    frames: u64,
    loop: ?group.Loop,
    gains: Gains,
    ramp_remaining: u32,
    ramp_total: u32,
    curve: group.GainCurve,
    ramp_amplitude: u32,
    optional_dropped: u16,
    degraded: bool,
    layer_count: u16,
    mutation_epoch: u64,
    virtualized: u64,
    realized: u64,
    dropped: u64,
    stolen: u64,
    underrun_frame: ?u64,
    underrun_cursor: u64,
    underrun_loop_epoch: u64,
    failed_layer: u16,
    terminal_published: bool,
    terminal_reason: group.TerminalReason,
    last_sample_frame: ?u64,
};
pub const GroupBegin = struct {
    control: ?group.Handle,
    context: u64,
    transport_epoch: u64,
    sequence: u64,
    state: GroupState,
    prepared_segment: u64,
    prepared_generation: u64,
    sample_rate: u32,
    input_layout: @import("sme-channels").ChannelLayout,
    voice_count: u16,
    emergency_real_count: u16,
    policy_managed: bool,
    emergency: bool,
    /// Absent for a reached non-four-layer shape, which cannot qualify this
    /// scope. The actual layer_count above is never truncated to four.
    layers: ?[4]LayerBegin,
};
pub const SpanBegin = struct {
    at: Position,
    end_frame: u64,
    channels: u16,
    active_groups: u16,
    individual_voices: u16,
    graph: bool,
    graph_binding: bool,
    graph_programs: bool,
    master_gains: Gains,
    music_gain: u32,
    /// The first actual active group in the Mixer's own traversal order.
    /// More than one actual group is retained as active_groups>1 and rejected.
    selected: ?GroupBegin,
};
pub const LayerEnd = struct {
    state: @FieldType(group.LayerRuntime, "state"),
    gains: Gains,
    ramp_remaining: u32,
    release_remaining: u32,
    sample_reads: u64,
    consumed: ?u64,
};
pub const SpanEnd = struct {
    at: Position,
    end_frame: u64,
    selected: ?GroupState,
    /// Same begin-selected layers, only while the actual source incarnation
    /// and layer count still match. A mutation is explicit, never relabeled.
    layers: ?[4]LayerEnd,
};
pub const Hook = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, *const Event) void,
    reserve_span_begin: *const fn (*anyopaque) ?*SpanBegin,
    finish_span_begin: *const fn (*anyopaque, *const SpanBegin) void,
    reserve_span_end: *const fn (*anyopaque) ?*SpanEnd,
    finish_span_end: *const fn (*anyopaque, *const SpanEnd) void,
    pub fn event(self: Hook, value: Event) void {
        self.emit(self.context, &value);
    }
};

/// Exactly one callback-local scratch chunk, never a second scheduler scan.
pub const Scan = struct {
    hook: Hook,
    chunk: scheduler_observation.ScanChunk = .{},
    pub fn sink(self: *Scan) scheduler_observation.Sink {
        return .{ .context = self, .begin_chunk = begin, .end_chunk = end };
    }
    fn begin(raw: *anyopaque, _: u16, _: u32) ?*scheduler_observation.ScanChunk {
        const self: *Scan = @ptrCast(@alignCast(raw));
        return &self.chunk;
    }
    fn end(raw: *anyopaque, value: *const scheduler_observation.ScanChunk) bool {
        const self: *Scan = @ptrCast(@alignCast(raw));
        self.hook.event(.{ .scan_chunk = value.* });
        return true;
    }
};

/// Only callback-local pointers protected by the real group Render pins. This
/// is never sent to a recorder or retained beyond the immediate DSP call.
pub const Selection = struct {
    selected: ?*group.MusicVoiceGroup = null,
    source_incarnation: u64 = 0,
    rings: [4]?*stream.Ring = @splat(null),
};
fn state(value: *const group.MusicVoiceGroup) GroupState {
    return .{
        .render = value.handle,
        .segment = value.segment,
        .generation = value.generation,
        .source_incarnation = value.source_incarnation,
        .state = value.state,
        .paused = value.paused,
        .start_render_frame = value.start_render_frame,
        .timeline_frames = value.timeline_frames,
        .rendered_frames = value.rendered_frames,
        .cursor = value.cursor,
        .loop_epoch = value.loop_epoch,
        .frames = value.frames,
        .loop = value.loop,
        .gains = Gains.from(value.gain_current, value.gain_target, value.gain_step),
        .ramp_remaining = value.ramp_remaining,
        .ramp_total = value.ramp_total,
        .curve = value.gain_curve,
        .ramp_amplitude = @bitCast(value.ramp_amplitude),
        .optional_dropped = value.optional_dropped,
        .degraded = value.degraded,
        .layer_count = value.layer_count,
        .mutation_epoch = value.mutation_epoch,
        .virtualized = value.virtualized,
        .realized = value.realized,
        .dropped = value.dropped,
        .stolen = value.stolen,
        .underrun_frame = value.underrun_frame,
        .underrun_cursor = value.underrun_cursor,
        .underrun_loop_epoch = value.underrun_loop_epoch,
        .failed_layer = value.failed_layer,
        .terminal_published = value.terminal.published,
        .terminal_reason = value.terminal.reason,
        .last_sample_frame = value.terminal.last_sample_frame,
    };
}
pub fn beginSpan(hook: Hook, mix: *mixer.Mixer, bindings: anytype, at: Position, end_frame: u64, channels: u16) Selection {
    const output = hook.reserve_span_begin(hook.context) orelse return .{};
    output.* = .{ .at = at, .end_frame = end_frame, .channels = channels, .active_groups = 0, .individual_voices = 0, .graph = mix.graph != null, .graph_binding = mix.graph_binding != null, .graph_programs = false, .master_gains = Gains.from(mix.master_gain_current, mix.master_gain_target, mix.master_gain_step), .music_gain = @bitCast(mix.music_gain), .selected = null };
    var selection: Selection = .{};
    for (&mix.groups) |*value| if (value.state == .playing or value.state == .releasing) {
        output.active_groups += 1;
        if (selection.selected == null) selection.selected = value;
    };
    for (&mix.voices) |*voice| if (voice.group == null and (voice.state == .starting or voice.state == .real or voice.state == .releasing)) {
        output.individual_voices += 1;
    };
    for (mix.graph_programs) |program| if (program != null) {
        output.graph_programs = true;
    };
    if (selection.selected) |value| {
        selection.source_incarnation = value.source_incarnation;
        const prepared = value.prepared;
        output.selected = .{ .control = null, .context = 0, .transport_epoch = 0, .sequence = 0, .state = state(value), .prepared_segment = prepared.segment, .prepared_generation = prepared.generation, .sample_rate = prepared.sample_rate, .input_layout = prepared.matrix.input, .voice_count = prepared.voice_count, .emergency_real_count = prepared.emergency_real_count, .policy_managed = prepared.policy_managed, .emergency = prepared.emergency != null, .layers = null };
        for (bindings) |maybe| if (maybe) |binding| if (binding.render.eql(value.handle)) {
            output.selected.?.control = binding.control;
            output.selected.?.context = binding.context;
            output.selected.?.transport_epoch = binding.transport_epoch;
            output.selected.?.sequence = binding.sequence;
            break;
        };
        if (value.layer_count == 4) {
            output.selected.?.layers = @as([4]LayerBegin, undefined);
            for (value.layers[0..4], 0..) |layer, ordinal| {
                const source = layer.stream();
                const ring = if (source) |s| s.ring else null;
                selection.rings[ordinal] = ring;
                output.selected.?.layers.?[ordinal] = .{ .ordinal = @intCast(ordinal), .source = if (source) |s| s.identity else null, .ring = if (ring) |r| .{ .generation = r.generation, .channels = r.channels, .capacity_frames = r.capacity_frames, .start_cursor = r.start_cursor, .start_loop_epoch = r.start_loop_epoch, .frames = r.frames, .loop = r.loop, .gated = r.gated, .consumed = r.consumed.load(.monotonic), .visible_produced = r.visible_produced.load(.monotonic) } else null, .asset_frame_origin = layer.prepared.asset_frame_origin, .asset_frames = layer.prepared.asset_frames, .required = layer.prepared.required, .optional_policy = layer.prepared.optional_policy, .initial_state = layer.prepared.initial_state, .state = layer.state, .source_override = layer.source_override != null, .continuity_source = layer.continuity_source != null, .automation = layer.automation != null, .release_target = layer.release_target, .release_remaining = layer.release_remaining, .release_total = layer.release_total, .gains = Gains.from(layer.gain_current, layer.gain_target, layer.gain_step), .ramp_remaining = layer.ramp_remaining, .last_change_frame = layer.last_change_frame, .sample_reads = layer.sample_reads };
            }
        }
    }
    hook.finish_span_begin(hook.context, output);
    return selection;
}
pub fn endSpan(hook: Hook, selection: Selection, at: Position, end_frame: u64) void {
    const output = hook.reserve_span_end(hook.context) orelse return;
    output.* = .{ .at = at, .end_frame = end_frame, .selected = null, .layers = null };
    if (selection.selected) |value| {
        // Do not rescan active groups: the last consumed Stop frame may have
        // finished this exact group. Runtime has not returned its pins yet.
        output.selected = state(value);
        if (value.layer_count == 4 and value.source_incarnation == selection.source_incarnation) {
            output.layers = @as([4]LayerEnd, undefined);
            for (value.layers[0..4], 0..) |layer, ordinal| output.layers.?[ordinal] = .{
                .state = layer.state,
                .gains = Gains.from(layer.gain_current, layer.gain_target, layer.gain_step),
                .ramp_remaining = layer.ramp_remaining,
                .release_remaining = layer.release_remaining,
                .sample_reads = layer.sample_reads,
                .consumed = if (selection.rings[ordinal]) |ring| ring.consumed.load(.monotonic) else null,
            };
        }
    }
    hook.finish_span_end(hook.context, output);
}

/// Maximum canonical scalar payload under one-byte booleans, exact-width enums,
/// one-byte optional presence, exact-width integers and fixed-order fields.
/// No native padding, pointer, usize, sample buffer or error ordinal is allowed.
/// This is the row budget for the downstream codec, not a complete tape format.
pub fn maxCanonicalBytes(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |i| (i.bits + 7) / 8,
        .@"enum" => |e| @max(1, maxCanonicalBytes(e.tag_type)),
        .optional => |o| 1 + maxCanonicalBytes(o.child),
        .array => |a| a.len * maxCanonicalBytes(a.child),
        .@"struct" => |s| blk: {
            var bytes: usize = 0;
            for (s.fields) |f| bytes += maxCanonicalBytes(f.type);
            break :blk bytes;
        },
        else => @compileError("noncanonical Render span field"),
    };
}
pub const span_begin_max_bytes = maxCanonicalBytes(SpanBegin);
pub const span_end_max_bytes = maxCanonicalBytes(SpanEnd);
comptime {
    if (span_begin_max_bytes > 2048 or span_end_max_bytes > 512) @compileError("private Render span row budget exceeded");
}
