//! Deterministic, bounded offline media import. No renderer dependency or I/O.
//! The complete SRC contract is docs/validation/sme/TASK-010/import-policy.md.
const std = @import("std");
const opus = @import("sme-opus");
const channel_layout = @import("sme-channels");
const kernel = @import("src_kernel.zig");
pub const Layout = opus.Layout;
pub const Hash = [32]u8;
pub const target_rate: u32 = 48_000;
pub const algorithm_id: u32 = 0x53424331; // SBC1: sinc/Blackman compiler v1.
pub const algorithm_version: u32 = 1;
pub const Error = opus.Error || error{
    InvalidWav,
    UnsupportedWavFormat,
    UnsupportedWavMetadata,
    ConflictingMetadata,
    InvalidSampleRate,
    UnsupportedLayout,
    InvalidSample,
    SampleOutOfRange,
    ArithmeticOverflow,
    InvalidMarker,
    InvalidLoop,
    EmptyRemappedLoop,
    MisalignedAudio,
    SampleRateConversionFailed,
};
/// Limits apply before allocations. Callers may reduce, never expand this profile.
pub const Limits = struct {
    encoded_bytes: usize = 64 * 1024 * 1024,
    decoded_samples: usize = 16 * 1024 * 1024,
    normalized_samples: usize = 16 * 1024 * 1024,
    markers: usize = 65_536,
    wav_chunks: usize = 65_536,
};
pub const MarkerKind = enum { cue, anchor };
pub const Marker = struct { id: u64, kind: MarkerKind, frame: u64 };
pub const MappedMarker = struct { id: u64, kind: MarkerKind, source_frame: u64, target_frame: u64 };
/// Half-open interval, in original source frames (Opus uses audible 48 kHz).
pub const FrameLoop = struct { start: u64, end: u64, play_count: u32 = 0 };
pub const Options = struct { markers: []const Marker = &.{}, loop: ?FrameLoop = null, limits: Limits = .{} };
pub const PcmView = struct {
    samples: []const f32,
    rate_hz: u32,
    layout: Layout,
    /// Zero uses the named layout's canonical mask. Explicit layouts require a
    /// nonzero WAVE speaker mask; samples follow ascending set-bit speaker order.
    channel_mask: u32 = 0,
};
pub const SourceFormat = enum { pcm_f32le, wav_integer, wav_float, ogg_opus };
pub const ImportReport = struct {
    version: u32 = 1,
    source_format: SourceFormat,
    source_hash: Hash,
    normalized_hash: Hash,
    source_rate_hz: u32,
    target_rate_hz: u32 = target_rate,
    /// Informational only: this never controls SRC or authored frame mapping.
    opus_input_rate_hint: ?u32 = null,
    source_frames: u64,
    target_frames: u64,
    channels: u8,
    layout: Layout,
    channel_mask: u32,
    src_algorithm: u32 = algorithm_id,
    src_version: u32 = algorithm_version,
    coefficients_hash: Hash,
    bypass: bool,
    source_loop: ?FrameLoop,
    mapped_loop: ?FrameLoop,
};
pub const NormalizedAudio = struct {
    allocator: std.mem.Allocator,
    samples: []f32,
    layout: Layout,
    channels: u8,
    channel_mask: u32,
    frames: u64,
    markers: []MappedMarker,
    loop: ?FrameLoop,
    report: ImportReport,
    pub fn deinit(self: *NormalizedAudio) void {
        self.allocator.free(self.samples);
        self.allocator.free(self.markers);
        self.* = undefined;
    }
};

pub fn coefficientsHash() Hash {
    var result: Hash = undefined;
    _ = std.fmt.hexToBytes(&result, kernel.sha256) catch unreachable;
    return result;
}
/// Audit the frozen table itself rather than trusting its stored hash string.
pub fn verifyFrozenKernel() bool {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (kernel.bits) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        h.update(&bytes);
    }
    return std.mem.eql(u8, &h.finalResult(), &coefficientsHash());
}
/// Canonical byte hash is endian independent and retains f32 signed zero.
pub fn pcmHash(samples: []const f32) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (samples) |sample| {
        var bits: [4]u8 = undefined;
        std.mem.writeInt(u32, &bits, @bitCast(sample), .little);
        h.update(&bits);
    }
    return h.finalResult();
}
fn bytesHash(bytes: []const u8) Hash {
    var h: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    return h;
}
fn checkLimits(limits: Limits) Error!void {
    const cap: Limits = .{};
    inline for (std.meta.fields(Limits)) |f| {
        if (@field(limits, f.name) > @field(cap, f.name) or @field(limits, f.name) == 0) return error.ResourceLimitExceeded;
    }
}
fn checkRate(rate: u32) Error!void {
    if (rate < 8_000 or rate > 192_000) return error.InvalidSampleRate;
}
/// Named-layout helpers cannot infer an explicit mask. Use NormalizedAudio's
/// channels/channel_mask for imported media, including explicit layouts.
pub fn channelCount(layout: Layout) Error!u8 {
    const value = channel_layout.ChannelLayout.canonical(layout) catch return error.UnsupportedLayout;
    return @intCast(value.count);
}
pub fn channelMask(layout: Layout) Error!u32 {
    const value = channel_layout.ChannelLayout.canonical(layout) catch return error.UnsupportedLayout;
    return value.mask;
}
fn declaredLayout(count: u16, mask: u32) Error!channel_layout.ChannelLayout {
    const explicit = channel_layout.ChannelLayout.init(.explicit_mask, count, mask) catch return error.UnsupportedLayout;
    // Preserve the existing named identity for its exact mask, never by count.
    for (channel_layout.canonical_layouts) |named| if (mask == named.mask) return named;
    return explicit;
}
fn pcmLayout(source: PcmView) Error!channel_layout.ChannelLayout {
    if (source.layout == .explicit_mask) return declaredLayout(@popCount(source.channel_mask), source.channel_mask);
    const named = channel_layout.ChannelLayout.canonical(source.layout) catch return error.UnsupportedLayout;
    if (source.channel_mask != 0 and source.channel_mask != named.mask) return error.UnsupportedLayout;
    return named;
}
/// Source-origin rational rounding, exactly once; no float time or local deltas.
pub fn remapFrame(frame: u64, rate: u32) Error!u64 {
    try checkRate(rate);
    const n: u128 = @as(u128, frame) * target_rate;
    const q = n / rate;
    const r = n % rate;
    const rounded = q + @intFromBool(2 * r > rate or (2 * r == rate and q & 1 == 1));
    return std.math.cast(u64, rounded) orelse error.ArithmeticOverflow;
}
fn checkSample(sample: f64) Error!void {
    if (!std.math.isFinite(sample)) return error.InvalidSample;
    if (@abs(sample) > 1) return error.SampleOutOfRange;
}
fn sampleCount(frames: u64, channels: u8, limit: usize) Error!usize {
    const count = std.math.mul(u64, frames, channels) catch return error.ArithmeticOverflow;
    if (count > limit) return error.ResourceLimitExceeded;
    return std.math.cast(usize, count) orelse error.ArithmeticOverflow;
}
fn mapLoop(loop: ?FrameLoop, frames: u64, rate: u32) Error!?FrameLoop {
    const source = loop orelse return null;
    if (source.start >= source.end or source.end > frames) return error.InvalidLoop;
    const result: FrameLoop = .{ .start = try remapFrame(source.start, rate), .end = try remapFrame(source.end, rate), .play_count = source.play_count };
    if (result.start >= result.end) return error.EmptyRemappedLoop;
    return result;
}
fn mapMarkers(allocator: std.mem.Allocator, markers: []const Marker, frames: u64, rate: u32, limit: usize) Error![]MappedMarker {
    if (markers.len > limit) return error.ResourceLimitExceeded;
    const result = try allocator.alloc(MappedMarker, markers.len);
    errdefer allocator.free(result);
    var ids: std.AutoHashMap(u64, void) = .init(allocator);
    defer ids.deinit();
    var last_anchor: ?u64 = null;
    for (markers, result) |source, *destination| {
        if ((try ids.getOrPut(source.id)).found_existing) return error.ConflictingMetadata;
        if (source.frame > frames) return error.InvalidMarker;
        const frame = try remapFrame(source.frame, rate);
        if (source.kind == .anchor) {
            if (last_anchor) |last| if (frame <= last) return error.InvalidMarker;
            last_anchor = frame;
        }
        destination.* = .{ .id = source.id, .kind = source.kind, .source_frame = source.frame, .target_frame = frame };
    }
    return result;
}

/// All positions and phase indexes are rational; binary64 is used only for
/// coefficient interpolation and the explicitly ordered dot product.
fn weight(distance_numerator: u64, denominator: u32) f64 {
    @setFloatMode(.strict);
    // The support check bounds p below 128*192000*1024, exactly in u64.
    if (distance_numerator >= @as(u64, kernel.radius) * denominator) return 0;
    const p = distance_numerator * kernel.resolution;
    const index = p / denominator;
    if (index >= kernel.bits.len - 1) return 0;
    const i: usize = @intCast(index);
    const left: f64 = @bitCast(kernel.bits[i]);
    const right: f64 = @bitCast(kernel.bits[i + 1]);
    const fraction = @as(f64, @floatFromInt(p % denominator)) / @as(f64, @floatFromInt(denominator));
    return left + (right - left) * fraction;
}
fn resample(source: PcmView, channels: u8, destination: []f32) Error!void {
    @setFloatMode(.strict);
    const source_frames = source.samples.len / channels;
    const denominator: u32 = @max(source.rate_hz, target_rate);
    const support_numerator: i64 = @as(i64, kernel.radius) * denominator;
    for (0..destination.len / channels) |m| {
        // t=m*source_rate/48000; d=(48000*n-m*rate)/max(rate,48000).
        const center: i64 = @as(i64, @intCast(m)) * source.rate_hz;
        const first = @divFloor(center - support_numerator + target_rate - 1, target_rate);
        const last = @divFloor(center + support_numerator, target_rate);
        var sums: [8]f64 = @splat(0);
        var coefficient_sum: f64 = 0;
        var n = first;
        while (n <= last) : (n += 1) {
            const coefficient = weight(@abs(n * target_rate - center), denominator);
            coefficient_sum += coefficient;
            const source_frame: usize = @intCast(@max(0, @min(n, @as(i64, @intCast(source_frames - 1)))));
            for (0..channels) |c| sums[c] += @as(f64, source.samples[source_frame * channels + c]) * coefficient;
        }
        if (!std.math.isFinite(coefficient_sum) or coefficient_sum < 0.5) return error.SampleRateConversionFailed;
        for (0..channels) |c| {
            const value = sums[c] / coefficient_sum;
            try checkSample(value);
            destination[m * channels + c] = @floatCast(value);
        }
    }
}

pub fn normalizePcm(allocator: std.mem.Allocator, source: PcmView, options: Options) Error!NormalizedAudio {
    try checkLimits(options.limits);
    try checkRate(source.rate_hz);
    const layout = try pcmLayout(source);
    const channels: u8 = @intCast(layout.count);
    if (source.samples.len == 0 or source.samples.len % channels != 0) return error.InvalidPcm;
    if (source.samples.len > options.limits.decoded_samples) return error.ResourceLimitExceeded;
    for (source.samples) |sample| try checkSample(sample);
    const source_frames: u64 = @intCast(source.samples.len / channels);
    const frames = try remapFrame(source_frames, source.rate_hz);
    if (frames == 0) return error.SampleRateConversionFailed;
    const count = try sampleCount(frames, channels, options.limits.normalized_samples);
    const loop = try mapLoop(options.loop, source_frames, source.rate_hz);
    const markers = try mapMarkers(allocator, options.markers, source_frames, source.rate_hz, options.limits.markers);
    errdefer allocator.free(markers);
    const samples = try allocator.alloc(f32, count);
    errdefer allocator.free(samples);
    if (source.rate_hz == target_rate) @memcpy(samples, source.samples) else try resample(source, channels, samples);
    return .{
        .allocator = allocator,
        .samples = samples,
        .layout = layout.kind,
        .channels = channels,
        .channel_mask = layout.mask,
        .frames = frames,
        .markers = markers,
        .loop = loop,
        .report = .{ .source_format = .pcm_f32le, .source_hash = pcmHash(source.samples), .normalized_hash = pcmHash(samples), .source_rate_hz = source.rate_hz, .source_frames = source_frames, .target_frames = frames, .channels = channels, .layout = layout.kind, .channel_mask = layout.mask, .coefficients_hash = coefficientsHash(), .bypass = source.rate_hz == target_rate, .source_loop = options.loop, .mapped_loop = loop },
    };
}

const Wav = struct { data: []const u8, rate: u32, channels: u8, layout: Layout, channel_mask: u32, bits: u16, valid_bits: u16, floating: bool, cues: ?[]const u8, sampler: ?[]const u8 };
fn read(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@sizeOf(T)], .little);
}
fn inspectWav(bytes: []const u8, limits: Limits) Error!Wav {
    try checkLimits(limits);
    if (bytes.len > limits.encoded_bytes) return error.ResourceLimitExceeded;
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWav;
    if (@as(u64, read(u32, bytes, 4)) + 8 != bytes.len) return error.InvalidWav;
    var format: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var cues: ?[]const u8 = null;
    var sampler: ?[]const u8 = null;
    var fact: ?[]const u8 = null;
    var pos: usize = 12;
    var chunks: usize = 0;
    while (pos < bytes.len) {
        chunks += 1;
        if (chunks > limits.wav_chunks) return error.ResourceLimitExceeded;
        if (bytes.len - pos < 8) return error.InvalidWav;
        const size: usize = read(u32, bytes, pos + 4);
        const tag = bytes[pos..][0..4];
        pos += 8;
        if (size > bytes.len - pos) return error.InvalidWav;
        const chunk = bytes[pos..][0..size];
        if (std.mem.eql(u8, tag, "fmt ")) {
            if (format != null) return error.InvalidWav;
            format = chunk;
        } else if (std.mem.eql(u8, tag, "data")) {
            if (data != null or format == null) return error.InvalidWav;
            data = chunk;
        } else if (std.mem.eql(u8, tag, "fact")) {
            if (fact != null or chunk.len < 4) return error.InvalidWav;
            fact = chunk;
        } else if (std.mem.eql(u8, tag, "cue ")) {
            if (cues != null) return error.InvalidWav;
            cues = chunk;
        } else if (std.mem.eql(u8, tag, "smpl")) {
            if (sampler != null) return error.InvalidWav;
            sampler = chunk;
        } else if (std.mem.eql(u8, tag, "plst")) return error.UnsupportedWavMetadata;
        pos += size;
        if (size & 1 != 0) {
            if (pos == bytes.len) return error.InvalidWav;
            pos += 1;
        }
    }
    const fmt = format orelse return error.InvalidWav;
    const pcm = data orelse return error.InvalidWav;
    if (fmt.len < 16 or pcm.len == 0) return error.InvalidWav;
    var tag = read(u16, fmt, 0);
    const channels = std.math.cast(u8, read(u16, fmt, 2)) orelse return error.UnsupportedLayout;
    if (channels == 0 or channels > channel_layout.max_channels) return error.UnsupportedLayout;
    var layout: channel_layout.ChannelLayout = undefined;
    const rate = read(u32, fmt, 4);
    try checkRate(rate);
    const bits = read(u16, fmt, 14);
    var valid_bits = bits;
    if (tag == 0xfffe) {
        if (fmt.len != 40 or read(u16, fmt, 16) != 22) return error.InvalidWav;
        valid_bits = read(u16, fmt, 18);
        layout = try declaredLayout(channels, read(u32, fmt, 20));
        const guid_suffix = [_]u8{ 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 };
        if (!std.mem.eql(u8, fmt[26..40], &guid_suffix)) return error.UnsupportedWavFormat;
        tag = read(u16, fmt, 24);
    } else {
        if (channels > 2) return error.UnsupportedLayout;
        layout = channel_layout.ChannelLayout.fromCount(channels) catch return error.UnsupportedLayout;
        if (fmt.len != 16 and !(fmt.len == 18 and read(u16, fmt, 16) == 0)) return error.InvalidWav;
    }
    const floating = tag == 3;
    if (tag != 1 and !floating) return error.UnsupportedWavFormat;
    if (floating) {
        if ((bits != 32 and bits != 64) or valid_bits != bits) return error.UnsupportedWavFormat;
    } else if ((bits != 8 and bits != 16 and bits != 24 and bits != 32) or valid_bits == 0 or valid_bits > bits) return error.UnsupportedWavFormat;
    const block_align = @as(u32, channels) * (bits / 8);
    if (read(u16, fmt, 12) != block_align or read(u32, fmt, 8) != @as(u64, rate) * block_align or pcm.len % block_align != 0) return error.InvalidWav;
    if (fact) |description| if (read(u32, description, 0) != pcm.len / block_align) return error.InvalidWav;
    if (pcm.len / (bits / 8) > limits.decoded_samples) return error.ResourceLimitExceeded;
    return .{ .data = pcm, .rate = rate, .channels = channels, .layout = layout.kind, .channel_mask = layout.mask, .bits = bits, .valid_bits = valid_bits, .floating = floating, .cues = cues, .sampler = sampler };
}

const WavMetadata = struct {
    markers: []Marker,
    loop: ?FrameLoop,
    fn deinit(self: *WavMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.markers);
    }
};
fn wavMetadata(allocator: std.mem.Allocator, wav: Wav, options: Options) Error!WavMetadata {
    var list: std.ArrayList(Marker) = .empty;
    defer list.deinit(allocator);
    var ids: std.AutoHashMap(u64, Marker) = .init(allocator);
    defer ids.deinit();
    if (options.markers.len > options.limits.markers) return error.ResourceLimitExceeded;
    for (options.markers) |marker| {
        const entry = try ids.getOrPut(marker.id);
        if (entry.found_existing) return error.ConflictingMetadata;
        entry.value_ptr.* = marker;
        try list.append(allocator, marker);
    }
    if (wav.cues) |cues| {
        if (cues.len < 4) return error.InvalidWav;
        const count: usize = read(u32, cues, 0);
        if (count > options.limits.markers) return error.ResourceLimitExceeded;
        if (@as(u64, count) * 24 + 4 != cues.len) return error.InvalidWav;
        var container_ids: std.AutoHashMap(u32, void) = .init(allocator);
        defer container_ids.deinit();
        for (0..count) |i| {
            const cue = cues[4 + i * 24 ..][0..24];
            const id = read(u32, cue, 0);
            if ((try container_ids.getOrPut(id)).found_existing) return error.ConflictingMetadata;
            const frame = read(u32, cue, 20);
            if (!std.mem.eql(u8, cue[8..12], "data") or read(u32, cue, 12) != 0 or read(u32, cue, 16) != 0 or
                (read(u32, cue, 4) != 0 and read(u32, cue, 4) != frame)) return error.UnsupportedWavMetadata;
            const marker: Marker = .{ .id = id, .kind = .cue, .frame = frame };
            const entry = try ids.getOrPut(id);
            if (entry.found_existing) {
                if (!std.meta.eql(entry.value_ptr.*, marker)) return error.ConflictingMetadata;
            } else {
                if (list.items.len == options.limits.markers) return error.ResourceLimitExceeded;
                entry.value_ptr.* = marker;
                try list.append(allocator, marker);
            }
        }
    }
    var loop = options.loop;
    if (wav.sampler) |sampler| {
        if (sampler.len < 36) return error.InvalidWav;
        const count = read(u32, sampler, 28);
        if (count > 1 or read(u32, sampler, 32) != 0) return error.UnsupportedWavMetadata;
        if (@as(u64, count) * 24 + 36 != sampler.len) return error.InvalidWav;
        if (count == 1) {
            const l = sampler[36..60];
            if (read(u32, l, 4) != 0 or read(u32, l, 16) != 0) return error.UnsupportedWavMetadata;
            // WAV end is inclusive; widening precedes addition and rational remap.
            const found: FrameLoop = .{ .start = read(u32, l, 8), .end = @as(u64, read(u32, l, 12)) + 1, .play_count = read(u32, l, 20) };
            if (loop) |authored| {
                if (!std.meta.eql(authored, found)) return error.ConflictingMetadata;
            } else loop = found;
        }
    }
    return .{ .markers = try list.toOwnedSlice(allocator), .loop = loop };
}

pub fn importWav(allocator: std.mem.Allocator, bytes: []const u8, options: Options) Error!NormalizedAudio {
    @setFloatMode(.strict);
    const wav = try inspectWav(bytes, options.limits);
    const width = wav.bits / 8;
    const samples = try allocator.alloc(f32, wav.data.len / width);
    defer allocator.free(samples);
    for (samples, 0..) |*sample, i| {
        const p = wav.data[i * width ..][0..width];
        var value: f64 = undefined;
        if (wav.floating) {
            value = if (wav.bits == 32) @as(f32, @bitCast(read(u32, p, 0))) else @as(f64, @bitCast(read(u64, p, 0)));
        } else {
            const raw: u32 = switch (wav.bits) {
                8 => p[0],
                16 => read(u16, p, 0),
                24 => @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16),
                32 => read(u32, p, 0),
                else => unreachable,
            };
            const padding: u5 = @intCast(wav.bits - wav.valid_bits);
            if (raw & ((@as(u32, 1) << padding) - 1) != 0) return error.InvalidWav;
            const integer: i64 = if (wav.bits == 8) @as(i64, raw) - 128 else if (raw & (@as(u32, 1) << @as(u5, @intCast(wav.bits - 1))) != 0) @as(i64, raw) - (@as(i64, 1) << @as(u6, @intCast(wav.bits))) else raw;
            value = @as(f64, @floatFromInt(integer)) / @as(f64, @floatFromInt(@as(u64, 1) << @as(u6, @intCast(wav.bits - 1))));
        }
        try checkSample(value);
        sample.* = @floatCast(value);
    }
    var metadata = try wavMetadata(allocator, wav, options);
    defer metadata.deinit(allocator);
    var merged = options;
    merged.markers = metadata.markers;
    merged.loop = metadata.loop;
    var result = try normalizePcm(allocator, .{ .samples = samples, .rate_hz = wav.rate, .layout = wav.layout, .channel_mask = wav.channel_mask }, merged);
    result.report.source_hash = bytesHash(bytes);
    result.report.source_format = if (wav.floating) .wav_float else .wav_integer;
    return result;
}

pub fn importOpus(allocator: std.mem.Allocator, bytes: []const u8, options: Options) Error!NormalizedAudio {
    try checkLimits(options.limits);
    if (bytes.len > options.limits.encoded_bytes) return error.ResourceLimitExceeded;
    var scan = try opus.inspect(allocator, bytes);
    defer scan.deinit();
    if (scan.info.sample_rate_hz != target_rate or scan.packets.len < 3) return error.InvalidHeader;
    const count = try sampleCount(scan.info.audible_frames, scan.info.channels, options.limits.decoded_samples);
    if (count > options.limits.normalized_samples) return error.ResourceLimitExceeded;
    const samples = try allocator.alloc(f32, count);
    defer allocator.free(samples);
    var decoder = try opus.Decoder.prepare(allocator, scan.info, opus.scanReader(&scan), scan.packets[2].byte_offset);
    defer decoder.deinit();
    var frame: usize = 0;
    while (frame < scan.info.audible_frames) {
        const n: usize = @intCast(@min(1024, scan.info.audible_frames - frame));
        const result = try decoder.decode(samples[frame * scan.info.channels ..][0 .. n * scan.info.channels]);
        if (result.frames != n or result.eos != (frame + n == scan.info.audible_frames)) return error.DecodeFailure;
        frame += n;
    }
    // Audible EOS can precede fully trimmed packets. Validate their real payloads
    // using this uninterrupted BOS decoder before accepting source PCM.
    try decoder.validatePayloadToEnd();
    var result = try normalizePcm(allocator, .{ .samples = samples, .rate_hz = target_rate, .layout = scan.info.layout }, options);
    result.report.source_hash = bytesHash(bytes);
    result.report.source_format = .ogg_opus;
    result.report.opus_input_rate_hint = scan.info.input_rate_hint;
    return result;
}

/// Re-check group alignment after SRC and delay compensation. The importer
/// never adjusts one stem to hide a mismatch, or accumulates segment rounding.
pub fn validateAlignment(stems: []const *const NormalizedAudio) Error!void {
    if (stems.len == 0) return error.MisalignedAudio;
    const first = stems[0];
    for (stems[1..]) |stem| {
        if (stem.frames != first.frames or stem.layout != first.layout or stem.channels != first.channels or stem.channel_mask != first.channel_mask or stem.markers.len != first.markers.len) return error.MisalignedAudio;
        if (!std.meta.eql(stem.loop, first.loop)) return error.MisalignedAudio;
        for (stem.markers, first.markers) |a, b| {
            if (a.id != b.id or a.kind != b.kind or a.target_frame != b.target_frame) return error.MisalignedAudio;
        }
    }
}
