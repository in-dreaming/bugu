//! Separate versioned extension bound to an exact MigrationMapV1 hash/build pair.
//! It chooses an epoch count only. It does not transplant selector history,
//! revision/cursor, or promise the same random sequence after an ID rename.
const std = @import("std");
const music = @import("music");
const migration = @import("sme-reload-contract").migration;
pub const version: u16 = 1;
pub const header_bytes: usize = 112;
pub const max_entries: usize = migration.max_entries_per_category;
pub const max_encoded_bytes: usize = header_bytes + max_entries * 24;
pub const supported_capabilities: u64 = 3;
pub const EpochPolicy = enum(u16) { preserve_epoch = 1, reset_epoch = 2, _ };
pub const Entry = struct { from: music.SegmentSelectorId, to: music.SegmentSelectorId, policy: EpochPolicy };
pub const Selector = struct { id: music.SegmentSelectorId, stochastic: bool };
pub const Catalogs = struct { source: []const Selector, target: []const Selector };
pub const Diagnostic = struct { from: music.SegmentSelectorId = .invalid, to: music.SegmentSelectorId = .invalid, source_index: ?usize = null, target_index: ?usize = null };
pub const Description = struct {
    schema_version: u16 = version,
    from_build_id: u64,
    to_build_id: u64,
    map_hash: [32]u8,
    required_capabilities: u64,
    entries: []const Entry = &.{},
};
pub const Error = migration.Error || error{ MissingEpochPolicy, UnexpectedEpochPolicy, UnsupportedEpochPolicy, InvalidPolicyCatalog };

pub const RuntimeMigrationPolicyV1 = struct {
    allocator: std.mem.Allocator,
    description: Description,
    content_hash: [32]u8,

    pub fn init(allocator: std.mem.Allocator, description: Description, map: *const migration.MigrationMapV1, context: migration.ValidationContext, catalogs: Catalogs, diagnostic: ?*Diagnostic) Error!RuntimeMigrationPolicyV1 {
        try validate(description, map, context, catalogs, diagnostic);
        const entries = try allocator.dupe(Entry, description.entries);
        std.mem.sort(Entry, entries, {}, less);
        var owned = description;
        owned.entries = entries;
        var result = RuntimeMigrationPolicyV1{ .allocator = allocator, .description = owned, .content_hash = @splat(0) };
        result.content_hash = result.calculateHash();
        return result;
    }
    pub fn deinit(self: *RuntimeMigrationPolicyV1) void {
        self.allocator.free(self.description.entries);
        self.* = undefined;
    }
    pub fn validateFor(self: *const RuntimeMigrationPolicyV1, map: *const migration.MigrationMapV1, context: migration.ValidationContext, catalogs: Catalogs, diagnostic: ?*Diagnostic) Error!void {
        try validate(self.description, map, context, catalogs, diagnostic);
        for (self.description.entries, 0..) |entry, i| if (i != 0 and !less({}, self.description.entries[i - 1], entry)) return error.NonCanonicalEncoding;
        if (!std.mem.eql(u8, &self.content_hash, &self.calculateHash())) return error.HashMismatch;
    }
    pub fn encodedLen(self: *const RuntimeMigrationPolicyV1) usize { return header_bytes + self.description.entries.len * 24; }
    fn header(self: *const RuntimeMigrationPolicyV1) [header_bytes]u8 {
        var bytes: [header_bytes]u8 = @splat(0);
        @memcpy(bytes[0..8], "BUGUEPC1");
        put(&bytes, 8, version);
        put(&bytes, 10, @as(u16, header_bytes));
        put(&bytes, 12, @as(u32, @intCast(self.encodedLen())));
        put(&bytes, 16, self.description.required_capabilities);
        put(&bytes, 24, self.description.from_build_id);
        put(&bytes, 32, self.description.to_build_id);
        @memcpy(bytes[40..72], &self.description.map_hash);
        put(&bytes, 104, @as(u32, @intCast(self.description.entries.len)));
        return bytes;
    }
    fn calculateHash(self: *const RuntimeMigrationPolicyV1) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        const bytes = self.header();
        hasher.update(&bytes);
        for (self.description.entries) |entry| hasher.update(&row(entry));
        return hasher.finalResult();
    }
    /// Failure leaves destination unchanged. All validation is off Render.
    pub fn encode(self: *const RuntimeMigrationPolicyV1, map: *const migration.MigrationMapV1, context: migration.ValidationContext, catalogs: Catalogs, destination: []u8) Error!usize {
        try self.validateFor(map, context, catalogs, null);
        const len = self.encodedLen();
        if (destination.len < len) return error.BufferTooSmall;
        const bytes = self.header();
        @memcpy(destination[0..header_bytes], &bytes);
        @memcpy(destination[72..104], &self.content_hash);
        for (self.description.entries, 0..) |entry, i| @memcpy(destination[header_bytes + i * 24 ..][0..24], &row(entry));
        return len;
    }
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, map: *const migration.MigrationMapV1, context: migration.ValidationContext, catalogs: Catalogs, diagnostic: ?*Diagnostic) Error!RuntimeMigrationPolicyV1 {
        if (bytes.len < header_bytes or bytes.len > max_encoded_bytes) return error.InvalidLength;
        if (!std.mem.eql(u8, bytes[0..8], "BUGUEPC1")) return error.InvalidMagic;
        if (get(bytes, 8, u16) != version) return error.UnknownVersion;
        if (get(bytes, 10, u16) != header_bytes or !std.mem.allEqual(u8, bytes[108..112], 0)) return error.NonCanonicalEncoding;
        const count = get(bytes, 104, u32);
        if (count > max_entries or bytes.len != header_bytes + @as(usize, count) * 24 or get(bytes, 12, u32) != bytes.len) return error.InvalidLength;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(bytes[0..72]);
        hasher.update(&@as([32]u8, @splat(0)));
        hasher.update(bytes[104..]);
        if (!std.mem.eql(u8, bytes[72..104], &hasher.finalResult())) return error.HashMismatch;
        const entries = try allocator.alloc(Entry, count);
        defer allocator.free(entries);
        for (entries, 0..) |*entry, i| {
            const offset = header_bytes + i * 24;
            if (!std.mem.allEqual(u8, bytes[offset + 18 ..][0..6], 0)) return error.NonCanonicalEncoding;
            entry.* = .{ .from = @enumFromInt(get(bytes, offset, u64)), .to = @enumFromInt(get(bytes, offset + 8, u64)), .policy = @enumFromInt(get(bytes, offset + 16, u16)) };
            if (i != 0 and !less({}, entries[i - 1], entry.*)) return error.NonCanonicalEncoding;
        }
        var result = try init(allocator, .{ .from_build_id = get(bytes, 24, u64), .to_build_id = get(bytes, 32, u64), .map_hash = bytes[40..72].*, .required_capabilities = get(bytes, 16, u64), .entries = entries }, map, context, catalogs, diagnostic);
        errdefer result.deinit();
        if (!std.mem.eql(u8, &result.content_hash, bytes[72..104])) return error.NonCanonicalEncoding;
        return result;
    }
    /// Unchanged IDs retain existing behavior. Renamed stochastic selectors need
    /// an explicit entry; preserve keeps the count, while RNG still uses NEW ID.
    /// This is not a complete selector-State conversion or mutation operation.
    pub fn epochFor(self: *const RuntimeMigrationPolicyV1, map: *const migration.MigrationMapV1, context: migration.ValidationContext, catalogs: Catalogs, from: music.SegmentSelectorId, old_epoch: u64) Error!u64 {
        try self.validateFor(map, context, catalogs, null);
        const to = try map.mapSelector(context, from);
        if (from == to) return old_epoch;
        for (self.description.entries) |entry| if (entry.from == from) return switch (entry.policy) {
            .preserve_epoch => old_epoch,
            .reset_epoch => 0,
            else => error.UnsupportedEpochPolicy,
        };
        return old_epoch; // Non-stochastic rename, already validated above.
    }
};
fn less(_: void, a: Entry, b: Entry) bool { return a.from.value() < b.from.value(); }
fn put(bytes: []u8, offset: usize, value: anytype) void { std.mem.writeInt(@TypeOf(value), bytes[offset..][0..@sizeOf(@TypeOf(value))], value, .little); }
fn get(bytes: []const u8, offset: usize, comptime T: type) T { return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little); }
fn row(entry: Entry) [24]u8 {
    var bytes: [24]u8 = @splat(0);
    put(&bytes, 0, entry.from.value()); put(&bytes, 8, entry.to.value()); put(&bytes, 16, @intFromEnum(entry.policy));
    return bytes;
}
fn locate(values: []const Selector, id: music.SegmentSelectorId) ?usize { for (values, 0..) |value, i| if (value.id == id) return i; return null; }
fn checkCatalog(values: []const Selector, ids: []const music.SegmentSelectorId) Error!void {
    if (values.len != ids.len) return error.InvalidPolicyCatalog;
    for (values, 0..) |value, i| {
        if (!value.id.isValid()) return error.InvalidPolicyCatalog;
        for (values[0..i]) |prior| if (value.id == prior.id) return error.InvalidPolicyCatalog;
        for (ids) |id| { if (id == value.id) break; } else return error.InvalidPolicyCatalog;
    }
}
fn validate(description: Description, map: *const migration.MigrationMapV1, context: migration.ValidationContext, catalogs: Catalogs, diagnostic: ?*Diagnostic) Error!void {
    if (diagnostic) |out| out.* = .{};
    try map.validateFor(context);
    if (description.schema_version != version) return error.UnknownVersion;
    if (description.from_build_id != context.from_build_id or description.to_build_id != context.to_build_id) return error.BuildIdMismatch;
    if (!std.mem.eql(u8, &description.map_hash, &map.content_hash)) return error.HashMismatch;
    if (description.required_capabilities & ~supported_capabilities != 0) return error.UnsupportedCapability;
    if (description.entries.len > max_entries) return error.ResourceLimitExceeded;
    try checkCatalog(catalogs.source, context.source.selectors);
    try checkCatalog(catalogs.target, context.target.selectors);
    for (description.entries, 0..) |entry, i| {
        if (!entry.from.isValid() or !entry.to.isValid()) return error.InvalidId;
        if (entry.from == entry.to) return error.UnexpectedEpochPolicy;
        const capability: u64 = switch (entry.policy) { .preserve_epoch => 1, .reset_epoch => 2, else => return error.UnsupportedEpochPolicy };
        if (description.required_capabilities & capability == 0) return error.MissingCapability;
        for (description.entries[0..i]) |prior| {
            if (entry.from == prior.from) return error.DuplicateSource;
            if (entry.to == prior.to) return error.DuplicateTarget;
        }
        const from_index = locate(catalogs.source, entry.from) orelse return error.MissingSource;
        const to_index = locate(catalogs.target, entry.to) orelse return error.MissingTarget;
        if (!catalogs.source[from_index].stochastic and !catalogs.target[to_index].stochastic) return error.UnexpectedEpochPolicy;
        for (map.description.selectors) |pair| { if (pair.from == entry.from and pair.to == entry.to) break; } else return error.MissingRequiredMapping;
    }
    for (map.description.selectors) |pair| {
        if (pair.from == pair.to) continue;
        const from_index = locate(catalogs.source, pair.from) orelse return error.MissingSource;
        const to_index = locate(catalogs.target, pair.to) orelse return error.MissingTarget;
        if (!catalogs.source[from_index].stochastic and !catalogs.target[to_index].stochastic) continue;
        for (description.entries) |entry| { if (entry.from == pair.from and entry.to == pair.to) break; } else {
            if (diagnostic) |out| out.* = .{ .from = pair.from, .to = pair.to, .source_index = from_index, .target_index = to_index };
            return error.MissingEpochPolicy;
        }
    }
}
