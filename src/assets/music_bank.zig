//! Owned immutable compiled MusicBank; only worker/control callers may allocate.
const std = @import("std");
pub const schema = @import("music_schema.zig");
pub const tempo_validation = @import("tempo_validation.zig");
pub const selection_validation = @import("selection_validation.zig");
/// TASK009 consumer alias only; loader invocation awaits independent slice review.
pub const transition_validation = @import("transition_validation.zig");
pub const bus_graph_adapter = @import("bus_graph_adapter.zig");
pub const music_policy_adapter = @import("music_policy_adapter.zig");
const s = schema;
pub const BankError = s.BankError;
pub const MusicBank = struct {
    allocator: std.mem.Allocator,
    metadata: s.Metadata,
    content_hash: s.Hash,
    /// Immutable typed tables. Lifetime is this generation; never free on render.
    tables: s.Tables,
    bus_graph: ?bus_graph_adapter.Owned = null,
    pub fn deinit(self: *MusicBank) void {
        if (self.bus_graph) |*graph| graph.deinit();
        inline for (std.meta.fields(s.Tables)) |field| self.allocator.free(@field(self.tables, field.name));
        self.* = undefined;
    }
    pub fn checkGeneration(self: *const MusicBank, generation: @import("music").AssetGeneration) BankError!void {
        if (generation.value() != self.metadata.generation) return error.StaleAssetGeneration;
    }
    pub fn loadNewer(allocator: std.mem.Allocator, bytes: []const u8, previous_generation: u64) !MusicBank {
        var bank = try loadBank(allocator, bytes);
        errdefer bank.deinit();
        if (bank.metadata.generation <= previous_generation) return error.StaleAssetGeneration;
        return bank;
    }
    pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !MusicBank {
        return loadBank(allocator, bytes);
    }
};

pub fn wireSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .int => |info| info.bits / 8,
        .float => |info| info.bits / 8,
        .@"enum" => |info| wireSize(info.tag_type),
        .array => |info| info.len * wireSize(info.child),
        .@"struct" => |info| blk: {
            var size: usize = 0;
            inline for (info.fields) |field| size += wireSize(field.type);
            break :blk size;
        },
        else => @compileError("wire schema must contain only fixed-width scalars, arrays and records"),
    };
}
pub fn encode(comptime T: type, value: T, bytes: []u8) void {
    switch (@typeInfo(T)) {
        .int => std.mem.writeInt(T, bytes[0..@sizeOf(T)], value, .little),
        .float => |info| encode(std.meta.Int(.unsigned, info.bits), @bitCast(value), bytes),
        .@"enum" => |info| encode(info.tag_type, @intFromEnum(value), bytes),
        .array => |info| for (value, 0..) |v, i| encode(info.child, v, bytes[i * wireSize(info.child) ..]),
        .@"struct" => |info| {
            var offset: usize = 0;
            inline for (info.fields) |field| {
                encode(field.type, @field(value, field.name), bytes[offset..]);
                offset += wireSize(field.type);
            }
        },
        else => unreachable,
    }
}
pub fn decode(comptime T: type, bytes: []const u8) BankError!T {
    if (bytes.len < wireSize(T)) return error.TruncatedBank;
    return switch (@typeInfo(T)) {
        .int => std.mem.readInt(T, bytes[0..@sizeOf(T)], .little),
        .float => |info| blk: {
            const v: T = @bitCast(try decode(std.meta.Int(.unsigned, info.bits), bytes));
            if (!std.math.isFinite(v)) return error.InvalidRecord;
            break :blk v;
        },
        .@"enum" => |info| std.enums.fromInt(T, try decode(info.tag_type, bytes)) orelse return error.InvalidRecord,
        .array => |info| blk: {
            var v: T = undefined;
            for (&v, 0..) |*entry, i| entry.* = try decode(info.child, bytes[i * wireSize(info.child) ..]);
            break :blk v;
        },
        .@"struct" => |info| blk: {
            var v: T = undefined;
            var offset: usize = 0;
            inline for (info.fields) |field| {
                @field(v, field.name) = try decode(field.type, bytes[offset..]);
                offset += wireSize(field.type);
            }
            break :blk v;
        },
        else => unreachable,
    };
}
fn add(a: u64, b: u64) BankError!u64 {
    return std.math.add(u64, a, b) catch error.ArithmeticOverflow;
}
fn mul(a: u64, b: u64) BankError!u64 {
    return std.math.mul(u64, a, b) catch error.ArithmeticOverflow;
}
fn aligned(value: u64) BankError!u64 {
    return (try add(value, 7)) & ~@as(u64, 7);
}
fn hash(bytes: []const u8) s.Hash {
    var result: s.Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
fn contentHash(bytes: []const u8) s.Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(bytes[0..s.hash_offset]);
    h.update(&s.zero_hash);
    h.update(bytes[s.hash_offset + 32 ..]);
    return h.finalResult();
}
fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    encode(T, value, bytes[offset..]);
}
fn get(comptime T: type, bytes: []const u8, offset: usize) BankError!T {
    if (offset > bytes.len) return error.TruncatedBank;
    return decode(T, bytes[offset..]);
}

pub fn build(allocator: std.mem.Allocator, ir: s.ValidatedIR) ![]u8 {
    @setEvalBranchQuota(30000);
    try validateIR(allocator, ir);
    const directory_count = s.directoryCount(ir.metadata);
    var length: u64 = s.header_bytes + directory_count * s.directory_entry_bytes;
    inline for (std.meta.fields(s.Tables), 0..) |field, i| {
        if (i < directory_count) {
            length = try aligned(length);
            length = try add(length, try mul(@field(ir.tables, field.name).len, wireSize(std.meta.Child(field.type))));
        }
    }
    if (length > s.Limits.bank_bytes or length > ir.tables.platforms[ir.metadata.profile].max_bank_bytes) return error.ResourceLimitExceeded;
    const bytes = try allocator.alloc(u8, @intCast(length));
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], s.magic);
    put(u32, bytes, 8, s.endian_marker);
    put(u16, bytes, 12, s.major);
    put(u16, bytes, 14, s.bankMinor(ir.metadata));
    put(u32, bytes, 16, s.header_bytes);
    put(u32, bytes, 20, directory_count);
    put(u64, bytes, 24, length);
    put(u64, bytes, 32, ir.metadata.required_capabilities);
    put(u64, bytes, 40, ir.metadata.optional_capabilities);
    put(u64, bytes, 48, ir.metadata.generation);
    put(u32, bytes, 56, s.sample_rate);
    put(u32, bytes, 60, ir.metadata.profile);
    put(u64, bytes, 96, s.header_bytes);
    put(u32, bytes, 104, ir.metadata.initial_state);
    var offset: u64 = s.header_bytes + directory_count * s.directory_entry_bytes;
    inline for (std.meta.fields(s.Tables), 0..) |field, index| {
        if (index < directory_count) {
            const table: s.Table = @enumFromInt(index);
            const values = @field(ir.tables, field.name);
            const T = std.meta.Child(field.type);
            offset = try aligned(offset);
            const size = wireSize(T);
            const dir = s.header_bytes + index * s.directory_entry_bytes;
            put(u16, bytes, dir, @intCast(index + 1));
            put(u16, bytes, dir + 2, 1);
            put(u32, bytes, dir + 4, @intCast(size));
            put(u64, bytes, dir + 8, offset);
            put(u64, bytes, dir + 16, @intCast(values.len * size));
            put(u32, bytes, dir + 24, @intCast(values.len));
            for (values, 0..) |value, i| encode(T, value, bytes[@as(usize, @intCast(offset)) + i * size ..]);
            offset += values.len * size;
            _ = table;
        }
    }
    @memcpy(bytes[s.hash_offset..][0..32], &contentHash(bytes));
    return bytes;
}

const Directory = struct { offset: u64 = 0, length: u64 = 0, count: u32 = 0, present: bool = false };
pub fn loadBank(allocator: std.mem.Allocator, bytes: []const u8) !MusicBank {
    @setEvalBranchQuota(30000);
    if (bytes.len < s.header_bytes) return error.TruncatedBank;
    if (!std.mem.eql(u8, bytes[0..8], s.magic)) return error.InvalidBankMagic;
    if (try get(u32, bytes, 8) != s.endian_marker) return error.InvalidEndian;
    if (try get(u16, bytes, 12) != s.major) return error.InvalidBankVersion;
    const file_minor = try get(u16, bytes, 14);
    if (try get(u32, bytes, 16) != s.header_bytes or try get(u64, bytes, 96) != s.header_bytes) return error.InvalidBankLayout;
    if (try get(u64, bytes, 24) != bytes.len) return error.TruncatedBank;
    if (bytes.len > s.Limits.bank_bytes) return error.ResourceLimitExceeded;
    const metadata: s.Metadata = .{ .required_capabilities = try get(u64, bytes, 32), .optional_capabilities = try get(u64, bytes, 40), .generation = try get(u64, bytes, 48), .profile = try get(u32, bytes, 60), .initial_state = try get(u32, bytes, 104) };
    try validateMetadata(metadata);
    if (file_minor != s.bankMinor(metadata)) return error.InvalidBankVersion;
    if (try get(u32, bytes, 56) != s.sample_rate) return error.InvalidSampleRate;
    for (bytes[108..s.header_bytes]) |b| if (b != 0) return error.InvalidBankLayout;
    const digest = contentHash(bytes);
    if (!std.mem.eql(u8, &digest, bytes[s.hash_offset..][0..32])) return error.BankHashMismatch;
    const count = try get(u32, bytes, 20);
    if (count != s.directoryCount(metadata)) return error.InvalidBankLayout;
    const directory_end = try add(s.header_bytes, try mul(count, s.directory_entry_bytes));
    if (directory_end > bytes.len) return error.TruncatedBank;
    var dirs: [s.table_count]Directory = @splat(.{});
    var last_end = directory_end;
    var last_id: u16 = 0;
    for (0..count) |i| {
        const d = s.header_bytes + i * s.directory_entry_bytes;
        const id = try get(u16, bytes, d);
        const flags = try get(u16, bytes, d + 2);
        const stride = try get(u32, bytes, d + 4);
        const offset = try get(u64, bytes, d + 8);
        const length = try get(u64, bytes, d + 16);
        const records = try get(u32, bytes, d + 24);
        if (id <= last_id) return error.DuplicateTable;
        last_id = id;
        if (try get(u32, bytes, d + 28) != 0 or flags > 1 or offset % s.alignment != 0 or offset < last_end) return error.InvalidBankLayout;
        const end = try add(offset, length);
        if (end > bytes.len) return error.TruncatedBank;
        for (bytes[@intCast(last_end)..@intCast(offset)]) |b| if (b != 0) return error.InvalidBankLayout;
        if (try mul(records, stride) != length) return error.InvalidBankLayout;
        last_end = end;
        if (id == 0 or id > s.directoryCount(metadata)) {
            if (flags != 0 or id < 0x8000) return error.UnsupportedCapability;
            continue;
        }
        const table: s.Table = @enumFromInt(id - 1);
        if (records > s.countLimit(table)) return error.ResourceLimitExceeded;
        inline for (std.meta.fields(s.Tables), 0..) |field, index| {
            if (id == index + 1 and stride != wireSize(std.meta.Child(field.type))) return error.InvalidBankLayout;
        }
        dirs[id - 1] = .{ .offset = offset, .length = length, .count = records, .present = true };
    }
    if (last_end != bytes.len) return error.InvalidBankLayout;
    for (dirs[0..s.directoryCount(metadata)]) |dir| if (!dir.present) return error.MissingRequiredTable;
    const profile_dir = dirs[@intFromEnum(s.Table.platforms)];
    if (metadata.profile >= profile_dir.count) return error.InvalidReference;
    const selected_profile = try decode(s.Platform, bytes[@as(usize, @intCast(profile_dir.offset)) + @as(usize, metadata.profile) * wireSize(s.Platform) ..]);
    if (selected_profile.max_bank_bytes == 0 or selected_profile.max_bank_bytes > s.Limits.bank_bytes or bytes.len > selected_profile.max_bank_bytes) return error.ResourceLimitExceeded;
    inline for (std.meta.fields(s.Tables), 0..) |_, i| {
        const table: s.Table = @enumFromInt(i);
        if (dirs[i].count > profileCountLimit(selected_profile, table)) return error.ResourceLimitExceeded;
    }
    var peak: u64 = try add(bytes.len, s.Limits.validation_scratch_bytes);
    inline for (std.meta.fields(s.Tables), 0..) |field, i| peak = try add(peak, try mul(dirs[i].count, @sizeOf(std.meta.Child(field.type))));
    // TASK013 new graph-only peak reservation: validation's temporary Graph is
    // destroyed before the retained one is created. Runtime preparation is a
    // separate owner and must account its own additional Graph/catalog storage.
    if (metadata.required_capabilities & s.bit(.bus_graph) != 0) {
        const graph_dir = dirs[@intFromEnum(s.Table.graph_configs)];
        if (graph_dir.count != 1) return error.InvalidMusicGraph;
        const graph_config = try decode(s.GraphConfig, bytes[@intCast(graph_dir.offset)..]);
        if (graph_config.max_state_bytes > bus_graph_adapter.bg.max_state_bytes) return error.ResourceLimitExceeded;
        peak = try add(peak, try add(graph_config.max_state_bytes, bus_graph_adapter.metadata_storage_bytes + @sizeOf(bus_graph_adapter.Owned)));
    }
    if (peak > s.Limits.loader_peak_bytes) return error.ResourceLimitExceeded;
    var tables: s.Tables = .{};
    var allocated: usize = 0;
    errdefer {
        inline for (std.meta.fields(s.Tables), 0..) |field, i| {
            if (i < allocated) allocator.free(@field(tables, field.name));
        }
    }
    inline for (std.meta.fields(s.Tables), 0..) |field, i| {
        const T = std.meta.Child(field.type);
        const dir = dirs[i];
        const values = try allocator.alloc(T, dir.count);
        @field(tables, field.name) = values;
        allocated += 1;
        for (values, 0..) |*value, j| value.* = try decode(T, bytes[@as(usize, @intCast(dir.offset)) + j * wireSize(T) ..]);
    }
    try validateIR(allocator, .{ .metadata = metadata, .tables = tables });
    const graph = try bus_graph_adapter.load(allocator, metadata, tables);
    return .{ .allocator = allocator, .metadata = metadata, .content_hash = digest, .tables = tables, .bus_graph = graph };
}
fn validateMetadata(m: s.Metadata) BankError!void {
    if (m.optional_capabilities & s.bit(.music_policy_v1) != 0) return error.InvalidCapabilityDeclaration;
    if (m.generation == 0) return error.InvalidGeneration;
    if (m.required_capabilities & ~s.full_capabilities != 0) return error.UnsupportedCapability;
    if (m.required_capabilities & s.bit(.core) == 0 or m.required_capabilities & m.optional_capabilities != 0) return error.InvalidCapabilityDeclaration;
}
fn ref(index: u32, count: usize) BankError!void {
    if (index >= count) return error.InvalidReference;
}
fn optionalRef(index: u32, count: usize) BankError!void {
    if (index != s.none) try ref(index, count);
}
fn range(r: s.Range, count: usize) BankError!void {
    if (@as(u64, r.first) + r.count > count) return error.InvalidReference;
}
fn finite(value: anytype) BankError!void {
    if (!std.math.isFinite(value)) return error.InvalidRecord;
}
fn boolean(value: u8) BankError!void {
    if (value > 1) return error.InvalidRecord;
}
fn nonzeroHash(value: s.Hash) BankError!void {
    if (std.mem.eql(u8, &value, &s.zero_hash)) return error.AudioReportMismatch;
}
fn layout(value: s.Layout, channels: u16, mask: u32) BankError!void {
    _ = @import("sme-channels").ChannelLayout.init(value, channels, mask) catch return error.InvalidRecord;
}

pub fn string(t: s.Tables, index: u32) BankError![]const u8 {
    try ref(index, t.strings.len);
    const r = t.strings[index].bytes;
    try range(r, t.string_data.len);
    return t.string_data[r.first..][0..r.count];
}
fn validateNamed(t: s.Tables, key: s.Named) BankError!void {
    const text = try string(t, key.name);
    if (text.len > s.Limits.id_bytes) return error.ResourceLimitExceeded;
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (key.id == 0 or key.id != (s.music.hashName(text) catch return error.InvalidRecord)) return error.IdCollision;
}
fn validateFinite(comptime T: type, value: T) BankError!void {
    switch (@typeInfo(T)) {
        .float => try finite(value),
        .array => |info| for (value) |v| try validateFinite(info.child, v),
        .@"struct" => |info| inline for (info.fields) |f| try validateFinite(f.type, @field(value, f.name)),
        else => {},
    }
}
pub fn validateIR(allocator: std.mem.Allocator, ir: s.ValidatedIR) (BankError || std.mem.Allocator.Error)!void {
    @setEvalBranchQuota(30000);
    const t = ir.tables;
    try validateMetadata(ir.metadata);
    try validateCapabilityDeclarations(ir.metadata, t);
    try music_policy_adapter.validate(ir.metadata, t);
    const directory_count = s.directoryCount(ir.metadata);
    var serialized_bytes: u64 = s.header_bytes + directory_count * s.directory_entry_bytes;
    inline for (std.meta.fields(s.Tables), 0..) |field, i| {
        const table: s.Table = @enumFromInt(i);
        const n = @field(t, field.name).len;
        if (n > s.countLimit(table)) return error.ResourceLimitExceeded;
        if (i < directory_count) serialized_bytes = try add(try aligned(serialized_bytes), try mul(n, wireSize(std.meta.Child(field.type))));
        if (serialized_bytes > s.Limits.bank_bytes) return error.ResourceLimitExceeded;
        if (s.mustBeNonempty(table) and ir.metadata.required_capabilities & s.requiredCapability(table) != 0 and n == 0) return error.MissingRequiredTable;
    }
    try ref(ir.metadata.profile, t.platforms.len);
    if (serialized_bytes > t.platforms[ir.metadata.profile].max_bank_bytes) return error.ResourceLimitExceeded;
    {
        const strings = try allocator.alloc(Interval, t.strings.len);
        defer allocator.free(strings);
        for (t.strings, strings) |entry, *interval| {
            const end = try add(entry.bytes.first, entry.bytes.count);
            if (end > t.string_data.len) return error.InvalidReference;
            interval.* = .{ .start = entry.bytes.first, .end = end };
        }
        std.mem.sort(Interval, strings, {}, Interval.lessThan);
        for (strings, 0..) |interval, i| if (i > 0 and interval.start < strings[i - 1].end) return error.InvalidBankLayout;
    }
    inline for (std.meta.fields(s.Tables), 0..) |field, i| {
        const table: s.Table = @enumFromInt(i);
        const entries = @field(t, field.name);
        const T = std.meta.Child(field.type);
        if (entries.len > s.countLimit(table)) return error.ResourceLimitExceeded;
        if (s.mustBeNonempty(table) and ir.metadata.required_capabilities & s.requiredCapability(table) != 0 and entries.len == 0) return error.MissingRequiredTable;
        for (entries) |entry| try validateFinite(T, entry);
        if (@typeInfo(T) == .@"struct" and @hasField(T, "key")) {
            var seen = std.AutoHashMap(u64, void).init(allocator);
            defer seen.deinit();
            for (entries) |entry| {
                try validateNamed(t, entry.key);
                const result = try seen.getOrPut(entry.key.id);
                if (result.found_existing) return error.IdCollision;
            }
        }
    }
    for (t.strings) |entry| {
        try range(entry.bytes, t.string_data.len);
        const text = t.string_data[entry.bytes.first..][0..entry.bytes.count];
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidUtf8;
    }
    try ref(ir.metadata.profile, t.platforms.len);
    try ref(ir.metadata.initial_state, t.states.len);
    const profile = t.platforms[ir.metadata.profile];
    for (t.platforms) |p| {
        if (p.resident_limit_bytes == 0 or p.resident_limit_bytes > s.Limits.blob_bytes or p.max_bank_bytes == 0 or p.max_bank_bytes > s.Limits.bank_bytes or p.max_blob_bytes == 0 or p.max_blob_bytes > s.Limits.blob_bytes or p.max_chunk_bytes == 0 or p.max_chunk_bytes > s.Limits.chunk_bytes or p.max_table_records == 0 or p.max_table_records > s.Limits.records or p.max_grid_entries == 0 or p.max_grid_entries > s.Limits.grid_entries or p.max_tempo_spans == 0 or p.max_tempo_spans > s.Limits.records or p.max_logic_instructions == 0 or p.max_logic_instructions > s.Limits.logic_instructions or p.max_logic_stack == 0 or p.max_logic_stack > s.Limits.logic_stack or p.max_planner_phases == 0 or p.max_planner_phases > s.Limits.planner_phases or p.max_planner_candidates == 0 or p.max_planner_candidates > s.Limits.planner_candidates) return error.ResourceLimitExceeded;
        try nonzeroHash(p.profile_hash);
    }
    inline for (std.meta.fields(s.Tables), 0..) |field, i| {
        const table: s.Table = @enumFromInt(i);
        const n = @field(t, field.name).len;
        const limit = profileCountLimit(profile, table);
        if (n > limit) return error.ResourceLimitExceeded;
    }
    for (t.import_policies) |p| {
        if (p.version != 1 or p.target_sample_rate != s.sample_rate or p.src_version == 0) return error.InvalidSampleRate;
        try nonzeroHash(p.policy_hash);
        try nonzeroHash(p.quality_policy_hash);
    }
    for (t.import_reports) |r| {
        try ref(r.policy, t.import_policies.len);
        try range(r.remaps, t.remaps.len);
        try validateImportRecord(allocator, r, t.import_policies[r.policy], t.remaps[r.remaps.first..][0..r.remaps.count]);
    }
    for (t.quality_reports) |r| {
        try validateQualityRecord(r);
        if (!std.mem.eql(u8, &r.profile_hash, &profile.profile_hash)) return error.AudioReportMismatch;
    }
    for (t.codecs) |c| {
        if (c.version == 0 or c.stream_count == 0 or c.coupled_count > c.stream_count) return error.InvalidRecord;
        if (c.kind == .pcm_f32le and (c.pre_skip != 0 or c.end_trim != 0 or c.channel_mapping_family != 0)) return error.InvalidRecord;
        if (c.kind == .ogg_opus and c.channel_mapping_family != 0 and c.channel_mapping_family != 1) return error.InvalidRecord;
    }
    {
        const intervals = try allocator.alloc(Interval, t.sounds.len);
        defer allocator.free(intervals);
        for (t.sounds, intervals) |sound, *interval| {
            const end = try add(sound.blob_offset, sound.blob_length);
            if (sound.blob_length == 0 or end > t.blob.len) return error.InvalidReference;
            interval.* = .{ .start = sound.blob_offset, .end = end };
        }
        std.mem.sort(Interval, intervals, {}, Interval.lessThan);
        for (intervals, 0..) |interval, i| if (i > 0 and interval.start < intervals[i - 1].end) return error.InvalidBankLayout;
    }
    var owned_chunks: u64 = 0;
    var owned_seeks: u64 = 0;
    for (t.sounds, 0..) |sound, index| {
        try ref(sound.codec, t.codecs.len);
        try ref(sound.import_report, t.import_reports.len);
        try ref(sound.quality_report, t.quality_reports.len);
        try layout(sound.layout, sound.channels, sound.channel_mask);
        if (sound.sample_rate_hz != s.sample_rate) return error.InvalidSampleRate;
        if (sound.frames == 0 or sound.blob_length == 0 or try add(sound.blob_offset, sound.blob_length) > t.blob.len) return error.InvalidReference;
        const actual = hash(t.blob[@intCast(sound.blob_offset)..][0..@intCast(sound.blob_length)]);
        if (!std.mem.eql(u8, &actual, &sound.audio_hash)) return error.AudioReportMismatch;

        const report = t.import_reports[sound.import_report];
        const quality = t.quality_reports[sound.quality_report];
        const policy = t.import_policies[report.policy];
        if (report.target_frames != sound.frames or report.channels != sound.channels or report.channel_mask != sound.channel_mask or report.layout != sound.layout or !std.mem.eql(u8, &report.normalized_hash, &sound.normalized_hash) or !std.mem.eql(u8, &quality.audio_hash, &sound.normalized_hash) or quality.stage != .normalized or quality.channels != sound.channels or quality.measurement_frames != sound.frames or quality.layout != sound.layout or quality.channel_mask != sound.channel_mask or !std.mem.eql(u8, &quality.source_hash, &report.source_hash) or !std.mem.eql(u8, &quality.policy_hash, &policy.quality_policy_hash)) return error.AudioReportMismatch;
        if (report.loop_present == 1 and (quality.loop_present != 1 or quality.loop.start != report.target_loop_start or quality.loop.end != report.target_loop_end)) return error.AudioReportMismatch;
        try range(sound.chunks, t.chunks.len);
        try range(sound.seeks, t.seeks.len);
        const codec = t.codecs[sound.codec];
        if (sound.storage == .resident) {
            if (codec.kind != .pcm_f32le or sound.blob_length != try mul(try mul(sound.frames, sound.channels), 4) or sound.chunks.count != 0 or sound.seeks.count != 0 or !std.mem.eql(u8, &sound.audio_hash, &sound.normalized_hash)) return error.InvalidStorageDecision;
            // An imported encoded source can become resident PCM. Preserve its
            // decoded-stage report, binding source-container bytes separately
            // from normalized PCM and retaining the importer codec provenance.
            if ((report.source_format == .ogg_opus) != (sound.encoded_quality_report != s.none)) return error.AudioReportMismatch;
            if (sound.encoded_quality_report != s.none) {
                try ref(sound.encoded_quality_report, t.quality_reports.len);
                const q = t.quality_reports[sound.encoded_quality_report];
                if (q.stage != .decoded_encoded or q.encoded_hash_present != 1 or !std.mem.eql(u8, &q.encoded_hash, &report.source_hash) or !std.mem.eql(u8, &q.audio_hash, &sound.normalized_hash) or !std.mem.eql(u8, &q.source_hash, &report.source_hash) or !std.mem.eql(u8, &q.policy_hash, &policy.quality_policy_hash) or !std.mem.eql(u8, &q.effective_policy_hash, &quality.effective_policy_hash) or q.channels != sound.channels or q.measurement_frames != sound.frames or q.layout != sound.layout or q.channel_mask != sound.channel_mask or q.loop_present != quality.loop_present or !std.meta.eql(q.loop, quality.loop)) return error.AudioReportMismatch;
            }
            var pos: usize = @intCast(sound.blob_offset);
            while (pos < sound.blob_offset + sound.blob_length) : (pos += 4) {
                const sample = try decode(f32, t.blob[pos..]);
                if (@abs(sample) > 1) return error.AudioQualityGateFailed;
            }
        } else {
            if (ir.metadata.required_capabilities & s.bit(.streaming) == 0 or codec.kind != .ogg_opus or sound.chunks.count == 0 or sound.seeks.count == 0) return error.InvalidStorageDecision;
            try ref(sound.encoded_quality_report, t.quality_reports.len);
            const q = t.quality_reports[sound.encoded_quality_report];
            if (q.stage != .decoded_encoded or q.encoded_hash_present != 1 or !std.mem.eql(u8, &q.encoded_hash, &actual) or !std.mem.eql(u8, &q.source_hash, &report.source_hash) or !std.mem.eql(u8, &q.policy_hash, &policy.quality_policy_hash) or !std.mem.eql(u8, &q.effective_policy_hash, &quality.effective_policy_hash) or q.channels != sound.channels or q.measurement_frames != sound.frames or q.layout != sound.layout or q.channel_mask != sound.channel_mask or q.loop_present != quality.loop_present or !std.meta.eql(q.loop, quality.loop)) return error.AudioReportMismatch;
            owned_chunks = try add(owned_chunks, sound.chunks.count);
            owned_seeks = try add(owned_seeks, sound.seeks.count);
            var chunk_byte: u64 = 0;
            var chunk_frame: u64 = 0;
            for (t.chunks[sound.chunks.first..][0..sound.chunks.count]) |c| {
                if (c.sound != index or c.byte_offset != chunk_byte or c.first_frame != chunk_frame) return error.InvalidReference;
                chunk_byte = try add(chunk_byte, c.byte_length);
                chunk_frame = try add(chunk_frame, c.frame_count);
            }
            if (chunk_byte != sound.blob_length or chunk_frame != sound.frames) return error.InvalidReference;
            var previous: u64 = 0;
            for (t.seeks[sound.seeks.first..][0..sound.seeks.count], 0..) |seek, i| {
                if (seek.sound != index or seek.logical_frame >= sound.frames or (i == 0 and seek.logical_frame != 0) or (i > 0 and seek.logical_frame <= previous) or seek.logical_frame - previous > 48000) return error.InvalidSeekIndex;
                previous = seek.logical_frame;
            }
            if (sound.frames - previous > 48000) return error.InvalidSeekIndex;
        }
    }
    // Prevent orphan descriptors from repeatedly hashing the same large payload.
    // Ranges owned by different sounds cannot overlap because each entry's sound
    // index was checked above; exact summed counts therefore prove full coverage.
    if (owned_chunks != t.chunks.len or owned_seeks != t.seeks.len) return error.InvalidReference;
    for (t.chunks) |chunk| {
        try ref(chunk.sound, t.sounds.len);
        const sound = t.sounds[chunk.sound];
        if (sound.storage != .streaming or chunk.byte_length == 0 or chunk.byte_length > profile.max_chunk_bytes or try add(chunk.byte_offset, chunk.byte_length) > sound.blob_length or chunk.frame_count == 0 or try add(chunk.first_frame, chunk.frame_count) > sound.frames) return error.InvalidReference;
        const start = try add(sound.blob_offset, chunk.byte_offset);
        const digest = hash(t.blob[@intCast(start)..][0..@intCast(chunk.byte_length)]);
        if (!std.mem.eql(u8, &digest, &chunk.hash)) return error.AudioReportMismatch;
    }
    for (t.seeks) |seek| {
        try ref(seek.sound, t.sounds.len);
        const sound = t.sounds[seek.sound];
        if (sound.storage != .streaming or seek.logical_frame >= sound.frames or seek.page_byte_offset >= sound.blob_length or seek.packet_byte_offset >= sound.blob_length or seek.recovery_byte_offset > seek.packet_byte_offset or seek.link_id != 0 or seek.granule_position < seek.logical_frame) return error.InvalidSeekIndex;
    }
    try validateMusic(allocator, t, profile);
    try bus_graph_adapter.validate(allocator, ir.metadata, t);
}
fn validateMusic(allocator: std.mem.Allocator, t: s.Tables, p: s.Platform) (BankError || std.mem.Allocator.Error)!void {
    for (t.states) |v| {
        try ref(v.theme, t.themes.len);
        try ref(v.selector, t.selectors.len);
        try boolean(v.required);
    }
    for (t.parameters) |v| if (v.minimum > v.maximum or v.initial < v.minimum or v.initial > v.maximum) return error.InvalidRecord;
    for (t.contexts) |v| if (v.kind == .boolean and v.initial_integer != 0 and v.initial_integer != 1) return error.InvalidRecord;
    for (t.themes, 0..) |v, i| {
        try ref(v.initial_segment, t.segments.len);
        if (t.segments[v.initial_segment].theme != i) return error.InvalidReference;
    }
    for (t.segments, 0..) |v, index| {
        try ref(v.theme, t.themes.len);
        try ref(v.tempo, t.tempos.len);
        try optionalRef(v.fallback_segment, t.segments.len);
        try range(v.layers, t.layers.len);
        try range(v.cues, t.cues.len);
        try boolean(v.emergency);
        if (v.frames == 0 or v.loop_start >= v.loop_end or v.loop_end > v.frames or v.layers.count == 0 or v.cues.count == 0 or t.tempos[v.tempo].total_frames != v.frames) return error.InvalidMusicGraph;
        var decoded: u64 = 0;
        var required: u32 = 0;
        var first_sound: ?s.Sound = null;
        for (t.layers[v.layers.first..][0..v.layers.count]) |layer| {
            if (layer.segment != index) return error.InvalidReference;
            try ref(layer.sound, t.sounds.len);
            const sound = t.sounds[layer.sound];
            if (first_sound) |first| {
                if (sound.channels != first.channels or sound.layout != first.layout or sound.channel_mask != first.channel_mask) return error.MisalignedStems;
            } else first_sound = sound;
            if (layer.source_start != 0 or sound.frames != v.frames or sound.storage != v.storage) return error.MisalignedStems;
            decoded = try add(decoded, try mul(try mul(sound.frames, sound.channels), 4));
            required += layer.required;
        }
        if (required == 0) return error.InvalidMusicGraph;
        if (decoded != v.decoded_bytes) return error.InvalidStorageDecision;
        if (v.emergency == 1 and (decoded > p.resident_limit_bytes or v.storage != .resident)) return error.EmergencyMustBeResident;
        if (decoded > p.resident_limit_bytes and v.storage != .streaming) return error.InvalidStorageDecision;
        for (t.cues[v.cues.first..][0..v.cues.count]) |cue| if (cue.segment != index) return error.InvalidReference;
    }
    for (t.selectors) |v| {
        try range(v.candidates, t.candidates.len);
        try optionalRef(v.fallback_segment, t.segments.len);
        // TASK-008 owns typed pool/exhaustion semantics; retain the selected
        // platform's tighter planner-candidate capacity at the bank boundary.
        if (v.candidates.count > p.max_planner_candidates) return error.ResourceLimitExceeded;
    }
    for (t.candidates) |v| {
        try ref(v.segment, t.segments.len);
        try optionalRef(v.condition, t.logic.len);
    }
    for (t.layers) |v| {
        try ref(v.segment, t.segments.len);
        try ref(v.sound, t.sounds.len);
        try ref(v.bus, t.buses.len);
        try optionalRef(v.gain_curve, t.curves.len);
        try boolean(v.required);
        const sound = t.sounds[v.sound];
        const bus = t.buses[v.bus];
        if (sound.layout != bus.layout or sound.channel_mask != bus.channel_mask) return error.UnsupportedOperation;
    }
    var transition_keys = std.AutoHashMap(TransitionKey, void).init(allocator);
    defer transition_keys.deinit();
    for (t.transitions) |v| {
        try ref(v.from, t.states.len);
        try ref(v.to, t.states.len);
        try ref(v.selector, t.selectors.len);
        try optionalRef(v.condition, t.logic.len);
        try optionalRef(v.fill, t.fills.len);
        try optionalRef(v.fallback_segment, t.segments.len);
        try ref(v.source_exit, t.cues.len);
        try ref(v.target_entry, t.cues.len);
        if (!isExit(t.cues[v.source_exit].kind) or !isEntry(t.cues[v.target_entry].kind) or (v.fallback == .segment) != (v.fallback_segment != s.none)) return error.InvalidMusicGraph;
        const duplicate = try transition_keys.getOrPut(.{ .from = v.from, .to = v.to, .priority = v.priority, .specificity = v.specificity, .authored_order = v.authored_order });
        if (duplicate.found_existing) return error.InvalidMusicGraph;
    }
    const grid_entries = @as(u64, t.beats.len) + t.bars.len + t.tempo_tick_frames.len;
    if (grid_entries > p.max_grid_entries or grid_entries > s.Limits.grid_entries) return error.ResourceLimitExceeded;
    for (t.tempos) |v| try tempo_validation.validate(t, p, v);
    for (t.tempo_spans) |v| {
        if (v.start_tick >= v.end_tick or v.start_frame > v.end_frame or v.start_milli_bpm < 1000 or v.start_milli_bpm > 1_000_000 or v.end_milli_bpm < 1000 or v.end_milli_bpm > 1_000_000 or (v.curve == .constant and v.start_milli_bpm != v.end_milli_bpm) or v.numerator == 0 or v.numerator > 32 or v.denominator == 0 or v.denominator > 32 or !std.math.isPowerOfTwo(v.denominator)) return error.InvalidTempo;
        try range(v.groups, t.beat_groups.len);
        if (v.groups.count == 0) return error.InvalidTempo;
        var sum: u32 = 0;
        for (t.beat_groups[v.groups.first..][0..v.groups.count]) |n| {
            if (n == 0) return error.InvalidTempo;
            sum += n;
        }
        if (sum != v.numerator) return error.InvalidTempo;
    }
    for (t.cues) |v| {
        try ref(v.segment, t.segments.len);
        const segment = t.segments[v.segment];
        if (v.frame > segment.frames or v.tick > t.tempos[segment.tempo].total_ticks) return error.InvalidReference;
        // Tempo tables were deeply validated above; cues must use that same
        // authoritative integer query rather than only fitting the segment.
        try tempo_validation.validateCue(t, t.tempos[segment.tempo], v);
    }
    for (t.fills) |v| {
        try ref(v.source_exit, t.cues.len);
        try ref(v.target_entry, t.cues.len);
        try range(v.steps, t.fill_steps.len);
        if (v.steps.count > p.max_planner_phases or !isExit(t.cues[v.source_exit].kind) or !isEntry(t.cues[v.target_entry].kind)) return error.InvalidMusicGraph;
    }
    for (t.fill_steps) |v| {
        try ref(v.segment, t.segments.len);
        try ref(v.entry, t.cues.len);
        try ref(v.exit, t.cues.len);
        if (t.cues[v.entry].segment != v.segment or t.cues[v.exit].segment != v.segment or !isEntry(t.cues[v.entry].kind) or !isExit(t.cues[v.exit].kind) or t.cues[v.exit].frame <= t.cues[v.entry].frame) return error.InvalidMusicGraph;
    }
    for (t.stingers) |v| {
        try ref(v.segment, t.segments.len);
        try ref(v.cue, t.cues.len);
        try optionalRef(v.duck_preset, t.sidechains.len);
        try boolean(v.protected);
        if (t.cues[v.cue].segment != v.segment) return error.InvalidReference;
    }
    // Every flat record is validated, including records outside owner ranges.
    // Ownership ranges may share data, but cannot hide a malformed reference.
    for (t.beats) |entry| try ref(entry.span, t.tempo_spans.len);
    for (t.bars) |entry| try ref(entry.span, t.tempo_spans.len);
    for (t.beat_groups) |group| if (group == 0 or group > 32) return error.InvalidTempo;
    // New typed logic/selection admission validates all flat operands and
    // references, including records outside owner ranges, then stack/pools.
    try selection_validation.validate(allocator, t, p);
    for (t.curves) |v| {
        try range(v.points, t.curve_points.len);
        if (v.points.count == 0) return error.InvalidRecord;
        var prev: ?f64 = null;
        for (t.curve_points[v.points.first..][0..v.points.count]) |point| {
            if (prev) |x| if (point.position <= x) return error.InvalidRecord;
            prev = point.position;
        }
    }
    for (t.buses, 0..) |v, i| {
        try optionalRef(v.parent, t.buses.len);
        try range(v.sends, t.bus_sends.len);
        try layout(v.layout, @intCast(@popCount(v.channel_mask)), v.channel_mask);
        // Parent/send edges must reference earlier buses: explicit topological order.
        if (v.parent != s.none and v.parent >= i) return error.InvalidMusicGraph;
        if (v.parent != s.none and (t.buses[v.parent].layout != v.layout or t.buses[v.parent].channel_mask != v.channel_mask)) return error.UnsupportedOperation;
        for (t.bus_sends[v.sends.first..][0..v.sends.count]) |send| {
            if (send.target >= i) return error.InvalidMusicGraph;
            if (t.buses[send.target].layout != v.layout or t.buses[send.target].channel_mask != v.channel_mask) return error.UnsupportedOperation;
        }
    }
    for (t.bus_sends) |v| try ref(v.target, t.buses.len);
    for (t.sidechains) |v| {
        try ref(v.source_bus, t.buses.len);
        try ref(v.target_bus, t.buses.len);
        if (v.source_bus == v.target_bus or v.ratio < 1 or v.window_frames == 0 or v.max_attenuation_db < 0) return error.InvalidRecord;
    }
    for (t.acoustic_profiles) |v| {
        try ref(v.parameter, t.parameters.len);
        try ref(v.mapping_curve, t.curves.len);
        if (v.minimum > v.maximum) return error.InvalidRecord;
    }
}
fn isEntry(kind: s.CueKind) bool {
    return kind == .entry or kind == .both or kind == .fill_entry;
}
fn isExit(kind: s.CueKind) bool {
    return kind == .exit or kind == .both or kind == .fill_exit;
}
fn validateGrid(grid: []const s.Grid, tempo: s.Tempo, spans: usize) BankError!void {
    var previous: ?s.Grid = null;
    for (grid) |v| {
        try ref(v.span, spans);
        if (v.tick > tempo.total_ticks or v.frame > tempo.total_frames or v.span < tempo.spans.first or v.span >= tempo.spans.first + tempo.spans.count) return error.InvalidTempo;
        if (previous) |old| {
            if (v.tick <= old.tick or v.frame <= old.frame or v.ordinal <= old.ordinal) return error.InvalidTempo;
        }
        previous = v;
    }
}

const Interval = struct {
    start: u64,
    end: u64,
    fn lessThan(_: void, a: Interval, b: Interval) bool {
        return a.start < b.start;
    }
};
const TransitionKey = struct { from: u32, to: u32, priority: u8, specificity: u16, authored_order: u32 };

fn profileCountLimit(profile: s.Platform, table: s.Table) u64 {
    return switch (table) {
        .blob => profile.max_blob_bytes,
        .string_data => s.Limits.string_bytes,
        .beats, .bars, .anchors, .tempo_tick_frames => profile.max_grid_entries,
        .tempo_spans, .tempo_meters, .tempo_queries => profile.max_tempo_spans,
        .instructions => @as(u64, profile.max_table_records) * profile.max_logic_instructions,
        else => profile.max_table_records,
    };
}

fn remapFrame(frame: u64, source_rate: u32) BankError!u64 {
    if (source_rate == 0) return error.InvalidSampleRate;
    const numerator: u128 = @as(u128, frame) * s.sample_rate;
    var quotient = numerator / source_rate;
    const remainder = numerator % source_rate;
    if (remainder * 2 > source_rate or (remainder * 2 == source_rate and quotient % 2 == 1)) quotient += 1;
    if (quotient > std.math.maxInt(u64)) return error.ArithmeticOverflow;
    return @intCast(quotient);
}

/// Validate only the fixed-width quality record, without scanning PCM or running
/// the whole-bank validator. This is also used at the compiler mapping boundary.
/// Source/encoded hash authenticity is bound by the media producer and sound
/// checks; a quality record is evidence, not a cryptographic proof of a scan.
pub fn validateQualityRecord(r: s.AudioQualityReportV1) BankError!void {
    @setFloatMode(.strict);
    try validateFinite(s.AudioQualityReportV1, r);
    try boolean(r.peak_silence);
    try boolean(r.encoded_hash_present);
    try boolean(r.loop_present);
    try layout(r.layout, r.channels, r.channel_mask);
    if (r.version != 1 or r.algorithm_version != 2 or r.sample_rate_hz != s.sample_rate or r.measurement_frames == 0 or r.measurement_frames > 2_073_600_000) return error.AudioReportMismatch;
    if (r.true_peak_oversample != 4 or r.loop_minimum_support_frames != 64 or r.loudness_window_frames != 19_200 or r.loudness_hop_frames != 4_800 or r.absolute_gate_lufs != -70 or r.relative_gate_lu != -10) return error.AudioReportMismatch;
    try validateQualityPolicy(r.policy);
    try nonzeroHash(r.source_hash);
    try nonzeroHash(r.audio_hash);
    try nonzeroHash(r.policy_hash);
    if (!std.mem.eql(u8, &r.effective_policy_hash, &(try qualityPolicyHash(r.policy)))) return error.AudioReportMismatch;
    if (r.encoded_hash_present == 1) {
        try nonzeroHash(r.encoded_hash);
    } else if (r.stage == .decoded_encoded or !std.mem.eql(u8, &r.encoded_hash, &s.zero_hash)) return error.AudioReportMismatch;
    if (r.completed_measurements & ~@as(u32, 0x3f) != 0 or (r.warnings | r.failures) & ~@as(u32, 0x1ff) != 0) return error.AudioReportMismatch;
    var required = r.policy.required_measurements | @as(u32, 0x1f);
    if (r.policy.require_loop == 1) required |= 0x20;
    if (r.completed_measurements & required != required) return error.MissingRequiredPass;
    if (r.loop_present == 1) {
        if (r.loop.start >= r.loop.end or r.loop.end > r.measurement_frames) return error.AudioReportMismatch;
    } else if (!std.meta.eql(r.loop, s.QualityLoopRangeV1{})) return error.AudioReportMismatch;
    const loop_window: u32 = if (r.loop_present == 1) @intCast(@min(r.policy.loop_window_frames, (r.loop.end - r.loop.start) / 2)) else 0;
    const loop_measured = r.loop_present == 1 and loop_window >= r.loop_minimum_support_frames;
    const actual_measurements: u32 = 0x1f | (if (loop_measured) @as(u32, 0x20) else 0);
    if (r.completed_measurements != actual_measurements) return error.AudioReportMismatch;
    var expected: QualityIssues = .{};
    var sample_peak: f64 = 0;
    var true_peak: f64 = 0;
    var mean_square: f64 = 0;
    var has_loudness_input = false;
    // Each float32 sample and its square are exactly representable in f64.
    // Sequential sums then have gamma_n relative error; allow both the energy
    // and signed-mean chains plus division/sqrt rounding, never policy slack.
    const n_eps = (@as(f64, @floatFromInt(r.measurement_frames)) + 4) * std.math.floatEps(f64);
    const statistics_gamma = 2 * n_eps / (1 - n_eps);
    var next_bit: u5 = 0;
    for (r.channel, 0..) |ch, index| {
        if (index >= r.channels) {
            if (!std.meta.eql(ch, s.QualityChannelV1{})) return error.AudioReportMismatch;
            continue;
        }
        while (r.channel_mask & (@as(u32, 1) << next_bit) == 0) next_bit += 1;
        try validateQualitySpeaker(ch.speaker, r.layout, next_bit);
        next_bit += 1;
        const statistics_tolerance = @max(ch.sample_peak, ch.rms) * statistics_gamma;
        if (ch.sample_peak < 0 or ch.sample_peak > 1 or ch.true_peak < ch.sample_peak or ch.rms < 0 or ch.rms > ch.sample_peak + statistics_tolerance or @abs(ch.dc) > ch.rms + statistics_tolerance) return error.AudioReportMismatch;
        sample_peak = @max(sample_peak, ch.sample_peak);
        true_peak = @max(true_peak, ch.true_peak);
        mean_square += ch.rms * ch.rms;
        has_loudness_input = has_loudness_input or (ch.speaker.loudness_weight > 0 and ch.sample_peak > 0);
        if (@abs(ch.dc) > r.policy.dc_absolute_maximum) expected.add(0, r.policy.dc_severity);
        try validateQualityLoop(ch.loop, r, loop_window);
        if (r.loop_present == 1) {
            if (!loop_measured) {
                expected.add(6, if (r.policy.require_loop == 1 or r.policy.loop_severity == .fail or r.policy.required_measurements & 0x20 != 0) .fail else .warn);
            } else {
                if (@max(0, @abs(ch.loop.seam_delta) - ch.loop.local_max_difference) > r.policy.loop_seam_excess_maximum) expected.add(1, r.policy.loop_severity);
                if (@max(0, @max(@abs(ch.loop.seam_delta - ch.loop.difference_before), @abs(ch.loop.difference_after - ch.loop.seam_delta)) - ch.loop.local_max_slope_change) > r.policy.loop_slope_excess_maximum) expected.add(2, r.policy.loop_severity);
                if (ch.loop.dc_anomaly == 1) expected.add(3, r.policy.loop_severity);
            }
        }
    }
    if (r.rms < 0 or r.rms > sample_peak * (1 + statistics_gamma) or r.sample_peak != sample_peak or r.true_peak != true_peak or !qualityNear(r.rms, @sqrt(mean_square / @as(f64, @floatFromInt(r.channels))))) return error.AudioReportMismatch;
    if (r.peak_silence != @intFromBool(sample_peak == 0)) return error.AudioReportMismatch;
    if (r.peak_silence == 1) {
        if (r.true_peak != 0 or r.rms != 0 or r.sample_peak_dbfs != 0 or r.true_peak_dbtp != 0) return error.AudioReportMismatch;
    } else {
        if (!qualityNear(r.sample_peak_dbfs, 20 * @log10(sample_peak)) or !qualityNear(r.true_peak_dbtp, 20 * @log10(true_peak))) return error.AudioReportMismatch;
        if (r.stage == .decoded_encoded and true_peak > 1) expected.add(5, .fail) else if (r.stage == .normalized and 20 * @log10(true_peak) > r.policy.normalized_true_peak_maximum_dbtp) expected.add(5, r.policy.normalized_true_peak_severity);
    }
    const bins = r.measurement_frames / r.loudness_hop_frames;
    const blocks = if (bins >= 4) bins - 3 else 0;
    if (r.loudness_blocks != blocks or r.relative_gated_blocks > r.absolute_gated_blocks or r.absolute_gated_blocks > blocks) return error.AudioReportMismatch;
    if (!has_loudness_input and r.loudness_state == .measured) return error.AudioReportMismatch;
    switch (r.loudness_state) {
        .insufficient_duration => if (blocks != 0 or r.absolute_gated_blocks != 0 or r.relative_gated_blocks != 0 or r.integrated_lufs != 0 or r.measured_relative_gate_lufs != 0) return error.AudioReportMismatch,
        .silence => if (blocks == 0 or r.absolute_gated_blocks != 0 or r.relative_gated_blocks != 0 or r.integrated_lufs != 0 or r.measured_relative_gate_lufs != 0) return error.AudioReportMismatch,
        .measured => if (blocks == 0 or r.relative_gated_blocks == 0 or r.integrated_lufs <= r.absolute_gate_lufs or r.integrated_lufs <= r.measured_relative_gate_lufs) return error.AudioReportMismatch,
    }
    if (r.policy.lufs_range_present == 1) {
        if (r.loudness_state != .measured) {
            expected.add(7, if (r.policy.require_lufs_range == 1 or r.policy.lufs_severity == .fail) .fail else r.policy.lufs_severity);
        } else if (r.integrated_lufs < r.policy.lufs_range.minimum or r.integrated_lufs > r.policy.lufs_range.maximum) expected.add(4, if (r.policy.require_lufs_range == 1) .fail else r.policy.lufs_severity);
    }
    if (expected.failures != 0 or r.failures != 0 or r.verdict == .fail) return error.AudioQualityGateFailed;
    const verdict: s.Verdict = if (expected.warnings != 0) .warn else .pass;
    if (r.warnings != expected.warnings or r.verdict != verdict) return error.AudioReportMismatch;
}
const QualityIssues = struct {
    warnings: u32 = 0,
    failures: u32 = 0,
    fn add(self: *QualityIssues, bit_index: u5, severity: s.QualitySeverity) void {
        const flag = @as(u32, 1) << bit_index;
        switch (severity) {
            .report_only => {},
            .warn => self.warnings |= flag,
            .fail => self.failures |= flag,
        }
    }
};
fn qualityNear(a: f64, b: f64) bool {
    return @abs(a - b) <= 1e-12 * @max(1, @max(@abs(a), @abs(b)));
}
fn validateQualityPolicy(p: s.QualityPolicyRecordV1) BankError!void {
    try boolean(p.require_loop);
    try boolean(p.lufs_range_present);
    try boolean(p.require_lufs_range);
    if (p.version != 1 or p.loop_window_frames == 0 or p.loop_window_frames > 48_000 or p.required_measurements & ~@as(u32, 0x3f) != 0) return error.AudioReportMismatch;
    for ([_]f64{ p.dc_absolute_maximum, p.loop_seam_excess_maximum, p.loop_slope_excess_maximum, p.loop_dc_difference_maximum }) |v| if (v < 0 or v > 4) return error.AudioReportMismatch;
    if (p.normalized_true_peak_maximum_dbtp > 0 or p.normalized_true_peak_maximum_dbtp < -200) return error.AudioReportMismatch;
    if (p.lufs_range_present == 1) {
        if (p.lufs_range.minimum > p.lufs_range.maximum or p.lufs_range.minimum < -200 or p.lufs_range.maximum > 100) return error.AudioReportMismatch;
    } else if (p.require_lufs_range != 0 or p.lufs_severity != .report_only or !std.meta.eql(p.lufs_range, s.QualityRangeV1{})) return error.AudioReportMismatch;
}
/// Match scanner policy JSON field order/types exactly, including bool/null,
/// without importing the offline scanner into the runtime or allocating memory.
fn qualityPolicyHash(p: s.QualityPolicyRecordV1) BankError!s.Hash {
    const PolicyJson = struct {
        version: u32,
        dc_absolute_maximum: f64,
        dc_severity: s.QualitySeverity,
        normalized_true_peak_maximum_dbtp: f64,
        normalized_true_peak_severity: s.QualitySeverity,
        loop_window_frames: u32,
        loop_seam_excess_maximum: f64,
        loop_slope_excess_maximum: f64,
        loop_dc_difference_maximum: f64,
        loop_severity: s.QualitySeverity,
        require_loop: bool,
        lufs_range: ?s.QualityRangeV1,
        lufs_severity: s.QualitySeverity,
        require_lufs_range: bool,
        required_measurements: u32,
    };
    const policy: PolicyJson = .{
        .version = p.version,
        .dc_absolute_maximum = p.dc_absolute_maximum,
        .dc_severity = p.dc_severity,
        .normalized_true_peak_maximum_dbtp = p.normalized_true_peak_maximum_dbtp,
        .normalized_true_peak_severity = p.normalized_true_peak_severity,
        .loop_window_frames = p.loop_window_frames,
        .loop_seam_excess_maximum = p.loop_seam_excess_maximum,
        .loop_slope_excess_maximum = p.loop_slope_excess_maximum,
        .loop_dc_difference_maximum = p.loop_dc_difference_maximum,
        .loop_severity = p.loop_severity,
        .require_loop = p.require_loop == 1,
        .lufs_range = if (p.lufs_range_present == 1) p.lufs_range else null,
        .lufs_severity = p.lufs_severity,
        .require_lufs_range = p.require_lufs_range == 1,
        .required_measurements = p.required_measurements,
    };
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(policy, .{}, &writer) catch return error.AudioReportMismatch;
    return hash(writer.buffered());
}
fn validateQualitySpeaker(speaker: s.QualitySpeakerV1, channel_layout: s.Layout, bit_index: u5) BankError!void {
    try boolean(speaker.lfe);
    const azimuth = [_]i16{ 30, -30, 0, 0, 135, -135, 15, -15, 180, 90, -90, 0, 30, 0, -30, 135, 180, -135 };
    var az = azimuth[bit_index];
    if (channel_layout == .surround_5_1 and (bit_index == 4 or bit_index == 5)) az = if (bit_index == 4) 110 else -110;
    const elevation: i16 = if (bit_index == 11) 90 else if (bit_index >= 12) 45 else 0;
    const lfe = bit_index == 3;
    const weight: f64 = if (lfe) 0 else if (elevation == 0 and @abs(az) >= 60 and @abs(az) <= 120) 1.41 else 1;
    if (speaker.mask_bit != @as(u32, 1) << bit_index or speaker.azimuth_degrees != az or speaker.elevation_degrees != elevation or speaker.lfe != @intFromBool(lfe) or speaker.loudness_weight != weight) return error.AudioReportMismatch;
}
fn validateQualityLoop(m: s.QualityLoopMetricsV1, r: s.AudioQualityReportV1, window: u32) BankError!void {
    try boolean(m.dc_anomaly);
    if (r.loop_present == 0) {
        if (!std.meta.eql(m, s.QualityLoopMetricsV1{})) return error.AudioReportMismatch;
        return;
    }
    const state: s.QualityLoopState = if (window >= r.loop_minimum_support_frames) .measured else .insufficient_duration;
    if (m.state != state or m.window_frames != window) return error.AudioReportMismatch;
    for ([_]f64{ m.seam_delta, m.difference_before, m.difference_after }) |v| if (@abs(v) > 2) return error.AudioReportMismatch;
    for ([_]f64{ m.slope_change_before, m.slope_change_after }) |v| if (@abs(v) > 4) return error.AudioReportMismatch;
    if (@abs(m.dc_before) > 1 or @abs(m.dc_after) > 1 or m.dc_difference < 0 or m.dc_difference > 2 or m.local_max_difference < 0 or m.local_max_difference > 2 or m.local_max_slope_change < 0 or m.local_max_slope_change > 4 or m.seam_excess < 0 or m.slope_excess < 0) return error.AudioReportMismatch;
    if (!qualityNear(m.dc_difference, @abs(m.dc_after - m.dc_before)) or !qualityNear(m.seam_excess, @max(0, @abs(m.seam_delta) - m.local_max_difference)) or !qualityNear(m.slope_excess, @max(0, @max(@abs(m.slope_change_before), @abs(m.slope_change_after)) - m.local_max_slope_change))) return error.AudioReportMismatch;
    if (r.loop.end - r.loop.start >= 2) {
        if (!qualityNear(m.slope_change_before, m.seam_delta - m.difference_before) or !qualityNear(m.slope_change_after, m.difference_after - m.seam_delta)) return error.AudioReportMismatch;
    } else if (m.seam_delta != 0 or m.difference_before != 0 or m.difference_after != 0 or m.slope_change_before != 0 or m.slope_change_after != 0) return error.AudioReportMismatch;
    if (window == 0 and (m.dc_before != 0 or m.dc_after != 0)) return error.AudioReportMismatch;
    if (window >= 2 and m.local_max_difference < @max(@abs(m.difference_before), @abs(m.difference_after))) return error.AudioReportMismatch;
    if (window < 2 and m.local_max_difference != 0) return error.AudioReportMismatch;
    if (window < 3 and m.local_max_slope_change != 0) return error.AudioReportMismatch;
    const seam_excess = @max(0, @abs(m.seam_delta) - m.local_max_difference);
    const slope_excess = @max(0, @max(@abs(m.seam_delta - m.difference_before), @abs(m.difference_after - m.seam_delta)) - m.local_max_slope_change);
    const dc_anomaly = state == .measured and @abs(m.dc_after - m.dc_before) > r.policy.loop_dc_difference_maximum and (seam_excess > r.policy.loop_seam_excess_maximum or slope_excess > r.policy.loop_slope_excess_maximum);
    if (m.dc_anomaly != @intFromBool(dc_anomaly)) return error.AudioReportMismatch;
}

/// Populated capability-owned tables cannot be disguised by downgraded metadata.
/// Applicable to source ASTs as well; derived/required table presence is checked
/// separately once media/domain passes have produced complete IR.
pub fn validateCapabilityDeclarations(metadata: s.Metadata, tables: s.Tables) BankError!void {
    // Stereo is multichannel too: every layout with >1 channel requires this bit.
    if (metadata.required_capabilities & s.bit(.multichannel) == 0) {
        for (tables.sounds) |sound| if (sound.channels > 1) return error.InvalidCapabilityDeclaration;
        for (tables.buses) |bus| if (@popCount(bus.channel_mask) > 1) return error.InvalidCapabilityDeclaration;
    }
    inline for (std.meta.fields(s.Tables), 0..) |field, index| {
        const table: s.Table = @enumFromInt(index);
        if (@field(tables, field.name).len != 0 and metadata.required_capabilities & s.requiredCapability(table) == 0) return error.InvalidCapabilityDeclaration;
    }
}

/// Narrow offline provenance validation, also callable by the media compiler.
/// No source paths or runtime filesystem access are retained.
pub fn validateImportRecord(allocator: std.mem.Allocator, r: s.AudioImportReportV1, p: s.AudioImportPolicyV1, remaps: []const s.Remap) (BankError || std.mem.Allocator.Error)!void {
    if (remaps.len > s.Limits.records) return error.ResourceLimitExceeded;
    if (r.version != 1 or r.target_sample_rate != s.sample_rate or r.source_sample_rate < 8_000 or r.source_sample_rate > 192_000 or r.source_frames == 0 or r.target_frames == 0) return error.InvalidSampleRate;
    try layout(r.layout, r.channels, r.channel_mask);
    try boolean(r.bypass);
    try boolean(r.opus_input_rate_hint_present);
    try boolean(r.loop_present);
    if (r.bypass != @intFromBool(r.source_sample_rate == s.sample_rate)) return error.AudioReportMismatch;
    if (r.source_format == .ogg_opus) {
        if (r.source_sample_rate != s.sample_rate or r.opus_input_rate_hint_present != 1) return error.AudioReportMismatch;
    } else if (r.opus_input_rate_hint_present != 0 or r.opus_input_rate_hint != 0) return error.AudioReportMismatch;
    if (r.verdict == .fail or r.src_algorithm != p.src_algorithm or r.src_version != p.src_version or !std.mem.eql(u8, &r.coefficients_hash, &p.coefficients_hash)) return error.AudioReportMismatch;
    try nonzeroHash(r.source_hash);
    try nonzeroHash(r.normalized_hash);
    if (r.target_frames != try remapFrame(r.source_frames, r.source_sample_rate)) return error.AudioReportMismatch;
    if (r.bypass == 0 and (r.src_algorithm == 0 or std.mem.eql(u8, &r.coefficients_hash, &s.zero_hash))) return error.AudioReportMismatch;
    if (r.loop_present == 1) {
        if (r.source_loop_start >= r.source_loop_end or r.source_loop_end > r.source_frames or r.target_loop_start >= r.target_loop_end or r.target_loop_end > r.target_frames) return error.AudioReportMismatch;
        if (r.target_loop_start != try remapFrame(r.source_loop_start, r.source_sample_rate) or r.target_loop_end != try remapFrame(r.source_loop_end, r.source_sample_rate)) return error.AudioReportMismatch;
    } else if (r.source_loop_start != 0 or r.source_loop_end != 0 or r.target_loop_start != 0 or r.target_loop_end != 0 or r.loop_play_count != 0) return error.AudioReportMismatch;
    if (remaps.len != r.remaps.count) return error.AudioReportMismatch;
    var marker_ids = std.AutoHashMap(u64, void).init(allocator);
    defer marker_ids.deinit();
    var previous_anchor: ?u64 = null;
    var loop_start_seen = false;
    var loop_end_seen = false;
    for (remaps) |v| {
        if (v.source_frame > r.source_frames or v.target_frame > r.target_frames) return error.InvalidReference;
        if (v.target_frame != try remapFrame(v.source_frame, r.source_sample_rate)) return error.AudioReportMismatch;
        switch (v.kind) {
            .cue, .anchor => {
                if ((try marker_ids.getOrPut(v.marker_id)).found_existing) return error.AudioReportMismatch;
                if (v.kind == .anchor) {
                    if (previous_anchor) |previous| if (v.target_frame <= previous) return error.AudioReportMismatch;
                    previous_anchor = v.target_frame;
                }
            },
            .loop_start => {
                if (r.loop_present == 0 or loop_start_seen or v.marker_id != 0 or v.source_frame != r.source_loop_start or v.target_frame != r.target_loop_start) return error.AudioReportMismatch;
                loop_start_seen = true;
            },
            .loop_end => {
                if (r.loop_present == 0 or loop_end_seen or v.marker_id != 0 or v.source_frame != r.source_loop_end or v.target_frame != r.target_loop_end) return error.AudioReportMismatch;
                loop_end_seen = true;
            },
        }
    }
    if (r.loop_present == 1 and (!loop_start_seen or !loop_end_seen)) return error.AudioReportMismatch;
}
