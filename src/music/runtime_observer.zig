//! RuntimeObserverV1: one Control publisher, one host reader, owned numeric data.
//! The host retains this heap allocation until both owners release it. No audio
//! resource, runtime pointer, receipt or Render hook is retained here.
const std = @import("std");
const v1 = @import("runtime_contract.zig");
const trace = @import("sme-trace");

pub const version: u16 = 1;
pub const publication_capacity: usize = 3;
pub const record_capacity: usize = 64;
pub const Handle = struct { context: u64, storage_id: u64, incarnation: u64 };
var next_storage_id: std.atomic.Value(u64) = .init(1);
pub const Operation = enum(u8) { subscribed, control_tick, control_operation, detached, destroyed };
pub const CloseReason = enum(u8) { detached, runtime_destroyed };
pub const Sections = struct {
    status: bool = true,
    canonical_inputs: bool = true,
    canonical_schedule: bool = true,
    groups: bool = false,
    buses: bool = false,
    streams: bool = false,
    policy_lifetimes: bool = false,
    generation_registry: bool = false,
    fenced_snapshot: bool = false,
    complete_recording: bool = false,
};
pub const Loss = struct {
    dropped_publications: u64 = 0,
    dropped_records: u64 = 0,
    counters_exhausted: bool = false,
    pub fn incomplete(self: Loss) bool {
        return self.dropped_publications != 0 or self.dropped_records != 0 or self.counters_exhausted;
    }
};
pub const Record = struct {
    /// Separate debug namespace, never allocated from a canonical Position.
    sequence: u64,
    source_ordinal: u64,
    fact: union(enum) { input: trace.Input, schedule: trace.ScheduleEntry },
};
pub const Header = struct {
    version: u16 = version,
    owned_value_bytes: u32 = @sizeOf(Frame), // ABI copy size, NOT a wire encoding.
    subscription: Handle,
    sequence: u64,
    operation: Operation,
    /// Present only for the actual integrated Tick publish phase. Every trace
    /// row independently preserves its original Position and execution frames.
    control_tick: ?u64,
    status: v1.StatusV1,
    sections: Sections = .{},
    input_begin: u64,
    schedule_begin: u64,
    record_count: u32,
    offered_records: u64,
    loss: Loss,
    canonical_history_incomplete: bool,
};
pub const Frame = struct {
    header: Header,
    records: [record_capacity]?Record,
    pub fn recordAt(self: *const Frame, index: usize) ?Record {
        if (index >= self.header.record_count) return null;
        return self.records[index];
    }
};
pub const Footer = struct {
    version: u16 = version,
    subscription: Handle,
    reason: CloseReason,
    attempted_publications: u64,
    offered_records: u64,
    last_status: v1.StatusV1,
    loss: Loss,
    canonical_history_incomplete: bool,
};
pub const Poll = union(enum) { empty, frame, closed: Footer };
pub const Usage = struct {
    host_storage_bytes: usize,
    output_buffer_bytes: usize,
    publication_slots: usize = publication_capacity,
    records_per_publication: usize = record_capacity,
    publisher_attached: bool,
    reader_attached: bool,
};

/// Recursively fail compilation if a future trace/status extension borrows data.
pub fn requireOwnedValue(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .bool, .@"enum", .void => {},
        .array => |t| requireOwnedValue(t.child),
        .optional => |t| requireOwnedValue(t.child),
        .@"struct" => |t| inline for (t.fields) |field| requireOwnedValue(field.type),
        .@"union" => |t| {
            if (t.tag_type == null) @compileError("observer requires tagged owned values");
            inline for (t.fields) |field| requireOwnedValue(field.type);
        },
        else => @compileError("observer cannot publish pointers or mutable resources"),
    }
}
comptime {
    @setEvalBranchQuota(30_000);
    requireOwnedValue(Frame);
    requireOwnedValue(Footer);
}

/// Unique, address-stable host ownership. create/destroy and reattach are host
/// lifecycle operations; the host must prevent calls through a freed pointer.
/// A retained reader blocks destroy even between polls. releaseReader requires
/// the host to stop/join its reader before destroying/reusing this allocation.
/// Copying a Handle does not create another ownership reference.
pub const Storage = struct {
    pub const PollHook = struct { context: *anyopaque, call: *const fn (*anyopaque) void };
    const State = enum(u8) { unused, open, closed };
    allocator: std.mem.Allocator,
    state: std.atomic.Value(State),
    publisher_attached: std.atomic.Value(bool),
    reader_attached: std.atomic.Value(bool),
    reader_guard: std.atomic.Value(bool),
    handle: Handle,
    storage_id: u64,
    last_incarnation: u64,
    // SPSC ownership: producer writes only [head] with head-tail < capacity;
    // consumer owns [tail] until its release store. Ordinary payloads never race.
    head: std.atomic.Value(u64),
    tail: std.atomic.Value(u64),
    cells: [publication_capacity]Frame,
    pending: [record_capacity]?Record,
    pending_count: usize,
    input_begin: u64,
    schedule_begin: u64,
    sequence: u64,
    record_sequence: u64,
    loss: Loss,
    footer: Footer,
    test_poll_hook: if (@import("builtin").is_test) ?PollHook else void,

    pub fn requiredBytes() usize {
        return @sizeOf(Storage);
    }
    pub fn create(allocator: std.mem.Allocator, max_owned_bytes: usize) !*Storage {
        if (max_owned_bytes < requiredBytes()) return error.ObserverBudgetExceeded;
        const identity = next_storage_id.load(.monotonic);
        if (identity == std.math.maxInt(u64)) return error.ObserverIdentityExhausted;
        if (next_storage_id.cmpxchgStrong(identity, identity + 1, .monotonic, .monotonic) != null) return error.ObserverBusy;
        const self = try allocator.create(Storage);
        // Initialize in place: no maximal Frame/Storage by-value temporary.
        @memset(std.mem.asBytes(self), 0);
        self.allocator = allocator;
        self.storage_id = identity;
        self.state = .init(.unused);
        self.publisher_attached = .init(false);
        self.reader_attached = .init(false);
        self.reader_guard = .init(false);
        self.head = .init(0);
        self.tail = .init(0);
        for (&self.pending) |*row| row.* = null;
        for (&self.cells) |*cell| for (&cell.records) |*row| {
            row.* = null;
        };
        if (@import("builtin").is_test) self.test_poll_hook = null;
        return self;
    }
    pub fn usage(self: *const Storage) Usage {
        return .{ .host_storage_bytes = requiredBytes(), .output_buffer_bytes = @sizeOf(Frame), .publisher_attached = self.publisher_attached.load(.acquire), .reader_attached = self.reader_attached.load(.acquire) };
    }
    pub fn destroy(self: *Storage) !void {
        if (self.publisher_attached.load(.acquire) or self.reader_attached.load(.acquire)) return error.ObserverInUse;
        if (self.reader_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ObserverBusy;
        // Host externally serializes destroy with subscribe and new call entry.
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    fn claimReader(self: *Storage) !void {
        if (self.reader_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ObserverBusy;
    }
    fn validateReader(self: *const Storage, handle: Handle) !void {
        if (!std.meta.eql(handle, self.handle)) return error.StaleObserver;
        if (!self.reader_attached.load(.acquire)) return error.StaleObserver;
    }
    /// Internal Control-owner seam. MusicRuntime validates affinity and serializes
    /// its own attachment. Only fully released storage may start a new session.
    pub fn attach(self: *Storage, context: u64, input_begin: u64, schedule_begin: u64) !Handle {
        try self.claimReader();
        defer self.reader_guard.store(false, .release);
        if (context == 0) return error.InvalidContext;
        if (self.publisher_attached.load(.acquire) or self.reader_attached.load(.acquire)) return error.ObserverInUse;
        if (self.last_incarnation == std.math.maxInt(u64)) return error.ObserverIdentityExhausted;
        self.last_incarnation += 1;
        self.handle = .{ .context = context, .storage_id = self.storage_id, .incarnation = self.last_incarnation };
        self.head.store(0, .monotonic);
        self.tail.store(0, .monotonic);
        self.pending_count = 0;
        self.input_begin = input_begin;
        self.schedule_begin = schedule_begin;
        self.sequence = 0;
        self.record_sequence = 0;
        self.loss = .{};
        for (&self.pending) |*row| row.* = null;
        self.reader_attached.store(true, .release);
        self.publisher_attached.store(true, .release);
        self.state.store(.open, .release);
        return self.handle;
    }
    fn addCounter(self: *Storage, counter: *u64, amount: u64) void {
        const result = @addWithOverflow(counter.*, amount);
        if (result[1] != 0) self.loss.counters_exhausted = true;
        counter.* = if (result[1] == 0) result[0] else std.math.maxInt(u64);
    }
    pub fn recordInput(self: *Storage, ordinal: u64, value: trace.Input) void {
        self.record(ordinal, .{ .input = value });
    }
    pub fn recordSchedule(self: *Storage, ordinal: u64, value: trace.ScheduleEntry) void {
        self.record(ordinal, .{ .schedule = value });
    }
    fn record(self: *Storage, ordinal: u64, fact: @FieldType(Record, "fact")) void {
        if (self.record_sequence == std.math.maxInt(u64)) {
            self.loss.counters_exhausted = true;
            self.addCounter(&self.loss.dropped_records, 1);
            return;
        }
        self.record_sequence += 1;
        if (self.pending_count == record_capacity) {
            self.addCounter(&self.loss.dropped_records, 1);
            return;
        }
        self.pending[self.pending_count] = .{ .sequence = self.record_sequence, .source_ordinal = ordinal, .fact = fact };
        self.pending_count += 1;
    }
    /// Only the attached Control publisher calls this. No allocation, wait,
    /// canonical sequence allocation, resource receipt or renderer access.
    pub fn publish(self: *Storage, status: v1.StatusV1, operation: Operation, tick: ?u64) void {
        std.debug.assert(self.publisher_attached.load(.monotonic));
        if (self.sequence == std.math.maxInt(u64)) {
            self.loss.counters_exhausted = true;
            self.dropPending();
            return;
        }
        self.sequence += 1;
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head == std.math.maxInt(u64) or head - tail == publication_capacity) {
            if (head == std.math.maxInt(u64)) self.loss.counters_exhausted = true;
            self.dropPending();
            return;
        }
        const cell = &self.cells[head % publication_capacity];
        cell.header = .{ .subscription = self.handle, .sequence = self.sequence, .operation = operation, .control_tick = tick, .status = status, .input_begin = self.input_begin, .schedule_begin = self.schedule_begin, .record_count = @intCast(self.pending_count), .offered_records = self.record_sequence, .loss = self.loss, .canonical_history_incomplete = !status.complete or self.input_begin != 0 or self.schedule_begin != 0 };
        for (&cell.records, 0..) |*row, i| row.* = if (i < self.pending_count) self.pending[i] else null;
        self.pending_count = 0;
        self.head.store(head + 1, .release);
    }
    fn dropPending(self: *Storage) void {
        self.addCounter(&self.loss.dropped_publications, 1);
        self.addCounter(&self.loss.dropped_records, @intCast(self.pending_count));
        self.pending_count = 0;
    }
    /// Lossless one-time footer sits outside the lossy queue. Runtime frees its
    /// own resources independently; this allocation remains solely host-owned.
    pub fn close(self: *Storage, status: v1.StatusV1, reason: CloseReason) void {
        std.debug.assert(self.publisher_attached.load(.monotonic));
        self.publish(status, if (reason == .detached) .detached else .destroyed, null);
        self.footer = .{ .subscription = self.handle, .reason = reason, .attempted_publications = self.sequence, .offered_records = self.record_sequence, .last_status = status, .loss = self.loss, .canonical_history_incomplete = !status.complete or self.input_begin != 0 or self.schedule_begin != 0 };
        self.state.store(.closed, .release);
        self.publisher_attached.store(false, .release);
    }
    /// Copies one bounded owned value into a host-owned buffer. Concurrent polls
    /// fail Busy. Output is untouched on Empty/Closed/error. There is no runtime
    /// pointer dereference; this remains valid after MusicRuntime destruction.
    pub fn poll(self: *Storage, handle: Handle, output: *Frame) !Poll {
        try self.claimReader();
        defer self.reader_guard.store(false, .release);
        try self.validateReader(handle);
        const tail = self.tail.load(.monotonic);
        // Acquire Closed BEFORE the final head check: a close observed after an
        // empty-head check could otherwise skip the last queued publication.
        const state = self.state.load(.acquire);
        const head = self.head.load(.acquire);
        if (tail != head) {
            if (@import("builtin").is_test) if (self.test_poll_hook) |hook| hook.call(hook.context);
            const cell = &self.cells[tail % publication_capacity];
            output.header = cell.header;
            for (&output.records, &cell.records) |*destination, row| destination.* = row;
            self.tail.store(tail + 1, .release);
            return .frame;
        }
        if (state == .closed) return .{ .closed = self.footer };
        return .empty;
    }
    /// Host reader disconnect. Pending debug rows may be discarded on reuse;
    /// this never touches the publisher or resource cleanup. Join the reader
    /// before calling this and before destroying storage.
    pub fn releaseReader(self: *Storage, handle: Handle) !void {
        try self.claimReader();
        defer self.reader_guard.store(false, .release);
        try self.validateReader(handle);
        self.reader_attached.store(false, .release);
    }
};
