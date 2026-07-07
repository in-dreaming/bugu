const std = @import("std");
const spatial = @import("../spatial/spatial.zig");

pub const Vec3 = spatial.Vec3;

pub const AcousticBands = struct {
    low: f32 = 1.0,
    mid: f32 = 1.0,
    high: f32 = 1.0,
};

pub const AcousticMaterial = struct {
    id: u16,
    name: []const u8,
    absorption: AcousticBands,
    reflection: AcousticBands,
    transmission: AcousticBands,
    scattering: AcousticBands = .{ .low = 0.2, .mid = 0.2, .high = 0.2 },
    density: f32 = 1.0,
};

pub const PortalState = enum {
    open,
    closed,
    partial,
    dynamic,
};

pub const AcousticPortal = struct {
    id: u32,
    room_a: u32 = 0,
    room_b: u32 = 0,
    center: Vec3,
    normal_a_to_b: Vec3 = .{ .x = 1, .y = 0, .z = 0 },
    radius: f32,
    area_open_m2: f32,
    max_area_m2: f32,
    material_id: u16,
    state: PortalState = .open,
};

pub const AcousticRoom = struct {
    id: u32,
    bounds_min: Vec3,
    bounds_max: Vec3,
    default_material_id: u16,
    reverb_preset_id: u32 = 0,
};

pub const Probe = struct {
    position: Vec3,
    room_id: u32,
    rt60: AcousticBands,
    density: f32,
    coloration: AcousticBands,
    openness: f32,
};

pub const SolidBox = struct {
    min: Vec3,
    max: Vec3,
    material_id: u16,
    thickness_cm: u8,
};

pub const TestScene = struct {
    bounds_min: Vec3,
    bounds_max: Vec3,
    cell_size_meters: f32,
    materials: []const AcousticMaterial,
    solids: []const SolidBox,
    portals: []const AcousticPortal,
    rooms: []const AcousticRoom = &.{},
    probes: []const Probe = &.{},
};

pub const ReflectionTap = struct {
    gain: f32 = 0.0,
    delay_seconds: f32 = 0.0,
    direction: Vec3 = .{},
};

pub const AcousticResponse = struct {
    direct_gain: f32 = 0.0,
    direct_delay: f32 = 0.0,
    direct_lowpass_hz: f32 = 20_000.0,
    transmission_gain: f32 = 0.0,
    transmission_lowpass_hz: f32 = 20_000.0,
    diffraction_or_portal_gain: f32 = 0.0,
    diffraction_or_portal_direction: Vec3 = .{},
    early_reflection_taps: [4]ReflectionTap = [_]ReflectionTap{.{}} ** 4,
    late_reverb_send: f32 = 0.0,
    openness: f32 = 1.0,
    ambient_direction: Vec3 = .{ .x = 0, .y = 0, .z = 1 },
    confidence: f32 = 1.0,
};

pub const SolveConfig = struct {
    sample_rate: u32 = 48_000,
    max_escape_distance_m: f32 = 24.0,
    smoothing_alpha: f32 = 1.0,
    enable_smoothing: bool = false,
};

pub const TemporalSmoother = struct {
    initialized: bool = false,
    previous: AcousticResponse = .{},

    pub fn step(self: *TemporalSmoother, raw: AcousticResponse, alpha: f32) AcousticResponse {
        if (!self.initialized) {
            self.initialized = true;
            self.previous = raw;
            return raw;
        }
        const a = std.math.clamp(alpha, 0.0, 1.0);
        const smoothed = blendResponse(self.previous, raw, a);
        self.previous = smoothed;
        return smoothed;
    }
};

const AcousticVoxel = struct {
    solid: bool = false,
    material_id: u16 = 0,
    thickness_cm: u8 = 0,
};

const AcousticVoxelGrid = struct {
    allocator: std.mem.Allocator,
    origin: Vec3,
    dims: [3]usize,
    cell_size: f32,
    voxels: []AcousticVoxel,

    fn init(allocator: std.mem.Allocator, scene: TestScene) !AcousticVoxelGrid {
        const dims = .{
            @max(@as(usize, @intFromFloat(@ceil((scene.bounds_max.x - scene.bounds_min.x) / scene.cell_size_meters))), 1),
            @max(@as(usize, @intFromFloat(@ceil((scene.bounds_max.y - scene.bounds_min.y) / scene.cell_size_meters))), 1),
            @max(@as(usize, @intFromFloat(@ceil((scene.bounds_max.z - scene.bounds_min.z) / scene.cell_size_meters))), 1),
        };
        const count = dims[0] * dims[1] * dims[2];
        var voxels = try allocator.alloc(AcousticVoxel, count);
        @memset(voxels, .{});

        var z: usize = 0;
        while (z < dims[2]) : (z += 1) {
            var y: usize = 0;
            while (y < dims[1]) : (y += 1) {
                var x: usize = 0;
                while (x < dims[0]) : (x += 1) {
                    const center = Vec3{
                        .x = scene.bounds_min.x + (@as(f32, @floatFromInt(x)) + 0.5) * scene.cell_size_meters,
                        .y = scene.bounds_min.y + (@as(f32, @floatFromInt(y)) + 0.5) * scene.cell_size_meters,
                        .z = scene.bounds_min.z + (@as(f32, @floatFromInt(z)) + 0.5) * scene.cell_size_meters,
                    };
                    for (scene.solids) |solid| {
                        if (pointInBox(center, solid.min, solid.max)) {
                            voxels[indexOf(dims, x, y, z)] = .{
                                .solid = true,
                                .material_id = solid.material_id,
                                .thickness_cm = solid.thickness_cm,
                            };
                            break;
                        }
                    }
                }
            }
        }

        return .{
            .allocator = allocator,
            .origin = scene.bounds_min,
            .dims = dims,
            .cell_size = scene.cell_size_meters,
            .voxels = voxels,
        };
    }

    fn deinit(self: *AcousticVoxelGrid) void {
        self.allocator.free(self.voxels);
        self.* = undefined;
    }

    fn sample(self: *const AcousticVoxelGrid, point: Vec3) AcousticVoxel {
        const fx = (point.x - self.origin.x) / self.cell_size;
        const fy = (point.y - self.origin.y) / self.cell_size;
        const fz = (point.z - self.origin.z) / self.cell_size;
        if (fx < 0 or fy < 0 or fz < 0) return .{};
        const x: usize = @intFromFloat(@floor(fx));
        const y: usize = @intFromFloat(@floor(fy));
        const z: usize = @intFromFloat(@floor(fz));
        if (x >= self.dims[0] or y >= self.dims[1] or z >= self.dims[2]) return .{};
        return self.voxels[indexOf(self.dims, x, y, z)];
    }
};

const PathTrace = struct {
    solid_distance_m: f32 = 0.0,
    material_low: f32 = 1.0,
    material_mid: f32 = 1.0,
    material_high: f32 = 1.0,
    hit_solid: bool = false,
    confidence: f32 = 1.0,
};

pub fn solve(
    allocator: std.mem.Allocator,
    scene: TestScene,
    listener: Vec3,
    source: Vec3,
    config: SolveConfig,
    smoother: ?*TemporalSmoother,
) !AcousticResponse {
    var grid = try AcousticVoxelGrid.init(allocator, scene);
    defer grid.deinit();

    const raw = solveWithGrid(scene, &grid, listener, source, config);
    if (config.enable_smoothing) {
        if (smoother) |s| return s.step(raw, config.smoothing_alpha);
    }
    return raw;
}

fn solveWithGrid(scene: TestScene, grid: *const AcousticVoxelGrid, listener: Vec3, source: Vec3, config: SolveConfig) AcousticResponse {
    const to_source = sub(source, listener);
    const distance = @max(length(to_source), 0.001);
    const direct_trace = traceSegment(scene, grid, listener, source);
    const distance_gain = 1.0 / (1.0 + 0.12 * distance);
    const occlusion = std.math.clamp(1.0 - direct_trace.solid_distance_m / @max(distance, grid.cell_size), 0.0, 1.0);

    var response: AcousticResponse = .{
        .direct_gain = distance_gain * occlusion,
        .direct_delay = distance / 343.0,
        .direct_lowpass_hz = 20_000.0 - (1.0 - occlusion) * 12_000.0,
        .transmission_gain = 0.0,
        .transmission_lowpass_hz = 20_000.0,
        .confidence = direct_trace.confidence,
    };

    if (direct_trace.hit_solid) {
        const depth = @max(direct_trace.solid_distance_m, grid.cell_size);
        response.transmission_gain = distance_gain * direct_trace.material_mid * std.math.exp(-1.6 * depth);
        response.transmission_lowpass_hz = std.math.clamp(12_000.0 * direct_trace.material_high + 900.0, 700.0, 12_000.0);
        response.direct_lowpass_hz = @min(response.direct_lowpass_hz, response.transmission_lowpass_hz);
    }

    applyBestPortal(scene, grid, listener, source, distance_gain, &response);
    applyEscape(scene, grid, listener, config.max_escape_distance_m, &response);
    applyReflections(scene, listener, source, distance_gain, &response);
    applyProbeReverb(scene, listener, &response);

    response.late_reverb_send = std.math.clamp(response.late_reverb_send + (1.0 - response.openness) * 0.45, 0.0, 1.0);
    response.ambient_direction = normalize(response.ambient_direction);
    response.confidence = std.math.clamp(response.confidence, 0.0, 1.0);
    return response;
}

fn traceSegment(scene: TestScene, grid: *const AcousticVoxelGrid, start: Vec3, end: Vec3) PathTrace {
    const delta = sub(end, start);
    const distance = @max(length(delta), 0.001);
    const dir = normalize(delta);
    const step_len = @max(grid.cell_size * 0.5, 0.05);
    const steps: usize = @max(@as(usize, @intFromFloat(@ceil(distance / step_len))), 1);
    var trace: PathTrace = .{};
    var last_solid_index: ?usize = null;

    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const t = @min(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps)), 1.0);
        const point = add(start, scale(dir, distance * t));
        const voxel = grid.sample(point);
        if (!voxel.solid) {
            last_solid_index = null;
            continue;
        }

        trace.hit_solid = true;
        trace.solid_distance_m += step_len;
        const material_index = findMaterialIndex(scene.materials, voxel.material_id);
        if (last_solid_index == null or last_solid_index.? != material_index) {
            const mat = scene.materials[material_index];
            const thickness_scale = @max(@as(f32, @floatFromInt(voxel.thickness_cm)) / 100.0, grid.cell_size);
            trace.material_low *= std.math.pow(f32, std.math.clamp(mat.transmission.low, 0.0, 1.0), thickness_scale);
            trace.material_mid *= std.math.pow(f32, std.math.clamp(mat.transmission.mid, 0.0, 1.0), thickness_scale);
            trace.material_high *= std.math.pow(f32, std.math.clamp(mat.transmission.high, 0.0, 1.0), thickness_scale);
            last_solid_index = material_index;
        }
    }

    trace.solid_distance_m = @min(trace.solid_distance_m, distance);
    trace.confidence = std.math.clamp(1.0 - grid.cell_size / @max(distance, grid.cell_size), 0.35, 1.0);
    return trace;
}

fn applyBestPortal(scene: TestScene, grid: *const AcousticVoxelGrid, listener: Vec3, source: Vec3, direct_distance_gain: f32, response: *AcousticResponse) void {
    var best_gain: f32 = 0.0;
    var best_dir: Vec3 = .{};
    for (scene.portals) |portal| {
        const openness = std.math.clamp(portal.area_open_m2 / @max(portal.max_area_m2, 0.001), 0.0, 1.0);
        if (openness <= 0.001 and portal.state != .closed) continue;

        const listener_trace = traceSegment(scene, grid, listener, portal.center);
        const source_trace = traceSegment(scene, grid, source, portal.center);
        const listener_dist = @max(length(sub(portal.center, listener)), 0.001);
        const source_dist = @max(length(sub(portal.center, source)), 0.001);
        const path_gain = 1.0 / (1.0 + 0.12 * (listener_dist + source_dist));
        const clear = std.math.clamp(1.0 - 0.5 * (listener_trace.solid_distance_m + source_trace.solid_distance_m) / @max(listener_dist + source_dist, grid.cell_size), 0.0, 1.0);
        const radius_gain = std.math.clamp(portal.radius / 2.0, 0.05, 1.0);
        const material = scene.materials[findMaterialIndex(scene.materials, portal.material_id)];
        const closed_leak = if (portal.state == .closed) material.transmission.mid * 0.08 else 0.0;
        const gain = path_gain * clear * radius_gain * @max(openness, closed_leak);
        if (gain > best_gain) {
            best_gain = gain;
            best_dir = normalize(sub(portal.center, listener));
        }
    }

    response.diffraction_or_portal_gain = @max(best_gain, response.diffraction_or_portal_gain);
    response.diffraction_or_portal_direction = best_dir;
    if (best_gain > 0.0) {
        response.direct_gain = @max(response.direct_gain, direct_distance_gain * best_gain * 0.25);
    }
}

fn applyEscape(scene: TestScene, grid: *const AcousticVoxelGrid, listener: Vec3, max_distance: f32, response: *AcousticResponse) void {
    _ = scene;
    const dirs = [_]Vec3{
        .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = -1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 1, .z = 0 },
        .{ .x = 0, .y = -1, .z = 0 },
        .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = 0, .y = 0, .z = -1 },
    };
    var clear_sum: f32 = 0.0;
    var ambient: Vec3 = .{};
    for (dirs) |dir| {
        const clear = traceClearDistance(grid, listener, dir, max_distance) / max_distance;
        clear_sum += clear;
        ambient = add(ambient, scale(dir, clear));
    }
    response.openness = std.math.clamp(clear_sum / @as(f32, @floatFromInt(dirs.len)), 0.0, 1.0);
    response.ambient_direction = ambient;
}

fn traceClearDistance(grid: *const AcousticVoxelGrid, start: Vec3, dir: Vec3, max_distance: f32) f32 {
    const step_len = @max(grid.cell_size * 0.75, 0.05);
    const steps: usize = @max(@as(usize, @intFromFloat(@ceil(max_distance / step_len))), 1);
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const d = @as(f32, @floatFromInt(i)) * step_len;
        if (grid.sample(add(start, scale(dir, d))).solid) return @min(d, max_distance);
    }
    return max_distance;
}

fn applyReflections(scene: TestScene, listener: Vec3, source: Vec3, distance_gain: f32, response: *AcousticResponse) void {
    var count: usize = 0;
    for (scene.solids) |solid| {
        if (count >= response.early_reflection_taps.len) break;
        const center = scale(add(solid.min, solid.max), 0.5);
        const source_to_wall = length(sub(center, source));
        const wall_to_listener = length(sub(listener, center));
        const path_len = source_to_wall + wall_to_listener;
        const material = scene.materials[findMaterialIndex(scene.materials, solid.material_id)];
        const gain = distance_gain * material.reflection.mid / (1.0 + 0.18 * path_len);
        if (gain <= 0.001) continue;
        response.early_reflection_taps[count] = .{
            .gain = gain,
            .delay_seconds = path_len / 343.0,
            .direction = normalize(sub(center, listener)),
        };
        response.late_reverb_send += gain * (1.0 + material.scattering.mid);
        count += 1;
    }
}

fn applyProbeReverb(scene: TestScene, listener: Vec3, response: *AcousticResponse) void {
    if (scene.probes.len == 0) return;
    var best_index: usize = 0;
    var best_dist = std.math.floatMax(f32);
    for (scene.probes, 0..) |probe, index| {
        const d = length(sub(probe.position, listener));
        if (d < best_dist) {
            best_dist = d;
            best_index = index;
        }
    }
    const probe = scene.probes[best_index];
    const rt60_mid = std.math.clamp(probe.rt60.mid / 4.0, 0.0, 1.0);
    response.late_reverb_send = @max(response.late_reverb_send, rt60_mid * probe.density * (1.0 - 0.35 * probe.openness));
    response.openness = std.math.clamp((response.openness + probe.openness) * 0.5, 0.0, 1.0);
}

fn blendResponse(a: AcousticResponse, b: AcousticResponse, t: f32) AcousticResponse {
    var out = b;
    out.direct_gain = lerp(a.direct_gain, b.direct_gain, t);
    out.direct_delay = lerp(a.direct_delay, b.direct_delay, t);
    out.direct_lowpass_hz = lerp(a.direct_lowpass_hz, b.direct_lowpass_hz, t);
    out.transmission_gain = lerp(a.transmission_gain, b.transmission_gain, t);
    out.transmission_lowpass_hz = lerp(a.transmission_lowpass_hz, b.transmission_lowpass_hz, t);
    out.diffraction_or_portal_gain = lerp(a.diffraction_or_portal_gain, b.diffraction_or_portal_gain, t);
    out.diffraction_or_portal_direction = lerpVec3(a.diffraction_or_portal_direction, b.diffraction_or_portal_direction, t);
    for (&out.early_reflection_taps, 0..) |*tap, i| {
        tap.gain = lerp(a.early_reflection_taps[i].gain, b.early_reflection_taps[i].gain, t);
        tap.delay_seconds = lerp(a.early_reflection_taps[i].delay_seconds, b.early_reflection_taps[i].delay_seconds, t);
        tap.direction = lerpVec3(a.early_reflection_taps[i].direction, b.early_reflection_taps[i].direction, t);
    }
    out.late_reverb_send = lerp(a.late_reverb_send, b.late_reverb_send, t);
    out.openness = lerp(a.openness, b.openness, t);
    out.ambient_direction = lerpVec3(a.ambient_direction, b.ambient_direction, t);
    out.confidence = lerp(a.confidence, b.confidence, t);
    return out;
}

pub const TestScenes = struct {
    pub const concrete_id: u16 = 1;
    pub const rock_id: u16 = 2;
    pub const wood_id: u16 = 3;

    pub const materials = [_]AcousticMaterial{
        .{
            .id = concrete_id,
            .name = "concrete",
            .absorption = .{ .low = 0.08, .mid = 0.12, .high = 0.18 },
            .reflection = .{ .low = 0.75, .mid = 0.65, .high = 0.55 },
            .transmission = .{ .low = 0.36, .mid = 0.14, .high = 0.04 },
            .density = 2.4,
        },
        .{
            .id = rock_id,
            .name = "rock",
            .absorption = .{ .low = 0.05, .mid = 0.08, .high = 0.12 },
            .reflection = .{ .low = 0.88, .mid = 0.80, .high = 0.66 },
            .transmission = .{ .low = 0.25, .mid = 0.08, .high = 0.02 },
            .scattering = .{ .low = 0.35, .mid = 0.45, .high = 0.55 },
            .density = 2.7,
        },
        .{
            .id = wood_id,
            .name = "wood",
            .absorption = .{ .low = 0.12, .mid = 0.18, .high = 0.30 },
            .reflection = .{ .low = 0.50, .mid = 0.42, .high = 0.35 },
            .transmission = .{ .low = 0.62, .mid = 0.34, .high = 0.16 },
            .density = 0.7,
        },
    };

    pub const empty_solids = [_]SolidBox{};
    pub const empty_portals = [_]AcousticPortal{};
    pub const empty_rooms = [_]AcousticRoom{};
    pub const empty_probes = [_]Probe{};
    pub const thick_wall_solids = [_]SolidBox{
        .{ .min = .{ .x = -0.5, .y = -4, .z = -4 }, .max = .{ .x = 0.5, .y = 4, .z = 4 }, .material_id = concrete_id, .thickness_cm = 100 },
    };
    pub const cave_solids = [_]SolidBox{
        .{ .min = .{ .x = -8, .y = -4, .z = -4 }, .max = .{ .x = 8, .y = -3, .z = 4 }, .material_id = rock_id, .thickness_cm = 120 },
        .{ .min = .{ .x = -8, .y = 3, .z = -4 }, .max = .{ .x = 8, .y = 4, .z = 4 }, .material_id = rock_id, .thickness_cm = 120 },
        .{ .min = .{ .x = -8, .y = -4, .z = 3 }, .max = .{ .x = 8, .y = 4, .z = 4 }, .material_id = rock_id, .thickness_cm = 120 },
        .{ .min = .{ .x = -8, .y = -4, .z = -4 }, .max = .{ .x = 8, .y = 4, .z = -3 }, .material_id = rock_id, .thickness_cm = 120 },
    };
    pub const cave_probes = [_]Probe{
        .{ .position = .{ .x = 0, .y = 0, .z = 0 }, .room_id = 1, .rt60 = .{ .low = 2.6, .mid = 2.2, .high = 1.4 }, .density = 0.9, .coloration = .{ .low = 1.2, .mid = 1.0, .high = 0.7 }, .openness = 0.22 },
    };
    pub const open_field_solids = [_]SolidBox{
        .{ .min = .{ .x = 9, .y = 4, .z = -1 }, .max = .{ .x = 10, .y = 5, .z = 2 }, .material_id = concrete_id, .thickness_cm = 100 },
    };

    pub fn openAir() TestScene {
        return base(&empty_solids, &empty_portals, &empty_rooms, &empty_probes);
    }

    pub fn thickWall() TestScene {
        return base(&thick_wall_solids, &empty_portals, &empty_rooms, &empty_probes);
    }

    pub fn wallHole(portals: []const AcousticPortal) TestScene {
        return base(&thick_wall_solids, portals, &empty_rooms, &empty_probes);
    }

    pub fn doorOpening(portals: []const AcousticPortal) TestScene {
        const door_wall = thick_wall_solids[0..];
        return base(door_wall, portals, &empty_rooms, &empty_probes);
    }

    pub fn cave() TestScene {
        return base(&cave_solids, &empty_portals, &empty_rooms, &cave_probes);
    }

    pub fn openField() TestScene {
        return base(&open_field_solids, &empty_portals, &empty_rooms, &empty_probes);
    }

    fn base(solids: []const SolidBox, portals: []const AcousticPortal, rooms: []const AcousticRoom, probes: []const Probe) TestScene {
        return .{
            .bounds_min = .{ .x = -10, .y = -6, .z = -5 },
            .bounds_max = .{ .x = 12, .y = 6, .z = 5 },
            .cell_size_meters = 0.5,
            .materials = &materials,
            .solids = solids,
            .portals = portals,
            .rooms = rooms,
            .probes = probes,
        };
    }
};

fn findMaterialIndex(materials: []const AcousticMaterial, id: u16) usize {
    for (materials, 0..) |material, index| {
        if (material.id == id) return index;
    }
    return 0;
}

fn indexOf(dims: [3]usize, x: usize, y: usize, z: usize) usize {
    return (z * dims[1] + y) * dims[0] + x;
}

fn pointInBox(p: Vec3, min: Vec3, max: Vec3) bool {
    return p.x >= min.x and p.x <= max.x and p.y >= min.y and p.y <= max.y and p.z >= min.z and p.z <= max.z;
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
    if (len <= 0.00001) return .{};
    return scale(a, 1.0 / len);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn lerpVec3(a: Vec3, b: Vec3, t: f32) Vec3 {
    return .{ .x = lerp(a.x, b.x, t), .y = lerp(a.y, b.y, t), .z = lerp(a.z, b.z, t) };
}

test "required scenes produce distinct acoustic responses from scene data" {
    const allocator = std.testing.allocator;
    const listener = Vec3{ .x = -4, .y = 0, .z = 0 };
    const source = Vec3{ .x = 4, .y = 0, .z = 0 };
    const config: SolveConfig = .{ .enable_smoothing = false };

    const open = try solve(allocator, TestScenes.openAir(), listener, source, config, null);
    const wall = try solve(allocator, TestScenes.thickWall(), listener, source, config, null);

    const small_portals = [_]AcousticPortal{
        .{ .id = 1, .center = .{ .x = 0, .y = 2.0, .z = 0 }, .radius = 0.35, .area_open_m2 = 0.25, .max_area_m2 = 2.0, .material_id = TestScenes.concrete_id },
    };
    const large_portals = [_]AcousticPortal{
        .{ .id = 1, .center = .{ .x = 0, .y = 2.0, .z = 0 }, .radius = 1.0, .area_open_m2 = 1.8, .max_area_m2 = 2.0, .material_id = TestScenes.concrete_id },
    };
    const small_hole = try solve(allocator, TestScenes.wallHole(&small_portals), listener, source, config, null);
    const large_hole = try solve(allocator, TestScenes.wallHole(&large_portals), listener, source, config, null);

    const closed_door = [_]AcousticPortal{
        .{ .id = 7, .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = 0.9, .area_open_m2 = 0.0, .max_area_m2 = 2.0, .material_id = TestScenes.wood_id, .state = .closed },
    };
    const open_door = [_]AcousticPortal{
        .{ .id = 7, .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = 0.9, .area_open_m2 = 2.0, .max_area_m2 = 2.0, .material_id = TestScenes.wood_id, .state = .open },
    };
    const door_closed = try solve(allocator, TestScenes.doorOpening(&closed_door), listener, source, config, null);
    const door_open = try solve(allocator, TestScenes.doorOpening(&open_door), listener, source, config, null);

    const cave = try solve(allocator, TestScenes.cave(), listener, source, config, null);
    const field = try solve(allocator, TestScenes.openField(), listener, source, config, null);

    try std.testing.expect(open.direct_gain > wall.direct_gain);
    try std.testing.expect(wall.transmission_gain > 0.0);
    try std.testing.expect(wall.transmission_lowpass_hz < open.direct_lowpass_hz);
    try std.testing.expect(large_hole.diffraction_or_portal_gain > small_hole.diffraction_or_portal_gain);
    try std.testing.expect(large_hole.diffraction_or_portal_direction.y > 0.1);
    try std.testing.expect(door_open.diffraction_or_portal_gain > door_closed.diffraction_or_portal_gain);
    try std.testing.expect(cave.late_reverb_send > field.late_reverb_send);
    try std.testing.expect(field.openness > cave.openness);
    try std.testing.expect(cave.early_reflection_taps[0].gain > 0.0);
}

test "temporal smoothing is optional and changes abrupt portal updates" {
    const allocator = std.testing.allocator;
    const listener = Vec3{ .x = -4, .y = 0, .z = 0 };
    const source = Vec3{ .x = 4, .y = 0, .z = 0 };
    const closed = [_]AcousticPortal{
        .{ .id = 8, .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = 0.9, .area_open_m2 = 0.0, .max_area_m2 = 2.0, .material_id = TestScenes.wood_id, .state = .closed },
    };
    const open = [_]AcousticPortal{
        .{ .id = 8, .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = 0.9, .area_open_m2 = 2.0, .max_area_m2 = 2.0, .material_id = TestScenes.wood_id, .state = .open },
    };

    const raw_closed = try solve(allocator, TestScenes.doorOpening(&closed), listener, source, .{ .enable_smoothing = false }, null);
    const raw_open = try solve(allocator, TestScenes.doorOpening(&open), listener, source, .{ .enable_smoothing = false }, null);

    var smoother: TemporalSmoother = .{};
    _ = try solve(allocator, TestScenes.doorOpening(&closed), listener, source, .{ .enable_smoothing = true, .smoothing_alpha = 0.25 }, &smoother);
    const smoothed_open = try solve(allocator, TestScenes.doorOpening(&open), listener, source, .{ .enable_smoothing = true, .smoothing_alpha = 0.25 }, &smoother);

    try std.testing.expect(raw_open.diffraction_or_portal_gain > raw_closed.diffraction_or_portal_gain);
    try std.testing.expect(smoothed_open.diffraction_or_portal_gain > raw_closed.diffraction_or_portal_gain);
    try std.testing.expect(smoothed_open.diffraction_or_portal_gain < raw_open.diffraction_or_portal_gain);
}
