const std = @import("std");
const bugu = @import("bugu_audio");

pub fn main(init: std.process.Init) !void {
    var engine = try bugu.Engine.init(.{});
    engine.setEffectBus(.reverb, .{
        .return_gain = 0.42,
        .feedback = 0.38,
        .crossfeed = 0.06,
    });

    try engine.startTestVoice(.{
        .frequency_hz = 440.0,
        .gain = 0.18,
        .pan = -0.35,
        .reverb_send = 0.85,
    });
    try engine.startTestVoice(.{
        .frequency_hz = 660.0,
        .gain = 0.12,
        .pan = 0.45,
        .reverb_send = 0.55,
        .start_delay_frames = 512,
    });

    var backend = bugu.OfflineBackend.init(&engine);
    const rendered = try backend.renderFrames(init.gpa, 12_000);
    init.gpa.free(rendered);

    const telemetry = engine.telemetrySnapshot();
    const effects = engine.effectBusSnapshot();
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print(
        "effect bus demo frames={} peak={d:.6} rms={d:.6} active={} clipping={} reverb_send_peak={d:.6} reverb_return_peak={d:.6} return_gain={d:.2} feedback={d:.2}\n",
        .{
            telemetry.rendered_frames,
            telemetry.peak_abs,
            telemetry.rms,
            telemetry.active_voices,
            telemetry.clipping_count,
            effects.reverb_send_peak,
            effects.reverb_return_peak,
            effects.reverb_return_gain,
            effects.reverb_feedback,
        },
    );
    try stdout.interface.flush();
}
