//! Bounded worker demux over random-access fetched bytes. Does not retain a
//! complete stream or index. Source must outlive this object and the decoder.
const std = @import("std");
const t = @import("types.zig");
const container = @import("container.zig");
const decoder = @import("decoder.zig");
pub const max_page_bytes: usize = 27 + 255 + 255 * 255;
pub const ByteSource = struct {
    context: *anyopaque,
    length: u64,
    /// Exactly fills destination or fails. Worker may satisfy this from its
    /// bounded prefetch chunks or synchronous non-render I/O.
    read_at: *const fn (*anyopaque, u64, []u8) t.Error!void,
};
pub const BoundedPacketSource = struct {
    allocator: std.mem.Allocator,
    source: ByteSource,
    info: t.OpusStreamInfo,
    page: []u8,
    page_offset: u64 = 0,
    page_length: usize = 0,
    segment: usize = 0,
    body: usize = 0,
    locator: u64 = 0,
    valid: bool = false,
    pub fn prepare(allocator: std.mem.Allocator, source: ByteSource, info: t.OpusStreamInfo) t.Error!BoundedPacketSource {
        return .{ .allocator = allocator, .source = source, .info = info, .page = try allocator.alloc(u8, max_page_bytes) };
    }
    pub fn deinit(self: *BoundedPacketSource) void {
        self.allocator.free(self.page);
        self.* = undefined;
    }
    fn read(self: *BoundedPacketSource, offset: u64, destination: []u8) t.Error!void {
        if (offset > self.source.length or destination.len > self.source.length - offset) return error.TruncatedContainer;
        try self.source.read_at(self.source.context, offset, destination);
    }
    fn load(self: *BoundedPacketSource, offset: u64, expected_sequence: ?u32) t.Error!void {
        self.valid = false;
        try self.read(offset, self.page[0..27]);
        if (!std.mem.eql(u8, self.page[0..4], "OggS") or self.page[4] != 0 or self.page[5] & ~@as(u8, 7) != 0) return error.InvalidContainer;
        const count: usize = self.page[26];
        try self.read(offset + 27, self.page[27..][0..count]);
        var body_len: usize = 0;
        for (self.page[27..][0..count]) |lace| body_len += lace;
        const size = 27 + count + body_len;
        try self.read(offset + 27 + count, self.page[27 + count .. size]);
        if (container.pageCrc(self.page[0..size]) != std.mem.readInt(u32, self.page[22..26], .little)) return error.ContainerCrcMismatch;
        if (std.mem.readInt(u32, self.page[14..18], .little) != self.info.stream_serial) return error.ChainedStreamUnsupported;
        if (expected_sequence) |expected| {
            if (self.page[5] & 2 != 0) return error.ChainedStreamUnsupported;
            if (std.mem.readInt(u32, self.page[18..22], .little) != expected) return error.ContainerSequenceGap;
        }
        if (self.page[5] & 4 != 0) {
            if (offset + size != self.source.length) return error.ChainedStreamUnsupported;
            if (std.mem.readInt(u64, self.page[6..14], .little) != self.info.final_granule) return error.InvalidGranule;
        }
        self.page_offset = offset;
        self.page_length = size;
        self.segment = 0;
        self.body = 27 + count;
        self.valid = true;
    }
    /// Both page and packet offsets come from the verified stream index.
    /// Position this reader before Decoder.prepare/reset/seek.
    pub fn positionAt(self: *BoundedPacketSource, page_byte_offset: u64, packet_byte_offset: u64) t.Error!void {
        try self.load(page_byte_offset, null);
        var continuation = self.page[5] & 1 != 0;
        while (self.segment < self.page[26]) {
            if (!continuation and self.page_offset + self.body == packet_byte_offset) {
                self.locator = packet_byte_offset;
                return;
            }
            const lace = self.page[27 + self.segment];
            self.body += lace;
            self.segment += 1;
            continuation = lace == 255;
        }
        self.valid = false;
        return error.SeekOutOfRange;
    }
    fn advance(self: *BoundedPacketSource, continuation: bool) t.Error!void {
        if (self.page[5] & 4 != 0) return error.PartialPacket;
        const sequence = std.mem.readInt(u32, self.page[18..22], .little);
        if (sequence == std.math.maxInt(u32)) return error.ContainerSequenceGap;
        const next = self.page_offset + self.page_length;
        try self.load(next, sequence + 1);
        if ((self.page[5] & 1 != 0) != continuation) return error.PartialPacket;
    }
    fn readPacket(ctx: *anyopaque, offset: u64, destination: []u8) t.Error!decoder.ReadResult {
        const self: *BoundedPacketSource = @ptrCast(@alignCast(ctx));
        if (!self.valid or self.locator != offset) return error.SeekOutOfRange;
        var wrote: usize = 0;
        while (true) {
            if (self.segment == self.page[26]) {
                try self.advance(true);
                continue;
            }
            const lace = self.page[27 + self.segment];
            if (lace > destination.len - wrote) return error.BufferTooSmall;
            @memcpy(destination[wrote..][0..lace], self.page[self.body..][0..lace]);
            wrote += lace;
            self.body += lace;
            self.segment += 1;
            if (lace < 255) break;
        }
        if (wrote == 0) return error.DecodeFailure;
        while (self.segment == self.page[26]) {
            if (self.page[5] & 4 != 0) {
                self.locator = 0;
                return .{ .bytes = wrote, .next_byte_offset = 0 };
            }
            try self.advance(false);
        }
        self.locator = self.page_offset + self.body;
        return .{ .bytes = wrote, .next_byte_offset = self.locator };
    }
    pub fn reader(self: *BoundedPacketSource) decoder.PacketReader {
        return .{ .context = self, .read = readPacket };
    }
};
