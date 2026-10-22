//! Offline-only deterministic audio quality scanner. Never call from render.
//! Policy: tests/fixtures/sme/audio-quality/quality-policy.toml (version 1).
//! Numerical coefficients: ITU-R BS.1770-5 Annexes 1/2/3, November 2023.
//! This is a fixed 4x true-peak estimator, not an ideal analog-peak guarantee.
const std = @import("std");
const schema = @import("sme-bank").schema;
pub const Layout = schema.Layout;
pub const Stage = schema.QualityStage;
pub const Severity = schema.QualitySeverity;
pub const Verdict = schema.Verdict;
pub const LoudnessState = schema.LoudnessState;
pub const Hash = [32]u8;
pub const algorithm_version: u32 = 2;
/// Local maxima are not reliable continuity baselines with only a few waveform
/// phases. Insufficient support is availability, never evidence of a click.
pub const loop_minimum_support_frames: u32 = 64;
pub const policy_id = "Bugu.QualityPolicyV1";
pub const sample_rate: u32 = 48_000;
pub const max_channels = 8;
pub const maximum_frames: u64 = 2_073_600_000;
pub const loudness_window_frames = 19_200;
pub const loudness_hop_frames = 4_800;
pub const absolute_gate_lufs: f64 = -70;
pub const relative_gate_lu: f64 = -10;
pub const true_peak_oversample: u8 = 4;
pub const Error = error{ InvalidPcm, NonFiniteSample, SampleOutOfRange, InvalidSampleRate, UnsupportedLayout, InvalidLoop, InvalidPolicy, MissingRequiredMeasurement, MissingEncodedHash, ResourceLimitExceeded, AudioQualityGateFailed } || std.mem.Allocator.Error;
/// Detailed compiler diagnostics converge on the existing bank error domain.
pub fn bankError(err: Error) schema.BankError {
    return switch (err) {
        error.OutOfMemory => error.ResourceLimitExceeded,
        error.InvalidSampleRate => error.InvalidSampleRate,
        error.ResourceLimitExceeded => error.ResourceLimitExceeded,
        error.MissingRequiredMeasurement => error.MissingRequiredPass,
        else => error.AudioQualityGateFailed,
    };
}
pub const Measurement = enum(u5) { sample_peak, true_peak, rms, lufs, dc, loop };
pub fn measurementBit(m: Measurement) u32 {
    return @as(u32, 1) << @intFromEnum(m);
}
pub const required_base_measurements: u32 = 0x1f;
pub const Issue = enum(u5) { dc_offset, loop_seam, loop_slope, loop_dc, lufs_range, true_peak, loop_insufficient, loudness_unavailable, missing_measurement };
pub fn issueBit(i: Issue) u32 {
    return @as(u32, 1) << @intFromEnum(i);
}
pub const Range = struct { minimum: f64, maximum: f64 };
pub const QualityPolicyV1 = struct {
    version: u32 = 1,
    dc_absolute_maximum: f64 = 0.001,
    dc_severity: Severity = .warn,
    normalized_true_peak_maximum_dbtp: f64 = 0,
    normalized_true_peak_severity: Severity = .warn,
    loop_window_frames: u32 = 256,
    loop_seam_excess_maximum: f64 = 0.01,
    loop_slope_excess_maximum: f64 = 0.02,
    loop_dc_difference_maximum: f64 = 0.01,
    loop_severity: Severity = .warn,
    require_loop: bool = false,
    lufs_range: ?Range = null,
    lufs_severity: Severity = .report_only,
    require_lufs_range: bool = false,
    required_measurements: u32 = required_base_measurements,
};
pub const Loop = struct { start: u64, end: u64 };
pub const Input = struct {
    samples: []const f32,
    layout: Layout,
    channel_mask: u32,
    source_hash: Hash,
    sample_rate_hz: u32 = sample_rate,
    stage: Stage = .normalized,
    encoded_hash: ?Hash = null,
    profile_hash: Hash = @splat(0),
    loop: ?Loop = null,
};
pub const Speaker = struct {
    mask_bit: u32 = 0,
    azimuth_degrees: i16 = 0,
    elevation_degrees: i16 = 0,
    lfe: bool = false,
    loudness_weight: f64 = 0,
};
pub const LoopState = enum { not_requested, measured, insufficient_duration };
pub const LoopMetrics = struct {
    state: LoopState = .not_requested,
    window_frames: u32 = 0,
    seam_delta: f64 = 0,
    difference_before: f64 = 0,
    difference_after: f64 = 0,
    slope_change_before: f64 = 0,
    slope_change_after: f64 = 0,
    dc_before: f64 = 0,
    dc_after: f64 = 0,
    dc_difference: f64 = 0,
    local_max_difference: f64 = 0,
    local_max_slope_change: f64 = 0,
    seam_excess: f64 = 0,
    slope_excess: f64 = 0,
    dc_anomaly: bool = false,
};
pub const ChannelReport = struct {
    speaker: Speaker = .{},
    sample_peak: f64 = 0,
    true_peak: f64 = 0,
    rms: f64 = 0,
    dc: f64 = 0,
    loop: LoopMetrics = .{},
};
pub const Report = struct {
    version: u32 = 1,
    algorithm_version: u32 = algorithm_version,
    source_hash: Hash,
    encoded_hash: ?Hash,
    audio_hash: Hash,
    policy_hash: Hash,
    effective_policy_hash: Hash,
    profile_hash: Hash,
    stage: Stage,
    sample_rate_hz: u32 = sample_rate,
    layout: Layout,
    channel_mask: u32,
    channels: u8,
    frames: u64,
    completed_measurements: u32 = 0,
    policy: QualityPolicyV1,
    channel: [max_channels]ChannelReport = @splat(.{}),
    sample_peak: f64 = 0,
    sample_peak_dbfs: f64 = 0,
    true_peak: f64 = 0,
    true_peak_dbtp: f64 = 0,
    peak_silence: bool = true,
    rms: f64 = 0,
    integrated_lufs: f64 = 0,
    loudness_state: LoudnessState = .insufficient_duration,
    loudness_window_frames: u32 = loudness_window_frames,
    loudness_hop_frames: u32 = loudness_hop_frames,
    absolute_gate_lufs: f64 = absolute_gate_lufs,
    relative_gate_lu: f64 = relative_gate_lu,
    measured_relative_gate_lufs: f64 = 0,
    loudness_blocks: u64 = 0,
    absolute_gated_blocks: u64 = 0,
    relative_gated_blocks: u64 = 0,
    true_peak_oversample: u8 = true_peak_oversample,
    loop_minimum_support_frames: u32 = loop_minimum_support_frames,
    loop: ?Loop,
    warnings: u32 = 0,
    failures: u32 = 0,
    verdict: Verdict = .pass,

    /// Explicit-field JSON, never native struct bytes/padding or wall-clock data.
    pub fn canonicalJson(self: Report, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
    pub fn requirePassed(self: Report) Error!void {
        if (self.failures != 0 or self.verdict == .fail) return error.AudioQualityGateFailed;
        var required = self.policy.required_measurements | required_base_measurements;
        if (self.policy.require_loop) required |= measurementBit(.loop);
        if (self.completed_measurements & required != required) return error.MissingRequiredMeasurement;
    }
};

// Fixed BS.1770-5 Annex 2 numerical specification, tap-major, phase-minor.
const fir: [12][4]f64 = .{
    .{ 0.0017089843750, -0.0291748046875, -0.0189208984375, -0.0083007812500 },
    .{ 0.0109863281250, 0.0292968750000, 0.0330810546875, 0.0148925781250 },
    .{ -0.0196533203125, -0.0517578125000, -0.0582275390625, -0.0266113281250 },
    .{ 0.0332031250000, 0.0891113281250, 0.1015625000000, 0.0476074218750 },
    .{ -0.0594482421875, -0.1665039062500, -0.2003173828125, -0.1022949218750 },
    .{ 0.1373291015625, 0.4650878906250, 0.7797851562500, 0.9721679687500 },
    .{ 0.9721679687500, 0.7797851562500, 0.4650878906250, 0.1373291015625 },
    .{ -0.1022949218750, -0.2003173828125, -0.1665039062500, -0.0594482421875 },
    .{ 0.0476074218750, 0.1015625000000, 0.0891113281250, 0.0332031250000 },
    .{ -0.0266113281250, -0.0582275390625, -0.0517578125000, -0.0196533203125 },
    .{ 0.0148925781250, 0.0330810546875, 0.0292968750000, 0.0109863281250 },
    .{ -0.0083007812500, -0.0189208984375, -0.0291748046875, 0.0017089843750 },
};
const shelf_b = [3]f64{ 1.53512485958697, -2.69169618940638, 1.19839281085285 };
const shelf_a = [2]f64{ -1.69065929318241, 0.73248077421585 };
const high_b = [3]f64{ 1, -2, 1 };
const high_a = [2]f64{ -1.99004745483398, 0.99007225036621 };
const Biquad = struct {
    z1: f64 = 0,
    z2: f64 = 0,
    fn tick(self: *Biquad, x: f64, b: [3]f64, a: [2]f64) f64 {
        @setFloatMode(.strict);
        const y = b[0] * x + self.z1;
        self.z1 = b[1] * x - a[0] * y + self.z2;
        self.z2 = b[2] * x - a[1] * y;
        return y;
    }
};
const State = struct {
    shelf: Biquad = .{},
    high: Biquad = .{},
    history: [12]f64 = @splat(0),
    energy: f64 = 0,
    sum: f64 = 0,
};

pub fn speakers(layout: Layout, mask: u32) Error!struct { count: u8, values: [8]Speaker } {
    const canonical: ?u32 = switch (layout) {
        .mono => 4,
        .stereo => 3,
        .surround_5_1 => 0x3f,
        .surround_7_1 => 0x63f,
        .explicit_mask => null,
    };
    if (canonical) |known| {
        if (mask != known) return error.UnsupportedLayout;
    }
    const count = @popCount(mask);
    if (count == 0 or count > max_channels or mask & ~@as(u32, 0x3ffff) != 0) return error.UnsupportedLayout;
    var out: [8]Speaker = @splat(.{});
    const azimuth = [_]i16{ 30, -30, 0, 0, 135, -135, 15, -15, 180, 90, -90, 0, 30, 0, -30, 135, 180, -135 };
    var c: usize = 0;
    for (0..18) |bit| {
        const flag = @as(u32, 1) << @as(u5, @intCast(bit));
        if (mask & flag == 0) continue;
        var az = azimuth[bit];
        if (layout == .surround_5_1 and (bit == 4 or bit == 5)) az = if (bit == 4) 110 else -110;
        const elevation: i16 = if (bit == 11) 90 else if (bit >= 12) 45 else 0;
        const lfe = bit == 3;
        out[c] = .{ .mask_bit = flag, .azimuth_degrees = az, .elevation_degrees = elevation, .lfe = lfe, .loudness_weight = if (lfe) 0 else if (elevation == 0 and @abs(az) >= 60 and @abs(az) <= 120) 1.41 else 1 };
        c += 1;
    }
    return .{ .count = @intCast(count), .values = out };
}

pub fn validatePolicy(p: QualityPolicyV1) Error!void {
    if (p.version != 1 or p.loop_window_frames == 0 or p.loop_window_frames > 48_000 or p.required_measurements & ~@as(u32, 0x3f) != 0) return error.InvalidPolicy;
    const positive = [_]f64{ p.dc_absolute_maximum, p.loop_seam_excess_maximum, p.loop_slope_excess_maximum, p.loop_dc_difference_maximum };
    for (positive) |v| if (!std.math.isFinite(v) or v < 0 or v > 4) return error.InvalidPolicy;
    if (!std.math.isFinite(p.normalized_true_peak_maximum_dbtp) or p.normalized_true_peak_maximum_dbtp > 0 or p.normalized_true_peak_maximum_dbtp < -200) return error.InvalidPolicy;
    if (p.require_lufs_range and p.lufs_range == null) return error.MissingRequiredMeasurement;
    if (p.lufs_range) |r| {
        if (!std.math.isFinite(r.minimum) or !std.math.isFinite(r.maximum) or r.minimum > r.maximum or r.minimum < -200 or r.maximum > 100) return error.InvalidPolicy;
    } else if (p.lufs_severity != .report_only) return error.MissingRequiredMeasurement;
}

pub fn scan(allocator: std.mem.Allocator, input: Input, policy: QualityPolicyV1) Error!Report {
    @setFloatMode(.strict);
    try validatePolicy(policy);
    if (input.sample_rate_hz != sample_rate) return error.InvalidSampleRate;
    const speaker = try speakers(input.layout, input.channel_mask);
    const channels = speaker.count;
    if (input.samples.len == 0 or input.samples.len % channels != 0) return error.InvalidPcm;
    const frames = input.samples.len / channels;
    if (frames > maximum_frames) return error.ResourceLimitExceeded;
    if (input.stage == .decoded_encoded and input.encoded_hash == null) return error.MissingEncodedHash;
    if (input.loop) |loop| {
        if (loop.start >= loop.end or loop.end > frames) return error.InvalidLoop;
    } else if (policy.require_loop or policy.required_measurements & measurementBit(.loop) != 0) return error.MissingRequiredMeasurement;
    // Validate every sample before allocating filter scratch or computing measurements.
    for (input.samples) |x| {
        if (!std.math.isFinite(x)) return error.NonFiniteSample;
        if (@abs(x) > 1) return error.SampleOutOfRange;
    }
    const policy_json = try std.json.Stringify.valueAlloc(allocator, policy, .{});
    defer allocator.free(policy_json);
    var effective_hash: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(policy_json, &effective_hash, .{});
    var report: Report = .{ .source_hash = input.source_hash, .encoded_hash = input.encoded_hash, .audio_hash = hashPcm(input.samples), .policy_hash = frozen_policy_hash, .effective_policy_hash = effective_hash, .profile_hash = input.profile_hash, .stage = input.stage, .layout = input.layout, .channel_mask = input.channel_mask, .channels = channels, .frames = frames, .policy = policy, .loop = input.loop };
    for (0..channels) |c| report.channel[c].speaker = speaker.values[c];
    // At most 432000 energy bins (3.46 MiB) for the 12-hour bound; no PCM copy.
    const bins = try allocator.alloc(f64, frames / loudness_hop_frames);
    defer allocator.free(bins);
    @memset(bins, 0);
    var states: [8]State = @splat(.{});
    for (0..frames + 11) |frame| {
        for (0..channels) |c| {
            const x: f64 = if (frame < frames) input.samples[frame * channels + c] else 0;
            const state = &states[c];
            var t: usize = 11;
            while (t > 0) : (t -= 1) state.history[t] = state.history[t - 1];
            state.history[0] = x;
            for (0..4) |phase| {
                var y: f64 = 0;
                for (0..12) |tap| y += state.history[tap] * fir[tap][phase];
                report.channel[c].true_peak = @max(report.channel[c].true_peak, @abs(y));
            }
            if (frame < frames) {
                state.sum += x;
                state.energy += x * x;
                report.channel[c].sample_peak = @max(report.channel[c].sample_peak, @abs(x));
                const k = state.high.tick(state.shelf.tick(x, shelf_b, shelf_a), high_b, high_a);
                if (frame / loudness_hop_frames < bins.len) bins[frame / loudness_hop_frames] += k * k * speaker.values[c].loudness_weight;
            }
        }
    }
    var total_energy: f64 = 0;
    for (0..channels) |c| {
        const ch = &report.channel[c];
        ch.true_peak = @max(ch.true_peak, ch.sample_peak);
        ch.rms = @sqrt(states[c].energy / @as(f64, @floatFromInt(frames)));
        ch.dc = states[c].sum / @as(f64, @floatFromInt(frames));
        total_energy += states[c].energy;
        report.sample_peak = @max(report.sample_peak, ch.sample_peak);
        report.true_peak = @max(report.true_peak, ch.true_peak);
        if (@abs(ch.dc) > policy.dc_absolute_maximum) issue(&report, .dc_offset, policy.dc_severity);
    }
    report.rms = @sqrt(total_energy / @as(f64, @floatFromInt(input.samples.len)));
    report.peak_silence = report.sample_peak == 0;
    if (!report.peak_silence) {
        report.sample_peak_dbfs = 20 * @log10(report.sample_peak);
        report.true_peak_dbtp = 20 * @log10(report.true_peak);
        if (input.stage == .decoded_encoded and report.true_peak_dbtp > 0) issue(&report, .true_peak, .fail) else if (input.stage == .normalized and report.true_peak_dbtp > policy.normalized_true_peak_maximum_dbtp) issue(&report, .true_peak, policy.normalized_true_peak_severity);
    }
    measureLoudness(&report, bins);
    report.completed_measurements = required_base_measurements;
    if (policy.lufs_range) |range| {
        if (report.loudness_state != .measured) {
            const severity: Severity = if (policy.require_lufs_range or policy.lufs_severity == .fail) .fail else policy.lufs_severity;
            issue(&report, .loudness_unavailable, severity);
        } else if (report.integrated_lufs < range.minimum or report.integrated_lufs > range.maximum) issue(&report, .lufs_range, if (policy.require_lufs_range) .fail else policy.lufs_severity);
    }
    if (input.loop) |loop| {
        for (0..channels) |c| {
            report.channel[c].loop = measureLoop(input.samples, channels, c, loop, policy);
            const m = report.channel[c].loop;
            if (m.state == .insufficient_duration) {
                issue(&report, .loop_insufficient, if (policy.require_loop or policy.loop_severity == .fail or policy.required_measurements & measurementBit(.loop) != 0) .fail else .warn);
            } else {
                report.completed_measurements |= measurementBit(.loop);
                if (m.seam_excess > policy.loop_seam_excess_maximum) issue(&report, .loop_seam, policy.loop_severity);
                if (m.slope_excess > policy.loop_slope_excess_maximum) issue(&report, .loop_slope, policy.loop_severity);
                if (m.dc_anomaly) issue(&report, .loop_dc, policy.loop_severity);
            }
        }
    }
    if (report.completed_measurements & policy.required_measurements != policy.required_measurements) issue(&report, .missing_measurement, .fail);
    return report;
}

fn measureLoudness(report: *Report, bins: []const f64) void {
    @setFloatMode(.strict);
    if (bins.len < 4) return;
    report.loudness_state = .silence;
    report.loudness_blocks = bins.len - 3;
    var sum: f64 = 0;
    for (0..bins.len - 3) |i| {
        const power = (bins[i] + bins[i + 1] + bins[i + 2] + bins[i + 3]) / loudness_window_frames;
        if (aboveGate(power, absolute_gate_lufs)) {
            sum += power;
            report.absolute_gated_blocks += 1;
        }
    }
    if (report.absolute_gated_blocks == 0) return;
    report.measured_relative_gate_lufs = -0.691 + 10 * @log10(sum / @as(f64, @floatFromInt(report.absolute_gated_blocks))) + relative_gate_lu;
    sum = 0;
    for (0..bins.len - 3) |i| {
        const power = (bins[i] + bins[i + 1] + bins[i + 2] + bins[i + 3]) / loudness_window_frames;
        if (aboveGate(power, absolute_gate_lufs) and aboveGate(power, report.measured_relative_gate_lufs)) {
            sum += power;
            report.relative_gated_blocks += 1;
        }
    }
    if (report.relative_gated_blocks == 0) return;
    report.integrated_lufs = -0.691 + 10 * @log10(sum / @as(f64, @floatFromInt(report.relative_gated_blocks)));
    report.loudness_state = .measured;
}
fn aboveGate(power: f64, gate: f64) bool {
    return power > 0 and -0.691 + 10 * @log10(power) > gate;
}
fn issue(report: *Report, which: Issue, severity: Severity) void {
    switch (severity) {
        .report_only => {},
        .warn => {
            report.warnings |= issueBit(which);
            if (report.verdict == .pass) report.verdict = .warn;
        },
        .fail => {
            report.failures |= issueBit(which);
            report.verdict = .fail;
        },
    }
}
fn at(samples: []const f32, channels: usize, channel: usize, frame: usize) f64 {
    return samples[frame * channels + channel];
}
fn localVariation(samples: []const f32, channels: usize, channel: usize, start: usize, end: usize, m: *LoopMetrics) void {
    if (end - start < 2) return;
    var last = at(samples, channels, channel, start + 1) - at(samples, channels, channel, start);
    m.local_max_difference = @max(m.local_max_difference, @abs(last));
    for (start + 2..end) |i| {
        const delta = at(samples, channels, channel, i) - at(samples, channels, channel, i - 1);
        m.local_max_difference = @max(m.local_max_difference, @abs(delta));
        m.local_max_slope_change = @max(m.local_max_slope_change, @abs(delta - last));
        last = delta;
    }
}
fn measureLoop(samples: []const f32, channels: usize, channel: usize, loop: Loop, p: QualityPolicyV1) LoopMetrics {
    @setFloatMode(.strict);
    const start: usize = @intCast(loop.start);
    const end: usize = @intCast(loop.end);
    const length = end - start;
    const w = @min(p.loop_window_frames, length / 2);
    var m: LoopMetrics = .{ .state = if (w < loop_minimum_support_frames) .insufficient_duration else .measured, .window_frames = @intCast(w) };
    m.seam_delta = at(samples, channels, channel, start) - at(samples, channels, channel, end - 1);
    if (length >= 2) {
        m.difference_before = at(samples, channels, channel, end - 1) - at(samples, channels, channel, end - 2);
        m.difference_after = at(samples, channels, channel, start + 1) - at(samples, channels, channel, start);
        m.slope_change_before = m.seam_delta - m.difference_before;
        m.slope_change_after = m.difference_after - m.seam_delta;
    }
    if (w > 0) {
        for (0..w) |i| {
            m.dc_before += at(samples, channels, channel, end - w + i);
            m.dc_after += at(samples, channels, channel, start + i);
        }
        m.dc_before /= @as(f64, @floatFromInt(w));
        m.dc_after /= @as(f64, @floatFromInt(w));
        m.dc_difference = @abs(m.dc_after - m.dc_before);
    }
    // Keep support windows separate even when touching. Joining them would
    // admit an unrelated midpoint transition and let it mask the seam.
    localVariation(samples, channels, channel, start, start + w, &m);
    localVariation(samples, channels, channel, end - w, end, &m);
    m.seam_excess = @max(0, @abs(m.seam_delta) - m.local_max_difference);
    m.slope_excess = @max(0, @max(@abs(m.slope_change_before), @abs(m.slope_change_after)) - m.local_max_slope_change);
    m.dc_anomaly = m.state == .measured and m.dc_difference > p.loop_dc_difference_maximum and (m.seam_excess > p.loop_seam_excess_maximum or m.slope_excess > p.loop_slope_excess_maximum);
    return m;
}

pub fn hashPcm(samples: []const f32) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [4]u8 = undefined;
    for (samples) |x| {
        std.mem.writeInt(u32, &bytes, @bitCast(x), .little);
        h.update(&bytes);
    }
    return h.finalResult();
}

/// SHA-256 of the reviewed policy document; options have a separate effective hash.
pub const frozen_policy_hash: Hash = .{ 157, 135, 213, 231, 224, 180, 110, 73, 245, 94, 254, 235, 173, 220, 76, 210, 172, 33, 99, 50, 251, 16, 201, 140, 224, 83, 40, 148, 62, 120, 218, 222 };
