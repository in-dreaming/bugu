//! Worker/preparation-only descriptor-to-source binding. Reads only the bounded
//! first/last authenticated chunks. Reuses accepted OpusHead parsing; no whole
//! file scan, packet inventory, full decoded PCM or schema-stride extension.
const std = @import("std");
const opus = @import("sme-opus");
const schema = @import("sme-bank").schema;
const profile = @import("prefetch.zig");
pub const Error = opus.Error || profile.Error || error{ InvalidStreamAsset, HashMismatch };
pub const Descriptor = struct { sound_index: u32, sound: schema.Sound, codec: schema.Codec, chunks: []const schema.Chunk, seeks: []const schema.SeekEntryV1, source: opus.ByteSource };
const Page = struct { bytes: []const u8, body: []const u8, laces: []const u8, length: usize, flags: u8, serial: u32, sequence: u32, granule: u64 };
fn page(bytes: []const u8, offset: usize) Error!Page {
    if (offset > bytes.len or bytes.len - offset < 27) return error.TruncatedContainer;
    const head = bytes[offset..];
    if (!std.mem.eql(u8, head[0..4], "OggS") or head[4] != 0 or head[5] & ~@as(u8, 7) != 0) return error.InvalidContainer;
    const count: usize = head[26];
    if (head.len < 27 + count) return error.TruncatedContainer;
    const laces = head[27..][0..count];
    var body_len: usize = 0;
    for (laces) |n| body_len += n;
    const len = 27 + count + body_len;
    if (head.len < len) return error.TruncatedContainer;
    const data = head[0..len];
    if (opus.container.pageCrc(data) != std.mem.readInt(u32, head[22..26], .little)) return error.ContainerCrcMismatch;
    return .{ .bytes = data, .body = data[27 + count ..], .laces = laces, .length = len, .flags = head[5], .serial = std.mem.readInt(u32, head[14..18], .little), .sequence = std.mem.readInt(u32, head[18..22], .little), .granule = std.mem.readInt(u64, head[6..14], .little) };
}
fn fetch(scratch: []u8, source: opus.ByteSource, chunk: schema.Chunk) Error![]const u8 {
    if (chunk.byte_length > scratch.len or chunk.byte_offset > source.length or chunk.byte_length > source.length - chunk.byte_offset) return error.InvalidStreamAsset;
    const bytes = scratch[0..@intCast(chunk.byte_length)];
    try source.read_at(source.context, chunk.byte_offset, bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    if (!std.mem.eql(u8, &hash, &chunk.hash)) return error.HashMismatch;
    return bytes;
}
pub fn derive(scratch: []u8, desc: Descriptor, capacity: profile.StreamCapacityProfile) Error!opus.OpusStreamInfo {
    try capacity.validate();
    if (desc.sound.storage != .streaming or desc.sound.frames == 0 or desc.sound.blob_length != desc.source.length or desc.codec.kind != .ogg_opus or desc.codec.version != 1 or desc.chunks.len == 0 or desc.chunks.len > 65536 or desc.seeks.len == 0 or desc.seeks.len > 65536) return error.InvalidStreamAsset;
    var extent: u64 = 0;
    var frame_extent: u64 = 0;
    for (desc.chunks) |chunk| {
        if (chunk.sound != desc.sound_index or chunk.byte_offset != extent or chunk.first_frame != frame_extent or chunk.byte_length == 0 or chunk.byte_length > capacity.max_encoded_chunk_bytes or chunk.frame_count == 0) return error.InvalidStreamAsset;
        extent = std.math.add(u64, extent, chunk.byte_length) catch return error.InvalidStreamAsset;
        frame_extent = std.math.add(u64, frame_extent, chunk.frame_count) catch return error.InvalidStreamAsset;
    }
    if (extent != desc.source.length or frame_extent != desc.sound.frames) return error.InvalidStreamAsset;
    const first = try fetch(scratch, desc.source, desc.chunks[0]);
    const head = try page(first, 0);
    if (head.flags != 2 or head.sequence != 0 or head.granule != 0 or head.laces.len == 0 or head.laces[head.laces.len - 1] == 255) return error.InvalidHeader;
    for (head.laces[0 .. head.laces.len - 1]) |lace| if (lace != 255) return error.InvalidHeader;
    var info = try opus.container.parseHeader(head.body);
    info.stream_serial = head.serial;
    var offset: usize = head.length;
    var sequence: u32 = 1;
    var packet_index: usize = 1;
    var partial = false;
    var found_audio = false;
    while (offset < first.len and !found_audio) {
        const p = try page(first, offset);
        if (p.serial != info.stream_serial or p.sequence != sequence or p.flags & 2 != 0 or ((p.flags & 1 != 0) != partial)) return error.InvalidContainer;
        sequence = std.math.add(u32, sequence, 1) catch return error.ResourceLimitExceeded;
        var body_offset: usize = 0;
        for (p.laces) |lace| {
            if (!partial) {
                if (packet_index == 1) {
                    if (p.body.len - body_offset < 8 or !std.mem.eql(u8, p.body[body_offset..][0..8], "OpusTags")) return error.InvalidHeader;
                } else if (packet_index == 2) {
                    const locator = offset + 27 + p.laces.len + body_offset;
                    const seek = desc.seeks[0];
                    if (seek.logical_frame != 0 or seek.page_byte_offset != offset or seek.recovery_byte_offset != locator or seek.stream_serial != info.stream_serial) return error.InvalidStreamAsset;
                    found_audio = true;
                    break;
                }
            }
            body_offset += lace;
            partial = lace == 255;
            if (!partial) packet_index += 1;
        }
        offset += p.length;
    }
    if (!found_audio) return error.InvalidHeader;
    // Accepted first chunks contain positive audible coverage, hence the entire
    // header prefix and the first audio packet start. The last chunk is page
    // aligned and contains actual EOS, including foreign granule origins.
    const last_chunk = desc.chunks[desc.chunks.len - 1];
    const last = if (desc.chunks.len == 1) first else try fetch(scratch, desc.source, last_chunk);
    offset = 0;
    var expected_sequence: ?u32 = null;
    var final_granule: ?u64 = null;
    while (offset < last.len) {
        const p = try page(last, offset);
        if (p.serial != info.stream_serial or (last_chunk.byte_offset + offset != 0 and p.flags & 2 != 0) or final_granule != null) return error.InvalidContainer;
        if (expected_sequence) |expected| if (p.sequence != expected) return error.ContainerSequenceGap;
        expected_sequence = std.math.add(u32, p.sequence, 1) catch return error.ResourceLimitExceeded;
        if (p.flags & 4 != 0) {
            if (offset + p.length != last.len or p.laces.len == 0 or p.laces[p.laces.len - 1] == 255 or p.granule > std.math.maxInt(i64)) return error.InvalidGranule;
            final_granule = p.granule;
        }
        offset += p.length;
    }
    info.final_granule = final_granule orelse return error.TruncatedContainer;
    const audible_end = std.math.add(u64, info.pre_skip, desc.sound.frames) catch return error.InvalidStreamAsset;
    info.granule_origin = std.math.sub(u64, info.final_granule, audible_end) catch return error.InvalidGranule;
    info.audible_frames = desc.sound.frames;
    info.end_trim = desc.codec.end_trim;
    info.raw_frames = std.math.add(u64, audible_end, info.end_trim) catch return error.InvalidStreamAsset;
    return info;
}
