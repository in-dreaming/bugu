//! Strict, non-realtime whole-stream inspector. Owned packet payloads are for
//! compiler use only. Runtime Decoder consumes a bounded PacketReader instead.
const std = @import("std");
const c = @import("c.zig").api;
const t = @import("types.zig");
pub const max_packet_bytes: usize = 8 * 1275 * 48;
pub const max_header_bytes: usize = 1024 * 1024;
pub const max_inventory_entries: usize = 262144;
pub const max_stream_bytes: usize = 192 * 1024 * 1024;
pub const Page = struct {
    byte_offset: u64,
    byte_length: u32,
    body_offset: u64,
    granule: u64,
    sequence: u32,
    flags: u8,
    first_packet: u32,
    completed_packets: u32,
};
pub const Packet = struct {
    byte_offset: u64,
    end_byte_offset: u64,
    start_page: u32,
    end_page: u32,
    payload_offset: usize,
    payload_length: usize,
    raw_frame: u64 = 0,
    frames: u32 = 0,
};
pub const Scan = struct {
    allocator: std.mem.Allocator,
    info: t.OpusStreamInfo,
    pages: []Page,
    /// Includes OpusHead and OpusTags at indices 0 and 1.
    packets: []Packet,
    payloads: []u8,
    pub fn deinit(self: *Scan) void {
        self.allocator.free(self.pages);
        self.allocator.free(self.packets);
        self.allocator.free(self.payloads);
        self.* = undefined;
    }
    pub fn payload(self: Scan, packet: Packet) []const u8 {
        return self.payloads[packet.payload_offset..][0..packet.payload_length];
    }
};
fn read(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
pub fn pageCrc(bytes: []const u8) u32 {
    var crc: u32 = 0;
    for (bytes, 0..) |byte, i| {
        crc ^= @as(u32, if (i >= 22 and i < 26) 0 else byte) << 24;
        for (0..8) |_| crc = (crc << 1) ^ (if (crc & 0x80000000 != 0) @as(u32, 0x04c11db7) else 0);
    }
    return crc;
}
pub fn parseHeader(bytes: []const u8) t.Error!t.OpusStreamInfo {
    if (bytes.len < 19 or !std.mem.eql(u8, bytes[0..8], "OpusHead") or bytes[8] == 0 or bytes[8] > 15) return error.InvalidHeader;
    const count = bytes[9];
    const layout = try t.layoutFor(count);
    const family = bytes[18];
    var streams: u8 = 1;
    var coupled: u8 = if (count == 2) 1 else 0;
    var mapping: [8]u8 = @splat(0);
    if (family == 0) {
        if (count > 2) return error.UnsupportedChannelMapping;
        if (bytes[8] == 1 and bytes.len != 19) return error.InvalidHeader;
        if (count == 2) mapping[1] = 1;
    } else if (family == 1) {
        if (bytes.len < 21 + @as(usize, count) or (bytes[8] == 1 and bytes.len != 21 + @as(usize, count))) return error.InvalidHeader;
        streams = bytes[19];
        coupled = bytes[20];
        if (streams == 0 or coupled > streams or @as(u16, streams) + coupled > 255) return error.UnsupportedChannelMapping;
        @memcpy(mapping[0..count], bytes[21..][0..count]);
        for (mapping[0..count]) |m| if (m != 255 and @as(u16, m) >= @as(u16, streams) + coupled) return error.UnsupportedChannelMapping;
    } else return error.UnsupportedChannelMapping;
    return .{ .input_rate_hint = read(u32, bytes, 12), .channels = count, .layout = layout, .channel_mask = try t.mask(layout), .pre_skip = read(u16, bytes, 10), .output_gain_q8 = read(i16, bytes, 16), .mapping_family = family, .stream_count = streams, .coupled_count = coupled, .channel_mapping = mapping };
}
fn checkTags(bytes: []const u8) t.Error!void {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..8], "OpusTags")) return error.InvalidHeader;
    const vendor_len: usize = read(u32, bytes, 8);
    if (vendor_len > bytes.len - 16) return error.InvalidHeader;
    var p: usize = 12 + vendor_len;
    const count = read(u32, bytes, p);
    p += 4;
    if (count > (bytes.len - p) / 4) return error.InvalidHeader;
    for (0..count) |_| {
        if (bytes.len - p < 4) return error.InvalidHeader;
        const n: usize = read(u32, bytes, p);
        p += 4;
        if (n > bytes.len - p) return error.InvalidHeader;
        p += n;
    }
}
pub fn inspect(allocator: std.mem.Allocator, bytes: []const u8) t.Error!Scan {
    if (bytes.len > max_stream_bytes) return error.ResourceLimitExceeded;
    var pages: std.ArrayList(Page) = .empty;
    defer pages.deinit(allocator);
    var packets: std.ArrayList(Packet) = .empty;
    defer packets.deinit(allocator);
    var payloads: std.ArrayList(u8) = .empty;
    defer payloads.deinit(allocator);
    var pos: usize = 0;
    var serial: ?u32 = null;
    var sequence: u32 = 0;
    var partial: ?Packet = null;
    var saw_eos = false;
    while (pos < bytes.len) {
        if (saw_eos) return error.ChainedStreamUnsupported;
        if (pages.items.len == max_inventory_entries) return error.ResourceLimitExceeded;
        if (bytes.len - pos < 27) return error.TruncatedContainer;
        const h = bytes[pos..];
        if (!std.mem.eql(u8, h[0..4], "OggS") or h[4] != 0 or h[5] & ~@as(u8, 7) != 0) return error.InvalidContainer;
        const flags = h[5];
        const n: usize = h[26];
        if (h.len < 27 + n) return error.TruncatedContainer;
        const body_offset = pos + 27 + n;
        var body_len: usize = 0;
        for (h[27..][0..n]) |l| body_len += l;
        const end = body_offset + body_len;
        if (end > bytes.len) return error.TruncatedContainer;
        if (pageCrc(bytes[pos..end]) != read(u32, h, 22)) return error.ContainerCrcMismatch;
        const this_serial = read(u32, h, 14);
        if (serial) |s| {
            if (this_serial != s or flags & 2 != 0) return error.ChainedStreamUnsupported;
        } else {
            if (flags != 2 or read(u32, h, 18) != 0) return error.InvalidContainer;
            serial = this_serial;
        }
        if (read(u32, h, 18) != sequence) return error.ContainerSequenceGap;
        if (sequence == std.math.maxInt(u32)) return error.ResourceLimitExceeded;
        sequence += 1;
        if ((flags & 1 != 0) != (partial != null)) return error.PartialPacket;
        const first_packet = packets.items.len;
        var body_pos = body_offset;
        for (h[27..][0..n]) |lace| {
            if (partial == null) partial = .{ .byte_offset = body_pos, .end_byte_offset = 0, .start_page = @intCast(pages.items.len), .end_page = 0, .payload_offset = payloads.items.len, .payload_length = 0 };
            if (partial.?.payload_length + lace > (if (packets.items.len < 2) max_header_bytes else max_packet_bytes)) return error.ResourceLimitExceeded;
            try payloads.appendSlice(allocator, bytes[body_pos..][0..lace]);
            body_pos += lace;
            partial.?.payload_length += lace;
            if (lace < 255) {
                partial.?.end_byte_offset = body_pos;
                partial.?.end_page = @intCast(pages.items.len);
                if (packets.items.len == max_inventory_entries) return error.ResourceLimitExceeded;
                try packets.append(allocator, partial.?);
                partial = null;
            }
        }
        const complete = packets.items.len - first_packet;
        const gp = read(u64, h, 6);
        if (complete == 0 and gp != std.math.maxInt(u64)) return error.InvalidGranule;
        if (pages.items.len == 0 and (packets.items.len != 1 or partial != null or gp != 0)) return error.InvalidHeader;
        if (first_packet <= 1 and packets.items.len >= 2 and (packets.items.len != 2 or partial != null or gp != 0)) return error.InvalidHeader;
        try pages.append(allocator, .{ .byte_offset = pos, .byte_length = @intCast(end - pos), .body_offset = body_offset, .granule = gp, .sequence = sequence - 1, .flags = flags, .first_packet = @intCast(first_packet), .completed_packets = @intCast(complete) });
        if (flags & 4 != 0) {
            if (partial != null) return error.PartialPacket;
            if (complete == 0 or packets.items.len < 3) return error.InvalidGranule;
            saw_eos = true;
        }
        pos = end;
    }
    if (partial != null) return error.PartialPacket;
    if (!saw_eos) return error.TruncatedContainer;
    if (packets.items.len < 3) return error.InvalidHeader;
    var info = try parseHeader(payloads.items[packets.items[0].payload_offset..][0..packets.items[0].payload_length]);
    try checkTags(payloads.items[packets.items[1].payload_offset..][0..packets.items[1].payload_length]);
    info.stream_serial = serial.?;
    var raw: u64 = 0;
    for (packets.items[2..]) |*packet| {
        const data = payloads.items[packet.payload_offset..][0..packet.payload_length];
        if (data.len == 0) return error.DecodeFailure;
        const frames = c.opus_packet_get_nb_samples(data.ptr, @intCast(data.len), t.sample_rate);
        if (frames <= 0 or frames > t.max_packet_frames) return error.DecodeFailure;
        packet.raw_frame = raw;
        packet.frames = @intCast(frames);
        raw += @intCast(frames);
    }
    info.raw_frames = raw;
    var origin: ?u64 = null;
    var previous_gp: u64 = 0;
    for (pages.items) |page| {
        const finish: usize = @as(usize, page.first_packet) + page.completed_packets;
        if (finish <= 2 or page.completed_packets == 0) continue;
        const last = packets.items[finish - 1];
        const page_raw_end = last.raw_frame + last.frames;
        if (page.granule > std.math.maxInt(i64)) return error.InvalidGranule;
        if (page.flags & 4 == 0) {
            if (origin == null) {
                if (page.granule < page_raw_end) return error.InvalidGranule;
                origin = page.granule - page_raw_end;
            }
            if (page.granule != page_raw_end + origin.?) return error.InvalidGranule;
        } else {
            // RFC 7845 4.5: even if the first completed audio page is EOS,
            // timestamp backwards when its granule exceeds decoded duration.
            // Otherwise the origin is zero and EOS may express end trim.
            if (origin == null) origin = page.granule -| raw;
            const start = origin.?;
            if (page.granule < previous_gp or page.granule < start + info.pre_skip or page.granule > raw + start) return error.InvalidGranule;
            const trim = raw + start - page.granule;
            if (trim > std.math.maxInt(u32)) return error.InvalidGranule;
            info.end_trim = @intCast(trim);
            info.audible_frames = page.granule - start - info.pre_skip;
            if (info.audible_frames == 0) return error.InvalidGranule;
            info.final_granule = page.granule;
        }
        previous_gp = page.granule;
    }
    info.granule_origin = origin orelse 0;
    const out_pages = try pages.toOwnedSlice(allocator);
    errdefer allocator.free(out_pages);
    const out_packets = try packets.toOwnedSlice(allocator);
    errdefer allocator.free(out_packets);
    const out_payloads = try payloads.toOwnedSlice(allocator);
    return .{ .allocator = allocator, .info = info, .pages = out_pages, .packets = out_packets, .payloads = out_payloads };
}
