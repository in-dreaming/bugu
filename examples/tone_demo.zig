const std = @import("std");
const audio = @import("bugu_audio");

const Mode = enum {
    offline,
    device,
};

pub fn main(init: std.process.Init) !void {
    var mode: Mode = .offline;
    var seconds: f32 = 2.0;
    var out_path: []const u8 = "bugu-tone.wav";
    var voices: u32 = 8;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--device")) {
            mode = .device;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            mode = .offline;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            const value = args.next() orelse return error.MissingSecondsValue;
            seconds = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args.next() orelse return error.MissingOutValue;
        } else if (std.mem.eql(u8, arg, "--voices")) {
            const value = args.next() orelse return error.MissingVoicesValue;
            voices = try std.fmt.parseInt(u32, value, 10);
        } else {
            return error.UnknownArgument;
        }
    }

    var engine = try audio.Engine.init(.{});
    try configureDemoVoices(&engine, voices);

    switch (mode) {
        .offline => {
            var backend = audio.OfflineBackend.init(&engine);
            try backend.renderWavFile(init.io, out_path, seconds);
            const telemetry = engine.telemetrySnapshot();
            try printTelemetry(init.io, "offline", seconds, telemetry, out_path);
        },
        .device => {
            var backend = audio.MiniaudioBackend.init(&engine);
            defer backend.deinit();
            try backend.open(.{});
            try backend.start();
            try std.Io.sleep(init.io, .fromNanoseconds(@intFromFloat(seconds * std.time.ns_per_s)), .boot);
            backend.stop();
            const telemetry = engine.telemetrySnapshot();
            try printTelemetry(init.io, "device", seconds, telemetry, null);
        },
    }
}

fn printTelemetry(io: std.Io, mode: []const u8, seconds: f32, telemetry: audio.TelemetrySnapshot, out_path: ?[]const u8) !void {
    var buffer: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("bugu tone demo mode={s} seconds={d:.2}\n", .{ mode, seconds });
    if (out_path) |path| {
        try stdout.interface.print("output={s}\n", .{path});
    }
    try stdout.interface.print(
        "callbacks={} frames={} quantums={} underruns={} dropouts={} max_callback_ns={} peak_abs={d:.6}\n",
        .{
            telemetry.callback_count,
            telemetry.rendered_frames,
            telemetry.rendered_quantums,
            telemetry.underrun_count,
            telemetry.dropout_count,
            telemetry.max_callback_nanos,
            telemetry.peak_abs,
        },
    );
    try stdout.interface.print(
        "active={} virtual={} stolen={} clipping={} rms={d:.6} mixer_time_ns={}\n",
        .{
            telemetry.active_voices,
            telemetry.virtual_voices,
            telemetry.stolen_voices,
            telemetry.clipping_count,
            telemetry.rms,
            telemetry.mixer_time_nanos,
        },
    );
    try stdout.interface.flush();
}

fn configureDemoVoices(engine: *audio.Engine, voices: u32) !void {
    const active_budget = @min(@max(voices, 1), 64);
    const gain = @min(0.025, 0.45 / @as(f32, @floatFromInt(active_budget)));
    var i: u32 = 0;
    while (i < voices) : (i += 1) {
        try engine.startTestVoice(.{
            .frequency_hz = 220.0 + 55.0 * @as(f32, @floatFromInt(i)),
            .gain = gain,
            .priority = @floatFromInt(i + 1),
            .bus = if (i == 0) .music else .sfx,
        });
    }
}
