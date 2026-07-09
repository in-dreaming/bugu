const std = @import("std");
const bugu = @import("bugu_audio");

pub const WINDOW_W: u32 = 1280;
pub const WINDOW_H: u32 = 720;
pub const MAX_SEGMENTS: u32 = 16;
pub const MAX_RAYS: u32 = 96;
pub const PARAM_BASE: u32 = 0;
pub const SEG_BASE: u32 = 64;
pub const SEG_STRIDE: u32 = 8;
pub const RAY_BASE: u32 = SEG_BASE + MAX_SEGMENTS * SEG_STRIDE;
pub const RAY_STRIDE: u32 = 12;
pub const METRIC_BASE: u32 = RAY_BASE + MAX_RAYS * RAY_STRIDE;
pub const FLOAT_COUNT: u32 = METRIC_BASE + 32;

pub const KEY_ESCAPE: u32 = 0x0000001b;
pub const KEY_SPACE: u32 = 0x00000020;
pub const KEY_1: u32 = 0x00000031;
pub const KEY_2: u32 = 0x00000032;
pub const KEY_3: u32 = 0x00000033;
pub const KEY_A: u32 = 0x00000061;
pub const KEY_D: u32 = 0x00000064;
pub const KEY_R: u32 = 0x00000072;
pub const KEY_S: u32 = 0x00000073;
pub const KEY_W: u32 = 0x00000077;
pub const KEY_LEFT: u32 = 0x40000050;
pub const KEY_DOWN: u32 = 0x40000051;
pub const KEY_UP: u32 = 0x40000052;
pub const KEY_RIGHT: u32 = 0x4000004f;

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Segment = struct {
    a: Vec2,
    b: Vec2,
    transmission: f32,
    kind: f32,
    active: f32,
};

pub const Material = struct {
    name: []const u8,
    absorption: f32,
    transmission: f32,
    reflection: f32,
};

pub const MATERIALS = [_]Material{
    .{ .name = "concrete", .absorption = 0.18, .transmission = 0.06, .reflection = 0.82 },
    .{ .name = "wood", .absorption = 0.42, .transmission = 0.18, .reflection = 0.48 },
    .{ .name = "rock", .absorption = 0.10, .transmission = 0.03, .reflection = 0.90 },
};

pub const AppState = struct {
    source: Vec2 = .{},
    listener: Vec2 = .{},
    door_open: bool = false,
    material_index: usize = 0,
    key_w: bool = false,
    key_a: bool = false,
    key_s: bool = false,
    key_d: bool = false,
    key_up: bool = false,
    key_down: bool = false,
    key_left: bool = false,
    key_right: bool = false,
    dragging_source: bool = false,
    width: u32 = WINDOW_W,
    height: u32 = WINDOW_H,

    pub fn reset(self: *AppState) void {
        self.source = .{ .x = 3.9, .y = -1.55 };
        self.listener = .{ .x = -3.7, .y = 1.35 };
        self.door_open = false;
        self.material_index = 0;
        self.dragging_source = false;
    }

    pub fn material(self: *const AppState) Material {
        return MATERIALS[self.material_index];
    }

    pub fn handleKey(self: *AppState, key: u32, down: bool, quit: *bool) void {
        if (key == KEY_ESCAPE and down) quit.* = true;
        if (key == KEY_W) self.key_w = down;
        if (key == KEY_A) self.key_a = down;
        if (key == KEY_S) self.key_s = down;
        if (key == KEY_D) self.key_d = down;
        if (key == KEY_UP) self.key_up = down;
        if (key == KEY_DOWN) self.key_down = down;
        if (key == KEY_LEFT) self.key_left = down;
        if (key == KEY_RIGHT) self.key_right = down;
        if (!down) return;
        if (key == KEY_SPACE) self.door_open = !self.door_open;
        if (key == KEY_R) self.reset();
        if (key == KEY_1) self.material_index = 0;
        if (key == KEY_2) self.material_index = 1;
        if (key == KEY_3) self.material_index = 2;
    }

    pub fn updateMotion(self: *AppState) void {
        const step: f32 = 0.045;
        if (self.key_w) self.listener.y += step;
        if (self.key_s) self.listener.y -= step;
        if (self.key_a) self.listener.x -= step;
        if (self.key_d) self.listener.x += step;
        if (self.key_up) self.source.y += step;
        if (self.key_down) self.source.y -= step;
        if (self.key_left) self.source.x -= step;
        if (self.key_right) self.source.x += step;
        self.listener.x = clampf(self.listener.x, -4.9, 4.9);
        self.listener.y = clampf(self.listener.y, -2.65, 2.65);
        self.source.x = clampf(self.source.x, -4.9, 4.9);
        self.source.y = clampf(self.source.y, -2.65, 2.65);
    }

    pub fn screenToWorld(self: *const AppState, x: i32, y: i32) Vec2 {
        const nx = (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(self.width))) * 2.0 - 1.0;
        const ny = (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(self.height))) * 2.0 - 1.0;
        return .{ .x = nx * 6.2, .y = ny * 3.55 };
    }

    pub fn listener3d(self: *const AppState) bugu.Vec3 {
        return .{ .x = self.listener.x, .y = 0, .z = self.listener.y };
    }

    pub fn source3d(self: *const AppState) bugu.Vec3 {
        return .{ .x = self.source.x, .y = 0, .z = self.source.y };
    }

    pub fn portalMaterialId(self: *const AppState) u16 {
        return switch (self.material_index) {
            0 => bugu.acoustic.TestScenes.concrete_id,
            1 => bugu.acoustic.TestScenes.wood_id,
            else => bugu.acoustic.TestScenes.rock_id,
        };
    }

    pub fn makePortal(self: *const AppState) bugu.acoustic.AcousticPortal {
        const open_fraction: f32 = if (self.door_open) 1.0 else 0.0;
        const state: bugu.acoustic.PortalState = if (self.door_open) .open else .closed;
        return .{
            .id = 7,
            .center = .{ .x = 0, .y = 0, .z = 0 },
            .normal_a_to_b = .{ .x = 1, .y = 0, .z = 0 },
            .radius = 0.9,
            .area_open_m2 = 2.0 * open_fraction,
            .max_area_m2 = 2.0,
            .material_id = self.portalMaterialId(),
            .state = state,
        };
    }

    pub fn toAcousticScene(self: *const AppState, portals: []const bugu.acoustic.AcousticPortal) bugu.acoustic.TestScene {
        _ = self;
        return bugu.acoustic.TestScenes.doorOpening(portals);
    }
};

pub fn clampf(v: f32, lo: f32, hi: f32) f32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

pub fn buildSegments(app: *const AppState, segs: *[MAX_SEGMENTS]Segment) u32 {
    const m = app.material();
    var n: u32 = 0;
    const add = struct {
        fn seg(out: *[MAX_SEGMENTS]Segment, count: *u32, ax: f32, ay: f32, bx: f32, by: f32, kind: f32, active: f32, transmission: f32) void {
            if (count.* >= MAX_SEGMENTS) return;
            out[count.*] = .{
                .a = .{ .x = ax, .y = ay },
                .b = .{ .x = bx, .y = by },
                .transmission = transmission,
                .kind = kind,
                .active = active,
            };
            count.* += 1;
        }
    }.seg;

    add(segs, &n, -5.2, -2.9, 5.2, -2.9, 0.0, 1.0, m.transmission);
    add(segs, &n, 5.2, -2.9, 5.2, 2.9, 0.0, 1.0, m.transmission);
    add(segs, &n, 5.2, 2.9, -5.2, 2.9, 0.0, 1.0, m.transmission);
    add(segs, &n, -5.2, 2.9, -5.2, -2.9, 0.0, 1.0, m.transmission);
    add(segs, &n, 0.0, -2.9, 0.0, -0.62, 0.0, 1.0, m.transmission);
    add(segs, &n, 0.0, 0.62, 0.0, 2.9, 0.0, 1.0, m.transmission);
    add(segs, &n, 0.0, -0.62, 0.0, 0.62, 0.0, if (app.door_open) 0.0 else 1.0, m.transmission);
    add(segs, &n, 0.0, -0.62, 0.0, 0.62, 2.0, if (app.door_open) 1.0 else 0.0, m.transmission);
    add(segs, &n, 2.05, -2.9, 2.05, -1.55, 0.0, 1.0, m.transmission);
    add(segs, &n, 2.05, 0.95, 2.05, 2.9, 0.0, 1.0, m.transmission);
    add(segs, &n, -4.55, -0.85, -2.15, -0.85, 0.0, 1.0, m.transmission);
    add(segs, &n, -2.15, -0.85, -2.15, -2.05, 0.0, 1.0, m.transmission);
    return n;
}

pub fn packGpuData(app: *const AppState, data: []f32) void {
    std.debug.assert(data.len >= FLOAT_COUNT);
    @memset(data[0..FLOAT_COUNT], 0);

    var segs: [MAX_SEGMENTS]Segment = undefined;
    const segment_count = buildSegments(app, &segs);
    const m = app.material();

    data[PARAM_BASE + 0] = app.source.x;
    data[PARAM_BASE + 1] = app.source.y;
    data[PARAM_BASE + 2] = app.listener.x;
    data[PARAM_BASE + 3] = app.listener.y;
    data[PARAM_BASE + 4] = @floatFromInt(segment_count);
    data[PARAM_BASE + 5] = 8.5;
    data[PARAM_BASE + 6] = if (app.door_open) 1.0 else 0.0;
    data[PARAM_BASE + 7] = @floatFromInt(app.material_index);
    data[PARAM_BASE + 8] = m.absorption;
    data[PARAM_BASE + 9] = m.transmission;
    data[PARAM_BASE + 10] = m.reflection;
    data[PARAM_BASE + 11] = 0.0;
    data[PARAM_BASE + 12] = 0.0;
    data[PARAM_BASE + 13] = 0.62;

    var i: u32 = 0;
    while (i < segment_count) : (i += 1) {
        const base = SEG_BASE + i * SEG_STRIDE;
        data[base + 0] = segs[i].a.x;
        data[base + 1] = segs[i].a.y;
        data[base + 2] = segs[i].b.x;
        data[base + 3] = segs[i].b.y;
        data[base + 4] = segs[i].transmission;
        data[base + 5] = segs[i].kind;
        data[base + 6] = segs[i].active;
    }
}
