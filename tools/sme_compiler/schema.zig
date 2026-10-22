//! Music source v1: strict, deliberately bounded TOML subset.
//!
//! Required root keys: schema="bugu.music.source/v1", generation (positive
//! integer), initial_state and profile (quoted author IDs). Capability lists
//! default to the legacy v1 required capabilities and no optional capabilities.
//! The explicit bus_graph extension requires its separate capability and pass.
//! Every [[schema_table_name]] record has a unique, nonempty quoted id. Named
//! runtime records derive their numeric key and interned name from this ID.
//! sounds additionally require source="local/path"; paths never enter the bank.
//! All fixed-width schema fields are supported with their schema defaults.
//! References are quoted IDs (never numeric table indexes); optional references
//! are omitted to retain the none sentinel. Ranges are {first=0, count=1}; both
//! keys are required. Hashes are 64 hex digits or exact-length integer arrays.
//! Boolean-tagged u8 fields require true/false; floats accept integer literals.
//! strings records use value="text"; beat_groups records use value=integer.
//! blob and string_data are computed pools and cannot be authored directly.
//!
//! Supported TOML: bare keys, [[array tables]], basic/literal single-line
//! strings, TOML escapes including Unicode, decimal signed integers/floats
//! (digit-separator underscores allowed), booleans, single-line arrays and
//! inline tables, # comments, LF/CRLF. Arrays permit trailing commas; inline
//! tables do not. Duplicate/unknown keys (including nested keys), dotted keys,
//! table headers other than array tables, multiline values, dates, non-decimal
//! integers and non-finite floats are rejected. No permissive TOML fallback.
//! Input is capped at 4 MiB, 65,536 total records, 128 fields per record and
//! 16 levels of value nesting. ID/reference and string interning use hash maps.
//! Field types/ranges, UTF-8 and references are checked before any compiler pass.
//! Deep musical/media constraints are checked on the resulting IR by the bank
//! and registered validators. Schema defaults are not evidence of valid media.
//!
//! TASK-010 owns the only production media provider. There is intentionally no
//! default provider, no source-to-fixture fallback and no successful empty pass.
//! Required source capabilities automatically require their deep compiler passes;
//! requirePass can impose additional requirements and cannot relax these gates.
const std = @import("std");
pub const bank = @import("sme-bank");
pub const schema = bank.schema;
pub const policy_source = @import("sme-music-policy-source");
const s = schema;
/// Offline diagnostics only; this does not expand the public realtime error set.
pub const MediaCompileError = error{
    SourceReadFailed,
    UnsafeSourcePath,
    UnsupportedSourceFormat,
    InvalidWav,
    UnsupportedWavFormat,
    UnsupportedWavMetadata,
    ConflictingMetadata,
    UnsupportedLayout,
    InvalidSample,
    SampleOutOfRange,
    InvalidMarker,
    InvalidLoop,
    EmptyRemappedLoop,
    MisalignedAudio,
    SampleRateConversionFailed,
    InvalidContainer,
    TruncatedContainer,
    ContainerCrcMismatch,
    ContainerSequenceGap,
    PartialPacket,
    ChainedStreamUnsupported,
    UnsupportedChannelMapping,
    UnsupportedChannels,
    InvalidHeader,
    InvalidGranule,
    DecodeFailure,
    EncodeFailure,
    InvalidPcm,
    SeekOutOfRange,
    BufferTooSmall,
    NonFiniteSample,
    InvalidPolicy,
    MissingRequiredMeasurement,
    MissingEncodedHash,
};
pub const CompileError = s.BankError || std.mem.Allocator.Error || MediaCompileError || error{ InvalidFieldType, FieldOutOfRange, UnsupportedSourceImportVersion, SourceExpectationMismatch };
pub const source_schema = "bugu.music.source/v1";
pub const source_byte_limit = 4 * 1024 * 1024;
pub const maximum_value_depth = 16;
pub const maximum_record_fields = 128;

pub const AuthorRecord = struct { table: s.Table, id: []const u8, index: u32 };
/// Source-only declarations. Frames are original source frames, never normalized
/// frames. These records do not change the compiled bank wire layout.
pub const SourceMarkerKind = enum { cue, anchor };
pub const SourceMarker = struct { id: u64, kind: SourceMarkerKind, source_frame: u64, target: u32 = s.none };
pub const SourceLoop = struct { start: u64, end: u64, play_count: u32 = 0 };
pub const SourceImportV1 = struct {
    version: u32 = 1,
    source_hash: s.Hash,
    source_rate_hz: u32,
    source_layout: s.Layout,
    source_channel_mask: u32,
    markers: []const SourceMarker = &.{},
    loop: ?SourceLoop = null,
};
pub const SoundSource = struct { sound: u32, path: []const u8, import: ?SourceImportV1 = null };
/// Authoring tables are typed but are NOT a ValidatedIR: media bytes, reports,
/// grids and derived products still need their real owning compiler passes.
pub const SourceAST = struct {
    arena: std.heap.ArenaAllocator,
    metadata: s.Metadata,
    tables: s.Tables,
    authors: []const AuthorRecord,
    sound_sources: []const SoundSource,
    music_policy: ?policy_source.Source = null,
    pub fn deinit(self: *SourceAST) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn lookup(self: *const SourceAST, table: s.Table, id: []const u8) ?u32 {
        for (self.authors) |author| if (author.table == table and std.mem.eql(u8, id, author.id)) return author.index;
        return null;
    }
};

/// Every returned table and pool is owned by this arena, never by the SourceAST.
/// A media provider must not return borrowed input or independently-owned slices.
pub const StorageDecisionV1 = struct {
    segment_id: u64,
    requested: s.Storage,
    produced: s.Storage,
    decoded_bytes: u64,
    resident_limit_bytes: u64,
    forced_streaming: bool,
};
pub const OwnedIR = struct {
    /// TASK-010 supplies one source-bound decision per produced segment, in
    /// segment-table order. These reports are not runtime binary records.
    storage_decisions: []const StorageDecisionV1 = &.{},
    arena: std.heap.ArenaAllocator,
    ir: s.ValidatedIR,
    pub fn init(allocator: std.mem.Allocator) OwnedIR {
        return .{ .arena = .init(allocator), .ir = .{ .metadata = .{}, .tables = .{} } };
    }
    pub fn clone(allocator: std.mem.Allocator, ir: s.ValidatedIR) std.mem.Allocator.Error!OwnedIR {
        var owned = init(allocator);
        errdefer owned.deinit();
        owned.ir.metadata = ir.metadata;
        inline for (std.meta.fields(s.Tables)) |field| @field(owned.ir.tables, field.name) = try owned.arena.allocator().dupe(std.meta.Child(field.type), @field(ir.tables, field.name));
        return owned;
    }
    pub fn deinit(self: *OwnedIR) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const MediaProvider = *const fn (std.mem.Allocator, *const SourceAST) CompileError!OwnedIR;
/// Caller-owned synchronous context; no global resolver or implicit filesystem access.
/// Context must outlive compileAST/buildSource calls through this registry.
pub const MediaProviderContext = struct {
    context: *anyopaque,
    compile: *const fn (*anyopaque, std.mem.Allocator, *const SourceAST) CompileError!OwnedIR,
};
pub const Pass = enum { tempo, logic, selection, transitions, curves, buses, sidechain, acoustic, bus_graph, music_policy };
pub fn capabilityForPass(pass: Pass) s.Capability {
    return switch (pass) {
        .tempo => .tempo,
        .logic => .logic,
        .selection => .selection,
        .transitions => .transitions,
        .curves => .curves,
        .buses => .bus,
        .bus_graph => .bus_graph,
        .music_policy => .music_policy_v1,
        .sidechain => .sidechain,
        .acoustic => .acoustic,
    };
}
pub const CompilerPass = *const fn (*OwnedIR, *const SourceAST) CompileError!void;
pub const TableValidator = *const fn (std.mem.Allocator, *const SourceAST, *const s.ValidatedIR) CompileError!void;
const pass_count = std.meta.fields(Pass).len;

pub const Registry = struct {
    media_provider: ?MediaProvider = null,
    media_provider_context: ?MediaProviderContext = null,
    passes: [pass_count]?CompilerPass = @splat(null),
    required_passes: [pass_count]bool = @splat(false),
    validators: [s.table_count]?TableValidator = @splat(null),
    pub fn registerMediaProvider(self: *Registry, callback: MediaProvider) CompileError!void {
        if (self.media_provider != null or self.media_provider_context != null) return error.DuplicatePass;
        self.media_provider = callback;
    }
    pub fn registerMediaProviderContext(self: *Registry, provider: MediaProviderContext) CompileError!void {
        if (self.media_provider != null or self.media_provider_context != null) return error.DuplicatePass;
        self.media_provider_context = provider;
    }
    pub fn registerPass(self: *Registry, pass: Pass, callback: CompilerPass) CompileError!void {
        const i = @intFromEnum(pass);
        if (self.passes[i] != null) return error.DuplicatePass;
        self.passes[i] = callback;
    }
    pub fn requirePass(self: *Registry, pass: Pass) void {
        self.required_passes[@intFromEnum(pass)] = true;
    }
    pub fn registerValidator(self: *Registry, table: s.Table, callback: TableValidator) CompileError!void {
        const i = @intFromEnum(table);
        if (self.validators[i] != null) return error.DuplicatePass;
        self.validators[i] = callback;
    }
    pub fn compileAST(self: *const Registry, allocator: std.mem.Allocator, ast: *const SourceAST) CompileError!OwnedIR {
        if (self.media_provider == null and self.media_provider_context == null) return error.MissingRequiredPass;
        try bank.validateCapabilityDeclarations(ast.metadata, ast.tables);
        try policy_source.validateHandoff(ast.metadata, ast.tables, ast.music_policy);
        for (self.required_passes, self.passes, 0..) |required, pass, i| {
            const capability = capabilityForPass(@enumFromInt(i));
            if ((required or ast.metadata.required_capabilities & s.bit(capability) != 0) and pass == null) return error.MissingRequiredPass;
        }
        var owned = if (self.media_provider_context) |provider|
            try provider.compile(provider.context, allocator, ast)
        else
            try self.media_provider.?(allocator, ast);
        errdefer owned.deinit();
        // Execution order is the declared Pass enum, independent of registration.
        for (self.passes) |maybe_pass| if (maybe_pass) |pass| try pass(&owned, ast);
        // Mandatory recomputation cannot be bypassed by a registered callback.
        try policy_source.validateProduced(allocator, ast.music_policy, ast.metadata, ast.tables, owned.ir);
        try bank.validateIR(allocator, owned.ir);
        try validateStorageDecisions(allocator, ast, &owned);
        for (self.validators) |maybe_validator| if (maybe_validator) |validator| try validator(allocator, ast, &owned.ir);
        return owned;
    }
    pub fn buildSource(self: *const Registry, allocator: std.mem.Allocator, text: []const u8) CompileError!BuildResult {
        var ast = try parse(allocator, text);
        defer ast.deinit();
        return self.buildAST(allocator, &ast);
    }
    pub fn buildAST(self: *const Registry, allocator: std.mem.Allocator, ast: *const SourceAST) CompileError!BuildResult {
        var owned = try self.compileAST(allocator, ast);
        defer owned.deinit();
        const bytes = try bank.build(allocator, owned.ir);
        errdefer allocator.free(bytes);
        const decisions = try allocator.dupe(StorageDecisionV1, owned.storage_decisions);
        errdefer allocator.free(decisions);
        const policy = try policy_source.Report.copy(allocator, owned.ir.tables);
        return .{ .allocator = allocator, .bytes = bytes, .report = reportFor(bytes, owned.ir, decisions, policy) };
    }
};
pub const BuildReport = struct {
    music_policy: policy_source.Report,
    /// Owned by BuildResult; numeric IDs only, no local source paths.
    storage_decisions: []const StorageDecisionV1,
    forced_streaming_segments: u32,
    authored_streaming_segments: u32,
    /// Bit 0 = ForcedStreaming. Quality warnings retain their separate domain.
    storage_warning_bits: u32,
    content_hash: s.Hash,
    counts: [s.table_count]u32,
    bank_bytes: u64,
    blob_bytes: u64,
    resident_limit_bytes: u64,
    quality_warning_bits: u32,
};
pub const BuildResult = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    report: BuildReport,
    pub fn deinit(self: *BuildResult) void {
        self.report.music_policy.deinit(self.allocator);
        self.allocator.free(self.report.storage_decisions);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};
fn reportFor(bytes: []const u8, ir: s.ValidatedIR, decisions: []const StorageDecisionV1, policy: policy_source.Report) BuildReport {
    var report: BuildReport = .{ .music_policy = policy, .storage_decisions = decisions, .forced_streaming_segments = 0, .authored_streaming_segments = 0, .storage_warning_bits = 0, .content_hash = bytes[s.hash_offset..][0..32].*, .counts = @splat(0), .bank_bytes = bytes.len, .blob_bytes = ir.tables.blob.len, .resident_limit_bytes = ir.tables.platforms[ir.metadata.profile].resident_limit_bytes, .quality_warning_bits = 0 };
    inline for (std.meta.fields(s.Tables), 0..) |field, i| report.counts[i] = @intCast(@field(ir.tables, field.name).len);
    for (ir.tables.quality_reports) |quality| report.quality_warning_bits |= quality.warnings;
    for (decisions) |decision| {
        if (decision.forced_streaming) {
            report.forced_streaming_segments += 1;
            report.storage_warning_bits |= 1;
        }
        if (decision.requested == .streaming) report.authored_streaming_segments += 1;
    }
    return report;
}

pub fn validateStorageDecisions(allocator: std.mem.Allocator, ast: *const SourceAST, owned: *const OwnedIR) CompileError!void {
    if (owned.storage_decisions.len != owned.ir.tables.segments.len) return error.AudioReportMismatch;
    var authored = std.AutoHashMap(u64, s.Storage).init(allocator);
    defer authored.deinit();
    for (ast.tables.segments) |segment| {
        const entry = try authored.getOrPut(segment.key.id);
        if (entry.found_existing) return error.IdCollision;
        entry.value_ptr.* = segment.storage;
    }
    if (owned.ir.metadata.profile >= owned.ir.tables.platforms.len) return error.InvalidReference;
    const limit = owned.ir.tables.platforms[owned.ir.metadata.profile].resident_limit_bytes;
    var stems: std.ArrayList(s.StemSize) = .empty;
    defer stems.deinit(allocator);
    for (owned.ir.tables.segments, owned.storage_decisions) |segment, record| {
        const requested = authored.get(segment.key.id) orelse return error.AudioReportMismatch;
        if (@as(u64, segment.layers.first) + segment.layers.count > owned.ir.tables.layers.len) return error.InvalidReference;
        stems.clearRetainingCapacity();
        for (owned.ir.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            if (layer.sound >= owned.ir.tables.sounds.len) return error.InvalidReference;
            const sound = owned.ir.tables.sounds[layer.sound];
            try stems.append(allocator, .{ .frames = sound.frames, .channels = sound.channels });
        }
        const expected = try s.storageDecision(stems.items, limit, requested, segment.emergency == 1);
        if (expected.decoded_bytes != segment.decoded_bytes) return error.AudioReportMismatch;
        const produced = expected.storage;
        const forced = expected.forced_streaming;
        if (record.segment_id != segment.key.id or record.requested != requested or record.produced != produced or record.produced != segment.storage or record.decoded_bytes != segment.decoded_bytes or record.resident_limit_bytes != limit or record.forced_streaming != forced) return error.AudioReportMismatch;
    }
}

/// Caller-owned, allocation-free failure attribution. Locations refer to original
/// input bytes; field labels are known schema names, never untrusted source text.
pub const LocationKind = enum { document, token, record, field };
pub const ParseDiagnostic = struct {
    offset: ?usize = null,
    line: ?usize = null,
    column: ?usize = null,
    location_kind: ?LocationKind = null,
    table: ?s.Table = null,
    record_index: ?u32 = null,
    object_id: ?u64 = null,
    field_buffer: [256]u8 = undefined,
    field_len: usize = 0,

    pub fn field(self: *const ParseDiagnostic) ?[]const u8 {
        return if (self.field_len == 0) null else self.field_buffer[0..self.field_len];
    }
    pub fn setField(self: *ParseDiagnostic, name: ?[]const u8) void {
        self.field_len = 0;
        if (name) |text| if (text.len <= self.field_buffer.len) {
            @memcpy(self.field_buffer[0..text.len], text);
            self.field_len = text.len;
        };
    }
};
const Anchor = struct { offset: usize = 0, line: usize = 1, column: usize = 1, kind: LocationKind = .document };
const DiagnosticContext = struct {
    sink: *ParseDiagnostic,
    owner: Anchor = .{},
    fn anchor(self: *DiagnosticContext, at: Anchor) void {
        self.sink.offset = at.offset;
        self.sink.line = at.line;
        self.sink.column = at.column;
        self.sink.location_kind = at.kind;
    }
    fn record(self: *DiagnosticContext, at: Anchor, table: ?s.Table, index: ?u32) void {
        self.owner = at;
        self.sink.* = .{ .table = table, .record_index = index };
        self.anchor(at);
    }
    fn select(self: *DiagnosticContext, at: Anchor, name: ?[]const u8) void {
        self.anchor(at);
        self.sink.setField(name);
    }
    fn nested(self: *DiagnosticContext, parent: ParseDiagnostic, at: Anchor, name: ?[]const u8) void {
        self.sink.* = parent;
        self.anchor(at);
        self.sink.setField(null);
        if (name) |known| {
            if (parent.field()) |prefix| {
                if (prefix.len + 1 + known.len <= self.sink.field_buffer.len) {
                    @memcpy(self.sink.field_buffer[0..prefix.len], prefix);
                    self.sink.field_buffer[prefix.len] = '.';
                    @memcpy(self.sink.field_buffer[prefix.len + 1 ..][0..known.len], known);
                    self.sink.field_len = prefix.len + 1 + known.len;
                }
            }
        }
    }
};
fn selectField(context: ?*DiagnosticContext, entry: Field, name: ?[]const u8) void {
    if (context) |c| c.select(entry.anchor, name);
}
fn knownField(table: ?s.Table, name: []const u8) bool {
    if (table) |tag| {
        if (std.mem.eql(u8, name, "id")) return true;
        inline for (std.meta.fields(s.Tables), 0..) |_, i| {
            const t: s.Table = @enumFromInt(i);
            if (tag == t) {
                if (t == .strings or t == .beat_groups or t == .tempo_tick_frames) return std.mem.eql(u8, name, "value");
                if (t == .sounds and (std.mem.eql(u8, name, "source") or std.mem.eql(u8, name, "source_import"))) return true;
                if (comptime @typeInfo(s.Record(t)) == .@"struct") {
                    inline for (std.meta.fields(s.Record(t))) |f| {
                        if (!std.mem.eql(u8, f.name, "key") and std.mem.eql(u8, name, f.name)) return true;
                    }
                }
            }
        }
        return false;
    }
    for ([_][]const u8{ "schema", "generation", "initial_state", "profile", "required_capabilities", "optional_capabilities" }) |key| if (std.mem.eql(u8, name, key)) return true;
    return false;
}
fn knownNestedIn(comptime T: type, path: []const u8, name: []const u8) bool {
    switch (@typeInfo(T)) {
        .array => |info| return knownNestedIn(info.child, path, name),
        .@"struct" => |info| {
            if (path.len == 0) {
                inline for (info.fields) |f| if (std.mem.eql(u8, f.name, name)) return true;
            } else {
                const end = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
                inline for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, path[0..end])) return knownNestedIn(f.type, if (end == path.len) "" else path[end + 1 ..], name);
                }
            }
        },
        else => {},
    }
    return false;
}
fn knownNested(table: ?s.Table, path: ?[]const u8, name: []const u8) bool {
    const tag = table orelse return false;
    const parent = path orelse return false;
    if (tag == .sounds) {
        if (std.mem.eql(u8, parent, "source_import")) return sourceImportField(name);
        if (std.mem.eql(u8, parent, "source_import.markers")) return knownNestedIn(SourceMarker, "", name);
        if (std.mem.eql(u8, parent, "source_import.loop")) return knownNestedIn(SourceLoop, "", name);
    }
    inline for (std.meta.fields(s.Tables), 0..) |_, i| {
        if (@intFromEnum(tag) == i) return knownNestedIn(s.Record(@enumFromInt(i)), parent, name);
    }
    return false;
}
fn sourceImportField(name: []const u8) bool {
    inline for (std.meta.fields(SourceImportV1)) |field| if (std.mem.eql(u8, field.name, name)) return true;
    return false;
}
const Value = union(enum) { integer: i512, float: f64, boolean: bool, string: []const u8, array: []const Value, object: []const Field };
const Field = struct { name: []const u8, value: Value, anchor: Anchor };
const ParsedRecord = struct { table: s.Table, anchor: Anchor, index: u32, fields: std.ArrayList(Field) = .empty };
const ValueParser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,
    line_offset: usize = 0,
    line_number: usize = 1,
    context: ?*DiagnosticContext = null,
    fn position(self: *const ValueParser, column: usize, kind: LocationKind) Anchor {
        return .{ .offset = self.line_offset + column, .line = self.line_number, .column = column + 1, .kind = kind };
    }
    fn whitespace(self: *ValueParser) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) self.pos += 1;
    }
    fn consume(self: *ValueParser, expected: u8) bool {
        self.whitespace();
        if (self.pos < self.text.len and self.text[self.pos] == expected) {
            self.pos += 1;
            return true;
        }
        return false;
    }
    fn key(self: *ValueParser) CompileError![]const u8 {
        self.whitespace();
        const start = self.pos;
        while (self.pos < self.text.len and bare(self.text[self.pos])) self.pos += 1;
        if (self.pos == start) return error.InvalidSource;
        return self.text[start..self.pos];
    }
    fn string(self: *ValueParser) CompileError![]const u8 {
        const quote = self.text[self.pos];
        self.pos += 1;
        var decoded: std.ArrayList(u8) = .empty;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            self.pos += 1;
            if (c == quote) return decoded.toOwnedSlice(self.allocator);
            if (c < 0x20 and c != '\t' or c == 0x7f) return error.InvalidSource;
            if (c != '\\' or quote == '\'') {
                try decoded.append(self.allocator, c);
                continue;
            }
            if (self.pos == self.text.len) return error.InvalidSource;
            const escape = self.text[self.pos];
            self.pos += 1;
            const byte: u8 = switch (escape) {
                'b' => 8,
                't' => '\t',
                'n' => '\n',
                'f' => 12,
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                'u', 'U' => {
                    const digits: usize = if (escape == 'u') 4 else 8;
                    if (self.text.len - self.pos < digits) return error.InvalidSource;
                    var cp: u32 = 0;
                    for (self.text[self.pos..][0..digits]) |hex_digit| cp = (std.math.mul(u32, cp, 16) catch return error.InvalidSource) + try hex(hex_digit);
                    self.pos += digits;
                    if (cp > 0x10ffff or cp >= 0xd800 and cp <= 0xdfff) return error.InvalidSource;
                    var encoded: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &encoded) catch return error.InvalidSource;
                    try decoded.appendSlice(self.allocator, encoded[0..n]);
                    continue;
                },
                else => return error.InvalidSource,
            };
            try decoded.append(self.allocator, byte);
        }
        return error.InvalidSource;
    }
    fn value(self: *ValueParser, depth: usize) CompileError!Value {
        if (depth > maximum_value_depth) return error.ResourceLimitExceeded;
        self.whitespace();
        if (self.pos == self.text.len) return error.InvalidSource;
        switch (self.text[self.pos]) {
            '"', '\'' => return .{ .string = try self.string() },
            '[' => {
                self.pos += 1;
                var values: std.ArrayList(Value) = .empty;
                if (self.consume(']')) return .{ .array = &.{} };
                while (true) {
                    if (values.items.len >= s.Limits.records) return error.ResourceLimitExceeded;
                    try values.append(self.allocator, try self.value(depth + 1));
                    if (self.consume(']')) break;
                    if (!self.consume(',')) return error.InvalidSource;
                    if (self.consume(']')) break;
                }
                return .{ .array = try values.toOwnedSlice(self.allocator) };
            },
            '{' => {
                self.pos += 1;
                var fields: std.ArrayList(Field) = .empty;
                if (self.consume('}')) return .{ .object = &.{} };
                while (true) {
                    self.whitespace();
                    const at = self.position(self.pos, .field);
                    const parent = if (self.context) |c| c.sink.* else ParseDiagnostic{};
                    const name = try self.key();
                    if (self.context) |c| c.nested(parent, at, if (knownNested(parent.table, parent.field(), name)) name else null);
                    if (!self.consume('=')) return error.InvalidSource;
                    const entry: Field = .{ .name = name, .value = try self.value(depth + 1), .anchor = at };
                    try appendField(self.allocator, &fields, entry);
                    if (self.context) |c| c.sink.* = parent;
                    if (self.consume('}')) break;
                    if (!self.consume(',')) return error.InvalidSource;
                }
                return .{ .object = try fields.toOwnedSlice(self.allocator) };
            },
            else => {
                const start = self.pos;
                while (self.pos < self.text.len and std.mem.indexOfScalar(u8, " \t,]}#", self.text[self.pos]) == null) self.pos += 1;
                const token = self.text[start..self.pos];
                if (std.mem.eql(u8, token, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, token, "false")) return .{ .boolean = false };
                return self.number(token);
            },
        }
    }
    fn number(self: *ValueParser, token: []const u8) CompileError!Value {
        if (token.len == 0) return error.InvalidSource;
        const clean = try self.allocator.alloc(u8, token.len);
        var n: usize = 0;
        for (token, 0..) |c, i| {
            if (c == '_') {
                if (i == 0 or i + 1 == token.len or !digit(token[i - 1]) or !digit(token[i + 1])) return error.InvalidSource;
            } else {
                clean[n] = c;
                n += 1;
            }
        }
        const text = clean[0..n];
        var i: usize = 0;
        if (i < n and (text[i] == '+' or text[i] == '-')) i += 1;
        const start = i;
        while (i < n and digit(text[i])) i += 1;
        if (i == start or i - start > 1 and text[start] == '0') return error.InvalidSource;
        var floating = false;
        if (i < n and text[i] == '.') {
            floating = true;
            i += 1;
            const fraction = i;
            while (i < n and digit(text[i])) i += 1;
            if (i == fraction) return error.InvalidSource;
        }
        if (i < n and (text[i] == 'e' or text[i] == 'E')) {
            floating = true;
            i += 1;
            if (i < n and (text[i] == '+' or text[i] == '-')) i += 1;
            const exponent = i;
            while (i < n and digit(text[i])) i += 1;
            if (i == exponent) return error.InvalidSource;
        }
        if (i != n) return error.InvalidSource;
        if (floating) {
            const result = std.fmt.parseFloat(f64, text) catch return error.FieldOutOfRange;
            if (!std.math.isFinite(result)) return error.FieldOutOfRange;
            return .{ .float = result };
        }
        return .{ .integer = std.fmt.parseInt(i512, text, 10) catch return error.FieldOutOfRange };
    }
};
fn digit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn bare(c: u8) bool {
    return digit(c) or c >= 'a' and c <= 'z' or c >= 'A' and c <= 'Z' or c == '_' or c == '-';
}
fn hex(c: u8) CompileError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidSource,
    };
}
fn appendField(allocator: std.mem.Allocator, fields: *std.ArrayList(Field), field: Field) CompileError!void {
    if (fields.items.len == maximum_record_fields) return error.ResourceLimitExceeded;
    for (fields.items) |previous| if (std.mem.eql(u8, previous.name, field.name)) return error.DuplicateField;
    try fields.append(allocator, field);
}
fn findField(fields: []const Field, name: []const u8) ?Value {
    for (fields) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}
fn requiredField(fields: []const Field, name: []const u8, context: ?*DiagnosticContext) CompileError!Value {
    for (fields) |entry| if (std.mem.eql(u8, entry.name, name)) {
        selectField(context, entry, name);
        return entry.value;
    };
    if (context) |c| c.select(c.owner, name);
    return error.MissingField;
}
fn optionalField(fields: []const Field, name: []const u8, context: ?*DiagnosticContext) ?Value {
    for (fields) |entry| if (std.mem.eql(u8, entry.name, name)) {
        selectField(context, entry, name);
        return entry.value;
    };
    return null;
}
fn optionalNested(fields: []const Field, name: []const u8, parent: ParseDiagnostic, context: ?*DiagnosticContext) ?Value {
    for (fields) |entry| if (std.mem.eql(u8, entry.name, name)) {
        if (context) |c| c.nested(parent, entry.anchor, name);
        return entry.value;
    };
    return null;
}
fn requiredNested(fields: []const Field, name: []const u8, parent: ParseDiagnostic, context: ?*DiagnosticContext) CompileError!Value {
    if (optionalNested(fields, name, parent, context)) |value| return value;
    if (context) |c| c.nested(parent, .{ .offset = parent.offset.?, .line = parent.line.?, .column = parent.column.?, .kind = parent.location_kind.? }, name);
    return error.MissingField;
}
fn rejectUnknownNested(comptime T: type, fields: []const Field, parent: ParseDiagnostic, context: ?*DiagnosticContext) CompileError!void {
    for (fields) |entry| {
        var known = false;
        inline for (std.meta.fields(T)) |field| if (std.mem.eql(u8, field.name, entry.name)) {
            known = true;
        };
        if (!known) {
            if (context) |c| c.nested(parent, entry.anchor, null);
            return error.UnknownField;
        }
    }
}
fn stringValue(value: Value) CompileError![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidFieldType,
    };
}
fn identifier(value: Value) CompileError![]const u8 {
    const text = try stringValue(value);
    if (text.len == 0 or text.len > s.Limits.id_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidSource;
    for (text) |c| if (c < 0x20 or c == 0x7f) return error.InvalidSource;
    return text;
}
fn qualityBoolean(comptime T: type, comptime name: []const u8) bool {
    return T == s.QualityPolicyRecordV1 and (std.mem.eql(u8, name, "require_loop") or std.mem.eql(u8, name, "lufs_range_present") or std.mem.eql(u8, name, "require_lufs_range")) or
        T == s.QualitySpeakerV1 and std.mem.eql(u8, name, "lfe") or
        T == s.QualityLoopMetricsV1 and std.mem.eql(u8, name, "dc_anomaly");
}
fn parseBoolean(value: Value) CompileError!u8 {
    return switch (value) {
        .boolean => |v| @intFromBool(v),
        else => error.InvalidFieldType,
    };
}
fn convert(comptime T: type, value: Value, context: ?*DiagnosticContext) CompileError!T {
    return switch (@typeInfo(T)) {
        .int => switch (value) {
            .integer => |integer| std.math.cast(T, integer) orelse error.FieldOutOfRange,
            else => error.InvalidFieldType,
        },
        .float => blk: {
            const number: f64 = switch (value) {
                .float => |v| v,
                .integer => |v| @floatFromInt(v),
                else => return error.InvalidFieldType,
            };
            const narrowed: T = @floatCast(number);
            if (!std.math.isFinite(narrowed)) return error.FieldOutOfRange;
            break :blk narrowed;
        },
        .@"enum" => std.meta.stringToEnum(T, try stringValue(value)) orelse error.InvalidFieldType,
        .array => |info| blk: {
            var result: T = undefined;
            if (T == s.Hash and value == .string) {
                const text = value.string;
                if (text.len != 64) return error.FieldOutOfRange;
                for (&result, 0..) |*byte, i| byte.* = (try hex(text[i * 2])) * 16 + try hex(text[i * 2 + 1]);
            } else {
                const values = switch (value) {
                    .array => |array| array,
                    else => return error.InvalidFieldType,
                };
                if (values.len != info.len) return error.FieldOutOfRange;
                for (&result, values) |*out, in| out.* = try convert(info.child, in, context);
            }
            break :blk result;
        },
        .@"struct" => |info| blk: {
            const fields = switch (value) {
                .object => |object| object,
                else => return error.InvalidFieldType,
            };
            var result: T = undefined;
            const parent = if (context) |c| c.sink.* else ParseDiagnostic{};
            const enclosing: Anchor = if (context) |c| .{ .offset = c.sink.offset.?, .line = c.sink.line.?, .column = c.sink.column.?, .kind = c.sink.location_kind.? } else .{};
            inline for (info.fields) |f| {
                var selected: ?Field = null;
                for (fields) |entry| if (std.mem.eql(u8, entry.name, f.name)) {
                    selected = entry;
                    break;
                };
                if (context) |c| c.nested(parent, if (selected) |entry| entry.anchor else enclosing, f.name);
                const field_value = if (selected) |entry| entry.value else return error.MissingField;
                @field(result, f.name) = if (comptime f.type == u8 and qualityBoolean(T, f.name))
                    try parseBoolean(field_value)
                else
                    try convert(f.type, field_value, context);
            }
            if (context) |c| c.sink.* = parent;
            for (fields) |entry| {
                var known = false;
                inline for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, entry.name)) known = true;
                }
                if (!known) {
                    selectField(context, entry, null);
                    return error.UnknownField;
                }
            }
            break :blk result;
        },
        else => @compileError("Unsupported source schema field"),
    };
}

pub const Reference = struct { table: s.Table, optional: bool = false };
/// Shared source-field metadata for authoring tools. Opcode is needed only for instructions.reference.
pub fn referenceTarget(table: s.Table, name: []const u8, instruction_op: ?s.LogicOp) CompileError!?Reference {
    const Pair = struct { owner: s.Table, name: []const u8, target: s.Table, optional: bool = false };
    const pairs = [_]Pair{
        .{ .owner = .graph_configs, .name = "platform", .target = .platforms },
        .{ .owner = .graph_configs, .name = "output_bus", .target = .buses },
        .{ .owner = .graph_configs, .name = "music_bus", .target = .buses },
        .{ .owner = .graph_configs, .name = "sfx_bus", .target = .buses, .optional = true },
        .{ .owner = .graph_configs, .name = "legacy_music_bus", .target = .buses, .optional = true },
        .{ .owner = .graph_configs, .name = "legacy_master_bus", .target = .buses, .optional = true },
        .{ .owner = .graph_configs, .name = "reverb_bus", .target = .buses, .optional = true },
        .{ .owner = .graph_nodes, .name = "bus", .target = .buses },
        .{ .owner = .graph_edges, .name = "source", .target = .buses },
        .{ .owner = .graph_edges, .name = "destination", .target = .buses },
        .{ .owner = .graph_edges, .name = "matrix", .target = .graph_matrices, .optional = true },
        .{ .owner = .graph_effects, .name = "detector_bus", .target = .buses, .optional = true },
        .{ .owner = .graph_effects, .name = "preset", .target = .graph_presets, .optional = true },
        .{ .owner = .graph_targets, .name = "bus", .target = .buses, .optional = true },
        .{ .owner = .graph_targets, .name = "edge", .target = .graph_edges, .optional = true },
        .{ .owner = .graph_targets, .name = "effect", .target = .graph_effects, .optional = true },

        .{ .owner = .transition_paths, .name = "transition", .target = .transitions },
        .{ .owner = .transition_paths, .name = "source_exit", .target = .cues },
        .{ .owner = .transition_paths, .name = "target_entry", .target = .cues },
        .{ .owner = .transition_paths, .name = "fill", .target = .fills, .optional = true },
        .{ .owner = .sounds, .name = "codec", .target = .codecs },
        .{ .owner = .sounds, .name = "import_report", .target = .import_reports },
        .{ .owner = .sounds, .name = "quality_report", .target = .quality_reports },
        .{ .owner = .sounds, .name = "encoded_quality_report", .target = .quality_reports, .optional = true },
        .{ .owner = .states, .name = "theme", .target = .themes },
        .{ .owner = .states, .name = "selector", .target = .selectors },
        .{ .owner = .themes, .name = "initial_segment", .target = .segments },
        .{ .owner = .segments, .name = "theme", .target = .themes },
        .{ .owner = .segments, .name = "tempo", .target = .tempos },
        .{ .owner = .segments, .name = "fallback_segment", .target = .segments, .optional = true },
        .{ .owner = .selectors, .name = "fallback_segment", .target = .segments, .optional = true },
        .{ .owner = .candidates, .name = "segment", .target = .segments },
        .{ .owner = .candidates, .name = "condition", .target = .logic, .optional = true },
        .{ .owner = .layers, .name = "segment", .target = .segments },
        .{ .owner = .layers, .name = "sound", .target = .sounds },
        .{ .owner = .layers, .name = "bus", .target = .buses },
        .{ .owner = .layers, .name = "gain_curve", .target = .curves, .optional = true },
        .{ .owner = .transitions, .name = "from", .target = .states },
        .{ .owner = .transitions, .name = "to", .target = .states },
        .{ .owner = .transitions, .name = "condition", .target = .logic, .optional = true },
        .{ .owner = .transitions, .name = "selector", .target = .selectors },
        .{ .owner = .transitions, .name = "source_exit", .target = .cues },
        .{ .owner = .transitions, .name = "target_entry", .target = .cues },
        .{ .owner = .transitions, .name = "fill", .target = .fills, .optional = true },
        .{ .owner = .transitions, .name = "fallback_segment", .target = .segments, .optional = true },
        .{ .owner = .cues, .name = "segment", .target = .segments },
        .{ .owner = .fills, .name = "source_exit", .target = .cues },
        .{ .owner = .fills, .name = "target_entry", .target = .cues },
        .{ .owner = .fill_steps, .name = "segment", .target = .segments },
        .{ .owner = .fill_steps, .name = "entry", .target = .cues },
        .{ .owner = .fill_steps, .name = "exit", .target = .cues },
        .{ .owner = .stingers, .name = "segment", .target = .segments },
        .{ .owner = .stingers, .name = "cue", .target = .cues },
        .{ .owner = .stingers, .name = "duck_preset", .target = .sidechains, .optional = true },
        .{ .owner = .buses, .name = "parent", .target = .buses, .optional = true },
        .{ .owner = .bus_sends, .name = "target", .target = .buses },
        .{ .owner = .sidechains, .name = "source_bus", .target = .buses },
        .{ .owner = .sidechains, .name = "target_bus", .target = .buses },
        .{ .owner = .acoustic_profiles, .name = "parameter", .target = .parameters },
        .{ .owner = .acoustic_profiles, .name = "mapping_curve", .target = .curves },
        .{ .owner = .chunks, .name = "sound", .target = .sounds },
        .{ .owner = .seeks, .name = "sound", .target = .sounds },
        .{ .owner = .beats, .name = "span", .target = .tempo_spans },
        .{ .owner = .bars, .name = "span", .target = .tempo_spans },
        .{ .owner = .import_reports, .name = "policy", .target = .import_policies },
    };
    for (pairs) |pair| if (pair.owner == table and std.mem.eql(u8, name, pair.name)) return .{ .table = pair.target, .optional = pair.optional };
    if (table == .instructions and std.mem.eql(u8, name, "reference")) {
        const op = instruction_op orelse return error.MissingField;
        return switch (op) {
            .load_state => .{ .table = .states },
            .load_parameter => .{ .table = .parameters },
            .load_context => .{ .table = .contexts },
            else => error.InvalidFieldType,
        };
    }
    return null;
}
/// Shared source spelling for boolean-tagged integers; tools must not duplicate it.
pub fn booleanField(table: s.Table, name: []const u8) bool {
    if (table == .graph_nodes and std.mem.eql(u8, name, "mute") or table == .graph_edges and std.mem.eql(u8, name, "route_selected") or table == .graph_effects and std.mem.eql(u8, name, "bypass")) return true;
    return (table == .states or table == .layers) and std.mem.eql(u8, name, "required") or table == .segments and std.mem.eql(u8, name, "emergency") or table == .stingers and std.mem.eql(u8, name, "protected") or table == .tempos and std.mem.eql(u8, name, "loop_present") or table == .import_reports and (std.mem.eql(u8, name, "bypass") or std.mem.eql(u8, name, "opus_input_rate_hint_present") or std.mem.eql(u8, name, "loop_present")) or table == .quality_reports and (std.mem.eql(u8, name, "peak_silence") or std.mem.eql(u8, name, "encoded_hash_present") or std.mem.eql(u8, name, "loop_present"));
}
const Lowering = struct {
    allocator: std.mem.Allocator,
    indexes: *const [s.table_count]std.StringHashMap(u32),
    string_index: std.StringHashMap(u32),
    strings: std.ArrayList(s.String) = .empty,
    string_data: std.ArrayList(u8) = .empty,
    sound_sources: std.ArrayList(SoundSource) = .empty,
    context: ?*DiagnosticContext = null,
    fn resolve(self: *const Lowering, table: s.Table, value: Value) CompileError!u32 {
        const id = try identifier(value);
        return self.indexes[@intFromEnum(table)].get(id) orelse error.InvalidReference;
    }
    fn intern(self: *Lowering, text: []const u8) CompileError!u32 {
        if (self.string_index.get(text)) |index| return index;
        return self.appendString(text);
    }
    fn appendString(self: *Lowering, text: []const u8) CompileError!u32 {
        if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSource;
        if (self.string_data.items.len + text.len > s.Limits.string_bytes or self.strings.items.len == s.Limits.records) return error.ResourceLimitExceeded;
        const index: u32 = @intCast(self.strings.items.len);
        try self.strings.append(self.allocator, .{ .bytes = .{ .first = @intCast(self.string_data.items.len), .count = @intCast(text.len) } });
        try self.string_data.appendSlice(self.allocator, text);
        const entry = try self.string_index.getOrPut(text);
        if (!entry.found_existing) entry.value_ptr.* = index;
        return index;
    }
    fn sourceImport(self: *Lowering, value: Value) CompileError!SourceImportV1 {
        const context = self.context;
        const parent = if (context) |c| c.sink.* else ParseDiagnostic{};
        const fields = switch (value) {
            .object => |v| v,
            else => return error.InvalidFieldType,
        };
        try rejectUnknownNested(SourceImportV1, fields, parent, context);
        const version = try convert(u32, try requiredNested(fields, "version", parent, context), context);
        if (version != 1) return error.UnsupportedSourceImportVersion;
        const source_hash = try convert(s.Hash, try requiredNested(fields, "source_hash", parent, context), context);
        const source_rate = try convert(u32, try requiredNested(fields, "source_rate_hz", parent, context), context);
        if (source_rate == 0) return error.FieldOutOfRange;
        const layout = try convert(s.Layout, try requiredNested(fields, "source_layout", parent, context), context);
        const mask = try convert(u32, try requiredNested(fields, "source_channel_mask", parent, context), context);
        var result: SourceImportV1 = .{ .source_hash = source_hash, .source_rate_hz = source_rate, .source_layout = layout, .source_channel_mask = mask };
        if (optionalNested(fields, "markers", parent, context)) |markers_value| {
            const marker_parent = if (context) |c| c.sink.* else ParseDiagnostic{};
            const values = switch (markers_value) {
                .array => |v| v,
                else => return error.InvalidFieldType,
            };
            const markers = try self.allocator.alloc(SourceMarker, values.len);
            for (values, markers) |item, *marker| {
                const row = switch (item) {
                    .object => |v| v,
                    else => return error.InvalidFieldType,
                };
                try rejectUnknownNested(SourceMarker, row, marker_parent, context);
                const id = try convert(u64, try requiredNested(row, "id", marker_parent, context), context);
                const kind = try convert(SourceMarkerKind, try requiredNested(row, "kind", marker_parent, context), context);
                const frame = try convert(u64, try requiredNested(row, "source_frame", marker_parent, context), context);
                const target = if (optionalNested(row, "target", marker_parent, context)) |target_value| try self.resolve(if (kind == .cue) .cues else .anchors, target_value) else s.none;
                marker.* = .{ .id = id, .kind = kind, .source_frame = frame, .target = target };
            }
            result.markers = markers;
        }
        if (optionalNested(fields, "loop", parent, context)) |loop_value| {
            const loop_parent = if (context) |c| c.sink.* else ParseDiagnostic{};
            const row = switch (loop_value) {
                .object => |v| v,
                else => return error.InvalidFieldType,
            };
            try rejectUnknownNested(SourceLoop, row, loop_parent, context);
            result.loop = .{
                .start = try convert(u64, try requiredNested(row, "start", loop_parent, context), context),
                .end = try convert(u64, try requiredNested(row, "end", loop_parent, context), context),
                .play_count = if (optionalNested(row, "play_count", loop_parent, context)) |v| try convert(u32, v, context) else 0,
            };
        }
        if (context) |c| c.sink.* = parent;
        return result;
    }
    fn record(self: *Lowering, comptime table: s.Table, fields: []const Field, index: u32) CompileError!s.Record(table) {
        const T = s.Record(table);
        const id = try identifier(try requiredField(fields, "id", self.context));
        if (comptime table == .strings) {
            for (fields) |entry| if (!std.mem.eql(u8, entry.name, "id") and !std.mem.eql(u8, entry.name, "value")) {
                selectField(self.context, entry, null);
                return error.UnknownField;
            };
            const text = try stringValue(try requiredField(fields, "value", self.context));
            const str_index = try self.appendString(text);
            return self.strings.items[str_index];
        } else if (comptime table == .beat_groups or table == .tempo_tick_frames) {
            for (fields) |entry| if (!std.mem.eql(u8, entry.name, "id") and !std.mem.eql(u8, entry.name, "value")) {
                selectField(self.context, entry, null);
                return error.UnknownField;
            };
            return convert(T, try requiredField(fields, "value", self.context), self.context);
        } else if (comptime table == .blob or table == .string_data) {
            return error.UnknownField;
        } else {
            var result: T = .{};
            if (@hasField(T, "key")) result.key = .{ .id = s.music.hashName(id) catch return error.InvalidSource, .name = try self.intern(id) };
            if (table == .sounds) {
                const path = try stringValue(try requiredField(fields, "source", self.context));
                if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidSource;
                const imported = if (optionalField(fields, "source_import", self.context)) |value| try self.sourceImport(value) else null;
                try self.sound_sources.append(self.allocator, .{ .sound = index, .path = path, .import = imported });
            }
            for (fields) |entry| {
                if (std.mem.eql(u8, entry.name, "id") or table == .sounds and (std.mem.eql(u8, entry.name, "source") or std.mem.eql(u8, entry.name, "source_import"))) continue;
                var known = false;
                inline for (std.meta.fields(T)) |f| {
                    if (comptime !std.mem.eql(u8, f.name, "key")) {
                        if (std.mem.eql(u8, entry.name, f.name)) {
                            known = true;
                            selectField(self.context, entry, f.name);
                            if (comptime f.type == u32) {
                                const op = if (table == .instructions and std.mem.eql(u8, f.name, "reference")) try convert(s.LogicOp, try requiredField(fields, "op", self.context), self.context) else null;
                                selectField(self.context, entry, f.name);
                                if (try referenceTarget(table, f.name, op)) |ref| {
                                    @field(result, f.name) = try self.resolve(ref.table, entry.value);
                                } else @field(result, f.name) = try convert(f.type, entry.value, self.context);
                            } else if (comptime f.type == u8) {
                                if (booleanField(table, f.name)) {
                                    @field(result, f.name) = switch (entry.value) {
                                        .boolean => |v| @intFromBool(v),
                                        else => return error.InvalidFieldType,
                                    };
                                } else @field(result, f.name) = try convert(f.type, entry.value, self.context);
                            } else @field(result, f.name) = try convert(f.type, entry.value, self.context);
                        }
                    }
                }
                if (!known) {
                    selectField(self.context, entry, null);
                    return error.UnknownField;
                }
            }
            return result;
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) CompileError!SourceAST {
    return parseImpl(allocator, input, null);
}
pub fn parseDiagnosed(allocator: std.mem.Allocator, input: []const u8, diagnostic: *ParseDiagnostic) CompileError!SourceAST {
    diagnostic.* = .{};
    var context: DiagnosticContext = .{ .sink = diagnostic };
    context.record(.{}, null, null);
    const result = try parseImpl(allocator, input, &context);
    diagnostic.* = .{};
    return result;
}
fn parseImpl(allocator: std.mem.Allocator, input: []const u8, context: ?*DiagnosticContext) CompileError!SourceAST {
    @setEvalBranchQuota(100_000);
    if (input.len > source_byte_limit) return error.ResourceLimitExceeded;
    if (!std.unicode.utf8ValidateSlice(input) or std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidUtf8;
    for (input, 0..) |c, i| {
        if (c < 0x20 and c != '\n' and c != '\r' and c != '\t' or c == 0x7f or c == '\r' and (i + 1 == input.len or input[i + 1] != '\n')) {
            if (context) |ctx| {
                const line = 1 + std.mem.count(u8, input[0..i], "\n");
                const column = i - (if (std.mem.lastIndexOfScalar(u8, input[0..i], '\n')) |nl| nl + 1 else 0) + 1;
                ctx.select(.{ .offset = i, .line = line, .column = column, .kind = .token }, null);
            }
            return error.InvalidSource;
        }
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const text = try a.dupe(u8, input);
    var root: std.ArrayList(Field) = .empty;
    var records: std.ArrayList(ParsedRecord) = .empty;
    var lexical_counts: [s.table_count]u32 = @splat(0);
    var line_offset: usize = 0;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        defer {
            line_offset += raw_line.len + 1;
            line_number += 1;
        }
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        var parser: ValueParser = .{ .allocator = a, .text = line, .line_offset = line_offset, .line_number = line_number, .context = context };
        parser.whitespace();
        if (parser.pos == line.len or line[parser.pos] == '#') continue;
        const at = parser.position(parser.pos, if (line[parser.pos] == '[') .record else .field);
        if (context) |c| {
            if (records.items.len == 0) c.record(.{}, null, null) else {
                const current = records.items[records.items.len - 1];
                c.record(current.anchor, current.table, current.index);
            }
            c.select(at, null);
        }
        if (line[parser.pos] == '[') {
            if (context) |c| c.record(at, null, null);
            if (!std.mem.startsWith(u8, line[parser.pos..], "[[")) return error.InvalidSource;
            parser.pos += 2;
            const name = try parser.key();
            parser.whitespace();
            if (!std.mem.startsWith(u8, line[parser.pos..], "]]")) return error.InvalidSource;
            parser.pos += 2;
            const table = std.meta.stringToEnum(s.Table, name) orelse return error.UnknownField;
            if (table == .blob or table == .string_data or @intFromEnum(table) >= s.legacy_table_count) return error.UnknownField;
            if (records.items.len >= s.Limits.records) return error.ResourceLimitExceeded;
            const index = lexical_counts[@intFromEnum(table)];
            if (context) |c| c.record(at, table, index);
            try records.append(a, .{ .table = table, .anchor = at, .index = index });
            lexical_counts[@intFromEnum(table)] += 1;
        } else {
            const name = try parser.key();
            if (context) |c| c.select(at, if (knownField(c.sink.table, name)) name else null);
            if (!parser.consume('=')) return error.InvalidSource;
            const entry: Field = .{ .name = name, .value = try parser.value(0), .anchor = at };
            if (records.items.len == 0) try appendField(a, &root, entry) else try appendField(a, &records.items[records.items.len - 1].fields, entry);
        }
        parser.whitespace();
        if (parser.pos < line.len and line[parser.pos] != '#') return error.InvalidSource;
    }
    if (context) |c| c.record(.{}, null, null);
    for (root.items) |entry| {
        const names = [_][]const u8{ "schema", "generation", "initial_state", "profile", "required_capabilities", "optional_capabilities" };
        var known = false;
        for (names) |name| if (std.mem.eql(u8, entry.name, name)) {
            known = true;
            break;
        };
        if (!known) {
            selectField(context, entry, null);
            return error.UnknownField;
        }
    }
    if (!std.mem.eql(u8, try stringValue(try requiredField(root.items, "schema", context)), source_schema)) return error.InvalidBankVersion;
    var metadata: s.Metadata = .{ .generation = try convert(u64, try requiredField(root.items, "generation", context), context) };
    if (metadata.generation == 0) return error.InvalidGeneration;
    if (optionalField(root.items, "required_capabilities", context)) |value| metadata.required_capabilities = try capabilities(value);
    if (optionalField(root.items, "optional_capabilities", context)) |value| metadata.optional_capabilities = try capabilities(value);
    if (metadata.required_capabilities & s.bit(.core) == 0 or metadata.required_capabilities & metadata.optional_capabilities != 0) {
        if (context) |c| {
            const name = if (metadata.required_capabilities & s.bit(.core) == 0) "required_capabilities" else "optional_capabilities";
            if (optionalField(root.items, name, context) == null) c.select(c.owner, name);
        }
        return error.InvalidCapabilityDeclaration;
    }
    var authors: std.ArrayList(AuthorRecord) = .empty;
    var indexes: [s.table_count]std.StringHashMap(u32) = undefined;
    for (&indexes) |*index| index.* = .init(a);
    var counts: [s.table_count]u32 = @splat(0);
    for (records.items) |record| {
        if (context) |c| c.record(record.anchor, record.table, record.index);
        const id = try identifier(try requiredField(record.fields.items, "id", context));
        const i = @intFromEnum(record.table);
        const entry = try indexes[i].getOrPut(id);
        if (entry.found_existing) return error.IdCollision;
        entry.value_ptr.* = counts[i];
        if (counts[i] == s.countLimit(record.table)) return error.ResourceLimitExceeded;
        try authors.append(a, .{ .table = record.table, .id = id, .index = counts[i] });
        counts[i] += 1;
    }
    var lowering: Lowering = .{ .allocator = a, .indexes = &indexes, .string_index = .init(a), .context = context };
    if (context) |c| c.record(.{}, null, null);
    metadata.initial_state = try lowering.resolve(.states, try requiredField(root.items, "initial_state", context));
    metadata.profile = try lowering.resolve(.platforms, try requiredField(root.items, "profile", context));
    var tables: s.Tables = .{};
    inline for (std.meta.fields(s.Tables), 0..) |f, i| {
        const table: s.Table = @enumFromInt(i);
        if (comptime table != .blob and table != .string_data) {
            const values = try a.alloc(s.Record(table), counts[i]);
            var next: u32 = 0;
            for (records.items) |record| if (record.table == table) {
                if (context) |c| {
                    c.record(record.anchor, record.table, record.index);
                    if (comptime @typeInfo(s.Record(table)) == .@"struct") {
                        if (@hasField(s.Record(table), "key")) c.sink.object_id = s.music.hashName(try identifier(try requiredField(record.fields.items, "id", context))) catch null;
                    }
                }
                values[next] = try lowering.record(table, record.fields.items, next);
                next += 1;
            };
            @field(tables, f.name) = values;
        }
    }
    tables.strings = try lowering.strings.toOwnedSlice(a);
    tables.string_data = try lowering.string_data.toOwnedSlice(a);
    return .{ .arena = arena, .metadata = metadata, .tables = tables, .authors = try authors.toOwnedSlice(a), .sound_sources = try lowering.sound_sources.toOwnedSlice(a) };
}
fn capabilities(value: Value) CompileError!u64 {
    const array = switch (value) {
        .array => |values| values,
        else => return error.InvalidFieldType,
    };
    var bits: u64 = 0;
    for (array) |entry| {
        const cap = std.meta.stringToEnum(s.Capability, try stringValue(entry)) orelse return error.UnsupportedCapability;
        if (bits & s.bit(cap) != 0) return error.DuplicateField;
        bits |= s.bit(cap);
    }
    return bits;
}
