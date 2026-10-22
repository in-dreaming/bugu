//! TASK-004 observability primitives. Serialization and export are control-only.
//! No scheduler or decoder results are manufactured by these primitives.
const std = @import("std");
const music = @import("music");
const capture_order = @import("sme-capture-order");
const live_semantic = @import("sme-live-semantic");
pub const schema = @import("trace_schema.zig");
pub const codec = @import("trace_codec.zig");
pub const replay = @import("replay.zig");
/// Separate bounded chunk container; legacy envelopes remain unchanged.
pub const chunks = @import("recording_chunks.zig");
pub const chunk_recording = @import("chunk_recording.zig");
pub const metrics = @import("trace_metrics.zig");
pub const Header = schema.Header;
pub const ScheduleRecord = schema.ScheduleRecord;
pub const TransactionRecord = schema.TransactionRecord;
pub const VoiceBudgetRecord = schema.VoiceBudgetRecord;
pub const PlannerRecord = schema.PlannerRecord;
pub const BusEvent = schema.BusEvent;
pub const LayerAutomationEvent = schema.LayerAutomationEvent;
pub const BusOperation = schema.BusOperation;
pub const BusTarget = schema.BusTarget;
pub const ScheduleEntry = schema.ScheduleEntry;
pub const Input = schema.Input;
pub const Error = schema.Error || codec.Error || error{ OutOfMemory, InvalidMagic, UnexpectedRecordKind };
pub const schedule_magic: [8]u8 = "SMESCH02".*;
pub const replay_magic: [8]u8 = "SMERPL02".*;
comptime {
    @setEvalBranchQuota(20_000);
    if (@sizeOf(ScheduleEntry) > schema.max_record_bytes or @sizeOf(Input) > schema.max_record_bytes) @compileError("in-memory entry bound exceeded");
    if (codec.maxSize(ScheduleEntry) > schema.max_record_bytes or codec.maxSize(Input) > schema.max_record_bytes) @compileError("record bound exceeded");
}
pub fn encode(comptime T: type, bytes: []u8, header: Header, records: []const T) Error![]const u8 {
    try header.validate();
    if (records.len > schema.max_events) return error.InvalidLength;
    if (T == Input) try replay.validateSequence(records);
    var e: codec.Encoder = .{ .bytes = bytes };
    try e.put(if (T == Input) replay_magic else if (canonicalType(T) == ScheduleEntry) schedule_magic else @compileError("unsupported recording"));
    try e.put(header);
    try e.put(@as(u32, @intCast(records.len)));
    for (records) |record| {
        try record.validate();
        var scratch: [schema.max_record_bytes]u8 = undefined;
        var row: codec.Encoder = .{ .bytes = &scratch };
        try row.put(canonicalRecord(T, record));
        try e.put(@as(u16, @intCast(row.offset)));
        if (e.bytes.len - e.offset < row.offset) return error.BufferTooSmall;
        @memcpy(e.bytes[e.offset..][0..row.offset], scratch[0..row.offset]);
        e.offset += row.offset;
    }
    return e.bytes[0..e.offset];
}
pub fn Decoded(comptime T: type) type {
    return struct {
        header: Header,
        records: []T,
        allocator: std.mem.Allocator,
        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.records);
            self.* = undefined;
        }
    };
}
pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8, event_limit: u32) !Decoded(T) {
    if (event_limit > schema.max_events) return error.InvalidLength;
    var d: codec.Decoder = .{ .bytes = bytes };
    const magic = try d.get([8]u8);
    const expected = if (T == Input) replay_magic else if (canonicalType(T) == ScheduleEntry) schedule_magic else @compileError("unsupported recording");
    if (!std.mem.eql(u8, &magic, &expected)) return error.InvalidMagic;
    const header = try d.get(Header);
    try header.validate();
    const count = try d.get(u32);
    if (count > event_limit or count > (bytes.len - d.offset) / 2) return error.InvalidLength;
    // Validate every length and record before allocating caller-sized storage.
    // Malformed short rows cannot force a large allocation under a high limit.
    var preflight = d;
    for (0..count) |_| {
        const n = try preflight.get(u16);
        if (n > schema.max_record_bytes or n > bytes.len - preflight.offset) return error.InvalidLength;
        var row: codec.Decoder = .{ .bytes = bytes[preflight.offset..][0..n] };
        const record = try projectRecord(T, try row.get(canonicalType(T)));
        try row.finish();
        try record.validate();
        preflight.offset += n;
    }
    try preflight.finish();
    const records = try allocator.alloc(T, count);
    errdefer allocator.free(records);
    for (records) |*record| {
        const n = try d.get(u16);
        if (n > schema.max_record_bytes or n > bytes.len - d.offset) return error.InvalidLength;
        var row: codec.Decoder = .{ .bytes = bytes[d.offset..][0..n] };
        record.* = try projectRecord(T, try row.get(canonicalType(T)));
        try row.finish();
        try record.validate();
        d.offset += n;
    }
    try d.finish();
    if (T == Input) try replay.validateSequence(records);
    return .{ .header = header, .records = records, .allocator = allocator };
}
pub fn scheduleEnvelope(header: Header, payload: []const u8) music.ScheduleTraceV2 {
    return .{ .header = header.base(), .payload = payload };
}
pub fn inputEnvelope(header: Header, payload: []const u8) music.ReplayInputV2 {
    return .{ .header = header.base(), .payload = payload };
}
pub fn decodeInputEnvelope(allocator: std.mem.Allocator, envelope: music.ReplayInputV2, event_limit: u32) !Decoded(Input) {
    var decoded = try decode(Input, allocator, envelope.payload, event_limit);
    errdefer decoded.deinit();
    if (!decoded.header.matchesBase(envelope.header)) return error.InvalidHeader;
    return decoded;
}
pub fn decodeScheduleEnvelope(allocator: std.mem.Allocator, envelope: music.ScheduleTraceV2, event_limit: u32) !Decoded(ScheduleRecord) {
    var decoded = try decode(ScheduleRecord, allocator, envelope.payload, event_limit);
    errdefer decoded.deinit();
    if (!decoded.header.matchesBase(envelope.header)) return error.InvalidHeader;
    return decoded;
}
/// Single producer / single consumer. Producer writes records before release
/// publication; consumer acquires before reading, then releases reuse. No retries.
/// A disabled or overflowed sink makes evidence incomplete, never changes decisions.
pub const QueuePush = struct {
    enabled: bool,
    head_before: ?u64 = null,
    tail_acquired: ?u64 = null,
    head_after: ?u64 = null,
    accepted: bool = false,
};
pub const QueuePop = struct { tail_before: u64, head_acquired: u64, tail_after: u64, present: bool };
pub const QueueObservation = union(enum) { push: QueuePush, pop: QueuePop };
pub const QueueSite = enum { group_event_space, group_event_publish, group_event_pop, group_event_return };
pub const QueueCheckpoint = struct {
    site: QueueSite,
    edge: enum { before, after },
    index: u64 = 0,
    generation: u64,
    value: u64 = 0,
};
pub const QueueHooks = struct { context: *anyopaque, epoch: u64, checkpoint: *const fn (*anyopaque, QueueCheckpoint) void };
/// Attached only at a producer/consumer safe point. These callbacks are bounded
/// capture fan-out; the separate offline hooks are never installed by live RT.
pub const QueueSink = struct {
    context: *anyopaque,
    epoch: u64,
    emit: *const fn (*anyopaque, u64, QueueObservation) void,
    invalidate: *const fn (*anyopaque) void,
};
pub fn Ring(comptime T: type, comptime capacity: usize) type {
    if (capacity < 2 or capacity > 65536 or !std.math.isPowerOfTwo(capacity)) @compileError("ring capacity must be power-of-two 2..65536");
    comptime assertRenderValue(T);
    if (@sizeOf(T) > schema.max_record_bytes) @compileError("render record exceeds bound");
    return struct {
        const Self = @This();
        storage: [capacity]T = undefined,
        head: std.atomic.Value(u64) = .init(0),
        tail: std.atomic.Value(u64) = .init(0),
        lost: std.atomic.Value(u64) = .init(0),
        high_water: std.atomic.Value(u64) = .init(0),
        incomplete: std.atomic.Value(bool) = .init(false),
        enabled: std.atomic.Value(bool) = .init(true),
        reset_epoch: std.atomic.Value(u64) = .init(1),
        public_causal_sink: ?QueueSink = null,
        offline_causal_hooks: ?QueueHooks = null,
        /// Private partial-order prerequisite. Only the real group-event queue
        /// attaches these: its SPSC producer is Render and consumer is Control.
        /// Generic Ring users do not acquire roles from the element type or
        /// method name. The lifecycle owner validates the genuine role threads,
        /// pins each collector, and installs index 0 with the actual reset_epoch
        /// as generation while BOTH queue roles and the collector consumer are
        /// quiescent. Bindings and epoch remain immutable until joined detach.
        /// No allocation, callbacks, or extra queue-state reads when attached;
        /// default-null costs only the relevant optional-binding check per point.
        order_render: ?capture_order.Binding = null,
        order_control: ?capture_order.Binding = null,
        /// Explicit semantic Host only, pinned while both actual queue roles
        /// can run. Native reset/loss still invalidates canonical completeness.
        live_semantic_hooks: ?live_semantic.Binding = null,
        fn queuePoint(self: *Self, site: QueueSite, edge: @FieldType(QueueCheckpoint, "edge"), value: u64) void {
            const order_site: capture_order.Site = switch (site) {
                .group_event_space => .group_event_space,
                .group_event_publish => .group_event_publish,
                .group_event_pop => .group_event_pop,
                .group_event_return => .group_event_return,
            };
            const order_edge: capture_order.Edge = switch (edge) {
                .before => .before,
                .after => .after,
            };
            // The original load has not happened at a before-load checkpoint.
            // A real observed zero remains present. Known writes are present on
            // both sides; never reread head/tail to reconstruct an observation.
            const order_value: ?u64 = if (edge == .before and
                (site == .group_event_space or site == .group_event_pop)) null else value;
            switch (site) {
                .group_event_space, .group_event_publish => if (self.order_render) |binding| {
                    if (binding.index != 0 or binding.generation == 0) {
                        binding.collector.invalidateBinding();
                    } else binding.emitFor(.render, order_site, order_edge, order_value);
                },
                .group_event_pop, .group_event_return => if (self.order_control) |binding| {
                    if (binding.index != 0 or binding.generation == 0) {
                        binding.collector.invalidateBinding();
                    } else binding.emitFor(.control, order_site, order_edge, order_value);
                },
            }
            if (self.live_semantic_hooks) |hooks| hooks.point(hooks.context, .{
                .role = switch (site) {
                    .group_event_space, .group_event_publish => .render,
                    .group_event_pop, .group_event_return => .control,
                },
                .site = order_site,
                .edge = order_edge,
                .generation = self.reset_epoch.load(.monotonic),
                .value = order_value,
            });
            // Independent legacy offline path: its original values (including
            // before-load zero placeholders) and callback order stay unchanged.
            if (self.offline_causal_hooks) |hooks| hooks.checkpoint(hooks.context, .{ .site = site, .edge = edge, .generation = hooks.epoch, .value = value });
        }
        fn queueObserve(self: *Self, value: QueueObservation) void {
            if (self.public_causal_sink) |sink| sink.emit(sink.context, sink.epoch, value);
        }
        fn queueInvalidate(self: *Self) void {
            // Atomic sticky invalidation is safe from either SPSC role. It
            // neither resets the borrowed lane nor changes queue outcomes.
            if (self.order_render) |binding| binding.collector.invalidateSource();
            if (self.order_control) |binding| binding.collector.invalidateSource();
            if (self.public_causal_sink) |sink| sink.invalidate(sink.context);
        }
        pub fn push(self: *Self, value: T) bool {
            const enabled = self.enabled.load(.monotonic);
            if (!enabled) {
                self.incomplete.store(true, .release);
                self.queueObserve(.{ .push = .{ .enabled = enabled } });
                self.queueInvalidate();
                return false;
            }
            const head = self.head.load(.monotonic);
            self.queuePoint(.group_event_space, .before, 0);
            const tail = self.tail.load(.acquire);
            self.queuePoint(.group_event_space, .after, tail);
            if (head -% tail >= capacity) {
                self.lost.store(self.lost.load(.monotonic) +| 1, .monotonic);
                self.incomplete.store(true, .release);
                self.queueObserve(.{ .push = .{ .enabled = enabled, .head_before = head, .tail_acquired = tail } });
                self.queueInvalidate();
                return false;
            }
            self.storage[@intCast(head & (capacity - 1))] = value;
            const occupancy = head -% tail + 1;
            if (occupancy > self.high_water.load(.monotonic)) self.high_water.store(occupancy, .monotonic);
            const after = head +% 1;
            self.queuePoint(.group_event_publish, .before, after);
            self.head.store(after, .release);
            self.queuePoint(.group_event_publish, .after, after);
            self.queueObserve(.{ .push = .{ .enabled = enabled, .head_before = head, .tail_acquired = tail, .head_after = after, .accepted = true } });
            if (head == std.math.maxInt(u64)) self.queueInvalidate();
            return true;
        }
        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);
            self.queuePoint(.group_event_pop, .before, 0);
            const head = self.head.load(.acquire);
            self.queuePoint(.group_event_pop, .after, head);
            if (tail == head) {
                self.queueObserve(.{ .pop = .{ .tail_before = tail, .head_acquired = head, .tail_after = tail, .present = false } });
                return null;
            }
            const value = self.storage[@intCast(tail & (capacity - 1))];
            const after = tail +% 1;
            self.queuePoint(.group_event_return, .before, after);
            self.tail.store(after, .release);
            self.queuePoint(.group_event_return, .after, after);
            self.queueObserve(.{ .pop = .{ .tail_before = tail, .head_acquired = head, .tail_after = after, .present = true } });
            if (tail == std.math.maxInt(u64)) self.queueInvalidate();
            return value;
        }
        pub fn setEnabled(self: *Self, enabled: bool) void {
            self.enabled.store(enabled, .release);
            if (!enabled) {
                self.incomplete.store(true, .release);
                self.queueInvalidate();
            }
        }
        /// Host must stop/join BOTH producer and consumer before reset. Never call
        /// from render, nor use it to hide lost evidence in an ongoing recording.
        /// A prerequisite borrow must also be detached after its collector's
        /// consumer is quiescent. Reject rather than silently reuse an attached
        /// identity or clear borrowed pointers; the caller must attach a fresh,
        /// validated capture with the new actual epoch after reset.
        pub fn resetQuiescent(self: *Self, epoch: u64) !void {
            if (self.order_render != null or self.order_control != null) return error.InvalidState;
            if (epoch <= self.reset_epoch.load(.monotonic)) return error.InvalidEvent;
            self.queueInvalidate();
            self.head.store(0, .monotonic);
            self.tail.store(0, .monotonic);
            self.lost.store(0, .monotonic);
            self.high_water.store(0, .monotonic);
            self.incomplete.store(!self.enabled.load(.monotonic), .monotonic);
            self.reset_epoch.store(epoch, .release);
        }
        pub fn requireComplete(self: *const Self) !void {
            if (self.incomplete.load(.acquire)) return error.IncompleteTrace;
        }
    };
}
pub const RenderRing = Ring(ScheduleEntry, schema.default_ring_capacity);
/// JSON has no diagnostic object or free-form environment fields. The supplied
/// diagnostics are deliberately excluded, including in nested event payloads.
/// Every field in Header/Input/ScheduleRecord is classified PUBLIC by the schema.
pub fn exportJson(comptime T: type, allocator: std.mem.Allocator, header: Header, records: []const T, diagnostics: schema.Diagnostic) ![]u8 {
    _ = comptime canonicalType(T);
    _ = diagnostics;
    try header.validate();
    if (records.len > schema.max_events) return error.InvalidLength;
    for (records) |record| try record.validate();
    if (T == Input) try replay.validateSequence(records);
    const canonical = try allocator.alloc(canonicalType(T), records.len);
    defer allocator.free(canonical);
    for (records, canonical) |record, *out| out.* = canonicalRecord(T, record);
    return std.json.Stringify.valueAlloc(allocator, .{ .header = header, .records = canonical }, .{ .whitespace = .indent_2, .emit_strings_as_arrays = true, .emit_nonportable_numbers_as_strings = true });
}
pub fn importJson(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8, event_limit: u32) !Decoded(T) {
    _ = comptime canonicalType(T);
    if (event_limit > schema.max_events) return error.InvalidLength;
    try preflightJson(T, bytes, event_limit);
    const Document = struct { header: Header, records: []canonicalType(T) };
    // Reject unknown fields rather than accidentally preserving private payloads.
    const parsed = try std.json.parseFromSlice(Document, allocator, bytes, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try parsed.value.header.validate();
    if (parsed.value.records.len > event_limit) return error.InvalidLength;
    for (parsed.value.records) |record| {
        try record.validate();
        _ = try projectRecord(T, record);
    }
    if (T == Input) try replay.validateSequence(parsed.value.records);
    const records = try allocator.alloc(T, parsed.value.records.len);
    errdefer allocator.free(records);
    for (parsed.value.records, records) |record, *out| out.* = try projectRecord(T, record);
    return .{ .header = parsed.value.header, .records = records, .allocator = allocator };
}
/// Lossless machine CSV: schema + row kind + ordinal + canonical lowercase hex.
/// The header row carries full metadata; each record row carries the same LE
/// bytes as binary. No ambiguous locale formatting, quoting or string leakage.
pub fn exportCsv(comptime T: type, allocator: std.mem.Allocator, header: Header, records: []const T, diagnostics: schema.Diagnostic) ![]u8 {
    _ = comptime canonicalType(T);
    _ = diagnostics;
    try header.validate();
    if (records.len > schema.max_events) return error.InvalidLength;
    if (T == Input) try replay.validateSequence(records);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("schema,row,index,canonical_le_hex\n");
    var scratch: [schema.max_record_bytes]u8 = undefined;
    var e: codec.Encoder = .{ .bytes = &scratch };
    try e.put(header);
    const name = if (T == Input) "ReplayInputV2" else "ScheduleTraceV2";
    try output.writer.print("{s},header,0,{x}\n", .{ name, scratch[0..e.offset] });
    for (records, 0..) |record, i| {
        try record.validate();
        e.offset = 0;
        try e.put(canonicalRecord(T, record));
        try output.writer.print("{s},record,{d},{x}\n", .{ name, i, scratch[0..e.offset] });
    }
    return output.toOwnedSlice();
}

/// Before JSON allocates document storage, use a fixed-stack scanner to bound
/// nesting and count record objects. Escaped field names are rejected by this
/// strict canonical importer (our exporter never emits them).
fn preflightJson(comptime T: type, bytes: []const u8, event_limit: u32) !void {
    // 64 bytes of textual expansion per binary byte comfortably covers decimal
    // integer arrays, field names and pretty whitespace in our frozen schemas.
    const budget: u64 = 32768 + @as(u64, event_limit) * schema.max_record_bytes * 64;
    if (bytes.len > budget) return error.InvalidLength;
    var stack: [1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&stack);
    var scanner = std.json.Scanner.initCompleteInput(allocator.allocator(), bytes);
    defer scanner.deinit();
    var depth: u32 = 0;
    var records_depth: ?u32 = null;
    var expect_records = false;
    var records_seen = false;
    var header_fields: u64 = 0;
    var header_depth: ?u32 = null;
    var expect_header = false;
    var header_seen = false;
    var count: u32 = 0;
    while (true) {
        const token = try scanner.next();
        switch (token) {
            .object_begin => {
                if (expect_header) {
                    if (header_seen or depth != 1) return error.InvalidEvent;
                    header_seen = true;
                    header_depth = depth + 1;
                    expect_header = false;
                }
                if (records_depth) |rd| if (depth == rd) {
                    count += 1;
                    if (count > event_limit) return error.InvalidLength;
                };
                depth += 1;
            },
            .array_begin => {
                depth += 1;
                if (expect_records) {
                    if (records_seen) return error.InvalidEvent;
                    records_seen = true;
                    records_depth = depth;
                    expect_records = false;
                }
            },
            .object_end, .array_end => {
                if (header_depth) |hd| if (depth == hd) {
                    header_depth = null;
                };
                if (records_depth) |rd| if (depth == rd) {
                    records_depth = null;
                };
                depth -= 1;
            },
            .string => |text| {
                if (depth == 1 and std.mem.eql(u8, text, "records")) expect_records = true;
                if (depth == 1 and std.mem.eql(u8, text, "header")) expect_header = true;
                if (header_depth) |hd| if (depth == hd) {
                    inline for (std.meta.fields(Header), 0..) |field, i| {
                        if (std.mem.eql(u8, text, field.name)) header_fields |= @as(u64, 1) << i;
                    }
                };
            },
            .number => |text| try requireDecimalInteger(text),
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => return error.InvalidEvent,
            .end_of_document => break,
            else => {},
        }
        if (depth > 16) return error.InvalidLength;
    }
    if (!records_seen) return error.InvalidEvent;
    // Reuse the same fixed storage for type-directed validation. Every integer
    // slot is checked regardless of its first character; std.json never gets
    // an opportunity to coerce decimal/exponent strings through floating point.
    scanner.deinit();
    allocator.reset();
    scanner = std.json.Scanner.initCompleteInput(allocator.allocator(), bytes);
    const Document = struct { header: Header, records: []canonicalType(T) };
    try validateJsonValue(Document, &scanner, 0, event_limit);
    if (try scanner.next() != .end_of_document) return error.TrailingBytes;
    if (!header_seen or header_fields != (@as(u64, 1) << std.meta.fields(Header).len) - 1) return error.MissingField;
}

fn assertRenderValue(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .bool, .@"enum", .void => {},
        .array => |v| assertRenderValue(v.child),
        .optional => |v| assertRenderValue(v.child),
        .@"struct" => |v| for (v.fields) |f| assertRenderValue(f.type),
        .@"union" => |v| for (v.fields) |f| assertRenderValue(f.type),
        else => @compileError("render rings accept owned fixed numeric values only"),
    }
}

fn requireDecimalInteger(text: []const u8) !void {
    if (text.len == 0) return error.InvalidNumber;
    const digits = if (text[0] == '-') text[1..] else text;
    if (digits.len == 0) return error.InvalidNumber;
    for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidNumber;
}

/// Allocation-free validation against the exact allowed wire types. Struct
/// fields must be explicit, including fields with Zig convenience defaults.
fn validateJsonValue(comptime T: type, scanner: *std.json.Scanner, depth: u32, event_limit: u32) anyerror!void {
    if (depth > 16) return error.InvalidLength;
    switch (@typeInfo(T)) {
        .int => {
            const token = try scanner.next();
            const text = switch (token) {
                .number, .string => |v| v,
                else => return error.UnexpectedToken,
            };
            try requireDecimalInteger(text);
            _ = try std.fmt.parseInt(T, text, 10);
        },
        .bool => switch (try scanner.next()) {
            .true, .false => {},
            else => return error.UnexpectedToken,
        },
        .@"enum" => |e| {
            const token = try scanner.next();
            const text = switch (token) {
                .number, .string => |v| v,
                else => return error.UnexpectedToken,
            };
            if (token == .string and std.meta.stringToEnum(T, text) != null) return;
            try requireDecimalInteger(text);
            const raw = try std.fmt.parseInt(e.tag_type, text, 10);
            inline for (e.fields) |f| if (raw == f.value) return;
            return error.InvalidEnum;
        },
        .optional => |o| {
            if (try scanner.peekNextTokenType() == .null) {
                _ = try scanner.next();
            } else try validateJsonValue(o.child, scanner, depth + 1, event_limit);
        },
        .array => |arr| {
            if (try scanner.next() != .array_begin) return error.UnexpectedToken;
            for (0..arr.len) |_| try validateJsonValue(arr.child, scanner, depth + 1, event_limit);
            if (try scanner.next() != .array_end) return error.InvalidLength;
        },
        .pointer => |ptr| {
            if (ptr.size != .slice or ptr.child != Input and ptr.child != ScheduleEntry) @compileError("unexpected JSON slice");
            if (try scanner.next() != .array_begin) return error.UnexpectedToken;
            var count: u32 = 0;
            while (try scanner.peekNextTokenType() != .array_end) {
                if (count >= event_limit) return error.InvalidLength;
                try validateJsonValue(ptr.child, scanner, depth + 1, event_limit);
                count += 1;
            }
            _ = try scanner.next();
        },
        .@"struct" => |info| {
            if (try scanner.next() != .object_begin) return error.UnexpectedToken;
            var seen: [info.fields.len]bool = @splat(false);
            while (try scanner.peekNextTokenType() != .object_end) {
                const key = switch (try scanner.next()) {
                    .string => |v| v,
                    else => return error.UnexpectedToken,
                };
                var matched = false;
                inline for (info.fields, 0..) |field, i| {
                    if (std.mem.eql(u8, key, field.name)) {
                        if (seen[i]) return error.DuplicateField;
                        seen[i] = true;
                        matched = true;
                        try validateJsonValue(field.type, scanner, depth + 1, event_limit);
                    }
                }
                if (!matched) return error.UnknownField;
            }
            _ = try scanner.next();
            for (seen) |present| if (!present) return error.MissingField;
        },
        .@"union" => |info| {
            if (try scanner.next() != .object_begin) return error.UnexpectedToken;
            const key = switch (try scanner.next()) {
                .string => |v| v,
                else => return error.UnexpectedToken,
            };
            var matched = false;
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, key, field.name)) {
                    matched = true;
                    try validateJsonValue(field.type, scanner, depth + 1, event_limit);
                }
            }
            if (!matched) return error.UnknownField;
            if (try scanner.next() != .object_end) return error.UnexpectedToken;
        },
        .void => {
            if (try scanner.next() != .object_begin or try scanner.next() != .object_end) return error.UnexpectedToken;
        },
        else => @compileError("unexpected JSON type"),
    }
}

/// One schedule wire for both mixed entries and homogeneous convenience APIs.
pub fn canonicalType(comptime T: type) type {
    if (T == Input) return Input;
    if (T == ScheduleRecord or T == TransactionRecord or T == VoiceBudgetRecord or T == PlannerRecord or T == BusEvent or T == LayerAutomationEvent or T == ScheduleEntry) return ScheduleEntry;
    @compileError("record type is not in the export/import allowlist");
}
fn canonicalRecord(comptime T: type, record: T) canonicalType(T) {
    if (T == ScheduleRecord) return .{ .event = record };
    if (T == TransactionRecord) return .{ .transaction = record };
    if (T == VoiceBudgetRecord) return .{ .voice_budget = record };
    if (T == PlannerRecord) return .{ .planner_candidate = record };
    if (T == BusEvent) return .{ .bus = record };
    if (T == LayerAutomationEvent) return .{ .layer_automation = record };
    return record;
}
fn projectRecord(comptime T: type, record: canonicalType(T)) Error!T {
    if (T == PlannerRecord) {
        if (record != .planner_candidate) return error.UnexpectedRecordKind;
        return record.planner_candidate;
    }
    if (T == ScheduleRecord) {
        if (record != .event) return error.UnexpectedRecordKind;
        return record.event;
    }
    if (T == LayerAutomationEvent) {
        if (record != .layer_automation) return error.UnexpectedRecordKind;
        return record.layer_automation;
    }
    if (T == BusEvent) {
        if (record != .bus) return error.UnexpectedRecordKind;
        return record.bus;
    }
    if (T == VoiceBudgetRecord) {
        if (record != .voice_budget) return error.UnexpectedRecordKind;
        return record.voice_budget;
    }
    if (T == TransactionRecord) {
        if (record != .transaction) return error.UnexpectedRecordKind;
        return record.transaction;
    }
    return record;
}
pub fn decodeScheduleEntriesEnvelope(allocator: std.mem.Allocator, envelope: music.ScheduleTraceV2, event_limit: u32) !Decoded(ScheduleEntry) {
    var decoded = try decode(ScheduleEntry, allocator, envelope.payload, event_limit);
    errdefer decoded.deinit();
    if (!decoded.header.matchesBase(envelope.header)) return error.InvalidHeader;
    return decoded;
}

pub const chunk_pcm_proof = @import("chunk_pcm_proof.zig");
