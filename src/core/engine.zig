const std = @import("std");
const mixer = @import("../mixer/mixer.zig");

pub const BuguError = error{
    InvalidState,
    InvalidArgument,
    DeviceUnavailable,
    DeviceStartFailed,
    DeviceStopFailed,
    FileWriteFailed,
    NoVoiceAvailable,
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
    callback_p50_nanos: u64,
    callback_p95_nanos: u64,
    callback_p99_nanos: u64,
    peak_abs: f32,
    rms: f32,
    active_voices: u32,
    virtual_voices: u32,
    stolen_voices: u64,
    clipping_count: u64,
    mixer_time_nanos: u64,
};

pub const callback_histogram_buckets = 32;

pub const EffectBusSnapshot = mixer.EffectBusSnapshot;

pub const TelemetryCounters = struct {
    callback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rendered_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rendered_quantums: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    underrun_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropout_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_callback_nanos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    callback_histogram: [callback_histogram_buckets]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** callback_histogram_buckets,
    peak_abs_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    rms_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    active_voices: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    virtual_voices: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    stolen_voices: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    clipping_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mixer_time_nanos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn snapshot(self: *const TelemetryCounters) TelemetrySnapshot {
        const quantiles = self.callbackQuantiles();
        return .{
            .callback_count = self.callback_count.load(.monotonic),
            .rendered_frames = self.rendered_frames.load(.monotonic),
            .rendered_quantums = self.rendered_quantums.load(.monotonic),
            .underrun_count = self.underrun_count.load(.monotonic),
            .dropout_count = self.dropout_count.load(.monotonic),
            .max_callback_nanos = self.max_callback_nanos.load(.monotonic),
            .callback_p50_nanos = quantiles.p50,
            .callback_p95_nanos = quantiles.p95,
            .callback_p99_nanos = quantiles.p99,
            .peak_abs = @bitCast(self.peak_abs_bits.load(.monotonic)),
            .rms = @bitCast(self.rms_bits.load(.monotonic)),
            .active_voices = self.active_voices.load(.monotonic),
            .virtual_voices = self.virtual_voices.load(.monotonic),
            .stolen_voices = self.stolen_voices.load(.monotonic),
            .clipping_count = self.clipping_count.load(.monotonic),
            .mixer_time_nanos = self.mixer_time_nanos.load(.monotonic),
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
        _ = self.callback_histogram[histogramBucket(nanos)].fetchAdd(1, .monotonic);
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

    fn callbackQuantiles(self: *const TelemetryCounters) struct { p50: u64, p95: u64, p99: u64 } {
        var counts: [callback_histogram_buckets]u64 = undefined;
        var total: u64 = 0;
        for (&counts, &self.callback_histogram) |*destination, *source| {
            destination.* = source.load(.acquire);
            total +|= destination.*;
        }
        if (total == 0) return .{ .p50 = 0, .p95 = 0, .p99 = 0 };
        return .{ .p50 = histogramQuantile(&counts, total, 50), .p95 = histogramQuantile(&counts, total, 95), .p99 = histogramQuantile(&counts, total, 99) };
    }

    pub fn storeRms(self: *TelemetryCounters, rms: f32) void {
        self.rms_bits.store(@bitCast(rms), .monotonic);
    }
};

fn histogramBucket(nanos: u64) usize {
    if (nanos <= 1) return 0;
    const bits = 64 - @clz(nanos - 1);
    return @min(callback_histogram_buckets - 1, bits);
}

fn histogramQuantile(counts: *const [callback_histogram_buckets]u64, total: u64, percentile: u64) u64 {
    const rank = @max(1, (total *| percentile +| 99) / 100);
    var cumulative: u64 = 0;
    for (counts, 0..) |count, index| {
        cumulative +|= count;
        if (cumulative >= rank) return @as(u64, 1) << @intCast(index);
    }
    return @as(u64, 1) << (callback_histogram_buckets - 1);
}

test "callback histogram aggregates bounded quantiles outside render" {
    var telemetry: TelemetryCounters = .{};
    for (0..50) |_| telemetry.recordCallbackNanos(100);
    for (0..45) |_| telemetry.recordCallbackNanos(1_000);
    for (0..5) |_| telemetry.recordCallbackNanos(10_000);
    const value = telemetry.snapshot();
    try std.testing.expectEqual(@as(u64, 128), value.callback_p50_nanos);
    try std.testing.expectEqual(@as(u64, 1_024), value.callback_p95_nanos);
    try std.testing.expectEqual(@as(u64, 16_384), value.callback_p99_nanos);
    try std.testing.expectEqual(@as(u64, 10_000), value.max_callback_nanos);
}

pub const Engine = struct {
    config: EngineConfig,
    mixer: mixer.Mixer,
    telemetry: TelemetryCounters = .{},

    pub fn init(config: EngineConfig) BuguError!Engine {
        if (config.sample_rate == 0 or config.quantum_frames == 0 or config.quantum_frames > 1024 or config.channels != 2) {
            return BuguError.InvalidArgument;
        }
        return .{
            .config = config,
            .mixer = mixer.Mixer.init(config.sample_rate),
        };
    }

    pub fn render(self: *Engine, output: []f32, frame_count: u32) void {
        self.mixer.render(output, frame_count, self.config.channels, &self.telemetry);
    }

    pub fn startTestVoice(self: *Engine, desc: mixer.TestVoiceDesc) BuguError!void {
        return self.mixer.startTestVoice(desc, &self.telemetry);
    }

    pub fn startTestVoiceWithHandle(self: *Engine, desc: mixer.TestVoiceDesc) BuguError!mixer.VoiceHandle {
        return self.mixer.startTestVoiceWithHandle(desc, &self.telemetry);
    }

    pub fn startSampleVoice(self: *Engine, desc: mixer.SampleVoiceDesc) BuguError!void {
        return self.mixer.startSampleVoice(desc, &self.telemetry);
    }

    pub fn startSampleVoiceWithHandle(self: *Engine, desc: mixer.SampleVoiceDesc) BuguError!mixer.VoiceHandle {
        return self.mixer.startSampleVoiceWithHandle(desc, &self.telemetry);
    }

    pub fn updateVoice(self: *Engine, handle: mixer.VoiceHandle, params: mixer.VoiceControlParams, ramp_frames: u32) BuguError!void {
        return self.mixer.updateVoice(handle, params, ramp_frames);
    }

    pub fn stopAllVoices(self: *Engine, release_frames: u32) void {
        self.mixer.stopAll(release_frames);
    }

    pub fn setBusGain(self: *Engine, bus: mixer.BusId, gain: f32) void {
        self.mixer.setBusGain(bus, gain);
    }

    pub fn setMasterGain(self: *Engine, gain: f32, ramp_frames: u32) void {
        self.mixer.setMasterGain(gain, ramp_frames);
    }

    pub fn setEffectBus(self: *Engine, bus: mixer.EffectBusId, params: mixer.EffectBusControlParams) void {
        self.mixer.setEffectBus(bus, params);
    }

    pub fn effectBusSnapshot(self: *const Engine) mixer.EffectBusSnapshot {
        return self.mixer.effectBusSnapshot();
    }

    pub fn telemetrySnapshot(self: *const Engine) TelemetrySnapshot {
        return self.telemetry.snapshot();
    }
};

test "engine renders nonzero stereo samples" {
    var engine = try Engine.init(.{});
    try engine.startTestVoice(.{ .frequency_hz = 440.0, .gain = 0.2 });
    var buffer: [512]f32 = undefined;
    engine.render(&buffer, 256);
    const telemetry = engine.telemetrySnapshot();
    try std.testing.expectEqual(@as(u64, 256), telemetry.rendered_frames);
    try std.testing.expectEqual(@as(u64, 1), telemetry.rendered_quantums);
    try std.testing.expectEqual(@as(u32, 1), telemetry.active_voices);
    try std.testing.expect(telemetry.peak_abs > 0.0);
    try std.testing.expect(telemetry.rms > 0.0);
}
