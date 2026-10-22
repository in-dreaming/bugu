const std = @import("std");
const c = @import("c.zig").api;
const t = @import("types.zig");
const container = @import("container.zig");
const profile = @import("profile.zig");
const native_errors = @import("native_errors.zig");
pub const preroll_frames: u32 = 11520;
pub const max_native_state_bytes: usize = 2 * 1024 * 1024;
/// Caller fills at most destination.len bytes. The reader must validate fetched
/// Ogg pages (CRC, serial, sequence, lacing) and reassemble a whole packet. The
/// encoded locator is sound-relative, including headers in the byte origin.
pub const PacketReader = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, u64, []u8) t.Error!ReadResult,
};
pub const ReadResult = struct { bytes: usize, next_byte_offset: u64 };
pub const Recovery = struct { packet_byte_offset: u64, raw_frame: u64, page_byte_offset: u64 = 0 };
const Inner = struct {
    allocator: std.mem.Allocator,
    native: *c.OpusMSDecoder,
    info: t.OpusStreamInfo,
    reader: PacketReader,
    first: Recovery,
    packet: []u8,
    pcm: []i32,
    next_byte_offset: u64,
    raw_cursor: u64 = 0,
    cursor: u64 = 0,
    output_gain: f64 = 1,
    validation_from_bos: bool = true,
    pending_start: usize = 0,
    pending_end: usize = 0,
};
/// Worker-only. Owns bounded scratch and codec state; never stores an encoded
/// file or complete decoded audio. It does not allocate during decode or seek.
pub const Decoder = struct {
    implementation: *anyopaque,
    fn inner(self: Decoder) *Inner {
        return @ptrCast(@alignCast(self.implementation));
    }
    pub fn prepare(allocator: std.mem.Allocator, info: t.OpusStreamInfo, reader: PacketReader, first_packet_byte_offset: u64) t.Error!Decoder {
        const audible_end = std.math.add(u64, info.pre_skip, info.audible_frames) catch return error.InvalidHeader;
        if (try t.channels(info.layout) != info.channels or try t.mask(info.layout) != info.channel_mask or
            info.sample_rate_hz != t.sample_rate or info.audible_frames == 0 or info.raw_frames < audible_end or
            info.raw_frames - audible_end != info.end_trim or info.stream_count == 0 or info.coupled_count > info.stream_count or
            @as(u16, info.stream_count) + info.coupled_count > 255 or info.mapping_family > 1 or
            (info.mapping_family == 0 and (info.channels > 2 or info.stream_count != 1 or info.coupled_count != info.channels - 1))) return error.InvalidHeader;
        if (first_packet_byte_offset == 0) return error.InvalidHeader;
        const native_size = c.opus_multistream_decoder_get_size(info.stream_count, info.coupled_count);
        if (native_size <= 0) return error.InvalidHeader;
        if (native_size > max_native_state_bytes) return error.ResourceLimitExceeded;
        var mapping: [8]u8 = @splat(0);
        const permutation = t.canonicalToOpus(info.channels);
        for (0..info.channels) |i| mapping[i] = info.channel_mapping[permutation[i]];
        var code: c_int = 0;
        const native = c.opus_multistream_decoder_create(t.sample_rate, info.channels, info.stream_count, info.coupled_count, &mapping, &code) orelse return native_errors.classify(.decoder, code);
        errdefer c.opus_multistream_decoder_destroy(native);
        if (code != c.OPUS_OK) return native_errors.classify(.decoder, code);
        // Upstream 1.6.1 fixed RES24 gain clamps to 32767 (opus_decoder.c).
        // Keep native gain at zero and apply RFC 7845 gain in Zig, unclipped.
        const output_gain = std.math.pow(f64, 10, @as(f64, @floatFromInt(info.output_gain_q8)) / 5120.0);
        if (c.opus_multistream_decoder_ctl(native, c.OPUS_SET_GAIN_REQUEST, @as(c_int, 0)) != c.OPUS_OK) return error.DecodeFailure;
        const packet = try allocator.alloc(u8, container.max_packet_bytes);
        errdefer allocator.free(packet);
        const pcm = try allocator.alloc(i32, t.max_packet_frames * @as(usize, info.channels));
        errdefer allocator.free(pcm);
        const state = try allocator.create(Inner);
        state.* = .{ .allocator = allocator, .native = native, .info = info, .reader = reader, .first = .{ .packet_byte_offset = first_packet_byte_offset, .raw_frame = 0 }, .packet = packet, .pcm = pcm, .next_byte_offset = first_packet_byte_offset, .output_gain = output_gain };
        return .{ .implementation = state };
    }
    /// Worker/control diagnostic: exact payload bytes requested by native Opus
    /// for this prepared stream. Excludes the native allocator's bookkeeping.
    pub fn nativeStateBytes(self: Decoder) usize {
        const info = self.inner().info;
        return @intCast(c.opus_multistream_decoder_get_size(info.stream_count, info.coupled_count));
    }
    /// Owned allocation payload, not process RSS: native state plus the Zig
    /// Inner/packet/PCM allocations. Excludes caller-owned PacketReader storage
    /// and allocator bookkeeping; do not add this to a Zig peak that already
    /// counts the same Inner/packet/PCM allocations.
    pub fn allocatedBytes(self: Decoder) usize {
        const state = self.inner();
        return self.nativeStateBytes() + @sizeOf(Inner) + state.packet.len + state.pcm.len * @sizeOf(i32);
    }
    pub fn deinit(self: *Decoder) void {
        const state = self.inner();
        c.opus_multistream_decoder_destroy(state.native);
        state.allocator.free(state.packet);
        state.allocator.free(state.pcm);
        const allocator = state.allocator;
        allocator.destroy(state);
        self.* = undefined;
    }
    pub fn position(self: Decoder) u64 {
        return self.inner().cursor;
    }
    pub fn reset(self: *Decoder) t.Error!void {
        try self.startAt(self.inner().first);
    }
    fn startAt(self: *Decoder, recovery: Recovery) t.Error!void {
        const state = self.inner();
        if (c.opus_multistream_decoder_ctl(state.native, c.OPUS_RESET_STATE) != c.OPUS_OK) return error.DecodeFailure;
        state.next_byte_offset = recovery.packet_byte_offset;
        state.raw_cursor = recovery.raw_frame;
        state.validation_from_bos = recovery.raw_frame == 0 and recovery.packet_byte_offset == state.first.packet_byte_offset;
        state.cursor = recovery.raw_frame -| state.info.pre_skip;
        state.pending_start = 0;
        state.pending_end = 0;
    }
    fn fill(self: *Decoder) t.Error!void {
        const state = self.inner();
        if (state.next_byte_offset == 0 or state.raw_cursor >= state.info.raw_frames) return error.DecodeFailure;
        const result = try state.reader.read(state.reader.context, state.next_byte_offset, state.packet);
        if (result.bytes == 0 or result.bytes > state.packet.len or (result.next_byte_offset != 0 and result.next_byte_offset <= state.next_byte_offset)) return error.DecodeFailure;
        const decoded = c.opus_multistream_decode24(state.native, state.packet.ptr, @intCast(result.bytes), state.pcm.ptr, t.max_packet_frames, 0);
        if (decoded <= 0 or decoded > t.max_packet_frames) return error.DecodeFailure;
        const frames: u32 = @intCast(decoded);
        if (frames > state.info.raw_frames - state.raw_cursor) return error.InvalidGranule;
        const raw_end = state.raw_cursor + frames;
        const audible_end = @as(u64, state.info.pre_skip) + state.info.audible_frames;
        state.pending_start = @intCast(@min(frames, @as(u64, state.info.pre_skip) -| state.raw_cursor));
        state.pending_end = @intCast(@min(frames, audible_end -| state.raw_cursor));
        state.raw_cursor = raw_end;
        state.next_byte_offset = result.next_byte_offset;
    }
    pub fn decode(self: *Decoder, output: []f32) t.Error!t.DecodeResult {
        const state = self.inner();
        const channels: usize = state.info.channels;
        if (output.len % channels != 0) return error.BufferTooSmall;
        var wrote: usize = 0;
        while (wrote < output.len / channels and state.cursor < state.info.audible_frames) {
            if (state.pending_start == state.pending_end) {
                try self.fill();
                continue;
            }
            const n = @min(output.len / channels - wrote, state.pending_end - state.pending_start);
            for (0..n * channels) |i| output[wrote * channels + i] = @floatCast(@as(f64, profile.fromInt24(state.pcm[state.pending_start * channels + i])) * state.output_gain);
            state.pending_start += n;
            wrote += n;
            state.cursor += n;
        }
        return .{ .frames = wrote, .eos = state.cursor == state.info.audible_frames };
    }
    /// Explicit worker/compiler acceptance step after continuous BOS decoding
    /// reaches audible EOS. Fully trimmed packets still require native payload
    /// validation. This consumes no PCM storage or allocations, and does not
    /// change audible cursor/EOS semantics. A non-BOS recovery cannot certify
    /// packets it skipped; reset and continuously decode from BOS first.
    pub fn validatePayloadToEnd(self: *Decoder) t.Error!void {
        const state = self.inner();
        if (!state.validation_from_bos or state.cursor != state.info.audible_frames) return error.InvalidState;
        errdefer state.validation_from_bos = false;
        while (state.raw_cursor < state.info.raw_frames) try self.fill();
        if (state.next_byte_offset != 0) return error.InvalidGranule;
    }
    /// Recovery is an independently validated packet boundary from the index.
    /// At least 240 ms are decoded before the requested frame, except near BOS.
    /// Sample coordinates are exact; codec state converges within the documented
    /// preroll PCM tolerance. No frame-zero replay is substituted for an index.
    pub fn seek(self: *Decoder, recovery: Recovery, target_frame: u64) t.Error!void {
        const state = self.inner();
        if (target_frame > state.info.audible_frames) return error.SeekOutOfRange;
        const target_raw = @as(u64, state.info.pre_skip) + target_frame;
        if (recovery.packet_byte_offset == 0 or recovery.raw_frame > target_raw or (recovery.raw_frame != 0 and target_raw - recovery.raw_frame < preroll_frames)) return error.SeekOutOfRange;
        if (target_frame < preroll_frames and recovery.raw_frame != 0) return error.SeekOutOfRange;
        if (recovery.raw_frame == 0 and recovery.packet_byte_offset != state.first.packet_byte_offset) return error.SeekOutOfRange;
        try self.startAt(recovery);
        while (state.cursor < target_frame) {
            if (state.pending_start == state.pending_end) {
                try self.fill();
                continue;
            }
            const n: usize = @intCast(@min(target_frame - state.cursor, state.pending_end - state.pending_start));
            state.pending_start += n;
            state.cursor += n;
        }
    }
};
/// Compiler/test source. Scan must remain at a stable address for reader lifetime.
/// Runtime supplies its own bounded fetch/reassembly reader instead.
pub fn scanReader(scan: *const container.Scan) PacketReader {
    return .{ .context = @constCast(scan), .read = struct {
        fn read(ctx: *anyopaque, offset: u64, destination: []u8) t.Error!ReadResult {
            const stream: *const container.Scan = @ptrCast(@alignCast(ctx));
            var lo: usize = 2;
            var hi = stream.packets.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (stream.packets[mid].byte_offset < offset) lo = mid + 1 else hi = mid;
            }
            if (lo == stream.packets.len or stream.packets[lo].byte_offset != offset) return error.SeekOutOfRange;
            const data = stream.payload(stream.packets[lo]);
            if (data.len > destination.len) return error.BufferTooSmall;
            @memcpy(destination[0..data.len], data);
            return .{ .bytes = data.len, .next_byte_offset = if (lo + 1 < stream.packets.len) stream.packets[lo + 1].byte_offset else 0 };
        }
    }.read };
}
pub fn recoveryFor(scan: container.Scan, target_frame: u64) t.Error!Recovery {
    if (target_frame > scan.info.audible_frames) return error.SeekOutOfRange;
    // Pre-roll is measured from the first audible sample, independently of
    // potentially very large pre-skip (RFC 7845 4.6).
    const before = if (target_frame < preroll_frames) 0 else (@as(u64, scan.info.pre_skip) + target_frame) - preroll_frames;
    var best = scan.packets[2];
    for (scan.packets[2..]) |packet| {
        if (packet.raw_frame > before) break;
        best = packet;
    }
    return .{ .packet_byte_offset = best.byte_offset, .raw_frame = best.raw_frame, .page_byte_offset = scan.pages[best.start_page].byte_offset };
}
