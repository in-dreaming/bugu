const std = @import("std");
const core = @import("../core/engine.zig");
const builtin = @import("builtin");
pub const channel_layout = @import("sme-channels");
pub const music_group = @import("music_group.zig");
pub const bus_graph = @import("sme-bus-graph");
pub const bus_runtime = @import("sme-bus-runtime");
pub const graph_clock_runtime = @import("sme-graph-clock-runtime");
const gc = graph_clock_runtime.gc;
pub const GraphBinding = bus_runtime.Binding;
/// Render-owned current physical identity. The ring pointer is comparison-only:
/// bridge checks never dereference it, including after the old Service closes.
pub const GraphProgramSource = struct {
    ring: *const music_group.streaming.Ring,
    identity: music_group.streaming.SourceIdentity,
    fn from(source: music_group.streaming.Source) GraphProgramSource {
        return .{ .ring = source.ring, .identity = source.identity };
    }
    fn matches(self: GraphProgramSource, source: music_group.streaming.Source) bool {
        return self.ring == source.ring and std.meta.eql(self.identity, source.identity);
    }
};
pub const GraphProgramBridge = struct {
    manager: *graph_clock_runtime.Manager,
    program: gc.Handle,
    group: music_group.Handle,
    prepared: *const music_group.Prepared,
    layer: *const music_group.PreparedLayer,
    source: ?GraphProgramSource,
    effective_transport_epoch: u64,
    cursor: u64,
    loop_epoch: u64,
};
pub const PreparedRoutes = bus_runtime.PreparedRoutes;

const LayerRoutes = struct {
    current: ?*const PreparedRoutes = null,
    previous: ?*const PreparedRoutes = null,
    remaining: u32 = 0,
    duration: u32 = 0,
};

pub const max_real_voices = 64;
pub const max_logical_voices = @import("sme-virtual-voice").max_logical;
const reverb_delay_frames = 4096;

pub const VoiceState = enum {
    free,
    starting,
    real,
    virtual,
    releasing,
    stolen,
    paused,
};

pub const BusId = enum {
    sfx,
    music,
    master,
};

pub const EffectBusId = enum {
    reverb,
};

pub const VoiceHandle = struct {
    index: u16,
    generation: u16,
};

pub const TestVoiceDesc = struct {
    frequency_hz: f32 = 440.0,
    gain: f32 = 0.2,
    priority: f32 = 1.0,
    bus: BusId = .sfx,
    pan: f32 = 0.0,
    lowpass_hz: f32 = 20_000.0,
    start_delay_frames: u32 = 0,
    pitch_ratio: f32 = 1.0,
    reverb_send: f32 = 0.0,
};

pub const SampleVoiceDesc = struct {
    samples: []const f32,
    gain: f32 = 0.2,
    pitch: f32 = 1.0,
    priority: f32 = 1.0,
    bus: BusId = .sfx,
    loop: bool = false,
    pan: f32 = 0.0,
    lowpass_hz: f32 = 20_000.0,
    start_delay_frames: u32 = 0,
    reverb_send: f32 = 0.0,
};

pub const VoiceControlParams = struct {
    gain: ?f32 = null,
    pan: ?f32 = null,
    lowpass_hz: ?f32 = null,
    pitch_ratio: ?f32 = null,
    reverb_send: ?f32 = null,
};

pub const EffectBusControlParams = struct {
    return_gain: ?f32 = null,
    feedback: ?f32 = null,
    crossfeed: ?f32 = null,
};

pub const EffectBusSnapshot = struct {
    reverb_send_peak: f32,
    reverb_return_peak: f32,
    reverb_return_gain: f32,
    reverb_feedback: f32,
};

const StereoSample = struct {
    l: f32,
    r: f32,
};

const Voice = struct {
    generation: u16 = 0,
    group: ?music_group.Handle = null,
    group_layer: u16 = 0,
    state: VoiceState = .free,
    source: enum { test_tone, sample } = .test_tone,
    phase: f32 = 0.0,
    base_phase_step: f32 = 0.0,
    phase_step: f32 = 0.0,
    samples: []const f32 = &.{},
    cursor: f32 = 0.0,
    cursor_step: f32 = 1.0,
    loop: bool = false,
    gain_current: f32 = 0.0,
    gain_target: f32 = 0.0,
    gain_step: f32 = 0.0,
    priority: f32 = 0.0,
    bus: BusId = .sfx,
    pan: f32 = 0.0,
    lowpass_hz: f32 = 20_000.0,
    lowpass_z: f32 = 0.0,
    start_delay_frames: u32 = 0,
    reverb_send: f32 = 0.0,

    fn audibility(self: Voice) f32 {
        return self.priority * @max(self.gain_current, self.gain_target);
    }
};

const ReverbEffectBus = struct {
    delay_l: [reverb_delay_frames]f32 = [_]f32{0.0} ** reverb_delay_frames,
    delay_r: [reverb_delay_frames]f32 = [_]f32{0.0} ** reverb_delay_frames,
    delay_index: usize = 0,
    return_gain: f32 = 0.25,
    feedback: f32 = 0.45,
    crossfeed: f32 = 0.08,
    send_peak: f32 = 0.0,
    return_peak: f32 = 0.0,

    fn setParams(self: *ReverbEffectBus, params: EffectBusControlParams) void {
        if (params.return_gain) |gain| self.return_gain = std.math.clamp(gain, 0.0, 2.0);
        if (params.feedback) |feedback| self.feedback = std.math.clamp(feedback, 0.0, 0.98);
        if (params.crossfeed) |crossfeed| self.crossfeed = std.math.clamp(crossfeed, 0.0, 0.5);
    }

    fn process(self: *ReverbEffectBus, send_l: f32, send_r: f32) StereoSample {
        const wet_l = self.delay_l[self.delay_index];
        const wet_r = self.delay_r[self.delay_index];
        self.delay_l[self.delay_index] = send_l + wet_l * self.feedback + wet_r * self.crossfeed;
        self.delay_r[self.delay_index] = send_r + wet_r * self.feedback + wet_l * self.crossfeed;
        self.delay_index = (self.delay_index + 1) % reverb_delay_frames;

        const out_l = wet_l * self.return_gain;
        const out_r = wet_r * self.return_gain;
        self.send_peak = @max(self.send_peak, @max(@abs(send_l), @abs(send_r)));
        self.return_peak = @max(self.return_peak, @max(@abs(out_l), @abs(out_r)));
        return .{ .l = out_l, .r = out_r };
    }

    fn clearTail(self: *ReverbEffectBus) void {
        @memset(&self.delay_l, 0);
        @memset(&self.delay_r, 0);
        self.delay_index = 0;
        self.send_peak = 0;
        self.return_peak = 0;
    }

    fn snapshot(self: *const ReverbEffectBus) EffectBusSnapshot {
        return .{
            .reverb_send_peak = self.send_peak,
            .reverb_return_peak = self.return_peak,
            .reverb_return_gain = self.return_gain,
            .reverb_feedback = self.feedback,
        };
    }
};

const EffectBuses = struct {
    reverb: ReverbEffectBus = .{},

    fn setParams(self: *EffectBuses, bus: EffectBusId, params: EffectBusControlParams) void {
        switch (bus) {
            .reverb => self.reverb.setParams(params),
        }
    }

    fn processReverb(self: *EffectBuses, send_l: f32, send_r: f32) StereoSample {
        return self.reverb.process(send_l, send_r);
    }

    fn snapshot(self: *const EffectBuses) EffectBusSnapshot {
        return self.reverb.snapshot();
    }
};

pub const Mixer = struct {
    sample_rate: u32,
    output_layout: channel_layout.ChannelLayout = channel_layout.stereo,
    legacy_route: ?channel_layout.Matrix = channel_layout.Matrix.compile(channel_layout.stereo, channel_layout.stereo) catch unreachable,
    groups: [music_group.max_groups]music_group.MusicVoiceGroup = @splat(.{}),
    group_generation: u64 = 0,
    /// Mutable graph is exclusively owned by Render while bound. Runtime owns
    /// lifetime; immutable binding/routes stay leased for that graph lifetime.
    graph: ?*bus_graph.Graph = null,
    graph_binding: ?*const GraphBinding = null,
    graph_programs: [gc.max_programs]?GraphProgramBridge = @splat(null),
    group_routes: [music_group.max_groups][music_group.max_layers]LayerRoutes = @splat(@splat(.{})),
    voices: [max_logical_voices]Voice = [_]Voice{.{}} ** max_logical_voices,
    sfx_gain: f32 = 1.0,
    music_gain: f32 = 1.0,
    master_gain_current: f32 = 1.0,
    master_gain_target: f32 = 1.0,
    master_gain_step: f32 = 0.0,
    effect_buses: EffectBuses = .{},

    /// Host-exclusive construction in stable caller-owned storage. Static
    /// defaults avoid a large by-value Debug temporary on small callback stacks.
    pub fn initInPlace(self: *Mixer, sample_rate: u32, layout: channel_layout.ChannelLayout) core.BuguError!void {
        try layout.validate();
        if (sample_rate == 0) return error.InvalidArgument;
        const defaults: Mixer = .{ .sample_rate = 48_000 };
        @memcpy(std.mem.asBytes(self), std.mem.asBytes(&defaults));
        self.sample_rate = sample_rate;
        self.output_layout = layout;
        self.legacy_route = channel_layout.Matrix.compile(channel_layout.stereo, layout) catch null;
    }
    pub fn init(sample_rate: u32) Mixer {
        return .{ .sample_rate = sample_rate };
    }

    pub fn initWithLayout(sample_rate: u32, layout: channel_layout.ChannelLayout) core.BuguError!Mixer {
        try layout.validate();
        if (sample_rate == 0) return error.InvalidArgument;
        return .{ .sample_rate = sample_rate, .output_layout = layout, .legacy_route = channel_layout.Matrix.compile(channel_layout.stereo, layout) catch null };
    }

    fn hasLiveSources(self: *const Mixer) bool {
        for (&self.groups) |*group| if (group.state == .playing or group.state == .releasing) return true;
        for (&self.voices) |*voice| if (voice.state != .free and voice.state != .stolen) return true;
        return false;
    }

    fn validateRoutes(graph: *const bus_graph.Graph, generation: u64, routes: *const PreparedRoutes) !void {
        if (generation == 0 or routes.graph_generation != generation or routes.count == 0 or routes.count > routes.destinations.len) return error.InvalidArgument;
        try routes.source_layout.validate();
        if (routes.source_layout.kind == .explicit_mask) return error.UnsupportedChannelLayout;
        for (routes.destinations[0..routes.count]) |*destination| {
            const index = try graph.busIndex(destination.bus);
            if (!channel_layout.ChannelLayout.eql(destination.matrix.input, routes.source_layout) or !channel_layout.ChannelLayout.eql(destination.matrix.output, graph.buses[index].layout)) return error.InvalidArgument;
            try destination.matrix.input.validate();
            try destination.matrix.output.validate();
            if (!std.math.isFinite(destination.gain) or destination.gain < 0 or destination.gain > 4) return error.InvalidArgument;
            for (destination.matrix.coefficients) |row| for (row) |value| {
                if (!std.math.isFinite(value) or @abs(value) > 16) return error.InvalidArgument;
            };
        }
    }

    /// Host-quiescent install. Matrices were compiled by Binding.prepare on
    /// Control; this method only validates and installs stable borrowed pointers.
    pub fn validateGraphBinding(self: *const Mixer, binding: *const GraphBinding) !void {
        if (self.graph != null or self.hasLiveSources() or binding.graph.frame_open) return error.InvalidState;
        if (binding.graph.sample_rate != self.sample_rate or !channel_layout.ChannelLayout.eql(binding.graph.buses[binding.graph.output_index].layout, self.output_layout)) return error.UnsupportedChannelLayout;
        for (&binding.defaults, channel_layout.canonical_layouts) |*routes, layout| {
            try validateRoutes(binding.graph, binding.generation, routes);
            if (!channel_layout.ChannelLayout.eql(routes.source_layout, layout)) return error.UnsupportedChannelLayout;
        }
        for ([_]?PreparedRoutes{ binding.sfx, binding.legacy_music, binding.master, binding.reverb }) |maybe_routes| if (maybe_routes) |routes| {
            try validateRoutes(binding.graph, binding.generation, &routes);
            if (!channel_layout.ChannelLayout.eql(routes.source_layout, channel_layout.stereo)) return error.UnsupportedChannelLayout;
        };
        // Do not strand an existing fixed-reverb tail in a graph lacking return.
        if (binding.reverb == null) {
            for (self.effect_buses.reverb.delay_l) |sample| if (sample != 0) return error.InvalidState;
            for (self.effect_buses.reverb.delay_r) |sample| if (sample != 0) return error.InvalidState;
        }
    }

    /// Render-only installation after the whole phase has passed preflight.
    /// The active slot and immutable graph/group leases outlive this bridge.
    pub fn installGraphProgram(self: *Mixer, manager: *graph_clock_runtime.Manager, program: gc.Handle, group: *music_group.MusicVoiceGroup, frame: u64) void {
        const slot = manager.get(program) catch unreachable;
        var actual: [gc.max_targets]f32 = undefined;
        for (slot.desc.targets, 0..) |write, i| actual[i] = self.graph.?.sourceClockValue(write.target) catch unreachable;
        if (slot.desc.previous) |previous| self.detachGraphProgram(previous, .superseded, frame, frame);
        slot.progress = gc.Progress.init(slot.desc, actual[0..slot.desc.targets.len]) catch unreachable;
        for (slot.desc.targets, 0..) |write, i| self.graph.?.applySourceClockValue(write.target, slot.progress.current[i]) catch unreachable;
        std.debug.assert(self.graph_programs[program.index] == null);
        const layer = &group.layers[slot.desc.progress.tracks[0].ordinal];
        self.graph_programs[program.index] = .{ .manager = manager, .program = program, .group = group.handle, .prepared = group.prepared, .layer = layer.prepared, .source = if (layer.stream()) |source| GraphProgramSource.from(source) else null, .effective_transport_epoch = slot.desc.progress.anchor.transport_epoch, .cursor = group.cursor, .loop_epoch = group.loop_epoch };
        slot.state.store(.active, .release);
        if (slot.desc.progress.tracks[0].instant) self.detachGraphProgram(program, .completed, frame, frame + 1);
    }
    /// Render only. Control uses immutable descriptors/acquired execution facts.
    pub fn graphProgramTransportEpoch(self: *const Mixer, program: gc.Handle) ?u64 {
        if (program.index >= self.graph_programs.len) return null;
        const bridge = self.graph_programs[program.index] orelse return null;
        return if (bridge.program.eql(program)) bridge.effective_transport_epoch else null;
    }
    pub fn graphProgramSourceMatches(self: *const Mixer, program: gc.Handle, group: *const music_group.MusicVoiceGroup) bool {
        if (program.index >= self.graph_programs.len) return false;
        const bridge = self.graph_programs[program.index] orelse return false;
        if (!bridge.program.eql(program) or !bridge.group.eql(group.handle) or bridge.prepared != group.prepared) return false;
        const slot = bridge.manager.get(program) catch return false;
        const ordinal = slot.desc.progress.tracks[0].ordinal;
        if (ordinal >= group.layer_count or group.generation != slot.desc.progress.anchor.bank_generation) return false;
        const layer = &group.layers[ordinal];
        if (layer.prepared != bridge.layer) return false;
        const actual = layer.stream();
        if (bridge.source) |expected| return if (actual) |source| expected.matches(source) else false;
        return actual == null;
    }
    /// Pure whole-group graph preflight. Runtime separately validates the exact
    /// Control-to-Render group mapping and every old/new Service handle/window.
    /// Control and Render group indices are deliberately not assumed identical.
    pub fn checkGroupGraphContinuity(self: *const Mixer, group: *const music_group.MusicVoiceGroup, desc: *const music_group.SourceContinuity) bool {
        if (group.generation != desc.bank_generation or group.layer_count != desc.layer_count or
            group.mutation_epoch != desc.mutation_epoch or group.paused == desc.paused or
            desc.old_transport_epoch == 0 or desc.old_transport_epoch == std.math.maxInt(u64) or
            desc.new_transport_epoch != desc.old_transport_epoch + 1) return false;
        if (!desc.paused and (group.cursor != desc.cursor or group.loop_epoch != desc.loop_epoch)) return false;
        for (self.graph_programs) |maybe| if (maybe) |bridge| {
            if (!bridge.group.eql(group.handle)) continue;
            if (bridge.effective_transport_epoch != desc.old_transport_epoch or bridge.cursor != group.cursor or
                bridge.loop_epoch != group.loop_epoch or !self.graphProgramSourceMatches(bridge.program, group)) return false;
            const slot = bridge.manager.get(bridge.program) catch return false;
            if (slot.state.load(.acquire) != .active) return false;
            const ordinal = slot.desc.progress.tracks[0].ordinal;
            const actual_loop: ?gc.spans.Loop = if (group.loop) |loop| .{ .start = loop.start, .end = loop.end } else null;
            if (!std.meta.eql(actual_loop, slot.desc.progress.anchor.loop)) return false;
            if (bridge.source) |source| {
                const old = desc.old_sources[ordinal] orelse return false;
                const old_handle = desc.old_handles[ordinal] orelse return false;
                if (old_handle.generation != old.stream_generation or !std.meta.eql(source.identity, old)) return false;
                if (!desc.paused) {
                    const fresh = desc.sources[ordinal] orelse return false;
                    const fresh_handle = desc.handles[ordinal] orelse return false;
                    if (fresh_handle.generation != fresh.identity.stream_generation or fresh.ring == source.ring or
                        !music_group.sameAuthoredSource(old, fresh.identity) or fresh.identity.transport_epoch != desc.new_transport_epoch) return false;
                } else if (desc.sources[ordinal] != null or desc.handles[ordinal] != null) return false;
            } else if (desc.old_sources[ordinal] != null or desc.old_handles[ordinal] != null or desc.sources[ordinal] != null or desc.handles[ordinal] != null) return false;
        };
        return true;
    }
    /// No-fail Render phase commit before the paired group install/unpause.
    /// Leases retain both descriptor generations until actual execution and the
    /// completed frontier permit old-resource retirement. Progress, DSP history,
    /// cursor/loop and immutable program hashes are preserved byte-for-byte.
    pub fn commitGroupGraphContinuity(self: *Mixer, group: *const music_group.MusicVoiceGroup, desc: *const music_group.SourceContinuity) void {
        for (&self.graph_programs) |*maybe| {
            const bridge = if (maybe.*) |*value| value else continue;
            if (!bridge.group.eql(group.handle)) continue;
            bridge.effective_transport_epoch = desc.new_transport_epoch;
            if (!desc.paused) {
                const slot = bridge.manager.get(bridge.program) catch unreachable;
                bridge.source = if (desc.sources[slot.desc.progress.tracks[0].ordinal]) |source| GraphProgramSource.from(source) else null;
            }
        }
    }
    pub fn detachGraphProgram(self: *Mixer, program: gc.Handle, reason: gc.Reason, frame: u64, frontier: u64) void {
        const bridge = self.graph_programs[program.index] orelse return;
        if (!bridge.program.eql(program)) return;
        const slot = bridge.manager.get(program) catch unreachable;
        slot.progress.finish(slot.desc, reason, frame, frontier);
        self.graph_programs[program.index] = null;
        bridge.manager.publishTerminal(program); // Last slot access before acquire/reclamation.
    }
    pub fn detachGroupGraphPrograms(self: *Mixer, group: music_group.Handle, reason: gc.Reason, frame: u64) void {
        for (self.graph_programs) |maybe| if (maybe) |bridge| {
            if (bridge.group.eql(group)) self.detachGraphProgram(bridge.program, reason, frame, frame);
        };
    }
    pub fn detachLayerGraphPrograms(self: *Mixer, group: music_group.Handle, layer: u16, reason: gc.Reason, frame: u64) void {
        for (self.graph_programs) |maybe| if (maybe) |bridge| {
            if (!bridge.group.eql(group)) continue;
            const slot = bridge.manager.get(bridge.program) catch unreachable;
            if (slot.desc.progress.tracks[0].ordinal == layer) self.detachGraphProgram(bridge.program, reason, frame, frame);
        };
    }
    pub fn detachAllGraphPrograms(self: *Mixer, reason: gc.Reason, frame: u64) void {
        for (self.graph_programs) |maybe| if (maybe) |bridge| self.detachGraphProgram(bridge.program, reason, frame, frame);
    }
    /// Capture may replace a source after command preflight. Old graph DSP
    /// remains graph-owned (including tails), but no fallback input may enter
    /// an old source lane or its in-progress ingress blend. Keep graph claims
    /// and route leases intact until their existing owner/frontier retires.
    fn commitEmergencySourceHandoff(self: *Mixer, group: *music_group.MusicVoiceGroup) void {
        const result = group.source_switch.pending orelse return;
        for (self.graph_programs) |maybe| if (maybe) |bridge| {
            if (bridge.group.eql(group.handle)) self.detachGraphProgram(bridge.program, .source_replaced, result.frame, result.frame + 1);
        };
        // Clear every ordinal, including old layers absent from the fallback.
        // Null routes select the prepared graph defaults for the new layout.
        self.group_routes[group.handle.index] = @splat(.{});
        group.publishSourceSwitch();
    }
    fn advanceGraphPrograms(self: *Mixer, group: *music_group.MusicVoiceGroup, captured: *const music_group.CapturedGroupFrame, frame: u64) void {
        for (&self.graph_programs) |*maybe| {
            const bridge = if (maybe.*) |*b| b else continue;
            if (!bridge.group.eql(group.handle)) continue;
            const slot = bridge.manager.get(bridge.program) catch unreachable;
            const anchor = slot.desc.progress.anchor;
            if (!self.graphProgramSourceMatches(bridge.program, group)) {
                self.detachGraphProgram(bridge.program, .source_replaced, frame, frame + 1);
                continue;
            }
            // No accepted shared frame means no progress, even though graph DSP
            // and tails still run. valid_layers is only an audibility mask.
            if (captured.layer_count == 0) {
                if (group.state == .finished) self.detachGraphProgram(bridge.program, .group_ended, frame, frame + 1);
                continue;
            }
            const actual_loop: ?gc.spans.Loop = if (group.loop) |l| .{ .start = l.start, .end = l.end } else null;
            if (captured.cursor != bridge.cursor or captured.loop_epoch != bridge.loop_epoch or !std.meta.eql(actual_loop, anchor.loop)) {
                self.detachGraphProgram(bridge.program, .clock_discontinuity, frame, frame + 1);
                continue;
            }
            slot.progress.capture(slot.desc, frame);
            for (slot.desc.targets, 0..) |write, i| self.graph.?.applySourceClockValue(write.target, slot.progress.current[i]) catch unreachable;
            if (slot.progress.terminal != null) {
                const manager = bridge.manager;
                const program = bridge.program;
                maybe.* = null;
                manager.publishTerminal(program);
                continue;
            }
            if (group.state == .finished) {
                self.detachGraphProgram(bridge.program, .group_ended, frame, frame + 1);
                continue;
            }
            bridge.cursor = group.cursor;
            bridge.loop_epoch = group.loop_epoch;
        }
    }

    pub fn bindGraphPrepared(self: *Mixer, binding: *const GraphBinding) !void {
        try self.validateGraphBinding(binding);
        self.group_routes = @splat(@splat(.{}));
        self.graph_binding = binding;
        self.graph = binding.graph;
    }

    pub fn unbindGraph(self: *Mixer) !void {
        const graph = self.graph orelse return error.InvalidState;
        if (self.hasLiveSources() or graph.frame_open) return error.InvalidState;
        self.group_routes = @splat(@splat(.{}));
        self.graph_binding = null;
        self.graph = null;
        // Explicit graph retirement ends its fixed-effect tail as well as DAG
        // tails. Preserve authored reverb settings for subsequent legacy work.
        self.effect_buses.reverb.clearTail();
    }

    pub fn canStartLegacyVoice(self: *const Mixer, bus: BusId, reverb_send: f32) bool {
        if (self.graph_binding) |binding| {
            const present = switch (bus) {
                .sfx => binding.sfx != null,
                .music => binding.legacy_music != null,
                .master => binding.master != null,
            };
            return present and (reverb_send <= 0 or binding.reverb != null);
        }
        return self.legacy_route != null;
    }

    pub fn validateGroupLayerRoutes(self: *const Mixer, handle: music_group.Handle, layer: u16, routes: *const PreparedRoutes) !void {
        const binding = self.graph_binding orelse return error.InvalidState;
        if (handle.index >= self.groups.len) return error.InvalidState;
        const group = &self.groups[handle.index];
        if (!group.handle.eql(handle) or (group.state != .playing and group.state != .releasing) or layer >= group.layer_count or self.group_routes[handle.index][layer].remaining != 0) return error.InvalidState;
        try validateRoutes(binding.graph, binding.generation, routes);
        if (!channel_layout.ChannelLayout.eql(group.prepared.matrix.input, routes.source_layout)) return error.UnsupportedChannelLayout;
        if (group.prepared.emergency) |emergency| if (!channel_layout.ChannelLayout.eql(emergency.matrix.input, routes.source_layout)) return error.UnsupportedChannelLayout;
    }

    /// Read-only M3 source-identity guard. No prediction, source consumption or
    /// ramp advancement. Claimed lanes are installed with zero ingress blend.
    pub fn groupLayerUsesRoutes(self: *const Mixer, handle: music_group.Handle, layer: u16, routes: *const PreparedRoutes) bool {
        if (handle.index >= self.groups.len) return false;
        const group = &self.groups[handle.index];
        if (!group.handle.eql(handle) or group.state != .playing or layer >= group.layer_count) return false;
        const state = self.group_routes[handle.index][layer];
        return state.current == routes and state.remaining == 0;
    }

    /// Immutable, publication-frozen bound includes every prepared future route
    /// alternative for this source layout, not only today's audible selection.
    /// Scalar music/layer/group/envelope gains are composed by the caller in f64.
    pub fn groupLayerRouteBound(self: *const Mixer, handle: music_group.Handle, layer: u16) f64 {
        const binding = self.graph_binding orelse return 1;
        if (handle.index >= self.groups.len) return 1;
        const group = &self.groups[handle.index];
        if (!group.handle.eql(handle) or (group.state != .playing and group.state != .releasing) or layer >= group.layer_count) return 1;
        return binding.metric_bounds[@intFromEnum(group.prepared.matrix.input.kind)];
    }

    pub fn groupLayerDetectorDependency(self: *const Mixer, handle: music_group.Handle, layer: u16) bool {
        const binding = self.graph_binding orelse return false;
        if (handle.index >= self.groups.len) return false;
        const group = &self.groups[handle.index];
        if (!group.handle.eql(handle) or (group.state != .playing and group.state != .releasing) or layer >= group.layer_count) return false;
        return binding.detector_dependencies[@intFromEnum(group.prepared.matrix.input.kind)];
    }

    pub fn setGroupLayerRoutes(self: *Mixer, handle: music_group.Handle, layer: u16, routes: *const PreparedRoutes, ramp_frames: u32) !void {
        try self.validateGroupLayerRoutes(handle, layer, routes);
        self.applyGroupLayerRoutesValidated(handle, layer, routes, ramp_frames);
    }

    /// Runtime must preflight the entire atomic command group first, including
    /// duplicate route writes. It retains both borrowed endpoints until unbind.
    pub fn applyGroupLayerRoutesValidated(self: *Mixer, handle: music_group.Handle, layer: u16, routes: *const PreparedRoutes, ramp_frames: u32) void {
        const state = &self.group_routes[handle.index][layer];
        std.debug.assert(state.remaining == 0);
        state.previous = if (ramp_frames == 0) null else state.current;
        state.current = routes;
        state.remaining = ramp_frames;
        state.duration = ramp_frames;
    }

    fn defaultRoutes(self: *const Mixer, layout: channel_layout.ChannelLayout) *const PreparedRoutes {
        std.debug.assert(layout.kind != .explicit_mask);
        return &self.graph_binding.?.defaults[@intFromEnum(layout.kind)];
    }

    fn injectRoutes(self: *Mixer, routes: *const PreparedRoutes, samples: []const f32, gain: f32) void {
        for (routes.destinations[0..routes.count]) |*destination| {
            var converted: [channel_layout.max_channels]f32 = @splat(0);
            // The complete gain product may exceed Graph's input scalar range;
            // apply it to PCM here, then Graph sanitizes the converted samples.
            destination.matrix.addFrame(samples, converted[0..destination.matrix.output.count], gain * destination.gain);
            self.graph.?.addInputFrame(destination.bus, converted[0..destination.matrix.output.count], 1) catch unreachable;
        }
    }

    fn routeCaptured(self: *Mixer, group_index: u16, captured: *const music_group.CapturedGroupFrame) void {
        if (captured.layer_count == 0) return;
        const defaults = self.defaultRoutes(captured.source_layout);
        for (0..captured.layer_count) |layer| {
            const state = &self.group_routes[group_index][layer];
            const new_weight = if (state.remaining == 0) @as(f32, 1) else @as(f32, @floatFromInt(state.duration - state.remaining + 1)) / @as(f32, @floatFromInt(state.duration));
            if (captured.valid_layers & (@as(u16, 1) << @intCast(layer)) != 0) {
                const samples = captured.samples[layer][0..captured.source_layout.count];
                const gain = captured.gain(layer, self.music_gain);
                if (state.remaining != 0 and new_weight < 1) self.injectRoutes(state.previous orelse defaults, samples, gain * (1 - new_weight));
                self.injectRoutes(state.current orelse defaults, samples, gain * new_weight);
            }
            // Source-clock transition: a paused/failed capture has no layers;
            // a virtual layer advances with the same successful group frame.
            if (state.remaining != 0) {
                state.remaining -= 1;
                if (state.remaining == 0) state.previous = null;
            }
        }
    }

    pub fn canStartGroup(self: *const Mixer, prepared: *const music_group.Prepared) bool {
        if (self.graph != null) {
            if (prepared.matrix.input.kind == .explicit_mask) return false;
            if (prepared.emergency) |emergency| {
                if (emergency.matrix.input.kind == .explicit_mask) return false;
                if (self.graph_binding.?.detector_dependencies[@intFromEnum(emergency.matrix.input.kind)] and emergency.hasVirtual()) return false;
            }
            if (self.graph_binding.?.detector_dependencies[@intFromEnum(prepared.matrix.input.kind)]) {
                if (prepared.hasVirtual()) return false;
                for (prepared.layers[0..prepared.layer_count]) |layer| if (layer.stream) |source| {
                    const asset_frame = layer.assetFrame(prepared.start_cursor) catch return false;
                    if (!source.ready(asset_frame, prepared.start_loop_epoch)) return false;
                };
            }
        } else if (!channel_layout.ChannelLayout.eql(prepared.matrix.output, self.output_layout)) return false;
        if (self.freeVoiceCount() < prepared.realCount() or self.freeLogicalCount() < prepared.voice_count) return false;
        for (&self.groups) |*group| if (group.state == .free or group.state == .finished) return true;
        return false;
    }

    pub const GroupStart = struct { group: music_group.Handle, voices: [music_group.max_layers]VoiceHandle };
    pub fn startMusicGroupReserved(self: *Mixer, prepared: *const music_group.Prepared, frame: u64, identity: u64) GroupStart {
        std.debug.assert(self.canStartGroup(prepared));
        const group_index = for (&self.groups, 0..) |*group, i| {
            if (group.state == .free or group.state == .finished) break i;
        } else unreachable;
        const handle: music_group.Handle = .{ .index = @intCast(group_index), .generation = identity };
        self.groups[group_index] = music_group.MusicVoiceGroup.start(handle, prepared, frame);
        self.group_routes[group_index] = @splat(.{});
        var result: GroupStart = .{ .group = handle, .voices = undefined };
        for (0..prepared.voice_count) |layer| {
            const index = self.findFreeLogicalVoice().?;
            const generation = nextGeneration(self.voices[index].generation);
            self.voices[index] = .{ .generation = generation, .group = handle, .group_layer = @intCast(layer), .state = if (layer < prepared.layer_count and prepared.layers[layer].initial_state == .virtual) .virtual else .real, .bus = .music, .gain_current = prepared.gain, .gain_target = prepared.gain, .priority = 1 };
            result.voices[layer] = handleFor(index, generation);
            self.groups[group_index].accounting_voices[layer] = @intCast(index);
        }
        self.groups[group_index].accounting_count = prepared.voice_count;
        return result;
    }

    pub fn groupFor(self: *Mixer, handle: music_group.Handle) ?*music_group.MusicVoiceGroup {
        if (handle.index >= self.groups.len) return null;
        const group = &self.groups[handle.index];
        return if (group.state != .free and group.handle.eql(handle)) group else null;
    }

    pub fn isGroupVoice(self: *const Mixer, handle: VoiceHandle) bool {
        return self.isVoiceActive(handle) and self.voices[handle.index].group != null;
    }

    pub fn startTestVoice(self: *Mixer, desc: TestVoiceDesc, telemetry: *core.TelemetryCounters) core.BuguError!void {
        _ = try self.startTestVoiceWithHandle(desc, telemetry);
    }

    pub fn startTestVoiceWithHandle(self: *Mixer, desc: TestVoiceDesc, telemetry: *core.TelemetryCounters) core.BuguError!VoiceHandle {
        if (!self.canStartLegacyVoice(desc.bus, desc.reverb_send)) return error.UnsupportedChannelLayout;
        if (self.freeVoiceCount() == 0 and !self.hasStealableVoice()) return error.VoiceBudgetExceeded;
        const index = self.findFreeVoice() orelse self.stealVoice(desc, telemetry);
        const voice = &self.voices[index];
        const generation = nextGeneration(voice.generation);
        const base_step = (2.0 * std.math.pi * desc.frequency_hz) / @as(f32, @floatFromInt(self.sample_rate));
        voice.* = .{
            .generation = generation,
            .state = .starting,
            .source = .test_tone,
            .phase = 0.0,
            .base_phase_step = base_step,
            .phase_step = base_step * std.math.clamp(desc.pitch_ratio, 0.01, 8.0),
            .gain_current = 0.0,
            .gain_target = desc.gain,
            .gain_step = desc.gain / 128.0,
            .priority = desc.priority,
            .bus = desc.bus,
            .pan = desc.pan,
            .lowpass_hz = desc.lowpass_hz,
            .start_delay_frames = desc.start_delay_frames,
            .reverb_send = std.math.clamp(desc.reverb_send, 0.0, 1.0),
        };
        return handleFor(index, generation);
    }

    pub fn startSampleVoice(self: *Mixer, desc: SampleVoiceDesc, telemetry: *core.TelemetryCounters) core.BuguError!void {
        _ = try self.startSampleVoiceWithHandle(desc, telemetry);
    }

    pub fn startSampleVoiceWithHandle(self: *Mixer, desc: SampleVoiceDesc, telemetry: *core.TelemetryCounters) core.BuguError!VoiceHandle {
        if (!self.canStartLegacyVoice(desc.bus, desc.reverb_send)) return error.UnsupportedChannelLayout;
        if (desc.samples.len == 0) return core.BuguError.InvalidArgument;
        if (self.freeVoiceCount() == 0 and !self.hasStealableVoice()) return error.VoiceBudgetExceeded;
        const index = self.findFreeVoice() orelse self.stealVoice(.{
            .gain = desc.gain,
            .priority = desc.priority,
            .bus = desc.bus,
        }, telemetry);
        const voice = &self.voices[index];
        const generation = nextGeneration(voice.generation);
        voice.* = .{
            .generation = generation,
            .state = .starting,
            .source = .sample,
            .samples = desc.samples,
            .cursor = 0.0,
            .cursor_step = desc.pitch,
            .loop = desc.loop,
            .gain_current = 0.0,
            .gain_target = desc.gain,
            .gain_step = desc.gain / 128.0,
            .priority = desc.priority,
            .bus = desc.bus,
            .pan = desc.pan,
            .lowpass_hz = desc.lowpass_hz,
            .start_delay_frames = desc.start_delay_frames,
            .reverb_send = std.math.clamp(desc.reverb_send, 0.0, 1.0),
        };
        return handleFor(index, generation);
    }

    /// Scheduler preflight reserves all slots before calling this no-failure
    /// primitive. It never steals an unrelated SFX or music voice.
    pub fn startSampleVoiceReserved(self: *Mixer, desc: SampleVoiceDesc, telemetry: *core.TelemetryCounters) VoiceHandle {
        std.debug.assert(self.freeVoiceCount() != 0 and desc.samples.len != 0);
        const handle = self.startSampleVoiceWithHandle(desc, telemetry) catch unreachable;
        // Scheduled sample onset is exactly the requested frame. Legacy starts
        // retain their historical startup ramp for compatibility.
        self.voices[handle.index].gain_current = desc.gain;
        self.voices[handle.index].gain_step = 0;
        return handle;
    }

    pub fn freeLogicalCount(self: *const Mixer) usize {
        var count: usize = 0;
        for (&self.voices) |*voice| if (voice.state == .free or voice.state == .stolen) {
            count += 1;
        };
        return count;
    }
    pub fn freeVoiceCount(self: *const Mixer) usize {
        const counts = self.countVoices();
        var reserved: usize = counts.active;
        for (&self.groups) |*group| if (group.state == .playing or group.state == .releasing) {
            if (group.prepared.emergency_real_count == 0) continue;
            var real: usize = 0;
            for (group.layers[0..group.layer_count]) |layer| real += @intFromBool(layer.state == .real or layer.state == .releasing);
            reserved += group.prepared.emergency_real_count -| real;
        };
        return @min(self.freeLogicalCount(), max_real_voices -| reserved);
    }
    pub fn syncGroupVoices(self: *Mixer, group: *const music_group.MusicVoiceGroup) void {
        for (group.accounting_voices[0..group.accounting_count]) |index| {
            const v = &self.voices[index];
            const handle = v.group orelse continue;
            if (!handle.eql(group.handle) or v.state == .free or v.group_layer >= group.layer_count) continue;
            v.state = switch (group.layers[v.group_layer].state) {
                .real => .real,
                .virtual => .virtual,
                .releasing => .releasing,
                .stolen => .stolen,
            };
        }
    }

    pub fn renderSpan(self: *Mixer, output: []f32, frames: u32, channels: u16, telemetry: *core.TelemetryCounters) void {
        std.debug.assert(frames > 0 and channels == self.output_layout.count and output.len == @as(usize, frames) * channels);
        self.render(output, frames, channels, telemetry);
    }

    /// Same DSP implementation with an exact generated-frame origin.
    pub fn renderSpanAt(self: *Mixer, output: []f32, frames: u32, channels: u16, telemetry: *core.TelemetryCounters, origin: u64) void {
        std.debug.assert(frames > 0 and channels == self.output_layout.count and output.len == @as(usize, frames) * channels);
        self.renderAt(output, frames, channels, telemetry, origin);
    }

    /// Read-only whole-command preflight for ordinary voice updates. In
    /// particular, a missing return must reject before applying another field.
    pub fn canUpdateLegacyVoice(self: *const Mixer, handle: VoiceHandle, params: VoiceControlParams) bool {
        if (!self.isVoiceActive(handle)) return false;
        const voice = &self.voices[handle.index];
        return voice.group == null and self.canStartLegacyVoice(voice.bus, params.reverb_send orelse voice.reverb_send);
    }

    pub fn updateVoice(self: *Mixer, handle: VoiceHandle, params: VoiceControlParams, ramp_frames: u32) core.BuguError!void {
        if (handle.index >= max_logical_voices) return core.BuguError.InvalidArgument;
        const voice = &self.voices[handle.index];
        if (voice.generation != handle.generation or voice.state == .free or voice.state == .stolen) {
            return core.BuguError.InvalidArgument;
        }
        if (voice.group != null) return error.InvalidState;
        if (!self.canUpdateLegacyVoice(handle, params)) return error.UnsupportedChannelLayout;
        const frames = @max(ramp_frames, 1);
        if (params.gain) |gain| {
            const target = std.math.clamp(gain, 0.0, 4.0);
            voice.gain_target = target;
            voice.gain_step = (target - voice.gain_current) / @as(f32, @floatFromInt(frames));
        }
        if (params.pan) |pan| {
            voice.pan = std.math.clamp(pan, -1.0, 1.0);
        }
        if (params.lowpass_hz) |lowpass_hz| {
            voice.lowpass_hz = std.math.clamp(lowpass_hz, 20.0, @as(f32, @floatFromInt(self.sample_rate)) * 0.5);
        }
        if (params.pitch_ratio) |pitch_ratio| {
            const pitch = std.math.clamp(pitch_ratio, 0.01, 8.0);
            switch (voice.source) {
                .test_tone => voice.phase_step = voice.base_phase_step * pitch,
                .sample => voice.cursor_step = pitch,
            }
        }
        if (params.reverb_send) |reverb_send| {
            voice.reverb_send = std.math.clamp(reverb_send, 0.0, 1.0);
        }
    }

    pub fn stopVoice(self: *Mixer, handle: VoiceHandle, release_frames: u32) core.BuguError!void {
        return self.stopVoiceWithBoundary(handle, release_frames, null, .stopped);
    }
    pub fn stopVoiceAt(self: *Mixer, handle: VoiceHandle, release_frames: u32, frame: u64, reason: music_group.TerminalReason) core.BuguError!void {
        return self.stopVoiceWithBoundary(handle, release_frames, frame, reason);
    }
    fn stopVoiceWithBoundary(self: *Mixer, handle: VoiceHandle, release_frames: u32, frame: ?u64, reason: music_group.TerminalReason) core.BuguError!void {
        if (handle.index >= max_logical_voices) return core.BuguError.InvalidArgument;
        const voice = &self.voices[handle.index];
        if (voice.generation != handle.generation or voice.state == .free or voice.state == .stolen) return core.BuguError.InvalidArgument;
        if (voice.group) |group_handle| {
            const group = self.groupFor(group_handle) orelse return error.InvalidState;
            if (frame) |boundary| group.stopAt(release_frames, boundary, reason) else group.stop(release_frames);
            if (group.state == .finished) self.finishGroupVoices(group_handle);
            return;
        }
        voice.state = .releasing;
        voice.gain_target = 0.0;
        voice.gain_step = -voice.gain_current / @as(f32, @floatFromInt(@max(release_frames, 1)));
        if (voice.gain_current == 0) voice.state = .free;
    }

    pub fn isVoiceActive(self: *const Mixer, handle: VoiceHandle) bool {
        if (handle.index >= max_logical_voices) return false;
        const voice = self.voices[handle.index];
        return voice.generation == handle.generation and voice.state != .free and voice.state != .stolen;
    }

    pub fn stopAll(self: *Mixer, release_frames: u32) void {
        const frames = @max(release_frames, 1);
        for (&self.groups) |*group| if (group.state == .playing or group.state == .releasing) {
            group.stop(frames);
            if (group.state == .finished) self.finishGroupVoices(group.handle);
        };
        for (&self.voices) |*voice| {
            if (voice.group != null) continue;
            if (voice.state == .real or voice.state == .starting) {
                voice.state = .releasing;
                voice.gain_target = 0.0;
                voice.gain_step = -voice.gain_current / @as(f32, @floatFromInt(frames));
            }
        }
    }

    pub fn setBusGain(self: *Mixer, bus: BusId, gain: f32) void {
        switch (bus) {
            .sfx => self.sfx_gain = gain,
            .music => self.music_gain = gain,
            .master => self.master_gain_current = gain,
        }
    }

    pub fn setMasterGain(self: *Mixer, gain: f32, ramp_frames: u32) void {
        self.master_gain_target = gain;
        self.master_gain_step = (gain - self.master_gain_current) / @as(f32, @floatFromInt(@max(ramp_frames, 1)));
    }

    pub fn setEffectBus(self: *Mixer, bus: EffectBusId, params: EffectBusControlParams) void {
        self.effect_buses.setParams(bus, params);
    }

    pub fn effectBusSnapshot(self: *const Mixer) EffectBusSnapshot {
        return self.effect_buses.snapshot();
    }

    pub fn render(self: *Mixer, buffer: []f32, frame_count: u32, channels: u16, telemetry: *core.TelemetryCounters) void {
        self.renderAt(buffer, frame_count, channels, telemetry, null);
    }
    fn renderAt(self: *Mixer, buffer: []f32, frame_count: u32, channels: u16, telemetry: *core.TelemetryCounters, origin: ?u64) void {
        const sample_count = channel_layout.sampleCount(frame_count, channels) catch unreachable;
        std.debug.assert(channels == self.output_layout.count and buffer.len >= sample_count);
        if (frame_count == 0) return;
        // Legacy Engine callers may pass a larger backing buffer. Only the
        // requested complete frames belong to this render; preserve its tail.
        const output = buffer[0..sample_count];
        const start_ns = nowNanos();
        @memset(output, 0.0);
        _ = telemetry.rendered_frames.fetchAdd(frame_count, .monotonic);
        _ = telemetry.rendered_quantums.fetchAdd(1, .monotonic);

        var peak: f32 = 0.0;
        var sum_squares: f64 = 0.0;
        var clipping: u64 = 0;

        var group_indices: [music_group.max_groups]u16 = undefined;
        var group_count: usize = 0;
        for (&self.groups, 0..) |*group, i| if (group.state == .playing or group.state == .releasing) {
            group_indices[group_count] = @intCast(i);
            group_count += 1;
        };
        var individual_indices: [max_real_voices]u16 = undefined;
        var individual_count: usize = 0;
        for (&self.voices, 0..) |*voice, i| if (voice.group == null and (voice.state == .starting or voice.state == .real or voice.state == .releasing)) {
            individual_indices[individual_count] = @intCast(i);
            individual_count += 1;
        };
        var frame: u32 = 0;
        while (frame < frame_count) : (frame += 1) {
            self.advanceMasterRamp();

            var dry_l_sum: f32 = 0.0;
            var dry_r_sum: f32 = 0.0;
            var reverb_send_l: f32 = 0.0;
            var reverb_send_r: f32 = 0.0;

            var dry: [8]f32 = @splat(0);
            var legacy_inputs: [3][2]f32 = @splat(@splat(0));
            if (self.graph) |graph| graph.beginFrame() catch unreachable;
            var captured: music_group.CapturedGroupFrame = .{};
            for (group_indices[0..group_count]) |group_index| {
                const group = &self.groups[group_index];
                if (group.state != .playing and group.state != .releasing) continue;
                if (self.graph != null) {
                    const protected: u16 = if (self.graph_binding.?.detector_dependencies[@intFromEnum(group.prepared.matrix.input.kind)]) std.math.maxInt(u16) else 0;
                    group.captureFrameProtectedAt(&captured, protected, if (origin) |at| at + frame else group.start_render_frame +| group.timeline_frames);
                    self.commitEmergencySourceHandoff(group);
                    self.advanceGraphPrograms(group, &captured, if (origin) |at| at + frame else group.start_render_frame +| group.timeline_frames -| 1);
                    self.routeCaptured(group_index, &captured);
                } else {
                    group.captureFrameProtectedAt(&captured, 0, if (origin) |at| at + frame else group.start_render_frame +| group.timeline_frames);
                    self.commitEmergencySourceHandoff(group);
                    if (captured.valid_layers != 0) captured.addLegacy(&group.prepared.matrix, dry[0..channels], self.music_gain);
                }
                self.syncGroupVoices(group);
                if (group.state == .finished) self.finishGroupVoices(group.handle);
            }
            for (individual_indices[0..individual_count]) |voice_index| {
                const voice = &self.voices[voice_index];
                switch (voice.state) {
                    .free, .stolen => {},
                    .virtual, .paused => {},
                    .starting, .real, .releasing => {
                        if (voice.state == .starting) voice.state = .real;
                        if (voice.start_delay_frames > 0) {
                            voice.start_delay_frames -= 1;
                            continue;
                        }
                        const source_sample = switch (voice.source) {
                            .test_tone => tone: {
                                const value = @sin(voice.phase);
                                voice.phase += voice.phase_step;
                                if (voice.phase >= 2.0 * std.math.pi) voice.phase -= 2.0 * std.math.pi;
                                break :tone value;
                            },
                            .sample => sample: {
                                var index: usize = @intFromFloat(voice.cursor);
                                if (index >= voice.samples.len) {
                                    if (voice.loop) {
                                        voice.cursor = 0.0;
                                        index = 0;
                                    } else {
                                        voice.state = .free;
                                        break :sample 0.0;
                                    }
                                }
                                const value = voice.samples[index];
                                voice.cursor += @max(voice.cursor_step, 0.01);
                                break :sample value;
                            },
                        };
                        const sample = source_sample * voice.gain_current;
                        self.advanceVoiceRamp(voice);

                        const bus_gain = switch (voice.bus) {
                            .sfx => self.sfx_gain,
                            .music => self.music_gain,
                            .master => 1.0,
                        };
                        const filtered = self.applyLowpass(voice, sample);
                        const out_sample = filtered * bus_gain;
                        const pan = std.math.clamp(voice.pan, -1.0, 1.0);
                        const left = @cos((pan + 1.0) * std.math.pi * 0.25);
                        const right = @sin((pan + 1.0) * std.math.pi * 0.25);
                        const dry_l = out_sample * left;
                        const dry_r = out_sample * right;
                        if (self.graph != null) {
                            legacy_inputs[@intFromEnum(voice.bus)][0] += dry_l;
                            legacy_inputs[@intFromEnum(voice.bus)][1] += dry_r;
                        } else {
                            dry_l_sum += dry_l;
                            dry_r_sum += dry_r;
                        }
                        reverb_send_l += dry_l * voice.reverb_send;
                        reverb_send_r += dry_r * voice.reverb_send;
                    },
                }
            }

            const wet = self.effect_buses.processReverb(reverb_send_l, reverb_send_r);
            if (self.graph) |graph| {
                const binding = self.graph_binding.?;
                if (binding.sfx) |*routes| self.injectRoutes(routes, &legacy_inputs[@intFromEnum(BusId.sfx)], 1);
                if (binding.legacy_music) |*routes| self.injectRoutes(routes, &legacy_inputs[@intFromEnum(BusId.music)], 1);
                if (binding.master) |*routes| self.injectRoutes(routes, &legacy_inputs[@intFromEnum(BusId.master)], 1);
                if (binding.reverb) |*routes| self.injectRoutes(routes, &.{ wet.l, wet.r }, 1);
                graph.processFrameAt(dry[0..channels], if (origin) |at| at + frame else null) catch unreachable;
            } else if (self.legacy_route) |route| route.addFrame(&.{ dry_l_sum + wet.l, dry_r_sum + wet.r }, dry[0..channels], 1);
            const base = @as(usize, frame) * channels;
            for (0..channels) |channel| {
                var mixed = dry[channel] * self.master_gain_current;
                if (mixed > 1 or mixed < -1) clipping += 1;
                mixed = std.math.clamp(mixed, -1, 1);
                peak = @max(peak, @abs(mixed));
                sum_squares += @as(f64, @floatCast(mixed * mixed));
                output[base + channel] = mixed;
            }
        }

        telemetry.recordPeak(peak);
        telemetry.storeRms(@floatCast(@sqrt(sum_squares / @as(f64, @floatFromInt(@as(usize, frame_count) * channels)))));
        const counts = self.countVoices();
        telemetry.active_voices.store(counts.active, .monotonic);
        telemetry.virtual_voices.store(counts.virtual, .monotonic);
        _ = telemetry.clipping_count.fetchAdd(clipping, .monotonic);
        const end_ns = nowNanos();
        if (end_ns > start_ns) {
            telemetry.mixer_time_nanos.store(end_ns - start_ns, .monotonic);
        }
    }

    pub fn finishStoppedGroup(self: *Mixer, handle: music_group.Handle) void {
        const group = self.groupFor(handle) orelse return;
        if (group.state == .finished) self.finishGroupVoices(handle);
    }

    fn finishGroupVoices(self: *Mixer, handle: music_group.Handle) void {
        for (&self.voices) |*voice| if (voice.group) |member| {
            if (member.eql(handle)) voice.state = .free;
        };
    }

    fn findFreeVoice(self: *Mixer) ?usize {
        if (self.freeVoiceCount() == 0) return null;
        return self.findFreeLogicalVoice();
    }
    fn findFreeLogicalVoice(self: *Mixer) ?usize {
        for (&self.voices, 0..) |*voice, index| {
            if (voice.state == .free or voice.state == .stolen) return index;
        }
        return null;
    }

    fn countVoices(self: *const Mixer) struct { active: u32, virtual: u32 } {
        var active: u32 = 0;
        var virtual: u32 = 0;
        for (&self.voices) |*voice| {
            switch (voice.state) {
                .starting, .real, .releasing, .paused => active += 1,
                .virtual => virtual += 1,
                .free, .stolen => {},
            }
        }
        return .{ .active = active, .virtual = virtual };
    }

    fn legacyDetectorRequired(self: *const Mixer, bus: BusId) bool {
        const binding = self.graph_binding orelse return false;
        return binding.legacyDetectorDependency(switch (bus) {
            .sfx => .sfx,
            .music => .music,
            .master => .master,
        });
    }

    fn hasStealableVoice(self: *const Mixer) bool {
        for (&self.voices) |*voice| if (voice.group == null and voice.state != .free and voice.state != .stolen and voice.state != .virtual and !self.legacyDetectorRequired(voice.bus)) return true;
        return false;
    }

    fn stealVoice(self: *Mixer, desc: TestVoiceDesc, telemetry: *core.TelemetryCounters) usize {
        _ = desc;
        var weakest_index: usize = 0;
        var weakest_score: f32 = std.math.floatMax(f32);
        for (&self.voices, 0..) |*voice, index| {
            if (voice.group != null or voice.state == .free or voice.state == .stolen or voice.state == .virtual or self.legacyDetectorRequired(voice.bus)) continue;
            const score = voice.audibility();
            if (score < weakest_score) {
                weakest_score = score;
                weakest_index = index;
            }
        }
        self.voices[weakest_index].state = .stolen;
        _ = telemetry.stolen_voices.fetchAdd(1, .monotonic);
        return weakest_index;
    }

    fn advanceVoiceRamp(self: *Mixer, voice: *Voice) void {
        _ = self;
        if (voice.gain_step == 0.0) return;
        const next = voice.gain_current + voice.gain_step;
        if ((voice.gain_step > 0.0 and next >= voice.gain_target) or
            (voice.gain_step < 0.0 and next <= voice.gain_target))
        {
            voice.gain_current = voice.gain_target;
            voice.gain_step = 0.0;
            if (voice.state == .releasing and voice.gain_current == 0.0) {
                voice.state = .free;
            }
        } else {
            voice.gain_current = next;
        }
    }

    fn advanceMasterRamp(self: *Mixer) void {
        if (self.master_gain_step == 0.0) return;
        const next = self.master_gain_current + self.master_gain_step;
        if ((self.master_gain_step > 0.0 and next >= self.master_gain_target) or
            (self.master_gain_step < 0.0 and next <= self.master_gain_target))
        {
            self.master_gain_current = self.master_gain_target;
            self.master_gain_step = 0.0;
        } else {
            self.master_gain_current = next;
        }
    }

    fn applyLowpass(self: *Mixer, voice: *Voice, sample: f32) f32 {
        const nyquist = @as(f32, @floatFromInt(self.sample_rate)) * 0.5;
        if (voice.lowpass_hz >= nyquist) return sample;
        const cutoff = std.math.clamp(voice.lowpass_hz, 20.0, nyquist);
        const dt = 1.0 / @as(f32, @floatFromInt(self.sample_rate));
        const rc = 1.0 / (2.0 * std.math.pi * cutoff);
        const alpha = dt / (rc + dt);
        voice.lowpass_z += alpha * (sample - voice.lowpass_z);
        return voice.lowpass_z;
    }
};

fn nextGeneration(current: u16) u16 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

fn handleFor(index: usize, generation: u16) VoiceHandle {
    return .{ .index = @intCast(index), .generation = generation };
}

fn nowNanos() u64 {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var counter: windows.LARGE_INTEGER = 0;
        var frequency: windows.LARGE_INTEGER = 0;
        if (!windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool()) return 0;
        if (!windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool()) return 0;
        if (frequency <= 0 or counter <= 0) return 0;
        return @intCast(@divTrunc(@as(i128, counter) * std.time.ns_per_s, frequency));
    }
    return 0;
}

test "mixer renders 64 real voices and steals beyond limit" {
    var mixer = Mixer.init(48_000);
    var telemetry: core.TelemetryCounters = .{};
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        try mixer.startTestVoice(.{
            .frequency_hz = 220.0 + @as(f32, @floatFromInt(i)),
            .gain = 0.01,
            .priority = @floatFromInt(i + 1),
        }, &telemetry);
    }

    var buffer: [256 * 2]f32 = undefined;
    mixer.render(&buffer, 256, 2, &telemetry);
    const snap = telemetry.snapshot();
    try std.testing.expectEqual(@as(u32, 64), snap.active_voices);
    try std.testing.expectEqual(@as(u64, 64), snap.stolen_voices);
    try std.testing.expect(snap.peak_abs > 0.0);
    try std.testing.expect(snap.rms > 0.0);
}

test "gain ramp releases without discontinuous hard stop" {
    var mixer = Mixer.init(48_000);
    var telemetry: core.TelemetryCounters = .{};
    try mixer.startTestVoice(.{ .frequency_hz = 440.0, .gain = 0.2 }, &telemetry);
    var buffer: [256 * 2]f32 = undefined;
    mixer.render(&buffer, 256, 2, &telemetry);
    mixer.stopAll(128);
    mixer.render(&buffer, 256, 2, &telemetry);
    try std.testing.expect(telemetry.snapshot().peak_abs > 0.0);
}

test "rapid start stop and master ramp stay bounded" {
    var mixer = Mixer.init(48_000);
    var telemetry: core.TelemetryCounters = .{};
    var buffer: [256 * 2]f32 = undefined;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try mixer.startTestVoice(.{
            .frequency_hz = 110.0 + @as(f32, @floatFromInt(i % 64)),
            .gain = 0.005,
            .priority = 1.0,
        }, &telemetry);
        mixer.stopAll(8);
        mixer.render(buffer[0 .. 8 * 2], 8, 2, &telemetry);
    }

    mixer.setMasterGain(0.5, 128);
    try mixer.startTestVoice(.{ .frequency_hz = 550.0, .gain = 0.1 }, &telemetry);
    mixer.render(&buffer, 256, 2, &telemetry);

    const snap = telemetry.snapshot();
    try std.testing.expect(snap.peak_abs <= 1.0);
    try std.testing.expect(snap.rms > 0.0);
    try std.testing.expect(snap.clipping_count == 0);
}

test "voice handle updates gain pan lowpass pitch and reverb send" {
    var mixer = Mixer.init(48_000);
    var telemetry: core.TelemetryCounters = .{};
    const handle = try mixer.startTestVoiceWithHandle(.{ .frequency_hz = 440.0, .gain = 0.05 }, &telemetry);
    try mixer.updateVoice(handle, .{
        .gain = 0.2,
        .pan = 0.75,
        .lowpass_hz = 1200.0,
        .pitch_ratio = 1.5,
        .reverb_send = 0.6,
    }, 64);
    const voice = mixer.voices[handle.index];
    try std.testing.expectEqual(handle.generation, voice.generation);
    try std.testing.expect(voice.gain_target == 0.2);
    try std.testing.expect(voice.pan > 0.7);
    try std.testing.expect(voice.lowpass_hz == 1200.0);
    try std.testing.expect(voice.phase_step > voice.base_phase_step);
    try std.testing.expect(voice.reverb_send == 0.6);
}

test "reverb send produces real delayed tail" {
    var mixer = Mixer.init(48_000);
    var telemetry: core.TelemetryCounters = .{};
    mixer.setEffectBus(.reverb, .{ .return_gain = 0.5, .feedback = 0.2, .crossfeed = 0.03 });
    try mixer.startTestVoice(.{ .frequency_hz = 440.0, .gain = 0.2, .reverb_send = 1.0 }, &telemetry);
    var buffer: [reverb_delay_frames * 2]f32 = undefined;
    mixer.render(&buffer, reverb_delay_frames, 2, &telemetry);
    mixer.stopAll(1);
    mixer.render(&buffer, reverb_delay_frames, 2, &telemetry);
    const snap = telemetry.snapshot();
    const bus = mixer.effectBusSnapshot();
    try std.testing.expect(snap.rms > 0.0);
    try std.testing.expect(snap.clipping_count == 0);
    try std.testing.expect(bus.reverb_send_peak > 0.0);
    try std.testing.expect(bus.reverb_return_peak > 0.0);
    try std.testing.expect(bus.reverb_return_gain == 0.5);
    try std.testing.expect(bus.reverb_feedback == 0.2);
}
