const std = @import("std");
const scene = @import("scene.zig");

pub const MAX_VERTICES: u32 = 32768;

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

fn add2(a: scene.Vec2, b: scene.Vec2) scene.Vec2 {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}

fn sub2(a: scene.Vec2, b: scene.Vec2) scene.Vec2 {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

fn mul2(a: scene.Vec2, s: f32) scene.Vec2 {
    return .{ .x = a.x * s, .y = a.y * s };
}

fn len2(a: scene.Vec2) f32 {
    return @sqrt(a.x * a.x + a.y * a.y);
}

fn norm2(a: scene.Vec2) scene.Vec2 {
    const l = len2(a);
    if (l < 0.0001) return .{ .x = 1.0, .y = 0.0 };
    return mul2(a, 1.0 / l);
}

fn worldToNdc(p: scene.Vec2) scene.Vec2 {
    return .{ .x = p.x / 6.2, .y = -p.y / 3.55 };
}

fn pushVertex(vertices: []Vertex, count: *u32, p: scene.Vec2, r: f32, g: f32, b: f32, a: f32) void {
    if (count.* >= MAX_VERTICES) return;
    const n = worldToNdc(p);
    vertices[count.*] = .{
        .x = n.x,
        .y = n.y,
        .z = 0.0,
        .w = 1.0,
        .r = r,
        .g = g,
        .b = b,
        .a = a,
    };
    count.* += 1;
}

fn addTri(vertices: []Vertex, count: *u32, a: scene.Vec2, b: scene.Vec2, c: scene.Vec2, r: f32, g: f32, bl: f32, alpha: f32) void {
    pushVertex(vertices, count, a, r, g, bl, alpha);
    pushVertex(vertices, count, b, r, g, bl, alpha);
    pushVertex(vertices, count, c, r, g, bl, alpha);
}

fn addRect(vertices: []Vertex, count: *u32, minp: scene.Vec2, maxp: scene.Vec2, r: f32, g: f32, b: f32, a: f32) void {
    const p0 = scene.Vec2{ .x = minp.x, .y = minp.y };
    const p1 = scene.Vec2{ .x = maxp.x, .y = minp.y };
    const p2 = scene.Vec2{ .x = maxp.x, .y = maxp.y };
    const p3 = scene.Vec2{ .x = minp.x, .y = maxp.y };
    addTri(vertices, count, p0, p1, p2, r, g, b, a);
    addTri(vertices, count, p0, p2, p3, r, g, b, a);
}

fn addLine(vertices: []Vertex, count: *u32, a: scene.Vec2, b: scene.Vec2, thickness: f32, r: f32, g: f32, bl: f32, alpha: f32) void {
    const d = sub2(b, a);
    const n = norm2(.{ .x = -d.y, .y = d.x });
    const off = mul2(n, thickness * 0.5);
    const p0 = add2(a, off);
    const p1 = add2(b, off);
    const p2 = sub2(b, off);
    const p3 = sub2(a, off);
    addTri(vertices, count, p0, p1, p2, r, g, bl, alpha);
    addTri(vertices, count, p0, p2, p3, r, g, bl, alpha);
}

fn addCircle(vertices: []Vertex, count: *u32, c: scene.Vec2, radius: f32, r: f32, g: f32, b: f32, a: f32) void {
    const steps: i32 = 24;
    var i: i32 = 0;
    while (i < steps) : (i += 1) {
        const a0 = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps))) * 6.2831853;
        const a1 = (@as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(steps))) * 6.2831853;
        const p0 = scene.Vec2{ .x = c.x + @cos(a0) * radius, .y = c.y + @sin(a0) * radius };
        const p1 = scene.Vec2{ .x = c.x + @cos(a1) * radius, .y = c.y + @sin(a1) * radius };
        addTri(vertices, count, c, p0, p1, r, g, b, a);
    }
}

fn addBar(vertices: []Vertex, count: *u32, x: f32, y: f32, value: f32, r: f32, g: f32, b: f32) void {
    addRect(vertices, count, .{ .x = x, .y = y }, .{ .x = x + 0.22, .y = y + 1.25 }, 0.10, 0.12, 0.14, 1.0);
    addRect(
        vertices,
        count,
        .{ .x = x + 0.03, .y = y + 0.03 },
        .{ .x = x + 0.19, .y = y + 0.03 + scene.clampf(value, 0.0, 1.0) * 1.19 },
        r,
        g,
        b,
        1.0,
    );
}

pub fn buildVertices(app: *const scene.AppState, data: []const f32, vertices: []Vertex) u32 {
    var count: u32 = 0;
    addRect(vertices, &count, .{ .x = -5.25, .y = -2.95 }, .{ .x = 5.25, .y = 2.95 }, 0.035, 0.04, 0.05, 1.0);

    var segs: [scene.MAX_SEGMENTS]scene.Segment = undefined;
    const segment_count = scene.buildSegments(app, &segs);
    var i: u32 = 0;
    while (i < segment_count) : (i += 1) {
        if (segs[i].active < 0.5) continue;
        if (segs[i].kind > 1.5) {
            addLine(vertices, &count, segs[i].a, segs[i].b, 0.08, 0.18, 0.72, 0.92, 1.0);
        } else {
            addLine(vertices, &count, segs[i].a, segs[i].b, 0.095, 0.72, 0.74, 0.69, 1.0);
        }
    }

    if (app.door_open) {
        addCircle(vertices, &count, .{ .x = 0.0, .y = 0.0 }, 0.16, 0.18, 0.76, 0.94, 0.95);
    } else {
        addLine(vertices, &count, .{ .x = -0.18, .y = -0.62 }, .{ .x = -0.18, .y = 0.62 }, 0.035, 0.92, 0.58, 0.20, 1.0);
    }

    var r: u32 = 0;
    while (r < scene.MAX_RAYS) : (r += 1) {
        const base = scene.RAY_BASE + r * scene.RAY_STRIDE;
        const a = scene.Vec2{ .x = data[base + 0], .y = data[base + 1] };
        const b = scene.Vec2{ .x = data[base + 2], .y = data[base + 3] };
        const c = scene.Vec2{ .x = data[base + 4], .y = data[base + 5] };
        const typ = data[base + 6];
        const energy = scene.clampf(data[base + 7], 0.05, 1.0);
        var cr: f32 = 0.45;
        var cg: f32 = 0.48;
        var cb: f32 = 0.52;
        if (typ == 1.0) {
            cr = 0.20;
            cg = 0.88;
            cb = 0.58;
        }
        if (typ == 2.0) {
            cr = 0.95;
            cg = 0.78;
            cb = 0.25;
        }
        if (typ == 3.0) {
            cr = 0.77;
            cg = 0.48;
            cb = 0.95;
        }
        if (typ == 4.0) {
            cr = 0.24;
            cg = 0.68;
            cb = 1.00;
        }
        addLine(vertices, &count, a, b, 0.018 + energy * 0.012, cr, cg, cb, 0.62);
        if (typ == 2.0 or typ == 3.0 or typ == 4.0) {
            addLine(vertices, &count, b, c, 0.014, cr, cg, cb, 0.38);
            addCircle(vertices, &count, b, 0.035, cr, cg, cb, 0.85);
        }
    }

    addCircle(vertices, &count, app.source, 0.18, 0.98, 0.32, 0.26, 1.0);
    addLine(vertices, &count, .{ .x = app.source.x - 0.28, .y = app.source.y }, .{ .x = app.source.x + 0.28, .y = app.source.y }, 0.035, 0.98, 0.32, 0.26, 1.0);
    addLine(vertices, &count, .{ .x = app.source.x, .y = app.source.y - 0.28 }, .{ .x = app.source.x, .y = app.source.y + 0.28 }, 0.035, 0.98, 0.32, 0.26, 1.0);

    addCircle(vertices, &count, app.listener, 0.18, 0.25, 0.76, 1.0, 1.0);
    addCircle(vertices, &count, app.listener, 0.09, 0.03, 0.04, 0.05, 1.0);

    addRect(vertices, &count, .{ .x = 3.55, .y = 1.05 }, .{ .x = 5.05, .y = 2.65 }, 0.075, 0.085, 0.095, 0.94);
    addBar(vertices, &count, 3.72, 1.24, data[scene.METRIC_BASE + 0], 0.20, 0.88, 0.58);
    addBar(vertices, &count, 4.02, 1.24, data[scene.METRIC_BASE + 1], 0.88, 0.30, 0.24);
    addBar(vertices, &count, 4.32, 1.24, data[scene.METRIC_BASE + 2], 0.95, 0.78, 0.25);
    addBar(vertices, &count, 4.62, 1.24, data[scene.METRIC_BASE + 3], 0.24, 0.68, 1.00);
    return count;
}
