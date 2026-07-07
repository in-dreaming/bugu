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
        } else {
            return error.UnknownArgument;
        }
    }

    var engine = try audio.Engine.init(.{});

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
    try stdout.interface.flush();
}
