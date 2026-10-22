//! TASK013 owned, control-thread-only MusicBank graph materialization.
//! Wire records are the only inputs. Actual Graph admission computes topology,
//! registry, state and latency; no duplicate or permissive graph validator.
const std = @import("std");
const s = @import("music_schema.zig");
pub const bg = @import("sme-bus-graph");
const sc = @import("sme-sidechain");
const ch = @import("sme-channels");
pub const Error = s.BankError || std.mem.Allocator.Error;
/// Fixed Control-owned descriptor/report backing, separate from DSP profile.
pub const metadata_storage_bytes: usize = 256 * 1024;
pub const AdapterDesc = struct {
    music_bus: u32,
    sfx_bus: ?u32,
    legacy_music_bus: ?u32,
    legacy_master_bus: ?u32,
    reverb_bus: ?u32,
};
pub const TargetReport = struct { id: u64, target: bg.Target, info: bg.TargetInfo };
pub const RegistryEntry = struct { target: bg.Target, info: bg.TargetInfo };
pub const EdgeReport = struct { id: u32, compensation_frames: u32 };
pub const CompressorReport = struct { effect_id: u32, snapshot: sc.CompressorSnapshot };
pub const Report = struct {
    graph: bg.GraphSnapshot,
    profile: bg.Profile,
    compressors: []const CompressorReport,
    metadata_bytes: usize,
    /// Graph admission budget, fixed metadata backing and inline Owned value.
    /// This is not an exact allocation-byte total for an embedding owner.
    owned_bytes: usize,
    nodes: []const bg.BusMeterSnapshot,
    edges: []const EdgeReport,
    registry: []const RegistryEntry,
    authored_targets: []const TargetReport,
};
pub const Owned = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    desc: bg.BusGraphDesc,
    profile: bg.Profile,
    adapter: AdapterDesc,
    graph: *bg.Graph,
    report: Report,
    /// Exact live backing allocations only. The containing MusicBank/Generation/
    /// Provider already charges this inline Owned descriptor in its own size.
    /// Call only while owning lifetime, serialized against deinit.
    pub fn backingAllocationBytes(self: *const Owned) error{Overflow}!usize {
        return std.math.add(usize, self.storage.len, try self.graph.allocationBytes());
    }
    pub fn deinit(self: *Owned) void {
        self.graph.deinit(self.allocator);
        self.allocator.free(self.storage);
        self.* = undefined;
    }
    pub fn target(self: *const Owned, id: u64) ?TargetReport {
        for (self.report.authored_targets) |entry| if (entry.id == id) return entry;
        return null;
    }
};
pub const fields = .{ "graph_configs", "graph_nodes", "graph_edges", "graph_matrices", "graph_effects", "graph_presets", "graph_targets" };
fn idx(value: u32, length: usize) Error!usize {
    if (value >= length) return error.InvalidReference;
    return value;
}
fn optionalBus(value: u32, length: usize) Error!?u32 {
    if (value == s.none) return null;
    _ = try idx(value, length);
    return value;
}
fn range(value: s.Range, length: usize) Error!void {
    if (@as(u64, value.first) + value.count > length) return error.InvalidReference;
}
fn translate(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ProfileExceeded, error.InvalidProfile, error.StateBudgetExceeded, error.LatencyExceeded => error.ResourceLimitExceeded,
        error.UnknownBus, error.UnknownEffect, error.UnknownSend, error.UnknownRoute => error.InvalidReference,
        error.InvalidVersion, error.UnsupportedEffectChain, error.UnsupportedChannelLayout => error.UnsupportedOperation,
        else => error.InvalidMusicGraph,
    };
}
fn layout(bus: s.Bus) Error!ch.ChannelLayout {
    const value = ch.ChannelLayout.init(bus.layout, @intCast(@popCount(bus.channel_mask)), bus.channel_mask) catch return error.InvalidRecord;
    if (value.kind == .explicit_mask) return error.UnsupportedOperation;
    return value;
}
pub fn preset(value: s.GraphPreset) sc.SidechainPreset {
    return .{
        .id = value.preset_id,
        .sample_rate = value.sample_rate,
        .detector_mode = @enumFromInt(@intFromEnum(value.detector_mode)),
        .rms_window_frames = value.rms_window_frames,
        .peak_window_frames = value.peak_window_frames,
        .meter_window_frames = value.meter_window_frames,
        .threshold_dbfs = value.threshold_dbfs,
        .ratio = value.ratio,
        .knee_db = value.knee_db,
        .attack_frames = value.attack_frames,
        .hold_frames = value.hold_frames,
        .release_frames = value.release_frames,
        .lookahead_frames = value.lookahead_frames,
        .makeup_db = value.makeup_db,
        .signal_cap_db = value.signal_cap_db,
        .automation_cap_db = value.automation_cap_db,
        .combined_cap_db = value.combined_cap_db,
        .weights = value.weights,
    };
}
fn matrix(value: s.GraphMatrix) Error!ch.Matrix {
    const input = ch.ChannelLayout.canonical(value.input_layout) catch return error.UnsupportedOperation;
    const output = ch.ChannelLayout.canonical(value.output_layout) catch return error.UnsupportedOperation;
    for (value.coefficients, 0..) |row, o| for (row, 0..) |v, i| {
        if (!std.math.isFinite(v) or @abs(v) > 16 or ((o >= output.count or i >= input.count) and v != 0)) return error.InvalidRecord;
    };
    return .{ .input = input, .output = output, .id = value.key.id, .coefficients = value.coefficients };
}
fn decodeTarget(t: s.Tables, value: s.GraphTarget) Error!bg.Target {
    switch (value.kind) {
        .bus_gain, .bus_mute, .channel_gain => {
            _ = try idx(value.bus, t.buses.len);
            if (value.edge != s.none or value.effect != s.none or (value.kind != .channel_gain and value.channel != 0)) return error.InvalidRecord;
            return switch (value.kind) {
                .bus_gain => .{ .bus_gain = value.bus },
                .bus_mute => .{ .bus_mute = value.bus },
                .channel_gain => .{ .channel_gain = .{ .bus = value.bus, .channel = value.channel } },
                else => unreachable,
            };
        },
        .send_gain, .prepared_route => {
            const edge = t.graph_edges[try idx(value.edge, t.graph_edges.len)];
            if (value.bus != s.none or value.effect != s.none or value.channel != 0) return error.InvalidRecord;
            return if (value.kind == .send_gain) .{ .send_gain = value.edge } else .{ .prepared_route = .{ .group = edge.route_group, .edge = value.edge } };
        },
        inline else => |tag| {
            _ = try idx(value.effect, t.graph_effects.len);
            if (value.bus != s.none or value.edge != s.none or value.channel != 0) return error.InvalidRecord;
            return @unionInit(bg.Target, @tagName(tag), value.effect);
        },
    }
}
/// Returns null for the existing simple-bus format. Its producer/runtime retain
/// their existing semantics. In graph mode legacy parent/send/sidechain fields
/// are rejected, never silently promoted into a different signal graph.
pub fn load(allocator: std.mem.Allocator, metadata: s.Metadata, t: s.Tables) Error!?Owned {
    const enabled = metadata.required_capabilities & s.bit(.bus_graph) != 0;
    if (!enabled) {
        inline for (fields) |field| if (@field(t, field).len != 0) return error.InvalidCapabilityDeclaration;
        return null;
    }
    if (metadata.required_capabilities & s.bit(.bus) == 0 or t.graph_configs.len != 1 or t.graph_nodes.len != t.buses.len) return error.InvalidMusicGraph;
    if (t.buses.len == 0 or t.buses.len > bg.max_buses or t.graph_edges.len > bg.max_edges or t.graph_effects.len > bg.max_effects or t.graph_presets.len > bg.max_sidechains or t.graph_targets.len > bg.max_targets or t.graph_matrices.len > bg.max_edges) return error.ResourceLimitExceeded;
    if (t.bus_sends.len != 0 or t.sidechains.len != 0) return error.UnsupportedOperation;
    const config = t.graph_configs[0];
    if (config.platform != metadata.profile or config.platform >= t.platforms.len) return error.InvalidReference;
    if (config.version != bg.version) return error.UnsupportedOperation;
    const profile: bg.Profile = .{
        .buses = config.max_buses,
        .audio_edges = config.max_edges,
        .effects = config.max_effects,
        .effects_per_bus = config.max_effects_per_bus,
        .sidechains = config.max_sidechains,
        .duck_requests = config.max_duck_requests,
        .duck_requests_per_bus = config.max_duck_requests_per_bus,
        .latency_frames = config.max_latency_frames,
        .state_bytes = std.math.cast(usize, config.max_state_bytes) orelse return error.ResourceLimitExceeded,
    };
    profile.validate() catch |err| return translate(err);
    _ = try idx(config.output_bus, t.buses.len);
    _ = try idx(config.music_bus, t.buses.len);
    const adapter: AdapterDesc = .{
        .music_bus = config.music_bus,
        .sfx_bus = try optionalBus(config.sfx_bus, t.buses.len),
        .legacy_music_bus = try optionalBus(config.legacy_music_bus, t.buses.len),
        .legacy_master_bus = try optionalBus(config.legacy_master_bus, t.buses.len),
        .reverb_bus = try optionalBus(config.reverb_bus, t.buses.len),
    };
    const storage = try allocator.alloc(u8, metadata_storage_bytes);
    errdefer allocator.free(storage);
    var backing = std.heap.FixedBufferAllocator.init(storage);
    const a = backing.allocator();
    const nodes = try a.alloc(bg.BusDesc, t.buses.len);
    const effects = try a.alloc(bg.EffectDesc, t.graph_effects.len);
    const edges = try a.alloc(bg.AudioEdgeDesc, t.graph_edges.len);
    var node_seen: [bg.max_buses]bool = @splat(false);
    var effect_seen: [bg.max_effects]bool = @splat(false);
    var preset_seen: [bg.max_sidechains]bool = @splat(false);
    var matrix_seen: [bg.max_edges]bool = @splat(false);
    for (t.graph_presets, 0..) |value, i| {
        for (t.graph_presets[0..i]) |prior| if (prior.preset_id == value.preset_id) return error.InvalidRecord;
    }
    for (t.graph_effects, effects, 0..) |value, *out, i| {
        if (value.bypass > 1) return error.InvalidRecord;
        // Inactive union payload fields have one canonical value.
        if (value.kind != .gain and value.gain != 1 or value.kind != .lowpass and value.cutoff_hz != 20000 or value.kind != .delay and value.delay_frames != 0 or value.kind != .compressor and (value.detector_bus != s.none or value.preset != s.none)) return error.InvalidRecord;
        out.* = .{ .id = @intCast(i), .bypass = value.bypass != 0, .kind = switch (value.kind) {
            .gain => .{ .gain = value.gain },
            .lowpass => .{ .lowpass_hz = value.cutoff_hz },
            .delay => .{ .delay_frames = value.delay_frames },
            .compressor => blk: {
                const detector = try layout(t.buses[try idx(value.detector_bus, t.buses.len)]);
                const pi = try idx(value.preset, t.graph_presets.len);
                preset_seen[pi] = true;
                const p = preset(t.graph_presets[pi]);
                p.validate() catch |err| return translate(err);
                var weight_sum: f64 = 0;
                for (p.weights.?, 0..) |weight, channel| {
                    if (channel >= detector.count and weight != 0) return error.InvalidRecord;
                    weight_sum += weight;
                }
                if (weight_sum <= 0 or !std.math.isFinite(weight_sum)) return error.InvalidRecord;
                break :blk .{ .compressor = .{ .detector_bus = value.detector_bus, .preset = p } };
            },
        } };
    }
    for (t.graph_nodes) |value| {
        const bi = try idx(value.bus, t.buses.len);
        const bus = t.buses[bi];
        if (node_seen[bi] or value.mute > 1) return error.InvalidRecord;
        node_seen[bi] = true;
        if (bus.parent != s.none or bus.sends.count != 0 or bus.sends.first != 0) return error.UnsupportedOperation;
        try range(value.effects, effects.len);
        for (value.effects.first..@as(usize, value.effects.first) + value.effects.count) |ei| {
            if (effect_seen[ei]) return error.InvalidRecord;
            effect_seen[ei] = true;
        }
        const bus_layout = try layout(bus);
        for (value.channel_gains[bus_layout.count..]) |gain| if (gain != 1) return error.InvalidRecord;
        nodes[bi] = .{
            .id = value.bus,
            .layout = bus_layout,
            .gain = sc.dbToLinear(bus.gain_db),
            .mute = value.mute != 0,
            .channel_gains = value.channel_gains,
            .effects = effects[value.effects.first..][0..value.effects.count],
            .input_latency_frames = value.input_latency_frames,
            .meter_window_frames = value.meter_window_frames,
            .duck_mode = @enumFromInt(@intFromEnum(value.duck_mode)),
            .automation_cap_db = value.automation_cap_db,
        };
    }
    for (t.graph_edges, edges, 0..) |value, *out, i| {
        _ = try idx(value.source, nodes.len);
        _ = try idx(value.destination, nodes.len);
        if (value.route_selected > 1) return error.InvalidRecord;
        out.* = .{
            .id = @intCast(i),
            .source = value.source,
            .destination = value.destination,
            .gain = value.gain,
            .route_group = value.route_group,
            .route_selected = value.route_selected != 0,
            .matrix = if (value.matrix == s.none) null else blk: {
                const mi = try idx(value.matrix, t.graph_matrices.len);
                matrix_seen[mi] = true;
                break :blk try matrix(t.graph_matrices[mi]);
            },
        };
    }
    for (effect_seen[0..effects.len]) |seen| if (!seen) return error.InvalidRecord;
    for (preset_seen[0..t.graph_presets.len]) |seen| if (!seen) return error.InvalidRecord;
    for (matrix_seen[0..t.graph_matrices.len]) |seen| if (!seen) return error.InvalidRecord;
    const desc: bg.BusGraphDesc = .{ .schema_version = config.version, .buses = nodes, .audio_edges = edges, .output_bus = config.output_bus };
    const graph = bg.Graph.init(allocator, desc, profile) catch |err| return translate(err);
    errdefer graph.deinit(allocator);
    const registry = try a.alloc(TargetReport, t.graph_targets.len);
    for (t.graph_targets, registry, 0..) |value, *out, i| {
        const target_value = try decodeTarget(t, value);
        for (registry[0..i]) |prior| if (prior.id == value.key.id or std.meta.eql(prior.target, target_value)) return error.InvalidRecord;
        out.* = .{ .id = value.key.id, .target = target_value, .info = graph.targetInfo(target_value) catch |err| return translate(err) };
    }
    const compressor_reports = try a.alloc(CompressorReport, graph.snapshot().sidechains);
    var compressor_index: usize = 0;
    for (effects) |effect| if (effect.kind == .compressor) {
        compressor_reports[compressor_index] = .{ .effect_id = effect.id, .snapshot = graph.compressorSnapshot(effect.id) catch |err| return translate(err) };
        compressor_index += 1;
    };
    const actual_registry = try a.alloc(RegistryEntry, graph.registry().len);
    for (graph.registry(), actual_registry) |value, *out| out.* = .{ .target = value, .info = graph.targetInfo(value) catch |err| return translate(err) };
    const node_reports = try a.alloc(bg.BusMeterSnapshot, nodes.len);
    for (nodes, node_reports) |node, *out| out.* = graph.busMeter(node.id, true) catch |err| return translate(err);
    const edge_reports = try a.alloc(EdgeReport, edges.len);
    for (edges, edge_reports) |edge, *out| out.* = .{ .id = edge.id, .compensation_frames = graph.edgeLatency(edge.id) catch |err| return translate(err) };
    return .{ .allocator = allocator, .storage = storage, .desc = desc, .profile = profile, .adapter = adapter, .graph = graph, .report = .{ .graph = graph.snapshot(), .profile = profile, .compressors = compressor_reports, .metadata_bytes = metadata_storage_bytes, .owned_bytes = graph.snapshot().state_bytes + metadata_storage_bytes + @sizeOf(Owned), .nodes = node_reports, .edges = edge_reports, .registry = actual_registry, .authored_targets = registry } };
}
pub fn validate(allocator: std.mem.Allocator, metadata: s.Metadata, tables: s.Tables) Error!void {
    var owned = try load(allocator, metadata, tables);
    if (owned) |*value| value.deinit();
}

comptime {
    // Eight fixed-buffer allocations, conservatively allowing alignment slack.
    const required = bg.max_buses * (@sizeOf(bg.BusDesc) + @sizeOf(bg.BusMeterSnapshot)) +
        bg.max_effects * @sizeOf(bg.EffectDesc) +
        bg.max_edges * (@sizeOf(bg.AudioEdgeDesc) + @sizeOf(EdgeReport)) +
        bg.max_targets * (@sizeOf(TargetReport) + @sizeOf(RegistryEntry)) +
        bg.max_sidechains * @sizeOf(CompressorReport) + 8 * 64;
    if (required > metadata_storage_bytes) @compileError("increase the explicit graph metadata storage bound");
}
