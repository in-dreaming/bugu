const std = @import("std");
const bugu = @import("bugu_audio");

const listener = bugu.Vec3{ .x = -4, .y = 0, .z = 0 };
const source = bugu.Vec3{ .x = 4, .y = 0, .z = 0 };

pub fn main(init: std.process.Init) !void {
    try generateWav(init.io, "bugu-acoustic-event-loop.wav", 180.0, 0.35, 0.20);

    const sources = [_]bugu.ImportSource{.{ .id = "door_loop", .path = "bugu-acoustic-event-loop.wav" }};
    _ = try bugu.importToBank(init.io, init.gpa, &sources, "bugu-acoustic-event-bank.toml", "bugu-acoustic-event-bank.blob");
    var bank = try bugu.loadBank(init.io, init.gpa, "bugu-acoustic-event-bank.toml", "bugu-acoustic-event-bank.blob");
    defer bank.deinit();

    const closed_snapshot = try solveDoorSnapshot(init.gpa, false);
    const open_snapshot = try solveDoorSnapshot(init.gpa, true);

    const refs = [_]bugu.SoundRef{refFor(&bank, "door_loop", 0.95, 2.0)};
    const events = [_]bugu.EventEntry{.{
        .id = bugu.hashEventName("door.acoustic.loop"),
        .action = .{ .play = .{ .variants = &refs, .loop = true } },
    }};

    var engine = try bugu.Engine.init(.{});
    var runtime = bugu.EventRuntime.init(&events);
    var posted = try runtime.postAcousticEvent(&engine, bugu.hashEventName("door.acoustic.loop"), closed_snapshot);

    var backend = bugu.OfflineBackend.init(&engine);
    const before = try backend.renderFrames(init.gpa, 4800);
    init.gpa.free(before);
    const before_telemetry = engine.telemetrySnapshot();

    const new_layers = try posted.instance.update(&engine, open_snapshot, 35.0);
    const after = try backend.renderFrames(init.gpa, 16_000);
    init.gpa.free(after);
    const after_telemetry = engine.telemetrySnapshot();

    var out_buffer: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);
    try stdout.interface.print(
        "acoustic event demo closed_direct={d:.5} closed_portal={d:.5} open_direct={d:.5} open_portal={d:.5} post_layers={} update_new_layers={} direct_handle={} portal_handle={} frames={} peak={d:.6} rms={d:.6} active={} clipping={}\n",
        .{
            closed_snapshot.direct.gain,
            closed_snapshot.portal.gain,
            open_snapshot.direct.gain,
            open_snapshot.portal.gain,
            posted.post.voices_requested,
            new_layers,
            posted.instance.handles.direct != null,
            posted.instance.handles.portal != null,
            after_telemetry.rendered_frames,
            after_telemetry.peak_abs,
            after_telemetry.rms,
            after_telemetry.active_voices,
            after_telemetry.clipping_count,
        },
    );
    try stdout.interface.print(
        "acoustic event demo before_frames={} before_rms={d:.6} voice_handle={}\n",
        .{ before_telemetry.rendered_frames, before_telemetry.rms, posted.post.voice_handle != null },
    );
    try stdout.interface.flush();
}

fn solveDoorSnapshot(allocator: std.mem.Allocator, open: bool) !bugu.AcousticMixerSnapshot {
    const portals = [_]bugu.acoustic.AcousticPortal{.{
        .id = 4,
        .center = .{ .x = 0, .y = 0, .z = 0 },
        .radius = 0.9,
        .area_open_m2 = if (open) 2.0 else 0.0,
        .max_area_m2 = 2.0,
        .material_id = bugu.acoustic.TestScenes.wood_id,
        .state = if (open) .open else .closed,
    }};
    const response = try bugu.solveAcoustic(allocator, bugu.acoustic.TestScenes.doorOpening(&portals), listener, source, .{}, null);
    return bugu.mapAcousticResponseToSnapshot(response, .{});
}

fn refFor(bank: *const bugu.Bank, id: []const u8, gain: f32, priority: f32) bugu.SoundRef {
    const entry = bank.find(id) orelse @panic("missing generated sound");
    return .{
        .id = id,
        .samples = entry.samples,
        .gain = gain,
        .priority = priority,
    };
}

fn generateWav(io: std.Io, path: []const u8, frequency: f32, seconds: f32, amplitude: f32) !void {
    const sample_rate: u32 = 48_000;
    const frames: u32 = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * seconds);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writeWavHeader(&writer.interface, frames, sample_rate);
    var frame: u32 = 0;
    while (frame < frames) : (frame += 1) {
        const phase = (2.0 * std.math.pi * frequency * @as(f32, @floatFromInt(frame))) / @as(f32, @floatFromInt(sample_rate));
        try writer.interface.writeInt(i16, @intFromFloat(@sin(phase) * amplitude * 32767.0), .little);
    }
    try writer.interface.flush();
}

fn writeWavHeader(writer: *std.Io.Writer, frame_count: u32, sample_rate: u32) !void {
    const data_bytes = frame_count * 2;
    try writer.writeAll("RIFF");
    try writer.writeInt(u32, 36 + data_bytes, .little);
    try writer.writeAll("WAVEfmt ");
    try writer.writeInt(u32, 16, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u32, sample_rate, .little);
    try writer.writeInt(u32, sample_rate * 2, .little);
    try writer.writeInt(u16, 2, .little);
    try writer.writeInt(u16, 16, .little);
    try writer.writeAll("data");
    try writer.writeInt(u32, data_bytes, .little);
}
