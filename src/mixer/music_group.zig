//! Immutable preparation and single-cursor, fixed-budget music group DSP.
const std = @import("std");
const equal_power = @import("equal_power.zig");
const capture_order = @import("sme-capture-order");
pub const layer_spans = @import("sme-layer-spans");
pub const streaming = @import("sme-streaming");
const channels = @import("sme-channels");
pub const voice = @import("sme-virtual-voice");
pub const max_layers = 16;
pub const max_groups = 64;
/// Scheduled direction is explicit. Unknown values must be rejected by both
/// Control admission and Render atomic preflight before these no-fail methods.
pub const GainCurve = enum(u8) { linear = 0, equal_power_in = 1, equal_power_out = 2, _ };
pub const Error = channels.Error || error{ MisalignedStems, VoiceBudgetExceeded, StaleAssetGeneration, InvalidState };
pub const Handle = struct {
    index: u16,
    generation: u64,
    pub fn eql(a: Handle, b: Handle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};
pub const Loop = struct { start: u64, end: u64 };
/// Exact Render outcome for one retained Control prepared-group incarnation.
/// boundary_frame is exclusive: no group sample at/after that frame belongs to
/// this lifetime. last_sample_frame is the inclusive last captured sample frame,
/// if any; its amplitude can be zero, and it is not a device playback timestamp.
pub const TerminalReason = enum { natural, stopped, underrun, stolen, shutdown };
pub const Terminal = struct {
    group: Handle,
    bank_generation: u64,
    reason: TerminalReason,
    boundary_frame: u64,
    last_sample_frame: ?u64,
};
/// One Render writer, serialized Control reader. Payload is immutable after the
/// release publication until existing group/schedule/voice leases permit reset.
/// A published terminal is not permission to release any physical resource.
pub const TerminalPublicationSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Terminal) void,
};
/// Installed only on an offline replay owner; live observers never park.
pub const TerminalReplayPoint = struct {
    edge: enum { before, after },
    group: Handle,
    published: bool,
};
pub const TerminalReplayHook = struct {
    context: *anyopaque,
    checkpoint: *const fn (*anyopaque, TerminalReplayPoint) void,
};
pub const TerminalCell = struct {
    /// Borrowed actual Render lane, immutable for this retained incarnation.
    prerequisite_order: ?capture_order.Binding = null,
    causal_publication_sink: ?TerminalPublicationSink = null,
    offline_causal_replay: ?TerminalReplayHook = null,
    published: std.atomic.Value(bool) = .init(false),
    group: Handle = .{ .index = 0, .generation = 0 },
    result: Terminal = undefined,
    pub fn read(self: *const TerminalCell) ?Terminal {
        return self.readObserved(null);
    }
    /// Records the same reached publication acquire, including an empty cell.
    pub fn readObserved(self: *const TerminalCell, observed: ?*bool) ?Terminal {
        const published = self.published.load(.acquire);
        if (observed) |value| value.* = published;
        if (!published) return null;
        return self.result;
    }
    fn publish(self: *TerminalCell, bank_generation: u64, reason: TerminalReason, boundary: u64, last: ?u64) void {
        std.debug.assert(!self.published.load(.monotonic));
        self.result = .{ .group = self.group, .bank_generation = bank_generation, .reason = reason, .boundary_frame = boundary, .last_sample_frame = last };
        // Copy the immutable identity and callbacks before the release. Do not
        // dereference the cell after exposing its final publication.
        const result = self.result;
        const sink = self.causal_publication_sink;
        const replay = self.offline_causal_replay;
        // Check the copied binding against the actual immutable Control
        // identity, not the distinct Render slot. A stale/misbound observer
        // loses eligibility without changing the original terminal outcome.
        const prerequisite: ?capture_order.Binding = bound: {
            const binding = self.prerequisite_order orelse break :bound null;
            if (binding.index != result.group.index or binding.generation != result.group.generation) {
                binding.collector.invalidateBinding();
                break :bound null;
            }
            break :bound binding;
        };
        const published = true;
        if (replay) |hook| hook.checkpoint(hook.context, .{ .edge = .before, .group = result.group, .published = false });
        // Before carries the intended store value, not an invented acquire.
        if (prerequisite) |binding| binding.emitFor(.render, .group_terminal_publish, .before, @intFromBool(published));
        self.published.store(published, .release);
        if (sink) |observer| observer.emit(observer.context, result);
        if (replay) |hook| hook.checkpoint(hook.context, .{ .edge = .after, .group = result.group, .published = true });
        if (prerequisite) |binding| binding.emitFor(.render, .group_terminal_publish, .after, @intFromBool(published));
    }
};

/// One actual semantic replacement inside a retained group lifetime. The frame
/// is the first fallback capture, not a command receipt or group terminal.
/// Source incarnation is independent of seek/pause/continuity mutation epochs.
pub const SourceSwitch = struct {
    group: Handle,
    bank_generation: u64,
    original_segment: u64,
    emergency_segment: u64,
    original_source_incarnation: u64,
    source_incarnation: u64,
    frame: u64,
    cursor: u64,
    loop_epoch: u64,
    layer: u16,
    old_mutation_epoch: u64,
    new_mutation_epoch: u64,
};
/// The resident leaf permits exactly one replacement. Render publishes only
/// after old per-source automation/routes have detached. Control acquires a
/// copy; publication never permits physical lease release by itself.
pub const SourceSwitchCell = struct {
    published: std.atomic.Value(bool) = .init(false),
    group: Handle = .{ .index = 0, .generation = 0 },
    result: SourceSwitch = undefined,
    pub fn read(self: *const SourceSwitchCell) ?SourceSwitch {
        return self.readObserved(null);
    }
    /// Records the same reached publication acquire, including an empty cell.
    pub fn readObserved(self: *const SourceSwitchCell, observed: ?*bool) ?SourceSwitch {
        const published = self.published.load(.acquire);
        if (observed) |value| value.* = published;
        if (!published) return null;
        return self.result;
    }
    fn publish(self: *SourceSwitchCell, result: SourceSwitch) void {
        std.debug.assert(!self.published.load(.monotonic));
        self.result = result;
        // Control and Render slot indices need not be equal.
        self.result.group = self.group;
        self.published.store(true, .release);
    }
};
pub const SourceSwitchWriter = struct {
    cell: ?*SourceSwitchCell = null,
    pending: ?SourceSwitch = null,
};

/// Render-owned fixed metadata, accounted separately from the Control cells.
pub const TerminalWriter = struct {
    cell: ?*TerminalCell = null,
    published: bool = false,
    reason: TerminalReason = .natural,
    last_sample_frame: ?u64 = null,
};

/// Immutable Control-owned transaction. `group` is the Control identity; the
/// Runtime resolves its distinct Render slot before calling the pure checks.
pub const SourceContinuity = struct {
    source_incarnation: u64 = 1,
    group: Handle,
    bank_generation: u64,
    old_transport_epoch: u64,
    new_transport_epoch: u64,
    mutation_epoch: u64,
    paused: bool,
    cursor: u64 = 0,
    loop_epoch: u64 = 0,
    layer_count: u16,
    old_sources: [max_layers]?streaming.SourceIdentity = @splat(null),
    old_handles: [max_layers]?streaming.Handle = @splat(null),
    sources: [max_layers]?streaming.Source = @splat(null),
    handles: [max_layers]?streaming.Handle = @splat(null),
};
pub const ContinuityCoordinate = struct { source_incarnation: u64 = 1, frame: u64, cursor: u64, loop_epoch: u64, mutation_epoch: u64, transport_epoch: u64, paused: bool };
pub fn sameAuthoredSource(a: streaming.SourceIdentity, b: streaming.SourceIdentity) bool {
    return a.asset == b.asset and a.asset_generation == b.asset_generation and a.profile_id == b.profile_id and
        std.mem.eql(u8, &a.profile_hash, &b.profile_hash) and std.mem.eql(u8, &a.encoded_hash, &b.encoded_hash) and
        a.frame_count == b.frame_count and a.channels == b.channels and a.minimum_playable_frames == b.minimum_playable_frames and std.meta.eql(a.loop, b.loop);
}

pub const OptionalPolicy = enum { drop_for_group_lifetime };
pub const Layer = struct {
    stream: ?streaming.Source = null,
    required: bool = true,
    optional_policy: OptionalPolicy = .drop_for_group_lifetime,
    samples: []const f32,
    /// Absolute normalized bank frame at group-logical frame zero. Legacy
    /// non-SME callers keep their declared sample-rate units and default zero.
    asset_frame_origin: u64 = 0,
    layout: channels.ChannelLayout,
    sample_rate: u32 = 48_000,
    generation: u64,
    gain: f32 = 1,
    authored: voice.Authored = .{},
    initial_state: voice.State = .real,
    audibility_envelope: f32 = 1,
};
pub const MusicGroupDesc = struct {
    segment: u64,
    generation: u64,
    layout: channels.ChannelLayout,
    layers: []const Layer,
    /// Shared group-logical extent; null preserves whole-asset compatibility.
    segment_frames: ?u64 = null,
    loop: ?Loop = null,
    start_cursor: u64 = 0,
    start_loop_epoch: u64 = 0,
    gain: f32 = 1,
    ramp_frames: u32 = 0,
};
pub const PreparedLayer = struct {
    samples: []const f32,
    gain: f32,
    asset_frame_origin: u64 = 0,
    /// Actual whole-asset extent, never a disguised segment/ring extent.
    asset_frames: u64 = 0,
    stream: ?streaming.Source = null,
    required: bool = true,
    optional_policy: OptionalPolicy = .drop_for_group_lifetime,
    authored: voice.Authored = .{},
    initial_state: voice.State = .real,
    audibility_envelope: f32 = 1,
    pub fn assetFrame(self: *const PreparedLayer, group_frame: u64) Error!u64 {
        const frame = std.math.add(u64, self.asset_frame_origin, group_frame) catch return error.InvalidArgument;
        if (frame >= self.asset_frames) return error.InvalidArgument;
        return frame;
    }
    pub fn assetLoop(self: *const PreparedLayer, loop: ?Loop) Error!?streaming.Loop {
        const range = loop orelse return null;
        const start = try self.assetFrame(range.start);
        const end = std.math.add(u64, self.asset_frame_origin, range.end) catch return error.InvalidArgument;
        if (start >= end or end > self.asset_frames) return error.InvalidArgument;
        return .{ .start = start, .end = end };
    }
};
pub const Prepared = struct {
    segment: u64,
    generation: u64,
    layers: [max_layers]PreparedLayer = undefined,
    sample_rate: u32,
    layer_count: u16,
    voice_count: u16,
    emergency_real_count: u16 = 0,
    policy_managed: bool = false,
    emergency: ?*const Prepared = null,
    frames: u64,
    loop: ?Loop,
    start_cursor: u64,
    start_loop_epoch: u64 = 0,
    gain: f32,
    ramp_frames: u32,
    matrix: channels.Matrix,
    pub fn prepare(desc: MusicGroupDesc, output: channels.ChannelLayout, sample_rate: u32) Error!Prepared {
        if (desc.segment == 0 or desc.generation == 0 or desc.layers.len == 0 or desc.layers.len > max_layers or sample_rate == 0 or !std.math.isFinite(desc.gain) or desc.gain < 0 or desc.gain > 4) return error.InvalidArgument;
        const matrix = try channels.Matrix.compile(desc.layout, output);
        var result: Prepared = .{ .segment = desc.segment, .generation = desc.generation, .layer_count = @intCast(desc.layers.len), .voice_count = @intCast(desc.layers.len), .sample_rate = sample_rate, .frames = 0, .loop = desc.loop, .start_cursor = desc.start_cursor, .start_loop_epoch = desc.start_loop_epoch, .gain = desc.gain, .ramp_frames = desc.ramp_frames, .matrix = matrix };
        for (desc.layers, 0..) |layer, i| {
            if (!std.math.isFinite(layer.audibility_envelope) or layer.audibility_envelope < 0 or layer.audibility_envelope > 1) return error.InvalidArgument;
            if (layer.authored.protection != .optional and !layer.required) return error.InvalidArgument;
            if (layer.initial_state != .real and layer.initial_state != .virtual) return error.InvalidArgument;
            if (layer.initial_state == .virtual and (layer.required or layer.authored.protection != .optional)) return error.InvalidArgument;
            if (layer.generation != desc.generation) return error.StaleAssetGeneration;
            try layer.layout.validate();
            if (!channels.ChannelLayout.eql(layer.layout, desc.layout) or layer.sample_rate != sample_rate) return error.MisalignedStems;
            if (!std.math.isFinite(layer.gain) or layer.gain < 0 or layer.gain > 4) return error.InvalidArgument;
            const asset_frames = if (layer.stream) |source| stream_frames: {
                if (!source.validate() or source.identity.asset_generation != desc.generation or source.identity.channels != desc.layout.count or source.identity.start_loop_epoch != desc.start_loop_epoch) return error.InvalidArgument;
                // The admitted Opus source emits fixed-rate canonical speakers;
                // caller metadata must not reinterpret that actual PCM.
                if (sample_rate != streaming.release_profile.sample_rate or !channels.ChannelLayout.eql(try channels.ChannelLayout.fromCount(source.identity.channels), desc.layout)) return error.InvalidArgument;
                break :stream_frames source.identity.frame_count;
            } else resident_frames: {
                const view = try channels.InterleavedView.init(layer.samples, layer.layout);
                for (layer.samples) |sample| if (!std.math.isFinite(sample)) return error.InvalidArgument;
                break :resident_frames view.frames;
            };
            const frames = desc.segment_frames orelse asset_frames;
            if (asset_frames == 0 or frames == 0) return error.MisalignedStems;
            const end = std.math.add(u64, layer.asset_frame_origin, frames) catch return error.InvalidArgument;
            if (end > asset_frames) return error.InvalidArgument;
            if (i == 0) result.frames = frames else if (result.frames != frames) return error.MisalignedStems;
            result.layers[i] = .{ .samples = layer.samples, .gain = layer.gain, .asset_frame_origin = layer.asset_frame_origin, .asset_frames = asset_frames, .stream = layer.stream, .required = layer.required, .optional_policy = layer.optional_policy, .initial_state = layer.initial_state, .authored = layer.authored, .audibility_envelope = layer.audibility_envelope };
            if (layer.stream) |source| {
                if (source.identity.start_cursor != try result.layers[i].assetFrame(desc.start_cursor) or !std.meta.eql(source.identity.loop, try result.layers[i].assetLoop(desc.loop))) return error.InvalidArgument;
            }
        }
        if (desc.start_cursor >= result.frames) return error.InvalidArgument;
        if (desc.loop) |loop| if (loop.start >= loop.end or loop.end > result.frames or desc.start_cursor >= loop.end) return error.InvalidArgument;
        return result;
    }
    pub fn realCount(self: *const Prepared) u16 {
        var count: u16 = self.voice_count - self.layer_count;
        for (self.layers[0..self.layer_count]) |layer| count += @intFromBool(layer.initial_state == .real);
        return @max(count, self.emergency_real_count);
    }
    pub fn hasVirtual(self: *const Prepared) bool {
        for (self.layers[0..self.layer_count]) |layer| if (layer.initial_state == .virtual) return true;
        return false;
    }
    pub fn hasStreams(self: *const Prepared) bool {
        for (self.layers[0..self.layer_count]) |layer| if (layer.stream != null) return true;
        return false;
    }
    pub fn hasSourceWindows(self: *const Prepared) bool {
        for (self.layers[0..self.layer_count]) |layer| if (layer.asset_frame_origin != 0 or layer.asset_frames != self.frames) return true;
        return false;
    }
    pub fn minimumPlayable(self: *const Prepared, cursor: u64, epoch: u64) bool {
        if (cursor >= self.frames) return false;
        for (self.layers[0..self.layer_count]) |layer| if (layer.required and layer.initial_state == .real) {
            if (layer.stream) |source| if (!source.ready(layer.assetFrame(cursor) catch return false, epoch)) return false;
        };
        return true;
    }
};
pub const LayerRuntime = struct {
    automation: ?*layer_spans.RenderCursor = null,
    /// M2-only bound for the current primitive. Legacy layerGain is unchanged.
    /// Capture F uses the actual value; subsequent f32 additions stay inside
    /// this actual-start/target interval, with the exact target still at F+N.
    automation_primitive_start: f32 = 0,
    /// Borrowed from the immutable group slot, retained until Render completion.
    prepared: *const PreparedLayer,
    /// Borrowed only from an immutable leased Control layer-change slot. The
    /// completed-frontier observation keeps that slot pinned while DSP uses it.
    source_override: ?*const streaming.Source = null,
    continuity_source: ?*const streaming.Source = null, // Borrowed from retained current transaction.
    state: voice.State,
    release_target: voice.State = .virtual,
    release_remaining: u32 = 0,
    release_total: u32 = 0,
    gain_current: f32,
    gain_target: f32,
    gain_step: f32 = 0,
    ramp_remaining: u32 = 0,
    last_change_frame: u64,
    sample_reads: u64 = 0,
    pub fn stream(self: *const LayerRuntime) ?streaming.Source {
        return if (self.source_override) |source| source.* else if (self.continuity_source) |source| source.* else self.prepared.stream;
    }
};
pub const LayerChange = struct { layer: u16, ticket: voice.Ticket, target: voice.State, source: ?streaming.Source = null, release_frames: u32 = 0 };
pub const State = enum { free, playing, releasing, finished };
pub const Snapshot = struct { paused: bool = false, handle: Handle, segment: u64, generation: u64, start_render_frame: u64, cursor: u64, loop_epoch: u64, layer_count: u16, state: State, gain: f32, degraded: bool, underrun_frame: ?u64 };
/// Captured canonical source PCM. Routing is read-only and cannot consume a
/// source, advance a gain ramp, or move the shared musical cursor.
pub const CapturedGroupFrame = struct {
    samples: [max_layers][channels.max_channels]f32 = undefined,
    source_layout: channels.ChannelLayout = channels.mono,
    valid_layers: u16 = 0,
    layer_count: u16 = 0,
    segment: u64 = 0,
    generation: u64 = 0,
    cursor: u64 = 0,
    loop_epoch: u64 = 0,
    group_gain: f32 = 0,
    layer_gains: [max_layers]f32 = undefined,
    release_gains: [max_layers]f32 = undefined,

    pub fn gain(self: *const CapturedGroupFrame, layer: usize, bus_gain: f32) f32 {
        // This order is the legacy addFrame expression, not a reassociation.
        return self.group_gain * self.layer_gains[layer] * bus_gain * self.release_gains[layer];
    }
    pub fn addLegacy(self: *const CapturedGroupFrame, matrix: *const channels.Matrix, destination: []f32, bus_gain: f32) void {
        for (0..self.layer_count) |i| {
            if (self.valid_layers & (@as(u16, 1) << @intCast(i)) == 0) continue;
            matrix.addFrame(self.samples[i][0..self.source_layout.count], destination, self.gain(i, bus_gain));
        }
    }
};
pub const MusicVoiceGroup = struct {
    handle: Handle = .{ .index = 0, .generation = 0 },
    terminal: TerminalWriter = .{},
    source_switch: SourceSwitchWriter = .{},
    source_incarnation: u64 = 1,
    /// Immutable preparation storage remains leased by Control (or Engine).
    prepared: *const Prepared = undefined,
    segment: u64 = 0,
    generation: u64 = 0,
    layer_count: u16 = 0,
    frames: u64 = 0,
    loop: ?Loop = null,
    state: State = .free,
    paused: bool = false,
    start_render_frame: u64 = 0,
    cursor: u64 = 0,
    loop_epoch: u64 = 0,
    gain_current: f32 = 0,
    gain_target: f32 = 0,
    gain_step: f32 = 0,
    ramp_remaining: u32 = 0,
    /// The curved lane is integer-progress and fixed-amplitude. Linear ramps
    /// retain their historical iterative f32 arithmetic and clear this state.
    gain_curve: GainCurve = .linear,
    ramp_total: u32 = 0,
    ramp_amplitude: f32 = 0,
    rendered_frames: u64 = 0,
    degraded: bool = false,
    underrun_frame: ?u64 = null,
    underrun_cursor: u64 = 0,
    underrun_loop_epoch: u64 = 0,
    failed_layer: u16 = 0,
    optional_dropped: u16 = 0,
    fault_reported: bool = false,
    original_segment: u64 = 0,
    accounting_voices: [max_layers]u16 = undefined,
    accounting_count: u16 = 0,
    timeline_frames: u64 = 0,
    layers: [max_layers]LayerRuntime = undefined,
    mutation_epoch: u64 = 1,
    virtualized: u64 = 0,
    realized: u64 = 0,
    dropped: u64 = 0,
    stolen: u64 = 0,
    pub fn start(handle: Handle, prepared: *const Prepared, frame: u64) MusicVoiceGroup {
        var result: MusicVoiceGroup = .{ .handle = handle, .prepared = prepared, .original_segment = prepared.segment, .segment = prepared.segment, .generation = prepared.generation, .layer_count = prepared.layer_count, .frames = prepared.frames, .loop = prepared.loop, .state = .playing, .start_render_frame = frame, .cursor = prepared.start_cursor, .loop_epoch = prepared.start_loop_epoch, .gain_current = if (prepared.ramp_frames == 0) prepared.gain else 0, .gain_target = prepared.gain };
        result.resetLayers(frame);
        if (prepared.ramp_frames != 0) result.ramp(prepared.gain, prepared.ramp_frames);
        return result;
    }
    /// Mixer calls this after the no-fail route/program handoff and before
    /// routing the first fallback sample. Direct group DSP keeps the pending
    /// fact until its owning mixer performs that boundary; no queue is involved.
    pub fn publishSourceSwitch(self: *MusicVoiceGroup) void {
        const result = self.source_switch.pending orelse return;
        if (self.source_switch.cell) |cell| cell.publish(result);
        self.source_switch.pending = null;
    }
    fn resetLayers(self: *MusicVoiceGroup, frame: u64) void {
        for (self.prepared.layers[0..self.layer_count], 0..) |*layer, i| self.layers[i] = .{ .prepared = layer, .state = layer.initial_state, .gain_current = layer.gain, .gain_target = layer.gain, .last_change_frame = frame };
    }
    /// Virtual prefetch intent is the shared musical coordinate, not a second
    /// independently advanced per-layer cursor.
    pub fn prefetchCoordinate(self: *const MusicVoiceGroup) struct { cursor: u64, loop_epoch: u64 } {
        return .{ .cursor = self.cursor, .loop_epoch = self.loop_epoch };
    }
    pub fn checkChange(self: *const MusicVoiceGroup, change: LayerChange, frame: u64, transport: u64) bool {
        const t = change.ticket;
        if (self.state != .playing or self.paused or change.layer >= self.layer_count or t.generation != self.generation or t.group != self.handle.generation or t.mutation_epoch != self.mutation_epoch or t.transport_epoch != transport or t.loop_epoch != self.loop_epoch or t.cursor != self.cursor or t.realize_frame != frame) return false;
        const layer = self.layers[change.layer];
        if (t.layer != layer.prepared.authored.layer_id or layer.state == .stolen or layer.state == .releasing or change.target == .releasing or change.target == layer.state) return false;
        if (change.target != .real and (layer.prepared.required or layer.prepared.authored.protection != .optional)) return false;
        if (change.target == .real) {
            if (layer.state != .virtual) return false;
            if (layer.prepared.stream != null) {
                const source = change.source orelse return false;
                const id = source.identity;
                if (!source.validate() or id.asset != layer.prepared.stream.?.identity.asset or id.asset_generation != t.generation or id.transport_epoch != t.transport_epoch or id.start_cursor != (layer.prepared.assetFrame(t.cursor) catch return false) or id.start_loop_epoch != t.loop_epoch or id.frame_count != layer.prepared.asset_frames or id.channels != self.prepared.matrix.input.count or !std.meta.eql(id.loop, layer.prepared.stream.?.identity.loop) or !source.ready(layer.prepared.assetFrame(self.cursor) catch return false, self.loop_epoch)) return false;
            } else if (change.source != null) return false;
        } else if (change.source != null) return false;
        return true;
    }
    pub fn changeLayer(self: *MusicVoiceGroup, change: *const LayerChange, frame: u64) void {
        const layer = &self.layers[change.layer];
        layer.last_change_frame = frame;
        if (change.target == .real) {
            if (change.source) |*source| layer.source_override = source;
            layer.state = .real;
            self.realized +|= 1;
        } else if (layer.state == .real and change.release_frames != 0) {
            layer.state = .releasing;
            layer.release_target = change.target;
            layer.release_remaining = change.release_frames;
            layer.release_total = change.release_frames;
        } else self.finishLayerChange(layer, change.target);
        if (self.state == .finished) self.publishTerminal(frame);
    }
    fn finishLayerChange(self: *MusicVoiceGroup, layer: *LayerRuntime, target: voice.State) void {
        const from = layer.state;
        layer.state = target;
        layer.source_override = null;
        if (target == .virtual) self.virtualized +|= 1 else if (from == .virtual) {
            self.dropped +|= 1;
        } else self.stolen +|= 1;
        self.finishIfAllStolen();
    }
    fn finishIfAllStolen(self: *MusicVoiceGroup) void {
        for (self.layers[0..self.layer_count]) |layer| if (layer.state != .stolen) return;
        // No logical owner remains to keep prepared descriptors leased. Stop
        // the group before Control can reclaim its last accounting voice.
        self.state = .finished;
        self.terminal.reason = .stolen;
    }
    /// Whole-group pure preflight: no source or automation changes on failure.
    pub fn checkSourceContinuity(self: *const MusicVoiceGroup, desc: *const SourceContinuity, transport_epoch: u64, required_mask: u16) bool {
        if (self.source_incarnation != desc.source_incarnation or self.handle.generation != desc.group.generation or self.generation != desc.bank_generation or self.state != .playing or
            self.paused == desc.paused or self.layer_count != desc.layer_count or self.mutation_epoch != desc.mutation_epoch or
            self.mutation_epoch == std.math.maxInt(u64) or transport_epoch != desc.old_transport_epoch or
            transport_epoch == std.math.maxInt(u64) or desc.new_transport_epoch != transport_epoch + 1) return false;
        if (!desc.paused and (self.cursor != desc.cursor or self.loop_epoch != desc.loop_epoch)) return false;
        for (self.layers[0..self.layer_count], 0..) |*layer, i| {
            if (layer.source_override != null) return false; // Semantic replacement has a separate handoff.
            const old = desc.old_sources[i];
            const actual = layer.stream();
            if ((old == null) != (actual == null)) return false;
            if (old) |identity| {
                if (desc.old_handles[i] == null or desc.old_handles[i].?.generation != identity.stream_generation or !std.meta.eql(actual.?.identity, identity)) return false;
                if (!desc.paused) {
                    const fresh = desc.sources[i] orelse return false;
                    if (desc.handles[i] == null or desc.handles[i].?.generation != fresh.identity.stream_generation or !fresh.validate() or !sameAuthoredSource(identity, fresh.identity) or
                        fresh.ring == actual.?.ring or fresh.identity.transport_epoch != desc.new_transport_epoch or
                        fresh.identity.start_cursor != (layer.prepared.assetFrame(self.cursor) catch return false) or
                        fresh.identity.start_loop_epoch != self.loop_epoch) return false;
                    if ((layer.prepared.required or required_mask & (@as(u16, 1) << @intCast(i)) != 0) and
                        (layer.state == .real or layer.state == .releasing) and !fresh.ready(layer.prepared.assetFrame(self.cursor) catch return false, self.loop_epoch)) return false;
                } else if (desc.sources[i] != null or desc.handles[i] != null) return false;
            } else if (desc.sources[i] != null or desc.handles[i] != null) return false;
        }
        return true;
    }
    /// No-fail Render commit. Old leases are released later by Control only.
    pub fn commitSourceContinuity(self: *MusicVoiceGroup, desc: *const SourceContinuity, frame: u64) ContinuityCoordinate {
        if (!desc.paused) for (desc.sources[0..desc.layer_count], 0..) |*source, i| {
            if (source.*) |*value| self.layers[i].continuity_source = value;
        };
        self.paused = desc.paused;
        self.mutation_epoch += 1;
        return .{ .source_incarnation = self.source_incarnation, .frame = frame, .cursor = self.cursor, .loop_epoch = self.loop_epoch, .mutation_epoch = self.mutation_epoch, .transport_epoch = desc.new_transport_epoch, .paused = desc.paused };
    }
    pub fn pause(self: *MusicVoiceGroup, paused: bool) Error!void {
        if (self.state != .playing or self.paused == paused or self.mutation_epoch == std.math.maxInt(u64)) return error.InvalidState;
        self.paused = paused;
        self.mutation_epoch += 1;
    }
    pub fn layerGain(self: *MusicVoiceGroup, index: u16, gain: f32, frames: u32) void {
        const layer = &self.layers[index];
        layer.gain_target = gain;
        layer.ramp_remaining = frames;
        if (frames == 0) {
            layer.gain_current = gain;
            layer.gain_step = 0;
        } else layer.gain_step = (gain - layer.gain_current) / @as(f32, @floatFromInt(frames));
    }
    /// Detach before terminal publication; no Render free or owner release.
    pub fn detachAutomation(self: *MusicVoiceGroup, program: ?layer_spans.ProgramHandle, reason: layer_spans.TerminalReason, frame: u64) void {
        for (self.layers[0..self.layer_count]) |*layer| if (layer.automation) |cursor| {
            if (program) |wanted| if (!cursor.program.eql(wanted)) continue;
            layer.automation = null;
            layer.gain_target = layer.gain_current;
            layer.gain_step = 0;
            layer.ramp_remaining = 0;
            cursor.finish(reason, frame, frame, layer.gain_current, layer.state == .real or layer.state == .releasing);
        };
    }
    pub fn attachAutomation(self: *MusicVoiceGroup, cursors: []layer_spans.RenderCursor) void {
        for (cursors) |*cursor| {
            std.debug.assert(self.layers[cursor.track.ordinal].automation == null);
            self.layers[cursor.track.ordinal].automation = cursor;
        }
    }
    pub fn snapshot(self: *const MusicVoiceGroup) Snapshot {
        return .{ .paused = self.paused, .handle = self.handle, .segment = self.segment, .generation = self.generation, .start_render_frame = self.start_render_frame, .cursor = self.cursor, .loop_epoch = self.loop_epoch, .layer_count = self.layer_count, .state = self.state, .gain = self.gain_current, .degraded = self.degraded, .underrun_frame = self.underrun_frame };
    }
    pub fn validCursor(self: *const MusicVoiceGroup, cursor: u64) bool {
        return cursor < (if (self.loop) |loop| loop.end else self.frames);
    }
    pub fn seek(self: *MusicVoiceGroup, cursor: u64) Error!void {
        if (self.state != .playing or self.prepared.hasStreams() or !self.validCursor(cursor)) return error.InvalidState;
        if (self.mutation_epoch == std.math.maxInt(u64)) return error.InvalidState;
        self.mutation_epoch += 1;
        self.cursor = cursor;
    }
    pub fn setLoop(self: *MusicVoiceGroup, loop: ?Loop) Error!void {
        if (self.state != .playing or self.prepared.hasStreams()) return error.InvalidState;
        if (loop) |range| if (range.start >= range.end or range.end > self.frames or self.cursor >= range.end) return error.InvalidArgument;
        if (self.mutation_epoch == std.math.maxInt(u64)) return error.InvalidState;
        self.mutation_epoch += 1;
        self.loop = loop;
    }
    /// Apply only immediately after ordinary start and before the first
    /// capture. Runtime has already validated the direction and positive N.
    /// Keeping selection on the command leaves Prepared and legacy starts
    /// unchanged. This initialization cannot allocate, fail, or move a cursor.
    pub fn setStartCurve(self: *MusicVoiceGroup, curve: GainCurve) void {
        switch (curve) {
            .linear => {},
            .equal_power_in => {
                std.debug.assert(self.state == .playing and self.rendered_frames == 0 and self.timeline_frames == 0);
                std.debug.assert(self.ramp_remaining != 0 and self.ramp_remaining == self.prepared.ramp_frames and self.gain_current == 0);
                self.gain_curve = curve;
                self.ramp_total = self.ramp_remaining;
                self.ramp_amplitude = self.gain_target;
                self.gain_step = 0;
            },
            else => unreachable, // Control and Render preflight reject it.
        }
    }
    pub fn ramp(self: *MusicVoiceGroup, gain: f32, frames: u32) void {
        self.gain_curve = .linear;
        self.ramp_total = 0;
        self.ramp_amplitude = 0;
        self.gain_target = gain;
        self.ramp_remaining = frames;
        if (frames == 0) {
            self.gain_current = gain;
            self.gain_step = 0;
        } else self.gain_step = (gain - self.gain_current) / @as(f32, @floatFromInt(frames));
    }
    pub fn stop(self: *MusicVoiceGroup, frames: u32) void {
        self.stopAt(frames, self.start_render_frame +| self.timeline_frames, .stopped);
    }
    pub fn stopAt(self: *MusicVoiceGroup, frames: u32, frame: u64, reason: TerminalReason) void {
        self.stopAtCurve(reason, frames, frame, .linear);
    }
    /// No-fail after atomic preflight: only linear or equal_power_out is legal.
    /// A validated nonlinear command can have effective zero duration because
    /// Runtime stops paused groups immediately. Emergency callers use stopAt's
    /// linear default from the actual current gain; Runtime caps an outgoing
    /// source's duration before this method replaces its ramp state.
    pub fn stopAtCurve(self: *MusicVoiceGroup, reason: TerminalReason, frames: u32, frame: u64, curve: GainCurve) void {
        switch (curve) {
            .linear => {},
            .equal_power_out => {},
            else => unreachable, // Control and Render preflight reject it.
        }
        if (self.state != .playing and self.state != .releasing) return;
        self.paused = false;
        self.state = .releasing;
        self.terminal.reason = reason;
        const amplitude = self.gain_current;
        self.ramp(0, frames);
        if (curve == .equal_power_out and frames != 0) {
            self.gain_curve = curve;
            self.ramp_total = frames;
            self.ramp_amplitude = amplitude;
            self.gain_step = 0;
        }
        if (frames == 0 or self.gain_current == 0) {
            self.state = .finished;
            self.publishTerminal(frame);
        }
    }
    fn publishTerminal(self: *MusicVoiceGroup, boundary: u64) void {
        if (self.terminal.published) return;
        self.terminal.published = true;
        if (self.terminal.cell) |cell| cell.publish(self.generation, self.terminal.reason, boundary, self.terminal.last_sample_frame);
    }
    fn preflight(self: *MusicVoiceGroup, scratch: *[max_layers][8]f32, required_mask: u16) bool {
        const count = self.prepared.matrix.input.count;
        for (self.layers[0..self.layer_count], 0..) |*runtime_layer, i| {
            if (runtime_layer.state == .virtual or runtime_layer.state == .stolen) continue;
            const layer = runtime_layer.prepared;
            const bit = @as(u16, 1) << @intCast(i);
            if (self.optional_dropped & bit != 0) continue;
            runtime_layer.sample_reads +|= 1;
            if (runtime_layer.stream()) |source| {
                if (!source.ring.peek(layer.asset_frame_origin + self.cursor, self.loop_epoch, scratch[i][0..count])) {
                    if (layer.required or required_mask & bit != 0) {
                        self.failed_layer = @intCast(i);
                        return false;
                    }
                    self.optional_dropped |= bit;
                    if (self.prepared.policy_managed) {
                        runtime_layer.state = .stolen;
                        runtime_layer.source_override = null;
                        self.dropped +|= 1;
                    }
                }
            } else {
                const offset: usize = @as(usize, @intCast(layer.asset_frame_origin + self.cursor)) * count;
                @memcpy(scratch[i][0..count], layer.samples[offset..][0..count]);
            }
        }
        self.finishIfAllStolen();
        return true;
    }
    /// Legacy one-destination API retains the exact arithmetic and layer order.
    pub fn addFrame(self: *MusicVoiceGroup, destination: []f32, bus_gain: f32) void {
        var captured: CapturedGroupFrame = .{};
        self.captureFrame(&captured);
        if (captured.valid_layers == 0) return;
        captured.addLegacy(&self.prepared.matrix, destination, bus_gain);
    }

    /// One shared cursor is read by every layer, then advanced exactly once.
    /// The caller may route the returned value any number of times.
    pub fn captureFrame(self: *MusicVoiceGroup, captured: *CapturedGroupFrame) void {
        self.captureFrameProtected(captured, 0);
    }

    /// Graph detector dependencies may promote optional sources for this capture.
    /// Admission must ensure protected layers are real; this is not realization.
    pub fn captureFrameProtected(self: *MusicVoiceGroup, captured: *CapturedGroupFrame, required_mask: u16) void {
        self.captureFrameProtectedAt(captured, required_mask, self.start_render_frame +| self.timeline_frames);
    }
    pub fn captureFrameProtectedAt(self: *MusicVoiceGroup, captured: *CapturedGroupFrame, required_mask: u16, physical_frame: u64) void {
        captured.valid_layers = 0;
        captured.layer_count = 0;
        if (self.state != .playing and self.state != .releasing) return;
        defer self.timeline_frames +|= 1;
        defer if (self.state == .finished) self.publishTerminal(physical_frame + @as(u64, @intFromBool(captured.layer_count != 0)));
        if (self.paused) return;
        if (self.cursor >= self.frames) {
            self.detachAutomation(null, .group_ended, physical_frame);
            self.terminal.reason = .natural;
            self.state = .finished;
            return;
        }
        // Fixed scratch and whole-required-set preflight. No layer is consumed
        // or mixed until every required source has passed at this shared cursor.
        if (!self.preflight(&captured.samples, required_mask)) {
            self.underrun_frame = self.start_render_frame +| self.timeline_frames;
            self.underrun_cursor = self.cursor;
            self.underrun_loop_epoch = self.loop_epoch;
            self.detachAutomation(null, if (self.prepared.emergency != null) .source_replaced else .group_ended, physical_frame);
            if (self.prepared.emergency) |emergency| {
                std.debug.assert(self.source_incarnation == 1 and emergency.emergency == null);
                const old_mutation_epoch = self.mutation_epoch;
                self.source_incarnation = 2;
                self.degraded = true;
                self.prepared = emergency;
                self.segment = emergency.segment;
                self.frames = emergency.frames;
                self.layer_count = emergency.layer_count;
                self.cursor = emergency.start_cursor;
                self.loop = emergency.loop;
                self.loop_epoch = 0;
                self.optional_dropped = 0;
                self.mutation_epoch +|= 1;
                self.source_switch.pending = .{ .group = self.handle, .bank_generation = self.generation, .original_segment = self.original_segment, .emergency_segment = emergency.segment, .original_source_incarnation = 1, .source_incarnation = self.source_incarnation, .frame = physical_frame, .cursor = self.underrun_cursor, .loop_epoch = self.underrun_loop_epoch, .layer = self.failed_layer, .old_mutation_epoch = old_mutation_epoch, .new_mutation_epoch = self.mutation_epoch };
                self.resetLayers(self.start_render_frame +| self.timeline_frames);
                if (self.state == .playing) self.ramp(emergency.gain, emergency.ramp_frames);
                // Emergency is a validated, fully resident leaf. No branch can
                // recurse to another fallback or retain/free resources here.
                std.debug.assert(self.preflight(&captured.samples, required_mask));
            } else {
                self.terminal.reason = .underrun;
                self.state = .finished;
                return;
            }
        }
        if (self.state == .finished) {
            self.detachAutomation(null, .group_ended, physical_frame);
            return;
        }
        for (self.layers[0..self.layer_count], 0..) |*layer, i| if (layer.automation) |cursor| {
            if (cursor.beforeCapture()) |primitive| {
                layer.automation_primitive_start = layer.gain_current;
                self.layerGain(@intCast(i), primitive.target, primitive.frames);
            }
        };
        captured.source_layout = self.prepared.matrix.input;
        captured.layer_count = self.layer_count;
        captured.segment = self.prepared.segment;
        captured.generation = self.prepared.generation;
        captured.cursor = self.cursor;
        captured.loop_epoch = self.loop_epoch;
        captured.group_gain = self.gain_current;
        for (self.layers[0..self.layer_count], 0..) |*runtime_layer, i| {
            if (runtime_layer.state == .virtual or runtime_layer.state == .stolen) continue;
            const bit = @as(u16, 1) << @intCast(i);
            if (self.optional_dropped & bit != 0) continue;
            captured.valid_layers |= bit;
            captured.layer_gains[i] = runtime_layer.gain_current;
            captured.release_gains[i] = if (runtime_layer.state == .releasing) @as(f32, @floatFromInt(runtime_layer.release_remaining)) / @as(f32, @floatFromInt(runtime_layer.release_total)) else @as(f32, 1);
            if (runtime_layer.stream()) |source| source.ring.consume();
        }
        if (captured.valid_layers != 0) self.terminal.last_sample_frame = physical_frame;
        for (self.layers[0..self.layer_count]) |*layer| {
            if (layer.automation) |cursor| {
                if (cursor.afterCapture(physical_frame, layer.gain_current, captured.valid_layers & (@as(u16, 1) << @intCast(cursor.track.ordinal)) != 0)) layer.automation = null;
            }
            if (layer.ramp_remaining != 0) {
                layer.ramp_remaining -= 1;
                if (layer.ramp_remaining == 0) layer.gain_current = layer.gain_target else {
                    layer.gain_current += layer.gain_step;
                    if (layer.automation != null) layer.gain_current = std.math.clamp(layer.gain_current, @min(layer.automation_primitive_start, layer.gain_target), @max(layer.automation_primitive_start, layer.gain_target));
                }
            }
            if (layer.state == .releasing) {
                layer.release_remaining -= 1;
                if (layer.release_remaining == 0) self.finishLayerChange(layer, layer.release_target);
            }
        }
        self.rendered_frames +|= 1;
        if (self.ramp_remaining != 0) {
            self.ramp_remaining -= 1;
            if (self.ramp_remaining == 0) self.gain_current = self.gain_target else {
                switch (self.gain_curve) {
                    .linear => self.gain_current += self.gain_step,
                    .equal_power_in => self.gain_current = self.ramp_amplitude * equal_power.sample(self.ramp_total - self.ramp_remaining, self.ramp_total),
                    .equal_power_out => self.gain_current = self.ramp_amplitude * equal_power.sample(self.ramp_remaining, self.ramp_total),
                    else => unreachable,
                }
            }
            if (self.state == .releasing and self.ramp_remaining == 0) self.state = .finished;
        }
        self.cursor += 1;
        if (self.loop) |loop| {
            if (self.cursor == loop.end) {
                self.cursor = loop.start;
                self.loop_epoch +|= 1;
            }
        } else if (self.cursor == self.frames and self.state != .finished) {
            self.terminal.reason = .natural;
            self.state = .finished;
        }
        if (self.state == .finished) self.detachAutomation(null, .group_ended, physical_frame + 1);
    }
};
