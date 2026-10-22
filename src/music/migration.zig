//! Owned TASK-016 migration contract, validated and encoded off Render.
//! IDs in each category name entities in the exact from/to build namespaces.
//! Maps apply ONE hop; they are never recursively resolved. Equal numeric IDs
//! across categories are unrelated. Explicit identity pairs are legal; a
//! nontrivial same-category numeric rename cycle is rejected by the v1 format.
const std = @import("std");
const music = @import("music");
const wire = @import("generation_wire.zig");
pub const Hash = wire.Hash;
pub const version: u16 = 1;
/// Format safety ceilings, not a production runtime/platform memory profile.
pub const max_entries_per_category: usize = 1024;
pub const max_history_entries: usize = 64;
pub const max_encoded_bytes: usize = wire.header_bytes + 3 * (12 + 16 * max_entries_per_category);
pub const Error = wire.Error || std.mem.Allocator.Error || error{
    InvalidBuildId, BuildIdMismatch, UnsupportedCapability, MissingCapability,
    UnsupportedHistoryPolicy, InvalidId, DuplicateSource, DuplicateTarget,
    MigrationCycle, InvalidCatalog, MissingSource, MissingTarget,
    MissingRequiredMapping, ResourceLimitExceeded, HistoryCapacityExceeded,
};
pub const Capability = enum(u6) { state_map, segment_map, selector_map, history_remap, history_reset };
pub fn bit(capability: Capability) u64 { return @as(u64, 1) << @intFromEnum(capability); }
pub const supported_capabilities: u64 = (1 << 5) - 1;
/// These policies convert only the ordered stable-segment history payload.
/// Selector algorithm, cursor, RNG/epoch and committed state are NOT invented or
/// transplanted here. Their compatibility is a future transaction-owner check.
pub const HistoryPolicy = enum(u16) { remap_exact = 1, reset_explicit = 2, _ };
fn Pair(comptime Id: type) type { return struct { from: Id, to: Id }; }
pub const StateMapping = Pair(music.MusicStateId);
pub const SegmentMapping = Pair(music.SegmentId);
pub const SelectorMapping = Pair(music.SegmentSelectorId);
pub const Description = struct {
    schema_version: u16 = version,
    from_build_id: u64,
    to_build_id: u64,
    required_capabilities: u64,
    history_policy: HistoryPolicy,
    states: []const StateMapping = &.{},
    segments: []const SegmentMapping = &.{},
    selectors: []const SelectorMapping = &.{},
};
/// Borrowed for validation only. The producer obtains these inventories from
/// individually validated typed bank artifacts; this module does not load banks.
pub const Inventory = struct {
    states: []const music.MusicStateId = &.{},
    segments: []const music.SegmentId = &.{},
    selectors: []const music.SegmentSelectorId = &.{},
};
pub const ValidationContext = struct {
    from_build_id: u64,
    to_build_id: u64,
    available_capabilities: u64 = supported_capabilities,
    source: Inventory,
    target: Inventory,
    /// Required committed state/segment/selector references must be explicit,
    /// including unchanged identities. There is no implicit identity fallback.
    required: Inventory = .{},
};
pub const ConvertedHistory = struct {
    selector: music.SegmentSelectorId,
    policy: HistoryPolicy,
    len: usize = 0,
    entries: [max_history_entries]music.SegmentId = @splat(.invalid),
    pub fn slice(self: *const ConvertedHistory) []const music.SegmentId { return self.entries[0..self.len]; }
};

/// Allocator-owned arrays with canonical ordering and a content hash. Treat the
/// value as immutable and move-only; use deinit exactly once. Input slices and
/// decoder bytes may be changed/freed immediately after init/decode returns.
pub const MigrationMapV1 = struct {
    allocator: std.mem.Allocator,
    description: Description,
    content_hash: Hash,

    pub fn init(allocator: std.mem.Allocator, description: Description, context: ValidationContext) Error!MigrationMapV1 {
        try validateDescription(description, context);
        const states = try allocator.dupe(StateMapping, description.states);
        errdefer allocator.free(states);
        const segments = try allocator.dupe(SegmentMapping, description.segments);
        errdefer allocator.free(segments);
        const selectors = try allocator.dupe(SelectorMapping, description.selectors);
        errdefer allocator.free(selectors);
        sort(StateMapping, states);
        sort(SegmentMapping, segments);
        sort(SelectorMapping, selectors);
        var owned = description;
        owned.states = states;
        owned.segments = segments;
        owned.selectors = selectors;
        var self = MigrationMapV1{ .allocator = allocator, .description = owned, .content_hash = @splat(0) };
        self.content_hash = self.calculateHash();
        return self;
    }
    pub fn deinit(self: *MigrationMapV1) void {
        self.allocator.free(self.description.states);
        self.allocator.free(self.description.segments);
        self.allocator.free(self.description.selectors);
        self.* = undefined;
    }
    pub fn encodedLen(self: *const MigrationMapV1) usize {
        return wire.header_bytes + 36 + 16 * (self.description.states.len + self.description.segments.len + self.description.selectors.len);
    }
    fn calculateHash(self: *const MigrationMapV1) Hash {
        // 49,268 bytes bounded Worker/Control scratch; never allocated on Render.
        var bytes: [max_encoded_bytes]u8 = undefined;
        self.writeCanonical(bytes[0..self.encodedLen()]);
        return wire.digest(bytes[0..self.encodedLen()]);
    }
    pub fn validateFor(self: *const MigrationMapV1, context: ValidationContext) Error!void {
        try validateDescription(self.description, context);
        try requireSorted(self.description.states);
        try requireSorted(self.description.segments);
        try requireSorted(self.description.selectors);
        if (!std.mem.eql(u8, &self.content_hash, &self.calculateHash())) return error.HashMismatch;
    }
    /// Returns exact encoded length. Failure leaves the destination untouched.
    pub fn encode(self: *const MigrationMapV1, context: ValidationContext, destination: []u8) Error!usize {
        try self.validateFor(context);
        const len = self.encodedLen();
        if (destination.len < len) return error.BufferTooSmall;
        self.writeCanonical(destination[0..len]);
        @memcpy(destination[wire.hash_offset..][0..32], &self.content_hash);
        return len;
    }
    fn writeCanonical(self: *const MigrationMapV1, bytes: []u8) void {
        @memset(bytes, 0);
        @memcpy(bytes[0..8], "BUGUMIG1");
        wire.put(bytes, 8, version);
        wire.put(bytes, 10, @as(u16, wire.header_bytes));
        wire.put(bytes, 12, @as(u32, @intCast(bytes.len)));
        wire.put(bytes, 16, self.description.required_capabilities);
        wire.put(bytes, 24, self.description.from_build_id);
        wire.put(bytes, 32, self.description.to_build_id);
        wire.put(bytes, 40, @intFromEnum(self.description.history_policy));
        var offset: usize = wire.header_bytes;
        inline for (.{ "states", "segments", "selectors" }, 1..) |field, tag| {
            const entries = @field(self.description, field);
            wire.put(bytes, offset, @as(u16, tag));
            wire.put(bytes, offset + 2, @as(u16, 16));
            wire.put(bytes, offset + 4, @as(u32, @intCast(entries.len * 16)));
            wire.put(bytes, offset + 8, @as(u32, @intCast(entries.len)));
            offset += 12;
            for (entries) |entry| {
                wire.put(bytes, offset, entry.from.value());
                wire.put(bytes, offset + 8, entry.to.value());
                offset += 16;
            }
        }
    }
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, context: ValidationContext) Error!MigrationMapV1 {
        try wire.check(bytes, "BUGUMIG1", max_encoded_bytes);
        if (wire.get(bytes, 10, u16) != wire.header_bytes or !std.mem.allEqual(u8, bytes[42..48], 0)) return error.NonCanonicalEncoding;
        var offset: usize = wire.header_bytes;
        const states = try readPairs(StateMapping, allocator, bytes, &offset, 1);
        defer allocator.free(states);
        const segments = try readPairs(SegmentMapping, allocator, bytes, &offset, 2);
        defer allocator.free(segments);
        const selectors = try readPairs(SelectorMapping, allocator, bytes, &offset, 3);
        defer allocator.free(selectors);
        if (offset != bytes.len) return error.InvalidLength;
        var result = try init(allocator, .{
            .from_build_id = wire.get(bytes, 24, u64), .to_build_id = wire.get(bytes, 32, u64),
            .required_capabilities = wire.get(bytes, 16, u64), .history_policy = @enumFromInt(wire.get(bytes, 40, u16)),
            .states = states, .segments = segments, .selectors = selectors,
        }, context);
        errdefer result.deinit();
        if (!std.mem.eql(u8, &result.content_hash, bytes[wire.hash_offset..][0..32])) return error.NonCanonicalEncoding;
        return result;
    }
    pub fn mapState(self: *const MigrationMapV1, context: ValidationContext, id: music.MusicStateId) Error!music.MusicStateId {
        try self.validateFor(context);
        return lookup(self.description.states, id) orelse error.MissingRequiredMapping;
    }
    pub fn mapSegment(self: *const MigrationMapV1, context: ValidationContext, id: music.SegmentId) Error!music.SegmentId {
        try self.validateFor(context);
        return lookup(self.description.segments, id) orelse error.MissingRequiredMapping;
    }
    pub fn mapSelector(self: *const MigrationMapV1, context: ValidationContext, id: music.SegmentSelectorId) Error!music.SegmentSelectorId {
        try self.validateFor(context);
        return lookup(self.description.selectors, id) orelse error.MissingRequiredMapping;
    }
    /// Converts only ordered segment IDs; no partial output on missing mapping.
    /// reset_explicit still validates the supplied source IDs and selector map.
    pub fn convertHistory(self: *const MigrationMapV1, context: ValidationContext, selector: music.SegmentSelectorId, history: []const music.SegmentId, target_capacity: usize) Error!ConvertedHistory {
        try self.validateFor(context);
        if (history.len > max_history_entries or target_capacity > max_history_entries) return error.ResourceLimitExceeded;
        var result = ConvertedHistory{ .selector = lookup(self.description.selectors, selector) orelse return error.MissingRequiredMapping, .policy = self.description.history_policy };
        for (history) |id| if (!contains(context.source.segments, id)) return error.MissingSource;
        switch (self.description.history_policy) {
            .reset_explicit => {},
            .remap_exact => {
                if (history.len > target_capacity) return error.HistoryCapacityExceeded;
                for (history, 0..) |id, i| result.entries[i] = lookup(self.description.segments, id) orelse return error.MissingRequiredMapping;
                result.len = history.len;
            },
            else => return error.UnsupportedHistoryPolicy,
        }
        return result;
    }
};

fn contains(values: anytype, id: anytype) bool {
    for (values) |value| if (value == id) return true;
    return false;
}
fn lookup(entries: anytype, id: anytype) ?@TypeOf(id) {
    for (entries) |entry| if (entry.from == id) return entry.to;
    return null;
}
fn validateIds(ids: anytype) Error!void {
    if (ids.len > max_entries_per_category) return error.ResourceLimitExceeded;
    for (ids, 0..) |id, i| {
        if (!id.isValid()) return error.InvalidCatalog;
        if (contains(ids[0..i], id)) return error.InvalidCatalog;
    }
}
fn validatePairs(entries: anytype, source: anytype, target: anytype, required: anytype) Error!void {
    if (entries.len > max_entries_per_category) return error.ResourceLimitExceeded;
    try validateIds(source);
    try validateIds(target);
    try validateIds(required);
    for (entries, 0..) |entry, i| {
        if (!entry.from.isValid() or !entry.to.isValid()) return error.InvalidId;
        for (entries[0..i]) |prior| {
            if (prior.from == entry.from) return error.DuplicateSource;
            if (prior.to == entry.to) return error.DuplicateTarget;
        }
        if (!contains(source, entry.from)) return error.MissingSource;
        if (!contains(target, entry.to)) return error.MissingTarget;
    }
    // Identity entries terminate; categories never share edges. Adjacency is
    // bounded O(n^2), then iterative coloring visits each edge at most twice.
    var next: [max_entries_per_category]?usize = @splat(null);
    var colors: [max_entries_per_category]enum { fresh, visiting, done } = @splat(.fresh);
    for (entries, 0..) |entry, i| {
        if (entry.from == entry.to) continue;
        for (entries, 0..) |other, j| if (entry.to == other.from) { next[i] = j; break; };
    }
    for (entries, 0..) |_, i| {
        var cursor: ?usize = i;
        while (cursor) |index| {
            if (colors[index] == .done) break;
            if (colors[index] == .visiting) return error.MigrationCycle;
            colors[index] = .visiting;
            cursor = next[index];
        }
        cursor = i;
        while (cursor) |index| {
            if (colors[index] != .visiting) break;
            colors[index] = .done;
            cursor = next[index];
        }
    }
    for (required) |id| {
        if (!contains(source, id)) return error.MissingSource;
        if (lookup(entries, id) == null) return error.MissingRequiredMapping;
    }
}
fn validateDescription(description: Description, context: ValidationContext) Error!void {
    if (description.schema_version != version) return error.UnknownVersion;
    if (description.from_build_id == 0 or description.to_build_id == 0 or context.from_build_id == 0 or context.to_build_id == 0) return error.InvalidBuildId;
    if (description.from_build_id != context.from_build_id or description.to_build_id != context.to_build_id) return error.BuildIdMismatch;
    if (description.required_capabilities & ~(supported_capabilities & context.available_capabilities) != 0) return error.UnsupportedCapability;
    const history_bit = switch (description.history_policy) {
        .remap_exact => bit(.history_remap), .reset_explicit => bit(.history_reset), else => return error.UnsupportedHistoryPolicy,
    };
    var used = history_bit;
    if (description.states.len != 0) used |= bit(.state_map);
    if (description.segments.len != 0) used |= bit(.segment_map);
    if (description.selectors.len != 0) used |= bit(.selector_map);
    if (used & ~description.required_capabilities != 0) return error.MissingCapability;
    try validatePairs(description.states, context.source.states, context.target.states, context.required.states);
    try validatePairs(description.segments, context.source.segments, context.target.segments, context.required.segments);
    try validatePairs(description.selectors, context.source.selectors, context.target.selectors, context.required.selectors);
}
fn sort(comptime T: type, entries: []T) void {
    std.mem.sort(T, entries, {}, struct { fn less(_: void, a: T, b: T) bool { return a.from.value() < b.from.value(); } }.less);
}
fn requireSorted(entries: anytype) Error!void {
    for (entries, 0..) |entry, i| if (i != 0 and entries[i - 1].from.value() >= entry.from.value()) return error.NonCanonicalEncoding;
}
fn readPairs(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8, offset: *usize, tag: u16) Error![]T {
    if (bytes.len - offset.* < 12) return error.InvalidLength;
    const count = wire.get(bytes, offset.* + 8, u32);
    if (count > max_entries_per_category) return error.ResourceLimitExceeded;
    if (wire.get(bytes, offset.*, u16) != tag or wire.get(bytes, offset.* + 2, u16) != 16) return error.NonCanonicalEncoding;
    const len: usize = @as(usize, count) * 16;
    if (wire.get(bytes, offset.* + 4, u32) != len) return error.InvalidLength;
    offset.* += 12;
    if (bytes.len - offset.* < len) return error.InvalidLength;
    const entries = try allocator.alloc(T, count);
    errdefer allocator.free(entries);
    for (entries) |*entry| {
        entry.* = .{ .from = @enumFromInt(wire.get(bytes, offset.*, u64)), .to = @enumFromInt(wire.get(bytes, offset.* + 8, u64)) };
        offset.* += 16;
    }
    try requireSorted(entries);
    return entries;
}
