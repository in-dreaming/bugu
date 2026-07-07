const std = @import("std");
const bugu = @import("bugu_audio");

const SceneCase = struct {
    name: []const u8,
    scene: bugu.acoustic.TestScene,
};

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);

    const allocator = std.heap.page_allocator;
    const listener = bugu.Vec3{ .x = -4, .y = 0, .z = 0 };
    const source = bugu.Vec3{ .x = 4, .y = 0, .z = 0 };

    const wall_hole_portals = [_]bugu.acoustic.AcousticPortal{
        .{ .id = 1, .center = .{ .x = 0, .y = 2.0, .z = 0 }, .radius = 1.0, .area_open_m2 = 1.8, .max_area_m2 = 2.0, .material_id = bugu.acoustic.TestScenes.concrete_id },
    };
    const closed_door = [_]bugu.acoustic.AcousticPortal{
        .{ .id = 2, .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = 0.9, .area_open_m2 = 0.0, .max_area_m2 = 2.0, .material_id = bugu.acoustic.TestScenes.wood_id, .state = .closed },
    };
    const open_door = [_]bugu.acoustic.AcousticPortal{
        .{ .id = 2, .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = 0.9, .area_open_m2 = 2.0, .max_area_m2 = 2.0, .material_id = bugu.acoustic.TestScenes.wood_id, .state = .open },
    };
    const scenes = [_]SceneCase{
        .{ .name = "open_air", .scene = bugu.acoustic.TestScenes.openAir() },
        .{ .name = "thick_wall", .scene = bugu.acoustic.TestScenes.thickWall() },
        .{ .name = "wall_hole", .scene = bugu.acoustic.TestScenes.wallHole(&wall_hole_portals) },
        .{ .name = "door_closed", .scene = bugu.acoustic.TestScenes.doorOpening(&closed_door) },
        .{ .name = "door_open", .scene = bugu.acoustic.TestScenes.doorOpening(&open_door) },
        .{ .name = "cave", .scene = bugu.acoustic.TestScenes.cave() },
        .{ .name = "open_field", .scene = bugu.acoustic.TestScenes.openField() },
    };

    try stdout.interface.writeAll("[\n");
    for (scenes, 0..) |case, index| {
        const response = try bugu.acoustic.solve(allocator, case.scene, listener, source, .{}, null);
        const snapshot = bugu.acoustic.mapResponseToSnapshot(response, .{ .sample_rate = 48_000 });
        const telemetry = try renderSnapshot(snapshot);
        try stdout.interface.print(
            "  {{\"scene\":\"{s}\",\"direct_gain\":{d:.5},\"direct_lowpass_hz\":{d:.1},\"transmission_gain\":{d:.5},\"transmission_lowpass_hz\":{d:.1},\"portal_gain\":{d:.5},\"portal_pan\":{d:.3},\"reflection0_gain\":{d:.5},\"reflection0_delay_frames\":{},\"late_reverb_send\":{d:.5},\"openness\":{d:.5},\"smoothing_ms\":{d:.2},\"rendered_frames\":{},\"peak\":{d:.6},\"rms\":{d:.6},\"active_voices\":{},\"clipping\":{}}}{s}\n",
            .{
                case.name,
                snapshot.direct.gain,
                snapshot.direct.lowpass_hz,
                snapshot.transmission.gain,
                snapshot.transmission.lowpass_hz,
                snapshot.portal.gain,
                snapshot.portal.pan,
                snapshot.early_reflections[0].gain,
                snapshot.early_reflections[0].delay_frames,
                snapshot.late_reverb_send,
                snapshot.openness,
                snapshot.smoothing_ms,
                telemetry.rendered_frames,
                telemetry.peak_abs,
                telemetry.rms,
                telemetry.active_voices,
                telemetry.clipping_count,
                if (index + 1 == scenes.len) "" else ",",
            },
        );
    }
    try stdout.interface.writeAll("]\n");
    try stdout.interface.flush();
}

fn renderSnapshot(snapshot: bugu.acoustic.AcousticMixerSnapshot) !bugu.TelemetrySnapshot {
    var engine = try bugu.Engine.init(.{});
    if (snapshot.direct.valid) {
        try engine.startTestVoice(.{ .frequency_hz = 440, .gain = snapshot.direct.gain, .pan = snapshot.direct.pan, .lowpass_hz = snapshot.direct.lowpass_hz, .start_delay_frames = snapshot.direct.delay_frames });
    }
    if (snapshot.transmission.valid) {
        try engine.startTestVoice(.{ .frequency_hz = 330, .gain = snapshot.transmission.gain, .pan = snapshot.transmission.pan, .lowpass_hz = snapshot.transmission.lowpass_hz, .start_delay_frames = snapshot.transmission.delay_frames });
    }
    if (snapshot.portal.valid) {
        try engine.startTestVoice(.{ .frequency_hz = 550, .gain = snapshot.portal.gain, .pan = snapshot.portal.pan, .lowpass_hz = snapshot.portal.lowpass_hz, .start_delay_frames = snapshot.portal.delay_frames });
    }
    for (snapshot.early_reflections, 0..) |layer, i| {
        if (!layer.valid) continue;
        try engine.startTestVoice(.{
            .frequency_hz = 660 + @as(f32, @floatFromInt(i)) * 55,
            .gain = layer.gain,
            .pan = layer.pan,
            .lowpass_hz = layer.lowpass_hz,
            .start_delay_frames = layer.delay_frames,
        });
    }

    var output: [48_000 / 4 * 2]f32 = undefined;
    engine.render(&output, 48_000 / 4);
    return engine.telemetrySnapshot();
}
