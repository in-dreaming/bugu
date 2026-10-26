//! Fixed-space execution-order gate for joint Service frame/sequence/job plan.
//! Each role privately streams the same pure schedule from copied INPUT
//! cursors. Planning another role's operations is not native execution: only
//! completed(), after the original atomic and its actual-result check, advances
//! the shared execution ordinal. No expected predicate becomes engine data.
const std = @import("std");
const joint_schedule = @import("sme-live-semantic-joint-schedule");

pub const Role = joint_schedule.Role;
pub const Kind = joint_schedule.Kind;
pub const Error = anyerror;

/// Cursor is a movable value with next() !?joint_schedule.Operation. Copying it
/// must copy its mutable iteration state, not share that state through a
/// pointer. The three inputs yield Control, Worker and Render operations respectively.
/// Any backing INPUT bytes are immutable and outlive the genuine actor joins.
/// The caller separately validates global occurrence uniqueness and matches
/// actual global BEFORE/AFTER markers. Nothing here grants cleanup custody.
pub fn Gate(comptime Cursor: type) type {
    return struct {
        const Self = @This();
        const RolePlan = struct {
            planner: joint_schedule.Scheduler = .{},
            cursors: [3]Cursor = undefined,
            pending: ?joint_schedule.Selection = null,
            active: bool = false,
            exhausted: bool = false,

            /// Single-owner planning only. Every selection, including those
            /// belonging to the other role, changes only this private model.
            fn nextSelection(self: *RolePlan, role: Role, aborted: *const std.atomic.Value(bool)) Error!?joint_schedule.Selection {
                if (self.pending) |selected| return selected;
                if (self.exhausted) return null;
                while (true) {
                    if (aborted.load(.acquire)) return error.Aborted;
                    for (0..3) |r| {
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
        roles: [3]RolePlan = .{ .{}, .{}, .{} },

        /// Initialize final pinned storage before either actor starts. All three
        /// planners begin with identical copies of ALL cursors. Space is
        /// independent of total_operations; there is no operation array/cap.
        pub fn init(self: *Self, job_slots: usize, cursors: [3]Cursor, total_operations: u64) Error!void {
            if (self.address != null) return error.InvalidState;
            var planner: joint_schedule.Scheduler = .{};
            try planner.init(job_slots);
            self.* = .{
                .address = self,
                .total_operations = total_operations,
                .roles = .{
                    .{ .planner = planner, .cursors = cursors },
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
        pub fn completed(self: *Self, role: Role, kind: Kind, index: u64, generation: u64, actual_eligible: ?bool, actual_value: ?u64) Error!u64 {
            try self.running();
            const state = &self.roles[@intFromEnum(role)];
            if (!state.active) return error.InvalidState;
            const selected = state.pending orelse return error.InvalidState;
            const op = selected.op;
            if (op.role != role or op.kind != kind or op.index != index or op.generation != generation or
                op.eligible != actual_eligible or op.value != actual_value) return error.ReplayMismatch;
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

        /// Post-genuine-join only. Exhaust all private planner copies, reject
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
