//! Bounded offline planner for ONE Service worker_busy exclusion lifetime.
//! Only explicit INPUT claim results and source brackets enter the planner.
//! Native replay still executes every original CAS/store and checks its result.
const std = @import("std");
pub const hard_operation_cap: usize = 65536;
pub const Role = enum(u8) { control, worker };
pub const Kind = enum { claim, release };
pub const Error = error{ InvalidState, InvalidOrder, InvalidOperation, OperationBudgetExceeded, ImpossibleExclusion, Incomplete, Aborted, ReplayMismatch };
pub const Operation = struct {
    role: Role,
    kind: Kind,
    before: u64,
    after: u64,
    site: u16,
    index: u64,
    generation: u64,
    success: ?bool = null,
};
const none = std.math.maxInt(u32);
const Entry = struct { op: Operation, next: u32 = none, ordinal: u32 = none };
const State = struct { head: u32 = none, tail: u32 = none, cursor: u32 = none, active: bool = false };
pub const Scheduler = struct {
    address: ?*Scheduler = null,
    limit: usize = 0,
    used: usize = 0,
    sealed: bool = false,
    aborted: std.atomic.Value(bool) = .init(false),
    turn: std.atomic.Value(u32) = .init(0),
    entries: [hard_operation_cap]Entry = undefined,
    roles: [2]State = .{ .{}, .{} },
    pub fn init(self: *Scheduler, limit: usize) Error!void {
        if (self.address != null) return error.InvalidState;
        if (limit > hard_operation_cap) return error.OperationBudgetExceeded;
        self.limit = limit;
        self.address = self;
        self.aborted.store(false, .monotonic);
    }
    fn building(self: *const Scheduler) Error!void {
        if (self.address != self or self.sealed or self.aborted.load(.acquire)) return error.InvalidState;
    }
    fn running(self: *const Scheduler) Error!void {
        if (self.address != self or !self.sealed) return error.InvalidState;
        if (self.aborted.load(.acquire)) return error.Aborted;
    }
    fn valid(op: Operation) bool {
        if ((op.kind == .claim) != (op.success != null)) return false;
        return switch (op.site) {
            0x6c => op.role == .control and op.kind == .claim,
            0x6e => op.role == .control and op.kind == .release,
            0x4e, 0x6f => op.role == .worker and op.kind == .claim,
            0x52, 0x70 => op.role == .worker and op.kind == .release,
            else => false,
        };
    }
    /// Add completed pairs in global AFTER-occurrence order. Complete source
    /// coordinates/results are independent execution input, never references.
    pub fn add(self: *Scheduler, op: Operation) Error!void {
        try self.building();
        if (self.used == self.limit) return error.OperationBudgetExceeded;
        if (!valid(op)) return error.InvalidOperation;
        if (op.before == 0 or op.after <= op.before) return error.InvalidOrder;
        if (self.used != 0 and op.after <= self.entries[self.used - 1].op.after) return error.InvalidOrder;
        const state = &self.roles[@intFromEnum(op.role)];
        if (state.tail != none and op.before <= self.entries[state.tail].op.after) return error.InvalidOrder;
        const index: u32 = @intCast(self.used);
        self.entries[index] = .{ .op = op };
        if (state.tail == none) state.head = index else self.entries[state.tail].next = index;
        state.tail = index;
        self.used += 1;
    }
    fn matches(claim: Operation, release: Operation) bool {
        if (claim.role != release.role) return false;
        return switch (claim.site) {
            0x6c => release.site == 0x6e and claim.index == release.index and claim.generation == release.generation,
            0x6f => release.site == 0x70 and claim.index == release.index and claim.generation == release.generation,
            // Worker idle carries completed job ID in generation; claim has
            // no selected job yet. Both still name the one Worker holder.
            0x4e => release.site == 0x52 and claim.index == 0 and release.index == 0,
            else => false,
        };
    }
    fn enabled(self: *const Scheduler, index: u32, holder: ?u32) bool {
        const op = self.entries[index].op;
        if (op.kind == .release) return if (holder) |h| matches(self.entries[h].op, op) else false;
        if (op.success.?) return holder == null;
        // A fully bracketed failed CAS is a no-op even for the current holder.
        // Overlapping same-role brackets remain rejected independently by add.
        return holder != null;
    }
    fn linearize(self: *Scheduler, index: u32, holder: *?u32, cursors: *[2]u32, count: *u32) Error!void {
        const entry = &self.entries[index];
        const role = @intFromEnum(entry.op.role);
        if (entry.ordinal != none or cursors[role] != index or !self.enabled(index, holder.*)) return error.ImpossibleExclusion;
        if (entry.op.kind == .release) holder.* = null else if (entry.op.success.?) holder.* = index;
        entry.ordinal = count.*;
        count.* += 1;
        cursors[role] = entry.next;
    }
    pub fn seal(self: *Scheduler) Error!void {
        try self.building();
        // Reset only offline planning metadata so a failed validation cannot
        // masquerade as sealed or leave runtime progress partly advanced.
        for (self.entries[0..self.used]) |*entry| entry.ordinal = none;
        var cursors: [2]u32 = .{ self.roles[0].head, self.roles[1].head };
        var holder: ?u32 = null;
        var count: u32 = 0;
        for (0..self.used) |i| {
            const index: u32 = @intCast(i);
            if (self.entries[index].ordinal != none) continue;
            const op = self.entries[index].op;
            // A pending failed claim may have read the current holder before
            // this release, while stamping its AFTER later. Preserve that
            // feasible witness before greedily removing the holder.
            {
                const other = cursors[1 - @as(usize, @intFromEnum(op.role))];
                if (other != none) {
                    const pending = self.entries[other].op;
                    if (pending.kind == .claim and pending.success == false and pending.before < op.after and self.enabled(other, holder))
                        try self.linearize(other, &holder, &cursors, &count);
                }
            }
            if (!self.enabled(index, holder)) {
                // Earliest unfinished AFTER must complete. At most the other
                // role's one pending atomic can enable it: release for a
                // successful claim, successful claim for a failed claim.
                const other = cursors[1 - @as(usize, @intFromEnum(op.role))];
                if (op.kind != .claim or other == none) return error.ImpossibleExclusion;
                const pending = self.entries[other].op;
                if (pending.before >= op.after) return error.ImpossibleExclusion;
                if (op.success.?) {
                    if (pending.kind != .release) return error.ImpossibleExclusion;
                } else if (pending.kind != .claim or pending.success != true) return error.ImpossibleExclusion;
                try self.linearize(other, &holder, &cursors, &count);
            }
            try self.linearize(index, &holder, &cursors, &count);
        }
        if (holder != null or cursors[0] != none or cursors[1] != none or count != self.used) return error.Incomplete;
        for (&self.roles) |*role| role.cursor = role.head;
        self.turn.store(0, .release);
        self.sealed = true;
    }
    /// Call only AFTER observing/leaving the operation BEFORE global marker.
    pub fn ready(self: *Scheduler, role: Role, before: u64) Error!bool {
        try self.running();
        const state = &self.roles[@intFromEnum(role)];
        if (state.cursor == none or self.entries[state.cursor].op.before != before) return error.InvalidOrder;
        const ordinal = self.entries[state.cursor].ordinal;
        const turn = self.turn.load(.acquire);
        if (turn > ordinal) return error.ReplayMismatch;
        if (turn < ordinal) return false;
        state.active = true;
        return true;
    }
    /// Native atomic already happened. Check and advance BEFORE global AFTER
    /// stamp waiting, so an intervening other role marker cannot deadlock it.
    pub fn completed(self: *Scheduler, role: Role, after: u64, actual_success: ?bool) Error!void {
        try self.running();
        const state = &self.roles[@intFromEnum(role)];
        if (state.cursor == none or !state.active) return error.InvalidState;
        const entry = self.entries[state.cursor];
        if (entry.op.after != after or entry.ordinal != self.turn.load(.acquire)) return error.InvalidOrder;
        if (entry.op.success != actual_success) return error.ReplayMismatch;
        state.active = false;
        state.cursor = entry.next;
        self.turn.store(entry.ordinal + 1, .release);
    }
    pub fn abort(self: *Scheduler) void {
        self.aborted.store(true, .release);
    }
    /// Post-join/exclusion only; never grants native cleanup custody.
    pub fn complete(self: *const Scheduler) bool {
        if (self.address != self or !self.sealed or self.aborted.load(.acquire) or self.turn.load(.acquire) != self.used) return false;
        for (self.roles) |role| if (role.cursor != none or role.active) return false;
        return true;
    }
};
