const std = @import("std");
const audio = @import("bugu_audio");

pub fn main(init: std.process.Init) !void {
    const profile: audio.AttenuationProfile = .{
        .min_distance = 1.0,
        .max_distance = 20.0,
        .curve = .inverse,
        .cone = .{
            .inner_degrees = 60,
            .outer_degrees = 140,
            .outer_gain = 0.25,
            .outer_lowpass_hz = 1400,
        },
        .min_pitch_ratio = 0.5,
        .max_pitch_ratio = 2.0,
    };

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);

    const emitter_base: audio.Transform = .{
        .position = .{ .x = 0, .y = 0, .z = 0 },
        .forward = .{ .x = 0, .y = 0, .z = 1 },
    };

    try stdout.interface.writeAll("spatial orbit trajectory\n");
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi * 0.25;
        const listener: audio.Transform = .{
            .position = .{ .x = @cos(angle) * 6.0, .y = 0, .z = @sin(angle) * 6.0 },
            .right = .{ .x = 1, .y = 0, .z = 0 },
        };
        const p = audio.evaluateSpatial(listener, emitter_base, profile);
        try stdout.interface.print(
            "orbit step={} listener=({d:.2},{d:.2},{d:.2}) distance={d:.3} gain={d:.4} pan={d:.4} lowpass={d:.1} pitch={d:.4}\n",
            .{ i, listener.position.x, listener.position.y, listener.position.z, p.distance, p.gain, p.pan, p.lowpass_hz, p.pitch_ratio },
        );
    }

    try stdout.interface.writeAll("spatial cone and doppler checks\n");
    const listener_front: audio.Transform = .{ .position = .{ .x = 0, .y = 0, .z = 6 } };
    const facing_away: audio.Transform = .{
        .position = .{},
        .forward = .{ .x = 0, .y = 0, .z = -1 },
    };
    const cone = audio.evaluateSpatial(listener_front, facing_away, profile);
    try stdout.interface.print("cone back-facing gain={d:.4} cone_gain={d:.4} lowpass={d:.1}\n", .{ cone.gain, cone.cone_gain, cone.lowpass_hz });

    const fast: audio.Transform = .{
        .position = .{ .x = 0, .y = 0, .z = 10 },
        .forward = .{ .x = 0, .y = 0, .z = -1 },
        .velocity = .{ .x = 0, .y = 0, .z = -180 },
    };
    const doppler = audio.evaluateSpatial(.{}, fast, profile);
    try stdout.interface.print("doppler relative_velocity=-180 pitch={d:.4} clamp=[0.5,2.0]\n", .{doppler.pitch_ratio});

    var engine = try audio.Engine.init(.{});
    try engine.startTestVoice(.{
        .frequency_hz = 440,
        .gain = doppler.gain * 0.4,
        .priority = 1,
        .pan = doppler.pan,
        .lowpass_hz = doppler.lowpass_hz,
    });
    var backend = audio.OfflineBackend.init(&engine);
    try backend.renderWavFile(init.io, "bugu-spatial-render.wav", 0.2);
    const t = engine.telemetrySnapshot();
    try stdout.interface.print("spatial render frames={} peak={d:.6} rms={d:.6} active={} clipping={}\n", .{ t.rendered_frames, t.peak_abs, t.rms, t.active_voices, t.clipping_count });
    try stdout.interface.flush();
}
