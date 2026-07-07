const std = @import("std");
const ToneRenderer = @import("../mixer/tone_renderer.zig").ToneRenderer;

pub const BuguError = error{
    InvalidState,
    InvalidArgument,
    DeviceUnavailable,
    DeviceStartFailed,
    DeviceStopFailed,
    FileWriteFailed,
};

pub const EngineConfig = struct {
    sample_rate: u32 = 48_000,
    quantum_frames: u32 = 256,
    channels: u16 = 2,
    frequency_hz: f32 = 440.0,
    amplitude: f32 = 0.20,
};

pub const TelemetrySnapshot = struct {
    callback_count: u64,
    rendered_frames: u64,
    rendered_quantums: u64,
    underrun_count: u64,
    dropout_count: u64,
    max_callback_nanos: u64,
    peak_abs: f32,
};

pub const TelemetryCounters = struct {
    callback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rendered_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rendered_quantums: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    underrun_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropout_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_callback_nanos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak_abs_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn snapshot(self: *const TelemetryCounters) TelemetrySnapshot {
        return .{
            .callback_count = self.callback_count.load(.monotonic),
            .rendered_frames = self.rendered_frames.load(.monotonic),
            .rendered_quantums = self.rendered_quantums.load(.monotonic),
            .underrun_count = self.underrun_count.load(.monotonic),
            .dropout_count = self.dropout_count.load(.monotonic),
            .max_callback_nanos = self.max_callback_nanos.load(.monotonic),
            .peak_abs = @bitCast(self.peak_abs_bits.load(.monotonic)),
        };
    }

    pub fn recordPeak(self: *TelemetryCounters, peak: f32) void {
        var current_bits = self.peak_abs_bits.load(.monotonic);
        while (true) {
            const current: f32 = @bitCast(current_bits);
            if (peak <= current) return;
            const new_bits: u32 = @bitCast(peak);
            current_bits = self.peak_abs_bits.cmpxchgWeak(
                current_bits,
                new_bits,
                .monotonic,
                .monotonic,
            ) orelse return;
        }
    }

    pub fn recordCallbackNanos(self: *TelemetryCounters, nanos: u64) void {
        var current = self.max_callback_nanos.load(.monotonic);
        while (nanos > current) {
            current = self.max_callback_nanos.cmpxchgWeak(
                current,
                nanos,
                .monotonic,
                .monotonic,
            ) orelse return;
        }
    }
};

pub const Engine = struct {
    config: EngineConfig,
    renderer: ToneRenderer,
    telemetry: TelemetryCounters = .{},

    pub fn init(config: EngineConfig) BuguError!Engine {
        if (config.sample_rate == 0 or config.quantum_frames == 0 or config.quantum_frames > 1024 or config.channels != 2) {
            return BuguError.InvalidArgument;
        }
        return .{
            .config = config,
            .renderer = ToneRenderer.init(config.sample_rate, config.frequency_hz, config.amplitude),
        };
    }

    pub fn render(self: *Engine, output: []f32, frame_count: u32) void {
        self.renderer.render(output, frame_count, self.config.channels, &self.telemetry);
    }

    pub fn telemetrySnapshot(self: *const Engine) TelemetrySnapshot {
        return self.telemetry.snapshot();
    }
};

test "engine renders nonzero stereo samples" {
    var engine = try Engine.init(.{});
    var buffer: [512]f32 = undefined;
    engine.render(&buffer, 256);
    const telemetry = engine.telemetrySnapshot();
    try std.testing.expectEqual(@as(u64, 256), telemetry.rendered_frames);
    try std.testing.expectEqual(@as(u64, 1), telemetry.rendered_quantums);
    try std.testing.expect(telemetry.peak_abs > 0.0);
}
