const std = @import("std");
const bugu = @import("bugu_audio");

pub fn main(init: std.process.Init) !void {
    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);

    try stdout.interface.writeAll("bugu validation report v0.1\n");
    try runMixerStress(&stdout.interface);
    try runAcousticCases(&stdout.interface);
    try stdout.interface.flush();
}

fn runMixerStress(writer: *std.Io.Writer) !void {
    var engine = try bugu.Engine.init(.{});
    var i: usize = 0;
    while (i < 96) : (i += 1) {
        try engine.startTestVoice(.{
            .frequency_hz = 160.0 + @as(f32, @floatFromInt(i)),
            .gain = 0.004,
            .priority = @floatFromInt(i + 1),
            .pan = (@as(f32, @floatFromInt(i % 17)) - 8.0) / 8.0,
        });
    }

    var durations: [96]u64 = undefined;
    var output: [256 * 2]f32 = undefined;
    for (&durations) |*duration| {
        engine.render(&output, 256);
        duration.* = engine.telemetrySnapshot().mixer_time_nanos;
    }
    std.mem.sort(u64, &durations, {}, comptime std.sort.asc(u64));

    const snap = engine.telemetrySnapshot();
    try writer.print(
        "mixer_stress rendered_frames={} active={} stolen={} clipping={} peak={d:.6} rms={d:.6} render_ns_p50={} render_ns_p99={} render_ns_p999={}\n",
        .{
            snap.rendered_frames,
            snap.active_voices,
            snap.stolen_voices,
            snap.clipping_count,
            snap.peak_abs,
            snap.rms,
            percentile(&durations, 0.50),
            percentile(&durations, 0.99),
            percentile(&durations, 0.999),
        },
    );
}

fn runAcousticCases(writer: *std.Io.Writer) !void {
    const allocator = std.heap.page_allocator;
    const listener = bugu.Vec3{ .x = -4, .y = 0, .z = 0 };
    const source = bugu.Vec3{ .x = 4, .y = 0, .z = 0 };
    const wall_hole_portals = [_]bugu.acoustic.AcousticPortal{
        .{ .id = 1, .center = .{ .x = 0, .y = 2.0, .z = 0 }, .radius = 1.0, .area_open_m2 = 1.8, .max_area_m2 = 2.0, .material_id = bugu.acoustic.TestScenes.concrete_id },
    };
    const door_portals = [_]bugu.acoustic.AcousticPortal{
        .{ .id = 2, .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = 0.9, .area_open_m2 = 2.0, .max_area_m2 = 2.0, .material_id = bugu.acoustic.TestScenes.wood_id, .state = .open },
    };
    const cases = [_]struct { name: []const u8, scene: bugu.acoustic.TestScene }{
        .{ .name = "open_air", .scene = bugu.acoustic.TestScenes.openAir() },
        .{ .name = "thick_wall", .scene = bugu.acoustic.TestScenes.thickWall() },
        .{ .name = "wall_hole", .scene = bugu.acoustic.TestScenes.wallHole(&wall_hole_portals) },
        .{ .name = "door_open", .scene = bugu.acoustic.TestScenes.doorOpening(&door_portals) },
        .{ .name = "cave", .scene = bugu.acoustic.TestScenes.cave() },
        .{ .name = "open_field", .scene = bugu.acoustic.TestScenes.openField() },
    };

    for (cases) |case| {
        const response = try bugu.acoustic.solve(allocator, case.scene, listener, source, .{}, null);
        const snapshot = bugu.acoustic.mapResponseToSnapshot(response, .{});
        try writer.print(
            "acoustic_case name={s} direct={d:.5} transmission={d:.5} portal={d:.5} portal_pan={d:.3} reverb={d:.5} openness={d:.5} confidence={d:.3} smoothing_ms={d:.2}\n",
            .{
                case.name,
                response.direct_gain,
                response.transmission_gain,
                snapshot.portal.gain,
                snapshot.portal.pan,
                response.late_reverb_send,
                response.openness,
                response.confidence,
                snapshot.smoothing_ms,
            },
        );
    }
}

fn percentile(values: []const u64, p: f32) u64 {
    if (values.len == 0) return 0;
    const clamped = std.math.clamp(p, 0.0, 1.0);
    const index: usize = @intFromFloat(@round(clamped * @as(f32, @floatFromInt(values.len - 1))));
    return values[index];
}
