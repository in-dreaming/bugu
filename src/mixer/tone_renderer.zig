const std = @import("std");
const TelemetryCounters = @import("../core/engine.zig").TelemetryCounters;

pub const ToneRenderer = struct {
    phase: f32 = 0.0,
    phase_step: f32,
    amplitude: f32,

    pub fn init(sample_rate: u32, frequency_hz: f32, amplitude: f32) ToneRenderer {
        return .{
            .phase_step = (2.0 * std.math.pi * frequency_hz) / @as(f32, @floatFromInt(sample_rate)),
            .amplitude = amplitude,
        };
    }

    pub fn render(
        self: *ToneRenderer,
        output: []f32,
        frame_count: u32,
        channels: u16,
        telemetry: *TelemetryCounters,
    ) void {
        _ = telemetry.rendered_frames.fetchAdd(frame_count, .monotonic);
        _ = telemetry.rendered_quantums.fetchAdd(1, .monotonic);

        var peak: f32 = 0.0;
        var frame: u32 = 0;
        while (frame < frame_count) : (frame += 1) {
            const sample = @sin(self.phase) * self.amplitude;
            self.phase += self.phase_step;
            if (self.phase >= 2.0 * std.math.pi) {
                self.phase -= 2.0 * std.math.pi;
            }
            peak = @max(peak, @abs(sample));

            const base = @as(usize, frame) * channels;
            var channel: usize = 0;
            while (channel < channels) : (channel += 1) {
                output[base + channel] = sample;
            }
        }
        telemetry.recordPeak(peak);
    }
};
