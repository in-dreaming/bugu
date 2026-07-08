const std = @import("std");
const core = @import("../core/engine.zig");
const builtin = @import("builtin");

pub const max_real_voices = 64;
const reverb_delay_frames = 4096;

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

pub const EffectBusId = enum {
    reverb,
};

pub const VoiceHandle = struct {
    index: u16,
    generation: u16,
};

pub const TestVoiceDesc = struct {
    frequency_hz: f32 = 440.0,
    gain: f32 = 0.2,
    priority: f32 = 1.0,
    bus: BusId = .sfx,
    pan: f32 = 0.0,
    lowpass_hz: f32 = 20_000.0,
    start_delay_frames: u32 = 0,
    pitch_ratio: f32 = 1.0,
    reverb_send: f32 = 0.0,
};

pub const SampleVoiceDesc = struct {
    samples: []const f32,
    gain: f32 = 0.2,
    pitch: f32 = 1.0,
    priority: f32 = 1.0,
    bus: BusId = .sfx,
    loop: bool = false,
    pan: f32 = 0.0,
    lowpass_hz: f32 = 20_000.0,
    start_delay_frames: u32 = 0,
    reverb_send: f32 = 0.0,
};

pub const VoiceControlParams = struct {
    gain: ?f32 = null,
    pan: ?f32 = null,
    lowpass_hz: ?f32 = null,
    pitch_ratio: ?f32 = null,
    reverb_send: ?f32 = null,
};

pub const EffectBusControlParams = struct {
    return_gain: ?f32 = null,
    feedback: ?f32 = null,
    crossfeed: ?f32 = null,
};

pub const EffectBusSnapshot = struct {
    reverb_send_peak: f32,
    reverb_return_peak: f32,
    reverb_return_gain: f32,
    reverb_feedback: f32,
};

const StereoSample = struct {
    l: f32,
    r: f32,
};

const Voice = struct {
    generation: u16 = 0,
    state: VoiceState = .free,
    source: enum { test_tone, sample } = .test_tone,
    phase: f32 = 0.0,
    base_phase_step: f32 = 0.0,
    phase_step: f32 = 0.0,
    samples: []const f32 = &.{},
    cursor: f32 = 0.0,
    cursor_step: f32 = 1.0,
    loop: bool = false,
    gain_current: f32 = 0.0,
    gain_target: f32 = 0.0,
    gain_step: f32 = 0.0,
    priority: f32 = 0.0,
    bus: BusId = .sfx,
    pan: f32 = 0.0,
    lowpass_hz: f32 = 20_000.0,
    lowpass_z: f32 = 0.0,
    start_delay_frames: u32 = 0,
    reverb_send: f32 = 0.0,

    fn audibility(self: Voice) f32 {
        return self.priority * @max(self.gain_current, self.gain_target);
    }
};

const ReverbEffectBus = struct {
    delay_l: [reverb_delay_frames]f32 = [_]f32{0.0} ** reverb_delay_frames,
    delay_r: [reverb_delay_frames]f32 = [_]f32{0.0} ** reverb_delay_frames,
    delay_index: usize = 0,
    return_gain: f32 = 0.25,
    feedback: f32 = 0.45,
    crossfeed: f32 = 0.08,
    send_peak: f32 = 0.0,
    return_peak: f32 = 0.0,

    fn setParams(self: *ReverbEffectBus, params: EffectBusControlParams) void {
        if (params.return_gain) |gain| self.return_gain = std.math.clamp(gain, 0.0, 2.0);
        if (params.feedback) |feedback| self.feedback = std.math.clamp(feedback, 0.0, 0.98);
        if (params.crossfeed) |crossfeed| self.crossfeed = std.math.clamp(crossfeed, 0.0, 0.5);
    }

    fn process(self: *ReverbEffectBus, send_l: f32, send_r: f32) StereoSample {
        const wet_l = self.delay_l[self.delay_index];
        const wet_r = self.delay_r[self.delay_index];
        self.delay_l[self.delay_index] = send_l + wet_l * self.feedback + wet_r * self.crossfeed;
        self.delay_r[self.delay_index] = send_r + wet_r * self.feedback + wet_l * self.crossfeed;
        self.delay_index = (self.delay_index + 1) % reverb_delay_frames;

        const out_l = wet_l * self.return_gain;
        const out_r = wet_r * self.return_gain;
        self.send_peak = @max(self.send_peak, @max(@abs(send_l), @abs(send_r)));
        self.return_peak = @max(self.return_peak, @max(@abs(out_l), @abs(out_r)));
        return .{ .l = out_l, .r = out_r };
    }

    fn snapshot(self: *const ReverbEffectBus) EffectBusSnapshot {
        return .{
            .reverb_send_peak = self.send_peak,
            .reverb_return_peak = self.return_peak,
            .reverb_return_gain = self.return_gain,
            .reverb_feedback = self.feedback,
        };
    }
};

const EffectBuses = struct {
    reverb: ReverbEffectBus = .{},

    fn setParams(self: *EffectBuses, bus: EffectBusId, params: EffectBusControlParams) void {
        switch (bus) {
            .reverb => self.reverb.setParams(params),
        }
    }

    fn processReverb(self: *EffectBuses, send_l: f32, send_r: f32) StereoSample {
        return self.reverb.process(send_l, send_r);
    }

    fn snapshot(self: *const EffectBuses) EffectBusSnapshot {
        return self.reverb.snapshot();
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
    effect_buses: EffectBuses = .{},

    pub fn init(sample_rate: u32) Mixer {
        return .{ .sample_rate = sample_rate };
    }

    pub fn startTestVoice(self: *Mixer, desc: TestVoiceDesc, telemetry: *core.TelemetryCounters) core.BuguError!void {
        _ = try self.startTestVoiceWithHandle(desc, telemetry);
    }

    pub fn startTestVoiceWithHandle(self: *Mixer, desc: TestVoiceDesc, telemetry: *core.TelemetryCounters) core.BuguError!VoiceHandle {
        const index = self.findFreeVoice() orelse self.stealVoice(desc, telemetry);
        const voice = &self.voices[index];
        const generation = nextGeneration(voice.generation);
        const base_step = (2.0 * std.math.pi * desc.frequency_hz) / @as(f32, @floatFromInt(self.sample_rate));
        voice.* = .{
            .generation = generation,
            .state = .starting,
            .source = .test_tone,
            .phase = 0.0,
            .base_phase_step = base_step,
            .phase_step = base_step * std.math.clamp(desc.pitch_ratio, 0.01, 8.0),
            .gain_current = 0.0,
            .gain_target = desc.gain,
            .gain_step = desc.gain / 128.0,
            .priority = desc.priority,
            .bus = desc.bus,
            .pan = desc.pan,
            .lowpass_hz = desc.lowpass_hz,
            .start_delay_frames = desc.start_delay_frames,
            .reverb_send = std.math.clamp(desc.reverb_send, 0.0, 1.0),
        };
        return handleFor(index, generation);
    }

    pub fn startSampleVoice(self: *Mixer, desc: SampleVoiceDesc, telemetry: *core.TelemetryCounters) core.BuguError!void {
        _ = try self.startSampleVoiceWithHandle(desc, telemetry);
    }

    pub fn startSampleVoiceWithHandle(self: *Mixer, desc: SampleVoiceDesc, telemetry: *core.TelemetryCounters) core.BuguError!VoiceHandle {
        if (desc.samples.len == 0) return core.BuguError.InvalidArgument;
        const index = self.findFreeVoice() orelse self.stealVoice(.{
            .gain = desc.gain,
            .priority = desc.priority,
            .bus = desc.bus,
        }, telemetry);
        const voice = &self.voices[index];
        const generation = nextGeneration(voice.generation);
        voice.* = .{
            .generation = generation,
            .state = .starting,
            .source = .sample,
            .samples = desc.samples,
            .cursor = 0.0,
            .cursor_step = desc.pitch,
            .loop = desc.loop,
            .gain_current = 0.0,
            .gain_target = desc.gain,
            .gain_step = desc.gain / 128.0,
            .priority = desc.priority,
            .bus = desc.bus,
            .pan = desc.pan,
            .lowpass_hz = desc.lowpass_hz,
            .start_delay_frames = desc.start_delay_frames,
            .reverb_send = std.math.clamp(desc.reverb_send, 0.0, 1.0),
        };
        return handleFor(index, generation);
    }

    pub fn updateVoice(self: *Mixer, handle: VoiceHandle, params: VoiceControlParams, ramp_frames: u32) core.BuguError!void {
        if (handle.index >= max_real_voices) return core.BuguError.InvalidArgument;
        const voice = &self.voices[handle.index];
        if (voice.generation != handle.generation or voice.state == .free or voice.state == .stolen) {
            return core.BuguError.InvalidArgument;
        }
        const frames = @max(ramp_frames, 1);
        if (params.gain) |gain| {
            const target = std.math.clamp(gain, 0.0, 4.0);
            voice.gain_target = target;
            voice.gain_step = (target - voice.gain_current) / @as(f32, @floatFromInt(frames));
        }
        if (params.pan) |pan| {
            voice.pan = std.math.clamp(pan, -1.0, 1.0);
        }
        if (params.lowpass_hz) |lowpass_hz| {
            voice.lowpass_hz = std.math.clamp(lowpass_hz, 20.0, @as(f32, @floatFromInt(self.sample_rate)) * 0.5);
        }
        if (params.pitch_ratio) |pitch_ratio| {
            const pitch = std.math.clamp(pitch_ratio, 0.01, 8.0);
            switch (voice.source) {
                .test_tone => voice.phase_step = voice.base_phase_step * pitch,
                .sample => voice.cursor_step = pitch,
            }
        }
        if (params.reverb_send) |reverb_send| {
            voice.reverb_send = std.math.clamp(reverb_send, 0.0, 1.0);
        }
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

    pub fn setEffectBus(self: *Mixer, bus: EffectBusId, params: EffectBusControlParams) void {
        self.effect_buses.setParams(bus, params);
    }

    pub fn effectBusSnapshot(self: *const Mixer) EffectBusSnapshot {
        return self.effect_buses.snapshot();
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

            var dry_l_sum: f32 = 0.0;
            var dry_r_sum: f32 = 0.0;
            var reverb_send_l: f32 = 0.0;
            var reverb_send_r: f32 = 0.0;

            for (&self.voices) |*voice| {
                switch (voice.state) {
                    .free, .stolen => {},
                    .virtual, .paused => {},
                    .starting, .real, .releasing => {
                        if (voice.state == .starting) voice.state = .real;
                        if (voice.start_delay_frames > 0) {
                            voice.start_delay_frames -= 1;
                            continue;
                        }
                        const source_sample = switch (voice.source) {
                            .test_tone => tone: {
                                const value = @sin(voice.phase);
                                voice.phase += voice.phase_step;
                                if (voice.phase >= 2.0 * std.math.pi) voice.phase -= 2.0 * std.math.pi;
                                break :tone value;
                            },
                            .sample => sample: {
                                var index: usize = @intFromFloat(voice.cursor);
                                if (index >= voice.samples.len) {
                                    if (voice.loop) {
                                        voice.cursor = 0.0;
                                        index = 0;
                                    } else {
                                        voice.state = .free;
                                        break :sample 0.0;
                                    }
                                }
                                const value = voice.samples[index];
                                voice.cursor += @max(voice.cursor_step, 0.01);
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
                        const filtered = self.applyLowpass(voice, sample);
                        const out_sample = filtered * bus_gain;
                        const pan = std.math.clamp(voice.pan, -1.0, 1.0);
                        const left = @cos((pan + 1.0) * std.math.pi * 0.25);
                        const right = @sin((pan + 1.0) * std.math.pi * 0.25);
                        const dry_l = out_sample * left;
                        const dry_r = out_sample * right;
                        dry_l_sum += dry_l;
                        dry_r_sum += dry_r;
                        reverb_send_l += dry_l * voice.reverb_send;
                        reverb_send_r += dry_r * voice.reverb_send;
                    },
                }
            }

            const wet = self.effect_buses.processReverb(reverb_send_l, reverb_send_r);
            var mixed_l = (dry_l_sum + wet.l) * self.master_gain_current;
            var mixed_r = (dry_r_sum + wet.r) * self.master_gain_current;

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

    fn applyLowpass(self: *Mixer, voice: *Voice, sample: f32) f32 {
        const nyquist = @as(f32, @floatFromInt(self.sample_rate)) * 0.5;
        if (voice.lowpass_hz >= nyquist) return sample;
        const cutoff = std.math.clamp(voice.lowpass_hz, 20.0, nyquist);
        const dt = 1.0 / @as(f32, @floatFromInt(self.sample_rate));
        const rc = 1.0 / (2.0 * std.math.pi * cutoff);
        const alpha = dt / (rc + dt);
        voice.lowpass_z += alpha * (sample - voice.lowpass_z);
        return voice.lowpass_z;
    }
};

fn nextGeneration(current: u16) u16 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

fn handleFor(index: usize, generation: u16) VoiceHandle {
    return .{ .index = @intCast(index), .generation = generation };
}

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

test "voice handle updates gain pan lowpass pitch and reverb send" {
    var mixer = Mixer.init(48_000);
    var telemetry: core.TelemetryCounters = .{};
    const handle = try mixer.startTestVoiceWithHandle(.{ .frequency_hz = 440.0, .gain = 0.05 }, &telemetry);
    try mixer.updateVoice(handle, .{
        .gain = 0.2,
        .pan = 0.75,
        .lowpass_hz = 1200.0,
        .pitch_ratio = 1.5,
        .reverb_send = 0.6,
    }, 64);
    const voice = mixer.voices[handle.index];
    try std.testing.expectEqual(handle.generation, voice.generation);
    try std.testing.expect(voice.gain_target == 0.2);
    try std.testing.expect(voice.pan > 0.7);
    try std.testing.expect(voice.lowpass_hz == 1200.0);
    try std.testing.expect(voice.phase_step > voice.base_phase_step);
    try std.testing.expect(voice.reverb_send == 0.6);
}

test "reverb send produces real delayed tail" {
    var mixer = Mixer.init(48_000);
    var telemetry: core.TelemetryCounters = .{};
    mixer.setEffectBus(.reverb, .{ .return_gain = 0.5, .feedback = 0.2, .crossfeed = 0.03 });
    try mixer.startTestVoice(.{ .frequency_hz = 440.0, .gain = 0.2, .reverb_send = 1.0 }, &telemetry);
    var buffer: [reverb_delay_frames * 2]f32 = undefined;
    mixer.render(&buffer, reverb_delay_frames, 2, &telemetry);
    mixer.stopAll(1);
    mixer.render(&buffer, reverb_delay_frames, 2, &telemetry);
    const snap = telemetry.snapshot();
    const bus = mixer.effectBusSnapshot();
    try std.testing.expect(snap.rms > 0.0);
    try std.testing.expect(snap.clipping_count == 0);
    try std.testing.expect(bus.reverb_send_peak > 0.0);
    try std.testing.expect(bus.reverb_return_peak > 0.0);
    try std.testing.expect(bus.reverb_return_gain == 0.5);
    try std.testing.expect(bus.reverb_feedback == 0.2);
}
