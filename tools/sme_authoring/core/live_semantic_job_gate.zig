//! Fixed-space execution-order gate for ONE initially-free Service job pool.
//! Each role privately streams the same pure schedule from copied INPUT
//! cursors. Planning another role's operations is not native execution: only
//! completed(), after the original atomic and its actual-result check, advances
//! the shared execution ordinal. No expected predicate becomes engine data.
const std = @import("std");
const job_schedule = @import("live_semantic_job_schedule.zig");

pub const Role = job_schedule.Role;
pub const Kind = job_schedule.Kind;
pub const Error = anyerror;

/// Cursor is a movable value with next() !?job_schedule.Operation. Copying it
/// must copy its mutable iteration state, not share that state through a
/// pointer. The two inputs yield Control and Worker operations respectively.
/// Any backing INPUT bytes are immutable and outlive the genuine actor joins.
/// The caller separately validates global occurrence uniqueness and matches
/// actual global BEFORE/AFTER markers. Nothing here grants cleanup custody.
pub fn Gate(comptime Cursor: type) type {
    return struct {
        const Self = @This();
        const RolePlan = struct {
            planner: job_schedule.Scheduler = .{},
            cursors: [2]Cursor = undefined,
            pending: ?job_schedule.Selection = null,
            active: bool = false,
            exhausted: bool = false,

            /// Single-owner planning only. Every selection, including those
            /// belonging to the other role, changes only this private model.
            fn nextSelection(self: *RolePlan, role: Role, aborted: *const std.atomic.Value(bool)) Error!?job_schedule.Selection {
                if (self.pending) |selected| return selected;
                if (self.exhausted) return null;
                while (true) {
                    if (aborted.load(.acquire)) return error.Aborted;
                    for (0..2) |r| {
                        if (self.planner.roles[r].head == null and !self.planner.roles[r].eof) {
                            if (try self.cursors[r].next()) |op| {
                                if (op.role != @as(Role, @enumFromInt(r))) return error.InvalidOperation;
                                try self.planner.push(op);
                            } else try self.planner.roleEOF(@enumFromInt(r));
                        }
                    }
                    const selected = (try self.planner.next()) orelse {
                        try self.planner.finish();
                        self.exhausted = true;
                        return null;
                    };
                    if (selected.op.role == role) {
                        self.pending = selected;
                        return selected;
                    }
                }
            }
        };

        address: ?*Self = null,
        total_operations: u64 = 0,
        finished: bool = false,
        aborted: std.atomic.Value(bool) = .init(false),
        turn: std.atomic.Value(u64) = .init(0),
        roles: [2]RolePlan = .{ .{}, .{} },

        /// Initialize final pinned storage before either actor starts. Both
        /// planners begin with identical copies of BOTH cursors. Space is
        /// independent of total_operations; there is no operation array/cap.
        pub fn init(self: *Self, job_slots: usize, cursors: [2]Cursor, total_operations: u64) Error!void {
            if (self.address != null) return error.InvalidState;
            var planner: job_schedule.Scheduler = .{};
            try planner.init(job_slots);
            self.* = .{
                .address = self,
                .total_operations = total_operations,
                .roles = .{
                    .{ .planner = planner, .cursors = cursors },
                    .{ .planner = planner, .cursors = cursors },
                },
            };
        }

        fn running(self: *const Self) Error!void {
            if (self.address != self or self.finished) return error.InvalidState;
            if (self.aborted.load(.acquire)) return error.Aborted;
        }

        /// Call only AFTER the global BEFORE marker was validated and released.
        /// A false result keeps the same pending selection and does not grant
        /// permission to execute the atomic. The caller owns waiting/timeout.
        /// A true result must be followed by exactly one original native atomic
        /// and completed(), not another ready(). One owner per role is required.
        pub fn ready(self: *Self, role: Role, before: u64) Error!bool {
            try self.running();
            const state = &self.roles[@intFromEnum(role)];
            if (state.active) return error.InvalidState;
            const selected = (try state.nextSelection(role, &self.aborted)) orelse return error.InvalidOrder;
            if (selected.op.before != before) return error.InvalidOrder;
            if (selected.ordinal >= self.total_operations) return error.Incomplete;
            const turn = self.turn.load(.acquire);
            if (turn > selected.ordinal) return error.ReplayMismatch;
            if (turn < selected.ordinal) return false;
            if (self.aborted.load(.acquire)) return error.Aborted;
            state.active = true;
            return true;
        }

        /// Call AFTER the original native atomic, BEFORE entering/waiting for
        /// the global AFTER marker. Scans supply the actual observed predicate;
        /// stores supply null. Returned AFTER is solely a marker coordinate to
        /// compare later, never an engine load result or permission to skip it.
        /// A mismatch preserves pending/active state and never advances turn.
        /// The caller must abort on any error, including a cursor/planning error.
        pub fn completed(self: *Self, role: Role, kind: Kind, index: u64, generation: u64, actual_eligible: ?bool) Error!u64 {
            try self.running();
            const state = &self.roles[@intFromEnum(role)];
            if (!state.active) return error.InvalidState;
            const selected = state.pending orelse return error.InvalidState;
            const op = selected.op;
            if (op.role != role or op.kind != kind or op.index != index or op.generation != generation or
                op.eligible != actual_eligible) return error.ReplayMismatch;
            if (self.turn.load(.acquire) != selected.ordinal) return error.InvalidOrder;
            const next_turn = std.math.add(u64, selected.ordinal, 1) catch return error.CounterOverflow;
            if (next_turn > self.total_operations) return error.Incomplete;
            if (self.aborted.load(.acquire)) return error.Aborted;
            state.pending = null;
            state.active = false;
            // Only genuine execution completion publishes progress. Do not
            // plan another operation here or wait for its global AFTER stamp.
            self.turn.store(next_turn, .release);
            return op.after;
        }

        pub fn abort(self: *Self) void {
            self.aborted.store(true, .release);
        }

        /// Post-genuine-join only. Exhaust both private planner copies, reject
        /// any unexecuted role operation, and certify their finally-free pool.
        /// No actor may call ready()/completed() concurrently with finish().
        pub fn finish(self: *Self) Error!void {
            try self.running();
            for (self.roles) |state| if (state.active or state.pending != null) return error.Incomplete;
            if (self.turn.load(.acquire) != self.total_operations) return error.Incomplete;
            for (&self.roles, 0..) |*state, r| {
                if (try state.nextSelection(@enumFromInt(r), &self.aborted) != null) return error.Incomplete;
                if (!state.exhausted or state.planner.next_ordinal != self.total_operations) return error.Incomplete;
            }
            self.finished = true;
        }
    };
}

const MockCursor = struct {
    operations: []const job_schedule.Operation = &.{},
    index: usize = 0,
    repetitions: u64 = 1,
    repetition: u64 = 0,
    marker_stride: u64 = 0,
    fail_at: ?usize = null,

    fn next(self: *MockCursor) !?job_schedule.Operation {
        if (self.fail_at == self.index) return error.MockCursorFailure;
        if (self.operations.len == 0 or self.repetition == self.repetitions) return null;
        if (self.index == self.operations.len) {
            self.repetition = std.math.add(u64, self.repetition, 1) catch return error.CounterOverflow;
            if (self.repetition == self.repetitions) return null;
            self.index = 0;
        }
        var op = self.operations[self.index];
        const offset = std.math.mul(u64, self.repetition, self.marker_stride) catch return error.CounterOverflow;
        op.before = std.math.add(u64, op.before, offset) catch return error.CounterOverflow;
        op.after = std.math.add(u64, op.after, offset) catch return error.CounterOverflow;
        self.index += 1;
        return op;
    }
};

fn scan(role: Role, before: u64, after: u64, eligible: bool) job_schedule.Operation {
    return .{ .role = role, .kind = .scan, .before = before, .after = after, .index = 0, .generation = 0, .eligible = eligible };
}
fn store(kind: Kind, before: u64, after: u64) job_schedule.Operation {
    return .{
        .role = if (kind == .queued or kind == .free) .control else .worker,
        .kind = kind,
        .before = before,
        .after = after,
        .index = 0,
        .generation = 1,
    };
}
fn inputs(control: []const job_schedule.Operation, worker: []const job_schedule.Operation) [2]MockCursor {
    return .{ .{ .operations = control }, .{ .operations = worker } };
}
fn executeTest(gate: *Gate(MockCursor), op: job_schedule.Operation, observed: ?bool) !void {
    try std.testing.expect(try gate.ready(op.role, op.before));
    try std.testing.expectEqual(op.after, try gate.completed(op.role, op.kind, op.index, op.generation, observed));
}

test "job execution gate requires initialized pinned storage and supported slots" {
    var gate: Gate(MockCursor) = .{};
    const empty = inputs(&.{}, &.{});
    try std.testing.expectError(error.InvalidState, gate.ready(.control, 1));
    try std.testing.expectError(error.InvalidState, gate.completed(.control, .scan, 0, 0, false));
    try std.testing.expectError(error.InvalidState, gate.finish());
    try std.testing.expectError(error.UnsupportedSlots, gate.init(0, empty, 0));
    try std.testing.expectError(error.UnsupportedSlots, gate.init(job_schedule.hard_slot_cap + 1, empty, 0));
    try gate.init(job_schedule.hard_slot_cap, empty, 0);
    try std.testing.expectError(error.InvalidState, gate.init(1, empty, 0));
    var moved = gate;
    try std.testing.expectError(error.InvalidState, moved.ready(.control, 1));
    try std.testing.expectError(error.InvalidState, moved.completed(.control, .scan, 0, 0, false));
    try std.testing.expectError(error.InvalidState, moved.finish());
    try std.testing.expectError(error.InvalidOrder, gate.ready(.worker, 1));
    try gate.finish();
    try std.testing.expectError(error.InvalidState, gate.finish());
}

test "abort is safe and idempotent even before initialization" {
    var gate: Gate(MockCursor) = .{};
    gate.abort();
    gate.abort();
    try std.testing.expect(gate.aborted.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), gate.turn.load(.acquire));
    try std.testing.expectError(error.InvalidState, gate.ready(.control, 1));
    try std.testing.expectError(error.InvalidState, gate.finish());
    try gate.init(1, inputs(&.{}, &.{}), 0);
    gate.abort();
    gate.abort();
    try std.testing.expectError(error.Aborted, gate.ready(.control, 1));
    try std.testing.expectError(error.Aborted, gate.completed(.control, .scan, 0, 0, false));
    try std.testing.expectError(error.Aborted, gate.finish());
    try std.testing.expectEqual(@as(u64, 0), gate.turn.load(.acquire));
}

test "crossed true scans wait for real queued and completed publications" {
    const control = [_]job_schedule.Operation{
        store(.queued, 2, 4), scan(.control, 7, 9, true), store(.free, 11, 12),
    };
    const worker = [_]job_schedule.Operation{
        scan(.worker, 1, 3, true), store(.running, 5, 6), store(.completed, 8, 10),
    };
    var gate: Gate(MockCursor) = .{};
    try gate.init(1, inputs(&control, &worker), 6);
    try std.testing.expect(!try gate.ready(.worker, 1));
    try std.testing.expectEqual(@as(u64, 0), gate.turn.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), gate.roles[1].pending.?.ordinal);
    try std.testing.expect(try gate.ready(.control, 2));
    try std.testing.expectError(error.ReplayMismatch, gate.completed(.control, .queued, 0, 1, false));
    try std.testing.expectEqual(@as(u64, 0), gate.turn.load(.acquire));
    try std.testing.expectEqual(@as(u64, 4), try gate.completed(.control, .queued, 0, 1, null));
    try std.testing.expectEqual(@as(u64, 1), gate.turn.load(.acquire));
    try executeTest(&gate, worker[0], true);
    try executeTest(&gate, worker[1], null);
    try std.testing.expect(!try gate.ready(.control, 7));
    try executeTest(&gate, worker[2], null);
    try executeTest(&gate, control[1], true);
    try executeTest(&gate, control[2], null);
    try gate.finish();
    try std.testing.expectEqual(@as(u64, 6), gate.turn.load(.acquire));
    for (gate.roles) |state| try std.testing.expect(state.exhausted and state.planner.finished);
}

test "overlapping false scan executes before queued publication despite later AFTER" {
    const control = [_]job_schedule.Operation{ store(.queued, 2, 3), store(.free, 9, 10) };
    const worker = [_]job_schedule.Operation{ scan(.worker, 1, 4, false), store(.running, 5, 6), store(.completed, 7, 8) };
    var gate: Gate(MockCursor) = .{};
    try gate.init(1, inputs(&control, &worker), 5);
    try std.testing.expect(!try gate.ready(.control, 2));
    try std.testing.expectEqual(@as(u64, 0), gate.turn.load(.acquire));
    try executeTest(&gate, worker[0], false);
    try std.testing.expectEqual(@as(u64, 1), gate.turn.load(.acquire));
    try executeTest(&gate, control[0], null);
    try executeTest(&gate, worker[1], null);
    try executeTest(&gate, worker[2], null);
    try executeTest(&gate, control[1], null);
    try gate.finish();
}

test "wrong native identity and observed predicate preserve active selection and turn" {
    const control = [_]job_schedule.Operation{scan(.control, 1, 2, false)};
    var gate: Gate(MockCursor) = .{};
    try gate.init(1, inputs(&control, &.{}), 1);
    try std.testing.expect(try gate.ready(.control, 1));
    try std.testing.expectError(error.ReplayMismatch, gate.completed(.control, .queued, 0, 0, null));
    try std.testing.expectError(error.ReplayMismatch, gate.completed(.control, .scan, 1, 0, false));
    try std.testing.expectError(error.ReplayMismatch, gate.completed(.control, .scan, 0, 1, false));
    try std.testing.expectError(error.ReplayMismatch, gate.completed(.control, .scan, 0, 0, null));
    try std.testing.expectError(error.ReplayMismatch, gate.completed(.control, .scan, 0, 0, true));
    try std.testing.expectEqual(@as(u64, 0), gate.turn.load(.acquire));
    try std.testing.expect(gate.roles[0].active and gate.roles[0].pending != null);
    try std.testing.expectError(error.Incomplete, gate.finish());
    gate.abort();
    try std.testing.expectError(error.Aborted, gate.completed(.control, .scan, 0, 0, false));
    try std.testing.expectError(error.Aborted, gate.ready(.worker, 3));
    try std.testing.expectError(error.Aborted, gate.finish());
    try std.testing.expectEqual(@as(u64, 0), gate.turn.load(.acquire));
    try std.testing.expect(gate.roles[0].active and gate.roles[0].pending != null);
}

test "unready out of turn and wrong BEFORE calls cannot grant or advance execution" {
    const control = [_]job_schedule.Operation{store(.queued, 1, 4)};
    const worker = [_]job_schedule.Operation{scan(.worker, 2, 3, true)};
    var gate: Gate(MockCursor) = .{};
    try gate.init(1, inputs(&control, &worker), 2);
    try std.testing.expectError(error.InvalidState, gate.completed(.control, .queued, 0, 1, null));
    try std.testing.expect(!try gate.ready(.worker, 2));
    try std.testing.expect(!try gate.ready(.worker, 2));
    try std.testing.expectError(error.InvalidState, gate.completed(.worker, .scan, 0, 0, true));
    try std.testing.expectError(error.InvalidOrder, gate.ready(.control, 99));
    try std.testing.expectEqual(@as(u64, 0), gate.turn.load(.acquire));
    try std.testing.expect(gate.roles[0].pending != null and !gate.roles[0].active);
    try std.testing.expect(gate.roles[1].pending != null and !gate.roles[1].active);
    try std.testing.expectError(error.Incomplete, gate.finish());
    try std.testing.expect(try gate.ready(.control, 1));
    try std.testing.expectError(error.InvalidState, gate.ready(.control, 1));
    gate.abort();
    try std.testing.expectError(error.Aborted, gate.ready(.worker, 2));
    try std.testing.expectError(error.Aborted, gate.completed(.control, .queued, 0, 1, null));
    try std.testing.expectEqual(@as(u64, 0), gate.turn.load(.acquire));
}

test "cursor role source slot and cursor failures are rejected without execution progress" {
    const wrong_role = [_]job_schedule.Operation{scan(.worker, 1, 2, false)};
    var role_gate: Gate(MockCursor) = .{};
    try role_gate.init(1, inputs(&wrong_role, &.{}), 1);
    try std.testing.expectError(error.InvalidOperation, role_gate.ready(.control, 1));
    try std.testing.expectEqual(@as(u64, 0), role_gate.turn.load(.acquire));

    var bad_slot = [_]job_schedule.Operation{scan(.control, 1, 2, false)};
    bad_slot[0].index = 1;
    var slot_gate: Gate(MockCursor) = .{};
    try slot_gate.init(1, inputs(&bad_slot, &.{}), 1);
    try std.testing.expectError(error.InvalidSlot, slot_gate.ready(.control, 1));
    try std.testing.expectEqual(@as(u64, 0), slot_gate.turn.load(.acquire));

    var failed_gate: Gate(MockCursor) = .{};
    try failed_gate.init(1, .{ .{ .fail_at = 0 }, .{} }, 0);
    try std.testing.expectError(error.MockCursorFailure, failed_gate.ready(.control, 1));
    try std.testing.expectEqual(@as(u64, 0), failed_gate.turn.load(.acquire));
}

test "finish rejects wrong counts unconsumed operations and a pool left occupied" {
    const control = [_]job_schedule.Operation{scan(.control, 1, 2, false)};
    var unconsumed: Gate(MockCursor) = .{};
    try unconsumed.init(1, inputs(&control, &.{}), 0);
    try std.testing.expectError(error.Incomplete, unconsumed.finish());
    try std.testing.expect(unconsumed.roles[0].pending != null);
    try std.testing.expectError(error.Incomplete, unconsumed.ready(.control, 1));
    try std.testing.expectEqual(@as(u64, 0), unconsumed.turn.load(.acquire));

    var missing: Gate(MockCursor) = .{};
    try missing.init(1, inputs(&.{}, &.{}), 1);
    try std.testing.expectError(error.InvalidOrder, missing.ready(.control, 1));
    try std.testing.expectError(error.Incomplete, missing.finish());

    var count: Gate(MockCursor) = .{};
    try count.init(1, inputs(&control, &.{}), 2);
    try executeTest(&count, control[0], false);
    try std.testing.expectError(error.Incomplete, count.finish());

    const queued = [_]job_schedule.Operation{store(.queued, 1, 2)};
    var occupied: Gate(MockCursor) = .{};
    try occupied.init(1, inputs(&queued, &.{}), 1);
    try executeTest(&occupied, queued[0], null);
    try std.testing.expectError(error.Incomplete, occupied.finish());
    try std.testing.expect(!occupied.finished);
}

test "completion does not eagerly scan future input and finish exhausts both private copies" {
    const control = [_]job_schedule.Operation{scan(.control, 1, 2, false)};
    var gate: Gate(MockCursor) = .{};
    var source = inputs(&control, &.{});
    source[0].fail_at = 1;
    try gate.init(1, source, 1);
    try executeTest(&gate, control[0], false);
    try std.testing.expectEqual(@as(u64, 1), gate.turn.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), gate.roles[0].cursors[0].index);
    try std.testing.expectEqual(@as(usize, 0), gate.roles[1].cursors[0].index);
    try std.testing.expectError(error.MockCursorFailure, gate.finish());
    try std.testing.expectEqual(@as(u64, 1), gate.turn.load(.acquire));
}

test "counter overflow never wraps planning or genuine completion progress" {
    const control = [_]job_schedule.Operation{scan(.control, 1, 2, false)};
    const limit: u64 = std.math.maxInt(u64);
    var planning: Gate(MockCursor) = .{};
    try planning.init(1, inputs(&control, &.{}), limit);
    // Reach the finite-counter boundary without allocating or iterating an
    // impossible number of operations. These are internal fault injections.
    planning.roles[0].planner.next_ordinal = limit;
    try std.testing.expectError(error.CounterOverflow, planning.ready(.control, 1));
    try std.testing.expectEqual(@as(u64, 0), planning.turn.load(.acquire));

    var execution: Gate(MockCursor) = .{};
    try execution.init(1, inputs(&control, &.{}), limit);
    execution.roles[0].pending = .{ .op = control[0], .ordinal = limit };
    execution.roles[0].active = true;
    execution.turn.store(limit, .release);
    try std.testing.expectError(error.CounterOverflow, execution.completed(.control, .scan, 0, 0, false));
    try std.testing.expectEqual(limit, execution.turn.load(.acquire));
    try std.testing.expect(execution.roles[0].active and execution.roles[0].pending != null);
}

test "fixed space streams more than 65536 operations from immutable reused input" {
    const template = [_]job_schedule.Operation{scan(.control, 1, 2, false)};
    const count: u64 = 65537;
    var small: Gate(MockCursor) = .{};
    try small.init(1, inputs(&template, &.{}), 1);
    var gate: Gate(MockCursor) = .{};
    try gate.init(1, .{ .{ .operations = &template, .repetitions = count, .marker_stride = 2 }, .{} }, count);
    try std.testing.expectEqual(@sizeOf(@TypeOf(small)), @sizeOf(@TypeOf(gate)));
    try std.testing.expect(@sizeOf(@TypeOf(gate)) < 16 * 1024);
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        try std.testing.expect(try gate.ready(.control, 2 * i + 1));
        try std.testing.expectEqual(2 * i + 2, try gate.completed(.control, .scan, 0, 0, false));
    }
    try gate.finish();
    try std.testing.expectEqual(count, gate.turn.load(.acquire));
    for (gate.roles) |state| try std.testing.expect(state.exhausted and state.planner.next_ordinal == count);
}
