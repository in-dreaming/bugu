//! Pointer-free, bounded resident/direct-stream/fill-stream capture envelope. Large values are caller/heap
//! owned; encoding and decoding never copy a logical checkpoint by value.
const std = @import("std");
const director = @import("sme-director");
const trace = @import("sme-trace");
pub const version: u16 = 1;
pub const profile_version: u16 = 1;
pub const stream_direct_profile_version: u16 = 2;
pub const stream_fill_profile_version: u16 = 3;
pub const capacity: usize = director.snapshot_capacity + 2048;
pub const SnapshotV1 = struct {
    length: u32 = 0,
    bytes: [capacity]u8 = undefined,
    pub fn slice(self: *const SnapshotV1) []const u8 {
        return self.bytes[0..@min(self.length, capacity)];
    }
};
pub const TicketV1 = struct { context: u64, incarnation: u64 };
pub const PollV1 = union(enum) { pending, ready: struct { byte_size: u32, capture_frame: u64, hash: [32]u8 }, failed: @import("runtime_contract.zig").FailureV1 };
pub const RestorePollV1 = union(enum) { pending, installed: @import("contract.zig").PhaseReceipt, failed: @import("runtime_contract.zig").FailureV1 };
pub const Mode = enum(u8) { ready = 1, playing = 2, paused = 3 };
/// A remaining authored occurrence. Distance is musical frames from the captured
/// physical position (first entry) or preceding entry, never an absolute frame.
pub const Entry = struct { segment: u64, cue: u64, distance: u64, duration: u64, cursor: u64, tempo_span: u32, occurrence: u8, target: bool };
pub const Header = struct {
    magic: u64 = 0x3150435352454d53,
    version: u16 = version,
    profile_version: u16 = profile_version,
    algorithm_version: u16 = 1,
    byte_size: u32 = 0,
    logical_size: u32 = 0,
    bank_build_id: u64,
    bank_content_hash: [32]u8,
    profile: u64,
    saved_generation: u64,
    capture_frame: u64,
    capture_gate: u64,
    execution_ordinal: u64,
    executed_prefix: u8,
    mode: Mode,
    physical_segment: u64,
    cursor: u64,
    loop_epoch: u64,
    logical_bar: u64,
    fill_occurrence: ?u8,
    physical_path_id: u64 = 0,
    physical_fill_route: ?u64 = null,
    entry_count: u8,
    source_exit_cue: u64,
    fill_route: ?u64,
    path_id: u64,
};
pub const Decoded = struct {
    header: Header,
    entries: [3]Entry = undefined,
    logical: director.DirectorResidentSnapshotV1,
};
const header_size = trace.codec.maxSize(Header);
const entry_size = trace.codec.maxSize(Entry);
const checksum_size = 32;
pub fn encode(value: *const Decoded, out: *SnapshotV1) !void {
    if (value.header.entry_count > 3 or value.logical.length == 0 or value.logical.length > director.snapshot_capacity) return error.InvalidSnapshot;
    var header = value.header;
    header.logical_size = value.logical.length;
    // Optional fields have canonical variable length; fill size after encoding.
    var e: trace.codec.Encoder = .{ .bytes = &out.bytes };
    try e.put(header);
    for (value.entries[0..header.entry_count]) |entry| try e.put(entry);
    try e.put(value.logical.version);
    @memcpy(out.bytes[e.offset..][0..value.logical.length], value.logical.payload[0..value.logical.length]);
    e.offset += value.logical.length;
    header.byte_size = @intCast(e.offset + checksum_size);
    var h: trace.codec.Encoder = .{ .bytes = &out.bytes };
    try h.put(header);
    const checksum = hash(out.bytes[0..e.offset]);
    @memcpy(out.bytes[e.offset..][0..checksum_size], &checksum);
    out.length = header.byte_size;
}
pub fn decode(bytes: []const u8, out: *Decoded) !void {
    if (bytes.len > capacity or bytes.len < checksum_size) return error.InvalidSnapshot;
    const body = bytes[0 .. bytes.len - checksum_size];
    if (!std.mem.eql(u8, &hash(body), bytes[bytes.len - checksum_size ..])) return error.InvalidSnapshotChecksum;
    var d: trace.codec.Decoder = .{ .bytes = body };
    out.header = try d.get(Header);
    const h = &out.header;
    if (h.magic != 0x3150435352454d53 or h.version != version or (h.profile_version != profile_version and h.profile_version != stream_direct_profile_version and h.profile_version != stream_fill_profile_version) or h.algorithm_version != 1) return error.UnsupportedVersion;
    if (h.byte_size != bytes.len or h.entry_count > 3 or h.executed_prefix > 3 or h.logical_size == 0 or h.logical_size > director.snapshot_capacity or h.capture_gate == 0 or h.execution_ordinal == 0 or h.saved_generation == 0 or h.bank_build_id == 0) return error.InvalidSnapshot;
    if ((h.mode == .ready) != (h.physical_segment == 0) or (h.physical_segment == 0 and (h.cursor != 0 or h.loop_epoch != 0 or h.fill_occurrence != null))) return error.InvalidSnapshot;
    if (h.fill_occurrence) |occurrence| if (occurrence >= 2) return error.InvalidSnapshot;
    // Semantic profile 2 never admits a partially executed route or fill.
    if (h.profile_version == stream_direct_profile_version and (h.entry_count != 0 or h.executed_prefix != 0 or h.fill_occurrence != null or h.physical_path_id != 0 or h.physical_fill_route != null or h.source_exit_cue != 0 or h.fill_route != null or h.path_id != 0)) return error.UnsupportedCapability;
    for (out.entries[0..h.entry_count], 0..) |*entry, i| {
        entry.* = try d.get(Entry);
        if (entry.segment == 0 or entry.cue == 0 or entry.occurrence >= 3 or entry.target != (i + 1 == h.entry_count) or (i > 0 and entry.distance == 0)) return error.InvalidSnapshot;
    }
    out.logical.version = try d.get(u16);
    out.logical.length = h.logical_size;
    if (body.len - d.offset != h.logical_size) return error.InvalidSnapshot;
    @memcpy(out.logical.payload[0..h.logical_size], body[d.offset..]);
}
pub fn validateIdentity(value: *const Decoded, build: u64, content_hash: [32]u8, profile: u64) !void {
    if (value.header.bank_build_id != build or !std.mem.eql(u8, &value.header.bank_content_hash, &content_hash)) return error.StaleAssetGeneration;
    if (value.header.profile != profile) return error.UnsupportedCapability;
}
pub fn hash(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
pub fn resource(value: *const Decoded, bytes: []const u8) trace.schema.lifecycle.SnapshotResource {
    return .{ .schema_version = version, .byte_size = bytes.len, .bytes_hash = hash(bytes), .bank_build_id = value.header.bank_build_id, .bank_generation = value.header.saved_generation, .capture_render_frame = value.header.capture_frame };
}
comptime {
    if (header_size + 3 * entry_size + director.snapshot_capacity + 2 + checksum_size > capacity) @compileError("resident snapshot bound");
}

/// Exact-byte bridge for the existing replay consumer methods. The application
/// resolves persisted resources; these helpers never reconstruct substitute
/// bytes or claim that the rest of public-runtime replay is implemented.
pub const ResourceResolver = struct {
    context: *anyopaque,
    resolve: *const fn (*anyopaque, trace.schema.lifecycle.SnapshotResource) anyerror![]const u8,
    target: trace.schema.lifecycle.BankIdentity,
    profile: u64,
    decoded: *Decoded,
    snapshot_profile: @import("runtime_contract.zig").SnapshotProfileV1 = .resident_v1,
    pub fn prepareRestore(self: *ResourceResolver, event: trace.schema.lifecycle.Restore) !trace.replay.PreparedRestore {
        if (event.migration != null) return error.UnsupportedMigration;
        const bytes = try self.resolve(self.context, event.snapshot);
        const prepared: trace.replay.PreparedRestore = .{ .snapshot = .{ .reference = event.snapshot, .bytes = bytes }, .migration = null };
        try trace.replay.verifyRestore(event, prepared);
        return prepared;
    }
    pub fn validateRestore(self: *ResourceResolver, event: trace.schema.lifecycle.Restore, prepared: trace.replay.PreparedRestore) !void {
        if (event.migration != null or !std.meta.eql(event.target_bank, self.target)) return error.UnsupportedMigration;
        try trace.replay.verifyRestore(event, prepared);
        try decode(prepared.snapshot.bytes, self.decoded);
        if (self.decoded.header.profile_version != @intFromEnum(self.snapshot_profile)) return error.UnsupportedCapability;
        try validateIdentity(self.decoded, self.target.build_id, self.target.content_hash, self.profile);
        if (!std.meta.eql(resource(self.decoded, prepared.snapshot.bytes), event.snapshot)) return error.ResourceNotPrepared;
    }
};

test "stream fill semantic profile extends wire v1 without widening direct profile" {
    const t = std.testing;
    const value = try t.allocator.create(Decoded);
    defer t.allocator.destroy(value);
    const decoded = try t.allocator.create(Decoded);
    defer t.allocator.destroy(decoded);
    const snapshot = try t.allocator.create(SnapshotV1);
    defer t.allocator.destroy(snapshot);
    value.header = .{ .profile_version = stream_fill_profile_version, .bank_build_id = 7, .bank_content_hash = @splat(1), .profile = 2, .saved_generation = 1, .capture_frame = 128, .capture_gate = 1, .execution_ordinal = 2, .executed_prefix = 1, .mode = .playing, .physical_segment = 11, .cursor = 12, .loop_epoch = 0, .logical_bar = 0, .fill_occurrence = 0, .physical_path_id = 33, .physical_fill_route = 44, .entry_count = 1, .source_exit_cue = 55, .fill_route = 44, .path_id = 33 };
    value.entries[0] = .{ .segment = 22, .cue = 66, .distance = 16, .duration = 32, .cursor = 0, .tempo_span = 0, .occurrence = 1, .target = true };
    value.logical.version = director.resident_snapshot_version;
    value.logical.length = 1;
    value.logical.payload[0] = 0;
    try encode(value, snapshot);
    try decode(snapshot.slice(), decoded);
    try t.expectEqual(@as(u16, 1), decoded.header.version);
    try t.expectEqual(@as(u16, 3), decoded.header.profile_version);
    try t.expectEqual(@as(u8, 1), decoded.header.entry_count);
    try t.expectEqual(value.entries[0], decoded.entries[0]);
    value.header.profile_version = stream_direct_profile_version;
    try encode(value, snapshot);
    try t.expectError(error.UnsupportedCapability, decode(snapshot.slice(), decoded));
    value.header.profile_version = 4;
    try encode(value, snapshot);
    try t.expectError(error.UnsupportedVersion, decode(snapshot.slice(), decoded));
    value.header.profile_version = stream_fill_profile_version;
    value.entries[0].target = false;
    try encode(value, snapshot);
    try t.expectError(error.InvalidSnapshot, decode(snapshot.slice(), decoded));
    value.header.entry_count = 4;
    try t.expectError(error.InvalidSnapshot, encode(value, snapshot));
}
