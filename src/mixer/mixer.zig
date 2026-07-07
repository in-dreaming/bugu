const std = @import("std");
const core = @import("../core/engine.zig");
const builtin = @import("builtin");

pub const max_real_voices = 64;

pub const VoiceState = enum {
    free,
    starting,
    real,
    virtual,
    releasing,
    stolen,
    paused,
};

pub const BusId = enum {
    sfx,
    music,
    master,
};

pub const TestVoiceDesc = struct {
    frequency_hz: f32 = 440.0,
    gain: f32 = 0.2,
    priority: f32 = 1.0,
    bus: BusId = .sfx,
};

pub const SampleVoiceDesc = struct {
    samples: []const f32,
    gain: f32 = 0.2,
    priority: f32 = 1.0,
    bus: BusId = .sfx,
};

const Voice = struct {
    state: VoiceState = .free,
    source: enum { test_tone, sample } = .test_tone,
    phase: f32 = 0.0,
    phase_step: f32 = 0.0,
    samples: []const f32 = &.{},
    cursor: usize = 0,
    gain_current: f32 = 0.0,
    gain_target: f32 = 0.0,
    gain_step: f32 = 0.0,
    priority: f32 = 0.0,
    bus: BusId = .sfx,

    fn audibility(self: Voice) f32 {
        return self.priority * @max(self.gain_current, self.gain_target);
    }
};

pub const Mixer = struct {
    sample_rate: u32,
    voices: [max_real_voices]Voice = [_]Voice{.{}} ** max_real_voices,
    sfx_gain: f32 = 1.0,
    music_gain: f32 = 1.0,
    master_gain_current: f32 = 1.0,
    master_gain_target: f32 = 1.0,
    master_gain_step: f32 = 0.0,

    pub fn init(sample_rate: u32) Mixer {
        return .{ .sample_rate = sample_rate };
    }

    pub fn startTestVoice(self: *Mixer, desc: TestVoiceDesc, telemetry: *core.TelemetryCounters) core.BuguError!void {
        const index = self.findFreeVoice() orelse self.stealVoice(desc, telemetry);
        const voice = &self.voices[index];
        voice.* = .{
            .state = .starting,
            .source = .test_tone,
            .phase = 0.0,
            .phase_step = (2.0 * std.math.pi * desc.frequency_hz) / @as(f32, @floatFromInt(self.sample_rate)),
            .gain_current = 0.0,
            .gain_target = desc.gain,
            .gain_step = desc.gain / 128.0,
            .priority = desc.priority,
            .bus = desc.bus,
        };
    }

    pub fn startSampleVoice(self: *Mixer, desc: SampleVoiceDesc, telemetry: *core.TelemetryCounters) core.BuguError!void {
        if (desc.samples.len == 0) return core.BuguError.InvalidArgument;
        const index = self.findFreeVoice() orelse self.stealVoice(.{
            .gain = desc.gain,
            .priority = desc.priority,
            .bus = desc.bus,
        }, telemetry);
        const voice = &self.voices[index];
        voice.* = .{
            .state = .starting,
            .source = .sample,
            .samples = desc.samples,
            .cursor = 0,
            .gain_current = 0.0,
            .gain_target = desc.gain,
            .gain_step = desc.gain / 128.0,
            .priority = desc.priority,
            .bus = desc.bus,
        };
    }

    pub fn stopAll(self: *Mixer, release_frames: u32) void {
        const frames = @max(release_frames, 1);
        for (&self.voices) |*voice| {
            if (voice.state == .real or voice.state == .starting) {
                voice.state = .releasing;
                voice.gain_target = 0.0;
                voice.gain_step = -voice.gain_current / @as(f32, @floatFromInt(frames));
            }
        }
    }

    pub fn setBusGain(self: *Mixer, bus: BusId, gain: f32) void {
        switch (bus) {
            .sfx => self.sfx_gain = gain,
            .music => self.music_gain = gain,
            .master => self.master_gain_current = gain,
        }
    }

    pub fn setMasterGain(self: *Mixer, gain: f32, ramp_frames: u32) void {
        self.master_gain_target = gain;
        self.master_gain_step = (gain - self.master_gain_current) / @as(f32, @floatFromInt(@max(ramp_frames, 1)));
    }

    pub fn render(self: *Mixer, output: []f32, frame_count: u32, channels: u16, telemetry: *core.TelemetryCounters) void {
        const start_ns = nowNanos();
        @memset(output, 0.0);
        _ = telemetry.rendered_frames.fetchAdd(frame_count, .monotonic);
        _ = telemetry.rendered_quantums.fetchAdd(1, .monotonic);

        var peak: f32 = 0.0;
        var sum_squares: f64 = 0.0;
        var clipping: u64 = 0;

        var frame: u32 = 0;
        while (frame < frame_count) : (frame += 1) {
            self.advanceMasterRamp();

            var mixed_l: f32 = 0.0;
            var mixed_r: f32 = 0.0;

            for (&self.voices) |*voice| {
                switch (voice.state) {
                    .free, .stolen => {},
                    .virtual, .paused => {},
                    .starting, .real, .releasing => {
                        if (voice.state == .starting) voice.state = .real;
                        const source_sample = switch (voice.source) {
                            .test_tone => tone: {
                                const value = @sin(voice.phase);
                                voice.phase += voice.phase_step;
                                if (voice.phase >= 2.0 * std.math.pi) voice.phase -= 2.0 * std.math.pi;
                                break :tone value;
                            },
                            .sample => sample: {
                                if (voice.cursor >= voice.samples.len) {
                                    voice.state = .free;
                                    break :sample 0.0;
                                }
                                const value = voice.samples[voice.cursor];
                                voice.cursor += 1;
                                break :sample value;
                            },
                        };
                        const sample = source_sample * voice.gain_current;
                        self.advanceVoiceRamp(voice);

                        const bus_gain = switch (voice.bus) {
                            .sfx => self.sfx_gain,
                            .music => self.music_gain,
                            .master => 1.0,
                        };
                        const out_sample = sample * bus_gain * self.master_gain_current;
                        mixed_l += out_sample;
                        mixed_r += out_sample;
                    },
                }
            }

            if (mixed_l > 1.0 or mixed_l < -1.0) clipping += 1;
            if (mixed_r > 1.0 or mixed_r < -1.0) clipping += 1;
            mixed_l = std.math.clamp(mixed_l, -1.0, 1.0);
            mixed_r = std.math.clamp(mixed_r, -1.0, 1.0);

            peak = @max(peak, @abs(mixed_l));
            peak = @max(peak, @abs(mixed_r));
            sum_squares += @as(f64, @floatCast(mixed_l * mixed_l));
            sum_squares += @as(f64, @floatCast(mixed_r * mixed_r));

            const base = @as(usize, frame) * channels;
            output[base] = mixed_l;
            output[base + 1] = mixed_r;
        }

        telemetry.recordPeak(peak);
        telemetry.storeRms(@floatCast(@sqrt(sum_squares / @as(f64, @floatFromInt(frame_count * 2)))));
        const counts = self.countVoices();
        telemetry.active_voices.store(counts.active, .monotonic);
        telemetry.virtual_voices.store(counts.virtual, .monotonic);
        _ = telemetry.clipping_count.fetchAdd(clipping, .monotonic);
        const end_ns = nowNanos();
        if (end_ns > start_ns) {
            telemetry.mixer_time_nanos.store(end_ns - start_ns, .monotonic);
        }
    }

    fn findFreeVoice(self: *Mixer) ?usize {
        for (self.voices, 0..) |voice, index| {
            if (voice.state == .free) return index;
        }
        return null;
    }

    fn countVoices(self: *const Mixer) struct { active: u32, virtual: u32 } {
        var active: u32 = 0;
        var virtual: u32 = 0;
        for (self.voices) |voice| {
            switch (voice.state) {
                .starting, .real, .releasing, .paused => active += 1,
                .virtual => virtual += 1,
                .free, .stolen => {},
            }
        }
        return .{ .active = active, .virtual = virtual };
    }

    fn stealVoice(self: *Mixer, desc: TestVoiceDesc, telemetry: *core.TelemetryCounters) usize {
        _ = desc;
        var weakest_index: usize = 0;
        var weakest_score: f32 = std.math.floatMax(f32);
        for (self.voices, 0..) |voice, index| {
            const score = voice.audibility();
            if (score < weakest_score) {
                weakest_score = score;
                weakest_index = index;
            }
        }
        self.voices[weakest_index].state = .stolen;
        _ = telemetry.stolen_voices.fetchAdd(1, .monotonic);
        return weakest_index;
    }

    fn advanceVoiceRamp(self: *Mixer, voice: *Voice) void {
        _ = self;
        if (voice.gain_step == 0.0) return;
        const next = voice.gain_current + voice.gain_step;
        if ((voice.gain_step > 0.0 and next >= voice.gain_target) or
            (voice.gain_step < 0.0 and next <= voice.gain_target))
        {
            voice.gain_current = voice.gain_target;
            voice.gain_step = 0.0;
            if (voice.state == .releasing and voice.gain_current == 0.0) {
                voice.state = .free;
            }
        } else {
            voice.gain_current = next;
        }
    }

    fn advanceMasterRamp(self: *Mixer) void {
        if (self.master_gain_step == 0.0) return;
        const next = self.master_gain_current + self.master_gain_step;
        if ((self.master_gain_step > 0.0 and next >= self.master_gain_target) or
            (self.master_gain_step < 0.0 and next <= self.master_gain_target))
        {
            self.master_gain_current = self.master_gain_target;
            self.master_gain_step = 0.0;
        } else {
            self.master_gain_current = next;
        }
    }
};

fn nowNanos() u64 {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var counter: windows.LARGE_INTEGER = 0;
        var frequency: windows.LARGE_INTEGER = 0;
        if (!windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool()) return 0;
        if (!windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool()) return 0;
        if (frequency <= 0 or counter <= 0) return 0;
        return @intCast(@divTrunc(@as(i128, counter) * std.time.ns_per_s, frequency));
    }
    return 0;
}

test "mixer renders 64 real voices and steals beyond limit" {
    var mixer = Mixer.init(48_000);
    var telemetry: core.TelemetryCounters = .{};
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        try mixer.startTestVoice(.{
            .frequency_hz = 220.0 + @as(f32, @floatFromInt(i)),
            .gain = 0.01,
            .priority = @floatFromInt(i + 1),
        }, &telemetry);
    }

    var buffer: [256 * 2]f32 = undefined;
    mixer.render(&buffer, 256, 2, &telemetry);
    const snap = telemetry.snapshot();
    try std.testing.expectEqual(@as(u32, 64), snap.active_voices);
    try std.testing.expectEqual(@as(u64, 64), snap.stolen_voices);
    try std.testing.expect(snap.peak_abs > 0.0);
    try std.testing.expect(snap.rms > 0.0);
}

test "gain ramp releases without discontinuous hard stop" {
    var mixer = Mixer.init(48_000);
    var telemetry: core.TelemetryCounters = .{};
    try mixer.startTestVoice(.{ .frequency_hz = 440.0, .gain = 0.2 }, &telemetry);
    var buffer: [256 * 2]f32 = undefined;
    mixer.render(&buffer, 256, 2, &telemetry);
    mixer.stopAll(128);
    mixer.render(&buffer, 256, 2, &telemetry);
    try std.testing.expect(telemetry.snapshot().peak_abs > 0.0);
}

test "rapid start stop and master ramp stay bounded" {
    var mixer = Mixer.init(48_000);
    var telemetry: core.TelemetryCounters = .{};
    var buffer: [256 * 2]f32 = undefined;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try mixer.startTestVoice(.{
            .frequency_hz = 110.0 + @as(f32, @floatFromInt(i % 64)),
            .gain = 0.005,
            .priority = 1.0,
        }, &telemetry);
        mixer.stopAll(8);
        mixer.render(buffer[0 .. 8 * 2], 8, 2, &telemetry);
    }

    mixer.setMasterGain(0.5, 128);
    try mixer.startTestVoice(.{ .frequency_hz = 550.0, .gain = 0.1 }, &telemetry);
    mixer.render(&buffer, 256, 2, &telemetry);

    const snap = telemetry.snapshot();
    try std.testing.expect(snap.peak_abs <= 1.0);
    try std.testing.expect(snap.rms > 0.0);
    try std.testing.expect(snap.clipping_count == 0);
}
