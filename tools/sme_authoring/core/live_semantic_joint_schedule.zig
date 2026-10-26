//! Conservative finite joint planner; not a complete existential solver.
//! One Service, three serial roles, initially/finally free jobs, zero initial
//! frame/sequence. Only copied INPUT observations constrain this pure model;
//! the executor must perform and compare actual operations, never install reads.
//! Caller validates global marker uniqueness and original site/role coordinates.
//! Scalar coordinates here are normalized to index/generation zero. Consumed,
//! guard, lifecycle and other domains require separate strict overlap rejection.
const std = @import("std");
pub const hard_slot_cap = 48;
pub const Role = enum(u8) { control, worker, render };
pub const Kind = enum { scan, queued, running, completed, free, frame_read, frame_store, sequence_read, sequence_odd, sequence_even };
pub const State = enum { free, queued, running, completed };
pub const Error = error{ InvalidState, InvalidOrder, InvalidOperation, InvalidGeneration, InvalidSlot, UnsupportedSlots, MissingHead, ImpossibleSchedule, Incomplete, CounterOverflow };
pub const Operation = struct {
    role: Role,
    kind: Kind,
    before: u64,
    after: u64,
    index: u64 = 0,
    generation: u64 = 0,
    eligible: ?bool = null,
    /// Actual read value or actual publication AFTER value, never a return override.
    value: ?u64 = null,
};
pub const Selection = struct { op: Operation, ordinal: u64 };
const Slot = struct { state: State = .free, generation: u64 = 0 };
const RoleState = struct { head: ?Operation = null, eof: bool = false, last_after: u64 = 0 };
pub const Scheduler = struct {
    initialized: bool = false,
    finished: bool = false,
    job_slots: usize = 0,
    slots: [hard_slot_cap]Slot = @splat(.{}),
    roles: [3]RoleState = @splat(.{}),
    frame: u64 = 0,
    sequence: u64 = 0,
    frame_published: bool = false,
    last_queued_generation: u64 = 0,
    next_ordinal: u64 = 0,
    frontier: u64 = 0,
    pub fn init(self: *Scheduler, count: usize) Error!void {
        if (self.initialized) return error.InvalidState;
        if (count == 0 or count > hard_slot_cap) return error.UnsupportedSlots;
        self.* = .{ .initialized = true, .job_slots = count };
    }
    fn active(self: *const Scheduler) Error!void {
        if (!self.initialized or self.finished) return error.InvalidState;
    }
    fn isJob(kind: Kind) bool {
        return switch (kind) {
            .scan, .queued, .running, .completed, .free => true,
            else => false,
        };
    }
    fn isRead(kind: Kind) bool {
        return kind == .scan or kind == .frame_read or kind == .sequence_read;
    }
    pub fn push(self: *Scheduler, op: Operation) Error!void {
        try self.active();
        const role = &self.roles[@intFromEnum(op.role)];
        if (role.eof or role.head != null) return error.InvalidState;
        if (op.before == 0 or op.after <= op.before or op.before <= role.last_after) return error.InvalidOrder;
        if (isJob(op.kind)) {
            if (op.index >= self.job_slots) return error.InvalidSlot;
            if (op.value != null) return error.InvalidOperation;
            if (op.kind == .scan) {
                if (op.role == .render or op.eligible == null) return error.InvalidOperation;
                if (op.generation != 0) return error.InvalidGeneration;
            } else {
                if (op.eligible != null or op.role != (if (op.kind == .queued or op.kind == .free) Role.control else Role.worker)) return error.InvalidOperation;
                if (op.generation == 0 or op.generation == std.math.maxInt(u64) or (op.kind == .queued and op.generation <= self.last_queued_generation)) return error.InvalidGeneration;
            }
        } else {
            if (op.value == null or op.eligible != null or op.index != 0 or op.generation != 0) return error.InvalidOperation;
            if (op.role != (if (isRead(op.kind)) Role.control else Role.render)) return error.InvalidOperation;
        }
        role.head = op;
        role.last_after = op.after;
        if (op.kind == .queued) self.last_queued_generation = op.generation;
    }
    pub fn roleEOF(self: *Scheduler, r: Role) Error!void {
        try self.active();
        const role = &self.roles[@intFromEnum(r)];
        if (role.eof or role.head != null) return error.InvalidState;
        role.eof = true;
    }
    fn enabled(self: *const Scheduler, op: Operation) bool {
        if (isJob(op.kind)) {
            const s = self.slots[@intCast(op.index)];
            return switch (op.kind) {
                .scan => (s.state == (if (op.role == .worker) State.queued else State.completed)) == op.eligible.?,
                .queued => s.state == .free,
                .running => s.state == .queued and s.generation == op.generation,
                .completed => s.state == .running and s.generation == op.generation,
                .free => s.state == .completed and s.generation == op.generation,
                else => unreachable,
            };
        }
        return switch (op.kind) {
            .frame_read => self.frame == op.value.?,
            .sequence_read => self.sequence == op.value.?,
            .frame_store => self.sequence % 2 == 1 and !self.frame_published and op.value.? >= self.frame,
            .sequence_odd => self.sequence % 2 == 0 and self.sequence < std.math.maxInt(u64) and op.value.? == self.sequence + 1,
            .sequence_even => self.sequence % 2 == 1 and self.frame_published and self.sequence < std.math.maxInt(u64) and op.value.? == self.sequence + 1,
            else => unreachable,
        };
    }
    fn apply(self: *Scheduler, op: Operation) void {
        switch (op.kind) {
            .scan, .frame_read, .sequence_read => {},
            .queued => self.slots[@intCast(op.index)] = .{ .state = .queued, .generation = op.generation },
            .running => self.slots[@intCast(op.index)].state = .running,
            .completed => self.slots[@intCast(op.index)].state = .completed,
            .free => self.slots[@intCast(op.index)].state = .free,
            .frame_store => {
                self.frame = op.value.?;
                self.frame_published = true;
            },
            .sequence_odd, .sequence_even => {
                self.sequence = op.value.?;
                self.frame_published = false;
            },
        }
    }
    /// Refill every empty non-EOF role before each call. A rejected prefix is
    /// not a plan. Freeze only after finish(); never reselect after native failure.
    /// frontier is a dense marker-gap lower bound, NOT an integer atomic
    /// timestamp. Multiple operations can occur in one gap; do not increment
    /// frontier or advance it to AFTER. max(previous BEFOREs) < AFTER is enough.
    pub fn next(self: *Scheduler) Error!?Selection {
        try self.active();
        var deadline: ?u64 = null;
        for (self.roles) |role| {
            if (!role.eof and role.head == null) return error.MissingHead;
            if (role.head) |op| deadline = if (deadline) |d| @min(d, op.after) else op.after;
        }
        const limit = deadline orelse return null;
        var chosen: ?usize = null;
        for (self.roles, 0..) |role, r| {
            const op = role.head orelse continue;
            if (@max(self.frontier, op.before) >= limit or !self.enabled(op)) continue;
            // Protect every currently enabled read, including true scans and
            // same-valued publications. Conservative protection may reject a
            // feasible suffix; it can never justify an incorrect observation.
            var after = self.*;
            after.apply(op);
            var destructive = false;
            for (self.roles, 0..) |other, j| {
                if (j == r) continue;
                if (other.head) |read| if (isRead(read.kind) and @max(self.frontier, read.before) < op.after and self.enabled(read) and !after.enabled(read)) {
                    destructive = true;
                };
            }
            if (destructive) continue;
            if (chosen == null or op.after < self.roles[chosen.?].head.?.after) chosen = r;
        }
        const r = chosen orelse return error.ImpossibleSchedule;
        const op = self.roles[r].head.?;
        const advance = std.math.add(u64, self.next_ordinal, 1) catch return error.CounterOverflow;
        const result: Selection = .{ .op = op, .ordinal = self.next_ordinal };
        self.apply(op);
        self.roles[r].head = null;
        self.frontier = @max(self.frontier, op.before);
        self.next_ordinal = advance;
        return result;
    }
    pub fn finish(self: *Scheduler) Error!void {
        try self.active();
        for (self.roles) |role| if (!role.eof or role.head != null) return error.Incomplete;
        for (self.slots[0..self.job_slots]) |slot| if (slot.state != .free) return error.Incomplete;
        if (self.sequence % 2 != 0 or self.frame_published) return error.Incomplete;
        self.finished = true;
    }
};
