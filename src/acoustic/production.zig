//! Allocation-free production CPU acoustic queries over immutable cooked scenes.
const std = @import("std");
const acoustic = @import("acoustic.zig");

pub const Vec3 = acoustic.Vec3;
pub const AcousticResponse = acoustic.AcousticResponse;
pub const AcousticMaterial = acoustic.AcousticMaterial;
pub const PortalState = acoustic.PortalState;

pub const air_material = std.math.maxInt(u16);

pub const Voxel = extern struct {
    material_index: u16 = air_material,
    thickness_cm: u8 = 0,
    _padding: u8 = 0,

    pub fn isSolid(self: Voxel) bool {
        return self.material_index != air_material;
    }
};

pub const ReflectionSurface = struct {
    center: Vec3,
    material_index: u16,
};

pub const Portal = struct {
    id: u64,
    room_a: u64,
    room_b: u64,
    center: Vec3,
    radius: f32,
    area_open_m2: f32,
    max_area_m2: f32,
    material_index: u16,
    state: PortalState = .open,
};

pub const Room = struct {
    id: u64,
    bounds_min: Vec3,
    bounds_max: Vec3,
    material_index: u16,
};

pub const ReverbProbe = struct {
    position: Vec3,
    room_id: u64,
    late_reverb_send: f32,
    openness: f32,
};

/// All slices are owned by the embedding runtime and must remain immutable while
/// a worker can observe this snapshot.
pub const SceneSnapshot = struct {
    scene_id: u64,
    scene_generation: u32,
    dynamic_generation: u32,
    origin: Vec3,
    dimensions: [3]u32,
    cell_size_meters: f32,
    materials: []const AcousticMaterial,
    voxels: []const Voxel,
    portals: []const Portal = &.{},
    rooms: []const Room = &.{},
    probes: []const ReverbProbe = &.{},
    reflection_surfaces: []const ReflectionSurface = &.{},

    pub fn validate(self: SceneSnapshot) !void {
        if (self.scene_id == 0 or self.scene_generation == 0 or self.dynamic_generation == 0) return error.InvalidSceneIdentity;
        if (!finite3(self.origin) or !std.math.isFinite(self.cell_size_meters) or self.cell_size_meters <= 0) return error.InvalidSceneGeometry;
        const count = std.math.mul(usize, self.dimensions[0], self.dimensions[1]) catch return error.InvalidSceneGeometry;
        const all = std.math.mul(usize, count, self.dimensions[2]) catch return error.InvalidSceneGeometry;
        if (all == 0 or all != self.voxels.len or self.materials.len == 0 or self.materials.len >= air_material) return error.InvalidSceneGeometry;
        for (self.voxels) |voxel| if (voxel.isSolid() and voxel.material_index >= self.materials.len) return error.UnknownMaterial;
        for (self.reflection_surfaces) |surface| if (!finite3(surface.center) or surface.material_index >= self.materials.len) return error.UnknownMaterial;
        for (self.portals) |portal| if (portal.id == 0 or portal.room_a == 0 or portal.room_b == 0 or portal.room_a == portal.room_b or !finite3(portal.center) or !std.math.isFinite(portal.radius) or !std.math.isFinite(portal.area_open_m2) or !std.math.isFinite(portal.max_area_m2) or portal.radius <= 0 or portal.area_open_m2 < 0 or portal.max_area_m2 <= 0 or portal.area_open_m2 > portal.max_area_m2 or portal.material_index >= self.materials.len) return error.InvalidSceneGeometry;
        for (self.rooms) |room| if (room.id == 0 or !finite3(room.bounds_min) or !finite3(room.bounds_max) or room.material_index >= self.materials.len) return error.InvalidSceneGeometry;
        for (self.probes) |probe| if (!finite3(probe.position) or !std.math.isFinite(probe.late_reverb_send) or !std.math.isFinite(probe.openness)) return error.InvalidSceneGeometry;
    }

    fn sample(self: SceneSnapshot, point: Vec3) Voxel {
        const fx = (point.x - self.origin.x) / self.cell_size_meters;
        const fy = (point.y - self.origin.y) / self.cell_size_meters;
        const fz = (point.z - self.origin.z) / self.cell_size_meters;
        if (fx < 0 or fy < 0 or fz < 0) return .{};
        const x: usize = @intFromFloat(@floor(fx));
        const y: usize = @intFromFloat(@floor(fy));
        const z: usize = @intFromFloat(@floor(fz));
        if (x >= self.dimensions[0] or y >= self.dimensions[1] or z >= self.dimensions[2]) return .{};
        return self.voxels[x + @as(usize, self.dimensions[0]) * (y + @as(usize, self.dimensions[1]) * z)];
    }
};

pub const ObjectIdentity = struct {
    id: u64,
    generation: u32,
};

pub const Cancellation = struct {
    epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn cancel(self: *Cancellation) void {
        _ = self.epoch.fetchAdd(1, .release);
    }
};

pub const Query = struct {
    request_id: u64,
    source: ObjectIdentity,
    listener: ObjectIdentity,
    device_generation: u32,
    scene_id: u64,
    scene_generation: u32,
    dynamic_generation: u32,
    listener_position: Vec3,
    source_position: Vec3,
    deadline_tick: u64,
    max_work_units: u32,
    cancellation: ?*const Cancellation = null,
    cancellation_epoch: u64 = 0,
};

pub const CompletionStatus = enum(u8) {
    ok,
    canceled,
    deadline_exceeded,
    budget_exceeded,
    stale_scene,
    no_scene,
    invalid_query,
};

pub const Completion = struct {
    request_id: u64,
    source: ObjectIdentity,
    listener: ObjectIdentity,
    device_generation: u32,
    scene_id: u64,
    scene_generation: u32,
    dynamic_generation: u32,
    status: CompletionStatus,
    response: AcousticResponse = .{},
    work_units: u32 = 0,
};

pub const SubmitError = error{ QueryQueueFull, InvalidQuery };

/// Reused by the single consumer worker. It is intentionally embedded in the
/// backend so processing cannot accidentally allocate per source/listener pair.
pub const WorkerScratch = struct {
    budget: WorkBudget = .{ .remaining = 0 },
};

pub fn Backend(comptime queue_capacity: usize) type {
    if (queue_capacity < 2) @compileError("CPU acoustic queue capacity must be at least two");
    return struct {
        const Self = @This();
        const QueryQueue = MpscRing(Query, queue_capacity);
        const CompletionQueue = SpscRing(Completion, queue_capacity);

        queries: QueryQueue = QueryQueue.init(),
        completions: CompletionQueue = .{},
        scene: ?*const SceneSnapshot = null,
        scratch: WorkerScratch = .{},

        /// Called by the owning worker/control handoff before processing a batch.
        pub fn installScene(self: *Self, scene: *const SceneSnapshot) !void {
            try scene.validate();
            self.scene = scene;
        }

        pub fn unloadScene(self: *Self, scene_id: u64) void {
            if (self.scene) |scene| {
                if (scene.scene_id == scene_id) self.scene = null;
            }
        }

        /// Multi-producer safe. Cancellation memory must outlive its completion.
        pub fn submit(self: *Self, query: Query) SubmitError!void {
            if (!validQuery(query)) return error.InvalidQuery;
            if (!self.queries.push(query)) return error.QueryQueueFull;
        }

        /// Single-worker consumer. `batch_work_units` is deterministic, not wall time.
        pub fn processBatch(self: *Self, now_tick: u64, max_queries: usize, batch_work_units: u32) usize {
            var completed: usize = 0;
            var remaining = batch_work_units;
            while (completed < max_queries and remaining > 0 and self.completions.hasSpace()) {
                const query = self.queries.pop() orelse break;
                var completion = baseCompletion(query);
                if (query.deadline_tick <= now_tick) {
                    completion.status = .deadline_exceeded;
                } else if (isCanceled(query)) {
                    completion.status = .canceled;
                } else if (self.scene == null) {
                    completion.status = .no_scene;
                } else if (!matches(self.scene.?, query)) {
                    completion.status = .stale_scene;
                } else {
                    self.scratch.budget = .{ .remaining = @min(remaining, query.max_work_units) };
                    completion.response = solve(self.scene.?.*, query.listener_position, query.source_position, &self.scratch.budget) catch |err| switch (err) {
                        error.BudgetExceeded => {
                            completion.status = .budget_exceeded;
                            completion.work_units = self.scratch.budget.used;
                            remaining -|= self.scratch.budget.used;
                            self.completions.pushAssumeSpace(completion);
                            completed += 1;
                            continue;
                        },
                    };
                    completion.status = .ok;
                    completion.work_units = self.scratch.budget.used;
                    remaining -|= self.scratch.budget.used;
                }
                self.completions.pushAssumeSpace(completion);
                completed += 1;
            }
            return completed;
        }

        /// Audio Control is the intended consumer; workers never touch the mixer.
        pub fn pollCompletion(self: *Self) ?Completion {
            return self.completions.pop();
        }

        pub fn pendingQueries(self: *const Self) usize {
            return self.queries.count();
        }
    };
}

const WorkBudget = struct {
    remaining: u32,
    used: u32 = 0,

    fn consume(self: *WorkBudget) error{BudgetExceeded}!void {
        if (self.remaining == 0) return error.BudgetExceeded;
        self.remaining -= 1;
        self.used += 1;
    }
};

const PathTrace = struct {
    solid_distance_m: f32 = 0,
    material_mid: f32 = 1,
    material_high: f32 = 1,
    hit_solid: bool = false,
    confidence: f32 = 1,
};

fn solve(scene: SceneSnapshot, listener: Vec3, source: Vec3, budget: *WorkBudget) error{BudgetExceeded}!AcousticResponse {
    const to_source = sub(source, listener);
    const distance = @max(length(to_source), 0.001);
    const direct_trace = try traceSegment(scene, listener, source, budget);
    const distance_gain = 1 / (1 + 0.12 * distance);
    const occlusion = std.math.clamp(1 - direct_trace.solid_distance_m / @max(distance, scene.cell_size_meters), 0, 1);
    var response: AcousticResponse = .{
        .direct_gain = distance_gain * occlusion,
        .direct_delay = distance / 343,
        .direct_lowpass_hz = 20_000 - (1 - occlusion) * 12_000,
        .direct_direction = normalize(to_source),
        .confidence = direct_trace.confidence,
    };
    if (direct_trace.hit_solid) {
        const depth = @max(direct_trace.solid_distance_m, scene.cell_size_meters);
        response.transmission_gain = distance_gain * direct_trace.material_mid * std.math.exp(-1.6 * depth);
        response.transmission_lowpass_hz = std.math.clamp(12_000 * direct_trace.material_high + 900, 700, 12_000);
        response.direct_lowpass_hz = @min(response.direct_lowpass_hz, response.transmission_lowpass_hz);
    }
    try applyPortal(scene, listener, source, distance_gain, &response, budget);
    try applyEscape(scene, listener, 24, &response, budget);
    try applyReflections(scene, listener, source, distance_gain, &response, budget);
    try applyProbe(scene, listener, &response, budget);
    response.late_reverb_send = std.math.clamp(response.late_reverb_send + (1 - response.openness) * 0.45, 0, 1);
    response.ambient_direction = normalize(response.ambient_direction);
    response.confidence = std.math.clamp(response.confidence, 0, 1);
    return response;
}

fn traceSegment(scene: SceneSnapshot, start: Vec3, end: Vec3, budget: *WorkBudget) error{BudgetExceeded}!PathTrace {
    const delta = sub(end, start);
    const distance = @max(length(delta), 0.001);
    const dir = normalize(delta);
    const step_len = @max(scene.cell_size_meters * 0.5, 0.05);
    const steps: usize = @max(@as(usize, @intFromFloat(@ceil(distance / step_len))), 1);
    var trace: PathTrace = .{};
    var last_material: u16 = air_material;
    for (0..steps + 1) |i| {
        try budget.consume();
        const t = @min(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps)), 1);
        const voxel = scene.sample(add(start, scale(dir, distance * t)));
        if (!voxel.isSolid()) {
            last_material = air_material;
            continue;
        }
        trace.hit_solid = true;
        trace.solid_distance_m += step_len;
        if (voxel.material_index != last_material) {
            const material = scene.materials[voxel.material_index];
            const thickness = @max(@as(f32, @floatFromInt(voxel.thickness_cm)) / 100, scene.cell_size_meters);
            trace.material_mid *= std.math.pow(f32, std.math.clamp(material.transmission.mid, 0, 1), thickness);
            trace.material_high *= std.math.pow(f32, std.math.clamp(material.transmission.high, 0, 1), thickness);
            last_material = voxel.material_index;
        }
    }
    trace.solid_distance_m = @min(trace.solid_distance_m, distance);
    trace.confidence = std.math.clamp(1 - scene.cell_size_meters / @max(distance, scene.cell_size_meters), 0.35, 1);
    return trace;
}

fn applyPortal(scene: SceneSnapshot, listener: Vec3, source: Vec3, direct_gain: f32, response: *AcousticResponse, budget: *WorkBudget) error{BudgetExceeded}!void {
    var best_gain: f32 = 0;
    var best_dir: Vec3 = .{};
    for (scene.portals) |portal| {
        try budget.consume();
        const openness = std.math.clamp(portal.area_open_m2 / @max(portal.max_area_m2, 0.001), 0, 1);
        const a = try traceSegment(scene, listener, portal.center, budget);
        const b = try traceSegment(scene, source, portal.center, budget);
        const distance = @max(length(sub(portal.center, listener)) + length(sub(portal.center, source)), 0.001);
        const clear = std.math.clamp(1 - 0.5 * (a.solid_distance_m + b.solid_distance_m) / @max(distance, scene.cell_size_meters), 0, 1);
        const material = scene.materials[portal.material_index];
        const leak = if (portal.state == .closed) material.transmission.mid * 0.08 else 0;
        const gain = (1 / (1 + 0.12 * distance)) * clear * std.math.clamp(portal.radius / 2, 0.05, 1) * @max(openness, leak);
        if (gain > best_gain) {
            best_gain = gain;
            best_dir = normalize(sub(portal.center, listener));
        }
    }
    response.diffraction_or_portal_gain = best_gain;
    response.diffraction_or_portal_direction = best_dir;
    if (best_gain > 0) response.direct_gain = @max(response.direct_gain, direct_gain * best_gain * 0.25);
}

fn applyEscape(scene: SceneSnapshot, listener: Vec3, max_distance: f32, response: *AcousticResponse, budget: *WorkBudget) error{BudgetExceeded}!void {
    const dirs = [_]Vec3{ .{ .x = 1 }, .{ .x = -1 }, .{ .y = 1 }, .{ .y = -1 }, .{ .z = 1 }, .{ .z = -1 } };
    var sum: f32 = 0;
    var ambient: Vec3 = .{};
    for (dirs) |dir| {
        const clear = try traceClear(scene, listener, dir, max_distance, budget);
        sum += clear / max_distance;
        ambient = add(ambient, scale(dir, clear));
    }
    response.openness = std.math.clamp(sum / dirs.len, 0, 1);
    response.ambient_direction = ambient;
}

fn traceClear(scene: SceneSnapshot, start: Vec3, dir: Vec3, max_distance: f32, budget: *WorkBudget) error{BudgetExceeded}!f32 {
    const step_len = @max(scene.cell_size_meters * 0.75, 0.05);
    const steps: usize = @max(@as(usize, @intFromFloat(@ceil(max_distance / step_len))), 1);
    for (1..steps + 1) |i| {
        try budget.consume();
        const distance = @as(f32, @floatFromInt(i)) * step_len;
        if (scene.sample(add(start, scale(dir, distance))).isSolid()) return @min(distance, max_distance);
    }
    return max_distance;
}

fn applyReflections(scene: SceneSnapshot, listener: Vec3, source: Vec3, distance_gain: f32, response: *AcousticResponse, budget: *WorkBudget) error{BudgetExceeded}!void {
    var count: usize = 0;
    for (scene.reflection_surfaces) |surface| {
        try budget.consume();
        if (count == response.early_reflection_taps.len) break;
        const path = length(sub(surface.center, source)) + length(sub(listener, surface.center));
        const material = scene.materials[surface.material_index];
        const gain = distance_gain * material.reflection.mid / (1 + 0.18 * path);
        if (gain <= 0.001) continue;
        response.early_reflection_taps[count] = .{ .gain = gain, .delay_seconds = path / 343, .direction = normalize(sub(surface.center, listener)) };
        response.late_reverb_send += gain * (1 + material.scattering.mid);
        count += 1;
    }
}

fn applyProbe(scene: SceneSnapshot, listener: Vec3, response: *AcousticResponse, budget: *WorkBudget) error{BudgetExceeded}!void {
    if (scene.probes.len == 0) return;
    var best: usize = 0;
    var best_distance = std.math.floatMax(f32);
    for (scene.probes, 0..) |probe, i| {
        try budget.consume();
        const distance = length(sub(probe.position, listener));
        if (distance < best_distance) {
            best = i;
            best_distance = distance;
        }
    }
    const probe = scene.probes[best];
    response.late_reverb_send = @max(response.late_reverb_send, std.math.clamp(probe.late_reverb_send, 0, 1));
    response.openness = std.math.clamp((response.openness + probe.openness) * 0.5, 0, 1);
}

fn MpscRing(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Cell = struct { sequence: std.atomic.Value(usize) = std.atomic.Value(usize).init(0), value: T = undefined };
        cells: [capacity]Cell = undefined,
        enqueue_position: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        dequeue_position: usize = 0,

        fn init() Self {
            var self: Self = .{};
            for (&self.cells, 0..) |*cell, i| cell.* = .{ .sequence = std.atomic.Value(usize).init(i) };
            return self;
        }
        fn push(self: *Self, value: T) bool {
            var position = self.enqueue_position.load(.monotonic);
            while (true) {
                const cell = &self.cells[position % capacity];
                const sequence = cell.sequence.load(.acquire);
                const difference: isize = @as(isize, @bitCast(sequence -% position));
                if (difference == 0) {
                    if (self.enqueue_position.cmpxchgWeak(position, position +% 1, .monotonic, .monotonic)) |actual| {
                        position = actual;
                        continue;
                    }
                    cell.value = value;
                    cell.sequence.store(position +% 1, .release);
                    return true;
                }
                if (difference < 0) return false;
                position = self.enqueue_position.load(.monotonic);
            }
        }
        fn pop(self: *Self) ?T {
            const position = self.dequeue_position;
            const cell = &self.cells[position % capacity];
            if (cell.sequence.load(.acquire) != position +% 1) return null;
            const value = cell.value;
            cell.sequence.store(position +% capacity, .release);
            self.dequeue_position = position +% 1;
            return value;
        }
        fn count(self: *const Self) usize {
            return self.enqueue_position.load(.acquire) -% self.dequeue_position;
        }
    };
}

fn SpscRing(comptime T: type, comptime capacity: usize) type {
    return struct {
        values: [capacity]T = undefined,
        write: usize = 0,
        read: usize = 0,
        fn hasSpace(self: *const @This()) bool {
            return self.write -% self.read < capacity;
        }
        fn pushAssumeSpace(self: *@This(), value: T) void {
            self.values[self.write % capacity] = value;
            self.write +%= 1;
        }
        fn pop(self: *@This()) ?T {
            if (self.read == self.write) return null;
            const value = self.values[self.read % capacity];
            self.read +%= 1;
            return value;
        }
    };
}

fn validQuery(query: Query) bool {
    return query.request_id != 0 and query.source.id != 0 and query.source.generation != 0 and query.listener.id != 0 and query.listener.generation != 0 and query.device_generation != 0 and query.scene_id != 0 and query.scene_generation != 0 and query.dynamic_generation != 0 and query.deadline_tick != 0 and query.max_work_units != 0 and finite3(query.listener_position) and finite3(query.source_position) and (query.cancellation == null or query.cancellation_epoch != 0);
}
fn isCanceled(query: Query) bool {
    return if (query.cancellation) |token| token.epoch.load(.acquire) != query.cancellation_epoch else false;
}
fn matches(scene: *const SceneSnapshot, query: Query) bool {
    return scene.scene_id == query.scene_id and scene.scene_generation == query.scene_generation and scene.dynamic_generation == query.dynamic_generation;
}
fn baseCompletion(query: Query) Completion {
    return .{ .request_id = query.request_id, .source = query.source, .listener = query.listener, .device_generation = query.device_generation, .scene_id = query.scene_id, .scene_generation = query.scene_generation, .dynamic_generation = query.dynamic_generation, .status = .invalid_query };
}
fn finite3(value: Vec3) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y) and std.math.isFinite(value.z);
}
fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
}
fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
}
fn scale(a: Vec3, s: f32) Vec3 {
    return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
}
fn length(a: Vec3) f32 {
    return @sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
}
fn normalize(a: Vec3) Vec3 {
    const len = length(a);
    return if (len <= 0.00001) .{} else scale(a, 1 / len);
}

test "production backend reuses immutable acceleration and reports terminal states" {
    const materials = [_]AcousticMaterial{.{ .id = 0, .name = "wall", .absorption = .{}, .reflection = .{ .low = 0.8, .mid = 0.7, .high = 0.5 }, .transmission = .{ .low = 0.4, .mid = 0.2, .high = 0.05 } }};
    var voxels = [_]Voxel{.{}} ** 64;
    voxels[22] = .{ .material_index = 0, .thickness_cm = 20 };
    const surfaces = [_]ReflectionSurface{.{ .center = .{ .x = 2, .y = 2, .z = 1 }, .material_index = 0 }};
    const scene: SceneSnapshot = .{ .scene_id = 7, .scene_generation = 2, .dynamic_generation = 3, .origin = .{}, .dimensions = .{ 4, 4, 4 }, .cell_size_meters = 1, .materials = &materials, .voxels = &voxels, .reflection_surfaces = &surfaces };
    var backend: Backend(8) = .{};
    try backend.installScene(&scene);
    const base: Query = .{ .request_id = 1, .source = .{ .id = 2, .generation = 1 }, .listener = .{ .id = 3, .generation = 1 }, .device_generation = 4, .scene_id = 7, .scene_generation = 2, .dynamic_generation = 3, .listener_position = .{ .x = 0.5, .y = 1.5, .z = 1.5 }, .source_position = .{ .x = 3.5, .y = 1.5, .z = 1.5 }, .deadline_tick = 100, .max_work_units = 10_000 };
    try backend.submit(base);
    var canceled = Cancellation{};
    var cancel_query = base;
    cancel_query.request_id = 2;
    cancel_query.cancellation = &canceled;
    cancel_query.cancellation_epoch = canceled.epoch.load(.acquire);
    try backend.submit(cancel_query);
    canceled.cancel();
    var budget_query = base;
    budget_query.request_id = 3;
    budget_query.max_work_units = 1;
    try backend.submit(budget_query);
    try std.testing.expectEqual(@as(usize, 3), backend.processBatch(1, 8, 30_000));
    const ok = backend.pollCompletion().?;
    try std.testing.expectEqual(CompletionStatus.ok, ok.status);
    try std.testing.expect(ok.response.transmission_gain > 0 and ok.response.early_reflection_taps[0].gain > 0);
    try std.testing.expectEqual(CompletionStatus.canceled, backend.pollCompletion().?.status);
    try std.testing.expectEqual(CompletionStatus.budget_exceeded, backend.pollCompletion().?.status);
}

const ConcurrentBackend = Backend(64);
const SubmitContext = struct {
    backend: *ConcurrentBackend,
    producer: u32,
    failed: *std.atomic.Value(bool),
};

fn submitQueries(context: SubmitContext) void {
    for (0..8) |index| {
        context.backend.submit(.{
            .request_id = 1 + @as(u64, context.producer) * 8 + index,
            .source = .{ .id = 1 + index, .generation = 1 },
            .listener = .{ .id = 100 + context.producer, .generation = 1 },
            .device_generation = 1,
            .scene_id = 11,
            .scene_generation = 1,
            .dynamic_generation = 1,
            .listener_position = .{ .x = 0.25, .y = 0.25, .z = 0.25 },
            .source_position = .{ .x = 1.75, .y = 1.75, .z = 1.75 },
            .deadline_tick = 100,
            .max_work_units = 10_000,
        }) catch {
            context.failed.store(true, .release);
            return;
        };
    }
}

test "concurrent producers feed a bounded deterministic worker batch" {
    const material = [_]AcousticMaterial{.{ .id = 0, .name = "reference", .absorption = .{}, .reflection = .{}, .transmission = .{} }};
    const voxels = [_]Voxel{.{}} ** 8;
    const scene: SceneSnapshot = .{ .scene_id = 11, .scene_generation = 1, .dynamic_generation = 1, .origin = .{}, .dimensions = .{ 2, 2, 2 }, .cell_size_meters = 1, .materials = &material, .voxels = &voxels };
    var backend: ConcurrentBackend = .{};
    try backend.installScene(&scene);
    var failed = std.atomic.Value(bool).init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, producer| thread.* = try std.Thread.spawn(.{}, submitQueries, .{SubmitContext{ .backend = &backend, .producer = @intCast(producer), .failed = &failed }});
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 32), backend.pendingQueries());
    try std.testing.expectEqual(@as(usize, 32), backend.processBatch(1, 32, 1_000_000));
    var seen = [_]bool{false} ** 32;
    while (backend.pollCompletion()) |completion| {
        try std.testing.expectEqual(CompletionStatus.ok, completion.status);
        seen[completion.request_id - 1] = true;
    }
    for (seen) |value| try std.testing.expect(value);
}

test "deadline scene swap and unload produce structured failures" {
    const material = [_]AcousticMaterial{.{ .id = 0, .name = "reference", .absorption = .{}, .reflection = .{}, .transmission = .{} }};
    const voxels = [_]Voxel{.{}};
    const old_scene: SceneSnapshot = .{ .scene_id = 21, .scene_generation = 1, .dynamic_generation = 1, .origin = .{}, .dimensions = .{ 1, 1, 1 }, .cell_size_meters = 1, .materials = &material, .voxels = &voxels };
    const new_scene: SceneSnapshot = .{ .scene_id = 21, .scene_generation = 2, .dynamic_generation = 1, .origin = .{}, .dimensions = .{ 1, 1, 1 }, .cell_size_meters = 1, .materials = &material, .voxels = &voxels };
    var backend: Backend(8) = .{};
    try backend.installScene(&old_scene);
    const query: Query = .{ .request_id = 1, .source = .{ .id = 1, .generation = 1 }, .listener = .{ .id = 2, .generation = 1 }, .device_generation = 1, .scene_id = 21, .scene_generation = 1, .dynamic_generation = 1, .listener_position = .{}, .source_position = .{ .x = 0.5 }, .deadline_tick = 10, .max_work_units = 10_000 };
    try backend.submit(query);
    try std.testing.expectEqual(@as(usize, 1), backend.processBatch(10, 1, 10_000));
    try std.testing.expectEqual(CompletionStatus.deadline_exceeded, backend.pollCompletion().?.status);
    try backend.submit(query);
    try backend.installScene(&new_scene);
    _ = backend.processBatch(1, 1, 10_000);
    try std.testing.expectEqual(CompletionStatus.stale_scene, backend.pollCompletion().?.status);
    var current = query;
    current.request_id = 2;
    current.scene_generation = 2;
    try backend.submit(current);
    backend.unloadScene(21);
    _ = backend.processBatch(1, 1, 10_000);
    try std.testing.expectEqual(CompletionStatus.no_scene, backend.pollCompletion().?.status);
}
