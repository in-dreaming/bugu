//! TASK-010: actual encoded-byte Chunk/Seek producer. Compiler/worker only.
//! No decoder, source file, or unbounded inventory is retained by the result.
const std = @import("std");
const opus = @import("sme-opus");
const s = @import("sme-bank").schema;
pub const Error = opus.Error || error{InvalidSeekIndex};
pub const Options = struct {
    sound: u32 = 0,
    interval_frames: u32 = 48_000,
    target_chunk_bytes: u32 = 256 * 1024,
    max_chunk_bytes: u32 = 4 * 1024 * 1024,
    max_records: u32 = 65_536,
};
pub const Index = struct {
    /// Container/TOC validation only. A media compiler must also fully decode
    /// and run quality gates before this index can enter accepted bank IR.
    pub const requires_payload_decode = true;
    allocator: std.mem.Allocator,
    info: opus.OpusStreamInfo,
    encoded_hash: s.Hash,
    chunks: []s.Chunk,
    seeks: []s.SeekEntryV1,
    pub fn deinit(self: *Index) void {
        self.allocator.free(self.chunks);
        self.allocator.free(self.seeks);
        self.* = undefined;
    }
};
fn hash(bytes: []const u8) s.Hash {
    var out: s.Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
fn packetAt(scan: opus.Scan, raw: u64) usize {
    var lo: usize = 2;
    var hi = scan.packets.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (scan.packets[mid].raw_frame <= raw) lo = mid else hi = mid;
    }
    return lo;
}
fn appendChunk(allocator: std.mem.Allocator, list: *std.ArrayList(s.Chunk), bytes: []const u8, options: Options, start: u64, end: u64, first: u64, finish: u64) Error!void {
    if (end <= start or end - start > options.max_chunk_bytes or finish <= first or list.items.len >= options.max_records) return error.ResourceLimitExceeded;
    try list.append(allocator, .{ .sound = options.sound, .byte_offset = start, .byte_length = end - start, .first_frame = first, .frame_count = finish - first, .hash = hash(bytes[@intCast(start)..@intCast(end)]) });
}
/// Scans/validates the real Ogg bytes, then produces strictly increasing audible
/// seeks and contiguous page-aligned chunks. Hashes include all header bytes.
pub fn build(allocator: std.mem.Allocator, encoded: []const u8, options: Options) Error!Index {
    if (options.interval_frames == 0 or options.interval_frames > 48_000 or options.target_chunk_bytes == 0 or options.target_chunk_bytes > options.max_chunk_bytes or options.max_chunk_bytes > 4 * 1024 * 1024 or options.max_records == 0 or options.max_records > 65_536) return error.InvalidSeekIndex;
    var scan = try opus.inspect(allocator, encoded);
    defer scan.deinit();
    var chunks: std.ArrayList(s.Chunk) = .empty;
    defer chunks.deinit(allocator);
    var seeks: std.ArrayList(s.SeekEntryV1) = .empty;
    defer seeks.deinit(allocator);
    var start_byte: u64 = 0;
    var start_frame: u64 = 0;
    var previous_end: u64 = 0;
    var previous_frame: u64 = 0;
    for (scan.pages) |page| {
        const end = page.byte_offset + page.byte_length;
        if (end - start_byte > options.max_chunk_bytes) {
            // Cut before this page; never create a header-only/zero-frame chunk.
            try appendChunk(allocator, &chunks, encoded, options, start_byte, previous_end, start_frame, previous_frame);
            start_byte = previous_end;
            start_frame = previous_frame;
            if (end - start_byte > options.max_chunk_bytes) return error.ResourceLimitExceeded;
        }
        const finished: usize = @as(usize, page.first_packet) + page.completed_packets;
        if (finished > 2 and page.completed_packets > 0) {
            const packet = scan.packets[finished - 1];
            previous_frame = @min(scan.info.audible_frames, (packet.raw_frame + packet.frames) -| scan.info.pre_skip);
        }
        previous_end = end;
        if (end - start_byte >= options.target_chunk_bytes and previous_frame > start_frame and previous_frame < scan.info.audible_frames) {
            try appendChunk(allocator, &chunks, encoded, options, start_byte, end, start_frame, previous_frame);
            start_byte = end;
            start_frame = previous_frame;
        }
    }
    try appendChunk(allocator, &chunks, encoded, options, start_byte, encoded.len, start_frame, scan.info.audible_frames);
    var logical: u64 = 0;
    while (logical < scan.info.audible_frames) : (logical += options.interval_frames) {
        if (seeks.items.len >= options.max_records) return error.ResourceLimitExceeded;
        const target_raw = @as(u64, scan.info.pre_skip) + logical;
        const target = scan.packets[packetAt(scan, target_raw)];
        const recovery_packet = scan.packets[if (logical < opus.preroll_frames) 2 else packetAt(scan, target_raw -| opus.preroll_frames)];
        const discard = target_raw - recovery_packet.raw_frame;
        const preroll = logical - (recovery_packet.raw_frame -| scan.info.pre_skip);
        if (discard > std.math.maxInt(u32) or preroll > std.math.maxInt(u32)) return error.InvalidSeekIndex;
        const entry: s.SeekEntryV1 = .{
            .sound = options.sound,
            .logical_frame = logical,
            .page_byte_offset = scan.pages[recovery_packet.start_page].byte_offset,
            .granule_position = scan.pages[target.end_page].granule,
            .packet_byte_offset = target.byte_offset,
            .recovery_byte_offset = recovery_packet.byte_offset,
            .preroll_frames = @intCast(preroll),
            .discard_frames = @intCast(discard),
            .stream_serial = scan.info.stream_serial,
            .link_id = scan.info.link_id,
        };
        _ = try recovery(entry, scan.info);
        try seeks.append(allocator, entry);
    }
    const out_chunks = try chunks.toOwnedSlice(allocator);
    errdefer allocator.free(out_chunks);
    return .{ .allocator = allocator, .info = scan.info, .encoded_hash = hash(encoded), .chunks = out_chunks, .seeks = try seeks.toOwnedSlice(allocator) };
}
/// Reconstructs the exact decoder reset position without a packet inventory.
/// The bank/index must already be tied to the fetched bytes by its content hash.
/// Position BoundedPacketSource at (page_byte_offset, recovery_byte_offset), then
/// pass this result to Decoder.seek with the requested target >= entry.logical_frame.
pub fn recovery(entry: s.SeekEntryV1, info: opus.OpusStreamInfo) Error!opus.Recovery {
    if (entry.logical_frame >= info.audible_frames or entry.stream_serial != info.stream_serial or entry.link_id != 0 or info.link_id != 0 or entry.page_byte_offset >= entry.recovery_byte_offset or entry.recovery_byte_offset > entry.packet_byte_offset) return error.InvalidSeekIndex;
    const target_raw = std.math.add(u64, info.pre_skip, entry.logical_frame) catch return error.InvalidSeekIndex;
    const raw = std.math.sub(u64, target_raw, entry.discard_frames) catch return error.InvalidSeekIndex;
    if ((entry.logical_frame < opus.preroll_frames and raw != 0) or entry.preroll_frames != entry.logical_frame - (raw -| info.pre_skip) or (raw != 0 and entry.discard_frames < opus.preroll_frames)) return error.InvalidSeekIndex;
    const target_granule = std.math.add(u64, info.granule_origin, target_raw) catch return error.InvalidSeekIndex;
    if (entry.granule_position < target_granule or entry.granule_position > info.final_granule) return error.InvalidSeekIndex;
    return .{ .packet_byte_offset = entry.recovery_byte_offset, .raw_frame = raw, .page_byte_offset = entry.page_byte_offset };
}
