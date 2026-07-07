const std = @import("std");
const audio = @import("bugu_audio");

const WavSpec = struct {
    id: []const u8,
    path: []const u8,
    frequency: f32,
};

const wavs = [_]WavSpec{
    .{ .id = "weapon_0", .path = "bugu-event-weapon-0.wav", .frequency = 260.0 },
    .{ .id = "weapon_1", .path = "bugu-event-weapon-1.wav", .frequency = 290.0 },
    .{ .id = "weapon_2", .path = "bugu-event-weapon-2.wav", .frequency = 320.0 },
    .{ .id = "weapon_3", .path = "bugu-event-weapon-3.wav", .frequency = 350.0 },
    .{ .id = "weapon_4", .path = "bugu-event-weapon-4.wav", .frequency = 380.0 },
    .{ .id = "foot_wood", .path = "bugu-event-foot-wood.wav", .frequency = 520.0 },
    .{ .id = "foot_metal", .path = "bugu-event-foot-metal.wav", .frequency = 760.0 },
    .{ .id = "ambience", .path = "bugu-event-ambience.wav", .frequency = 120.0 },
};

pub fn main(init: std.process.Init) !void {
    for (wavs) |wav| try generateWav(init.io, wav.path, wav.frequency, 0.2, 0.22);

    var sources: [wavs.len]audio.ImportSource = undefined;
    for (wavs, 0..) |wav, i| sources[i] = .{ .id = wav.id, .path = wav.path };
    _ = try audio.importToBank(init.io, init.gpa, &sources, "bugu-event-bank.toml", "bugu-event-bank.blob");
    var bank = try audio.loadBank(init.io, init.gpa, "bugu-event-bank.toml", "bugu-event-bank.blob");
    defer bank.deinit();

    const weapon_refs = [_]audio.SoundRef{
        refFor(&bank, "weapon_0", 0.10, 1),
        refFor(&bank, "weapon_1", 0.10, 2),
        refFor(&bank, "weapon_2", 0.10, 3),
        refFor(&bank, "weapon_3", 0.10, 4),
        refFor(&bank, "weapon_4", 0.10, 5),
    };
    const wood_refs = [_]audio.SoundRef{refFor(&bank, "foot_wood", 0.12, 1)};
    const metal_refs = [_]audio.SoundRef{refFor(&bank, "foot_metal", 0.12, 1)};
    const ambience_refs = [_]audio.SoundRef{refFor(&bank, "ambience", 0.08, 1)};

    const surface = audio.hashEventName("surface");
    const metal = audio.hashEventName("metal");
    const loudness = audio.hashEventName("rtpc.loudness");
    const foot_cases = [_]audio.SwitchCase{.{
        .value = metal,
        .event = .{ .variants = &metal_refs },
    }};
    const events = [_]audio.EventEntry{
        .{ .id = audio.hashEventName("weapon.fire"), .action = .{ .play = .{
            .variants = &weapon_refs,
            .random = true,
            .volume_rtpc = .{ .parameter = loudness, .input_min = 0.0, .input_max = 1.0, .output_min = 0.25, .output_max = 1.0 },
        } } },
        .{ .id = audio.hashEventName("footstep"), .action = .{ .switch_play = .{
            .group = surface,
            .cases = &foot_cases,
            .default = .{ .variants = &wood_refs },
        } } },
        .{ .id = audio.hashEventName("ambience.start"), .action = .{ .play = .{ .variants = &ambience_refs, .loop = true } } },
        .{ .id = audio.hashEventName("ambience.stop"), .action = .{ .stop_all = 128 } },
    };

    var engine = try audio.Engine.init(.{});
    var runtime = audio.EventRuntime.init(&events);
    runtime.setRtpc(loudness, 0.5);

    var fire_indices: [5]u32 = undefined;
    for (&fire_indices) |*slot| {
        const result = try runtime.postEvent(&engine, audio.hashEventName("weapon.fire"));
        slot.* = result.random_index;
    }
    runtime.setSwitch(surface, metal);
    const footstep = try runtime.postEvent(&engine, audio.hashEventName("footstep"));
    _ = try runtime.postEvent(&engine, audio.hashEventName("ambience.start"));

    var backend = audio.OfflineBackend.init(&engine);
    try backend.renderWavFile(init.io, "bugu-event-render.wav", 0.2);
    const before_stop = engine.telemetrySnapshot();
    _ = try runtime.postEvent(&engine, audio.hashEventName("ambience.stop"));
    try backend.renderWavFile(init.io, "bugu-event-stop-render.wav", 0.1);
    const after_stop = engine.telemetrySnapshot();

    try printSummary(init.io, fire_indices, footstep, before_stop, after_stop);
}

fn refFor(bank: *const audio.Bank, id: []const u8, gain: f32, priority: f32) audio.SoundRef {
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

fn printSummary(
    io: std.Io,
    fire_indices: [5]u32,
    footstep: audio.events.PostResult,
    before_stop: audio.TelemetrySnapshot,
    after_stop: audio.TelemetrySnapshot,
) !void {
    var buffer: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print(
        "event demo weapon.fire random_indices={},{},{},{},{}\n",
        .{ fire_indices[0], fire_indices[1], fire_indices[2], fire_indices[3], fire_indices[4] },
    );
    try stdout.interface.print(
        "event demo footstep switch_value={} voices_requested={}\n",
        .{ footstep.switch_value.?, footstep.voices_requested },
    );
    try stdout.interface.print(
        "event demo before_stop active={} peak={d:.6} rms={d:.6} stolen={} clipping={}\n",
        .{ before_stop.active_voices, before_stop.peak_abs, before_stop.rms, before_stop.stolen_voices, before_stop.clipping_count },
    );
    try stdout.interface.print(
        "event demo after_stop active={} peak={d:.6} rms={d:.6} stolen={} clipping={}\n",
        .{ after_stop.active_voices, after_stop.peak_abs, after_stop.rms, after_stop.stolen_voices, after_stop.clipping_count },
    );
    try stdout.interface.flush();
}
