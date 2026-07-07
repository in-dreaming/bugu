const std = @import("std");
const audio = @import("bugu_audio");

const GeneratedWav = struct {
    id: []const u8,
    path: []const u8,
    frequency: f32,
    channels: u16,
};

const generated = [_]GeneratedWav{
    .{ .id = "tone_a_mono", .path = "bugu-asset-a.wav", .frequency = 330.0, .channels = 1 },
    .{ .id = "tone_b_stereo", .path = "bugu-asset-b.wav", .frequency = 440.0, .channels = 2 },
    .{ .id = "tone_c_mono", .path = "bugu-asset-c.wav", .frequency = 550.0, .channels = 1 },
};

pub fn main(init: std.process.Init) !void {
    const manifest_path = "bugu-bank.toml";
    const blob_path = "bugu-bank.blob";
    const render_path = "bugu-bank-render.wav";

    for (generated) |wav| {
        try generateWav(init.io, wav.path, wav.frequency, wav.channels, 0.25, 0.25);
    }

    const sources = [_]audio.ImportSource{
        .{ .id = generated[0].id, .path = generated[0].path },
        .{ .id = generated[1].id, .path = generated[1].path },
        .{ .id = generated[2].id, .path = generated[2].path },
    };

    const summary = try audio.importToBank(init.io, init.gpa, &sources, manifest_path, blob_path);
    var bank = try audio.loadBank(init.io, init.gpa, manifest_path, blob_path);
    defer bank.deinit();

    var engine = try audio.Engine.init(.{});
    for (generated, 0..) |wav, index| {
        const entry = bank.find(wav.id) orelse return error.MissingGeneratedSound;
        try engine.startSampleVoice(.{
            .samples = entry.samples,
            .gain = 0.18,
            .priority = @floatFromInt(index + 1),
            .bus = if (index == 1) .music else .sfx,
        });
    }

    var backend = audio.OfflineBackend.init(&engine);
    try backend.renderWavFile(init.io, render_path, 0.2);
    const telemetry = engine.telemetrySnapshot();

    try printSummary(init.io, summary, &bank, telemetry);
}

fn generateWav(io: std.Io, path: []const u8, frequency: f32, channels: u16, seconds: f32, amplitude: f32) !void {
    const sample_rate: u32 = 48_000;
    const frames: u32 = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * seconds);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writeWavHeader(&writer.interface, frames, sample_rate, channels);

    var frame: u32 = 0;
    while (frame < frames) : (frame += 1) {
        const phase = (2.0 * std.math.pi * frequency * @as(f32, @floatFromInt(frame))) / @as(f32, @floatFromInt(sample_rate));
        const sample: i16 = @intFromFloat(@sin(phase) * amplitude * 32767.0);
        var channel: u16 = 0;
        while (channel < channels) : (channel += 1) {
            try writer.interface.writeInt(i16, sample, .little);
        }
    }
    try writer.interface.flush();
}

fn writeWavHeader(writer: *std.Io.Writer, frame_count: u32, sample_rate: u32, channels: u16) !void {
    const bits_per_sample: u16 = 16;
    const block_align: u16 = channels * (bits_per_sample / 8);
    const byte_rate: u32 = sample_rate * block_align;
    const data_bytes: u32 = frame_count * block_align;
    const riff_size: u32 = 36 + data_bytes;

    try writer.writeAll("RIFF");
    try writer.writeInt(u32, riff_size, .little);
    try writer.writeAll("WAVE");
    try writer.writeAll("fmt ");
    try writer.writeInt(u32, 16, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, channels, .little);
    try writer.writeInt(u32, sample_rate, .little);
    try writer.writeInt(u32, byte_rate, .little);
    try writer.writeInt(u16, block_align, .little);
    try writer.writeInt(u16, bits_per_sample, .little);
    try writer.writeAll("data");
    try writer.writeInt(u32, data_bytes, .little);
}

fn printSummary(io: std.Io, summary: audio.ImportSummary, bank: *const audio.Bank, telemetry: audio.TelemetrySnapshot) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print(
        "asset demo imported={} total_frames={} blob_bytes={} import_peak={d:.6}\n",
        .{ summary.source_count, summary.total_frames, summary.blob_bytes, summary.peak },
    );
    for (bank.entries) |entry| {
        try stdout.interface.print(
            "sound id={s} rate={} source_channels={} frames={} offset={} peak={d:.6} rms={d:.6}\n",
            .{ entry.id, entry.sample_rate, entry.source_channels, entry.frames, entry.blob_offset_bytes, entry.peak, entry.rms },
        );
    }
    try stdout.interface.print(
        "render callbacks={} frames={} active={} peak={d:.6} rms={d:.6} stolen={} clipping={}\n",
        .{
            telemetry.callback_count,
            telemetry.rendered_frames,
            telemetry.active_voices,
            telemetry.peak_abs,
            telemetry.rms,
            telemetry.stolen_voices,
            telemetry.clipping_count,
        },
    );
    try stdout.interface.flush();
}
