//! TASK013 prepared graph ownership and immutable render command artifacts.
const std = @import("std");
pub const duck_runtime = @import("sme-duck-runtime");
pub const duck_lifetime = duck_runtime.life;
pub const bg = @import("sme-bus-graph");
pub const graph_clock = @import("sme-layer-graph-clock");
pub const sc = @import("sme-sidechain");
pub const ch = @import("sme-channels");
pub const Error = duck_runtime.Error || bg.Error || sc.Error || ch.Error || std.mem.Allocator.Error || error{ StaleGraph, StaleRoute, StaleBatch, GraphBusy, PreparedCapacity, ConflictingTargets, InvalidState, GenerationExhausted, LayerLaneConflict, InvalidLayerLane };
pub const graph_capacity = 4;
pub const route_capacity = 128;
pub const batch_capacity = 64;
pub const operations_per_batch = 64;
pub const routes_per_layer = 8;
/// Bounded M3 ingress claims. Claims and routes live until their graph retires.
pub const layer_lane_capacity = 16;
pub const LayerSource = struct {
    group_index: u16,
    group_generation: u64,
    layer: u16,
    source_incarnation: u64 = 1,
    pub fn eql(a: LayerSource, b: LayerSource) bool {
        return std.meta.eql(a, b);
    }
};
pub const Usage = struct {
    graphs: usize = 0,
    routes: usize = 0,
    batches: usize = 0,
    claimed_lanes: usize = 0,
    /// Requested fixed allocator sizes, not allocator overhead or full context.
    retained_metadata_bytes: usize = 0,
    /// TASK013 graph state charge, including existing alignment accounting.
    graph_dsp_charged_bytes: usize = 0,
};
pub const LayerLane = struct { source: LayerSource, bus: u32, route: RouteHandle, layout: ch.ChannelLayout };

pub const Handle = struct {
    context: u64 = 0,
    index: u16,
    generation: u64,
    pub fn eql(a: Handle, b: Handle) bool {
        return a.context == b.context and a.index == b.index and a.generation == b.generation;
    }
};
pub const RouteHandle = struct { context: u64 = 0, index: u16, generation: u64 };
pub const BatchHandle = struct { context: u64 = 0, index: u16, generation: u64 };
pub const RouteDesc = struct { bus: u32, gain: f32 = 1, matrix: ?ch.Matrix = null };
pub const PreparedRoute = struct { bus: u32, matrix: ch.Matrix, gain: f32 = 1 };
pub const PreparedRoutes = struct {
    graph_generation: u64,
    source_layout: ch.ChannelLayout,
    count: u8 = 0,
    destinations: [routes_per_layer]PreparedRoute = undefined,
    transfer_bound: f64 = 0,
    detector_dependency: bool = false,
};
pub const AdapterDesc = struct { music_bus: u32, sfx_bus: ?u32 = null, legacy_music_bus: ?u32 = null, legacy_master_bus: ?u32 = null, reverb_bus: ?u32 = null };
pub const Binding = struct {
    graph: *bg.Graph,
    generation: u64,
    music_bus: u32,
    defaults: [4]PreparedRoutes,
    metric_bounds: [4]f64 = @splat(0),
    detector_dependencies: [4]bool = @splat(false),
    sfx: ?PreparedRoutes = null,
    legacy_music: ?PreparedRoutes = null,
    master: ?PreparedRoutes = null,
    reverb: ?PreparedRoutes = null,
    pub fn prepare(graph: *bg.Graph, generation: u64, desc: AdapterDesc) !Binding {
        var result: Binding = .{ .graph = graph, .generation = generation, .music_bus = desc.music_bus, .defaults = undefined };
        for (ch.canonical_layouts, 0..) |layout, i| result.defaults[i] = try canonicalRoute(graph, generation, layout, desc.music_bus);
        if (desc.sfx_bus) |id| result.sfx = try canonicalRoute(graph, generation, ch.stereo, id);
        if (desc.legacy_music_bus) |id| result.legacy_music = try canonicalRoute(graph, generation, ch.stereo, id);
        if (desc.legacy_master_bus) |id| result.master = try canonicalRoute(graph, generation, ch.stereo, id);
        if (desc.reverb_bus) |id| result.reverb = try canonicalRoute(graph, generation, ch.stereo, id);
        const catalog = try Catalog.init(graph);
        for (&result.defaults, 0..) |*routes, i| {
            routes.transfer_bound = try catalog.routeBound(routes);
            routes.detector_dependency = try catalog.routesDetectorDependency(routes);
            result.metric_bounds[i] = routes.transfer_bound;
            result.detector_dependencies[i] = routes.detector_dependency;
        }
        inline for (.{ "sfx", "legacy_music", "master", "reverb" }) |field| {
            if (@field(result, field)) |*routes| {
                routes.transfer_bound = try catalog.routeBound(routes);
                routes.detector_dependency = try catalog.routesDetectorDependency(routes);
            }
        }
        return result;
    }
    pub const LegacyBus = enum { sfx, music, master };
    /// Conservative over admitted future send updates: a detector-fed reverb
    /// return protects all legacy sources, even while their send is currently zero.
    pub fn legacyDetectorDependency(self: *const Binding, bus: LegacyBus) bool {
        const direct = switch (bus) {
            .sfx => self.sfx,
            .music => self.legacy_music,
            .master => self.master,
        };
        return (if (direct) |routes| routes.detector_dependency else false) or
            (if (self.reverb) |routes| routes.detector_dependency else false);
    }
};
pub const GraphBinding = Binding;
fn canonicalRoute(graph: *const bg.Graph, generation: u64, source: ch.ChannelLayout, bus: u32) !PreparedRoutes {
    const destination = graph.buses[try graph.busIndex(bus)].layout;
    var result: PreparedRoutes = .{ .graph_generation = generation, .source_layout = source, .count = 1 };
    result.destinations[0] = .{ .bus = bus, .matrix = try ch.Matrix.compile(source, destination) };
    return result;
}
pub const TargetWrite = struct { target: bg.Target, value: f32, ramp_frames: u32 = 0 };
pub const DuckBegin = struct { bus: u32, target: sc.DuckAutomationTarget };
pub const DuckEnd = struct { bus: u32, id: u32 };
pub const Operation = union(enum) { target: TargetWrite, begin_duck: DuckBegin, end_duck: DuckEnd };
pub const CatalogTarget = struct { target: bg.Target, info: bg.TargetInfo };
/// Physical writer classes, independent of target validity. In particular, an
/// invalid channel/effect parameter or route alternative must not bypass a lane
/// claim before the ordinary target registry reports its validation error.
pub const OwnershipKey = union(enum) { bus: u32, send: u32, effect: u32, route_group: u32 };
pub const TargetOwner = struct { key: OwnershipKey, bus: u32 };
pub const ownership_capacity = bg.max_buses + 2 * bg.max_edges + bg.max_effects;
pub const BusCatalog = struct { id: u32, layout: ch.ChannelLayout, input_latency: u32, output_latency: u32, effect_id: ?u32 = null, initial_compressor: ?sc.CompressorSnapshot = null };
pub const Catalog = struct {
    buses: [bg.max_buses]BusCatalog = undefined,
    bus_count: u8 = 0,
    targets: [bg.max_targets]CatalogTarget = undefined,
    target_count: u16 = 0,
    /// Copied once while the graph is quiescent; never contains live DSP state.
    /// One bus/effect entry and two entries per edge (send and route group).
    owners: [ownership_capacity]TargetOwner = undefined,
    owner_count: u16 = 0,
    /// Maximum output-channel sensitivity to one input channel.
    detector_dependency: [bg.max_buses]bool = @splat(false),
    sensitivity: [bg.max_buses][8][8]f64 = @splat(@splat(@splat(0))),
    output_layout: ch.ChannelLayout,
    latency_frames: u32,
    state_bytes: usize,
    profile: bg.Profile,
    pub fn busIndex(self: *const Catalog, id: u32) Error!usize {
        for (self.buses[0..self.bus_count], 0..) |b, i| if (b.id == id) return i;
        return error.UnknownBus;
    }
    pub fn targetInfo(self: *const Catalog, target: bg.Target) Error!bg.TargetInfo {
        for (self.targets[0..self.target_count]) |entry| if (std.meta.eql(entry.target, target)) return entry.info;
        return error.UnsupportedTarget;
    }
    fn addOwner(self: *Catalog, key: OwnershipKey, bus: u32) void {
        std.debug.assert(self.owner_count < ownership_capacity);
        self.owners[self.owner_count] = .{ .key = key, .bus = bus };
        self.owner_count += 1;
    }
    /// Control can call this after publication. Only immutable Catalog bytes
    /// are read; neither Graph lookup methods nor its live aggregates are used.
    fn owns(self: *const Catalog, key: OwnershipKey, bus: u32) bool {
        for (self.owners[0..self.owner_count]) |entry| {
            if (entry.bus == bus and std.meta.eql(entry.key, key)) return true;
        }
        return false;
    }
    /// Preparation-only: caller has not published the graph to Render yet.
    fn init(graph: *const bg.Graph) !Catalog {
        var result: Catalog = .{ .output_layout = graph.buses[graph.output_index].layout, .latency_frames = graph.snapshot().latency_frames, .state_bytes = graph.snapshot().state_bytes, .profile = graph.profile };
        result.bus_count = graph.bus_count;
        for (graph.buses[0..graph.bus_count], 0..) |bus, i| {
            result.buses[i] = .{ .id = bus.id, .layout = bus.layout, .input_latency = bus.input_latency, .output_latency = bus.output_latency };
            result.addOwner(.{ .bus = bus.id }, bus.id);
            for (graph.effects[bus.first_effect..][0..bus.effect_count]) |effect| {
                result.addOwner(.{ .effect = effect.id }, bus.id);
                if (effect.state == .compressor) {
                    result.buses[i].effect_id = effect.id;
                    result.buses[i].initial_compressor = try graph.compressorSnapshot(effect.id);
                }
            }
        }
        for (graph.edges[0..graph.edge_count]) |edge| {
            const bus = graph.buses[edge.source].id;
            result.addOwner(.{ .send = edge.id }, bus);
            // Include zero to preserve prior alias rejection for invalid route
            // requests on ordinary edges. The registry still rejects group 0.
            result.addOwner(.{ .route_group = edge.route_group }, bus);
        }
        for (graph.registry()) |target| {
            result.targets[result.target_count] = .{ .target = target, .info = try graph.targetInfo(target) };
            result.target_count += 1;
        }
        // Any detector source and its upstream dependencies must keep producing.
        for (graph.effects[0..graph.effect_count]) |effect| if (effect.state == .compressor) {
            result.detector_dependency[effect.state.compressor.source] = true;
        };
        var dependency_at: usize = graph.bus_count;
        while (dependency_at > 0) {
            dependency_at -= 1;
            const index = graph.order[dependency_at];
            if (!result.detector_dependency[index]) continue;
            for (graph.edges[0..graph.edge_count]) |edge| if (edge.destination == index) {
                result.detector_dependency[edge.source] = true;
            };
        }
        var downstream: [bg.max_buses][8][8]f64 = @splat(@splat(@splat(0)));
        for (0..result.output_layout.count) |i| downstream[graph.output_index][i][i] = 1;
        var at: usize = graph.bus_count;
        while (at > 0) {
            at -= 1;
            const index = graph.order[at];
            const bus = graph.buses[index];
            var factor: f64 = 16; // admitted bus gain4 and channel gain4
            for (graph.effects[bus.first_effect..][0..bus.effect_count]) |effect| factor *= switch (effect.state) {
                .gain => @as(f64, 4),
                .compressor => std.math.pow(f64, 10, 24.0 / 20.0),
                else => @as(f64, 1),
            };
            for (0..result.output_layout.count) |o| for (0..bus.layout.count) |i| {
                result.sensitivity[index][o][i] = downstream[index][o][i] * factor;
            };
            for (graph.edges[0..graph.edge_count]) |edge| if (edge.destination == index) {
                for (0..result.output_layout.count) |o| for (0..edge.matrix.input.count) |i| {
                    var sum: f64 = 0;
                    for (0..bus.layout.count) |d| sum += result.sensitivity[index][o][d] * @abs(@as(f64, edge.matrix.coefficients[d][i]));
                    downstream[edge.source][o][i] += sum * 4; // all future send/route values
                };
            };
        }
        return result;
    }
    pub fn prepareRoutes(self: *const Catalog, generation: u64, source: ch.ChannelLayout, descriptions: []const RouteDesc) !PreparedRoutes {
        try source.validate();
        if (source.kind == .explicit_mask or descriptions.len == 0 or descriptions.len > routes_per_layer) return error.InvalidParameter;
        var result: PreparedRoutes = .{ .graph_generation = generation, .source_layout = source, .count = @intCast(descriptions.len) };
        for (descriptions, 0..) |desc, i| {
            const destination = self.buses[try self.busIndex(desc.bus)].layout;
            try sc.inRange(desc.gain, 0, 4);
            const matrix = desc.matrix orelse if (ch.ChannelLayout.eql(source, destination)) try ch.Matrix.compile(source, destination) else return error.InvalidMatrix;
            if (!ch.ChannelLayout.eql(matrix.input, source) or !ch.ChannelLayout.eql(matrix.output, destination)) return error.InvalidMatrix;
            for (matrix.coefficients) |row| for (row) |v| {
                if (!std.math.isFinite(v) or @abs(v) > 16) return error.InvalidMatrix;
            };
            result.destinations[i] = .{ .bus = desc.bus, .matrix = matrix, .gain = desc.gain };
        }
        result.transfer_bound = try self.routeBound(&result);
        result.detector_dependency = try self.routesDetectorDependency(&result);
        return result;
    }
    pub fn routesDetectorDependency(self: *const Catalog, routes: *const PreparedRoutes) Error!bool {
        for (routes.destinations[0..routes.count]) |route| if (self.detector_dependency[try self.busIndex(route.bus)]) return true;
        return false;
    }
    pub fn routeBound(self: *const Catalog, routes: *const PreparedRoutes) Error!f64 {
        var output: [8]f64 = @splat(0);
        for (routes.destinations[0..routes.count]) |route| {
            const bus = try self.busIndex(route.bus);
            for (0..self.output_layout.count) |o| for (0..routes.source_layout.count) |i| {
                for (0..route.matrix.output.count) |d| output[o] += self.sensitivity[bus][o][d] * @abs(@as(f64, route.matrix.coefficients[d][i])) * route.gain;
            };
        }
        var bound: f64 = 0;
        for (output) |value| bound = @max(bound, value);
        if (!std.math.isFinite(bound)) return error.InvalidParameter;
        return bound * 4; // final legacy Master can reach4
    }
};
pub const RouteSlot = struct { layer_source: ?LayerSource = null, content_hash: [32]u8 = @splat(0), graph: Handle, generation: u64, references: u16 = 0, prepared: PreparedRoutes };
pub const Batch = struct { tracked_duck: ?duck_runtime.Tracked = null, layer_source: ?LayerSource = null, content_hash: [32]u8 = @splat(0), graph: Handle, generation: u64, references: u16 = 0, count: u8, operations: [operations_per_batch]Operation = undefined };
pub const Observation = struct { graph: Handle, origin: u64, frame: u64, graph_rendered_frames: u64, invalid_samples: u64, bus_id: u32, input_latency: u32, output_latency: u32, partial: sc.MeterSnapshot, completed: sc.MeterSnapshot, automation_db: f32, compressor: ?sc.CompressorSnapshot, skipped_windows: u64, skipped_compressor_windows: u64 = 0, skipped_detector_windows: u64 = 0 };
const ObservationCell = struct {
    sequence: std.atomic.Value(u64) = .init(0),
    words: [82]std.atomic.Value(u64) = @splat(.init(0)),
    last_completed_end: u64 = 0,
    last_comp_end: u64 = 0,
    last_detector_end: u64 = 0,
    skipped_comp: u64 = 0,
    skipped_detector: u64 = 0,
    skipped: u64 = 0,
};
pub const PreparedGraph = struct {
    content_hash: [32]u8 = @splat(0),
    generation: u64,
    references: u16 = 0,
    graph: *bg.Graph,
    binding: Binding,
    catalog: Catalog,
    active: std.atomic.Value(bool) = .init(false),
    activated: bool = false,
    routes_sealed: bool = false,
    /// Atomic DSP-key reservations. Render never scans mutable Control-owned
    /// lifetime identities while deciding whether a generic operation aliases.
    tracked_duck_keys: [duck_lifetime.capacity]std.atomic.Value(u64) = @splat(.init(0)),
    layer_lanes: [layer_lane_capacity]LayerLane = undefined,
    layer_lane_count: u8 = 0,
    origin: u64 = 0,
    observations: [bg.max_buses]ObservationCell = @splat(.{}),
};
pub const Trial = struct {
    automations: [bg.max_buses]sc.Automation = undefined,
    seen: [operations_per_batch * 8]bg.Target = undefined,
    seen_count: u16 = 0,
    pub fn init(graph: *const bg.Graph) Trial {
        var result: Trial = .{};
        for (graph.buses[0..graph.bus_count], 0..) |bus, i| result.automations[i] = bus.automation;
        return result;
    }
};
var next_context: std.atomic.Value(u64) = .init(1);
pub const Manager = struct {
    identity: u64,
    allocator: std.mem.Allocator,
    graphs: [graph_capacity]?*PreparedGraph = @splat(null),
    routes: [route_capacity]?*RouteSlot = @splat(null),
    batches: [batch_capacity]?*Batch = @splat(null),
    ducks: duck_runtime.Manager = .{},
    next_generation: u64 = 1,
    dsp_bytes: usize = 0,
    pub fn usage(self: *const Manager) Usage {
        var result: Usage = .{ .retained_metadata_bytes = @sizeOf(Manager), .graph_dsp_charged_bytes = self.dsp_bytes };
        for (self.graphs) |entry| if (entry) |graph| {
            result.graphs += 1;
            result.claimed_lanes += graph.layer_lane_count;
            result.retained_metadata_bytes += @sizeOf(PreparedGraph);
        };
        for (self.routes) |entry| if (entry != null) {
            result.routes += 1;
            result.retained_metadata_bytes += @sizeOf(RouteSlot);
        };
        for (self.batches) |entry| if (entry != null) {
            result.batches += 1;
            result.retained_metadata_bytes += @sizeOf(Batch);
        };
        return result;
    }
    pub fn create(allocator: std.mem.Allocator) !*Manager {
        const self = try allocator.create(Manager);
        var identity = next_context.load(.monotonic);
        while (true) {
            if (identity == 0 or identity == std.math.maxInt(u64)) {
                allocator.destroy(self);
                return error.GenerationExhausted;
            }
            identity = next_context.cmpxchgWeak(identity, identity + 1, .monotonic, .monotonic) orelse break;
        }
        self.* = .{ .allocator = allocator, .identity = identity };
        return self;
    }
    fn generation(self: *Manager) Error!u64 {
        if (self.next_generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        defer self.next_generation += 1;
        return self.next_generation;
    }
    pub fn get(self: *const Manager, handle: Handle) Error!*PreparedGraph {
        if (handle.context != self.identity or handle.index >= self.graphs.len) return error.StaleGraph;
        const slot = self.graphs[handle.index] orelse return error.StaleGraph;
        if (slot.generation != handle.generation) return error.StaleGraph;
        return slot;
    }
    pub fn route(self: *const Manager, handle: RouteHandle) Error!*RouteSlot {
        if (handle.context != self.identity or handle.index >= self.routes.len) return error.StaleRoute;
        const slot = self.routes[handle.index] orelse return error.StaleRoute;
        if (slot.generation != handle.generation) return error.StaleRoute;
        _ = try self.get(slot.graph);
        return slot;
    }
    pub fn batch(self: *const Manager, handle: BatchHandle) Error!*Batch {
        if (handle.context != self.identity or handle.index >= self.batches.len) return error.StaleBatch;
        const slot = self.batches[handle.index] orelse return error.StaleBatch;
        if (slot.generation != handle.generation) return error.StaleBatch;
        _ = try self.get(slot.graph);
        return slot;
    }
    pub fn prepareGraph(self: *Manager, desc: bg.BusGraphDesc, profile: bg.Profile, adapters: AdapterDesc) !Handle {
        const index = for (self.graphs, 0..) |slot, i| {
            if (slot == null) break i;
        } else return error.PreparedCapacity;
        const graph = try bg.Graph.init(self.allocator, desc, profile);
        errdefer graph.deinit(self.allocator);
        if (graph.snapshot().state_bytes > bg.max_state_bytes - self.dsp_bytes) return error.StateBudgetExceeded;
        const gen = try self.generation();
        const prepared = try self.allocator.create(PreparedGraph);
        errdefer self.allocator.destroy(prepared);
        prepared.* = .{ .generation = gen, .graph = graph, .binding = try Binding.prepare(graph, gen, adapters), .catalog = try Catalog.init(graph) };
        for (&prepared.binding.defaults, 0..) |*r, i| {
            r.transfer_bound = try prepared.catalog.routeBound(r);
            r.detector_dependency = try prepared.catalog.routesDetectorDependency(r);
            prepared.binding.metric_bounds[i] = r.transfer_bound;
            prepared.binding.detector_dependencies[i] = r.detector_dependency;
        }
        inline for (.{ "sfx", "legacy_music", "master", "reverb" }) |field| {
            if (@field(prepared.binding, field)) |*r| {
                r.transfer_bound = try prepared.catalog.routeBound(r);
                r.detector_dependency = try prepared.catalog.routesDetectorDependency(r);
            }
        }
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, .{ .desc = desc, .profile = profile, .adapters = adapters }, .{});
        defer self.allocator.free(encoded);
        std.crypto.hash.sha2.Sha256.hash(encoded, &prepared.content_hash, .{});
        self.graphs[index] = prepared;
        self.dsp_bytes += graph.snapshot().state_bytes;
        return .{ .context = self.identity, .index = @intCast(index), .generation = gen };
    }
    pub fn prepareRoutes(self: *Manager, graph: Handle, source: ch.ChannelLayout, routes: []const RouteDesc) !RouteHandle {
        const slot = try self.get(graph);
        if (slot.routes_sealed or slot.active.load(.acquire)) return error.GraphBusy;
        const index = for (self.routes, 0..) |r, i| {
            if (r == null) break i;
        } else return error.PreparedCapacity;
        for (routes) |desc| for (slot.layer_lanes[0..slot.layer_lane_count]) |lane| {
            if (desc.bus == lane.bus) return error.LayerLaneConflict;
        };
        const value = try slot.catalog.prepareRoutes(graph.generation, source, routes);
        const gen = try self.generation();
        const route_slot = try self.allocator.create(RouteSlot);
        route_slot.* = .{ .graph = graph, .generation = gen, .prepared = value };
        errdefer self.allocator.destroy(route_slot);
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, .{ .graph = slot.content_hash, .source = source, .routes = value.destinations[0..value.count] }, .{});
        defer self.allocator.free(encoded);
        std.crypto.hash.sha2.Sha256.hash(encoded, &route_slot.content_hash, .{});
        for (ch.canonical_layouts, 0..) |layout, i| if (ch.ChannelLayout.eql(source, layout)) {
            slot.binding.metric_bounds[i] = @max(slot.binding.metric_bounds[i], value.transfer_bound);
            slot.binding.detector_dependencies[i] = slot.binding.detector_dependencies[i] or value.detector_dependency;
        };
        self.routes[index] = route_slot;
        return .{ .context = self.identity, .index = @intCast(index), .generation = gen };
    }
    /// Claim a graph ingress before publication. No graph input edge, default
    /// adapter, prior prepared route or prior target batch may alias the lane.
    /// Raw target/route APIs cannot subsequently write or inject this lane.
    pub fn prepareLayerLane(self: *Manager, graph: Handle, source: LayerSource, layout: ch.ChannelLayout, bus_id: u32, targets: []const bg.Target) !LayerLane {
        const slot = try self.get(graph);
        if (slot.routes_sealed or slot.active.load(.acquire)) return error.GraphBusy;
        if (source.group_generation == 0 or source.source_incarnation == 0 or source.layer >= 16) return error.InvalidLayerLane;
        if (slot.layer_lane_count == layer_lane_capacity) return error.PreparedCapacity;
        const bus_index = try slot.catalog.busIndex(bus_id);
        if (!ch.ChannelLayout.eql(slot.catalog.buses[bus_index].layout, layout)) return error.InvalidLayerLane;
        for (slot.layer_lanes[0..slot.layer_lane_count]) |lane| {
            if (lane.source.eql(source) or lane.bus == bus_id) return error.LayerLaneConflict;
        }
        for (targets) |target| {
            const info = try slot.catalog.targetInfo(target);
            if (!info.latency_preserving or !operationOnBus(&slot.catalog, .{ .target = .{ .target = target, .value = info.minimum } }, bus_id)) return error.InvalidLayerLane;
        }
        for (slot.graph.edges[0..slot.graph.edge_count]) |edge| {
            if (edge.destination == bus_index) return error.InvalidLayerLane;
            if (edge.source == bus_index and edge.route_group != 0) {
                for (slot.graph.edges[0..slot.graph.edge_count]) |other| {
                    if (other.route_group == edge.route_group and other.source != bus_index) return error.LayerLaneConflict;
                }
            }
        }
        for (&slot.binding.defaults) |*routes| if (routesContain(routes, bus_id)) return error.LayerLaneConflict;
        inline for (.{ "sfx", "legacy_music", "master", "reverb" }) |field| {
            if (@field(slot.binding, field)) |routes| if (routesContain(&routes, bus_id)) return error.LayerLaneConflict;
        }
        for (self.routes) |maybe_route| if (maybe_route) |r| {
            if (r.graph.eql(graph) and routesContain(&r.prepared, bus_id)) return error.LayerLaneConflict;
        };
        for (self.batches) |maybe_batch| if (maybe_batch) |b| {
            if (b.graph.eql(graph)) for (b.operations[0..b.count]) |op| {
                if (operationOnBus(&slot.catalog, op, bus_id)) return error.LayerLaneConflict;
            };
        };
        const route_handle = try self.prepareRoutes(graph, layout, &.{.{ .bus = bus_id }});
        const route_slot = try self.route(route_handle);
        route_slot.layer_source = source;
        var ownership_hash = std.crypto.hash.sha2.Sha256.init(.{});
        ownership_hash.update(&route_slot.content_hash);
        var ownership_bytes: [12]u8 = undefined;
        std.mem.writeInt(u16, ownership_bytes[0..2], source.group_index, .little);
        std.mem.writeInt(u64, ownership_bytes[2..10], source.group_generation, .little);
        std.mem.writeInt(u16, ownership_bytes[10..12], source.layer, .little);
        ownership_hash.update(&ownership_bytes);
        if (source.source_incarnation != 1) {
            ownership_hash.update("GROUP-SOURCE-INCARNATION-V1");
            var incarnation: [8]u8 = undefined;
            std.mem.writeInt(u64, &incarnation, source.source_incarnation, .little);
            ownership_hash.update(&incarnation);
        }
        ownership_hash.final(&route_slot.content_hash);
        // Commit only after the last fallible preparation. The claim cannot be
        // detached independently; graph teardown owns the route and lane record.
        const lane: LayerLane = .{ .source = source, .bus = bus_id, .route = route_handle, .layout = layout };
        slot.layer_lanes[slot.layer_lane_count] = lane;
        slot.layer_lane_count += 1;
        return lane;
    }
    pub fn layerLane(self: *const Manager, graph: Handle, source: LayerSource) !LayerLane {
        const slot = try self.get(graph);
        for (slot.layer_lanes[0..slot.layer_lane_count]) |lane| if (lane.source.eql(source)) return lane;
        return error.InvalidLayerLane;
    }
    pub fn validateLayerRoute(self: *const Manager, handle: RouteHandle, source: LayerSource, ramp_frames: u32) !void {
        const r = try self.route(handle);
        const slot = try self.get(r.graph);
        if (r.layer_source) |owner| if (!owner.eql(source) or ramp_frames != 0) return error.LayerLaneConflict;
        for (slot.layer_lanes[0..slot.layer_lane_count]) |lane| if (lane.source.eql(source)) {
            if (lane.route.index != handle.index or lane.route.generation != handle.generation or ramp_frames != 0) return error.LayerLaneConflict;
        };
    }
    /// Control-only immutable ownership/range validation, before any producer
    /// or consumer program allocation. Never reads the live Graph aggregate.
    pub fn validateGraphClockWrites(self: *const Manager, graph: Handle, source: LayerSource, writes: []const graph_clock.Write) !void {
        const slot = try self.get(graph);
        const lane = try self.layerLane(graph, source);
        if (writes.len == 0 or writes.len > graph_clock.max_targets) return error.InvalidParameter;
        for (writes, 0..) |write, i| {
            _ = try graph_clock.scalarRange(write.target);
            const info = try slot.catalog.targetInfo(write.target);
            if (!info.latency_preserving or !operationOnBus(&slot.catalog, .{ .target = .{ .target = write.target, .value = write.value } }, lane.bus)) return error.InvalidLayerLane;
            try sc.inRange(write.value, info.minimum, info.maximum);
            for (writes[0..i]) |other| if (sameTarget(other.target, write.target)) return error.ConflictingTargets;
        }
    }
    pub const DuckLease = struct { handle: duck_lifetime.Handle, begin_batch: BatchHandle, end_batch: BatchHandle };
    fn graphKey(graph: Handle) duck_lifetime.Graph {
        return .{ .context = graph.context, .index = graph.index, .generation = graph.generation };
    }
    fn batchHandle(key: duck_lifetime.Graph) BatchHandle {
        return .{ .context = key.context, .index = key.index, .generation = key.generation };
    }
    fn validateDuckOwner(self: *const Manager, graph: Handle, operation: Operation, tracked: ?duck_runtime.Tracked) !void {
        const key = switch (operation) {
            .begin_duck => |v| .{ v.bus, v.target.id },
            .end_duck => |v| .{ v.bus, v.id },
            else => return,
        };
        if (self.ducks.collision(graphKey(graph), key[0], key[1])) |owner| {
            if (tracked == null or !tracked.?.handle.eql(owner)) return error.DuckBusy;
        } else if (tracked != null) return error.StaleDuck;
    }
    /// Internal preparation only: ControlRuntime has already reserved a common
    /// cleanup credit. Both immutable batches and the whole-graph lease exist
    /// before a begin command can be admitted or published.
    pub fn prepareTrackedDuck(self: *Manager, graph: Handle, identity: duck_lifetime.Identity, target: sc.DuckAutomationTarget) !DuckLease {
        if (!std.meta.eql(identity.graph, graphKey(graph)) or identity.dsp_id != target.id) return error.InvalidDuckIdentity;
        const graph_slot = try self.get(graph);
        try target.validate();
        const handle = try self.ducks.prepare(identity);
        errdefer _ = self.ducks.release(handle, 0) catch unreachable;
        const was_sealed = graph_slot.routes_sealed;
        try self.retainGraph(graph);
        errdefer {
            self.releaseGraphReference(graph);
            graph_slot.routes_sealed = was_sealed;
        }
        const begin = try self.prepareBatchOwned(graph, null, &.{.{ .begin_duck = .{ .bus = identity.bus, .target = target } }}, .{ .handle = handle, .kind = .begin });
        errdefer {
            (self.batch(begin) catch unreachable).tracked_duck = null;
            self.releaseBatch(begin) catch unreachable;
        }
        const end = try self.prepareBatchOwned(graph, null, &.{.{ .end_duck = .{ .bus = identity.bus, .id = target.id } }}, .{ .handle = handle, .kind = .end });
        const slot = try self.ducks.get(handle);
        slot.begin_batch = .{ .context = begin.context, .index = begin.index, .generation = begin.generation };
        slot.end_batch = .{ .context = end.context, .index = end.index, .generation = end.generation };
        (try self.get(graph)).tracked_duck_keys[handle.index].store((@as(u64, identity.bus) << 32) | identity.dsp_id, .release);
        return .{ .handle = handle, .begin_batch = begin, .end_batch = end };
    }
    pub fn releaseTrackedDuck(self: *Manager, handle: duck_lifetime.Handle, frontier: u64) !void {
        try self.ducks.releasable(handle, frontier);
        const slot = try self.ducks.get(handle);
        const begin = batchHandle(slot.begin_batch.?);
        const end = batchHandle(slot.end_batch.?);
        const b = try self.batch(begin);
        const e = try self.batch(end);
        if (b.references != 0 or e.references != 0) return error.DuckDrainPending;
        const identity = try self.ducks.release(handle, frontier);
        (self.get(b.graph) catch unreachable).tracked_duck_keys[handle.index].store(0, .release);
        b.tracked_duck = null;
        e.tracked_duck = null;
        self.releaseBatch(begin) catch unreachable;
        self.releaseBatch(end) catch unreachable;
        self.releaseGraphReference(.{ .context = identity.graph.context, .index = identity.graph.index, .generation = identity.graph.generation });
    }
    pub fn prepareLayerBatch(self: *Manager, graph: Handle, source: LayerSource, operations: []const Operation) !BatchHandle {
        _ = try self.layerLane(graph, source);
        return self.prepareBatchOwned(graph, source, operations, null);
    }
    pub fn prepareBatch(self: *Manager, graph: Handle, operations: []const Operation) !BatchHandle {
        return self.prepareBatchOwned(graph, null, operations, null);
    }
    fn prepareBatchOwned(self: *Manager, graph: Handle, source: ?LayerSource, operations: []const Operation, tracked: ?duck_runtime.Tracked) !BatchHandle {
        const slot = try self.get(graph);
        for (operations) |op| {
            try self.validateDuckOwner(graph, op, tracked);
            var owner: ?LayerSource = null;
            for (slot.layer_lanes[0..slot.layer_lane_count]) |lane| {
                if (operationOnBus(&slot.catalog, op, lane.bus)) owner = lane.source;
            }
            if (source) |wanted| {
                if (op != .target or owner == null or !owner.?.eql(wanted)) return error.LayerLaneConflict;
                switch (op.target.target) {
                    .channel_gain, .send_gain, .lowpass_hz, .prepared_route => {},
                    .effect_bypass => |id| {
                        _ = try slot.catalog.targetInfo(.{ .lowpass_hz = id });
                    },
                    else => return error.UnsupportedTarget,
                }
            } else if (owner != null) return error.LayerLaneConflict;
        }
        if (operations.len == 0 or operations.len > operations_per_batch) return error.InvalidParameter;
        for (operations, 0..) |op, i| switch (op) {
            .target => |write| {
                const info = try slot.catalog.targetInfo(write.target);
                try sc.inRange(write.value, info.minimum, info.maximum);
                if ((info.unit == .boolean or info.unit == .frames) and write.value != @floor(write.value)) return error.InvalidParameter;
                if (write.ramp_frames > 480000) return error.InvalidParameter;
                for (operations[0..i]) |prior| if (prior == .target and sameTarget(prior.target.target, write.target)) return error.ConflictingTargets;
            },
            .begin_duck => |duck| {
                _ = try slot.catalog.busIndex(duck.bus);
                try duck.target.validate();
            },
            .end_duck => |duck| {
                _ = try slot.catalog.busIndex(duck.bus);
            },
        };
        const index = for (self.batches, 0..) |b, i| {
            if (b == null) break i;
        } else return error.PreparedCapacity;
        const gen = try self.generation();
        const result = try self.allocator.create(Batch);
        result.* = .{ .graph = graph, .generation = gen, .count = @intCast(operations.len), .layer_source = source, .tracked_duck = tracked };
        @memcpy(result.operations[0..operations.len], operations);
        errdefer self.allocator.destroy(result);
        const encoded = if (tracked) |owned|
            try std.json.Stringify.valueAlloc(self.allocator, .{ .graph = slot.content_hash, .operations = operations, .duck = owned, .identity = (try self.ducks.get(owned.handle)).cell.identity }, .{})
        else if (source) |owner|
            if (owner.source_incarnation == 1)
                try std.json.Stringify.valueAlloc(self.allocator, .{ .graph = slot.content_hash, .operations = operations, .layer_source = .{ .group_index = owner.group_index, .group_generation = owner.group_generation, .layer = owner.layer } }, .{})
            else
                try std.json.Stringify.valueAlloc(self.allocator, .{ .graph = slot.content_hash, .operations = operations, .layer_source = owner }, .{})
        else
            try std.json.Stringify.valueAlloc(self.allocator, .{ .graph = slot.content_hash, .operations = operations }, .{});
        defer self.allocator.free(encoded);
        std.crypto.hash.sha2.Sha256.hash(encoded, &result.content_hash, .{});
        self.batches[index] = result;
        return .{ .context = self.identity, .index = @intCast(index), .generation = gen };
    }
    /// Render-owner only. Payload uses atomics so bounded readers never race plain writes.
    pub fn publish(self: *Manager, handle: Handle, frame: u64) void {
        const slot = self.get(handle) catch unreachable;
        for (slot.catalog.buses[0..slot.catalog.bus_count], 0..) |bus, i| {
            const cell = &slot.observations[i];
            const partial = slot.graph.busMeter(bus.id, true) catch unreachable;
            const completed = slot.graph.busMeter(bus.id, false) catch unreachable;
            const last = completed.meter.end_frame;
            if (last > cell.last_completed_end and completed.meter.window_frames != 0) {
                const elapsed = (last - cell.last_completed_end) / completed.meter.window_frames;
                if (elapsed > 1) cell.skipped +|= elapsed - 1;
                cell.last_completed_end = last;
            }
            var words: [82]u64 = @splat(0);
            words[0] = handle.generation;
            words[1] = slot.origin;
            words[2] = frame;
            words[3] = bus.id;
            words[4] = bus.input_latency;
            words[5] = bus.output_latency;
            words[6] = floatWord(partial.automation_reduction_db);
            storeMeter(words[8..16], partial.meter, slot.origin);
            storeMeter(words[16..24], completed.meter, slot.origin);
            if (bus.effect_id) |effect_id| {
                const c = slot.graph.compressorSnapshot(effect_id) catch unreachable;
                words[7] = 1;
                storeMeter(words[64..72], c.meter, slot.origin);
                storeMeter(words[72..80], c.completed_meter, slot.origin);
                countSkipped(&cell.last_comp_end, &cell.skipped_comp, c.completed_meter);
                countSkipped(&cell.last_detector_end, &cell.skipped_detector, c.detector.completed_meter);
                storeMeter(words[24..32], c.detector.meter, slot.origin);
                storeMeter(words[32..40], c.detector.completed_meter, slot.origin);
                words[40] = floatWord(c.detector.rms);
                words[41] = floatWord(c.detector.peak);
                words[42] = floatWord(c.detector.envelope);
                words[43] = c.detector.invalid_samples;
                words[44] = floatWord(c.signal_reduction_db);
                words[45] = floatWord(c.automation_reduction_db);
                words[46] = floatWord(c.applied_signal_reduction_db);
                words[47] = floatWord(c.applied_automation_reduction_db);
                words[48] = floatWord(c.applied_makeup_db);
                words[49] = floatWord(c.combined_reduction_db);
                words[50] = floatWord(c.applied_gain);
                words[51] = floatWord(c.bypass_wet);
                words[52] = c.invalid_program_samples;
                words[53] = floatWord(c.preset.threshold_dbfs);
                words[54] = floatWord(c.preset.ratio);
                words[55] = floatWord(c.preset.knee_db);
                words[56] = c.preset.attack_frames;
                words[57] = c.preset.hold_frames;
                words[58] = c.preset.release_frames;
                words[59] = floatWord(c.preset.makeup_db);
            }
            words[60] = cell.skipped;
            words[61] = cell.skipped_comp;
            words[62] = cell.skipped_detector;
            words[80] = slot.graph.rendered_frames;
            words[81] = slot.graph.invalid_samples;
            _ = cell.sequence.fetchAdd(1, .seq_cst);
            for (&cell.words, words) |*word, value| word.store(value, .seq_cst);
            _ = cell.sequence.fetchAdd(1, .seq_cst);
        }
    }
    /// Control-owner read; graph remains leased throughout this bounded acquisition.
    pub fn observe(self: *const Manager, handle: Handle, bus_id: u32) !Observation {
        const slot = try self.get(handle);
        const index = try slot.catalog.busIndex(bus_id);
        const cell = &slot.observations[index];
        for (0..3) |_| {
            const before = cell.sequence.load(.seq_cst);
            if (before == 0 or before & 1 != 0) continue;
            var words: [82]u64 = undefined;
            for (&words, &cell.words) |*value, *word| value.* = word.load(.seq_cst);
            if (cell.sequence.load(.seq_cst) != before) continue;
            if (words[0] != handle.generation) return error.StaleGraph;
            var result: Observation = .{ .graph = handle, .origin = words[1], .frame = words[2], .graph_rendered_frames = words[80], .invalid_samples = words[81], .bus_id = @intCast(words[3]), .input_latency = @intCast(words[4]), .output_latency = @intCast(words[5]), .automation_db = wordFloat(words[6]), .partial = loadMeter(words[8..16]), .completed = loadMeter(words[16..24]), .compressor = null, .skipped_windows = words[60], .skipped_compressor_windows = words[61], .skipped_detector_windows = words[62] };
            if (words[7] != 0) {
                var c = slot.catalog.buses[index].initial_compressor.?;
                c.meter = loadMeter(words[64..72]);
                c.completed_meter = loadMeter(words[72..80]);
                c.detector.meter = loadMeter(words[24..32]);
                c.detector.completed_meter = loadMeter(words[32..40]);
                c.detector.rms = wordFloat(words[40]);
                c.detector.peak = wordFloat(words[41]);
                c.detector.envelope = wordFloat(words[42]);
                c.detector.invalid_samples = words[43];
                c.signal_reduction_db = wordFloat(words[44]);
                c.automation_reduction_db = wordFloat(words[45]);
                c.applied_signal_reduction_db = wordFloat(words[46]);
                c.applied_automation_reduction_db = wordFloat(words[47]);
                c.applied_makeup_db = wordFloat(words[48]);
                c.combined_reduction_db = wordFloat(words[49]);
                c.applied_gain = wordFloat(words[50]);
                c.bypass_wet = wordFloat(words[51]);
                c.invalid_program_samples = words[52];
                c.preset.threshold_dbfs = wordFloat(words[53]);
                c.preset.ratio = wordFloat(words[54]);
                c.preset.knee_db = wordFloat(words[55]);
                c.preset.attack_frames = @intCast(words[56]);
                c.preset.hold_frames = @intCast(words[57]);
                c.preset.release_frames = @intCast(words[58]);
                c.preset.makeup_db = wordFloat(words[59]);
                result.compressor = c;
            }
            return result;
        }
        return error.InvalidState;
    }
    pub fn retainGraph(self: *Manager, handle: Handle) !void {
        const slot = try self.get(handle);
        if (slot.references == std.math.maxInt(u16)) return error.PreparedCapacity;
        slot.routes_sealed = true;
        slot.references += 1;
    }
    pub fn releaseGraphReference(self: *Manager, handle: Handle) void {
        const slot = self.get(handle) catch unreachable;
        std.debug.assert(slot.references > 0);
        slot.references -= 1;
    }
    pub fn retainBatch(self: *Manager, handle: BatchHandle) !void {
        const slot = try self.batch(handle);
        if (slot.references == std.math.maxInt(u16)) return error.PreparedCapacity;
        try self.retainGraph(slot.graph);
        slot.references += 1;
    }
    pub fn releaseBatchReference(self: *Manager, handle: BatchHandle) void {
        const slot = self.batch(handle) catch unreachable;
        std.debug.assert(slot.references > 0);
        slot.references -= 1;
        self.releaseGraphReference(slot.graph);
    }
    pub fn retainRoute(self: *Manager, handle: RouteHandle) !void {
        const slot = try self.route(handle);
        if (slot.references == std.math.maxInt(u16)) return error.PreparedCapacity;
        try self.retainGraph(slot.graph);
        slot.references += 1;
    }
    pub fn releaseRouteReference(self: *Manager, handle: RouteHandle) void {
        const slot = self.route(handle) catch unreachable;
        std.debug.assert(slot.references > 0);
        slot.references -= 1;
        self.releaseGraphReference(slot.graph);
    }
    pub fn releaseBatch(self: *Manager, handle: BatchHandle) !void {
        const slot = try self.batch(handle);
        if (slot.tracked_duck != null) return error.DuckBusy;
        if (slot.references != 0) return error.GraphBusy;
        self.batches[handle.index] = null;
        self.allocator.destroy(slot);
    }
    pub fn releaseRoutes(self: *Manager, handle: RouteHandle) !void {
        const slot = try self.route(handle);
        if (slot.layer_source != null or slot.references != 0 or (try self.get(slot.graph)).active.load(.acquire)) return error.GraphBusy;
        self.routes[handle.index] = null;
        self.allocator.destroy(slot);
    }
    pub fn releaseGraph(self: *Manager, handle: Handle) !void {
        const slot = try self.get(handle);
        if (slot.references != 0 or slot.active.load(.acquire)) return error.GraphBusy;
        for (&self.routes) |*entry| if (entry.*) |r| {
            if (r.graph.eql(handle)) {
                std.debug.assert(r.references == 0);
                self.allocator.destroy(r);
                entry.* = null;
            }
        };
        for (&self.batches) |*entry| if (entry.*) |b| {
            if (b.graph.eql(handle)) {
                std.debug.assert(b.references == 0);
                self.allocator.destroy(b);
                entry.* = null;
            }
        };
        self.dsp_bytes -= slot.catalog.state_bytes;
        self.graphs[handle.index] = null;
        slot.graph.deinit(self.allocator);
        self.allocator.destroy(slot);
    }
    pub fn deinit(self: *Manager) !void {
        if (!self.ducks.empty()) return error.DuckDrainPending;
        for (self.graphs) |entry| if (entry) |g| {
            if (g.references != 0 or g.active.load(.acquire)) return error.GraphBusy;
        };
        for (self.graphs, 0..) |entry, i| if (entry) |g| try self.releaseGraph(.{ .context = self.identity, .index = @intCast(i), .generation = g.generation });
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    pub fn preflightBatch(self: *const Manager, handle: BatchHandle, active: Handle, trial: *Trial) !void {
        const b = try self.batch(handle);
        if (!b.graph.eql(active)) return error.StaleGraph;
        const slot = try self.get(active);
        if (b.tracked_duck) |tracked| {
            const cell = &(try @constCast(&self.ducks).get(tracked.handle)).cell;
            const state = cell.state.load(.acquire);
            switch (tracked.kind) {
                .begin => if (state != .bound) return error.DuckBusy,
                .end => if (state != .active) return error.DuckBusy,
            }
        }
        for (b.operations[0..b.count]) |operation| {
            if (b.tracked_duck == null) {
                const key: ?u64 = switch (operation) {
                    .begin_duck => |v| (@as(u64, v.bus) << 32) | v.target.id,
                    .end_duck => |v| (@as(u64, v.bus) << 32) | v.id,
                    else => null,
                };
                if (key) |wanted| for (&slot.tracked_duck_keys) |*entry| if (entry.load(.acquire) == wanted and wanted != 0) return error.DuckBusy;
            }
            switch (operation) {
                .target => |write| {
                    if (b.layer_source != null) try slot.graph.validateLayerTargetStart(write.target);
                    for (trial.seen[0..trial.seen_count]) |prior| if (sameTarget(prior, write.target)) return error.ConflictingTargets;
                    if (trial.seen_count == trial.seen.len) return error.PreparedCapacity;
                    trial.seen[trial.seen_count] = write.target;
                    trial.seen_count += 1;
                },
                .begin_duck => |duck| {
                    const index = try slot.catalog.busIndex(duck.bus);
                    var total: usize = 0;
                    for (trial.automations[0..slot.catalog.bus_count]) |*automation| total += automation.count();
                    if (total >= slot.catalog.profile.duck_requests or trial.automations[index].count() >= slot.catalog.profile.duck_requests_per_bus) return error.ProfileExceeded;
                    try trial.automations[index].begin(duck.target);
                },
                .end_duck => |duck| try trial.automations[try slot.catalog.busIndex(duck.bus)].end(duck.id),
            }
        }
    }
    pub fn applyBatch(self: *Manager, handle: BatchHandle) void {
        self.applyBatchAt(handle, null);
    }
    pub fn applyBatchAt(self: *Manager, handle: BatchHandle, frame: ?u64) void {
        const b = self.batch(handle) catch unreachable;
        const graph = (self.get(b.graph) catch unreachable).graph;
        if (b.tracked_duck) |tracked| {
            const at = frame orelse unreachable;
            const cell = &(self.ducks.get(tracked.handle) catch unreachable).cell;
            switch (tracked.kind) {
                .begin => {
                    std.debug.assert(cell.state.load(.acquire) == .bound);
                    graph.beginTrackedDuck(cell.identity.bus, b.operations[0].begin_duck.target, cell) catch unreachable;
                    cell.state.store(.active, .release);
                },
                .end => {
                    std.debug.assert(cell.state.load(.acquire) == .active);
                    graph.endTrackedDuck(cell.identity.bus, cell.identity.dsp_id, at) catch unreachable;
                },
            }
            return;
        }
        for (b.operations[0..b.count]) |op| switch (op) {
            .target => |v| {
                if (b.layer_source != null) graph.applyLayerTarget(v.target, v.value, v.ramp_frames) catch unreachable else graph.applyTarget(v.target, v.value, v.ramp_frames) catch unreachable;
            },
            .begin_duck => |v| graph.beginDuck(v.bus, v.target) catch unreachable,
            .end_duck => |v| graph.endDuck(v.bus, v.id) catch unreachable,
        };
    }
};
pub fn sameTarget(a: bg.Target, b: bg.Target) bool {
    return if (a == .prepared_route and b == .prepared_route) a.prepared_route.group == b.prepared_route.group else std.meta.eql(a, b);
}
/// Complete f64 product first. Existing policy's final 64x Q8.24 domain retained.
pub fn sampleComposed(state: anytype, profile: anytype, frame: u64, layer: f32, group: f32, bus: f32, envelope: f32, transfer: f64) !u32 {
    try profile.validate();
    inline for (.{ layer, group, bus }) |v| try sc.inRange(v, 0, 4);
    try sc.inRange(envelope, 0, 1);
    if (!std.math.isFinite(transfer) or transfer < 0 or (state.initialized and frame < state.frame)) return error.InvalidParameter;
    const one: u64 = 1 << 24;
    const amplitude = @as(f64, layer) * group * bus * envelope * transfer;
    const target: u32 = @intFromFloat(@min(amplitude * @as(f64, @floatFromInt(one)), @as(f64, @floatFromInt(64 * one))));
    if (!state.initialized) {
        state.value_q24 = target;
        state.initialized = true;
    } else {
        const delta = @min(frame - state.frame, profile.audibility_window_frames);
        state.value_q24 = @intCast((@as(u64, state.value_q24) * (profile.audibility_window_frames - delta) + @as(u64, target) * delta) / profile.audibility_window_frames);
    }
    state.frame = frame;
    return state.value_q24;
}

fn floatWord(value: f32) u64 {
    return @as(u32, @bitCast(value));
}
fn wordFloat(value: u64) f32 {
    return @bitCast(@as(u32, @truncate(value)));
}
fn storeMeter(out: []u64, meter: sc.MeterSnapshot, origin: u64) void {
    out[0] = origin +| meter.start_frame;
    out[1] = origin +| meter.end_frame;
    out[2] = meter.valid_frames;
    out[3] = meter.window_frames;
    out[4] = @intFromBool(meter.partial);
    out[5] = floatWord(meter.peak);
    out[6] = floatWord(meter.rms);
}
fn loadMeter(words: []const u64) sc.MeterSnapshot {
    return .{ .start_frame = words[0], .end_frame = words[1], .valid_frames = @intCast(words[2]), .window_frames = @intCast(words[3]), .partial = words[4] != 0, .peak = wordFloat(words[5]), .rms = wordFloat(words[6]) };
}

fn countSkipped(last: *u64, skipped: *u64, meter: sc.MeterSnapshot) void {
    if (meter.end_frame > last.* and meter.window_frames != 0) {
        const elapsed = (meter.end_frame - last.*) / meter.window_frames;
        if (elapsed > 1) skipped.* +|= elapsed - 1;
        last.* = meter.end_frame;
    }
}

fn routesContain(routes: *const PreparedRoutes, bus: u32) bool {
    for (routes.destinations[0..routes.count]) |r| if (r.bus == bus) return true;
    return false;
}
/// Physical writer identity follows the actual compiled node/edge, not authored
/// layer ID. Route alternatives share one physical route-group writer.
fn operationOnBus(catalog: *const Catalog, operation: Operation, bus_id: u32) bool {
    const key: OwnershipKey = switch (operation) {
        .begin_duck => |v| .{ .bus = v.bus },
        .end_duck => |v| .{ .bus = v.bus },
        .target => |write| switch (write.target) {
            .bus_gain, .bus_mute => |id| .{ .bus = id },
            .channel_gain => |v| .{ .bus = v.bus },
            .send_gain => |id| .{ .send = id },
            .prepared_route => |v| .{ .route_group = v.group },
            inline else => |id| .{ .effect = id },
        },
    };
    return catalog.owns(key, bus_id);
}
