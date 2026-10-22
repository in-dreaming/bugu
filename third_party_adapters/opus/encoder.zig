const std = @import("std");
const c = @import("c.zig").api;
const t = @import("types.zig");
const p = @import("profile.zig");
const container = @import("container.zig");
const native_errors = @import("native_errors.zig");
const Inner = struct {
    allocator: std.mem.Allocator,
    native: *c.OpusMSEncoder,
    ogg: c.ogg_stream_state,
    channels: u8,
    info: t.OpusStreamInfo,
    pcm: []i32,
    packet: []u8,
    output: std.ArrayList(u8) = .empty,
    buffered: usize = 0,
    input_frames: u64 = 0,
    raw_frames: u64 = 0,
    packet_number: i64 = 0,
    finalized: bool = false,
    failed: bool = false,
};
pub const Encoded = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    info: t.OpusStreamInfo,
    pub fn deinit(self: *Encoded) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};
pub const Encoder = struct {
    implementation: *anyopaque,
    fn inner(self: Encoder) *Inner {
        return @ptrCast(@alignCast(self.implementation));
    }
    pub fn prepare(allocator: std.mem.Allocator, layout: t.Layout) t.Error!Encoder {
        const channels = try t.channels(layout);
        const family: u8 = if (channels > 2) 1 else 0;
        var streams: c_int = 0;
        var coupled: c_int = 0;
        var code: c_int = 0;
        var mapping: [8]u8 = @splat(0);
        const native = c.opus_multistream_surround_encoder_create(t.sample_rate, channels, family, &streams, &coupled, &mapping, c.OPUS_APPLICATION_AUDIO, &code) orelse return native_errors.classify(.encoder, code);
        errdefer c.opus_multistream_encoder_destroy(native);
        if (code != c.OPUS_OK) return native_errors.classify(.encoder, code);
        const settings = [_][2]c_int{
            .{ c.OPUS_SET_BITRATE_REQUEST, 64000 * @as(c_int, channels) },
            .{ c.OPUS_SET_VBR_REQUEST, 0 },
            .{ c.OPUS_SET_VBR_CONSTRAINT_REQUEST, 1 },
            .{ c.OPUS_SET_COMPLEXITY_REQUEST, 10 },
            .{ c.OPUS_SET_SIGNAL_REQUEST, c.OPUS_SIGNAL_MUSIC },
            .{ c.OPUS_SET_LSB_DEPTH_REQUEST, 24 },
            .{ c.OPUS_SET_INBAND_FEC_REQUEST, 0 },
            .{ c.OPUS_SET_PACKET_LOSS_PERC_REQUEST, 0 },
            .{ c.OPUS_SET_DTX_REQUEST, 0 },
            .{ c.OPUS_SET_PHASE_INVERSION_DISABLED_REQUEST, 1 },
        };
        for (settings) |setting| if (c.opus_multistream_encoder_ctl(native, setting[0], setting[1]) != c.OPUS_OK) return error.EncodeFailure;
        var lookahead: c_int = 0;
        if (c.opus_multistream_encoder_ctl(native, c.OPUS_GET_LOOKAHEAD_REQUEST, &lookahead) != c.OPUS_OK or lookahead <= 0 or lookahead > 65535) return error.EncodeFailure;
        const pcm = try allocator.alloc(i32, p.frame_frames * @as(usize, channels));
        errdefer allocator.free(pcm);
        const packet = try allocator.alloc(u8, container.max_packet_bytes);
        errdefer allocator.free(packet);
        const state = try allocator.create(Inner);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .native = native, .ogg = std.mem.zeroes(c.ogg_stream_state), .channels = channels, .pcm = pcm, .packet = packet, .info = .{ .input_rate_hint = t.sample_rate, .channels = channels, .layout = layout, .channel_mask = try t.mask(layout), .pre_skip = @intCast(lookahead), .output_gain_q8 = 0, .mapping_family = family, .stream_count = @intCast(streams), .coupled_count = @intCast(coupled), .channel_mapping = mapping, .stream_serial = p.serial } };
        if (c.ogg_stream_init(&state.ogg, @bitCast(p.serial)) != 0) return error.OutOfMemory;
        errdefer _ = c.ogg_stream_clear(&state.ogg);
        errdefer state.output.deinit(allocator);
        var encoder: Encoder = .{ .implementation = state };
        var head: [29]u8 = @splat(0);
        @memcpy(head[0..8], "OpusHead");
        head[8] = 1;
        head[9] = channels;
        std.mem.writeInt(u16, head[10..12], @intCast(lookahead), .little);
        std.mem.writeInt(u32, head[12..16], t.sample_rate, .little);
        head[18] = family;
        if (family == 1) {
            head[19] = @intCast(streams);
            head[20] = @intCast(coupled);
            @memcpy(head[21..][0..channels], mapping[0..channels]);
        }
        try encoder.mux(head[0..if (family == 0) 19 else 21 + @as(usize, channels)], 0, true, false);
        const vendor = "Bugu " ++ p.id;
        var tags: [16 + vendor.len]u8 = @splat(0);
        @memcpy(tags[0..8], "OpusTags");
        std.mem.writeInt(u32, tags[8..12], vendor.len, .little);
        @memcpy(tags[12..][0..vendor.len], vendor);
        try encoder.mux(&tags, 0, false, false);
        return encoder;
    }
    pub fn deinit(self: *Encoder) void {
        const state = self.inner();
        c.opus_multistream_encoder_destroy(state.native);
        _ = c.ogg_stream_clear(&state.ogg);
        state.output.deinit(state.allocator);
        state.allocator.free(state.pcm);
        state.allocator.free(state.packet);
        const allocator = state.allocator;
        allocator.destroy(state);
        self.* = undefined;
    }
    fn mux(self: *Encoder, data: []const u8, granule: u64, bos: bool, eos: bool) t.Error!void {
        const state = self.inner();
        if (granule > std.math.maxInt(i64)) return error.ResourceLimitExceeded;
        var packet: c.ogg_packet = .{ .packet = @constCast(data.ptr), .bytes = @intCast(data.len), .b_o_s = @intFromBool(bos), .e_o_s = @intFromBool(eos), .granulepos = @intCast(granule), .packetno = state.packet_number };
        if (c.ogg_stream_packetin(&state.ogg, &packet) != 0) return error.EncodeFailure;
        state.packet_number += 1;
        var page: c.ogg_page = undefined;
        while (c.ogg_stream_flush(&state.ogg, &page) != 0) {
            if (page.header_len < 0 or page.body_len < 0) return error.EncodeFailure;
            const header: usize = @intCast(page.header_len);
            const body: usize = @intCast(page.body_len);
            if (header + body > container.max_stream_bytes - state.output.items.len) return error.ResourceLimitExceeded;
            try state.output.appendSlice(state.allocator, page.header[0..header]);
            try state.output.appendSlice(state.allocator, page.body[0..body]);
        }
    }
    fn encodeFrame(self: *Encoder, final: bool) t.Error!void {
        const state = self.inner();
        const n = c.opus_multistream_encode24(state.native, state.pcm.ptr, p.frame_frames, state.packet.ptr, @intCast(state.packet.len));
        if (n <= 0) return error.EncodeFailure;
        state.raw_frames += p.frame_frames;
        const granule = if (final) state.input_frames + state.info.pre_skip else state.raw_frames;
        try self.mux(state.packet[0..@intCast(n)], granule, false, final);
        state.buffered = 0;
    }
    /// Interleaved canonical WAVE speaker order, finite normalized float32.
    /// Arbitrary frame chunks are accepted; chunk boundaries cannot affect bytes.
    pub fn encode(self: *Encoder, pcm: []const f32) t.Error!void {
        const state = self.inner();
        if (state.finalized or state.failed) return error.InvalidState;
        if (pcm.len % state.channels != 0) return error.InvalidPcm;
        for (pcm) |sample| _ = try p.toInt24(sample);
        const frames = pcm.len / state.channels;
        if (frames > std.math.maxInt(i64) - state.input_frames - state.info.pre_skip - p.frame_frames) return error.ResourceLimitExceeded;
        errdefer state.failed = true;
        const permutation = t.canonicalToOpus(state.channels);
        for (0..frames) |frame| {
            for (0..state.channels) |channel| state.pcm[state.buffered * state.channels + permutation[channel]] = try p.toInt24(pcm[frame * state.channels + channel]);
            state.buffered += 1;
            state.input_frames += 1;
            if (state.buffered == p.frame_frames) try self.encodeFrame(false);
        }
    }
    pub fn finalize(self: *Encoder) t.Error!Encoded {
        const state = self.inner();
        if (state.finalized or state.failed) return error.InvalidState;
        if (state.input_frames == 0) return error.InvalidPcm;
        errdefer state.failed = true;
        const target = state.input_frames + state.info.pre_skip;
        while (state.raw_frames < target) {
            @memset(state.pcm[state.buffered * state.channels ..], 0);
            try self.encodeFrame(state.raw_frames + p.frame_frames >= target);
        }
        state.info.raw_frames = state.raw_frames;
        state.info.audible_frames = state.input_frames;
        state.info.end_trim = @intCast(state.raw_frames - target);
        state.info.final_granule = target;
        const bytes = try state.output.toOwnedSlice(state.allocator);
        state.finalized = true;
        return .{ .allocator = state.allocator, .bytes = bytes, .info = state.info };
    }
};
