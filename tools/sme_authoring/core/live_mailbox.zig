//! Finite app-specific UI/Control channels. Never used by Render.
//! Actor labels on methods are part of the API: one UI, one Control, one Worker.
//! Values must own their fixed-size contents (no slices or runtime pointers).
const std = @import("std");
const Atomic = std.atomic.Value;
pub const command_capacity = 8;
pub const event_capacity = 16;
pub const CommandKind = enum { play, stop, recover };
pub const Terminal = enum {
    executed,
    rejected,
    cancelled,
    /// Recovery only: accepted work was interrupted before Control observed
    /// completion. Render may already have produced audible or partial effects.
    interrupted,
    failed,
};
pub const Error = error{ InvalidEpoch, IdentityMismatch, QueueFull, AdmissionClosed, SequenceExhausted, UnknownCommand, DuplicateEvent, TerminalNotConsumed, InvalidState, ProgressPending };

/// Finite mailbox availability coordinates, independent of Host/session modules.
/// Original capture callbacks must be bounded, allocation-free and nonblocking.
/// An admitted offline callback may coordinate actors, but cannot supply a load
/// value, a return result or resource-release authority. The observer and its
/// context are immutable/pinned from mailbox construction through actor joins.
pub const Role = enum(u8) { ui, control };
pub const Queue = enum(u8) { commands, events };
pub const Counter = enum(u8) { written, read };
pub const Edge = enum(u8) { before, after };
pub const RingOperation = enum(u8) { push, pop, empty };
pub const Access = enum(u8) { acquire, release };
pub const RingCheckpoint = struct {
    role: Role,
    queue: Queue,
    counter: Counter,
    operation: RingOperation,
    access: Access,
    edge: Edge,
    /// The acting owner's actual monotonic prefix, before this operation.
    local_prefix: usize,
    /// Acquire: absent before, actual existing-load value after. Release:
    /// the native computed next prefix, before and after its real store.
    prefix: ?usize = null,
};
pub const AdmissionOperation = enum(u8) { request_close, close_requested, admission_drained };
pub const AdmissionCheckpoint = struct {
    role: Role,
    operation: AdmissionOperation,
    edge: Edge,
    /// Absent before; actual masked Close bit for close_requested, raw
    /// admission word for admission_drained, and new word for request_close.
    value: ?u8 = null,
    /// Only request_close/after: the real fetchOr return, not another sample.
    prior: ?u8 = null,
};
pub const Checkpoint = union(enum) { ring: RingCheckpoint, admission: AdmissionCheckpoint };
pub const Observer = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, Checkpoint) void,
};
fn emitCheckpoint(observer: ?Observer, checkpoint: Checkpoint) void {
    if (observer) |hook| hook.call(hook.context, checkpoint);
}
fn ringRole(queue: Queue, operation: RingOperation) Role {
    const producer: Role = if (queue == .commands) .ui else .control;
    return if (operation == .push) producer else if (producer == .ui) .control else .ui;
}
fn ringCheckpoint(observer: ?Observer, queue: Queue, operation: RingOperation, counter: Counter, access: Access, edge: Edge, local_prefix: usize, prefix: ?usize) void {
    emitCheckpoint(observer, .{ .ring = .{ .role = ringRole(queue, operation), .queue = queue, .counter = counter, .operation = operation, .access = access, .edge = edge, .local_prefix = local_prefix, .prefix = prefix } });
}

/// Shared allocator; zero is never issued and exhaustion never wraps.
pub const EpochAllocator = struct {
    last: Atomic(u64) = .init(0),
    pub fn allocate(self: *EpochAllocator) Error!u64 {
        var last = self.last.load(.acquire);
        while (true) {
            if (last == std.math.maxInt(u64)) return error.SequenceExhausted;
            if (self.last.cmpxchgWeak(last, last + 1, .acq_rel, .acquire)) |changed| {
                last = changed;
            } else return last + 1;
        }
    }
};

/// SPSC ring: release publication, acquire custody transfer in both directions.
/// Monotonic wrapping counters are safe because distance never exceeds capacity.
fn Ring(comptime T: type, comptime capacity: usize) type {
    return struct {
        slots: [capacity]T = undefined,
        written: Atomic(usize) = .init(0),
        read: Atomic(usize) = .init(0),
        fn push(self: *@This(), value: T, queue: Queue, observer: ?Observer) bool {
            const w = self.written.load(.monotonic);
            ringCheckpoint(observer, queue, .push, .read, .acquire, .before, w, null);
            const r = self.read.load(.acquire);
            ringCheckpoint(observer, queue, .push, .read, .acquire, .after, w, r);
            if (w -% r >= capacity) return false;
            self.slots[w % capacity] = value;
            ringCheckpoint(observer, queue, .push, .written, .release, .before, w, w +% 1);
            self.written.store(w +% 1, .release);
            ringCheckpoint(observer, queue, .push, .written, .release, .after, w, w +% 1);
            return true;
        }
        fn empty(self: *const @This(), queue: Queue, observer: ?Observer) bool {
            const r = self.read.load(.monotonic);
            ringCheckpoint(observer, queue, .empty, .written, .acquire, .before, r, null);
            const w = self.written.load(.acquire);
            ringCheckpoint(observer, queue, .empty, .written, .acquire, .after, r, w);
            return r == w;
        }
        fn pop(self: *@This(), queue: Queue, observer: ?Observer) ?T {
            const r = self.read.load(.monotonic);
            ringCheckpoint(observer, queue, .pop, .written, .acquire, .before, r, null);
            const w = self.written.load(.acquire);
            ringCheckpoint(observer, queue, .pop, .written, .acquire, .after, r, w);
            if (r == w) return null;
            const value = self.slots[r % capacity];
            ringCheckpoint(observer, queue, .pop, .read, .release, .before, r, r +% 1);
            self.read.store(r +% 1, .release);
            ringCheckpoint(observer, queue, .pop, .read, .release, .after, r, r +% 1);
            return value;
        }
    };
}

/// A bounded synchronized copy, not a seqlock over non-atomic bytes.
/// Both actors attempt custody once; contention skips telemetry only. seal()
/// closes future admission AND proves no prior reader/writer retains custody.
/// The caller must still stop future calls before freeing the enclosing Host.
pub fn StatusCell(comptime T: type) type {
    return struct {
        pub const Versioned = struct { version: u64, value: T };
        custody: Atomic(u8) = .init(0), // 0 free, 1 copying, 2 permanently sealed
        skipped: Atomic(u64) = .init(0),
        snapshot: ?Versioned = null,
        pub fn publish(self: *@This(), value: T) bool {
            if (self.custody.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
                _ = self.skipped.fetchAdd(1, .monotonic);
                return false;
            }
            defer self.custody.store(0, .release);
            const version = if (self.snapshot) |old| old.version else 0;
            if (version == std.math.maxInt(u64)) {
                _ = self.skipped.fetchAdd(1, .monotonic);
                return false;
            }
            self.snapshot = .{ .version = version + 1, .value = value };
            return true;
        }
        pub fn read(self: *@This()) ?Versioned {
            if (self.custody.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) return null;
            defer self.custody.store(0, .release);
            return self.snapshot;
        }
        pub fn seal(self: *@This()) bool {
            return if (self.custody.cmpxchgStrong(0, 2, .acq_rel, .acquire)) |state| state == 2 else true;
        }
        pub fn isSealed(self: *const @This()) bool {
            return self.custody.load(.acquire) == 2;
        }
    };
}

pub fn Mailbox(comptime Identity: type, comptime RuntimeReceipt: type, comptime Status: type) type {
    return MailboxWithRecovery(Identity, RuntimeReceipt, Status, void);
}

pub fn MailboxWithRecovery(comptime Identity: type, comptime RuntimeReceipt: type, comptime Status: type, comptime RecoveryEvidence: type) type {
    return struct {
        const Self = @This();
        pub const Command = struct { id: u64, identity: Identity, kind: CommandKind, slot: u8, device_epoch: u64 = 0 };
        pub const Event = struct {
            command: Command,
            kind: enum { accepted, terminal },
            receipt: ?RuntimeReceipt = null,
            terminal: ?Terminal = null,
            recovery: ?RecoveryEvidence = null,
        };
        const Reservation = struct { command: Command, terminal_consumed: bool = false };
        const Emission = struct { command: ?Command = null, accepted: bool = false, terminal: bool = false };
        identity: Identity,
        /// Immutable after construction; its context outlives both actors.
        observer: ?Observer = null,
        commands: Ring(Command, command_capacity) = .{},
        events: Ring(Event, event_capacity) = .{},
        // UI-only reservation ledger. Each live entry reserves TWO event slots,
        // including consumed events, until explicit terminal acknowledgment.
        reservations: [command_capacity]?Reservation = @splat(null),
        next_command: u64 = 1,
        // Control-only ledger, so UI slot reuse cannot race duplicate filtering.
        emissions: [command_capacity]Emission = @splat(.{}),
        // Bit 0 grants the UI publication custody; bit 1 closes admission.
        // Closing cannot lose a publisher that already acquired custody.
        admission: Atomic(u8) = .init(0),
        close_terminal: Atomic(u8) = .init(0), // 0 pending, 1 closed, 2 acknowledged
        status: StatusCell(Status) = .{},

        pub fn init(identity: Identity) Error!Self {
            return initObserved(identity, null);
        }
        pub fn initObserved(identity: Identity, observer: ?Observer) Error!Self {
            if (identity.epoch == 0) return error.InvalidEpoch;
            return .{ .identity = identity, .observer = observer };
        }
        fn check(self: *const Self, identity: Identity) Error!void {
            if (identity.epoch != self.identity.epoch) return error.InvalidEpoch;
            if (!std.meta.eql(identity, self.identity)) return error.IdentityMismatch;
        }
        /// UI. Reserves two credits BEFORE queue publication; rollback on failure.
        pub fn submit(self: *Self, identity: Identity, kind: CommandKind) Error!Command {
            if (kind == .recover) return error.InvalidState;
            return self.submitObserved(identity, kind, 0, {}, noObservation);
        }
        pub fn submitRecovery(self: *Self, identity: Identity, device_epoch: u64) Error!Command {
            if (device_epoch == 0) return error.InvalidEpoch;
            return self.submitObserved(identity, .recover, device_epoch, {}, noObservation);
        }
        fn noObservation(_: void) void {}
        /// Deterministic test interleaving without production callback storage.
        /// Hook runs after admission custody and before any queue publication.
        pub fn testSubmitObserved(self: *Self, identity: Identity, kind: CommandKind, context: anytype, comptime observe: anytype) Error!Command {
            if (!@import("builtin").is_test) @compileError("testSubmitObserved is test-only");
            if (kind == .recover) return error.InvalidState;
            return self.submitObserved(identity, kind, 0, context, observe);
        }
        fn submitObserved(self: *Self, identity: Identity, kind: CommandKind, device_epoch: u64, context: anytype, comptime observe: anytype) Error!Command {
            try self.check(identity);
            if (self.admission.cmpxchgStrong(0, 1, .acq_rel, .acquire)) |state| {
                return if (state & 2 != 0) error.AdmissionClosed else error.QueueFull;
            }
            // Preserve a concurrent sticky Close while relinquishing custody.
            defer _ = self.admission.fetchAnd(@as(u8, 0xfe), .release);
            observe(context);
            if (self.next_command == 0) return error.SequenceExhausted;
            for (&self.reservations, 0..) |*reservation, index| {
                if (reservation.* != null) continue;
                const command: Command = .{ .id = self.next_command, .identity = identity, .kind = kind, .slot = @intCast(index), .device_epoch = device_epoch };
                reservation.* = .{ .command = command };
                if (!self.commands.push(command, .commands, self.observer)) {
                    reservation.* = null;
                    return error.QueueFull;
                }
                self.next_command = if (self.next_command == std.math.maxInt(u64)) 0 else self.next_command + 1;
                return command;
            }
            return error.QueueFull;
        }
        /// Control. At most two calls per controller turn; even after Close,
        /// queued commands are dequeued and receive their reserved cancelled event.
        pub fn popCommand(self: *Self) ?Command {
            const command = self.commands.pop(.commands, self.observer) orelse return null;
            self.emissions[command.slot] = .{ .command = command };
            return command;
        }
        fn emission(self: *Self, command: Command) Error!*Emission {
            try self.check(command.identity);
            if (command.slot >= command_capacity or command.id == 0) return error.UnknownCommand;
            const entry = &self.emissions[command.slot];
            const admitted = entry.command orelse return error.UnknownCommand;
            if (!std.meta.eql(admitted, command)) return error.UnknownCommand;
            return entry;
        }
        /// Control. RuntimeReceipt must retain the exact admitted bank and ticket.
        pub fn publishAccepted(self: *Self, command: Command, receipt: RuntimeReceipt) Error!void {
            const entry = try self.emission(command);
            if (entry.accepted or entry.terminal) return error.DuplicateEvent;
            if (!self.events.push(.{ .command = command, .kind = .accepted, .receipt = receipt }, .events, self.observer)) return error.QueueFull;
            entry.accepted = true;
        }
        /// Control. Host acceptance has no runtime music request or ticket.
        pub fn publishHostAccepted(self: *Self, command: Command) Error!void {
            if (command.kind != .recover) return error.InvalidState;
            const entry = try self.emission(command);
            if (entry.accepted or entry.terminal) return error.DuplicateEvent;
            if (!self.events.push(.{ .command = command, .kind = .accepted }, .events, self.observer)) return error.QueueFull;
            entry.accepted = true;
        }
        /// Control. A pre-admission failure has no receipt and no accepted event.
        pub fn publishTerminal(self: *Self, command: Command, terminal: Terminal, receipt: ?RuntimeReceipt) Error!void {
            return self.publishTerminalEvidence(command, terminal, receipt, null);
        }
        pub fn publishRecoveryTerminal(self: *Self, command: Command, terminal: Terminal, recovery: ?RecoveryEvidence) Error!void {
            if (command.kind != .recover) return error.InvalidState;
            return self.publishTerminalEvidence(command, terminal, null, recovery);
        }
        fn publishTerminalEvidence(self: *Self, command: Command, terminal: Terminal, receipt: ?RuntimeReceipt, recovery: ?RecoveryEvidence) Error!void {
            const entry = try self.emission(command);
            if (entry.terminal) return error.DuplicateEvent;
            if (!self.events.push(.{ .command = command, .kind = .terminal, .terminal = terminal, .receipt = receipt, .recovery = recovery }, .events, self.observer)) return error.QueueFull;
            entry.terminal = true;
        }
        /// UI. Consuming an event alone does NOT restore its command's credits.
        pub fn popEvent(self: *Self) ?Event {
            const event = self.events.pop(.events, self.observer) orelse return null;
            if (event.kind == .terminal) {
                const entry = &self.reservations[event.command.slot];
                std.debug.assert(entry.* != null and entry.*.?.command.id == event.command.id);
                entry.*.?.terminal_consumed = true;
            }
            return event;
        }
        /// UI. Exactly this terminal must already have been consumed.
        pub fn acknowledgeTerminal(self: *Self, id: u64) Error!void {
            for (&self.reservations) |*entry| {
                if (entry.*) |reservation| {
                    if (reservation.command.id != id) continue;
                    if (!reservation.terminal_consumed) return error.TerminalNotConsumed;
                    entry.* = null;
                    return;
                }
            }
            return error.UnknownCommand;
        }
        pub fn requestClose(self: *Self, epoch: u64) Error!void {
            return self.requestCloseBy(epoch, .ui);
        }
        /// Control-origin native failure/abort cleanup, not a replay UI action.
        pub fn requestCloseFromControl(self: *Self, epoch: u64) Error!void {
            return self.requestCloseBy(epoch, .control);
        }
        fn requestCloseBy(self: *Self, epoch: u64, role: Role) Error!void {
            if (epoch != self.identity.epoch) return error.InvalidEpoch;
            emitCheckpoint(self.observer, .{ .admission = .{ .role = role, .operation = .request_close, .edge = .before } });
            const prior = self.admission.fetchOr(2, .acq_rel);
            emitCheckpoint(self.observer, .{ .admission = .{ .role = role, .operation = .request_close, .edge = .after, .value = prior | 2, .prior = prior } });
        }
        pub fn closeRequested(self: *const Self) bool {
            emitCheckpoint(self.observer, .{ .admission = .{ .role = .control, .operation = .close_requested, .edge = .before } });
            const value = self.admission.load(.acquire) & 2;
            emitCheckpoint(self.observer, .{ .admission = .{ .role = .control, .operation = .close_requested, .edge = .after, .value = value } });
            return value != 0;
        }
        /// Control. Non-consuming drain gate, not an additional dequeue attempt.
        /// Observe publisher release before queue emptiness: once closed and not
        /// busy there can be no subsequent publication from any UI submission.
        pub fn admissionDrained(self: *const Self) bool {
            emitCheckpoint(self.observer, .{ .admission = .{ .role = .control, .operation = .admission_drained, .edge = .before } });
            const value = self.admission.load(.acquire);
            emitCheckpoint(self.observer, .{ .admission = .{ .role = .control, .operation = .admission_drained, .edge = .after, .value = value } });
            if (value != 2) return false;
            return self.commands.empty(.commands, self.observer);
        }
        /// Control, only after genuine resource closure. Independent of events.
        pub fn publishClosed(self: *Self) Error!void {
            if (!self.admissionDrained()) return error.InvalidState;
            _ = self.close_terminal.cmpxchgStrong(0, 1, .release, .monotonic);
        }
        pub fn closed(self: *const Self) bool {
            return self.close_terminal.load(.acquire) != 0;
        }
        /// UI. Does not acknowledge ordinary commands implicitly.
        pub fn acknowledgeClosed(self: *Self) Error!void {
            if (self.close_terminal.cmpxchgStrong(1, 2, .acq_rel, .acquire)) |state| {
                if (state != 2) return error.InvalidState;
            }
        }
        /// UI only; caller additionally joins both threads and seals status.
        pub fn allAcknowledged(self: *const Self) bool {
            if (self.close_terminal.load(.acquire) != 2) return false;
            for (self.reservations) |entry| if (entry != null) return false;
            return true;
        }
    };
}

/// Optional finite lifecycle observer. Capture is bounded/nonblocking; replay
/// may wait at the callback, but cannot replace original atomic loads/stores.
/// Pin the observer/context until both native actors have actually joined.
pub const GateRole = enum(u8) { control, worker };
pub const GateCounter = enum(u8) { request, acknowledgment, resumed, progress, stopped };
pub const WorkerGateCheckpoint = struct {
    role: GateRole,
    counter: GateCounter,
    access: Access,
    edge: Edge,
    epoch: u64,
    prefix: ?u64 = null,
};
pub const WorkerGateObserver = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, WorkerGateCheckpoint) void,
};

/// Synchronization storage belongs to Host, never to the runtime being freed.
/// Control alone publishes requests/resumes/stop; Worker alone publishes ack
/// and progress. After park acknowledgment Worker touches ONLY this structure.
pub const WorkerGate = struct {
    pub const Action = union(enum) { work, park: u64, stop };
    epoch: u64,
    observer: ?WorkerGateObserver = null,
    request: Atomic(u64) = .init(0),
    acknowledgment: Atomic(u64) = .init(0),
    resumed: Atomic(u64) = .init(0),
    progress: Atomic(u64) = .init(0),
    stopped: Atomic(bool) = .init(false),
    sequence: u64 = 0, // Control only
    awaiting_progress: u64 = 0, // Control only
    in_call: bool = false, // Worker only
    call_resume: u64 = 0, // Worker only

    pub fn init(epoch: u64) Error!WorkerGate {
        return initObserved(epoch, null);
    }
    pub fn initObserved(epoch: u64, observer: ?WorkerGateObserver) Error!WorkerGate {
        if (epoch == 0) return error.InvalidEpoch;
        return .{ .epoch = epoch, .observer = observer };
    }
    fn checkpoint(self: *const WorkerGate, role: GateRole, counter: GateCounter, access: Access, edge: Edge, prefix: ?u64) void {
        if (self.observer) |hook| hook.call(hook.context, .{ .role = role, .counter = counter, .access = access, .edge = edge, .epoch = self.epoch, .prefix = prefix });
    }
    fn acquire(self: *const WorkerGate, role: GateRole, counter: GateCounter) u64 {
        self.checkpoint(role, counter, .acquire, .before, null);
        const prefix: u64 = switch (counter) {
            .request => self.request.load(.acquire),
            .acknowledgment => self.acknowledgment.load(.acquire),
            .resumed => self.resumed.load(.acquire),
            .progress => self.progress.load(.acquire),
            .stopped => @intFromBool(self.stopped.load(.acquire)),
        };
        self.checkpoint(role, counter, .acquire, .after, prefix);
        return prefix;
    }
    fn publish(self: *WorkerGate, role: GateRole, counter: GateCounter, prefix: u64) void {
        self.checkpoint(role, counter, .release, .before, prefix);
        switch (counter) {
            .request => self.request.store(prefix, .release),
            .acknowledgment => self.acknowledgment.store(prefix, .release),
            .resumed => self.resumed.store(prefix, .release),
            .progress => self.progress.store(prefix, .release),
            .stopped => self.stopped.store(prefix != 0, .release),
        }
        self.checkpoint(role, counter, .release, .after, prefix);
    }
    fn check(self: *const WorkerGate, epoch: u64) Error!void {
        if (epoch != self.epoch) return error.InvalidEpoch;
    }
    pub fn requestPark(self: *WorkerGate, epoch: u64) Error!u64 {
        try self.check(epoch);
        if (self.stopped.load(.acquire)) return error.InvalidState;
        if (self.awaiting_progress != 0 and self.acquire(.control, .progress) != self.awaiting_progress) return error.ProgressPending;
        if (self.sequence != 0 and self.resumed.load(.acquire) != self.sequence) return error.InvalidState;
        if (self.sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
        self.sequence += 1;
        self.awaiting_progress = 0;
        self.publish(.control, .request, self.sequence);
        return self.sequence;
    }
    /// Worker, only between calls. 'work' acquires one call's custody; caller
    /// must call workerCompleted after workerOneV1 returns, including errors.
    pub fn workerAction(self: *WorkerGate, epoch: u64) Error!Action {
        try self.check(epoch);
        if (self.in_call) return error.InvalidState;
        if (self.acquire(.worker, .stopped) != 0) return .stop;
        const requested = self.acquire(.worker, .request);
        const resume_seq = self.acquire(.worker, .resumed);
        if (requested != 0 and requested != resume_seq) return .{ .park = requested };
        self.in_call = true;
        self.call_resume = resume_seq;
        return .work;
    }
    pub fn acknowledgePark(self: *WorkerGate, epoch: u64, sequence: u64) Error!void {
        try self.check(epoch);
        if (self.in_call or sequence == 0 or self.acquire(.worker, .request) != sequence or self.acquire(.worker, .resumed) == sequence) return error.InvalidState;
        self.publish(.worker, .acknowledgment, sequence);
    }
    pub fn parked(self: *const WorkerGate, epoch: u64, sequence: u64) bool {
        return epoch == self.epoch and sequence != 0 and self.request.load(.acquire) == sequence and self.acquire(.control, .acknowledgment) == sequence and self.resumed.load(.acquire) != sequence;
    }
    pub fn resumeAfterPending(self: *WorkerGate, epoch: u64, sequence: u64) Error!void {
        try self.check(epoch);
        if (self.stopped.load(.acquire) or !self.parked(epoch, sequence)) return error.InvalidState;
        self.awaiting_progress = sequence;
        self.publish(.control, .resumed, sequence);
    }
    pub fn workerCompleted(self: *WorkerGate, epoch: u64) Error!void {
        try self.check(epoch);
        if (!self.in_call) return error.InvalidState;
        self.in_call = false;
        if (self.call_resume != 0) self.publish(.worker, .progress, self.call_resume);
    }
    /// A typed no-work deferral relinquishes this call without claiming the
    /// Worker progress required after a pending destroy/resume.
    pub fn workerDeferred(self: *WorkerGate, epoch: u64) Error!void {
        try self.check(epoch);
        if (!self.in_call) return error.InvalidState;
        self.in_call = false;
    }
    /// Internal first-slice exercise only. The fixed test adapter validates an
    /// actual owner-issued late-boundary capability before reaching this helper.
    /// Production Host still uses stopAfterDestroyed and exposes no early seal.
    pub const FinalizationTests = if (@import("builtin").is_test) struct {
        pub fn seal(self: *WorkerGate, epoch: u64, sequence: u64) Error!void {
            try self.check(epoch);
            if (self.stopped.load(.acquire) or !self.parked(epoch, sequence)) return error.InvalidState;
            self.publish(.control, .stopped, 1);
        }
    } else struct {};
    /// Only after successful destroy under the exact current parked custody.
    /// Terminal stop is irreversible and has precedence over all old resumes.
    pub fn stopAfterDestroyed(self: *WorkerGate, epoch: u64, sequence: u64) Error!void {
        try self.check(epoch);
        if (!self.parked(epoch, sequence)) return error.InvalidState;
        self.publish(.control, .stopped, 1);
    }
};

const CheckpointTestRing = Ring(u32, 2);
const CheckpointTestTrace = struct {
    events: [256]Checkpoint = undefined,
    native_prefix: [256]?usize = undefined,
    count: usize = 0,
    ring: ?*CheckpointTestRing = null,
    fn observer(self: *@This()) Observer {
        return .{ .context = self, .call = record };
    }
    fn record(raw: *anyopaque, point: Checkpoint) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        std.debug.assert(self.count < self.events.len);
        self.events[self.count] = point;
        self.native_prefix[self.count] = null;
        if (point == .ring and point.ring.access == .release) {
            if (self.ring) |ring| self.native_prefix[self.count] = switch (point.ring.counter) {
                .written => ring.written.load(.monotonic),
                .read => ring.read.load(.monotonic),
            };
        }
        self.count += 1;
    }
};

test "mailbox Ring checkpoints bracket actual loads and publications in both directions" {
    const t = std.testing;
    inline for (.{ Queue.commands, Queue.events }) |queue| {
        var ring: CheckpointTestRing = .{};
        var trace: CheckpointTestTrace = .{ .ring = &ring };
        const observer = trace.observer();
        try t.expect(ring.empty(queue, observer));
        try t.expect(ring.push(11, queue, observer));
        try t.expect(ring.push(22, queue, observer));
        const before_full = trace.count;
        try t.expect(!ring.push(33, queue, observer));
        try t.expectEqual(before_full + 2, trace.count);
        try t.expectEqual(@as(?u32, 11), ring.pop(queue, observer));
        try t.expect(ring.push(33, queue, observer));
        try t.expectEqual(@as(?u32, 22), ring.pop(queue, observer));
        try t.expectEqual(@as(?u32, 33), ring.pop(queue, observer));
        const before_empty = trace.count;
        try t.expect(ring.pop(queue, observer) == null);
        try t.expectEqual(before_empty + 2, trace.count);
        try t.expect(ring.empty(queue, observer));
        var release_pairs: usize = 0;
        for (trace.events[0..trace.count], 0..) |event, i| {
            const point = event.ring;
            try t.expectEqual(queue, point.queue);
            try t.expectEqual(ringRole(queue, point.operation), point.role);
            if (point.access == .acquire) {
                try t.expectEqual(if (point.operation == .push) Counter.read else Counter.written, point.counter);
                if (point.edge == .before) {
                    try t.expect(point.prefix == null);
                    const after = trace.events[i + 1].ring;
                    try t.expectEqual(Edge.after, after.edge);
                    try t.expectEqual(point.operation, after.operation);
                    try t.expectEqual(point.local_prefix, after.local_prefix);
                    try t.expect(after.prefix != null);
                }
            } else {
                try t.expectEqual(if (point.operation == .push) Counter.written else Counter.read, point.counter);
                try t.expectEqual(@as(?usize, point.local_prefix + 1), point.prefix);
                try t.expectEqual(@as(?usize, if (point.edge == .before) point.local_prefix else point.prefix.?), trace.native_prefix[i]);
                if (point.edge == .after) release_pairs += 1;
            }
        }
        try t.expectEqual(@as(usize, 6), release_pairs);
        try t.expectEqual(@as(usize, 3), ring.written.load(.acquire));
        try t.expectEqual(@as(usize, 3), ring.read.load(.acquire));
    }
}

const CheckpointTestMoveAfterAcquire = struct {
    ring: *CheckpointTestRing,
    operation: RingOperation,
    observed: ?usize = null,
    fired: bool = false,
    fn observer(self: *@This()) Observer {
        return .{ .context = self, .call = record };
    }
    fn record(raw: *anyopaque, event: Checkpoint) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (event != .ring) return;
        const point = event.ring;
        if (self.fired or point.operation != self.operation or point.access != .acquire or point.edge != .after) return;
        self.fired = true;
        self.observed = point.prefix;
        // Exercise actual opposite-side progress after the captured load. No
        // native counter is assigned, and the observed operation must not retry.
        if (self.operation == .push) {
            std.debug.assert(self.ring.pop(.commands, null).? == 11);
        } else {
            std.debug.assert(self.ring.push(42, .commands, null));
        }
    }
};

test "mailbox Ring uses the original acquired prefix despite later opposite-side progress" {
    const t = std.testing;
    inline for (.{ RingOperation.pop, RingOperation.empty }) |operation| {
        var ring: CheckpointTestRing = .{};
        var hook: CheckpointTestMoveAfterAcquire = .{ .ring = &ring, .operation = operation };
        if (operation == .pop) try t.expect(ring.pop(.commands, hook.observer()) == null) else try t.expect(ring.empty(.commands, hook.observer()));
        try t.expect(hook.fired);
        try t.expectEqual(@as(?usize, 0), hook.observed);
        try t.expectEqual(@as(?u32, 42), ring.pop(.commands, null));
    }
    var full: CheckpointTestRing = .{};
    try t.expect(full.push(11, .commands, null));
    try t.expect(full.push(22, .commands, null));
    var hook: CheckpointTestMoveAfterAcquire = .{ .ring = &full, .operation = .push };
    try t.expect(!full.push(33, .commands, hook.observer()));
    try t.expect(hook.fired);
    try t.expectEqual(@as(?usize, 0), hook.observed);
    try t.expectEqual(@as(usize, 2), full.written.load(.acquire));
    try t.expect(full.push(33, .commands, null));
    try t.expectEqual(@as(?u32, 22), full.pop(.commands, null));
    try t.expectEqual(@as(?u32, 33), full.pop(.commands, null));
}

const CheckpointTestIdentity = struct { epoch: u64, revision: u64 = 7 };
const CheckpointTestMailbox = Mailbox(CheckpointTestIdentity, u32, void);

test "mailbox optional observer leaves native reservations events and null-hook results unchanged" {
    const t = std.testing;
    const identity: CheckpointTestIdentity = .{ .epoch = 19 };
    var trace: CheckpointTestTrace = .{};
    var observed = try CheckpointTestMailbox.initObserved(identity, trace.observer());
    var plain = try CheckpointTestMailbox.init(identity);
    try t.expect(plain.observer == null);
    var commands: [command_capacity]CheckpointTestMailbox.Command = undefined;
    for (&commands) |*command| {
        command.* = try observed.submit(identity, .stop);
        try t.expectEqualDeep(try plain.submit(identity, .stop), command.*);
    }
    try t.expectError(error.QueueFull, observed.submit(identity, .play));
    try t.expectError(error.QueueFull, plain.submit(identity, .play));
    for (commands) |command| {
        try t.expectEqualDeep(plain.popCommand(), observed.popCommand());
        try observed.publishAccepted(command, 23);
        try plain.publishAccepted(command, 23);
        try observed.publishTerminal(command, .executed, 23);
        try plain.publishTerminal(command, .executed, 23);
    }
    for (commands) |command| {
        try t.expectEqualDeep(plain.popEvent(), observed.popEvent());
        try t.expectError(error.TerminalNotConsumed, observed.acknowledgeTerminal(command.id));
        try t.expectError(error.TerminalNotConsumed, plain.acknowledgeTerminal(command.id));
        try t.expectEqualDeep(plain.popEvent(), observed.popEvent());
    }
    // Credits remain reserved after pop; release them in the opposite id order.
    try t.expectError(error.QueueFull, observed.submit(identity, .stop));
    try t.expectError(error.QueueFull, plain.submit(identity, .stop));
    for (0..command_capacity) |i| {
        const command = commands[command_capacity - 1 - i];
        try observed.acknowledgeTerminal(command.id);
        try plain.acknowledgeTerminal(command.id);
    }
    const next = try observed.submit(identity, .play);
    try t.expectEqualDeep(try plain.submit(identity, .play), next);
    try t.expectEqual(@as(u8, 0), next.slot);
    try observed.requestClose(identity.epoch);
    try plain.requestClose(identity.epoch);
    try t.expectEqual(plain.admissionDrained(), observed.admissionDrained());
    try t.expectEqualDeep(plain.popCommand(), observed.popCommand());
    try observed.publishTerminal(next, .cancelled, null);
    try plain.publishTerminal(next, .cancelled, null);
    try t.expectEqualDeep(plain.popEvent(), observed.popEvent());
    try observed.acknowledgeTerminal(next.id);
    try plain.acknowledgeTerminal(next.id);
    try observed.publishClosed();
    try plain.publishClosed();
    try observed.acknowledgeClosed();
    try plain.acknowledgeClosed();
    try t.expect(observed.allAcknowledged() and plain.allAcknowledged());
    try t.expectError(error.AdmissionClosed, observed.submit(identity, .play));
    try t.expectError(error.AdmissionClosed, plain.submit(identity, .play));
}

const CheckpointTestCloseWhilePublishing = struct {
    box: *CheckpointTestMailbox,
    fn run(self: *@This()) void {
        std.debug.assert(!self.box.closeRequested()); // raw custody 1, masked 0
        self.box.requestCloseFromControl(self.box.identity.epoch) catch unreachable;
        std.debug.assert(self.box.closeRequested()); // raw custody 3, masked 2
        std.debug.assert(!self.box.admissionDrained()); // raw 3 must not drain
    }
};

test "mailbox Close cuts retain actual RMW bits masked polls and raw drain custody" {
    const t = std.testing;
    const identity: CheckpointTestIdentity = .{ .epoch = 29 };
    {
        var direct_trace: CheckpointTestTrace = .{};
        var direct = try CheckpointTestMailbox.initObserved(identity, direct_trace.observer());
        try direct.requestClose(identity.epoch);
        try t.expectEqualDeep(AdmissionCheckpoint{ .role = .ui, .operation = .request_close, .edge = .after, .value = 2, .prior = 0 }, direct_trace.events[1].admission);
        try t.expect(direct.admissionDrained());
    }
    var trace: CheckpointTestTrace = .{};
    var box = try CheckpointTestMailbox.initObserved(identity, trace.observer());
    try t.expectError(error.InvalidEpoch, box.requestClose(identity.epoch + 1));
    try t.expectEqual(@as(usize, 0), trace.count);
    var concurrent: CheckpointTestCloseWhilePublishing = .{ .box = &box };
    const command = try box.testSubmitObserved(identity, .stop, &concurrent, CheckpointTestCloseWhilePublishing.run);
    try t.expectEqualDeep(AdmissionCheckpoint{ .role = .control, .operation = .close_requested, .edge = .after, .value = 0 }, trace.events[1].admission);
    try t.expectEqualDeep(AdmissionCheckpoint{ .role = .control, .operation = .request_close, .edge = .after, .value = 3, .prior = 1 }, trace.events[3].admission);
    try t.expectEqualDeep(AdmissionCheckpoint{ .role = .control, .operation = .close_requested, .edge = .after, .value = 2 }, trace.events[5].admission);
    try t.expectEqualDeep(AdmissionCheckpoint{ .role = .control, .operation = .admission_drained, .edge = .after, .value = 3 }, trace.events[7].admission);
    // Real deferred custody release preserved the sticky Close. A nonempty
    // command ring still prevents drain, using a distinct non-consuming cut.
    const before_drain = trace.count;
    try t.expect(!box.admissionDrained());
    try t.expectEqualDeep(AdmissionCheckpoint{ .role = .control, .operation = .admission_drained, .edge = .after, .value = 2 }, trace.events[before_drain + 1].admission);
    const empty_cut = trace.events[before_drain + 3].ring;
    try t.expectEqual(RingOperation.empty, empty_cut.operation);
    try t.expectEqual(@as(?usize, 1), empty_cut.prefix);
    try t.expectEqualDeep(command, box.popCommand().?);
    try t.expect(box.admissionDrained());
    const before_duplicate = trace.count;
    try box.requestClose(identity.epoch);
    try t.expectEqualDeep(AdmissionCheckpoint{ .role = .ui, .operation = .request_close, .edge = .after, .value = 2, .prior = 2 }, trace.events[before_duplicate + 1].admission);
    for (trace.events[0..trace.count]) |point| if (point == .admission and point.admission.edge == .before) {
        try t.expect(point.admission.value == null and point.admission.prior == null);
    };
}

const GateCheckpointTrace = struct {
    points: [256]WorkerGateCheckpoint = undefined,
    actual: [256]u64 = undefined,
    used: usize = 0,
    gate: ?*WorkerGate = null,
    fn record(raw: *anyopaque, point: WorkerGateCheckpoint) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const gate = self.gate.?;
        self.points[self.used] = point;
        self.actual[self.used] = switch (point.counter) {
            .request => gate.request.load(.monotonic),
            .acknowledgment => gate.acknowledgment.load(.monotonic),
            .resumed => gate.resumed.load(.monotonic),
            .progress => gate.progress.load(.monotonic),
            .stopped => @intFromBool(gate.stopped.load(.monotonic)),
        };
        self.used += 1;
    }
};
test "WorkerGate optional observer brackets actual lifecycle prefixes without supplying results" {
    const t = std.testing;
    var trace: GateCheckpointTrace = .{};
    var gate = try WorkerGate.initObserved(7, .{ .context = &trace, .call = GateCheckpointTrace.record });
    trace.gate = &gate;
    try t.expectEqual(WorkerGate.Action.work, try gate.workerAction(7));
    try gate.workerCompleted(7);
    const sequence = try gate.requestPark(7);
    try t.expectEqual(@as(u64, 1), sequence);
    try t.expectEqual(sequence, (try gate.workerAction(7)).park);
    try gate.acknowledgePark(7, sequence);
    try gate.acknowledgePark(7, sequence); // genuine idempotent publication
    try t.expect(gate.parked(7, sequence));
    try gate.resumeAfterPending(7, sequence);
    try t.expectError(error.ProgressPending, gate.requestPark(7));
    for (0..2) |_| {
        try t.expectEqual(WorkerGate.Action.work, try gate.workerAction(7));
        try gate.workerCompleted(7); // second publication repeats prefix1
    }
    const next = try gate.requestPark(7);
    try t.expectEqual(@as(u64, 2), next);
    try t.expectEqual(next, (try gate.workerAction(7)).park);
    try gate.acknowledgePark(7, next);
    try gate.stopAfterDestroyed(7, next);
    try t.expectEqual(WorkerGate.Action.stop, try gate.workerAction(7));
    try t.expect(trace.used > 0 and trace.used % 2 == 0);
    var i: usize = 0;
    while (i < trace.used) : (i += 2) {
        const before = trace.points[i];
        const after = trace.points[i + 1];
        try t.expectEqual(Edge.before, before.edge);
        try t.expectEqual(Edge.after, after.edge);
        try t.expectEqual(before.role, after.role);
        try t.expectEqual(before.counter, after.counter);
        try t.expectEqual(before.access, after.access);
        try t.expectEqual(@as(u64, 7), after.epoch);
        try t.expectEqual(after.prefix.?, trace.actual[i + 1]);
        if (before.access == .acquire) try t.expect(before.prefix == null) else try t.expectEqual(before.prefix, after.prefix);
        const publisher: GateRole = switch (before.counter) {
            .request, .resumed, .stopped => .control,
            .acknowledgment, .progress => .worker,
        };
        try t.expectEqual(if (before.access == .release) publisher else if (publisher == .control) GateRole.worker else GateRole.control, before.role);
    }
}
test "WorkerGate absent observer preserves ordinary park progress and stop behavior" {
    const t = std.testing;
    var gate = try WorkerGate.init(9);
    try t.expect(gate.observer == null);
    const sequence = try gate.requestPark(9);
    try t.expect(!gate.parked(9, sequence));
    try t.expectEqual(sequence, (try gate.workerAction(9)).park);
    try gate.acknowledgePark(9, sequence);
    try t.expect(gate.parked(9, sequence));
    try gate.stopAfterDestroyed(9, sequence);
    try t.expectEqual(WorkerGate.Action.stop, try gate.workerAction(9));
}
