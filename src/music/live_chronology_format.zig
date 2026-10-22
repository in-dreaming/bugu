//! Canonical bytes for the isolated Live chronology grammar, NOT semantic tape
//! qualification. No producer attachment, IO, allocation or publication exists.
//! Missing semantic facts require later versioned records; hashes prove neither
//! execution nor authenticity. Caller owns every input/output buffer.
const std = @import("std");
pub const grammar = @import("live_chronology.zig");
const codec = @import("sme-trace").codec;
const Sha256 = std.crypto.hash.sha2.Sha256;
pub const magic = "SMELCF01";
pub const header_size: usize = 288;
pub const frame_size: usize = 192;
pub const input_frame_overhead: usize = 107;
pub const max_input_frame_size: usize = input_frame_overhead + grammar.input_max_bytes;
const payload_end: usize = 160;
pub const Hash = [32]u8;
pub const Limits = struct { max_bytes: u64, max_records: u64 };
pub const Header = struct { chronology: grammar.Header, max_bytes: u64 };
pub const Event = union(enum) { record: grammar.Record, terminal: grammar.Terminal };

const Writer = struct {
    bytes: []u8,
    position: usize = 0,
    fn int(self: *Writer, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.bytes[self.position..][0..@sizeOf(T)], value, .little);
        self.position += @sizeOf(T);
    }
    fn raw(self: *Writer, bytes: []const u8) void {
        @memcpy(self.bytes[self.position..][0..bytes.len], bytes);
        self.position += bytes.len;
    }
    fn optional(self: *Writer, value: ?u64) void {
        self.int(u8, if (value != null) 1 else 0);
        self.int(u64, value orelse 0);
    }
    fn point(self: *Writer, id: grammar.PointId) !void {
        const site = @intFromEnum(id.site);
        if (site < 1 or site > 14) return error.UnknownCode;
        self.int(u8, site);
        self.int(u64, id.occurrence);
    }
};
const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    fn int(self: *Reader, comptime T: type) T {
        const value = std.mem.readInt(T, self.bytes[self.position..][0..@sizeOf(T)], .little);
        self.position += @sizeOf(T);
        return value;
    }
    fn array(self: *Reader, comptime n: usize) [n]u8 {
        const value = self.bytes[self.position..][0..n].*;
        self.position += n;
        return value;
    }
    fn optional(self: *Reader) !?u64 {
        const present = self.int(u8);
        const value = self.int(u64);
        return switch (present) {
            0 => if (value == 0) null else error.Noncanonical,
            1 => value,
            else => error.Noncanonical,
        };
    }
    fn point(self: *Reader) !grammar.PointId {
        const site = self.int(u8);
        if (site < 1 or site > 14) return error.UnknownCode;
        return .{ .site = @enumFromInt(site), .occurrence = self.int(u64) };
    }
    fn padding(self: *Reader) !void {
        if (!std.mem.allEqual(u8, self.bytes[self.position..], 0)) return error.Noncanonical;
    }
};
fn digest(bytes: []const u8) Hash {
    var result: Hash = undefined;
    Sha256.hash(bytes, &result, .{});
    return result;
}
fn roleCode(role: grammar.Role) !u8 {
    return switch (role) { .control => 0, .worker => 1, .render => 2, _ => error.UnknownCode };
}
fn readRole(value: u8) !grammar.Role {
    return switch (value) { 0 => .control, 1 => .worker, 2 => .render, else => error.UnknownCode };
}
fn phaseCode(phase: grammar.Phase) !u8 {
    return switch (phase) { .collect => 1, .accept => 2, .prepare => 3, .publish => 4, _ => error.UnknownCode };
}
fn readPhase(value: u8) !grammar.Phase {
    return switch (value) { 1 => .collect, 2 => .accept, 3 => .prepare, 4 => .publish, else => error.UnknownCode };
}
fn originCode(origin: grammar.FailureOrigin) !u8 {
    return switch (origin) {
        .collect_owner => 1, .accept_device => 2, .accept_replay => 3, .accept_drain => 4,
        .prepare_owner => 5, .prepare_failure_drain => 6, .prepare_success_drain => 7, .snapshot => 8,
        .accept_acquire => 9, .accept_sync => 10, .accept_live => 11,
        _ => error.UnknownCode,
    };
}
fn readOrigin(value: u8) !grammar.FailureOrigin {
    return switch (value) {
        1 => .collect_owner, 2 => .accept_device, 3 => .accept_replay, 4 => .accept_drain,
        5 => .prepare_owner, 6 => .prepare_failure_drain, 7 => .prepare_success_drain, 8 => .snapshot,
        9 => .accept_acquire, 10 => .accept_sync, 11 => .accept_live,
        else => error.UnknownCode,
    };
}
fn writeIdentity(w: *Writer, identity: grammar.Identity) void {
    w.raw(&identity.session); w.raw(&identity.bank); w.raw(&identity.build);
    for (identity.sources) |source| w.raw(&source);
}
fn readIdentity(r: *Reader) grammar.Identity {
    var identity: grammar.Identity = .{ .session = r.array(16), .bank = r.array(32), .build = r.array(32), .sources = undefined };
    for (&identity.sources) |*source| source.* = r.array(32);
    return identity;
}
fn checkLimits(header: Header, cap: Limits) !void {
    if (header.max_bytes < header_size + frame_size or header.max_bytes == std.math.maxInt(u64) or
        header.max_bytes > cap.max_bytes or header.chronology.max_records > cap.max_records) return error.LimitExceeded;
}
fn writeHeader(header: Header, out: []u8) void {
    @memset(out, 0);
    var w: Writer = .{ .bytes = out };
    w.raw(magic); w.int(u16, grammar.profile_id); w.int(u16, grammar.wire_version); w.int(u16, grammar.semantic_rules_version); w.int(u16, 0);
    writeIdentity(&w, header.chronology.identity);
    w.int(u64, header.max_bytes); w.int(u64, header.chronology.max_records);
    w.int(u64, header.chronology.max_operations_per_role); w.int(u64, header.chronology.max_points_per_operation);
    w.raw(&digest(out[0..256]));
}
fn readHeader(bytes: []const u8) !Header {
    if (bytes.len != header_size) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.Unsupported;
    if (!std.mem.eql(u8, bytes[256..288], &digest(bytes[0..256]))) return error.HashMismatch;
    var r: Reader = .{ .bytes = bytes, .position = 8 };
    if (r.int(u16) != grammar.profile_id or r.int(u16) != grammar.wire_version or r.int(u16) != grammar.semantic_rules_version) return error.Unsupported;
    if (r.int(u16) != 0) return error.Noncanonical;
    const identity = readIdentity(&r);
    const max_bytes = r.int(u64);
    return .{ .chronology = .{ .identity = identity, .max_records = r.int(u64), .max_operations_per_role = r.int(u64), .max_points_per_operation = r.int(u64) }, .max_bytes = max_bytes };
}
fn tag(payload: grammar.Payload) u8 {
    return switch (payload) { .begin => 1, .phase => 2, .frontier => 3, .observation => 4, .acceptance => 5, .failure => 6, .snapshot => 7, .final_publish => 8, .end => 9, .retained_input => 10, .preparation_defer => 11 };
}
fn writePayload(payload: grammar.Payload, bytes: []u8) !void {
    var w: Writer = .{ .bytes = bytes };
    switch (payload) {
        .begin => |v| { w.int(u64, v.tick); w.int(u64, v.entry_frame); w.int(u64, v.prior_tick); w.int(u8, if (v.retained_inputs) 1 else 0); },
        .phase => |v| w.int(u8, try phaseCode(v)),
        .frontier => |v| { try w.point(v.id); w.int(u64, v.raw_frame); w.int(u64, v.effective_frame); },
        .observation => |v| {
            try w.point(v.id);
            w.int(u8, switch (v.outcome) { .value => 1, .empty => 2, .deferred => 3, .failed => 4, _ => return error.UnknownCode });
            w.int(u64, v.effective_frame); w.optional(v.input_order); w.int(u32, v.reason);
        },
        .acceptance => |v| {
            try w.point(v.id); w.int(u64, v.incoming_frame);
            w.int(u8, switch (v.outcome) { .accepted => 1, .no_completion => 2, .unstable => 3, .deferred => 4, .failed => 5, _ => return error.UnknownCode });
            w.int(u8, if (v.cut != null) 1 else 0);
            const cut = v.cut orelse grammar.Cut{ .sequence_before = 0 };
            w.int(u64, cut.sequence_before); w.optional(cut.sequence_after); w.optional(cut.frame); w.optional(cut.consumed); w.optional(cut.produced);
            w.optional(v.input_order); w.int(u64, v.batch); w.int(u32, v.reason); w.int(u64, v.worker_job);
        },
        .preparation_defer => |v| {
            var encoder: codec.Encoder = .{ .bytes = bytes };
            try encoder.put(v);
            if (encoder.offset != bytes.len) return error.InvalidLength;
        },
        .retained_input => |v| { try w.point(v.id); w.int(u16, @intCast(v.bytes.len)); w.raw(v.bytes); },
        .failure => |v| { try w.point(v.id); w.int(u8, try originCode(v.origin)); w.int(u32, v.reason); },
        .snapshot => |v| { try w.point(v.id); w.int(u8, switch (v.path) { .ordinary => 1, .prepare_failure => 2, _ => return error.UnknownCode }); },
        .final_publish => |v| { try w.point(v.id); w.int(u8, try phaseCode(v.exit_phase)); w.int(u64, v.effective_frame); },
        .end => |v| {
            w.int(u8, switch (v.outcome) { .returned => 1, .deferred => 2, .failed => 3, _ => return error.UnknownCode });
            w.int(u64, v.points); w.int(u64, v.effective_frame); w.int(u32, v.reason);
        },
    }
}
fn readPayload(code: u8, bytes: []const u8) !grammar.Payload {
    var r: Reader = .{ .bytes = bytes };
    const result: grammar.Payload = switch (code) {
        1 => blk: {
            const tick = r.int(u64); const entry = r.int(u64); const prior = r.int(u64); const retained = r.int(u8);
            if (retained > 1) return error.Noncanonical;
            break :blk .{ .begin = .{ .tick = tick, .entry_frame = entry, .prior_tick = prior, .retained_inputs = retained == 1 } };
        },
        2 => .{ .phase = try readPhase(r.int(u8)) },
        3 => .{ .frontier = .{ .id = try r.point(), .raw_frame = r.int(u64), .effective_frame = r.int(u64) } },
        4 => .{ .observation = .{
            .id = try r.point(), .outcome = switch (r.int(u8)) { 1 => .value, 2 => .empty, 3 => .deferred, 4 => .failed, else => return error.UnknownCode },
            .effective_frame = r.int(u64), .input_order = try r.optional(), .reason = r.int(u32),
        } },
        5 => blk: {
            const id = try r.point(); const incoming = r.int(u64);
            const outcome: grammar.AcceptanceOutcome = switch (r.int(u8)) { 1 => .accepted, 2 => .no_completion, 3 => .unstable, 4 => .deferred, 5 => .failed, else => return error.UnknownCode };
            const present = r.int(u8);
            const cut: grammar.Cut = .{ .sequence_before = r.int(u64), .sequence_after = try r.optional(), .frame = try r.optional(), .consumed = try r.optional(), .produced = try r.optional() };
            if (present > 1) return error.Noncanonical;
            if (present == 0 and (cut.sequence_before != 0 or cut.sequence_after != null or cut.frame != null or cut.consumed != null or cut.produced != null)) return error.Noncanonical;
            break :blk .{ .acceptance = .{ .id = id, .incoming_frame = incoming, .outcome = outcome, .cut = if (present == 1) cut else null, .input_order = try r.optional(), .batch = r.int(u64), .reason = r.int(u32), .worker_job = r.int(u64) } };
        },
        6 => .{ .failure = .{ .id = try r.point(), .origin = try readOrigin(r.int(u8)), .reason = r.int(u32) } },
        7 => .{ .snapshot = .{ .id = try r.point(), .path = switch (r.int(u8)) { 1 => .ordinary, 2 => .prepare_failure, else => return error.UnknownCode } } },
        8 => .{ .final_publish = .{ .id = try r.point(), .exit_phase = try readPhase(r.int(u8)), .effective_frame = r.int(u64) } },
        9 => .{ .end = .{ .outcome = switch (r.int(u8)) { 1 => .returned, 2 => .deferred, 3 => .failed, else => return error.UnknownCode }, .points = r.int(u64), .effective_frame = r.int(u64), .reason = r.int(u32) } },
        11 => blk: {
            var decoder: codec.Decoder = .{ .bytes = bytes };
            const value = try decoder.get(grammar.PreparationDefer);
            try decoder.finish(); r.position = bytes.len;
            break :blk .{ .preparation_defer = value };
        },
        10 => blk: {
            if (bytes.len < 11) return error.InvalidLength;
            const id = try r.point(); const length = r.int(u16);
            if (length == 0 or length > grammar.input_max_bytes or bytes.len != 11 + @as(usize, length)) return error.InvalidLength;
            const input = bytes[r.position..]; r.position = bytes.len;
            break :blk .{ .retained_input = .{ .id = id, .bytes = input } };
        },
        else => return error.UnknownCode,
    };
    try r.padding();
    return result;
}
fn writeTerminal(t: grammar.Terminal, total_bytes: u64, bytes: []u8) void {
    var w: Writer = .{ .bytes = bytes };
    w.int(u64, t.records); w.int(u64, total_bytes);
    for (t.role_sequences) |n| w.int(u64, n);
    for (t.role_operations) |n| w.int(u64, n);
    for (t.producer_closed) |closed| w.int(u8, if (closed) 1 else 0);
    w.int(u8, if (t.complete) 1 else 0);
}
fn readTerminal(identity: grammar.Identity, total_bytes: u64, bytes: []const u8) !grammar.Terminal {
    var r: Reader = .{ .bytes = bytes };
    var t: grammar.Terminal = .{ .identity = identity, .records = r.int(u64), .role_sequences = undefined, .role_operations = undefined, .producer_closed = undefined, .complete = false };
    if (r.int(u64) != total_bytes) return error.InvalidLength;
    for (&t.role_sequences) |*n| n.* = r.int(u64);
    for (&t.role_operations) |*n| n.* = r.int(u64);
    for (&t.producer_closed) |*closed| { const n = r.int(u8); if (n > 1) return error.Noncanonical; closed.* = n == 1; }
    const complete = r.int(u8); if (complete > 1) return error.Noncanonical; t.complete = complete == 1;
    try r.padding();
    return t;
}

/// A failure is permanent even if the caller later supplies a larger buffer.
/// Successful methods return only the initialized output prefix. Publication is
/// deliberately absent; a complete stream certifies grammar framing only.
pub const Encoder = struct {
    validator: grammar.Validator,
    max_bytes: u64,
    bytes: u64 = header_size,
    frames: u64 = 0,
    chain: Hash,
    poisoned: bool = false,
    pub fn init(header: Header, expected: grammar.Identity, out: []u8) !Encoder {
        if (out.len < header_size) return error.BufferTooSmall;
        try checkLimits(header, .{ .max_bytes = header.max_bytes, .max_records = header.chronology.max_records });
        const validator = try grammar.Validator.init(header.chronology, expected);
        writeHeader(header, out[0..header_size]);
        return .{ .validator = validator, .max_bytes = header.max_bytes, .chain = out[256..288].* };
    }
    fn reserve(self: *Encoder, out: []u8, size: usize) !u64 {
        if (self.poisoned) return error.Poisoned;
        if (self.validator.terminal_seen) return error.Closed;
        if (out.len < size) return error.BufferTooSmall;
        const next = std.math.add(u64, self.bytes, size) catch return error.Overflow;
        if (next > self.max_bytes) return error.LimitExceeded;
        return next;
    }
    fn prefix(self: *Encoder, out: []u8, code: u8, role: u8, sequence: u64, operation: u64) !void {
        @memset(out, 0);
        var w: Writer = .{ .bytes = out };
        w.int(u32, @intCast(out.len)); w.int(u8, code); w.int(u8, role); w.int(u16, 0);
        w.int(u64, try std.math.add(u64, self.frames, 1)); w.int(u64, sequence); w.int(u64, operation); w.raw(&self.chain);
    }
    fn commit(self: *Encoder, bytes: []u8, next: u64, validator: grammar.Validator) []const u8 {
        const end = bytes.len - 32;
        const hash = digest(bytes[0..end]);
        @memcpy(bytes[end..], &hash);
        self.chain = hash; self.bytes = next; self.frames += 1; self.validator = validator;
        return bytes;
    }
    pub fn record(self: *Encoder, value: grammar.Record, out: []u8) ![]const u8 {
        errdefer self.poisoned = true;
        var preparation_bytes: [codec.maxSize(grammar.PreparationDefer)]u8 = undefined;
        const size = switch (value.payload) {
            .retained_input => |input| input_frame_overhead + input.bytes.len,
            .preparation_defer => |deferred| blk: {
                var encoder: codec.Encoder = .{ .bytes = &preparation_bytes }; try encoder.put(deferred);
                break :blk 96 + encoder.offset;
            },
            else => frame_size,
        };
        const next = try self.reserve(out, size);
        // Reserve one terminal frame; a record cannot consume its budget.
        if ((std.math.add(u64, next, frame_size) catch return error.Overflow) > self.max_bytes) return error.LimitExceeded;
        var validator = self.validator; try validator.push(value);
        const bytes = out[0..size];
        try self.prefix(bytes, tag(value.payload), try roleCode(value.role), value.sequence, value.operation);
        try writePayload(value.payload, bytes[64 .. size - 32]);
        return self.commit(bytes, next, validator);
    }
    pub fn finish(self: *Encoder, terminal: grammar.Terminal, out: []u8) ![]const u8 {
        errdefer self.poisoned = true;
        const next = try self.reserve(out, frame_size);
        var validator = self.validator; try validator.finish(terminal);
        const bytes = out[0..frame_size];
        try self.prefix(bytes, 255, 255, 0, 0); writeTerminal(terminal, next, bytes[64..payload_end]);
        return self.commit(bytes, next, validator);
    }
};

pub const Decoder = struct {
    validator: grammar.Validator,
    max_bytes: u64,
    bytes: u64 = header_size,
    frames: u64 = 0,
    chain: Hash,
    poisoned: bool = false,
    pub fn init(bytes: []const u8, expected: grammar.Identity, cap: Limits) !Decoder {
        const header = try readHeader(bytes); try checkLimits(header, cap);
        const validator = try grammar.Validator.init(header.chronology, expected);
        return .{ .validator = validator, .max_bytes = header.max_bytes, .chain = bytes[256..288].* };
    }
    pub fn next(self: *Decoder, bytes: []const u8) !Event {
        errdefer self.poisoned = true;
        if (self.poisoned) return error.Poisoned;
        if (self.validator.terminal_seen) return error.Closed;
        if (bytes.len < 108 or bytes.len > max_input_frame_size) return error.InvalidLength;
        const total = std.math.add(u64, self.bytes, bytes.len) catch return error.Overflow;
        if (total > self.max_bytes) return error.LimitExceeded;
        var r: Reader = .{ .bytes = bytes };
        if (r.int(u32) != bytes.len) return error.InvalidLength;
        const code = r.int(u8); const role = r.int(u8);
        if (code != 10 and code != 11 and bytes.len != frame_size) return error.InvalidLength;
        if (r.int(u16) != 0) return error.Noncanonical;
        if (r.int(u64) != try std.math.add(u64, self.frames, 1)) return error.InvalidOrder;
        const sequence = r.int(u64); const operation = r.int(u64);
        if (!std.mem.eql(u8, &r.array(32), &self.chain)) return error.ChainMismatch;
        const end = bytes.len - 32;
        const hash = digest(bytes[0..end]);
        if (!std.mem.eql(u8, bytes[end..], &hash)) return error.HashMismatch;
        var validator = self.validator;
        const event: Event = if (code == 255) blk: {
            if (role != 255 or sequence != 0 or operation != 0) return error.Noncanonical;
            const terminal = try readTerminal(validator.header.identity, total, bytes[64..end]);
            try validator.finish(terminal);
            break :blk .{ .terminal = terminal };
        } else blk: {
            const record: grammar.Record = .{ .identity = validator.header.identity, .role = try readRole(role), .sequence = sequence, .operation = operation, .payload = try readPayload(code, bytes[64..end]) };
            try validator.push(record);
            break :blk .{ .record = record };
        };
        self.validator = validator; self.bytes = total; self.frames += 1; self.chain = hash;
        return event;
    }
    pub fn eof(self: *Decoder) !void {
        errdefer self.poisoned = true;
        if (self.poisoned) return error.Poisoned;
        try self.validator.eof();
    }
};

/// Preflight an immutable complete caller-owned buffer before any engine effect.
/// Does not authenticate the producer or certify semantic replay dependencies.
pub fn preflight(bytes: []const u8, expected: grammar.Identity, cap: Limits) !Header {
    if (bytes.len < header_size or bytes.len > cap.max_bytes) return error.InvalidLength;
    var decoder = try Decoder.init(bytes[0..header_size], expected, cap);
    var offset: usize = header_size;
    while (offset < bytes.len) {
        if (bytes.len - offset < 4) return error.InvalidLength;
        if (decoder.validator.terminal_seen) return error.Closed;
        const length = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        if (length < 108 or length > max_input_frame_size or bytes.len - offset < length) return error.InvalidLength;
        _ = try decoder.next(bytes[offset..][0..length]);
        offset += length;
    }
    try decoder.eof();
    return .{ .chronology = decoder.validator.header, .max_bytes = decoder.max_bytes };
}

fn fixtureIdentity() grammar.Identity {
    return .{ .session = @splat(1), .bank = @splat(2), .build = @splat(3), .sources = .{ @splat(4), @splat(5), @splat(6), @splat(7) } };
}
const test_cap: Limits = .{ .max_bytes = 32768, .max_records = 100 };
fn testHeader() Header {
    return .{ .chronology = .{ .identity = fixtureIdentity(), .max_records = 100, .max_operations_per_role = 20, .max_points_per_operation = 40 }, .max_bytes = 32768 };
}
const Capture = struct {
    storage: [32768]u8 = undefined,
    used: usize = header_size,
    expected: [100]grammar.Record = undefined,
    count: usize = 0,
    encoder: Encoder = undefined,
    fn init() !Capture {
        var self: Capture = .{};
        self.encoder = try Encoder.init(testHeader(), fixtureIdentity(), self.storage[0..header_size]);
        return self;
    }
    fn add(self: *Capture, role: grammar.Role, payload: grammar.Payload) !void {
        const lane = self.encoder.validator.lanes[@intFromEnum(role)];
        const value: grammar.Record = .{ .identity = fixtureIdentity(), .role = role, .sequence = lane.sequence + 1, .operation = lane.operations + 1, .payload = payload };
        const result = try self.encoder.record(value, self.storage[self.used..]);
        self.used += result.len; self.expected[self.count] = value; self.count += 1;
    }
    fn finish(self: *Capture) !void {
        const v = self.encoder.validator;
        var terminal: grammar.Terminal = .{ .identity = fixtureIdentity(), .records = v.records, .role_sequences = @splat(0), .role_operations = @splat(0), .producer_closed = @splat(true), .complete = true };
        for (v.lanes, 0..) |lane, i| { terminal.role_sequences[i] = lane.sequence; terminal.role_operations[i] = lane.operations; }
        const result = try self.encoder.finish(terminal, self.storage[self.used..]); self.used += result.len;
    }
    fn roundTrip(self: *const Capture) !void {
        var decoder = try Decoder.init(self.storage[0..header_size], fixtureIdentity(), test_cap);
        for (self.expected[0..self.count], 0..) |expected, i| {
            const actual = try decoder.next(self.storage[header_size + i * frame_size ..][0..frame_size]);
            try std.testing.expect(actual == .record);
            try std.testing.expect(std.meta.eql(expected, actual.record));
        }
        const terminal = try decoder.next(self.storage[header_size + self.count * frame_size ..][0..frame_size]);
        try std.testing.expect(terminal == .terminal);
        try std.testing.expectEqual(@as(u64, self.count), terminal.terminal.records);
        try decoder.eof();
        _ = try preflight(self.storage[0..self.used], fixtureIdentity(), test_cap);
    }
    fn phase(self: *Capture, value: grammar.Phase) !void { try self.add(.control, .{ .phase = value }); }
    fn point(self: *Capture, site: grammar.Site, outcome: grammar.Outcome, order: ?u64, reason: u32) !void {
        const role: grammar.Role = switch (site) { .worker_select, .worker_complete => .worker, .render_gate, .render_span => .render, else => .control };
        const lane = self.encoder.validator.lanes[@intFromEnum(role)];
        try self.add(role, .{ .observation = .{ .id = .{ .site = site, .occurrence = lane.occurrences[@intFromEnum(site) - 1] + 1 }, .outcome = outcome, .effective_frame = lane.effective_frame, .input_order = order, .reason = reason } });
    }
    fn frontier(self: *Capture, site: grammar.Site, raw: u64) !void {
        try self.add(.control, .{ .frontier = .{ .id = .{ .site = site, .occurrence = 1 }, .raw_frame = raw, .effective_frame = @max(raw, self.encoder.validator.lanes[0].effective_frame) } });
    }
    fn collect(self: *Capture, raw: u64, input: bool) !void {
        try self.add(.control, .{ .begin = .{ .tick = self.encoder.validator.ticks + 1, .entry_frame = self.encoder.validator.last_control_frame } });
        try self.phase(.collect); try self.frontier(.control_collect_frontier, raw);
        try self.point(.control_collect, if (input) .value else .empty, if (input) 0 else null, 0);
    }
    fn acceptPhase(self: *Capture, raw: u64) !void { try self.phase(.accept); try self.frontier(.control_accept_frontier, raw); }
    fn acceptance(self: *Capture, outcome: grammar.AcceptanceOutcome, cut: ?grammar.Cut) !void {
        const v = self.encoder.validator;
        try self.add(.control, .{ .acceptance = .{
            .id = .{ .site = .control_accept, .occurrence = v.lanes[0].occurrences[1] + 1 },
            .incoming_frame = v.lanes[0].effective_frame, .outcome = outcome, .cut = cut,
            .input_order = if (outcome == .accepted) v.input_order else null,
            .batch = if (outcome == .accepted) v.last_batch + 1 else 0,
            .reason = if (outcome == .accepted or outcome == .no_completion) 0 else 77,
        } });
    }
    fn success(self: *Capture, frame: u64) !void {
        try self.acceptance(.accepted, .{ .sequence_before = 2, .sequence_after = 2, .frame = frame, .consumed = 8, .produced = 16 });
    }
    fn failure(self: *Capture, origin: grammar.FailureOrigin, reason: u32) !void {
        try self.add(.control, .{ .failure = .{ .id = .{ .site = .control_failure, .occurrence = self.encoder.validator.lanes[0].occurrences[10] + 1 }, .origin = origin, .reason = reason } });
    }
    fn snapshot(self: *Capture, path: grammar.SnapshotPath) !void {
        try self.add(.control, .{ .snapshot = .{ .id = .{ .site = .control_snapshot, .occurrence = 1 }, .path = path } });
    }
    fn finalPublish(self: *Capture) !void {
        const lane = self.encoder.validator.lanes[0];
        try self.add(.control, .{ .final_publish = .{ .id = .{ .site = .control_final_publish, .occurrence = 1 }, .exit_phase = @enumFromInt(lane.phase), .effective_frame = lane.effective_frame } });
    }
    fn end(self: *Capture, role: grammar.Role, outcome: grammar.EndOutcome, reason: u32) !void {
        const lane = self.encoder.validator.lanes[@intFromEnum(role)];
        try self.add(role, .{ .end = .{ .outcome = outcome, .points = lane.points, .effective_frame = lane.effective_frame, .reason = reason } });
    }
    fn normalEnd(self: *Capture, deferred: bool) !void {
        try self.phase(.prepare); try self.point(.control_prepare, if (deferred) .deferred else .value, null, if (deferred) 77 else 0);
        try self.phase(.publish); try self.point(.control_publish, .empty, null, 0);
        try self.snapshot(.ordinary); try self.finalPublish();
        try self.end(.control, if (deferred) .deferred else .returned, if (deferred) 77 else 0);
    }
};

// Twenty-five independently sealed traces span all nine record tags and all
// structural operation/return branches. They are grammar examples, not engine
// captures; importing grammar also runs its independent malicious-trace tests.
test "25 canonical grammar trace round trips" {
    for (0..25) |scenario| {
        var c = try Capture.init();
        switch (scenario) {
            0 => {}, // empty, closed producer set
            1, 2, 3 => { // Worker empty, actual failed result, and pre-point failure
                try c.add(.worker, .{ .begin = .{} });
                if (scenario != 3) {
                    try c.point(.worker_select, if (scenario == 2) .value else .empty, null, 0);
                    try c.point(.worker_complete, if (scenario == 2) .failed else .empty, null, if (scenario == 2) 77 else 0);
                }
                try c.end(.worker, if (scenario == 1) .returned else .failed, if (scenario == 1) 0 else 77);
            },
            4, 5 => { // Render empty/short span and failed prefix
                try c.add(.render, .{ .begin = .{} });
                try c.point(.render_gate, .empty, null, 0);
                if (scenario == 4) try c.point(.render_span, .empty, null, 0);
                try c.end(.render, if (scenario == 4) .returned else .failed, if (scenario == 4) 0 else 77);
            },
            6 => { // failure before any actual collect frontier
                try c.add(.control, .{ .begin = .{ .tick = 1 } }); try c.phase(.collect);
                try c.failure(.collect_owner, 77); try c.finalPublish(); try c.end(.control, .failed, 77);
            },
            7, 8, 9 => { // device/replay/drain direct failures at real accept frontier
                try c.collect(10, false); try c.acceptPhase(20);
                try c.failure(switch (scenario) { 7 => .accept_device, 8 => .accept_replay, else => .accept_drain }, 77);
                try c.finalPublish(); try c.end(.control, .failed, 77);
            },
            10, 11, 12, 13, 14 => { // preparation failure and true recovery outcomes
                try c.collect(10, false); try c.acceptPhase(20); try c.acceptance(.no_completion, null); try c.phase(.prepare);
                if (scenario <= 12) {
                    try c.failure(.prepare_owner, 77);
                    if (scenario == 11) try c.failure(.prepare_failure_drain, 78) else {
                        try c.phase(.publish);
                        if (scenario == 12) try c.failure(.snapshot, 78) else try c.snapshot(.prepare_failure);
                    }
                } else {
                    try c.point(.control_prepare, .value, null, 0);
                    if (scenario == 13) try c.failure(.prepare_success_drain, 77) else {
                        try c.phase(.publish); try c.failure(.snapshot, 77);
                    }
                }
                try c.finalPublish(); try c.end(.control, .failed, if (scenario == 11 or scenario == 12) 78 else 77);
            },
            else => {
                try c.collect(10, scenario == 23); try c.acceptPhase(20);
                switch (scenario) {
                    15 => try c.acceptance(.no_completion, null),
                    16 => try c.acceptance(.unstable, .{ .sequence_before = 3 }),
                    17 => try c.acceptance(.unstable, .{ .sequence_before = 2, .sequence_after = 4, .frame = 20, .consumed = 8, .produced = 16 }),
                    18 => try c.acceptance(.deferred, null),
                    19 => try c.acceptance(.failed, .{ .sequence_before = 2, .frame = 20 }),
                    20 => { try c.success(30); try c.success(40); try c.acceptance(.no_completion, null); },
                    21 => try c.success(128),
                    22 => { // Role progress interleaves inside Control
                        try c.add(.worker, .{ .begin = .{} }); try c.point(.worker_select, .empty, null, 0); try c.end(.worker, .deferred, 77);
                        try c.success(30);
                        try c.add(.render, .{ .begin = .{} }); try c.point(.render_gate, .value, null, 0); try c.point(.render_span, .value, null, 0); try c.end(.render, .returned, 0);
                    },
                    23 => try c.success(30),
                    24 => try c.acceptance(.no_completion, null),
                    else => unreachable,
                }
                try c.normalEnd(scenario == 24);
                if (scenario == 21) {
                    try c.collect(64, false); try c.acceptPhase(64); try c.acceptance(.no_completion, null); try c.normalEnd(false);
                }
            },
        }
        try c.finish(); try c.roundTrip();
    }
}

fn rehashFrame(frame: []u8) void { @memcpy(frame[payload_end..frame_size], &digest(frame[0..payload_end])); }
fn rehashHeader(header: []u8) void { @memcpy(header[256..288], &digest(header[0..256])); }
fn sample() !Capture {
    var c = try Capture.init(); try c.collect(10, false); try c.acceptPhase(20);
    try c.success(30); try c.acceptance(.no_completion, null); try c.normalEnd(false); try c.finish(); return c;
}

test "every truncation and appended data reject complete preflight" {
    const c = try sample();
    for (0..c.used) |length| {
        if (preflight(c.storage[0..length], fixtureIdentity(), test_cap)) |_| return error.ExpectedFailure else |_| {}
    }
    var extra = c;
    @memset(extra.storage[extra.used..][0..frame_size], 0);
    try std.testing.expectError(error.InvalidLength, preflight(extra.storage[0 .. extra.used + 1], fixtureIdentity(), test_cap));
    try std.testing.expectError(error.Closed, preflight(extra.storage[0 .. extra.used + frame_size], fixtureIdentity(), test_cap));
}

test "unknown versions profile rules reserved tags and optional encodings reject" {
    const original = try sample();
    for ([_]usize{ 8, 10, 12 }) |offset| {
        var c = original; c.storage[offset] = 99; rehashHeader(c.storage[0..header_size]);
        try std.testing.expectError(error.Unsupported, Decoder.init(c.storage[0..header_size], fixtureIdentity(), test_cap));
    }
    {
        var c = original; c.storage[14] = 1; rehashHeader(c.storage[0..header_size]);
        try std.testing.expectError(error.Noncanonical, Decoder.init(c.storage[0..header_size], fixtureIdentity(), test_cap));
    }
    for ([_]usize{ 4, 6, 150 }) |offset| {
        var c = original; const frame = c.storage[header_size..][0..frame_size]; frame[offset] = 99; rehashFrame(frame);
        var decoder = try Decoder.init(c.storage[0..header_size], fixtureIdentity(), test_cap);
        if (decoder.next(frame)) |_| return error.ExpectedFailure else |_| {}
        try std.testing.expectError(error.Poisoned, decoder.next(frame));
    }
    // The first collect observation is record 4. Its absent input_order has
    // canonical presence=0 and value=0; either illegal presence or nonzero value
    // must fail even with a recomputed local digest.
    for ([_]usize{ 82, 83 }) |offset| {
        var c = original;
        const frame = c.storage[header_size + 3 * frame_size ..][0..frame_size]; frame[offset] = 2; rehashFrame(frame);
        var decoder = try Decoder.init(c.storage[0..header_size], fixtureIdentity(), test_cap);
        for (0..3) |i| _ = try decoder.next(c.storage[header_size + i * frame_size ..][0..frame_size]);
        try std.testing.expectError(error.Noncanonical, decoder.next(frame));
    }
}

test "byte corruption, missing duplicate reordered frame, identity and role swap reject" {
    const original = try sample();
    {
        var c = original; c.storage[header_size + 70] ^= 1;
        try std.testing.expectError(error.HashMismatch, preflight(c.storage[0..c.used], fixtureIdentity(), test_cap));
    }
    var wrong = fixtureIdentity(); wrong.session[0] = 99;
    try std.testing.expectError(error.IdentityMismatch, preflight(original.storage[0..original.used], wrong, test_cap));
    for ([_]usize{ 1, 2 }) |which| {
        var d = try Decoder.init(original.storage[0..header_size], fixtureIdentity(), test_cap);
        try std.testing.expectError(error.InvalidOrder, d.next(original.storage[header_size + which * frame_size ..][0..frame_size]));
    }
    {
        var d = try Decoder.init(original.storage[0..header_size], fixtureIdentity(), test_cap);
        _ = try d.next(original.storage[header_size..][0..frame_size]);
        try std.testing.expectError(error.InvalidOrder, d.next(original.storage[header_size..][0..frame_size]));
    }
    {
        var c = original; const frame = c.storage[header_size..][0..frame_size]; frame[5] = 2; rehashFrame(frame);
        // Control begin tick=1 cannot impersonate a Render operation.
        var d = try Decoder.init(c.storage[0..header_size], fixtureIdentity(), test_cap);
        try std.testing.expectError(error.InvalidFrame, d.next(frame));
    }
}

test "terminal exact counts and byte length are required despite rehashed bytes" {
    const original = try sample();
    for ([_]usize{ 64, 72, 80, 104, 128, 131 }) |offset| {
        var c = original; const frame = c.storage[c.used - frame_size ..][0..frame_size]; frame[offset] ^= 1; rehashFrame(frame);
        if (preflight(c.storage[0..c.used], fixtureIdentity(), test_cap)) |_| return error.ExpectedFailure else |_| {}
    }
}

test "finite budgets, buffer shortage and integer overflow permanently fail" {
    var buffer: [header_size]u8 = undefined;
    var header = testHeader(); header.max_bytes = header_size + frame_size;
    var encoder = try Encoder.init(header, fixtureIdentity(), &buffer);
    const record: grammar.Record = .{ .identity = fixtureIdentity(), .role = .worker, .sequence = 1, .operation = 1, .payload = .{ .begin = .{} } };
    var frame: [frame_size]u8 = undefined;
    try std.testing.expectError(error.LimitExceeded, encoder.record(record, &frame));
    try std.testing.expectError(error.Poisoned, encoder.record(record, &frame));
    encoder = try Encoder.init(testHeader(), fixtureIdentity(), &buffer);
    try std.testing.expectError(error.BufferTooSmall, encoder.record(record, frame[0..1]));
    try std.testing.expectError(error.Poisoned, encoder.record(record, &frame));
    encoder = try Encoder.init(testHeader(), fixtureIdentity(), &buffer);
    encoder.frames = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, encoder.record(record, &frame));
    const c = try sample();
    try std.testing.expectError(error.LimitExceeded, Decoder.init(c.storage[0..header_size], fixtureIdentity(), .{ .max_bytes = 1000, .max_records = 100 }));
    try std.testing.expectError(error.LimitExceeded, Decoder.init(c.storage[0..header_size], fixtureIdentity(), .{ .max_bytes = 32768, .max_records = 1 }));
}

test "chain links and absent cut bytes remain canonical under local rehash" {
    const original = try sample();
    {
        var c = original; const frame = c.storage[header_size..][0..frame_size]; frame[32] ^= 1; rehashFrame(frame);
        var d = try Decoder.init(c.storage[0..header_size], fixtureIdentity(), test_cap);
        try std.testing.expectError(error.ChainMismatch, d.next(frame));
    }
    {
        var c = original;
        // Record 8 is no_completion: the absent cut's stored sequence must be 0.
        const frame = c.storage[header_size + 7 * frame_size ..][0..frame_size]; frame[83] = 1; rehashFrame(frame);
        var d = try Decoder.init(c.storage[0..header_size], fixtureIdentity(), test_cap);
        for (0..7) |i| _ = try d.next(c.storage[header_size + i * frame_size ..][0..frame_size]);
        try std.testing.expectError(error.Noncanonical, d.next(frame));
    }
    {
        var c = original; const frame = c.storage[header_size..][0..frame_size]; frame[5] = 254; rehashFrame(frame);
        var d = try Decoder.init(c.storage[0..header_size], fixtureIdentity(), test_cap);
        try std.testing.expectError(error.UnknownCode, d.next(frame));
    }
    {
        var c = original; const frame = c.storage[header_size..][0..frame_size]; frame[0] = 191; rehashFrame(frame);
        var d = try Decoder.init(c.storage[0..header_size], fixtureIdentity(), test_cap);
        try std.testing.expectError(error.InvalidLength, d.next(frame));
    }
}

/// Structural capture preflight only. Rejects the legacy order-only experiment;
/// this result still grants no replay/publication capability or engine effects.
pub fn preflightCapture(bytes: []const u8, expected: grammar.Identity, cap: Limits) !Header {
    const header = try preflight(bytes, expected, cap);
    var decoder = try Decoder.init(bytes[0..header_size], expected, cap);
    var offset: usize = header_size;
    while (offset < bytes.len) {
        const length = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        _ = try decoder.next(bytes[offset..][0..length]);
        offset += length;
    }
    if (decoder.validator.capture_mode != true) return error.Unsupported;
    return header;
}

test "order-only grammar cannot pass capture preflight" {
    const c = try sample();
    try std.testing.expectError(error.Unsupported, preflightCapture(c.storage[0..c.used], fixtureIdentity(), test_cap));
}
