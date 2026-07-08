const std = @import("std");
const bugu = @import("bugu_audio");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);

    const allocator = std.heap.page_allocator;
    const listener = bugu.Vec3{ .x = -4, .y = 0, .z = 0 };
    const source = bugu.Vec3{ .x = 4, .y = 0, .z = 0 };

    const closed_door = [_]bugu.acoustic.AcousticPortal{
        .{ .id = 3, .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = 0.9, .area_open_m2 = 0.0, .max_area_m2 = 2.0, .material_id = bugu.acoustic.TestScenes.wood_id, .state = .closed },
    };
    const open_door = [_]bugu.acoustic.AcousticPortal{
        .{ .id = 3, .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = 0.9, .area_open_m2 = 2.0, .max_area_m2 = 2.0, .material_id = bugu.acoustic.TestScenes.wood_id, .state = .open },
    };

    const closed_response = try bugu.acoustic.solve(allocator, bugu.acoustic.TestScenes.doorOpening(&closed_door), listener, source, .{}, null);
    const open_response = try bugu.acoustic.solve(allocator, bugu.acoustic.TestScenes.doorOpening(&open_door), listener, source, .{}, null);
    const cave_response = try bugu.acoustic.solve(allocator, bugu.acoustic.TestScenes.cave(), listener, source, .{}, null);

    const closed_snapshot = bugu.acoustic.mapResponseToSnapshot(closed_response, .{});
    const open_snapshot = bugu.acoustic.mapResponseToSnapshot(open_response, .{});
    const cave_snapshot = bugu.acoustic.mapResponseToSnapshot(cave_response, .{});

    var engine = try bugu.Engine.init(.{});
    const portal_handle = try startLayer(&engine, closed_snapshot.portal, 550.0, closed_snapshot.late_reverb_send);
    try startOptionalLayer(&engine, closed_snapshot.transmission, 330.0, closed_snapshot.late_reverb_send);

    var backend = bugu.OfflineBackend.init(&engine);
    const before = try backend.renderFrames(allocator, 4800);
    allocator.free(before);

    try engine.updateVoice(portal_handle, .{
        .gain = open_snapshot.portal.gain,
        .pan = open_snapshot.portal.pan,
        .lowpass_hz = open_snapshot.portal.lowpass_hz,
        .reverb_send = open_snapshot.late_reverb_send,
    }, 4800);

    const after = try backend.renderFrames(allocator, 12_000);
    allocator.free(after);

    try startOptionalLayer(&engine, cave_snapshot.direct, 440.0, cave_snapshot.late_reverb_send);
    for (cave_snapshot.early_reflections, 0..) |layer, index| {
        if (!layer.valid) continue;
        try startOptionalLayer(&engine, layer, 660.0 + @as(f32, @floatFromInt(index)) * 45.0, cave_snapshot.late_reverb_send);
    }
    const cave = try backend.renderFrames(allocator, 12_000);
    allocator.free(cave);

    const telemetry = engine.telemetrySnapshot();
    try stdout.interface.print(
        "acoustic effects demo door_closed_portal={d:.5} door_open_portal={d:.5} cave_reverb={d:.5} frames={} peak={d:.6} rms={d:.6} active={} clipping={}\n",
        .{
            closed_snapshot.portal.gain,
            open_snapshot.portal.gain,
            cave_snapshot.late_reverb_send,
            telemetry.rendered_frames,
            telemetry.peak_abs,
            telemetry.rms,
            telemetry.active_voices,
            telemetry.clipping_count,
        },
    );
    try stdout.interface.flush();
}

fn startOptionalLayer(engine: *bugu.Engine, layer: bugu.acoustic.AcousticLayerParams, frequency: f32, reverb_send: f32) !void {
    if (!layer.valid or layer.gain <= 0.0) return;
    _ = try startLayer(engine, layer, frequency, reverb_send);
}

fn startLayer(engine: *bugu.Engine, layer: bugu.acoustic.AcousticLayerParams, frequency: f32, reverb_send: f32) !bugu.VoiceHandle {
    return engine.startTestVoiceWithHandle(.{
        .frequency_hz = frequency,
        .gain = layer.gain,
        .pan = layer.pan,
        .lowpass_hz = layer.lowpass_hz,
        .start_delay_frames = layer.delay_frames,
        .reverb_send = reverb_send,
    });
}
