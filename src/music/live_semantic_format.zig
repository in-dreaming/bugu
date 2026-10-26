//! Profile 9's bounded, owned transport and explicit little-endian envelope.
//! A framing seal proves neither engine admission nor genuine native cleanup.
//! The Host must separately validate the finite semantic schema and lifecycle.
//! No legacy profile, test fixture, runtime, IO, or allocator is imported here.
const std = @import("std");
pub const compilation_mode = @import("builtin").mode;
pub const IntegrityHash = @import("live_integrity_hash.zig");
pub const IntegrityHasher = IntegrityHash.Sha256;
const Sha256 = IntegrityHasher;

pub const profile_id: u16 = 9;
// v4 adds explicit native job-scan eligibility INPUT. Older tapes require
// their original matching tools; missing inputs are never inferred/upgraded.
pub const wire_version: u16 = 4;
pub const magic = "SMELSB01";
pub const header_size: usize = 192;
pub const frame_header_size: usize = 64;
pub const trailer_size: usize = 184;
pub const max_payload: usize = 64 * 1024;
pub const lane_byte_capacity: usize = 4 * 1024 * 1024;
pub const lane_record_capacity: usize = 16384;
pub const max_file_bytes: usize = 512 * 1024 * 1024;
pub const max_capture_bytes: usize = 64 * 1024 * 1024;
pub const Hash = [32]u8;
pub const Role = enum(u8) { control = 0, worker = 1, render = 2, ui = 3 };
pub const role_count = 4;
pub const closed_role_mask: u8 = 15;
pub const Class = enum(u8) { input = 0, reference = 1 };
/// Must be a bounded, pure finite-schema check. It runs on the producer.
pub const Validator = *const fn (family: u16, class: Class) bool;
pub const Identity = struct { build: Hash, bank: Hash, config: Hash, source: Hash };
pub const Error = @import("sme-live-wire-encoder").Error;
pub const Poison = enum(u8) {
    none = 0,
    overflow = 1,
    counter = 2,
    order = 3,
    unsupported = 4,
    closed = 5,
    consumer = 6,
};

pub fn hash(bytes: []const u8) Hash {
    var out: Hash = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}
fn index(role: Role) usize {
    return @intFromEnum(role);
}
fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.CounterOverflow;
}

/// Owned native producer bytes. Padding may exist here, but is never a wire
/// representation: the consumer must explicitly encode the fields it needs.
pub const NativeRecord = struct {
    role: Role,
    ordinal: u64,
    family: u16,
    class: Class,
    bytes: []const u8,
    first_len: usize,
    pub fn first(self: NativeRecord) []const u8 {
        return self.bytes[0..self.first_len];
    }
    pub fn second(self: NativeRecord) []const u8 {
        return self.bytes[self.first_len..];
    }
};
const Descriptor = struct {
    ordinal: u64,
    byte_start: u64,
    length: u32,
    first_len: u32,
    family: u16,
    class: Class,
};
pub const LaneStats = struct {
    produced: u64,
    consumed: u64,
    queued_bytes: u64,
    peak_bytes: u64,
    peak_records: u64,
    poison: Poison,
    closed: bool,
};

/// Exactly one producer and one consumer per lane. Its caller must allocate it
/// before attachment. init initializes metadata in place, not 4 MiB of bytes.
/// push performs only bounded checks, atomics, one owned copy and publication.
pub const Lane = struct {
    storage: [lane_byte_capacity]u8 = undefined,
    descriptors: [lane_record_capacity]Descriptor = undefined,
    role: Role = undefined,
    validator: Validator = undefined,
    byte_write: u64 = 0, // producer only
    byte_read: std.atomic.Value(u64) = .init(0),
    record_write: std.atomic.Value(u64) = .init(0),
    record_read: std.atomic.Value(u64) = .init(0),
    poison_code: std.atomic.Value(u8) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    peak_bytes: std.atomic.Value(u64) = .init(0),
    peak_records: std.atomic.Value(u64) = .init(0),

    pub fn init(self: *Lane, role: Role, validator: Validator) void {
        self.role = role;
        self.validator = validator;
        self.byte_write = 0;
        self.byte_read = .init(0);
        self.record_write = .init(0);
        self.record_read = .init(0);
        self.poison_code = .init(0);
        self.closed = .init(false);
        self.peak_bytes = .init(0);
        self.peak_records = .init(0);
    }
    pub fn poison(self: *Lane, reason: Poison) void {
        if (reason == .none) return;
        // First failure wins. A failed CAS means a failure is already sticky;
        // there is deliberately no retry loop on an RT producer.
        _ = self.poison_code.cmpxchgStrong(0, @intFromEnum(reason), .release, .monotonic);
    }
    pub fn failure(self: *const Lane) Poison {
        return @enumFromInt(self.poison_code.load(.acquire));
    }
    pub fn push(self: *Lane, family: u16, class: Class, first: []const u8, second: []const u8) bool {
        if (self.failure() != .none) return false;
        if (self.closed.load(.acquire)) {
            self.poison(.closed);
            return false;
        }
        if (!self.validator(family, class)) {
            self.poison(.unsupported);
            return false;
        }
        if (first.len > max_payload or second.len > max_payload - first.len) {
            self.poison(.overflow);
            return false;
        }
        const length = first.len + second.len;
        const written = self.record_write.load(.monotonic);
        const consumed = self.record_read.load(.acquire);
        const bytes_consumed = self.byte_read.load(.acquire);
        if (consumed > written or bytes_consumed > self.byte_write) {
            self.poison(.order);
            return false;
        }
        const records_used = written - consumed;
        const bytes_used = self.byte_write - bytes_consumed;
        if (records_used >= lane_record_capacity or bytes_used > lane_byte_capacity or length > lane_byte_capacity - bytes_used) {
            self.poison(.overflow);
            return false;
        }
        const next_record = add(written, 1) catch {
            self.poison(.counter);
            return false;
        };
        const next_byte = add(self.byte_write, length) catch {
            self.poison(.counter);
            return false;
        };
        self.copyIn(self.byte_write, first);
        self.copyIn(self.byte_write + first.len, second);
        self.descriptors[@intCast(written % lane_record_capacity)] = .{
            .ordinal = next_record,
            .byte_start = self.byte_write,
            .length = @intCast(length),
            .first_len = @intCast(first.len),
            .family = family,
            .class = class,
        };
        self.byte_write = next_byte;
        self.peak_bytes.store(@max(self.peak_bytes.load(.monotonic), bytes_used + length), .monotonic);
        self.peak_records.store(@max(self.peak_records.load(.monotonic), records_used + 1), .monotonic);
        self.record_write.store(next_record, .release);
        return true;
    }
    fn copyIn(self: *Lane, position: u64, bytes: []const u8) void {
        const start: usize = @intCast(position % lane_byte_capacity);
        const first = @min(bytes.len, lane_byte_capacity - start);
        @memcpy(self.storage[start..][0..first], bytes[0..first]);
        @memcpy(self.storage[0 .. bytes.len - first], bytes[first..]);
    }
    /// Returned slices borrow scratch until the caller reuses it. Scratch must
    /// hold the next whole native record. An undersized scratch does not pop.
    pub fn pop(self: *Lane, scratch: []u8) Error!?NativeRecord {
        if (self.failure() != .none) return error.Poisoned;
        const consumed = self.record_read.load(.monotonic);
        const written = self.record_write.load(.acquire);
        if (consumed > written or written - consumed > lane_record_capacity) {
            self.poison(.order);
            return error.InvalidOrder;
        }
        if (consumed == written) return null;
        const d = self.descriptors[@intCast(consumed % lane_record_capacity)];
        const next_record = add(consumed, 1) catch {
            self.poison(.counter);
            return error.CounterOverflow;
        };
        const bytes_consumed = self.byte_read.load(.monotonic);
        if (d.ordinal != next_record or d.byte_start != bytes_consumed or d.length > max_payload or d.first_len > d.length) {
            self.poison(.order);
            return error.InvalidOrder;
        }
        if (!self.validator(d.family, d.class)) {
            self.poison(.unsupported);
            return error.UnsupportedFamily;
        }
        if (scratch.len < d.length) return error.BufferTooSmall;
        const next_byte = add(bytes_consumed, d.length) catch {
            self.poison(.counter);
            return error.CounterOverflow;
        };
        const start: usize = @intCast(bytes_consumed % lane_byte_capacity);
        const first = @min(d.length, lane_byte_capacity - start);
        @memcpy(scratch[0..first], self.storage[start..][0..first]);
        @memcpy(scratch[first..d.length], self.storage[0 .. d.length - first]);
        self.byte_read.store(next_byte, .release);
        self.record_read.store(next_record, .release);
        return .{ .role = self.role, .ordinal = d.ordinal, .family = d.family, .class = d.class, .bytes = scratch[0..d.length], .first_len = d.first_len };
    }
    /// Only after the producer's genuine native join/exclusion. This flag is
    /// not a join implementation or a substitute for host lifetime evidence.
    pub fn closeAfterJoin(self: *Lane) void {
        self.closed.store(true, .release);
    }
    /// Call after producer exclusion; byte_write is producer-owned, non-atomic.
    pub fn finalStats(self: *const Lane) LaneStats {
        const produced = self.record_write.load(.acquire);
        const consumed = self.record_read.load(.acquire);
        return .{ .produced = produced, .consumed = consumed, .queued_bytes = self.byte_write - self.byte_read.load(.acquire), .peak_bytes = self.peak_bytes.load(.monotonic), .peak_records = self.peak_records.load(.monotonic), .poison = self.failure(), .closed = self.closed.load(.acquire) };
    }
};

pub const Capture = struct {
    lanes: [role_count]Lane = undefined,
    pub fn init(self: *Capture, validator: Validator) void {
        self.lanes[0].init(.control, validator);
        self.lanes[1].init(.worker, validator);
        self.lanes[2].init(.render, validator);
        self.lanes[3].init(.ui, validator);
    }
    pub fn lane(self: *Capture, role: Role) *Lane {
        return &self.lanes[index(role)];
    }
    pub fn healthy(self: *const Capture) bool {
        for (&self.lanes) |*l| if (l.failure() != .none) return false;
        return true;
    }
    /// The sole consumer calls this only after genuine Control/Worker/Render joins,
    /// UI-owner exclusion, and final draining. A native failure must poison a lane before this call.
    pub fn sealFraming(self: *const Capture, writer: *Writer) Error![]const u8 {
        // Preserve the memory API: an early NotDrained query is recoverable;
        // unhealthy capture alone permanently poisons its writer here.
        if (!self.healthy()) {
            writer.poison();
            return error.Poisoned;
        }
        return writer.sealFraming(try self.sealEvidence());
    }
    /// Requires genuine producer exclusion, not merely an empty lane snapshot.
    pub fn sealEvidence(self: *const Capture) Error!SealEvidence {
        if (!self.healthy()) return error.Poisoned;
        var evidence: SealEvidence = .{ .role_counts = undefined, .closed_roles = @splat(false), .healthy = true };
        for (&self.lanes, 0..) |*l, i| {
            const stats = l.finalStats();
            if (stats.produced != stats.consumed or stats.queued_bytes != 0) return error.NotDrained;
            evidence.role_counts[i] = stats.produced;
            evidence.closed_roles[i] = stats.closed;
        }
        return evidence;
    }
};
comptime {
    if (@sizeOf(Capture) > max_capture_bytes) @compileError("Live capture exceeds admission allocation cap");
}

/// Explicit scalar methods only: no struct reflection or native padding dump.
/// For PCM use f32Bits with the raw u32 bits copied out of native storage.
pub const Encoder = @import("sme-live-wire-encoder").Encoder;
pub const Decoder = struct {
    bytes: []const u8,
    offset: usize = 0,
    pub fn int(self: *Decoder, comptime T: type) Error!T {
        if (self.offset > self.bytes.len or self.bytes.len - self.offset < @sizeOf(T)) return error.Truncated;
        const value = std.mem.readInt(T, self.bytes[self.offset..][0..@sizeOf(T)], .little);
        self.offset += @sizeOf(T);
        return value;
    }
    pub fn raw(self: *Decoder, length: usize) Error![]const u8 {
        if (self.offset > self.bytes.len or self.bytes.len - self.offset < length) return error.Truncated;
        const result = self.bytes[self.offset..][0..length];
        self.offset += length;
        return result;
    }
    pub fn f32Bits(self: *Decoder) Error!u32 {
        return self.int(u32);
    }
    pub fn finish(self: Decoder) Error!void {
        if (self.offset != self.bytes.len) return error.TrailingBytes;
    }
};

/// Caller-provided evidence concerns transport closure only. Prefer
/// Capture.sealFraming, which obtains it from the actual drained lanes.
pub const SealEvidence = struct { role_counts: [role_count]u64, closed_roles: [role_count]bool, healthy: bool };
pub const Counts = struct {
    roles: [role_count]u64 = @splat(0),
    inputs: [role_count]u64 = @splat(0),
    references: [role_count]u64 = @splat(0),
    total: u64 = 0,
    fn accept(self: *Counts, role: Role, ordinal: u64, class: Class) Error!void {
        const i = index(role);
        if (ordinal != try add(self.roles[i], 1)) return error.InvalidOrder;
        const total = try add(self.total, 1);
        const count = try add(if (class == .input) self.inputs[i] else self.references[i], 1);
        self.roles[i] = ordinal;
        self.total = total;
        if (class == .input) self.inputs[i] = count else self.references[i] = count;
    }
};

// Shared canonical encoders keep memory and streaming outputs byte-identical
// for the same declared cap and ordered event sequence.
fn encodeHeader(bytes: []u8, byte_cap: u64, identity: Identity) Error!void {
    @memset(bytes[0..header_size], 0);
    var e: Encoder = .{ .bytes = bytes[0..header_size] };
    try e.raw(magic);
    try e.int(u16, profile_id);
    try e.int(u16, wire_version);
    try e.int(u16, header_size);
    try e.int(u16, 0);
    try e.int(u64, byte_cap);
    try e.int(u32, max_payload);
    try e.int(u16, role_count);
    try e.int(u16, 0);
    try e.raw(&identity.build);
    try e.raw(&identity.bank);
    try e.raw(&identity.config);
    try e.raw(&identity.source);
    try e.raw(&hash(bytes[0..160]));
}
fn encodeFrameHeader(bytes: []u8, role: Role, ordinal: u64, family: u16, class: Class, canonical_payload: []const u8) Error!void {
    const length = frame_header_size + canonical_payload.len;
    var e: Encoder = .{ .bytes = bytes };
    try e.raw("EVT1");
    try e.int(u32, @intCast(length));
    try e.int(u8, @intFromEnum(role));
    try e.int(u8, @intFromEnum(class));
    try e.int(u16, family);
    try e.int(u32, 0);
    try e.int(u64, ordinal);
    try e.int(u32, @intCast(canonical_payload.len));
    try e.int(u32, 0);
    try e.raw(&hash(canonical_payload));
}
fn encodeTrailerPrefix(trailer: []u8, total: u64, counts: Counts) Error!void {
    @memset(trailer, 0);
    var e: Encoder = .{ .bytes = trailer };
    try e.raw("SMELEND1");
    try e.int(u8, 1);
    try e.int(u8, closed_role_mask);
    try e.int(u16, 0);
    try e.int(u32, trailer_size);
    try e.int(u64, total);
    try e.int(u64, counts.total);
    for (counts.roles) |n| try e.int(u64, n);
    for (counts.inputs) |n| try e.int(u64, n);
    for (counts.references) |n| try e.int(u64, n);
    try e.int(u64, total - trailer_size - header_size);
    try e.raw(&([_]u8{0} ** 16));
}

/// Borrowed synchronous sink, called only by the sole non-RT collector. It must
/// consume/copy the supplied bytes before returning and never retain the slice.
/// Partial writes are supported; zero progress and over-reporting are errors.
pub const StreamSink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!usize,
};
pub const StreamSeal = struct { bytes: u64, counts: Counts, hash: Hash };

/// Bounded non-RT writer. No allocator, native-role hooks, file ownership, or
/// deferred scratch borrows. Sink lifetime and durable publication belong to
/// the caller. An I/O failure leaves uncertain external bytes and permanently
/// poisons this writer; it never authorizes native-role cleanup or early free.
pub const StreamingWriter = struct {
    sink: StreamSink,
    byte_cap: u64,
    validator: Validator,
    offset: u64 = 0,
    counts: Counts = .{},
    digest: Sha256 = Sha256.init(.{}),
    failed: bool = false,
    sealed: bool = false,
    first_error: ?anyerror = null,

    pub fn init(sink: StreamSink, byte_cap: u64, identity: Identity, validator: Validator) !StreamingWriter {
        if (byte_cap < header_size + trailer_size or byte_cap > max_file_bytes) return error.InvalidLength;
        var self: StreamingWriter = .{ .sink = sink, .byte_cap = byte_cap, .validator = validator };
        var header: [header_size]u8 = undefined;
        try encodeHeader(&header, byte_cap, identity);
        try self.writeAll(&header);
        return self;
    }
    pub fn poison(self: *StreamingWriter) void {
        self.failed = true;
    }
    fn writeAll(self: *StreamingWriter, bytes: []const u8) !void {
        errdefer |err| {
            self.failed = true;
            if (self.first_error == null) self.first_error = err;
        }
        var position: usize = 0;
        while (position < bytes.len) {
            const remaining = bytes[position..];
            const written = try self.sink.write(self.sink.context, remaining);
            if (written == 0 or written > remaining.len) return error.InvalidWrite;
            self.digest.update(remaining[0..written]);
            self.offset += written;
            position += written;
        }
    }
    pub fn append(self: *StreamingWriter, role: Role, ordinal: u64, family: u16, class: Class, canonical_payload: []const u8) !void {
        if (self.sealed) return error.AlreadySealed;
        if (self.failed) return error.Poisoned;
        errdefer |err| {
            self.failed = true;
            if (self.first_error == null) self.first_error = err;
        }
        if (!self.validator(family, class)) return error.UnsupportedFamily;
        if (canonical_payload.len > max_payload) return error.InvalidLength;
        const length = frame_header_size + canonical_payload.len;
        if (self.byte_cap - self.offset < trailer_size or length > self.byte_cap - self.offset - trailer_size) return error.BufferTooSmall;
        var next_counts = self.counts;
        try next_counts.accept(role, ordinal, class);
        var header: [frame_header_size]u8 = undefined;
        try encodeFrameHeader(&header, role, ordinal, family, class, canonical_payload);
        try self.writeAll(&header);
        try self.writeAll(canonical_payload);
        self.counts = next_counts;
    }
    /// Framing only. Caller must independently flush/close and publish its file;
    /// a flush failure must not be reported as durable recording completion.
    pub fn sealFraming(self: *StreamingWriter, evidence: SealEvidence) !StreamSeal {
        if (self.sealed) return error.AlreadySealed;
        if (self.failed) return error.Poisoned;
        errdefer |err| {
            self.failed = true;
            if (self.first_error == null) self.first_error = err;
        }
        if (!evidence.healthy) return error.Poisoned;
        for (evidence.closed_roles) |closed| if (!closed) return error.Incomplete;
        if (!std.mem.eql(u64, &evidence.role_counts, &self.counts.roles)) return error.CountMismatch;
        const total = self.offset + trailer_size;
        if (total > self.byte_cap) return error.BufferTooSmall;
        var trailer: [trailer_size]u8 = undefined;
        try encodeTrailerPrefix(&trailer, total, self.counts);
        try self.writeAll(trailer[0 .. trailer_size - 32]);
        var final_digest: Hash = undefined;
        var final_state = self.digest;
        final_state.final(&final_digest);
        // The published digest excludes its own final32 bytes. The incremental
        // state after this write is never consulted again.
        try self.writeAll(&final_digest);
        self.sealed = true;
        return .{ .bytes = total, .counts = self.counts, .hash = final_digest };
    }
};

/// Sole non-RT consumer. Caller owns a finite output allocation (at most
/// 512 MiB) and must keep sealed bytes immutable for the lifetime of Readers.
pub const Writer = struct {
    bytes: []u8,
    validator: Validator,
    offset: usize = header_size,
    counts: Counts = .{},
    failed: bool = false,
    sealed: bool = false,
    pub fn init(bytes: []u8, identity: Identity, validator: Validator) Error!Writer {
        if (bytes.len < header_size + trailer_size or bytes.len > max_file_bytes) return error.InvalidLength;
        try encodeHeader(bytes[0..header_size], bytes.len, identity);
        return .{ .bytes = bytes, .validator = validator };
    }
    pub fn poison(self: *Writer) void {
        self.failed = true;
    }
    /// canonical_payload is explicitly encoded by the finite event codec, not
    /// NativeRecord.bytes. There is deliberately no native-record append API.
    pub fn append(self: *Writer, role: Role, ordinal: u64, family: u16, class: Class, canonical_payload: []const u8) Error!void {
        if (self.sealed) return error.AlreadySealed;
        if (self.failed) return error.Poisoned;
        errdefer self.failed = true;
        if (!self.validator(family, class)) return error.UnsupportedFamily;
        if (canonical_payload.len > max_payload) return error.InvalidLength;
        const length = frame_header_size + canonical_payload.len;
        if (self.bytes.len - self.offset < trailer_size or length > self.bytes.len - self.offset - trailer_size) return error.BufferTooSmall;
        var next_counts = self.counts;
        try next_counts.accept(role, ordinal, class);
        try encodeFrameHeader(self.bytes[self.offset..][0..frame_header_size], role, ordinal, family, class, canonical_payload);
        @memcpy(self.bytes[self.offset + frame_header_size ..][0..canonical_payload.len], canonical_payload);
        self.offset += length;
        self.counts = next_counts;
    }
    /// Framing complete is NOT a declaration that fresh playback succeeds.
    pub fn sealFraming(self: *Writer, evidence: SealEvidence) Error![]const u8 {
        if (self.sealed) return error.AlreadySealed;
        if (self.failed) return error.Poisoned;
        errdefer self.failed = true;
        if (!evidence.healthy) return error.Poisoned;
        for (evidence.closed_roles) |closed| if (!closed) return error.Incomplete;
        if (!std.mem.eql(u64, &evidence.role_counts, &self.counts.roles)) return error.CountMismatch;
        const total = self.offset + trailer_size;
        if (total > self.bytes.len) return error.BufferTooSmall;
        const trailer = self.bytes[self.offset..total];
        try encodeTrailerPrefix(trailer, total, self.counts);
        @memcpy(trailer[trailer_size - 32 ..], &hash(self.bytes[0 .. total - 32]));
        self.offset = total;
        self.sealed = true;
        return self.bytes[0..total];
    }
};

const WireRecord = struct { role: Role, ordinal: u64, family: u16, class: Class, bytes: []const u8, size: usize };
fn readRecord(bytes: []const u8, validator: Validator) Error!WireRecord {
    if (bytes.len < frame_header_size) return error.Truncated;
    var d: Decoder = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try d.raw(4), "EVT1")) return error.Noncanonical;
    const length = try d.int(u32);
    if (length < frame_header_size or length > frame_header_size + max_payload) return error.InvalidLength;
    if (length > bytes.len) return error.Truncated;
    const role: Role = switch (try d.int(u8)) {
        0 => .control,
        1 => .worker,
        2 => .render,
        3 => .ui,
        else => return error.Noncanonical,
    };
    const class: Class = switch (try d.int(u8)) {
        0 => .input,
        1 => .reference,
        else => return error.Noncanonical,
    };
    const family = try d.int(u16);
    if (!validator(family, class)) return error.UnsupportedFamily;
    if (try d.int(u32) != 0) return error.Noncanonical;
    const ordinal = try d.int(u64);
    const payload_length = try d.int(u32);
    if (payload_length != length - frame_header_size) return error.InvalidLength;
    if (try d.int(u32) != 0) return error.Noncanonical;
    const expected_hash = try d.raw(32);
    const payload = try d.raw(payload_length);
    if (!std.mem.eql(u8, expected_hash, &hash(payload))) return error.HashMismatch;
    return .{ .role = role, .ordinal = ordinal, .family = family, .class = class, .bytes = payload, .size = length };
}

pub const InputRecord = struct { role: Role, ordinal: u64, family: u16, bytes: []const u8 };
pub const ReferenceRecord = struct { role: Role, ordinal: u64, family: u16, bytes: []const u8 };
/// Only the preflight/admission owner holds Reader. Execution code receives an
/// InputCursor, whose erased context exposes no typed reference bytes. The
/// Reader and its immutable backing bytes must outlive both cursor types.
const SealedContext = opaque {};
pub const InputCursor = struct {
    context: *const SealedContext,
    role: Role,
    offset: usize = 0,
    pub fn next(self: *InputCursor) Error!?InputRecord {
        const reader: *const Reader = @ptrCast(@alignCast(self.context));
        const r = try reader.nextClass(&self.offset, self.role, .input) orelse return null;
        return .{ .role = r.role, .ordinal = r.ordinal, .family = r.family, .bytes = r.bytes };
    }
    pub fn finish(self: *InputCursor) Error!void {
        if (try self.next() != null) return error.TrailingBytes;
    }
};
pub const ComparisonCursor = struct {
    context: *const SealedContext,
    role: Role,
    offset: usize = 0,
    pub fn next(self: *ComparisonCursor) Error!?ReferenceRecord {
        const reader: *const Reader = @ptrCast(@alignCast(self.context));
        const r = try reader.nextClass(&self.offset, self.role, .reference) orelse return null;
        return .{ .role = r.role, .ordinal = r.ordinal, .family = r.family, .bytes = r.bytes };
    }
    pub fn finish(self: *ComparisonCursor) Error!void {
        if (try self.next() != null) return error.TrailingBytes;
    }
};
pub const Reader = struct {
    sealed_records: []const u8,
    validator: Validator,
    counts: Counts,
    /// Full-file preflight, bounded to 512 MiB. This checks envelope shape,
    /// identities, exact digests, per-role order, class counts and complete EOF.
    /// Before owner effects, the caller must ALSO preflight its finite payload
    /// vocabulary/source bindings/cuts and genuine lifecycle terminal schema.
    pub fn preflight(bytes: []const u8, expected: Identity, validator: Validator) Error!Reader {
        if (bytes.len < header_size) return error.Incomplete;
        if (bytes.len > max_file_bytes) return error.InvalidLength;
        var d: Decoder = .{ .bytes = bytes[0..header_size] };
        if (!std.mem.eql(u8, try d.raw(8), magic)) return error.UnsupportedProfile;
        if (try d.int(u16) != profile_id) return error.UnsupportedProfile;
        if (try d.int(u16) != wire_version) return error.UnsupportedVersion;
        if (try d.int(u16) != header_size or try d.int(u16) != 0) return error.Noncanonical;
        const bound = try d.int(u64);
        if (bound < bytes.len or bound > max_file_bytes) return error.InvalidLength;
        if (try d.int(u32) != max_payload or try d.int(u16) != role_count or try d.int(u16) != 0) return error.Noncanonical;
        if (!std.mem.eql(u8, try d.raw(32), &expected.build)) return error.WrongBuild;
        if (!std.mem.eql(u8, try d.raw(32), &expected.bank)) return error.WrongBank;
        if (!std.mem.eql(u8, try d.raw(32), &expected.config)) return error.WrongConfig;
        if (!std.mem.eql(u8, try d.raw(32), &expected.source)) return error.WrongSource;
        if (!std.mem.eql(u8, try d.raw(32), &hash(bytes[0..160]))) return error.HashMismatch;
        try d.finish();
        if (bytes.len < header_size + trailer_size) return error.Incomplete;
        const end = bytes.len - trailer_size;
        const trailer = bytes[end..];
        d = .{ .bytes = trailer };
        if (!std.mem.eql(u8, try d.raw(8), "SMELEND1")) return error.Incomplete;
        if (try d.int(u8) != 1 or try d.int(u8) != closed_role_mask) return error.Incomplete;
        if (try d.int(u16) != 0 or try d.int(u32) != trailer_size) return error.Noncanonical;
        if (try d.int(u64) != bytes.len) return error.InvalidLength;
        var terminal: Counts = .{};
        terminal.total = try d.int(u64);
        for (&terminal.roles) |*n| n.* = try d.int(u64);
        for (&terminal.inputs) |*n| n.* = try d.int(u64);
        for (&terminal.references) |*n| n.* = try d.int(u64);
        if (try d.int(u64) != end - header_size) return error.InvalidLength;
        if (!std.mem.allEqual(u8, try d.raw(16), 0)) return error.Noncanonical;
        if (!std.mem.eql(u8, try d.raw(32), &hash(bytes[0 .. bytes.len - 32]))) return error.HashMismatch;
        try d.finish();
        var counts: Counts = .{};
        var offset: usize = header_size;
        while (offset < end) {
            const r = try readRecord(bytes[offset..end], validator);
            try counts.accept(r.role, r.ordinal, r.class);
            offset += r.size;
        }
        if (offset != end) return error.InvalidLength;
        if (!std.meta.eql(counts, terminal)) return error.CountMismatch;
        return .{ .sealed_records = bytes[header_size..end], .validator = validator, .counts = counts };
    }
    fn nextClass(self: *const Reader, offset: *usize, role: Role, class: Class) Error!?WireRecord {
        while (offset.* < self.sealed_records.len) {
            // Preflight already checked every record. Skip other classes from
            // envelope metadata alone: execution never reads reference payloads.
            const remaining = self.sealed_records[offset.*..];
            if (remaining.len < frame_header_size) return error.Truncated;
            const length = std.mem.readInt(u32, remaining[4..8], .little);
            if (length < frame_header_size or length > remaining.len or length > frame_header_size + max_payload) return error.InvalidLength;
            offset.* += length;
            if (remaining[8] == @intFromEnum(role) and remaining[9] == @intFromEnum(class))
                return try readRecord(remaining[0..length], self.validator);
        }
        return null;
    }
    pub fn execution(self: *const Reader, role: Role) InputCursor {
        return .{ .context = @ptrCast(self), .role = role };
    }
    pub fn comparison(self: *const Reader, role: Role) ComparisonCursor {
        return .{ .context = @ptrCast(self), .role = role };
    }
};
