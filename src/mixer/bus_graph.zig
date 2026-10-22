//! Versioned prepared Bus DAG. No allocation, topology mutation or locks in render.
const std = @import("std");
const ch = @import("sme-channels");
const sc = @import("sme-sidechain");
pub const version: u32 = 1;
pub const max_buses = 32;
pub const max_edges = 128;
pub const max_effects = 64;
pub const max_effects_per_bus = 8;
pub const max_sidechains = 16;
pub const max_duck_requests = 64;
pub const max_latency_frames = 2048;
pub const max_state_bytes = 32 * 1024 * 1024;
pub const max_targets = max_buses * (2 + ch.max_channels) + max_edges * 2 + max_effects * 8;
pub const Error = error{ InvalidVersion, InvalidProfile, InvalidParameter, DuplicateId, UnknownBus, UnknownSend, UnknownEffect, UnknownRoute, InvalidMatrix, Cycle, ProfileExceeded, LatencyExceeded, StateBudgetExceeded, UnsupportedTarget, TargetTypeMismatch, UnsupportedEffectChain, InvalidFrameState };
pub const Profile = struct {
    buses: u16 = max_buses,
    audio_edges: u16 = max_edges,
    effects: u16 = max_effects,
    effects_per_bus: u16 = max_effects_per_bus,
    sidechains: u16 = max_sidechains,
    duck_requests: u16 = max_duck_requests,
    duck_requests_per_bus: u16 = sc.Automation.capacity,
    latency_frames: u32 = max_latency_frames,
    state_bytes: usize = max_state_bytes,
    pub fn validate(self: Profile) Error!void {
        if (self.buses == 0 or self.buses > max_buses or self.audio_edges > max_edges or self.effects > max_effects or self.effects_per_bus > max_effects_per_bus or self.sidechains > max_sidechains or self.duck_requests > max_duck_requests or self.duck_requests_per_bus > sc.Automation.capacity or self.latency_frames > max_latency_frames or self.state_bytes > max_state_bytes) return error.InvalidProfile;
    }
};
pub const CompressorDesc = struct { detector_bus: u32, preset: sc.SidechainPreset = .{} };
pub const EffectKind = union(enum) { gain: f32, lowpass_hz: f32, delay_frames: u32, compressor: CompressorDesc };
pub const EffectDesc = struct { id: u32, bypass: bool = false, kind: EffectKind };
pub const BusDesc = struct {
    id: u32,
    layout: ch.ChannelLayout,
    gain: f32 = 1,
    mute: bool = false,
    channel_gains: [ch.max_channels]f32 = @splat(1),
    effects: []const EffectDesc = &.{},
    input_latency_frames: u32 = 0,
    meter_window_frames: u32 = 4800,
    duck_mode: sc.CombineMode = .strongest,
    automation_cap_db: f32 = 12,
};
pub const AudioEdgeDesc = struct {
    id: u32,
    source: u32,
    destination: u32,
    gain: f32 = 1,
    /// Required for cross-layout sends. Must describe exactly these endpoints.
    matrix: ?ch.Matrix = null,
    /// Nonzero identifies an exclusive group of precompiled alternate routes.
    route_group: u32 = 0,
    route_selected: bool = true,
};
pub const BusGraphDesc = struct { schema_version: u32 = version, sample_rate: u32 = 48000, buses: []const BusDesc, audio_edges: []const AudioEdgeDesc = &.{}, output_bus: u32 };
pub const ChannelTarget = struct { bus: u32, channel: u8 };
pub const PreparedRouteTarget = struct { group: u32, edge: u32 };
pub const Target = union(enum) {
    bus_gain: u32,
    bus_mute: u32,
    channel_gain: ChannelTarget,
    send_gain: u32,
    effect_gain: u32,
    lowpass_hz: u32,
    effect_bypass: u32,
    compressor_threshold_dbfs: u32,
    compressor_ratio: u32,
    compressor_knee_db: u32,
    compressor_attack_frames: u32,
    compressor_hold_frames: u32,
    compressor_release_frames: u32,
    compressor_makeup_db: u32,
    prepared_route: PreparedRouteTarget,
};
pub const Unit = enum { linear_gain, boolean, hz, dbfs, ratio, db, frames, route };
pub const TargetInfo = struct { unit: Unit, minimum: f32, maximum: f32, continuous: bool = true, latency_preserving: bool = true };
pub const Ramp = struct {
    current: f32,
    start: f32,
    target: f32,
    elapsed: u32 = 0,
    duration: u32 = 0,
    /// Only new source-owned layer targets opt into exact endpoints. Ordinary
    /// TASK013 targets retain their historical interpolation recurrence.
    exact_endpoint: bool = false,
    pub fn init(value: f32) Ramp {
        return .{ .current = value, .start = value, .target = value };
    }
    pub fn set(self: *Ramp, value: f32, frames: u32) void {
        self.start = self.current;
        self.target = value;
        self.elapsed = 0;
        self.duration = frames;
        self.exact_endpoint = false;
        if (frames == 0) self.current = value;
    }
    fn setLayer(self: *Ramp, value: f32, frames: u32) void {
        self.set(value, frames);
        self.exact_endpoint = true;
    }
    pub fn next(self: *Ramp) f32 {
        if (self.elapsed < self.duration) {
            self.elapsed += 1;
            self.current = self.start + (self.target - self.start) * (@as(f32, @floatFromInt(self.elapsed)) / @as(f32, @floatFromInt(self.duration)));
            if (self.exact_endpoint) self.current = if (self.elapsed == self.duration) self.target else std.math.clamp(self.current, @min(self.start, self.target), @max(self.start, self.target));
        }
        return self.current;
    }
};
const Lowpass = struct { cutoff: Ramp, state: [ch.max_channels]f32 = @splat(0) };
const CompressorState = struct {
    source: u8,
    dsp: sc.Compressor,
    detector_delay: sc.Delay,
    parameters: [7]Ramp,
};
const Effect = struct {
    id: u32,
    wet: Ramp,
    latency: u32,
    state: union(enum) { gain: Ramp, lowpass: Lowpass, delay: sc.Delay, compressor: CompressorState },
    fn deinit(self: *Effect, allocator: std.mem.Allocator) void {
        switch (self.state) {
            .delay => |*d| d.deinit(allocator),
            .compressor => |*c| {
                c.dsp.deinit(allocator);
                c.detector_delay.deinit(allocator);
            },
            else => {},
        }
    }
};
const Bus = struct {
    id: u32,
    layout: ch.ChannelLayout,
    gain: Ramp,
    audibility: Ramp,
    channel_gains: [ch.max_channels]Ramp,
    first_effect: u8 = 0,
    effect_count: u8 = 0,
    input_latency: u32 = 0,
    output_latency: u32 = 0,
    direct_delay: sc.Delay,
    meter: sc.Meter,
    automation: sc.Automation,
    has_compressor: bool = false,
    automation_db: f32 = 0,
    direct_input: [ch.max_channels]f32 = @splat(0),
    output: [ch.max_channels]f32 = @splat(0),
};
const Edge = struct {
    id: u32,
    source: u8,
    destination: u8,
    gain: Ramp,
    route_gain: Ramp,
    route_group: u32,
    matrix: ch.Matrix,
    alignment_delay: sc.Delay,
    compensation_frames: u32,
};
pub const BusMeterSnapshot = struct {
    bus_id: u32,
    input_latency_frames: u32,
    output_latency_frames: u32,
    automation_reduction_db: f32,
    meter: sc.MeterSnapshot,
};
pub const GraphSnapshot = struct { schema_version: u32 = version, sample_rate: u32, latency_frames: u32, state_bytes: usize, buses: u16, audio_edges: u16, effects: u16, sidechains: u16, rendered_frames: u64, invalid_samples: u64 };
pub const Graph = struct {
    profile: Profile,
    sample_rate: u32,
    buses: [max_buses]Bus = undefined,
    bus_count: u8 = 0,
    edges: [max_edges]Edge = undefined,
    edge_count: u16 = 0,
    effects: [max_effects]Effect = undefined,
    effect_count: u8 = 0,
    sidechain_count: u8 = 0,
    order: [max_buses]u8 = undefined,
    output_index: u8,
    state_bytes: usize = @sizeOf(Graph),
    rendered_frames: u64 = 0,
    invalid_samples: u64 = 0,
    frame_open: bool = false,
    targets: [max_targets]Target = undefined,
    target_count: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, desc: BusGraphDesc, profile: Profile) !*Graph {
        try profile.validate();
        if (desc.schema_version != version) return error.InvalidVersion;
        if (desc.sample_rate != 48000) return error.InvalidParameter;
        if (desc.buses.len == 0 or desc.buses.len > profile.buses or desc.audio_edges.len > profile.audio_edges) return error.ProfileExceeded;
        if (@sizeOf(Graph) > profile.state_bytes) return error.StateBudgetExceeded;
        const self = try allocator.create(Graph);
        self.* = .{ .profile = profile, .sample_rate = desc.sample_rate, .output_index = 0 };
        errdefer self.deinit(allocator);
        // All descriptor and topology checks happen before any sample is processed.
        for (desc.buses, 0..) |bus, i| {
            try bus.layout.validate();
            if (bus.layout.kind == .explicit_mask) return error.InvalidParameter;
            for (desc.buses[0..i]) |previous| if (previous.id == bus.id) return error.DuplicateId;
            try sc.inRange(bus.gain, 0, 4);
            try sc.inRange(bus.automation_cap_db, 0, 96);
            if (bus.effects.len > profile.effects_per_bus) return error.ProfileExceeded;
            if (bus.input_latency_frames > profile.latency_frames) return error.LatencyExceeded;
            var trims: [ch.max_channels]Ramp = undefined;
            for (0..ch.max_channels) |channel| {
                try sc.inRange(bus.channel_gains[channel], 0, 4);
                trims[channel] = Ramp.init(bus.channel_gains[channel]);
            }
            self.buses[i] = .{ .id = bus.id, .layout = bus.layout, .gain = Ramp.init(bus.gain), .audibility = Ramp.init(if (bus.mute) 0 else 1), .channel_gains = trims, .direct_delay = try sc.Delay.init(allocator, 0, bus.layout.count), .meter = try sc.Meter.init(bus.meter_window_frames), .automation = .{ .mode = bus.duck_mode, .cap_db = bus.automation_cap_db } };
            self.bus_count += 1;
        }
        self.output_index = try self.busIndex(desc.output_bus);
        var adjacency: [max_buses][max_buses]bool = @splat(@splat(false));
        for (desc.audio_edges, 0..) |edge, i| {
            for (desc.audio_edges[0..i]) |previous| if (previous.id == edge.id) return error.DuplicateId;
            const source = try self.busIndex(edge.source);
            const destination = try self.busIndex(edge.destination);
            try sc.inRange(edge.gain, 0, 4);
            if (edge.route_group == 0 and !edge.route_selected) return error.InvalidParameter;
            if (edge.route_group != 0) {
                for (desc.audio_edges[0..i]) |previous| if (previous.route_group == edge.route_group) {
                    if (previous.source != edge.source) return error.InvalidParameter;
                    if (previous.route_selected and edge.route_selected) return error.InvalidParameter;
                };
            }
            _ = try validatedMatrix(edge.matrix, self.buses[source].layout, self.buses[destination].layout);
            adjacency[source][destination] = true;
        }
        var count_effects: usize = 0;
        var count_sidechains: usize = 0;
        for (desc.buses, 0..) |bus, destination| {
            var compressor_count: u32 = 0;
            for (bus.effects, 0..) |effect, effect_index| {
                for (desc.buses[0 .. destination + 1], 0..) |prior_bus, bi| {
                    const prior_effects = if (bi == destination) prior_bus.effects[0..effect_index] else prior_bus.effects;
                    for (prior_effects) |prior| if (prior.id == effect.id) return error.DuplicateId;
                }
                count_effects += 1;
                switch (effect.kind) {
                    .gain => |gain| try sc.inRange(gain, 0, 4),
                    .lowpass_hz => |hz| try sc.inRange(hz, 20, 20000),
                    .delay_frames => |frames| if (frames > profile.latency_frames) return error.LatencyExceeded,
                    .compressor => |compressor| {
                        try compressor.preset.validate();
                        if (compressor.preset.sample_rate != desc.sample_rate) return error.InvalidParameter;
                        compressor_count += 1;
                        count_sidechains += 1;
                        if (compressor_count > 1) return error.UnsupportedEffectChain;
                        const source = try self.busIndex(compressor.detector_bus);
                        adjacency[source][destination] = true;
                    },
                }
            }
        }
        if (count_effects > profile.effects or count_sidechains > profile.sidechains) return error.ProfileExceeded;
        try self.topological(adjacency);
        // Cumulative latency includes detector dependencies and every prepared route.
        for (self.order[0..self.bus_count]) |index| {
            const authored = desc.buses[index];
            var arrival = authored.input_latency_frames;
            for (0..self.bus_count) |source| if (adjacency[source][index]) {
                arrival = @max(arrival, self.buses[source].output_latency);
            };
            var cumulative = arrival;
            for (authored.effects) |effect| cumulative = try self.addLatency(cumulative, switch (effect.kind) {
                .delay_frames => |n| n,
                .compressor => |c| c.preset.lookahead_frames,
                else => 0,
            });
            self.buses[index].input_latency = arrival;
            self.buses[index].output_latency = cumulative;
        }
        // Account all requested data bytes before allocating a potentially large DSP state.
        for (desc.buses, 0..) |bus, index| {
            const prepared = &self.buses[index];
            try self.reserveDelay(prepared.input_latency - bus.input_latency_frames, bus.layout.count);
            var latency = prepared.input_latency;
            for (bus.effects) |effect| switch (effect.kind) {
                .delay_frames => |frames| {
                    try self.reserveDelay(frames, bus.layout.count);
                    latency += frames;
                },
                .compressor => |compressor| {
                    const source = try self.busIndex(compressor.detector_bus);
                    try self.reserve(sc.Compressor.stateBytes(compressor.preset, bus.layout.count));
                    try self.reserveDelay(latency - self.buses[source].output_latency, self.buses[source].layout.count);
                    latency += compressor.preset.lookahead_frames;
                },
                else => {},
            };
        }
        for (desc.audio_edges) |edge| {
            const source = try self.busIndex(edge.source);
            const destination = try self.busIndex(edge.destination);
            try self.reserveDelay(self.buses[destination].input_latency - self.buses[source].output_latency, self.buses[destination].layout.count);
        }
        for (desc.buses, 0..) |bus, index| {
            var prepared = &self.buses[index];
            prepared.direct_delay.deinit(allocator);
            // Retain a valid empty delay for cleanup if allocation fails.
            prepared.direct_delay = .{ .data = &.{}, .channels_count = bus.layout.count };
            prepared.direct_delay = try sc.Delay.init(allocator, prepared.input_latency - bus.input_latency_frames, bus.layout.count);
            prepared.first_effect = self.effect_count;
            var latency = prepared.input_latency;
            for (bus.effects) |effect| {
                const state: @FieldType(Effect, "state") = switch (effect.kind) {
                    .gain => |gain| .{ .gain = Ramp.init(gain) },
                    .lowpass_hz => |hz| .{ .lowpass = .{ .cutoff = Ramp.init(hz) } },
                    .delay_frames => |frames| .{ .delay = try sc.Delay.init(allocator, frames, bus.layout.count) },
                    .compressor => |compressor| blk: {
                        const source = try self.busIndex(compressor.detector_bus);
                        var dsp = try sc.Compressor.init(allocator, bus.layout, self.buses[source].layout, compressor.preset);
                        errdefer dsp.deinit(allocator);
                        const detector_delay = try sc.Delay.init(allocator, latency - self.buses[source].output_latency, self.buses[source].layout.count);
                        const p = compressor.preset;
                        prepared.has_compressor = true;
                        prepared.automation.cap_db = @min(prepared.automation.cap_db, p.automation_cap_db);
                        self.sidechain_count += 1;
                        break :blk .{ .compressor = .{ .source = source, .dsp = dsp, .detector_delay = detector_delay, .parameters = .{ Ramp.init(p.threshold_dbfs), Ramp.init(p.ratio), Ramp.init(p.knee_db), Ramp.init(@floatFromInt(p.attack_frames)), Ramp.init(@floatFromInt(p.hold_frames)), Ramp.init(@floatFromInt(p.release_frames)), Ramp.init(p.makeup_db) } } };
                    },
                };
                const effect_latency: u32 = switch (effect.kind) {
                    .delay_frames => |n| n,
                    .compressor => |c| c.preset.lookahead_frames,
                    else => 0,
                };
                self.effects[self.effect_count] = .{ .id = effect.id, .wet = Ramp.init(if (effect.bypass) 0 else 1), .latency = effect_latency, .state = state };
                self.effect_count += 1;
                prepared.effect_count += 1;
                latency += effect_latency;
            }
        }
        for (desc.audio_edges) |edge| {
            const source = try self.busIndex(edge.source);
            const destination = try self.busIndex(edge.destination);
            const compensation = self.buses[destination].input_latency - self.buses[source].output_latency;
            self.edges[self.edge_count] = .{ .id = edge.id, .source = source, .destination = destination, .gain = Ramp.init(edge.gain), .route_gain = Ramp.init(if (edge.route_selected) 1 else 0), .route_group = edge.route_group, .matrix = try validatedMatrix(edge.matrix, self.buses[source].layout, self.buses[destination].layout), .alignment_delay = try sc.Delay.init(allocator, compensation, self.buses[destination].layout.count), .compensation_frames = compensation };
            self.edge_count += 1;
        }
        self.compileRegistry();
        return self;
    }
    /// Exact requested allocation bytes of this heap Graph and its live backing
    /// slices. Unlike snapshot.state_bytes, this excludes admission alignment
    /// rounding. Allocation metadata is immutable after successful init; callers
    /// must own the Graph lifetime and serialize against deinit, never Render.
    pub fn allocationBytes(self: *const Graph) error{Overflow}!usize {
        var bytes: usize = @sizeOf(Graph);
        for (self.buses[0..self.bus_count]) |*bus| try addAllocation(&bytes, bus.direct_delay.data);
        for (self.edges[0..self.edge_count]) |*edge| try addAllocation(&bytes, edge.alignment_delay.data);
        for (self.effects[0..self.effect_count]) |*effect| switch (effect.state) {
            .delay => |*delay| try addAllocation(&bytes, delay.data),
            .compressor => |*compressor| {
                try addAllocation(&bytes, compressor.detector_delay.data);
                try addAllocation(&bytes, compressor.dsp.lookahead.data);
                try addAllocation(&bytes, compressor.dsp.detector.power_ring);
                try addAllocation(&bytes, compressor.dsp.detector.peak_queue);
            },
            else => {},
        };
        return bytes;
    }
    fn addAllocation(bytes: *usize, values: anytype) error{Overflow}!void {
        const requested = try std.math.mul(usize, values.len, @sizeOf(std.meta.Elem(@TypeOf(values))));
        bytes.* = try std.math.add(usize, bytes.*, requested);
    }
    pub fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        for (self.edges[0..self.edge_count]) |*edge| edge.alignment_delay.deinit(allocator);
        for (self.effects[0..self.effect_count]) |*effect| effect.deinit(allocator);
        for (self.buses[0..self.bus_count]) |*bus| bus.direct_delay.deinit(allocator);
        allocator.destroy(self);
    }
    fn reserve(self: *Graph, bytes: usize) Error!void {
        const aligned = std.mem.alignForward(usize, bytes, @alignOf(f64));
        self.state_bytes = std.math.add(usize, self.state_bytes, aligned) catch return error.StateBudgetExceeded;
        if (self.state_bytes > self.profile.state_bytes) return error.StateBudgetExceeded;
    }
    fn reserveDelay(self: *Graph, frames: u32, count: u16) Error!void {
        try self.reserve(@as(usize, frames) * count * @sizeOf(f32));
    }
    fn addLatency(self: *const Graph, a: u32, b: u32) Error!u32 {
        const result = std.math.add(u32, a, b) catch return error.LatencyExceeded;
        if (result > self.profile.latency_frames) return error.LatencyExceeded;
        return result;
    }
    fn topological(self: *Graph, adjacency: [max_buses][max_buses]bool) Error!void {
        var emitted: [max_buses]bool = @splat(false);
        for (0..self.bus_count) |slot| {
            var found: ?u8 = null;
            for (0..self.bus_count) |candidate| {
                if (emitted[candidate]) continue;
                var ready = true;
                for (0..self.bus_count) |source| if (adjacency[source][candidate] and !emitted[source]) {
                    ready = false;
                    break;
                };
                if (ready) {
                    found = @intCast(candidate);
                    break;
                }
            }
            const chosen = found orelse return error.Cycle;
            emitted[chosen] = true;
            self.order[slot] = chosen;
        }
    }
    pub fn busIndex(self: *const Graph, id: u32) Error!u8 {
        for (self.buses[0..self.bus_count], 0..) |bus, i| if (bus.id == id) return @intCast(i);
        return error.UnknownBus;
    }
    fn edgeIndex(self: *const Graph, id: u32) Error!u16 {
        for (self.edges[0..self.edge_count], 0..) |edge, i| if (edge.id == id) return @intCast(i);
        return error.UnknownSend;
    }
    fn effectIndex(self: *const Graph, id: u32) Error!u8 {
        for (self.effects[0..self.effect_count], 0..) |effect, i| if (effect.id == id) return @intCast(i);
        return error.UnknownEffect;
    }

    pub fn beginFrame(self: *Graph) Error!void {
        if (self.frame_open) return error.InvalidFrameState;
        self.frame_open = true;
        for (self.buses[0..self.bus_count]) |*bus| @memset(&bus.direct_input, 0);
    }
    /// The caller consumes/advances a voice or music group once, then adds its PCM.
    pub fn addInputFrame(self: *Graph, bus_id: u32, samples: []const f32, gain: f32) !void {
        if (!self.frame_open) return error.InvalidFrameState;
        const index = try self.busIndex(bus_id);
        const bus = &self.buses[index];
        if (samples.len != bus.layout.count) return error.InvalidParameter;
        try sc.inRange(gain, 0, 4);
        for (samples, 0..) |sample, i| {
            const source = self.finiteOrSilence(sample);
            bus.direct_input[i] = self.finiteOrSilence(bus.direct_input[i] + source * gain);
        }
    }
    pub fn processFrame(self: *Graph, output: []f32) Error!void {
        return self.processFrameAt(output, null);
    }
    pub fn processFrameAt(self: *Graph, output: []f32, render_frame: ?u64) Error!void {
        if (!self.frame_open or output.len != self.buses[self.output_index].layout.count) return error.InvalidFrameState;
        // A tracked lifetime cannot advance on an invented graph-local clock.
        for (self.buses[0..self.bus_count]) |*bus| if (bus.automation.hasTracked() and (render_frame == null or render_frame.? == std.math.maxInt(u64))) return error.InvalidFrameState;
        for (self.order[0..self.bus_count]) |index| {
            var bus = &self.buses[index];
            const count = bus.layout.count;
            var frame: [ch.max_channels]f32 = @splat(0);
            bus.direct_delay.process(bus.direct_input[0..count], frame[0..count]);
            for (self.edges[0..self.edge_count]) |*edge| if (edge.destination == index) {
                const source = &self.buses[edge.source];
                var converted: [ch.max_channels]f32 = @splat(0);
                var aligned: [ch.max_channels]f32 = @splat(0);
                edge.matrix.addFrame(source.output[0..source.layout.count], converted[0..count], edge.route_gain.next());
                self.sanitize(converted[0..count]);
                edge.alignment_delay.process(converted[0..count], aligned[0..count]);
                const gain = edge.gain.next();
                for (0..count) |i| frame[i] += aligned[i] * gain;
            };
            self.sanitize(frame[0..count]);
            bus.automation_db = bus.automation.processAt(render_frame);
            for (self.effects[bus.first_effect..][0..bus.effect_count]) |*effect| {
                const wet = effect.wet.next();
                switch (effect.state) {
                    .gain => |*gain| {
                        const value = 1 + (gain.next() - 1) * wet;
                        for (frame[0..count]) |*x| x.* *= value;
                    },
                    .lowpass => |*filter| {
                        const alpha = 1 - @exp(-2 * std.math.pi * filter.cutoff.next() / @as(f32, @floatFromInt(self.sample_rate)));
                        for (0..count) |i| {
                            filter.state[i] = self.finiteOrSilence(filter.state[i] + alpha * (frame[i] - filter.state[i]));
                            frame[i] += (filter.state[i] - frame[i]) * wet;
                        }
                    },
                    .delay => |*delay| delay.process(frame[0..count], frame[0..count]),
                    .compressor => |*compressor| {
                        const source = &self.buses[compressor.source];
                        var detector_frame: [ch.max_channels]f32 = @splat(0);
                        compressor.detector_delay.process(source.output[0..source.layout.count], detector_frame[0..source.layout.count]);
                        updateCompressor(compressor);
                        compressor.dsp.processWet(detector_frame[0..source.layout.count], frame[0..count], frame[0..count], bus.automation_db, wet);
                    },
                }
                self.sanitize(frame[0..count]);
            }
            const automation_gain = if (bus.has_compressor) 1 else sc.dbToLinear(-bus.automation_db);
            const gain = bus.gain.next() * bus.audibility.next() * automation_gain;
            for (0..count) |i| bus.output[i] = self.finiteOrSilence(frame[i] * gain * bus.channel_gains[i].next());
            bus.meter.observeFrame(bus.output[0..count]);
        }
        @memcpy(output, self.buses[self.output_index].output[0..output.len]);
        self.rendered_frames +|= 1;
        self.frame_open = false;
    }
    fn finiteOrSilence(self: *Graph, value: f32) f32 {
        if (std.math.isFinite(value)) return value;
        self.invalid_samples +|= 1;
        return 0;
    }
    fn sanitize(self: *Graph, samples: []f32) void {
        for (samples) |*sample| sample.* = self.finiteOrSilence(sample.*);
    }
    fn compileRegistry(self: *Graph) void {
        for (self.buses[0..self.bus_count]) |bus| {
            self.addRegistryTarget(.{ .bus_gain = bus.id });
            self.addRegistryTarget(.{ .bus_mute = bus.id });
            for (0..bus.layout.count) |i| self.addRegistryTarget(.{ .channel_gain = .{ .bus = bus.id, .channel = @intCast(i) } });
        }
        for (self.edges[0..self.edge_count]) |edge| {
            self.addRegistryTarget(.{ .send_gain = edge.id });
            if (edge.route_group != 0) self.addRegistryTarget(.{ .prepared_route = .{ .group = edge.route_group, .edge = edge.id } });
        }
        for (self.effects[0..self.effect_count]) |effect| {
            self.addRegistryTarget(.{ .effect_bypass = effect.id });
            switch (effect.state) {
                .gain => self.addRegistryTarget(.{ .effect_gain = effect.id }),
                .lowpass => self.addRegistryTarget(.{ .lowpass_hz = effect.id }),
                .delay => {},
                .compressor => inline for (.{ "compressor_threshold_dbfs", "compressor_ratio", "compressor_knee_db", "compressor_attack_frames", "compressor_hold_frames", "compressor_release_frames", "compressor_makeup_db" }) |field| {
                    self.addRegistryTarget(@unionInit(Target, field, effect.id));
                },
            }
        }
    }
    fn addRegistryTarget(self: *Graph, target: Target) void {
        std.debug.assert(self.target_count < max_targets);
        self.targets[self.target_count] = target;
        self.target_count += 1;
    }
    /// Stable for this prepared graph's entire lifetime; includes only implemented targets.
    pub fn registry(self: *const Graph) []const Target {
        return self.targets[0..self.target_count];
    }
    pub fn targetInfo(self: *const Graph, target: Target) !TargetInfo {
        switch (target) {
            .bus_gain => |id| {
                _ = try self.busIndex(id);
                return .{ .unit = .linear_gain, .minimum = 0, .maximum = 4 };
            },
            .bus_mute => |id| {
                _ = try self.busIndex(id);
                return .{ .unit = .boolean, .minimum = 0, .maximum = 1, .continuous = false };
            },
            .channel_gain => |address| {
                const bus = self.buses[try self.busIndex(address.bus)];
                if (address.channel >= bus.layout.count) return error.InvalidParameter;
                return .{ .unit = .linear_gain, .minimum = 0, .maximum = 4 };
            },
            .send_gain => |id| {
                _ = try self.edgeIndex(id);
                return .{ .unit = .linear_gain, .minimum = 0, .maximum = 4 };
            },
            .effect_gain => |id| {
                if (self.effects[try self.effectIndex(id)].state != .gain) return error.TargetTypeMismatch;
                return .{ .unit = .linear_gain, .minimum = 0, .maximum = 4 };
            },
            .lowpass_hz => |id| {
                if (self.effects[try self.effectIndex(id)].state != .lowpass) return error.TargetTypeMismatch;
                return .{ .unit = .hz, .minimum = 20, .maximum = 20000 };
            },
            .effect_bypass => |id| {
                _ = try self.effectIndex(id);
                return .{ .unit = .boolean, .minimum = 0, .maximum = 1, .continuous = false };
            },
            .prepared_route => |route| {
                const edge = self.edges[try self.edgeIndex(route.edge)];
                if (route.group == 0 or edge.route_group != route.group) return error.UnknownRoute;
                return .{ .unit = .route, .minimum = 1, .maximum = 1, .continuous = false };
            },
            inline else => |id, tag| {
                if (self.effects[try self.effectIndex(id)].state != .compressor) return error.TargetTypeMismatch;
                return switch (tag) {
                    .compressor_threshold_dbfs => .{ .unit = .dbfs, .minimum = -96, .maximum = 0 },
                    .compressor_ratio => .{ .unit = .ratio, .minimum = 1, .maximum = 100 },
                    .compressor_knee_db => .{ .unit = .db, .minimum = 0, .maximum = 24 },
                    .compressor_attack_frames => .{ .unit = .frames, .minimum = 0, .maximum = 48000 },
                    .compressor_hold_frames, .compressor_release_frames => .{ .unit = .frames, .minimum = 0, .maximum = 480000 },
                    .compressor_makeup_db => .{ .unit = .db, .minimum = -24, .maximum = 24 },
                    else => unreachable,
                };
            },
        }
    }
    /// Called at a scheduled frame boundary. Every field is validated before mutation.
    pub fn applyTarget(self: *Graph, target: Target, value: f32, ramp_frames: u32) !void {
        const info = try self.targetInfo(target);
        try sc.inRange(value, info.minimum, info.maximum);
        if ((info.unit == .boolean or info.unit == .frames) and value != @floor(value)) return error.InvalidParameter;
        switch (target) {
            .bus_gain => |id| self.buses[try self.busIndex(id)].gain.set(value, ramp_frames),
            .bus_mute => |id| self.buses[try self.busIndex(id)].audibility.set(1 - value, ramp_frames),
            .channel_gain => |address| self.buses[try self.busIndex(address.bus)].channel_gains[address.channel].set(value, ramp_frames),
            .send_gain => |id| self.edges[try self.edgeIndex(id)].gain.set(value, ramp_frames),
            .effect_gain => |id| self.effects[try self.effectIndex(id)].state.gain.set(value, ramp_frames),
            .lowpass_hz => |id| self.effects[try self.effectIndex(id)].state.lowpass.cutoff.set(value, ramp_frames),
            .effect_bypass => |id| self.effects[try self.effectIndex(id)].wet.set(1 - value, ramp_frames),
            .prepared_route => |route| for (self.edges[0..self.edge_count]) |*edge| {
                if (edge.route_group == route.group) edge.route_gain.set(if (edge.id == route.edge) 1 else 0, ramp_frames);
            },
            inline else => |id, tag| self.effects[try self.effectIndex(id)].state.compressor.parameters[comptime compressorParameterIndex(tag)].set(value, ramp_frames),
        }
    }
    /// Called during whole-phase Render preflight, before ANY phase mutation.
    /// The runtime never installs a prepared prediction as the live start value.
    pub fn validateLayerTargetStart(self: *const Graph, target: Target) !void {
        const info = try self.targetInfo(target);
        switch (target) {
            .channel_gain => |v| try sc.inRange(self.buses[try self.busIndex(v.bus)].channel_gains[v.channel].current, info.minimum, info.maximum),
            .send_gain => |id| try sc.inRange(self.edges[try self.edgeIndex(id)].gain.current, info.minimum, info.maximum),
            .lowpass_hz => |id| try sc.inRange(self.effects[try self.effectIndex(id)].state.lowpass.cutoff.current, info.minimum, info.maximum),
            .effect_bypass => |id| try sc.inRange(self.effects[try self.effectIndex(id)].wet.current, 0, 1),
            .prepared_route => |route| for (self.edges[0..self.edge_count]) |edge| {
                if (edge.route_group == route.group) try sc.inRange(edge.route_gain.current, 0, 1);
            },
            else => return error.UnsupportedTarget,
        }
    }
    /// Source-owned M3 adapter, using the existing live DSP ramps and graph
    /// clock. No predicted seed, delayed command, duplicate DSP or source read.
    pub fn applyLayerTarget(self: *Graph, target: Target, value: f32, ramp_frames: u32) !void {
        const info = try self.targetInfo(target);
        try sc.inRange(value, info.minimum, info.maximum);
        if (info.unit == .boolean and value != @floor(value)) return error.InvalidParameter;
        switch (target) {
            .channel_gain => |v| self.buses[try self.busIndex(v.bus)].channel_gains[v.channel].setLayer(value, ramp_frames),
            .send_gain => |id| self.edges[try self.edgeIndex(id)].gain.setLayer(value, ramp_frames),
            .lowpass_hz => |id| self.effects[try self.effectIndex(id)].state.lowpass.cutoff.setLayer(value, ramp_frames),
            .effect_bypass => |id| {
                const effect = &self.effects[try self.effectIndex(id)];
                if (effect.state != .lowpass) return error.TargetTypeMismatch;
                effect.wet.setLayer(1 - value, ramp_frames);
            },
            .prepared_route => |route| for (self.edges[0..self.edge_count]) |*edge| {
                if (edge.route_group == route.group) edge.route_gain.setLayer(if (edge.id == route.edge) 1 else 0, ramp_frames);
            },
            else => return error.UnsupportedTarget,
        }
    }
    /// Render-only access to actual scalar DSP state. Control admission uses
    /// immutable Catalog metadata and never calls this method.
    pub fn sourceClockValue(self: *const Graph, target: Target) !f32 {
        try self.validateLayerTargetStart(target);
        return switch (target) {
            .channel_gain => |v| self.buses[try self.busIndex(v.bus)].channel_gains[v.channel].current,
            .send_gain => |id| self.edges[try self.edgeIndex(id)].gain.current,
            .lowpass_hz => |id| self.effects[try self.effectIndex(id)].state.lowpass.cutoff.current,
            else => error.UnsupportedTarget,
        };
    }
    /// Source progress selected this sample already. A zero-length write into
    /// the existing Ramp holds that value when normal DSP next() runs, including
    /// paused output frames. It never advances a second graph-clock ramp.
    pub fn applySourceClockValue(self: *Graph, target: Target, value: f32) !void {
        switch (target) {
            .channel_gain, .send_gain, .lowpass_hz => {},
            else => return error.UnsupportedTarget,
        }
        try self.applyLayerTarget(target, value, 0);
    }
    pub fn beginDuck(self: *Graph, bus_id: u32, target: sc.DuckAutomationTarget) !void {
        return self.beginTrackedDuck(bus_id, target, null);
    }
    pub fn beginTrackedDuck(self: *Graph, bus_id: u32, target: sc.DuckAutomationTarget, cell: ?*sc.duck_lifetime.Cell) !void {
        const index = try self.busIndex(bus_id);
        var count: usize = 0;
        for (self.buses[0..self.bus_count]) |*bus| count += bus.automation.count();
        if (count >= self.profile.duck_requests or self.buses[index].automation.count() >= self.profile.duck_requests_per_bus) return error.ProfileExceeded;
        try self.buses[index].automation.beginTracked(target, cell);
    }
    pub fn endDuck(self: *Graph, bus_id: u32, id: u32) !void {
        try self.buses[try self.busIndex(bus_id)].automation.end(id);
    }
    pub fn endTrackedDuck(self: *Graph, bus_id: u32, id: u32, frame: u64) !void {
        try self.buses[try self.busIndex(bus_id)].automation.endAt(id, frame);
    }
    pub fn detachTrackedDucks(self: *Graph, frame: u64) void {
        for (self.buses[0..self.bus_count]) |*bus| bus.automation.detachTracked(frame);
    }
    pub fn busMeter(self: *const Graph, bus_id: u32, partial: bool) !BusMeterSnapshot {
        const bus = self.buses[try self.busIndex(bus_id)];
        return .{ .bus_id = bus_id, .input_latency_frames = bus.input_latency, .output_latency_frames = bus.output_latency, .automation_reduction_db = bus.automation_db, .meter = if (partial) bus.meter.partialSnapshot() else bus.meter.completed };
    }
    pub fn compressorSnapshot(self: *const Graph, effect_id: u32) !sc.CompressorSnapshot {
        const effect = &self.effects[try self.effectIndex(effect_id)];
        if (effect.state != .compressor) return error.TargetTypeMismatch;
        return effect.state.compressor.dsp.snapshot;
    }
    pub fn edgeLatency(self: *const Graph, edge_id: u32) !u32 {
        return self.edges[try self.edgeIndex(edge_id)].compensation_frames;
    }
    pub fn snapshot(self: *const Graph) GraphSnapshot {
        return .{ .sample_rate = self.sample_rate, .latency_frames = self.buses[self.output_index].output_latency, .state_bytes = self.state_bytes, .buses = self.bus_count, .audio_edges = self.edge_count, .effects = self.effect_count, .sidechains = self.sidechain_count, .rendered_frames = self.rendered_frames, .invalid_samples = self.invalid_samples };
    }
};
fn compressorParameterIndex(comptime tag: std.meta.Tag(Target)) usize {
    return switch (tag) {
        .compressor_threshold_dbfs => 0,
        .compressor_ratio => 1,
        .compressor_knee_db => 2,
        .compressor_attack_frames => 3,
        .compressor_hold_frames => 4,
        .compressor_release_frames => 5,
        .compressor_makeup_db => 6,
        else => unreachable,
    };
}
fn updateCompressor(c: *CompressorState) void {
    c.dsp.preset.threshold_dbfs = c.parameters[0].next();
    c.dsp.preset.ratio = c.parameters[1].next();
    c.dsp.preset.knee_db = c.parameters[2].next();
    c.dsp.preset.attack_frames = @intFromFloat(@round(c.parameters[3].next()));
    c.dsp.preset.hold_frames = @intFromFloat(@round(c.parameters[4].next()));
    c.dsp.preset.release_frames = @intFromFloat(@round(c.parameters[5].next()));
    c.dsp.preset.makeup_db = c.parameters[6].next();
}
fn validatedMatrix(authored: ?ch.Matrix, input: ch.ChannelLayout, output: ch.ChannelLayout) !ch.Matrix {
    const matrix = authored orelse if (ch.ChannelLayout.eql(input, output)) try ch.Matrix.compile(input, output) else return error.InvalidMatrix;
    try matrix.input.validate();
    try matrix.output.validate();
    if (!ch.ChannelLayout.eql(input, matrix.input) or !ch.ChannelLayout.eql(output, matrix.output)) return error.InvalidMatrix;
    for (matrix.coefficients) |row| for (row) |value| {
        if (!std.math.isFinite(value) or @abs(value) > 16) return error.InvalidMatrix;
    };
    return matrix;
}
