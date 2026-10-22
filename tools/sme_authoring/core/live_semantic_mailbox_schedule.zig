//! Offline-only finite scheduling calendar for real SPSC mailbox publications
//! Service observation sequence, lifecycle gate, and two runtime frontiers.
//! Inputs describe publication/read coordinates, never returned engine values.
//! No allocator, IO, sleeps, mailbox pointer, reference cursor or counter setter.
const std = @import("std");
pub const hard_read_cap: usize = 65536;
pub const hard_publication_cap: usize = 65536;
pub const Slot = enum(u8) { commands_written, commands_read, events_written, events_read, closed, service_sequence, gate_request, gate_ack, gate_resumed, gate_progress, gate_stopped, runtime_frame, runtime_commit_horizon };
pub const slot_count = 13;
// runtime_frame and runtime_commit_horizon each identify one atomic in the
// single Host scheduler lifetime, initially zero. They are not stream-generation
// keys. Reset/restart is not admitted: frame strictly advances, horizon may only
// repeat or advance, and a new Host must construct a fresh offline calendar.
// service_sequence is service-wide, not keyed by a stream slot/generation.
// It starts at zero once per supported Host lifetime and never resets. Native
// u64 wrap is outside this finite profile and rejected by strict +1 validation.
pub const Error = error{ InvalidState, ReadBudgetExceeded, PublicationBudgetExceeded, InvalidOrder, CounterOverflow, InvalidPrefix, UnreachablePrefix, Aborted, ReplayMismatch };
const none = std.math.maxInt(u32);
const Read = struct { before: u64, after: u64, target: u64, next: u32 = none };
const Publication = struct { before: u64, after: u64, prefix: u64, next: u32 = none };
const State = struct {
    publication_head: u32 = none,
    publication_tail: u32 = none,
    head: u32 = none,
    tail: u32 = none,
    planned_prefix: u64 = 0,
    planned_publications: u64 = 0,
    // After seal: only the acquiring role writes cursor and active. The
    // publishing role reads cursor and owns pending_publication/publications.
    cursor: std.atomic.Value(u32) = .init(none),
    active: ?u32 = null,
    pending_publication: ?u64 = null,
    publications: u64 = 0,
    progress: std.atomic.Value(u64) = .init(0),
};
pub const Scheduler = struct {
    address: ?*Scheduler = null,
    limit: usize = 0,
    used: usize = 0,
    publications_used: usize = 0,
    sealed: bool = false,
    aborted: std.atomic.Value(bool) = .init(false),
    reads: [hard_read_cap]Read = undefined,
    publication_plan: [hard_publication_cap]Publication = undefined,
    slots: [slot_count]State = .{State{}} ** slot_count,

    /// Initialize final pinned storage before native threads start. Neither
    /// Builder metadata nor the immutable read array may change after seal.
    pub fn init(self: *Scheduler, limit: usize) Error!void {
        if (self.address != null) return error.InvalidState;
        if (limit > hard_read_cap) return error.ReadBudgetExceeded;
        self.limit = limit;
        self.used = 0;
        self.publications_used = 0;
        self.sealed = false;
        self.aborted.store(false, .monotonic);
        self.slots = .{State{}} ** slot_count;
        self.address = self;
    }
    fn building(self: *const Scheduler) Error!void {
        if (self.address != self or self.sealed or self.aborted.load(.acquire)) return error.InvalidState;
    }
    fn running(self: *const Scheduler) Error!void {
        if (self.address != self or !self.sealed) return error.InvalidState;
        if (self.aborted.load(.acquire)) return error.Aborted;
    }
    fn nextValid(slot: Slot, previous: u64, next: u64) Error!void {
        if (slot == .runtime_frame) {
            // Real positive render spans vary; frame values are not ordinals.
            if (next <= previous) return error.InvalidPrefix;
        } else if (slot == .runtime_commit_horizon) {
            // beginGate republishes the completed frontier, including initial0.
            // Each store still has its own bracket/count obligation.
            if (next < previous) return error.InvalidPrefix;
        } else if (slot == .closed or slot == .gate_stopped) {
            if (previous > 1 or next != 1) return error.InvalidPrefix;
        } else if (slot == .gate_ack or slot == .gate_progress) {
            // A parked Worker may acknowledge the same request again; multiple
            // real completed calls may publish the same resume progress.
            if (next == 0) return error.InvalidPrefix;
            if (next == previous) return;
            const expected = std.math.add(u64, previous, 1) catch return error.CounterOverflow;
            if (next != expected) return error.InvalidPrefix;
        } else {
            const expected = std.math.add(u64, previous, 1) catch return error.CounterOverflow;
            if (next != expected) return error.InvalidPrefix;
        }
    }
    /// Paired actual acquire coordinates from execution INPUTS only. Repeated
    /// targets remain distinct occurrence-qualified entries, never collapsed.
    pub fn addRead(self: *Scheduler, slot: Slot, before: u64, after: u64, target: u64) Error!void {
        try self.building();
        if (self.used == self.limit) return error.ReadBudgetExceeded;
        if (before == 0 or after <= before) return error.InvalidOrder;
        if ((slot == .closed or slot == .gate_stopped) and target > 1) return error.InvalidPrefix;
        const state = &self.slots[@intFromEnum(slot)];
        if (state.tail != none) {
            const prior = self.reads[state.tail];
            if (before <= prior.after or target < prior.target) return error.InvalidOrder;
        }
        const n: u32 = @intCast(self.used);
        self.reads[n] = .{ .before = before, .after = after, .target = target };
        if (state.tail == none) state.head = n else self.reads[state.tail].next = n;
        state.tail = n;
        self.used += 1;
    }
    /// Called once per release-AFTER input, not once per before/after pair.
    /// Declares reachable input coordinates; does not publish actual progress.
    pub fn addPublication(self: *Scheduler, slot: Slot, before: u64, after: u64, next: u64) Error!void {
        try self.building();
        const state = &self.slots[@intFromEnum(slot)];
        if (self.publications_used == hard_publication_cap) return error.PublicationBudgetExceeded;
        if (before == 0 or after <= before) return error.InvalidOrder;
        if (state.publication_tail != none and before <= self.publication_plan[state.publication_tail].after) return error.InvalidOrder;
        try nextValid(slot, state.planned_prefix, next);
        const count = std.math.add(u64, state.planned_publications, 1) catch return error.CounterOverflow;
        const n: u32 = @intCast(self.publications_used);
        self.publication_plan[n] = .{ .before = before, .after = after, .prefix = next };
        if (state.publication_tail == none) state.publication_head = n else self.publication_plan[state.publication_tail].next = n;
        state.publication_tail = n;
        self.publications_used += 1;
        state.planned_prefix = next;
        state.planned_publications = count;
    }
    pub fn seal(self: *Scheduler) Error!void {
        try self.building();
        for (&self.slots) |*state| {
            if (state.tail != none and self.reads[state.tail].target > state.planned_prefix) return error.UnreachablePrefix;
            // A load/store can linearize anywhere inside its stamped bracket.
            // Reject impossible ordering without forcing the after stamps to
            // coincide with actual acquisition/publication. Linear merge keeps
            // this finite even at both independent calendar limits.
            var publication = state.publication_head;
            var established: u64 = 0;
            var establishing_before: u64 = 0;
            var read_index = state.head;
            while (read_index != none) {
                const read = self.reads[read_index];
                while (publication != none and self.publication_plan[publication].prefix <= read.target) {
                    const item = self.publication_plan[publication];
                    // Equal-value publications do not re-establish a value.
                    if (item.prefix > established) {
                        established = item.prefix;
                        establishing_before = item.before;
                    }
                    publication = item.next;
                }
                if (read.target > established or (read.target != 0 and establishing_before >= read.after)) return error.UnreachablePrefix;
                if (publication != none and self.publication_plan[publication].after <= read.before) return error.UnreachablePrefix;
                read_index = read.next;
            }
        }
        for (&self.slots) |*state| state.cursor.store(state.head, .release);
        self.sealed = true;
    }
    /// AFTER observing/leaving the read-before global occurrence, poll this.
    /// false means wait for an actual publication; no global turn may be held.
    pub fn readReady(self: *Scheduler, slot: Slot, before: u64) Error!bool {
        try self.running();
        const state = &self.slots[@intFromEnum(slot)];
        const n = state.cursor.load(.acquire);
        if (n == none or self.reads[n].before != before) return error.InvalidOrder;
        if (state.active) |active| {
            if (active != n) return error.InvalidOrder;
            return true;
        }
        const progress = state.progress.load(.acquire);
        const target = self.reads[n].target;
        if (progress > target) return error.ReplayMismatch;
        if (progress < target) return false;
        state.active = n;
        return true;
    }
    /// At acquire-AFTER callback entry, BEFORE waiting for its global stamp.
    /// Actual load result must match; retiring releases blocked publishers.
    /// Returns only the expected after occurrence for identity validation.
    pub fn acquired(self: *Scheduler, slot: Slot, actual: u64) Error!u64 {
        try self.running();
        const state = &self.slots[@intFromEnum(slot)];
        const n = state.active orelse return error.InvalidState;
        const read = self.reads[n];
        if (state.cursor.load(.acquire) != n) return error.InvalidOrder;
        if (actual != read.target) return error.ReplayMismatch;
        state.active = null;
        state.cursor.store(read.next, .release);
        return read.after;
    }
    /// AFTER observing/leaving release-before global occurrence, poll this.
    /// A ready gate authorizes the original publication, never sets a counter.
    pub fn publicationReady(self: *Scheduler, slot: Slot, next: u64) Error!bool {
        try self.running();
        const state = &self.slots[@intFromEnum(slot)];
        if (state.pending_publication) |pending| {
            if (pending != next) return error.InvalidOrder;
            return true;
        }
        try nextValid(slot, state.progress.load(.acquire), next);
        if (state.publications >= state.planned_publications or next > state.planned_prefix) return error.UnreachablePrefix;
        const n = state.cursor.load(.acquire);
        if (n != none and next > self.reads[n].target) return false;
        state.pending_publication = next;
        return true;
    }
    /// At actual release-AFTER callback entry, BEFORE its global stamp wait.
    /// This is the ONLY method advancing observed publication progress.
    pub fn published(self: *Scheduler, slot: Slot, actual: u64) Error!void {
        try self.running();
        const state = &self.slots[@intFromEnum(slot)];
        const pending = state.pending_publication orelse return error.InvalidState;
        if (pending != actual) return error.ReplayMismatch;
        try nextValid(slot, state.progress.load(.acquire), actual);
        state.pending_publication = null;
        state.publications += 1; // bounded by preflighted planned_publications
        state.progress.store(actual, .release);
    }
    pub fn abort(self: *Scheduler) void {
        self.aborted.store(true, .release);
    }
    /// Call only after genuine producer exclusion/join, never as a join grant.
    pub fn complete(self: *const Scheduler) bool {
        if (self.address != self or !self.sealed or self.aborted.load(.acquire)) return false;
        for (&self.slots) |*state| {
            if (state.cursor.load(.acquire) != none or state.active != null or state.pending_publication != null or state.publications != state.planned_publications or state.progress.load(.acquire) != state.planned_prefix) return false;
        }
        return true;
    }
    /// Read-only diagnostic for tests/reporting; no engine state is reachable.
    pub fn observed(self: *const Scheduler, slot: Slot) u64 {
        return self.slots[@intFromEnum(slot)].progress.load(.acquire);
    }
};
