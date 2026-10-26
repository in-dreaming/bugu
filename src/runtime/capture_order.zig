//! Private, bounded observation of actual per-role checkpoint order.
//! This is partial evidence, not a recording format or completeness certificate.
//! No public recording/publication profile is enabled by this component.
//!
//! One serialized, genuine role producer owns begin/point/end; one consumer
//! owns pop. The host validates the producer's actual thread at its operation
//! boundary. The single-attempt guard rejects simultaneous/reentrant producer
//! entry; it does NOT authenticate a role or detect a wrong thread entering
//! serially during somebody else's operation. There are no thread-id syscalls,
//! user callbacks, allocation, IO, waiting, or retry loops on the producer path.
//!
//! Construct Storage as .{} at its final address and initialize once before
//! attachment. Its backing cells and collector must not move, alias another
//! lane, be reinitialized, or be freed while either role can use them. Bindings
//! are immutable while attached; attaching/detaching requires real producer
//! and consumer quiescence. A failure or an end record never grants quiescence.
//! Overflow permanently poisons this lane, independently of the audio engine:
//! callers MUST continue the original operation and preserve its true result.
const std = @import("std");

pub const max_capacity: usize = 65536;
pub const Role = enum(u8) { control, render, worker };
pub const Edge = enum(u8) { before, after };
/// Explicit domain codes for the prerequisite observer; not a persisted wire
/// schema. Exhaustive source-enum maps live at the real dispatch sites. Reserved
/// or dormant codes do not certify a reachable checkpoint or complete coverage.
pub const Site = enum(u8) {
    ring_consumed = 0x00,
    ring_produced = 0x01,
    produced_release = 0x02,
    consumed_release = 0x03,
    runtime_collection_frame = 0x20,
    runtime_plan_phase = 0x21,
    runtime_execution_receipt = 0x22,
    runtime_schedule_admission = 0x23,
    runtime_schedule_result = 0x24,
    runtime_group_source_switch_read = 0x25,
    runtime_schedule_release = 0x26,
    runtime_terminal_scan = 0x27,
    runtime_group_terminal_read = 0x28,
    runtime_group_pin_read = 0x29,
    runtime_group_pin_publish = 0x2A,
    runtime_group_pin_return = 0x2B,
    runtime_completion_space = 0x2C,
    runtime_completion_enqueue = 0x2D,
    runtime_completion_pop = 0x2E,
    runtime_completion_return = 0x2F,
    runtime_control_horizon = 0x30,
    runtime_control_accept_frame = 0x31,
    runtime_render_frame = 0x32,
    runtime_group_desired_active = 0x33,
    runtime_group_desired_start = 0x34,
    runtime_group_desired_reservation = 0x35,
    runtime_group_source_switch_final = 0x36,
    runtime_control_collect_frame = 0x37,
    runtime_render_commit_horizon = 0x38,
    runtime_stream_stop_publish = 0x39,
    // Profile-8 Live readiness envelope; old semantic tape rejects these.
    runtime_readiness_outer_before = 0x3A,
    runtime_readiness_outer_after = 0x3B,
    // Explicit Live semantic startup dispatch cuts; no pointer identity on tape.
    runtime_load_state_read = 0x3C,
    runtime_load_state_publish = 0x3D,
    runtime_load_state_claim = 0x3E,
    runtime_worker_service_read = 0x3F,
    runtime_worker_service_publish = 0xC0,
    // Explicit unsupported semantic domain: detached readiness reads raw Ring
    // consumed, not the completed-DSP control_consumed projection.
    service_readiness_raw_consumed = 0xC1,
    service_availability_readiness_sequence_before = 0x40,
    service_availability_readiness_frame = 0x41,
    service_availability_readiness_control_consumed = 0x42,
    service_availability_readiness_produced = 0x43,
    service_availability_readiness_sequence_after = 0x44,
    service_availability_acceptance_sequence_before = 0x45,
    service_availability_acceptance_frame = 0x46,
    service_availability_acceptance_control_consumed = 0x47,
    service_availability_acceptance_produced = 0x48,
    service_availability_acceptance_sequence_after = 0x49,
    service_stream_observation_frame = 0x4D,
    service_worker_claim = 0x4E,
    service_worker_scan = 0x4F,
    service_worker_running = 0x50,
    service_worker_completed = 0x51,
    service_worker_idle = 0x52,
    service_job_queued = 0x53,
    service_job_free = 0x54,
    service_worker_cancel = 0x55,
    service_worker_stopped = 0x56,
    service_acceptance_scan = 0x57,
    service_publication_release = 0x58,
    service_publication_frontier = 0x59,
    service_visibility_head = 0x5A,
    service_visibility_produced = 0x5B,
    service_visibility_stopped = 0x5C,
    service_visibility_release = 0x5D,
    service_visibility_poll = 0x5E,
    service_visibility_ack = 0x5F,
    service_readiness_stopped_first = 0x60,
    service_readiness_stopped_second = 0x61,
    service_readiness_sequence = 0x62,
    service_readiness_frame = 0x63,
    service_readiness_consumed = 0x64,
    service_readiness_produced = 0x65,
    service_readiness_job = 0x66,
    service_readiness_final_sequence = 0x67,
    service_render_sequence_odd = 0x68,
    service_render_consumed = 0x69,
    service_render_frame = 0x6A,
    service_render_sequence_even = 0x6B,
    service_stream_close_claim = 0x6C,
    service_stream_close_pending = 0x6D,
    service_stream_close_idle = 0x6E,
    service_service_prepare_claim = 0x6F,
    service_service_prepare_idle = 0x70,
    service_stream_close_visibility = 0x72,
    service_stream_close_stopped = 0x73,
    service_worker_release_progress = 0x74,
    service_control_release_progress = 0x75,
    // Explicit Live attachment only; private observer namespace, not old wire.
    service_slot_guard_open = 0x76,
    service_slot_guard_close = 0x77,
    service_slot_guard_render_claim = 0x78,
    service_slot_guard_render_release = 0x79,
    service_initial_entry_consumed = 0x7A,
    service_initial_entry_cancel = 0x7B,
    scheduler_validate = 0x80,
    scheduler_ack_terminal = 0x81,
    scheduler_control_scan = 0x82,
    scheduler_reap_phase = 0x83,
    scheduler_reap_readers = 0x84,
    scheduler_slot_return = 0x85,
    scheduler_scan = 0x86,
    scheduler_publication = 0x87,
    scheduler_acquired = 0x88,
    scheduler_phase = 0x89,
    scheduler_terminal = 0x8a,
    scheduler_receipt = 0x8b,
    scheduler_horizon = 0x8c,
    scheduler_prepare_horizon = 0x8d,
    // Semantic invalidation pass markers: index=gate, generation=frame,
    // value=zero-based arbitration iteration (zero for scan-adjacent passes).
    scheduler_invalidation_before_scan = 0x8e,
    scheduler_invalidation_after_scan = 0x8f,
    scheduler_invalidation_pre_claim = 0x90,
    // Poll: index=actual read cursor, generation=gate, after value=write prefix.
    scheduler_invalidation_poll = 0x91,
    // Publication: index/generation=intent handle, value=released write prefix.
    scheduler_invalidation_publication = 0x92,
    group_terminal_publish = 0xa0,
    group_event_space = 0xb0,
    group_event_publish = 0xb1,
    group_event_pop = 0xb2,
    group_event_return = 0xb3,
};
pub const Kind = enum(u8) { begin, point, end };
pub const Failure = enum(u8) {
    none,
    uninitialized,
    stale_address,
    concurrent_producer,
    role_mismatch,
    operation_active,
    invalid_operation,
    no_active_operation,
    counter_overflow,
    queue_full,
    binding_identity_mismatch,
    source_incomplete,
};
/// New observer eligibility only; old profiles on other targets remain absent.
/// Linux x86_64 lowering is checked separately, not a device latency promise.
pub const supported_target = @import("builtin").cpu.arch == .x86_64;
pub const InitError = error{ InvalidCapacity, AlreadyInitialized, UnsupportedTarget };

pub const Record = struct {
    role: Role,
    /// One-based contiguous number across every published record in this lane.
    /// This is producer order, never a global cross-role causal clock.
    sequence: u64,
    operation: u64,
    /// One-based, includes begin and end as well as every valueless checkpoint.
    point_ordinal: u64,
    kind: Kind,
    site: ?Site = null,
    edge: Edge,
    index: u64 = 0,
    generation: u64 = 0,
    value: ?u64 = null,
    /// End-only seal: equals the end's point_ordinal, including both endpoints.
    /// It seals observations, not semantic coverage or a successful operation.
    point_count: u64 = 0,
    /// End-only opaque original operation result; zero is conventionally success.
    result_code: u32 = 0,
};

/// Immutable-by-value snapshot of an actual begin or end record successfully
/// appended to this lane. No cell pointer or collector state is retained, so
/// consumer progress and cell reuse cannot change a returned receipt. `kind`
/// is always `.begin` or `.end`; points still publish only their usual records.
/// This is publication evidence only, never completeness or quiescence: an
/// asynchronous invalidation may race a successful append and its receipt.
pub const EndpointReceipt = struct {
    role: Role,
    sequence: u64,
    operation: u64,
    point_ordinal: u64,
    kind: Kind,
    result_code: u32,

    fn fromRecord(record: Record) EndpointReceipt {
        return .{
            .role = record.role,
            .sequence = record.sequence,
            .operation = record.operation,
            .point_ordinal = record.point_ordinal,
            .kind = record.kind,
            .result_code = record.result_code,
        };
    }
};

/// All rings used by the same role share the SAME RoleCollector. A separate
/// collector per ring would lose actual cross-ring per-sample program order.
pub const Binding = struct {
    collector: *RoleCollector,
    index: u64,
    generation: u64,
    pub fn emit(self: Binding, site: Site, edge: Edge, value: ?u64) void {
        self.collector.point(site, edge, self.index, self.generation, value);
    }
    /// The actual site supplies its required role. This checks the lane's label,
    /// not the calling thread's identity; the producer ownership contract holds.
    pub fn emitFor(self: Binding, expected_role: Role, site: Site, edge: Edge, value: ?u64) void {
        self.collector.pointFor(expected_role, site, edge, self.index, self.generation, value);
    }
};

/// Same pinned collectors across every subsystem, never per-subsystem counters.
/// Lifecycle checks are valid only under real producer/consumer quiescence.
pub const Roles = struct {
    control: *RoleCollector,
    render: *RoleCollector,
    worker: *RoleCollector,
    pub fn get(self: Roles, role: Role) *RoleCollector {
        return switch (role) {
            .control => self.control,
            .render => self.render,
            .worker => self.worker,
        };
    }
    pub fn pristine(self: Roles) bool {
        if (self.control == self.render or self.control == self.worker or self.render == self.worker) return false;
        inline for (.{ Role.control, Role.render, Role.worker }) |role| {
            const lane = self.get(role);
            if (lane.address != lane or lane.role != role or lane.incomplete() or
                lane.producer_guard.load(.acquire) or lane.head.load(.acquire) != 0 or
                lane.tail.load(.acquire) != 0 or lane.sequence != 0 or lane.last_operation != 0 or
                lane.active_operation != null) return false;
        }
        return true;
    }
};

pub const RoleCollector = struct {
    // Set only by initInPlace under lifecycle exclusion, immutable thereafter.
    address: ?*RoleCollector = null,
    role: Role = .control,
    cells: []Record = &.{},
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(Failure) = .init(.none),
    producer_guard: std.atomic.Value(bool) = .init(false),
    // Access only while holding the single-attempt producer entry guard.
    last_operation: u64 = 0,
    active_operation: ?u64 = null,
    point_ordinal: u64 = 0,
    sequence: u64 = 0,

    /// Lifecycle-only. Backing cells are caller-owned, fixed, and exclusively
    /// borrowed until both roles are quiescent. Never allocate in this method.
    pub fn initInPlace(self: *RoleCollector, role: Role, cells: []Record) InitError!void {
        if (!supported_target) return error.UnsupportedTarget;
        if (self.address != null) return error.AlreadyInitialized;
        if (cells.len == 0 or cells.len > max_capacity) return error.InvalidCapacity;
        self.role = role;
        self.cells = cells;
        self.address = self;
        // Preserve any failure raised by use-before-init. Initialization cannot
        // resurrect a collector after an invalid producer call.
    }

    pub fn failureValue(self: *const RoleCollector) Failure {
        return self.failure.load(.acquire);
    }
    /// False means only that this narrow collector has observed no loss yet.
    pub fn incomplete(self: *const RoleCollector) bool {
        return self.failureValue() != .none;
    }
    /// Bounded asynchronous invalidation only: no producer counters, queue
    /// state or guard are modified. Callers retain the same pinned lifetime.
    /// Concurrent points may finish, but completeness can never be restored.
    pub fn invalidateBinding(self: *RoleCollector) void {
        self.invalidateExternal(.binding_identity_mismatch);
    }
    pub fn invalidateSource(self: *RoleCollector) void {
        self.invalidateExternal(.source_incomplete);
    }
    fn invalidateExternal(self: *RoleCollector, reason: Failure) void {
        if (self.address == null) return self.fail(.uninitialized);
        if (self.address != self) return self.fail(.stale_address);
        self.fail(reason);
    }
    fn fail(self: *RoleCollector, reason: Failure) void {
        // Exactly one CAS; a later failure never replaces the first cause.
        _ = self.failure.cmpxchgStrong(.none, reason, .acq_rel, .acquire);
    }
    fn enter(self: *RoleCollector) bool {
        // Every producer entry is guarded before any non-atomic state read.
        if (self.producer_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            self.fail(.concurrent_producer);
            return false;
        }
        if (self.failureValue() != .none) {
            self.leave();
            return false;
        }
        if (self.address == null) {
            self.fail(.uninitialized);
            self.leave();
            return false;
        }
        if (self.address != self) {
            self.fail(.stale_address);
            self.leave();
            return false;
        }
        return true;
    }
    fn leave(self: *RoleCollector) void {
        self.producer_guard.store(false, .release);
    }
    /// Guarded helper. One capacity observation, one owned-value copy, one
    /// release publication. Return the same owned value, never resample a cell
    /// after publication: the consumer may already have released it for reuse.
    /// Failure leaves existing published cells untouched.
    fn append(self: *RoleCollector, record: Record) ?Record {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head == std.math.maxInt(usize) or self.sequence == std.math.maxInt(u64)) {
            self.fail(.counter_overflow);
            return null;
        }
        if (head - tail == self.cells.len) {
            self.fail(.queue_full);
            return null;
        }
        var owned = record;
        owned.sequence = self.sequence + 1;
        self.cells[head % self.cells.len] = owned;
        self.sequence = owned.sequence;
        self.head.store(head + 1, .release);
        return owned;
    }
    pub fn begin(self: *RoleCollector, operation: u64) void {
        _ = self.beginReceipt(operation);
    }
    /// One ordinary begin append, returning its exact owned publication data.
    /// Null means this call published no begin; sticky failure is unchanged.
    pub fn beginReceipt(self: *RoleCollector, operation: u64) ?EndpointReceipt {
        if (!self.enter()) return null;
        defer self.leave();
        if (self.active_operation != null) {
            self.fail(.operation_active);
            return null;
        }
        if (self.last_operation == std.math.maxInt(u64)) {
            self.fail(.counter_overflow);
            return null;
        }
        if (operation != self.last_operation + 1) {
            self.fail(.invalid_operation);
            return null;
        }
        const owned = self.append(.{ .role = self.role, .sequence = 0, .operation = operation, .point_ordinal = 1, .kind = .begin, .edge = .before }) orelse return null;
        self.last_operation = operation;
        self.active_operation = operation;
        self.point_ordinal = 1;
        return EndpointReceipt.fromRecord(owned);
    }
    pub fn point(self: *RoleCollector, site: Site, edge: Edge, index: u64, generation: u64, value: ?u64) void {
        if (!self.enter()) return;
        defer self.leave();
        self.pointGuarded(site, edge, index, generation, value);
    }
    /// Check site-to-lane role binding only after producer entry is acquired.
    /// A mismatch never touches operation/point counters or queue contents.
    pub fn pointFor(self: *RoleCollector, expected_role: Role, site: Site, edge: Edge, index: u64, generation: u64, value: ?u64) void {
        if (!self.enter()) return;
        defer self.leave();
        if (self.role != expected_role) {
            self.fail(.role_mismatch);
            return;
        }
        self.pointGuarded(site, edge, index, generation, value);
    }
    fn pointGuarded(self: *RoleCollector, site: Site, edge: Edge, index: u64, generation: u64, value: ?u64) void {
        const operation = self.active_operation orelse {
            self.fail(.no_active_operation);
            return;
        };
        const ordinal = std.math.add(u64, self.point_ordinal, 1) catch {
            self.fail(.counter_overflow);
            return;
        };
        if (self.append(.{ .role = self.role, .sequence = 0, .operation = operation, .point_ordinal = ordinal, .kind = .point, .site = site, .edge = edge, .index = index, .generation = generation, .value = value }) == null) return;
        self.point_ordinal = ordinal;
    }
    pub fn end(self: *RoleCollector, result_code: u32) void {
        _ = self.endReceipt(result_code);
    }
    /// One ordinary end append, preserving the original opaque result code.
    /// Null cannot stand in for an end seal; callers must still preserve their
    /// operation's true outcome, and a receipt never grants quiescence.
    pub fn endReceipt(self: *RoleCollector, result_code: u32) ?EndpointReceipt {
        if (!self.enter()) return null;
        defer self.leave();
        const operation = self.active_operation orelse {
            self.fail(.no_active_operation);
            return null;
        };
        const ordinal = std.math.add(u64, self.point_ordinal, 1) catch {
            self.fail(.counter_overflow);
            return null;
        };
        const owned = self.append(.{ .role = self.role, .sequence = 0, .operation = operation, .point_ordinal = ordinal, .kind = .end, .edge = .after, .point_count = ordinal, .result_code = result_code }) orelse return null;
        self.point_ordinal = ordinal;
        self.active_operation = null;
        return EndpointReceipt.fromRecord(owned);
    }
    /// Sole consumer only. Returns an owned copy, never a borrowed cell pointer.
    /// Failed lanes remain drainable; draining never clears their failure.
    pub fn pop(self: *RoleCollector) ?Record {
        // Lifecycle is immutable while attached; pop never reads producer state.
        if (self.address != self) return null;
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (tail == head) return null;
        const result = self.cells[tail % self.cells.len];
        self.tail.store(tail + 1, .release);
        return result;
    }
};

/// Fixed storage, initialized in place instead of returning/copying a large
/// array. Capacity is part of the caller's pre-admitted resource footprint.
pub fn Storage(comptime capacity: usize) type {
    if (capacity == 0 or capacity > max_capacity) @compileError("capture order capacity must be 1..65536");
    return struct {
        collector: RoleCollector = .{},
        records: [capacity]Record = undefined,
        pub fn initInPlace(self: *@This(), role: Role) InitError!void {
            try self.collector.initInPlace(role, &self.records);
        }
    };
}

test "capture order includes valueless points and original failed operation seal" {
    if (!supported_target) return error.SkipZigTest;
    var storage: Storage(8) = .{};
    try storage.initInPlace(.render);
    const lane = &storage.collector;
    const ring: Binding = .{ .collector = lane, .index = 7, .generation = 19 };
    lane.begin(1);
    ring.emit(.consumed_release, .before, null);
    ring.emit(.consumed_release, .after, 0);
    lane.end(51);
    for (0..4) |i| {
        const record = lane.pop().?;
        try std.testing.expectEqual(Role.render, record.role);
        try std.testing.expectEqual(@as(u64, 1), record.operation);
        try std.testing.expectEqual(@as(u64, i + 1), record.point_ordinal);
        try std.testing.expectEqual(@as(u64, i + 1), record.sequence);
        if (i == 0) try std.testing.expectEqual(Kind.begin, record.kind);
        if (i == 1 or i == 2) {
            try std.testing.expectEqual(Kind.point, record.kind);
            try std.testing.expectEqual(@as(?Site, .consumed_release), record.site);
            try std.testing.expectEqual(@as(u64, 7), record.index);
            try std.testing.expectEqual(@as(u64, 19), record.generation);
            try std.testing.expectEqual(if (i == 1) Edge.before else Edge.after, record.edge);
            try std.testing.expectEqual(if (i == 1) @as(?u64, null) else @as(?u64, 0), record.value);
        }
        if (i == 3) {
            try std.testing.expectEqual(Kind.end, record.kind);
            try std.testing.expectEqual(@as(u64, 4), record.point_count);
            try std.testing.expectEqual(@as(u32, 51), record.result_code);
        }
    }
    try std.testing.expect(lane.pop() == null);
    try std.testing.expect(!lane.incomplete());
}

test "capture order shares cross ring sequence and resets only operation ordinal" {
    if (!supported_target) return error.SkipZigTest;
    var storage: Storage(8) = .{};
    try storage.initInPlace(.render);
    const lane = &storage.collector;
    const a: Binding = .{ .collector = lane, .index = 3, .generation = 11 };
    const b: Binding = .{ .collector = lane, .index = 1, .generation = 12 };
    lane.begin(1);
    for ([_]Binding{ a, b, a }, 0..) |binding, i| {
        binding.emit(.consumed_release, .before, i + 1);
        binding.emit(.consumed_release, .after, i + 1);
    }
    lane.end(0);
    _ = lane.pop().?;
    for ([_]u64{ 3, 3, 1, 1, 3, 3 }, 0..) |index, i| {
        const record = lane.pop().?;
        try std.testing.expectEqual(index, record.index);
        try std.testing.expectEqual(@as(u64, i + 2), record.point_ordinal);
    }
    try std.testing.expectEqual(@as(u64, 8), lane.pop().?.point_count);
    lane.begin(2);
    lane.end(0);
    const next = lane.pop().?;
    try std.testing.expectEqual(@as(u64, 2), next.operation);
    try std.testing.expectEqual(@as(u64, 1), next.point_ordinal);
    try std.testing.expectEqual(@as(u64, 9), next.sequence);
    try std.testing.expectEqual(@as(u64, 2), lane.pop().?.point_count);
    try std.testing.expect(!lane.incomplete());
}

test "capture order queue exhaustion is permanent and does not control audio" {
    if (!supported_target) return error.SkipZigTest;
    var storage: Storage(2) = .{};
    try storage.initInPlace(.render);
    const lane = &storage.collector;
    const binding: Binding = .{ .collector = lane, .index = 0, .generation = 1 };
    var actual_audio_cursor: u64 = 0;
    lane.begin(1);
    for (0..3) |_| {
        binding.emit(.consumed_release, .before, actual_audio_cursor + 1);
        actual_audio_cursor += 1;
        binding.emit(.consumed_release, .after, actual_audio_cursor);
    }
    lane.end(99);
    try std.testing.expectEqual(@as(u64, 3), actual_audio_cursor);
    try std.testing.expectEqual(Failure.queue_full, lane.failureValue());
    try std.testing.expectEqual(Kind.begin, lane.pop().?.kind);
    try std.testing.expectEqual(Kind.point, lane.pop().?.kind);
    try std.testing.expect(lane.pop() == null);
    lane.end(0);
    lane.begin(2);
    lane.end(0);
    try std.testing.expect(lane.pop() == null);
    try std.testing.expectEqual(Failure.queue_full, lane.failureValue());
    try std.testing.expectError(error.AlreadyInitialized, storage.initInPlace(.render));
}

test "capture order rejects missing operation boundaries duplicate and out of order ids" {
    if (!supported_target) return error.SkipZigTest;
    for (0..7) |scenario| {
        var storage: Storage(8) = .{};
        try storage.initInPlace(.control);
        const lane = &storage.collector;
        switch (scenario) {
            0 => lane.begin(0),
            1 => lane.begin(2),
            2 => {
                lane.begin(1);
                lane.end(0);
                lane.begin(1);
            },
            3 => {
                lane.begin(1);
                lane.end(0);
                lane.begin(3);
            },
            4 => {
                lane.begin(1);
                lane.begin(2);
            },
            5 => lane.point(.ring_produced, .before, 0, 1, null),
            6 => lane.end(0),
            else => unreachable,
        }
        const expected: Failure = switch (scenario) {
            0...3 => .invalid_operation,
            4 => .operation_active,
            5, 6 => .no_active_operation,
            else => unreachable,
        };
        try std.testing.expectEqual(expected, lane.failureValue());
    }
}

test "capture order checks all counters without wrap" {
    if (!supported_target) return error.SkipZigTest;
    for (0..5) |scenario| {
        var storage: Storage(4) = .{};
        try storage.initInPlace(.worker);
        const lane = &storage.collector;
        switch (scenario) {
            0 => {
                lane.last_operation = std.math.maxInt(u64);
                lane.begin(1);
            },
            1 => {
                lane.sequence = std.math.maxInt(u64);
                lane.begin(1);
            },
            2 => {
                lane.head.store(std.math.maxInt(usize), .monotonic);
                lane.tail.store(std.math.maxInt(usize), .monotonic);
                lane.begin(1);
            },
            3, 4 => {
                lane.begin(1);
                _ = lane.pop();
                lane.point_ordinal = std.math.maxInt(u64);
                if (scenario == 3) lane.point(.ring_consumed, .before, 0, 1, null) else lane.end(0);
                try std.testing.expectEqual(std.math.maxInt(u64), lane.point_ordinal);
            },
            else => unreachable,
        }
        try std.testing.expectEqual(Failure.counter_overflow, lane.failureValue());
        try std.testing.expect(lane.pop() == null);
    }
}

test "capture order single attempt guard rejects every concurrent producer entry" {
    if (!supported_target) return error.SkipZigTest;
    for (0..3) |scenario| {
        var storage: Storage(4) = .{};
        try storage.initInPlace(.render);
        const lane = &storage.collector;
        // Deterministic occupied-entry seam, no timing-dependent thread race.
        lane.producer_guard.store(true, .release);
        switch (scenario) {
            0 => lane.begin(1),
            1 => lane.point(.consumed_release, .before, 0, 1, 1),
            2 => lane.end(0),
            else => unreachable,
        }
        try std.testing.expectEqual(Failure.concurrent_producer, lane.failureValue());
        try std.testing.expectEqual(@as(u64, 0), lane.last_operation);
        try std.testing.expectEqual(@as(u64, 0), lane.sequence);
        try std.testing.expect(lane.active_operation == null);
        try std.testing.expect(lane.producer_guard.load(.acquire));
        lane.producer_guard.store(false, .release);
        lane.begin(1);
        try std.testing.expect(lane.pop() == null);
    }
}

test "capture order roles are independent and a zero touch operation has a seal" {
    if (!supported_target) return error.SkipZigTest;
    var control: Storage(1) = .{};
    var render: Storage(2) = .{};
    var worker: Storage(2) = .{};
    try control.initInPlace(.control);
    try render.initInPlace(.render);
    try worker.initInPlace(.worker);
    control.collector.begin(1);
    control.collector.end(0);
    render.collector.begin(1);
    render.collector.end(0);
    worker.collector.begin(1);
    worker.collector.end(33);
    try std.testing.expectEqual(Failure.queue_full, control.collector.failureValue());
    try std.testing.expectEqual(Role.render, render.collector.pop().?.role);
    try std.testing.expectEqual(@as(u64, 2), render.collector.pop().?.point_count);
    try std.testing.expectEqual(Role.worker, worker.collector.pop().?.role);
    try std.testing.expectEqual(@as(u32, 33), worker.collector.pop().?.result_code);
    try std.testing.expect(!render.collector.incomplete());
    try std.testing.expect(!worker.collector.incomplete());
}

test "capture order initialization is bounded pinned and one shot" {
    if (!supported_target) return error.SkipZigTest;
    var collector: RoleCollector = .{};
    var cells: [1]Record = undefined;
    try std.testing.expectError(error.InvalidCapacity, collector.initInPlace(.control, cells[0..0]));
    try collector.initInPlace(.control, &cells);
    try std.testing.expectError(error.AlreadyInitialized, collector.initInPlace(.control, &cells));
    var copy = collector;
    copy.begin(1);
    try std.testing.expectEqual(Failure.stale_address, copy.failureValue());
    try std.testing.expect(!collector.incomplete());
    var uninitialized: RoleCollector = .{};
    uninitialized.begin(1);
    try std.testing.expectEqual(Failure.uninitialized, uninitialized.failureValue());
    try uninitialized.initInPlace(.worker, &cells);
    uninitialized.begin(1);
    try std.testing.expectEqual(Failure.uninitialized, uninitialized.failureValue());
}

test "capture order rejects mismatched site role before touching operation or queue" {
    if (!supported_target) return error.SkipZigTest;
    var storage: Storage(4) = .{};
    try storage.initInPlace(.worker);
    const lane = &storage.collector;
    const binding: Binding = .{ .collector = lane, .index = 2, .generation = 9 };
    lane.begin(1);
    binding.emitFor(.worker, .ring_produced, .before, null);
    try std.testing.expect(!lane.incomplete());
    try std.testing.expectEqual(@as(u64, 2), lane.point_ordinal);
    binding.emitFor(.render, .consumed_release, .after, 5);
    try std.testing.expectEqual(Failure.role_mismatch, lane.failureValue());
    try std.testing.expectEqual(@as(?u64, 1), lane.active_operation);
    try std.testing.expectEqual(@as(u64, 1), lane.last_operation);
    try std.testing.expectEqual(@as(u64, 2), lane.point_ordinal);
    try std.testing.expectEqual(@as(u64, 2), lane.sequence);
    try std.testing.expectEqual(Kind.begin, lane.pop().?.kind);
    try std.testing.expectEqual(@as(?Site, .ring_produced), lane.pop().?.site);
    try std.testing.expect(lane.pop() == null);
    binding.emitFor(.worker, .ring_produced, .after, 5);
    lane.end(0);
    try std.testing.expect(lane.pop() == null);
    try std.testing.expectEqual(Failure.role_mismatch, lane.failureValue());
}

test "capture order role check preserves first failure and checks entry before role" {
    if (!supported_target) return error.SkipZigTest;
    var full: Storage(1) = .{};
    try full.initInPlace(.control);
    full.collector.begin(1);
    full.collector.end(0);
    full.collector.pointFor(.render, .consumed_release, .before, 0, 1, 1);
    try std.testing.expectEqual(Failure.queue_full, full.collector.failureValue());
    try std.testing.expectEqual(@as(u64, 1), full.collector.sequence);
    var guarded: Storage(1) = .{};
    try guarded.initInPlace(.control);
    guarded.collector.producer_guard.store(true, .release);
    guarded.collector.pointFor(.render, .consumed_release, .before, 0, 1, 1);
    try std.testing.expectEqual(Failure.concurrent_producer, guarded.collector.failureValue());
    try std.testing.expectEqual(@as(u64, 0), guarded.collector.sequence);
    try std.testing.expect(guarded.collector.producer_guard.load(.acquire));
    guarded.collector.producer_guard.store(false, .release);
}

test "capture order attachment requires distinct fresh pinned role lanes" {
    if (!supported_target) return error.SkipZigTest;
    var c: Storage(4) = .{};
    var r: Storage(4) = .{};
    var w: Storage(4) = .{};
    try c.initInPlace(.control);
    try r.initInPlace(.render);
    try w.initInPlace(.worker);
    const roles: Roles = .{ .control = &c.collector, .render = &r.collector, .worker = &w.collector };
    try std.testing.expect(roles.pristine());
    try std.testing.expect(roles.get(.worker) == &w.collector);
    try std.testing.expect(!(Roles{ .control = &c.collector, .render = &c.collector, .worker = &w.collector }).pristine());
    try std.testing.expect(!(Roles{ .control = &r.collector, .render = &c.collector, .worker = &w.collector }).pristine());
    var moved = c.collector;
    try std.testing.expect(!(Roles{ .control = &moved, .render = &r.collector, .worker = &w.collector }).pristine());
    c.collector.begin(1);
    c.collector.end(0);
    while (c.collector.pop() != null) {}
    try std.testing.expect(!roles.pristine());
}

test "capture order external invalidation is sticky without touching producer state" {
    if (!supported_target) return error.SkipZigTest;
    var source: Storage(4) = .{};
    try source.initInPlace(.render);
    source.collector.begin(1);
    source.collector.producer_guard.store(true, .release);
    source.collector.invalidateSource();
    try std.testing.expectEqual(Failure.source_incomplete, source.collector.failureValue());
    try std.testing.expect(source.collector.producer_guard.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), source.collector.sequence);
    try std.testing.expectEqual(@as(?u64, 1), source.collector.active_operation);
    source.collector.invalidateBinding();
    try std.testing.expectEqual(Failure.source_incomplete, source.collector.failureValue());
    source.collector.producer_guard.store(false, .release);
    try std.testing.expectEqual(Kind.begin, source.collector.pop().?.kind);
    source.collector.end(0);
    try std.testing.expect(source.collector.pop() == null);
    var identity: Storage(2) = .{};
    try identity.initInPlace(.control);
    identity.collector.invalidateBinding();
    identity.collector.invalidateSource();
    try std.testing.expectEqual(Failure.binding_identity_mismatch, identity.collector.failureValue());
    var moved = identity.collector;
    // First cause is never overwritten, including when a later misuse copies it.
    moved.invalidateSource();
    try std.testing.expectEqual(Failure.binding_identity_mismatch, moved.failureValue());
    var fresh: Storage(2) = .{};
    try fresh.initInPlace(.worker);
    var fresh_copy = fresh.collector;
    fresh_copy.invalidateBinding();
    try std.testing.expectEqual(Failure.stale_address, fresh_copy.failureValue());
    try std.testing.expectEqual(Failure.none, fresh.collector.failureValue());
    var absent: RoleCollector = .{};
    absent.invalidateSource();
    try std.testing.expectEqual(Failure.uninitialized, absent.failureValue());
}

fn expectEndpointReceiptMatchesRecord(receipt: EndpointReceipt, record: Record) !void {
    try std.testing.expect(record.kind == .begin or record.kind == .end);
    try std.testing.expectEqualDeep(EndpointReceipt{
        .role = record.role,
        .sequence = record.sequence,
        .operation = record.operation,
        .point_ordinal = record.point_ordinal,
        .kind = record.kind,
        .result_code = record.result_code,
    }, receipt);
}

test "capture order endpoint receipts match actual records across valueless points" {
    if (!supported_target) return error.SkipZigTest;
    var storage: Storage(5) = .{};
    try storage.initInPlace(.render);
    const lane = &storage.collector;
    const first = lane.beginReceipt(1).?;
    lane.point(.consumed_release, .before, 7, 19, null);
    lane.point(.consumed_release, .after, 7, 19, null);
    lane.pointFor(.render, .ring_consumed, .after, 7, 19, 0);
    const last = lane.endReceipt(0xFEDCBA98).?;
    try std.testing.expectEqualDeep(EndpointReceipt{
        .role = .render,
        .sequence = 1,
        .operation = 1,
        .point_ordinal = 1,
        .kind = .begin,
        .result_code = 0,
    }, first);
    try std.testing.expectEqualDeep(EndpointReceipt{
        .role = .render,
        .sequence = 5,
        .operation = 1,
        .point_ordinal = 5,
        .kind = .end,
        .result_code = 0xFEDCBA98,
    }, last);
    try expectEndpointReceiptMatchesRecord(first, lane.pop().?);
    for (0..3) |i| {
        const record = lane.pop().?;
        try std.testing.expectEqual(Kind.point, record.kind);
        try std.testing.expectEqual(@as(u64, i + 2), record.sequence);
        try std.testing.expectEqual(@as(u64, i + 2), record.point_ordinal);
        try std.testing.expectEqual(if (i < 2) @as(?u64, null) else @as(?u64, 0), record.value);
    }
    const end_record = lane.pop().?;
    try expectEndpointReceiptMatchesRecord(last, end_record);
    try std.testing.expectEqual(last.point_ordinal, end_record.point_count);
    try std.testing.expect(lane.pop() == null);
    try std.testing.expect(!lane.incomplete());
    try std.testing.expect(!lane.producer_guard.load(.acquire));
}

test "capture order zero touch endpoint receipts preserve every result code bit" {
    if (!supported_target) return error.SkipZigTest;
    var storage: Storage(2) = .{};
    try storage.initInPlace(.worker);
    const lane = &storage.collector;
    for ([_]u32{ 0, 51, 0x80000000, std.math.maxInt(u32) }, 0..) |code, i| {
        const operation: u64 = i + 1;
        const first = lane.beginReceipt(operation).?;
        const last = lane.endReceipt(code).?;
        try std.testing.expectEqual(Role.worker, first.role);
        try std.testing.expectEqual(operation, first.operation);
        try std.testing.expectEqual(operation, last.operation);
        try std.testing.expectEqual(@as(u64, 1), first.point_ordinal);
        try std.testing.expectEqual(@as(u64, 2), last.point_ordinal);
        try std.testing.expectEqual(@as(u64, i * 2 + 1), first.sequence);
        try std.testing.expectEqual(@as(u64, i * 2 + 2), last.sequence);
        try std.testing.expectEqual(@as(u32, 0), first.result_code);
        try std.testing.expectEqual(code, last.result_code);
        try expectEndpointReceiptMatchesRecord(first, lane.pop().?);
        try expectEndpointReceiptMatchesRecord(last, lane.pop().?);
        try std.testing.expect(lane.pop() == null);
    }
    try std.testing.expect(!lane.incomplete());
}

test "capture order failed endpoint publication returns no receipt or synthetic end" {
    if (!supported_target) return error.SkipZigTest;
    var full: Storage(1) = .{};
    try full.initInPlace(.control);
    const first = full.collector.beginReceipt(1).?;
    try std.testing.expect(full.collector.endReceipt(99) == null);
    try std.testing.expectEqual(Failure.queue_full, full.collector.failureValue());
    try std.testing.expectEqual(@as(?u64, 1), full.collector.active_operation);
    try std.testing.expectEqual(@as(u64, 1), full.collector.point_ordinal);
    try expectEndpointReceiptMatchesRecord(first, full.collector.pop().?);
    full.collector.invalidateSource();
    try std.testing.expect(full.collector.endReceipt(0) == null);
    try std.testing.expect(full.collector.beginReceipt(2) == null);
    try std.testing.expect(full.collector.pop() == null);
    try std.testing.expectEqual(Failure.queue_full, full.collector.failureValue());

    var absent: Storage(1) = .{};
    try absent.initInPlace(.render);
    try std.testing.expect(absent.collector.endReceipt(std.math.maxInt(u32)) == null);
    try std.testing.expectEqual(Failure.no_active_operation, absent.collector.failureValue());
    try std.testing.expect(absent.collector.beginReceipt(1) == null);
    try std.testing.expect(absent.collector.pop() == null);

    var begin_full: Storage(2) = .{};
    try begin_full.initInPlace(.worker);
    _ = begin_full.collector.beginReceipt(1).?;
    _ = begin_full.collector.endReceipt(1).?;
    try std.testing.expect(begin_full.collector.beginReceipt(2) == null);
    try std.testing.expectEqual(Failure.queue_full, begin_full.collector.failureValue());
    try std.testing.expectEqual(@as(u64, 1), begin_full.collector.last_operation);
    try std.testing.expect(begin_full.collector.active_operation == null);
    try std.testing.expectEqual(@as(u64, 2), begin_full.collector.sequence);
}

test "capture order endpoint counter failures return null without wrapping" {
    if (!supported_target) return error.SkipZigTest;
    for (0..6) |scenario| {
        var storage: Storage(2) = .{};
        try storage.initInPlace(.worker);
        const lane = &storage.collector;
        if (scenario >= 3) {
            _ = lane.beginReceipt(1).?;
            _ = lane.pop().?;
        }
        switch (scenario) {
            0 => lane.last_operation = std.math.maxInt(u64),
            1, 4 => lane.sequence = std.math.maxInt(u64),
            2, 5 => {
                lane.head.store(std.math.maxInt(usize), .monotonic);
                lane.tail.store(std.math.maxInt(usize), .monotonic);
            },
            3 => lane.point_ordinal = std.math.maxInt(u64),
            else => unreachable,
        }
        const sequence = lane.sequence;
        const ordinal = lane.point_ordinal;
        const operation = lane.active_operation;
        const head = lane.head.load(.monotonic);
        const result = if (scenario < 3) lane.beginReceipt(1) else lane.endReceipt(0xFFFFFFFF);
        try std.testing.expect(result == null);
        try std.testing.expectEqual(Failure.counter_overflow, lane.failureValue());
        try std.testing.expectEqual(sequence, lane.sequence);
        try std.testing.expectEqual(ordinal, lane.point_ordinal);
        try std.testing.expectEqual(operation, lane.active_operation);
        try std.testing.expectEqual(head, lane.head.load(.monotonic));
        try std.testing.expect(lane.pop() == null);
        try std.testing.expect(!lane.producer_guard.load(.acquire));
    }
}

test "capture order owned endpoint receipts survive publication pop and cell reuse" {
    if (!supported_target) return error.SkipZigTest;
    var storage: Storage(1) = .{};
    try storage.initInPlace(.render);
    const lane = &storage.collector;
    const first = lane.beginReceipt(1).?;
    const first_record = lane.pop().?;
    const last = lane.endReceipt(0xFFFFFFFF).?;
    const last_record = lane.pop().?;
    for (2..5) |operation| {
        _ = lane.beginReceipt(operation).?;
        _ = lane.pop().?;
        lane.point(.ring_consumed, .after, 90, 12, operation);
        _ = lane.pop().?;
        _ = lane.endReceipt(0).?;
        _ = lane.pop().?;
    }
    // Every append above overwrote the sole cell. Earlier receipts and popped
    // records remain independent owned values, including the failed result.
    try std.testing.expectEqual(@as(u64, 11), storage.records[0].sequence);
    try std.testing.expectEqual(@as(u64, 4), storage.records[0].operation);
    try std.testing.expectEqualDeep(EndpointReceipt{
        .role = .render,
        .sequence = 1,
        .operation = 1,
        .point_ordinal = 1,
        .kind = .begin,
        .result_code = 0,
    }, first);
    try std.testing.expectEqualDeep(EndpointReceipt{
        .role = .render,
        .sequence = 2,
        .operation = 1,
        .point_ordinal = 2,
        .kind = .end,
        .result_code = 0xFFFFFFFF,
    }, last);
    try expectEndpointReceiptMatchesRecord(first, first_record);
    try expectEndpointReceiptMatchesRecord(last, last_record);
    lane.invalidateSource();
    try std.testing.expect(lane.beginReceipt(5) == null);
    try expectEndpointReceiptMatchesRecord(first, first_record);
    try expectEndpointReceiptMatchesRecord(last, last_record);
}

test "capture order void wrappers preserve receipt API records and failure semantics" {
    if (!supported_target) return error.SkipZigTest;
    const Calls = struct {
        fn begin(lane: *RoleCollector, receipt_api: bool, operation: u64) void {
            if (receipt_api) {
                _ = lane.beginReceipt(operation);
            } else {
                lane.begin(operation);
            }
        }
        fn end(lane: *RoleCollector, receipt_api: bool, result_code: u32) void {
            if (receipt_api) {
                _ = lane.endReceipt(result_code);
            } else {
                lane.end(result_code);
            }
        }
    };
    for ([_]Role{ .control, .render, .worker }) |role| {
        for (0..9) |scenario| {
            var wrappers: Storage(4) = .{};
            var receipts: Storage(4) = .{};
            try wrappers.initInPlace(role);
            try receipts.initInPlace(role);
            for ([_]*RoleCollector{ &wrappers.collector, &receipts.collector }, 0..) |lane, i| {
                const receipt_api = i == 1;
                switch (scenario) {
                    0 => {
                        Calls.begin(lane, receipt_api, 1);
                        lane.point(.ring_consumed, .before, 7, 19, null);
                        lane.pointFor(role, .ring_consumed, .after, 7, 19, 0);
                        Calls.end(lane, receipt_api, 0xFEDCBA98);
                    },
                    1 => {
                        Calls.begin(lane, receipt_api, 1);
                        Calls.end(lane, receipt_api, 0);
                        Calls.begin(lane, receipt_api, 2);
                        Calls.end(lane, receipt_api, 99);
                    },
                    2 => {
                        Calls.begin(lane, receipt_api, 1);
                        for (0..5) |_| lane.point(.ring_produced, .before, 2, 12, null);
                        Calls.end(lane, receipt_api, 77);
                    },
                    3 => Calls.end(lane, receipt_api, 33),
                    4 => Calls.begin(lane, receipt_api, 0),
                    5 => {
                        Calls.begin(lane, receipt_api, 1);
                        Calls.begin(lane, receipt_api, 2);
                    },
                    6 => {
                        lane.producer_guard.store(true, .release);
                        Calls.begin(lane, receipt_api, 1);
                    },
                    7 => {
                        Calls.begin(lane, receipt_api, 1);
                        lane.invalidateSource();
                        Calls.end(lane, receipt_api, 88);
                    },
                    8 => {
                        Calls.begin(lane, receipt_api, 1);
                        lane.point_ordinal = std.math.maxInt(u64);
                        Calls.end(lane, receipt_api, 0xFFFFFFFF);
                    },
                    else => unreachable,
                }
            }
            const a = &wrappers.collector;
            const b = &receipts.collector;
            try std.testing.expectEqual(a.failureValue(), b.failureValue());
            try std.testing.expectEqual(a.producer_guard.load(.acquire), b.producer_guard.load(.acquire));
            try std.testing.expectEqual(a.last_operation, b.last_operation);
            try std.testing.expectEqual(a.active_operation, b.active_operation);
            try std.testing.expectEqual(a.point_ordinal, b.point_ordinal);
            try std.testing.expectEqual(a.sequence, b.sequence);
            try std.testing.expectEqual(a.head.load(.monotonic), b.head.load(.monotonic));
            try std.testing.expectEqual(a.tail.load(.monotonic), b.tail.load(.monotonic));
            while (true) {
                const old_record = a.pop();
                const new_record = b.pop();
                // Compare all defined Record fields, not unspecified struct
                // padding. No endpoint receipt adds a queue record or seal.
                try std.testing.expectEqualDeep(old_record, new_record);
                if (old_record == null) break;
            }
            a.producer_guard.store(false, .release);
            b.producer_guard.store(false, .release);
        }
    }
}

test "capture order receipt failure paths keep the single attempt producer guard" {
    if (!supported_target) return error.SkipZigTest;
    for (0..2) |scenario| {
        var storage: Storage(2) = .{};
        try storage.initInPlace(.render);
        const lane = &storage.collector;
        lane.producer_guard.store(true, .release);
        const receipt = if (scenario == 0) lane.beginReceipt(1) else lane.endReceipt(7);
        try std.testing.expect(receipt == null);
        try std.testing.expectEqual(Failure.concurrent_producer, lane.failureValue());
        try std.testing.expect(lane.producer_guard.load(.acquire));
        try std.testing.expectEqual(@as(u64, 0), lane.sequence);
        try std.testing.expectEqual(@as(u64, 0), lane.last_operation);
        try std.testing.expect(lane.active_operation == null);
        lane.producer_guard.store(false, .release);
        try std.testing.expect(lane.beginReceipt(1) == null);
        try std.testing.expect(lane.pop() == null);
    }
    var absent: RoleCollector = .{};
    try std.testing.expect(absent.beginReceipt(1) == null);
    try std.testing.expectEqual(Failure.uninitialized, absent.failureValue());
    var storage: Storage(2) = .{};
    try storage.initInPlace(.control);
    var moved = storage.collector;
    try std.testing.expect(moved.beginReceipt(1) == null);
    try std.testing.expectEqual(Failure.stale_address, moved.failureValue());
    try std.testing.expect(!storage.collector.incomplete());
}

test "capture order invalidation after producer entry does not erase a published receipt" {
    if (!supported_target) return error.SkipZigTest;
    var storage: Storage(1) = .{};
    try storage.initInPlace(.worker);
    const lane = &storage.collector;
    // Deterministic interleaving of the existing guarded helper: external
    // invalidation may happen after entry succeeds and before publication.
    // Receipt creation must use append's owned result, not reread failure or
    // the queue cell and reinterpret a successful publication as missing.
    try std.testing.expect(lane.enter());
    lane.invalidateSource();
    const owned = lane.append(.{
        .role = .worker,
        .sequence = 0,
        .operation = 1,
        .point_ordinal = 1,
        .kind = .begin,
        .edge = .before,
    }).?;
    const receipt = EndpointReceipt.fromRecord(owned);
    lane.leave();
    try std.testing.expectEqual(Failure.source_incomplete, lane.failureValue());
    try std.testing.expectEqual(@as(u64, 1), receipt.sequence);
    try expectEndpointReceiptMatchesRecord(receipt, lane.pop().?);
    try std.testing.expect(lane.endReceipt(0) == null);
    try std.testing.expect(lane.pop() == null);
}
