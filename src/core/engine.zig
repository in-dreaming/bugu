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
    UnsupportedChannelLayout,
    ArithmeticOverflow,
    VoiceBudgetExceeded,
    MisalignedStems,
    StaleAssetGeneration,
};

pub const EngineConfig = struct {
    sample_rate: u32 = 48_000,
    quantum_frames: u32 = 256,
    channels: u16 = 2,
    output_layout: ?mixer.channel_layout.ChannelLayout = null,
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
    rms: f32,
    active_voices: u32,
    virtual_voices: u32,
    stolen_voices: u64,
    clipping_count: u64,
    mixer_time_nanos: u64,
};

pub const EffectBusSnapshot = mixer.EffectBusSnapshot;

pub const TelemetryCounters = struct {
    callback_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rendered_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rendered_quantums: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    underrun_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropout_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_callback_nanos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak_abs_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    rms_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    active_voices: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    virtual_voices: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    stolen_voices: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    clipping_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mixer_time_nanos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn snapshot(self: *const TelemetryCounters) TelemetrySnapshot {
        return .{
            .callback_count = self.callback_count.load(.monotonic),
            .rendered_frames = self.rendered_frames.load(.monotonic),
            .rendered_quantums = self.rendered_quantums.load(.monotonic),
            .underrun_count = self.underrun_count.load(.monotonic),
            .dropout_count = self.dropout_count.load(.monotonic),
            .max_callback_nanos = self.max_callback_nanos.load(.monotonic),
            .peak_abs = @bitCast(self.peak_abs_bits.load(.monotonic)),
            .rms = @bitCast(self.rms_bits.load(.monotonic)),
            .active_voices = self.active_voices.load(.monotonic),
            .virtual_voices = self.virtual_voices.load(.monotonic),
            .stolen_voices = self.stolen_voices.load(.monotonic),
            .clipping_count = self.clipping_count.load(.monotonic),
            .mixer_time_nanos = self.mixer_time_nanos.load(.monotonic),
        };
    }

    /// Callback telemetry is single-writer in each Engine/RuntimeRenderer.
    /// One strong CAS is exact for that contract and has no retry loop. If an
    /// unsupported concurrent writer races, this sample is best-effort only;
    /// it cannot overwrite a newer maximum with a smaller value.
    pub fn recordPeak(self: *TelemetryCounters, peak: f32) void {
        if (!std.math.isFinite(peak) or peak < 0) return;
        const current_bits = self.peak_abs_bits.load(.monotonic);
        const current: f32 = @bitCast(current_bits);
        if (peak <= current) return;
        _ = self.peak_abs_bits.cmpxchgStrong(current_bits, @bitCast(peak), .monotonic, .monotonic);
    }

    pub fn recordCallbackNanos(self: *TelemetryCounters, nanos: u64) void {
        const current = self.max_callback_nanos.load(.monotonic);
        if (nanos <= current) return;
        _ = self.max_callback_nanos.cmpxchgStrong(current, nanos, .monotonic, .monotonic);
    }

    pub fn storeRms(self: *TelemetryCounters, rms: f32) void {
        self.rms_bits.store(@bitCast(rms), .monotonic);
    }
};

pub const Engine = struct {
    config: EngineConfig,
    mixer: mixer.Mixer,
    telemetry: TelemetryCounters = .{},
    group_storage: [mixer.music_group.max_groups]mixer.music_group.Prepared = undefined,

    pub fn init(config: EngineConfig) BuguError!Engine {
        if (config.sample_rate == 0 or config.quantum_frames == 0 or config.quantum_frames > 1024 or config.channels == 0 or config.channels > 8) {
            return BuguError.InvalidArgument;
        }
        const layout = config.output_layout orelse try mixer.channel_layout.ChannelLayout.fromCount(config.channels);
        if (layout.count != config.channels) return error.UnsupportedChannelLayout;
        return .{ .config = config, .mixer = try mixer.Mixer.initWithLayout(config.sample_rate, layout) };
    }

    pub fn render(self: *Engine, output: []f32, frame_count: u32) void {
        self.mixer.render(output, frame_count, self.config.channels, &self.telemetry);
    }

    pub fn startMusicGroup(self: *Engine, desc: mixer.music_group.MusicGroupDesc) BuguError!mixer.music_group.Handle {
        const index = for (self.mixer.groups, 0..) |group, i| {
            if (group.state == .free or group.state == .finished) break i;
        } else return error.VoiceBudgetExceeded;
        const prepared = try mixer.music_group.Prepared.prepare(desc, self.mixer.output_layout, self.config.sample_rate);
        if (!self.mixer.canStartGroup(&prepared)) return error.VoiceBudgetExceeded;
        self.mixer.group_generation = std.math.add(u64, self.mixer.group_generation, 1) catch return error.InvalidState;
        self.group_storage[index] = prepared;
        return self.mixer.startMusicGroupReserved(&self.group_storage[index], self.telemetry.rendered_frames.load(.monotonic), self.mixer.group_generation).group;
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

test "TASK-025 callback telemetry maxima are bounded and reject invalid peaks" {
    var counters: TelemetryCounters = .{};
    counters.recordPeak(0.25);
    counters.recordPeak(0.1);
    counters.recordPeak(std.math.nan(f32));
    counters.recordPeak(std.math.inf(f32));
    counters.recordPeak(-1);
    try std.testing.expectEqual(@as(f32, 0.25), counters.snapshot().peak_abs);
    counters.recordPeak(0.5);
    counters.recordCallbackNanos(10);
    counters.recordCallbackNanos(5);
    counters.recordCallbackNanos(20);
    try std.testing.expectEqual(@as(f32, 0.5), counters.snapshot().peak_abs);
    try std.testing.expectEqual(@as(u64, 20), counters.snapshot().max_callback_nanos);
}
