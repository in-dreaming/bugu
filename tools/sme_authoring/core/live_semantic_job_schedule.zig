//! Pure, streaming preflight planner for ONE initially-free Service job pool.
//! This module has no engine imports, native gates, allocator, IO, atomics,
//! recording/replay integration, or reference-derived load results. A scan's
//! eligible boolean must eventually come from independent execution INPUT.
//!
//! Supported scope is deliberately 1..48 slots, not every Service profile.
//! prefetch.Profile permits up to 256; its default job_capacity is 48. Reject
//! larger pools rather than truncating them. A fresh planner starts all free;
//! finish requires all free again. Prefix planning alone is not completion.
//! The caller must first validate global occurrence uniqueness in the source
//! event stream. This fixed-space planner checks bracket/per-role order and
//! temporal embeddability, not uniqueness of every historical cross-role stamp.
const std = @import("std");

pub const hard_slot_cap: usize = 48;
pub const Role = enum(u8) { control, worker };
pub const Kind = enum { scan, queued, running, completed, free };
pub const State = enum { free, queued, running, completed };
pub const Error = error{
    InvalidState,
    InvalidOrder,
    InvalidOperation,
    InvalidGeneration,
    InvalidSlot,
    UnsupportedSlots,
    MissingHead,
    ImpossibleSchedule,
    Incomplete,
    CounterOverflow,
};
pub const Operation = struct {
    role: Role,
    kind: Kind,
    before: u64,
    after: u64,
    index: u64,
    /// Job descriptor ID for stores; exactly zero for scans. This is NOT a
    /// stream-slot generation. IDs are global to this one Service lifetime.
    generation: u64,
    /// Worker observes state == queued; Control observes state == completed.
    /// Required for scans and forbidden for stores. Never a forced return.
    eligible: ?bool = null,
};
pub const Selection = struct { op: Operation, ordinal: u64 };
const Slot = struct { state: State = .free, generation: u64 = 0 };
const RoleState = struct {
    head: ?Operation = null,
    eof: bool = false,
    last_after: u64 = 0,
};

/// Caller supplies each role's operations in original, non-overlapping source
/// order. Before EVERY next(), refill each empty non-EOF head, or roleEOF it.
/// next() never skips a head, reads ahead, or mistakes a missing head for EOF.
/// It returns null only once both inputs are explicitly exhausted. Call finish
/// separately to certify the complete initially-free -> finally-free history.
/// Errors do not consume the current heads or apply the failed operation;
/// already returned selections remain only a prefix, not a completed proof.
/// This is a movable, single-threaded value; no pinned address or runtime use.
pub const Scheduler = struct {
    initialized: bool = false,
    finished: bool = false,
    job_slots: usize = 0,
    slots: [hard_slot_cap]Slot = .{Slot{}} ** hard_slot_cap,
    roles: [2]RoleState = .{ .{}, .{} },
    last_queued_generation: u64 = 0,
    next_ordinal: u64 = 0,
    /// Max BEFORE of all selected operations. For an ordered finite set of
    /// open brackets, max(previous BEFOREs, this BEFORE) < this AFTER is the
    /// exact dense-time embeddability condition. Several atomic operations
    /// may occupy one marker gap; do not round this cursor up to an integer
    /// occurrence or advance it to a selected operation's AFTER.
    frontier: u64 = 0,

    pub fn init(self: *Scheduler, job_slots: usize) Error!void {
        if (self.initialized) return error.InvalidState;
        if (job_slots == 0 or job_slots > hard_slot_cap) return error.UnsupportedSlots;
        self.* = .{ .initialized = true, .job_slots = job_slots };
    }
    fn active(self: *const Scheduler) Error!void {
        if (!self.initialized or self.finished) return error.InvalidState;
    }
    pub fn push(self: *Scheduler, op: Operation) Error!void {
        try self.active();
        const r: usize = @intFromEnum(op.role);
        const role = &self.roles[r];
        if (role.eof or role.head != null) return error.InvalidState;
        if (op.before == 0 or op.after <= op.before or op.before <= role.last_after) return error.InvalidOrder;
        if (op.index >= self.job_slots) return error.InvalidSlot;
        if (op.kind == .scan) {
            if (op.eligible == null) return error.InvalidOperation;
            if (op.generation != 0) return error.InvalidGeneration;
        } else {
            if (op.eligible != null) return error.InvalidOperation;
            const owner: Role = switch (op.kind) {
                .queued, .free => .control,
                .running, .completed => .worker,
                .scan => unreachable,
            };
            if (op.role != owner) return error.InvalidOperation;
            // music_stream.Service refuses a request when next_job == maxInt
            // BEFORE assigning/incrementing it. Thus maxInt is never a job ID.
            if (op.generation == 0 or op.generation == std.math.maxInt(u64)) return error.InvalidGeneration;
            // All queued publications belong to Control. Validate freshness
            // in that INPUT order, not Worker order or a globally sorted ID
            // cursor. Gaps are allowed; repeats/reuse anywhere are not.
            if (op.kind == .queued and op.generation <= self.last_queued_generation) return error.InvalidGeneration;
        }
        role.head = op;
        role.last_after = op.after;
        if (op.kind == .queued) self.last_queued_generation = op.generation;
    }
    pub fn roleEOF(self: *Scheduler, role: Role) Error!void {
        try self.active();
        const input = &self.roles[@intFromEnum(role)];
        if (input.eof or input.head != null) return error.InvalidState;
        input.eof = true;
    }
    fn predicate(role: Role, state: State) bool {
        return state == (if (role == .worker) State.queued else State.completed);
    }
    fn enabledAt(op: Operation, slot: Slot) bool {
        return switch (op.kind) {
            .scan => predicate(op.role, slot.state) == op.eligible.?,
            .queued => slot.state == .free,
            .running => slot.state == .queued and slot.generation == op.generation,
            .completed => slot.state == .running and slot.generation == op.generation,
            .free => slot.state == .completed and slot.generation == op.generation,
        };
    }
    fn resultingSlot(op: Operation, prior: Slot) Slot {
        return switch (op.kind) {
            .scan => prior,
            .queued => .{ .state = .queued, .generation = op.generation },
            .running => .{ .state = .running, .generation = prior.generation },
            .completed => .{ .state = .completed, .generation = prior.generation },
            .free => .{ .state = .free, .generation = prior.generation },
        };
    }
    fn enabled(self: *const Scheduler, op: Operation) bool {
        return enabledAt(op, self.slots[@intCast(op.index)]);
    }
    pub fn next(self: *Scheduler) Error!?Selection {
        try self.active();
        for (self.roles) |role| if (!role.eof and role.head == null) return error.MissingHead;
        if (self.roles[0].head == null and self.roles[1].head == null) return null;
        const earliest: usize = if (self.roles[0].head) |control|
            (if (self.roles[1].head) |worker| (if (control.after < worker.after) @as(usize, 0) else 1) else 0)
        else
            1;
        const first = self.roles[earliest].head.?;
        if (@max(self.frontier, first.before) >= first.after) return error.ImpossibleSchedule;
        var chosen = earliest;
        if (self.roles[1 - earliest].head) |other| {
            const overlaps_deadline = @max(self.frontier, other.before) < first.after;
            if (self.enabled(first)) {
                // Critical exception to earliest AFTER: a started false scan
                // must precede a queued/completed publication which would
                // turn its predicate true, even if its AFTER is much later.
                // running/free cannot flip the OTHER role's scan predicate.
                if (overlaps_deadline and first.kind != .scan and other.kind == .scan and
                    other.eligible == false and other.index == first.index and self.enabled(other) and
                    !enabledAt(other, resultingSlot(first, self.slots[@intCast(first.index)])))
                    chosen = 1 - earliest;
            } else {
                // The other CURRENT head is the only operation which can
                // precede the earliest deadline. Its successor begins after
                // its AFTER, which is >= first.after. No future publication,
                // other-slot publication, or read can rescue a blocked head.
                if (!overlaps_deadline or other.kind == .scan or other.index != first.index or
                    !self.enabled(other) or !enabledAt(first, resultingSlot(other, self.slots[@intCast(other.index)])))
                    return error.ImpossibleSchedule;
                chosen = 1 - earliest;
            }
        } else if (!self.enabled(first)) return error.ImpossibleSchedule;

        const op = self.roles[chosen].head.?;
        const cursor = @max(self.frontier, op.before);
        // Preflight BOTH deadlines before mutating anything, including when
        // the selected operation is the later-deadline exceptional head.
        if (cursor >= op.after or cursor >= first.after or !self.enabled(op)) return error.ImpossibleSchedule;
        const advanced = std.math.add(u64, self.next_ordinal, 1) catch return error.CounterOverflow;
        const selected: Selection = .{ .op = op, .ordinal = self.next_ordinal };
        self.slots[@intCast(op.index)] = resultingSlot(op, self.slots[@intCast(op.index)]);
        self.roles[chosen].head = null;
        self.frontier = cursor;
        self.next_ordinal = advanced;
        return selected;
    }
    pub fn finish(self: *Scheduler) Error!void {
        try self.active();
        for (self.roles) |role| if (!role.eof or role.head != null) return error.Incomplete;
        for (self.slots[0..self.job_slots]) |slot| if (slot.state != .free) return error.Incomplete;
        self.finished = true;
    }
};

// Completeness argument for this narrow two-role FSM (not a general scheduler):
// Let A be the earliest-AFTER head, B the other head. Before A's deadline, only
// A and B can occur: B's successor starts strictly after B.after >= A.after.
// If A is disabled, B must be an enabled same-slot store immediately enabling
// A, or no witness exists. If A is enabled, move it to the front of a witness:
// reads commute, different slots commute, and two enabled same-slot stores
// cannot coexist in this single-successor FSM. The only noncommuting case is
// A's store changing B's scan. A cross-role store can only change false->true
// (queued for Worker, completed for Control). Preserve an enabled false scan
// first; otherwise A first is safe. Both choices satisfy the earliest deadline
// using frontier, so induction preserves a feasible, bracket-embedded suffix.
// Removing either role ownership or non-overlapping per-role brackets would
// invalidate this argument and is outside this module's contract.

fn testScan(role: Role, before: u64, after: u64, index: u64, eligible: bool) Operation {
    return .{ .role = role, .kind = .scan, .before = before, .after = after, .index = index, .generation = 0, .eligible = eligible };
}
fn testStore(kind: Kind, before: u64, after: u64, index: u64, generation: u64) Operation {
    return .{ .role = if (kind == .queued or kind == .free) .control else .worker, .kind = kind, .before = before, .after = after, .index = index, .generation = generation };
}
const SmallResult = struct { items: [16]Selection = undefined, len: usize = 0 };
fn runSmall(job_slots: usize, control: []const Operation, worker: []const Operation) !SmallResult {
    var planner: Scheduler = .{};
    try planner.init(job_slots);
    const inputs = [2][]const Operation{ control, worker };
    var cursors: [2]usize = .{ 0, 0 };
    var result: SmallResult = .{};
    var frontier: u64 = 0;
    while (true) {
        for (0..2) |r| {
            if (planner.roles[r].head == null and !planner.roles[r].eof) {
                if (cursors[r] < inputs[r].len) {
                    try planner.push(inputs[r][cursors[r]]);
                    cursors[r] += 1;
                } else try planner.roleEOF(@enumFromInt(r));
            }
        }
        const selected = (try planner.next()) orelse break;
        try std.testing.expect(result.len < result.items.len);
        try std.testing.expectEqual(@as(u64, @intCast(result.len)), selected.ordinal);
        frontier = @max(frontier, selected.op.before);
        try std.testing.expect(frontier < selected.op.after);
        result.items[result.len] = selected;
        result.len += 1;
    }
    try planner.finish();
    return result;
}

test "publication conflicts cover both predicates, booleans, start orders and all six bracket shapes" {
    // {read.before, read.after, write.before, write.after}; all interleavings
    // of two pairs: both serial, both crossing, and both nesting directions.
    const shapes = [_][4]u64{
        .{ 1, 2, 3, 4 }, .{ 3, 4, 1, 2 },
        .{ 1, 3, 2, 4 }, .{ 2, 4, 1, 3 },
        .{ 1, 4, 2, 3 }, .{ 2, 3, 1, 4 },
    };
    for ([_]Kind{ .queued, .completed }) |publication| {
        for ([_]bool{ false, true }) |eligible| {
            for (shapes, 0..) |shape, shape_index| {
                var control: [3]Operation = undefined;
                var worker: [3]Operation = undefined;
                var c: usize = 0;
                var w: usize = 0;
                const base: u64 = if (publication == .completed) 4 else 0;
                const read = testScan(if (publication == .queued) .worker else .control, base + shape[0], base + shape[1], 0, eligible);
                const store = testStore(publication, base + shape[2], base + shape[3], 0, 1);
                if (publication == .queued) {
                    control[c] = store;
                    c += 1;
                    worker[w] = read;
                    w += 1;
                    worker[w] = testStore(.running, 5, 6, 0, 1);
                    w += 1;
                    worker[w] = testStore(.completed, 7, 8, 0, 1);
                    w += 1;
                } else {
                    control[c] = testStore(.queued, 1, 2, 0, 1);
                    c += 1;
                    control[c] = read;
                    c += 1;
                    worker[w] = testStore(.running, 3, 4, 0, 1);
                    w += 1;
                    worker[w] = store;
                    w += 1;
                }
                control[c] = testStore(.free, 9, 10, 0, 1);
                c += 1;
                if ((shape_index == 0 and eligible) or (shape_index == 1 and !eligible)) {
                    try std.testing.expectError(error.ImpossibleSchedule, runSmall(1, control[0..c], worker[0..w]));
                } else {
                    const result = try runSmall(1, control[0..c], worker[0..w]);
                    var read_ordinal: ?u64 = null;
                    var store_ordinal: ?u64 = null;
                    for (result.items[0..result.len]) |selected| {
                        if (selected.op.before == read.before) read_ordinal = selected.ordinal;
                        if (selected.op.before == store.before) store_ordinal = selected.ordinal;
                    }
                    try std.testing.expect(read_ordinal != null and store_ordinal != null);
                    try std.testing.expectEqual(!eligible, read_ordinal.? < store_ordinal.?);
                }
            }
        }
    }
}

test "running and free do not flip the other role predicate" {
    _ = try runSmall(1, &.{
        testStore(.queued, 1, 2, 0, 1),
        testScan(.control, 3, 6, 0, false),
        testStore(.free, 11, 12, 0, 1),
    }, &.{
        testStore(.running, 4, 5, 0, 1),
        testStore(.completed, 7, 8, 0, 1),
        testScan(.worker, 9, 14, 0, false),
    });
    _ = try runSmall(1, &.{
        testStore(.queued, 1, 2, 0, 1),
        testScan(.control, 4, 5, 0, false),
        testStore(.free, 9, 14, 0, 1),
    }, &.{
        testStore(.running, 3, 6, 0, 1),
        testStore(.completed, 7, 8, 0, 1),
        testScan(.worker, 11, 12, 0, false),
    });
}

test "only the other started current same-slot store can unlock the earliest head" {
    const result = try runSmall(1, &.{
        testStore(.queued, 1, 4, 0, 1),
        testStore(.free, 6, 7, 0, 1),
    }, &.{
        testStore(.running, 2, 3, 0, 1),
        testStore(.completed, 5, 8, 0, 1),
    });
    try std.testing.expectEqual(Kind.queued, result.items[0].op.kind);
    try std.testing.expectEqual(Kind.completed, result.items[2].op.kind);
    try std.testing.expectError(error.ImpossibleSchedule, runSmall(2, &.{
        testStore(.queued, 2, 4, 1, 1),
    }, &.{testScan(.worker, 1, 3, 0, true)}));
    try std.testing.expectError(error.ImpossibleSchedule, runSmall(1, &.{
        testStore(.queued, 3, 4, 0, 1),
    }, &.{testScan(.worker, 1, 2, 0, true)}));
    try std.testing.expectError(error.ImpossibleSchedule, runSmall(2, &.{
        testScan(.control, 2, 6, 1, false),
        testStore(.queued, 7, 8, 0, 1),
    }, &.{testScan(.worker, 1, 5, 0, true)}));
    // The false scan can linearize before this nested publication, but must
    // not drag its AFTER into the time cursor and strand the queued deadline.
    _ = try runSmall(2, &.{
        testStore(.queued, 2, 3, 0, 1),
        testScan(.control, 4, 5, 1, false),
        testStore(.free, 15, 16, 0, 1),
    }, &.{
        testScan(.worker, 1, 10, 0, false),
        testStore(.running, 11, 12, 0, 1),
        testStore(.completed, 13, 14, 0, 1),
    });
}

test "initialization, heads, EOF, input shape and source order are strict" {
    var planner: Scheduler = .{};
    try std.testing.expectError(error.InvalidState, planner.next());
    try std.testing.expectError(error.UnsupportedSlots, planner.init(0));
    try std.testing.expectError(error.UnsupportedSlots, planner.init(hard_slot_cap + 1));
    try planner.init(hard_slot_cap);
    try std.testing.expectError(error.InvalidState, planner.init(1));
    try std.testing.expectError(error.MissingHead, planner.next());
    try std.testing.expectError(error.InvalidOrder, planner.push(testScan(.control, 0, 2, 0, false)));
    try std.testing.expectError(error.InvalidOrder, planner.push(testScan(.control, 2, 2, 0, false)));
    try std.testing.expectError(error.InvalidOrder, planner.push(testScan(.control, 3, 2, 0, false)));
    try std.testing.expectError(error.InvalidSlot, planner.push(testScan(.control, 1, 2, hard_slot_cap, false)));
    var malformed = testScan(.control, 1, 2, 0, false);
    malformed.eligible = null;
    try std.testing.expectError(error.InvalidOperation, planner.push(malformed));
    malformed = testScan(.control, 1, 2, 0, false);
    malformed.generation = 1;
    try std.testing.expectError(error.InvalidGeneration, planner.push(malformed));
    malformed = testStore(.queued, 1, 2, 0, 1);
    malformed.role = .worker;
    try std.testing.expectError(error.InvalidOperation, planner.push(malformed));
    malformed = testStore(.running, 1, 2, 0, 1);
    malformed.role = .control;
    try std.testing.expectError(error.InvalidOperation, planner.push(malformed));
    malformed = testStore(.queued, 1, 2, 0, 1);
    malformed.eligible = true;
    try std.testing.expectError(error.InvalidOperation, planner.push(malformed));
    try std.testing.expectError(error.InvalidGeneration, planner.push(testStore(.queued, 1, 2, 0, 0)));
    try std.testing.expectError(error.InvalidGeneration, planner.push(testStore(.queued, 1, 2, 0, std.math.maxInt(u64))));
    try planner.push(testScan(.control, 1, 4, hard_slot_cap - 1, false));
    try std.testing.expectError(error.InvalidState, planner.push(testScan(.control, 5, 6, 0, false)));
    try std.testing.expectError(error.InvalidState, planner.roleEOF(.control));
    try std.testing.expectError(error.MissingHead, planner.next());
    try planner.roleEOF(.worker);
    try std.testing.expectError(error.InvalidState, planner.roleEOF(.worker));
    try std.testing.expectError(error.InvalidState, planner.push(testScan(.worker, 2, 3, 0, false)));
    _ = try planner.next();
    try std.testing.expectError(error.MissingHead, planner.next());
    try std.testing.expectError(error.InvalidOrder, planner.push(testScan(.control, 3, 5, 0, false)));
    try std.testing.expectError(error.InvalidOrder, planner.push(testScan(.control, 4, 5, 0, false)));
    try std.testing.expectError(error.Incomplete, planner.finish());
    try planner.roleEOF(.control);
    try std.testing.expect((try planner.next()) == null);
    try planner.finish();
    try std.testing.expectError(error.InvalidState, planner.finish());
    try std.testing.expectError(error.InvalidState, planner.next());
}

test "generation reuse, illegal transitions, unfinished prefixes and overflow reject" {
    const control = [_]Operation{
        testStore(.queued, 1, 2, 0, 1), testStore(.free, 7, 8, 0, 1),
        testStore(.queued, 9, 10, 0, 2), testStore(.free, 15, 16, 0, 2),
    };
    const worker = [_]Operation{
        testStore(.running, 3, 4, 0, 1), testStore(.completed, 5, 6, 0, 1),
        testStore(.running, 11, 12, 0, 2), testStore(.completed, 13, 14, 0, 2),
    };
    _ = try runSmall(1, &control, &worker);
    // Worker may complete a newer job first. Global identity freshness does
    // NOT impose numerical job order on running/completed/free selections.
    _ = try runSmall(2, &.{
        testStore(.queued, 1, 2, 0, 1), testStore(.queued, 3, 4, 1, 2),
        testStore(.free, 9, 10, 1, 2), testStore(.free, 15, 16, 0, 1),
    }, &.{
        testStore(.running, 5, 6, 1, 2), testStore(.completed, 7, 8, 1, 2),
        testStore(.running, 11, 12, 0, 1), testStore(.completed, 13, 14, 0, 1),
    });
    var wrong_worker = worker;
    wrong_worker[2].generation = 1;
    try std.testing.expectError(error.ImpossibleSchedule, runSmall(1, &control, &wrong_worker));
    wrong_worker = worker;
    wrong_worker[1].generation = 2;
    try std.testing.expectError(error.ImpossibleSchedule, runSmall(1, &control, &wrong_worker));
    var wrong_control = control;
    wrong_control[1].generation = 2;
    try std.testing.expectError(error.ImpossibleSchedule, runSmall(1, &wrong_control, &worker));
    wrong_control = control;
    wrong_control[2].generation = 1;
    try std.testing.expectError(error.InvalidGeneration, runSmall(1, &wrong_control, &worker));
    // IDs remain globally unique even when the second queued slot differs.
    try std.testing.expectError(error.InvalidGeneration, runSmall(2, &.{
        testStore(.queued, 1, 2, 0, 2), testStore(.queued, 3, 4, 1, 1),
    }, &.{}));
    try std.testing.expectError(error.ImpossibleSchedule, runSmall(1, &.{testStore(.free, 1, 2, 0, 1)}, &.{}));
    try std.testing.expectError(error.ImpossibleSchedule, runSmall(1, &.{}, &.{testStore(.completed, 1, 2, 0, 1)}));
    try std.testing.expectError(error.ImpossibleSchedule, runSmall(1, &.{}, &.{testStore(.running, 1, 2, 0, 1)}));
    try std.testing.expectError(error.ImpossibleSchedule, runSmall(1, &.{
        testStore(.queued, 1, 2, 0, 1), testStore(.queued, 3, 4, 0, 2),
    }, &.{}));
    var prefix: Scheduler = .{};
    try prefix.init(1);
    try prefix.roleEOF(.worker);
    try prefix.push(testStore(.queued, 1, 2, 0, 1));
    _ = try prefix.next();
    try prefix.roleEOF(.control);
    try std.testing.expect((try prefix.next()) == null);
    try std.testing.expectError(error.Incomplete, prefix.finish());
    var overflow: Scheduler = .{};
    try overflow.init(1);
    try overflow.roleEOF(.control);
    try overflow.push(testScan(.worker, std.math.maxInt(u64) - 1, std.math.maxInt(u64), 0, false));
    overflow.next_ordinal = std.math.maxInt(u64);
    try std.testing.expectError(error.CounterOverflow, overflow.next());
    try std.testing.expect(overflow.roles[1].head != null);
    try std.testing.expectEqual(@as(u64, 0), overflow.frontier);
    try std.testing.expectEqual(State.free, overflow.slots[0].state);
}

test "65537 reads use the same fixed two heads and 48 slots" {
    try std.testing.expect(@sizeOf(Scheduler) < 4096);
    var planner: Scheduler = .{};
    try planner.init(hard_slot_cap);
    try planner.roleEOF(.control);
    for (0..65537) |i| {
        const ordinal: u64 = @intCast(i);
        try planner.push(testScan(.worker, ordinal * 2 + 1, ordinal * 2 + 2, @intCast(i % hard_slot_cap), false));
        const selected = (try planner.next()).?;
        try std.testing.expectEqual(ordinal, selected.ordinal);
        try std.testing.expect(planner.roles[1].head == null);
    }
    try planner.roleEOF(.worker);
    try std.testing.expect((try planner.next()) == null);
    try planner.finish();
    try std.testing.expectEqual(@as(u64, 65537), planner.next_ordinal);
}

// INDEPENDENT bounded backtracking oracle. It does not call Scheduler's
// predicate/enabled/resultingSlot, use its deadline choice, or trust its state.
// Numeric state 0/1/2/3 independently models free/queued/running/completed.
// Bit 0: some bracket-embedded prefix witness. Bit 1: a complete free witness.
const OracleSlot = struct { state: u8 = 0, job: u64 = 0 };
const OracleTrace = struct { ops: [2][3]Operation = undefined, lengths: [2]usize = .{ 0, 0 } };
fn oracleApply(op: Operation, slot: *OracleSlot) bool {
    switch (op.kind) {
        .scan => {
            const actual = slot.state == (if (op.role == .control) @as(u8, 3) else 1);
            if (actual != op.eligible.?) return false;
        },
        .queued => {
            if (slot.state != 0) return false;
            slot.* = .{ .state = 1, .job = op.generation };
        },
        .running => {
            if (slot.state != 1 or slot.job != op.generation) return false;
            slot.state = 2;
        },
        .completed => {
            if (slot.state != 2 or slot.job != op.generation) return false;
            slot.state = 3;
        },
        .free => {
            if (slot.state != 3 or slot.job != op.generation) return false;
            slot.state = 0;
        },
    }
    return true;
}
fn oracleSearch(trace: *const OracleTrace, cursor: [2]usize, slots: [2]OracleSlot, frontier: u64) u2 {
    if (cursor[0] == trace.lengths[0] and cursor[1] == trace.lengths[1]) {
        return if (slots[0].state == 0 and slots[1].state == 0) 3 else 1;
    }
    var found: u2 = 0;
    for (0..2) |r| {
        if (cursor[r] == trace.lengths[r]) continue;
        const op = trace.ops[r][cursor[r]];
        const time = @max(frontier, op.before);
        if (time >= op.after) continue;
        var after = slots;
        if (!oracleApply(op, &after[@intCast(op.index)])) continue;
        var next = cursor;
        next[r] += 1;
        found |= oracleSearch(trace, next, after, time);
        if (found == 3) return found;
    }
    return found;
}
fn oracleValidInput(trace: *const OracleTrace, job_slots: usize) bool {
    // Do not infer validity from the planner or its errors. The generator
    // supplies unique endpoints, but role order, shape, ownership, booleans,
    // slot bounds and global job freshness are checked independently here.
    var last_job: u64 = 0;
    for (0..2) |r| {
        var previous_after: u64 = 0;
        for (trace.ops[r][0..trace.lengths[r]]) |op| {
            if (@intFromEnum(op.role) != r or op.before <= previous_after or op.after <= op.before or op.index >= job_slots) return false;
            previous_after = op.after;
            if (op.kind == .scan) {
                if (op.generation != 0 or op.eligible == null) return false;
            } else {
                if (op.eligible != null or op.generation == 0 or op.generation == std.math.maxInt(u64)) return false;
                if ((op.kind == .queued or op.kind == .free) != (r == 0)) return false;
                if (op.kind == .queued) {
                    if (op.generation <= last_job) return false;
                    last_job = op.generation;
                }
            }
        }
    }
    return true;
}
fn greedyMask(trace: *const OracleTrace, job_slots: usize) Error!u2 {
    var planner: Scheduler = .{};
    try planner.init(job_slots);
    var cursor: [2]usize = .{ 0, 0 };
    var emitted: [2]usize = .{ 0, 0 };
    var witness_slots: [2]OracleSlot = .{ .{}, .{} };
    var count: u64 = 0;
    var time: u64 = 0;
    while (true) {
        for (0..2) |r| {
            if (planner.roles[r].head != null or planner.roles[r].eof) continue;
            if (cursor[r] == trace.lengths[r]) {
                try planner.roleEOF(@enumFromInt(r));
            } else {
                try planner.push(trace.ops[r][cursor[r]]);
                cursor[r] += 1;
            }
        }
        const selected = (try planner.next()) orelse break;
        // Independently check exact source order, boolean/FSM/generation and
        // time of the RETURNED witness, not just existence/acceptance parity.
        if (selected.ordinal != count) return error.InvalidOrder;
        const r: usize = @intFromEnum(selected.op.role);
        if (emitted[r] >= trace.lengths[r] or !std.meta.eql(selected.op, trace.ops[r][emitted[r]])) return error.InvalidOrder;
        emitted[r] += 1;
        if (!oracleApply(selected.op, &witness_slots[@intCast(selected.op.index)])) return error.InvalidOperation;
        count += 1;
        time = @max(time, selected.op.before);
        if (time >= selected.op.after) return error.InvalidOrder;
    }
    if (count != trace.lengths[0] + trace.lengths[1]) return error.InvalidOrder;
    const closed = witness_slots[0].state == 0 and witness_slots[1].state == 0;
    planner.finish() catch |err| {
        if (err == error.Incomplete and !closed) return 1;
        return err;
    };
    if (!closed) return error.InvalidState;
    return 3;
}
const oracle_case_limit: u64 = 4_600_000;
const OracleCounts = struct { cases: u64 = 0, feasible_prefix: u64 = 0, complete: u64 = 0 };
fn enumerateBrackets(trace: *OracleTrace, job_slots: usize, endpoints: [2]usize, occurrence: u64, counts: *OracleCounts) anyerror!void {
    if (endpoints[0] == 2 * trace.lengths[0] and endpoints[1] == 2 * trace.lengths[1]) {
        counts.cases += 1;
        try std.testing.expect(counts.cases <= oracle_case_limit);
        const valid_input = oracleValidInput(trace, job_slots);
        const expected: u2 = if (valid_input) oracleSearch(trace, .{ 0, 0 }, .{ .{}, .{} }, 0) else 0;
        const actual = greedyMask(trace, job_slots) catch |err| switch (err) {
            error.ImpossibleSchedule => @as(u2, 0),
            error.InvalidGeneration => if (valid_input) return err else @as(u2, 0),
            else => return err,
        };
        if (expected != actual) {
            std.debug.print("job scheduler oracle mismatch, case {d}, slots {d}, expected {d}, actual {d}\n", .{ counts.cases, job_slots, expected, actual });
            for (0..2) |r| for (trace.ops[r][0..trace.lengths[r]]) |op|
                std.debug.print("  {s} {s} [{d},{d}] slot={d} job={d} eligible={any}\n", .{ @tagName(op.role), @tagName(op.kind), op.before, op.after, op.index, op.generation, op.eligible });
        }
        try std.testing.expectEqual(expected, actual);
        if (expected & 1 != 0) counts.feasible_prefix += 1;
        if (expected & 2 != 0) counts.complete += 1;
        return;
    }
    // All shuffles of the role-local B,A,B,A,... endpoint sequences, not just
    // operation interleavings. This includes crossing/nesting across slots.
    for (0..2) |r| {
        if (endpoints[r] == 2 * trace.lengths[r]) continue;
        const op = &trace.ops[r][endpoints[r] / 2];
        if (endpoints[r] % 2 == 0) op.before = occurrence else op.after = occurrence;
        var next = endpoints;
        next[r] += 1;
        try enumerateBrackets(trace, job_slots, next, occurrence + 1, counts);
    }
}
fn enumerateWords(trace: *OracleTrace, job_slots: usize, position: usize, counts: *OracleCounts) anyerror!void {
    if (position == trace.lengths[0] + trace.lengths[1]) {
        try enumerateBrackets(trace, job_slots, .{ 0, 0 }, 1, counts);
        return;
    }
    const r: usize = if (position < trace.lengths[0]) 0 else 1;
    const offset = if (r == 0) position else position - trace.lengths[0];
    const role: Role = @enumFromInt(r);
    // Complete bounded alphabet: each slot x false/true read or either owner
    // store, including unreachable FSM words. Store ID is slot+1, so 2-slot
    // words also exercise global identity-order rejection. Reuse/new IDs and
    // malformed inputs have dedicated tests above, not this finite alphabet.
    for (0..job_slots) |slot| {
        for (0..4) |symbol| {
            trace.ops[r][offset] = if (symbol < 2)
                testScan(role, 1, 2, @intCast(slot), symbol == 1)
            else
                testStore(if (r == 0) (if (symbol == 2) .queued else .free) else (if (symbol == 2) .running else .completed), 1, 2, @intCast(slot), @intCast(slot + 1));
            try enumerateWords(trace, job_slots, position + 1, counts);
        }
    }
}

test "independent exhaustive bounded oracle agrees for every word and legal endpoint shuffle" {
    var counts: OracleCounts = .{};
    for (1..3) |job_slots| {
        const max_length: usize = if (job_slots == 1) 3 else 2;
        for (0..max_length + 1) |control_length| {
            for (0..max_length + 1) |worker_length| {
                var trace: OracleTrace = .{ .lengths = .{ control_length, worker_length } };
                try enumerateWords(&trace, job_slots, 0, &counts);
            }
        }
        try std.testing.expectEqual(if (job_slots == 1) @as(u64, 4_249_225) else 4_551_834, counts.cases);
    }
    try std.testing.expect(counts.feasible_prefix > counts.complete and counts.complete > 0);
    std.debug.print("ORACLE cases={d} feasible_prefix={d} complete={d}\n", .{ counts.cases, counts.feasible_prefix, counts.complete });
}
