const std = @import("std");
const live = @import("sme-author-live-mailbox");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const Identity = struct { epoch: u64, document: u64 = 42, revision: u64 = 1, draft_hash: [32]u8 = @splat(3), artifact_hash: [32]u8 = @splat(4), state: u32 = 7 };
const Receipt = struct { bank: u64, ticket: u64 };
const Status = struct { identity: Identity, count: u64 };
const Box = live.Mailbox(Identity, Receipt, Status);
const identity: Identity = .{ .epoch = 12 };
const receipt: Receipt = .{ .bank = 2, .ticket = 18 };

test "mailbox reserves both event credits until explicit terminal acknowledgment" {
    var box = try Box.init(identity);
    var commands: [live.command_capacity]Box.Command = undefined;
    for (&commands) |*command| command.* = try box.submit(identity, .stop);
    try expectError(error.QueueFull, box.submit(identity, .stop));
    for (commands) |command| {
        try std.testing.expectEqualDeep(command, box.popCommand().?);
        try box.publishAccepted(command, receipt);
        const accepted = box.popEvent().?;
        try expect(accepted.kind == .accepted);
        try std.testing.expectEqualDeep(receipt, accepted.receipt.?);
        try expectError(error.TerminalNotConsumed, box.acknowledgeTerminal(command.id));
    }
    // Empty command and event queues still have no admission credit.
    try expect(box.popCommand() == null and box.popEvent() == null);
    try expectError(error.QueueFull, box.submit(identity, .stop));
    for (commands) |command| try box.publishTerminal(command, .executed, receipt);
    for (commands) |command| {
        const terminal = box.popEvent().?;
        try expect(terminal.kind == .terminal and terminal.command.id == command.id);
    }
    try expectError(error.QueueFull, box.submit(identity, .stop));
    try box.acknowledgeTerminal(commands[0].id);
    try expectError(error.UnknownCommand, box.acknowledgeTerminal(commands[0].id));
    _ = try box.submit(identity, .stop);
    try expectError(error.QueueFull, box.submit(identity, .stop));
}

test "all sixteen completions survive stalled UI and Close uses separate retained slot" {
    var box = try Box.init(identity);
    for (0..live.command_capacity) |_| _ = try box.submit(identity, .stop);
    while (box.popCommand()) |command| {
        try box.publishAccepted(command, receipt);
        try box.publishTerminal(command, .executed, receipt);
    }
    try box.requestClose(identity.epoch);
    try box.requestClose(identity.epoch);
    try box.publishClosed();
    try expect(box.closed());
    try expect(!box.allAcknowledged());
    try box.acknowledgeClosed();
    try expect(!box.allAcknowledged());
    var count: usize = 0;
    while (box.popEvent()) |event| {
        count += 1;
        if (event.kind == .terminal) try box.acknowledgeTerminal(event.command.id);
    }
    try std.testing.expectEqual(@as(usize, 16), count);
    try expect(box.allAcknowledged());
    try box.publishClosed(); // Cannot turn an acknowledged slot back into pending.
    try expect(box.allAcknowledged());
    try expectError(error.AdmissionClosed, box.submit(identity, .play));
}

test "Close cancels queued commands without accepted events or early credit return" {
    var box = try Box.init(identity);
    for (0..live.command_capacity) |_| _ = try box.submit(identity, .stop);
    try box.requestClose(identity.epoch);
    while (box.popCommand()) |command| try box.publishTerminal(command, .cancelled, null);
    var count: usize = 0;
    while (box.popEvent()) |event| {
        try expect(event.kind == .terminal and event.terminal.? == .cancelled and event.receipt == null);
        try box.acknowledgeTerminal(event.command.id);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), count);
    try expect(!box.allAcknowledged());
    try box.publishClosed();
    try box.acknowledgeClosed();
    try expect(box.allAcknowledged());
}

test "epoch document identity and command identity are checked before events" {
    var box = try Box.init(identity);
    var wrong = identity;
    wrong.epoch += 1;
    try expectError(error.InvalidEpoch, box.submit(wrong, .play));
    try expectError(error.InvalidEpoch, box.requestClose(wrong.epoch));
    try expect(!box.closeRequested());
    wrong = identity;
    wrong.artifact_hash[0] ^= 1;
    try expectError(error.IdentityMismatch, box.submit(wrong, .play));
    wrong = identity;
    wrong.revision += 1;
    try expectError(error.IdentityMismatch, box.submit(wrong, .play));
    const command = try box.submit(identity, .play);
    try expectError(error.UnknownCommand, box.publishAccepted(command, receipt));
    _ = box.popCommand();
    var forged = command;
    forged.id += 1;
    try expectError(error.UnknownCommand, box.publishAccepted(forged, receipt));
    forged = command;
    forged.kind = .stop;
    try expectError(error.UnknownCommand, box.publishAccepted(forged, receipt));
    try box.publishAccepted(command, receipt);
    try expectError(error.DuplicateEvent, box.publishAccepted(command, receipt));
    try box.publishTerminal(command, .executed, receipt);
    try expectError(error.DuplicateEvent, box.publishTerminal(command, .failed, null));
    try expectError(error.DuplicateEvent, box.publishAccepted(command, receipt));
    _ = box.popEvent();
    _ = box.popEvent();
    try box.acknowledgeTerminal(command.id);
    const replacement = try box.submit(identity, .stop);
    _ = box.popCommand();
    try expectError(error.UnknownCommand, box.publishTerminal(command, .failed, null));
    try box.publishTerminal(replacement, .rejected, null);
    try expect(box.popEvent().?.command.id == replacement.id);
    try expect(box.popEvent() == null);
}

test "session and command sequence exhaustion never wraps" {
    var epochs: live.EpochAllocator = .{};
    try std.testing.expectEqual(@as(u64, 1), try epochs.allocate());
    epochs.last.store(std.math.maxInt(u64) - 1, .release);
    try std.testing.expectEqual(std.math.maxInt(u64), try epochs.allocate());
    try expectError(error.SequenceExhausted, epochs.allocate());
    try expectError(error.InvalidEpoch, Box.init(.{ .epoch = 0 }));
    var box = try Box.init(identity);
    box.next_command = std.math.maxInt(u64);
    _ = try box.submit(identity, .stop);
    try expectError(error.SequenceExhausted, box.submit(identity, .stop));
}

test "status copy custody is bounded and seal waits for reader release" {
    var status: live.StatusCell(Status) = .{};
    try expect(status.read() == null);
    try expect(status.publish(.{ .identity = identity, .count = 1 }));
    const first = status.read().?;
    try expect(first.version == 1 and first.value.count == 1);
    // Deterministically hold the identical custody acquired by a reader.
    try expect(status.custody.cmpxchgStrong(0, 1, .acquire, .monotonic) == null);
    try expect(!status.publish(.{ .identity = identity, .count = 2 }));
    try expect(status.read() == null);
    try expect(!status.seal());
    try std.testing.expectEqual(@as(u64, 1), status.skipped.load(.acquire));
    status.custody.store(0, .release);
    try expect(status.read().?.value.count == 1);
    try expect(status.publish(.{ .identity = identity, .count = 3 }));
    try expect(status.read().?.version == 2);
    try expect(status.seal());
    try expect(status.isSealed() and status.seal());
    try expect(status.read() == null);
    try expect(!status.publish(.{ .identity = identity, .count = 4 }));
}

test "worker exact park requires returned call then pending retry requires actual progress" {
    var gate = try live.WorkerGate.init(identity.epoch);
    try expect((try gate.workerAction(identity.epoch)) == .work);
    const first = try gate.requestPark(identity.epoch);
    try expectError(error.InvalidState, gate.acknowledgePark(identity.epoch, first));
    try expect(!gate.parked(identity.epoch, first));
    try gate.workerCompleted(identity.epoch); // Also required after workerOne error.
    try expect((try gate.workerAction(identity.epoch)).park == first);
    try gate.acknowledgePark(identity.epoch, first);
    try expect(gate.parked(identity.epoch, first));
    try expect(!gate.parked(identity.epoch + 1, first));
    try expectError(error.InvalidEpoch, gate.resumeAfterPending(identity.epoch + 1, first));
    try gate.resumeAfterPending(identity.epoch, first);
    try expect(!gate.parked(identity.epoch, first));
    try expectError(error.ProgressPending, gate.requestPark(identity.epoch));
    try expect((try gate.workerAction(identity.epoch)) == .work);
    try expectError(error.ProgressPending, gate.requestPark(identity.epoch));
    try gate.workerCompleted(identity.epoch);
    const second = try gate.requestPark(identity.epoch);
    try expect(second == first + 1);
    try expect(!gate.parked(identity.epoch, second)); // Old ack cannot satisfy it.
    try expectError(error.InvalidState, gate.acknowledgePark(identity.epoch, first));
    try expect((try gate.workerAction(identity.epoch)).park == second);
    try gate.acknowledgePark(identity.epoch, second);
    try expect(gate.parked(identity.epoch, second));
    try gate.stopAfterDestroyed(identity.epoch, second);
    try expectError(error.InvalidState, gate.resumeAfterPending(identity.epoch, second));
    try expectError(error.InvalidState, gate.requestPark(identity.epoch));
    try expect((try gate.workerAction(identity.epoch)) == .stop);
    // The successful continuation reads only the external gate, no owner.
}

test "worker sequence exhaustion fails closed rather than accepting old acknowledgment" {
    var gate = try live.WorkerGate.init(identity.epoch);
    gate.sequence = std.math.maxInt(u64);
    gate.resumed.store(gate.sequence, .release);
    try expectError(error.SequenceExhausted, gate.requestPark(identity.epoch));
    try expect(!gate.parked(identity.epoch, gate.sequence));
}

const Stress = struct {
    box: Box,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    fn control(self: *Stress) void {
        while (!self.stop.load(.acquire)) {
            if (self.box.popCommand()) |command| {
                const r: Receipt = .{ .bank = command.identity.document, .ticket = command.id };
                self.box.publishAccepted(command, r) catch {
                    self.failed.store(true, .release);
                    return;
                };
                self.box.publishTerminal(command, .executed, r) catch {
                    self.failed.store(true, .release);
                    return;
                };
                _ = self.box.status.publish(.{ .identity = command.identity, .count = command.id });
            } else std.Thread.yield() catch {};
        }
    }
};

test "concurrent SPSC reservation reuse preserves exact receipts and untorn status" {
    var stress: Stress = .{ .box = try Box.init(identity) };
    const thread = try std.Thread.spawn(.{}, Stress.control, .{&stress});
    defer {
        stress.stop.store(true, .release);
        thread.join();
    }
    const total = 10000;
    var submitted: usize = 0;
    var accepted: usize = 0;
    var terminated: usize = 0;
    var last_terminal: u64 = 0;
    while (terminated != total) {
        try expect(!stress.failed.load(.acquire));
        if (submitted < total) {
            if (stress.box.submit(identity, .stop)) |_| {
                submitted += 1;
            } else |err| try expect(err == error.QueueFull);
        }
        if (stress.box.popEvent()) |event| {
            try expect(event.receipt.?.ticket == event.command.id);
            try std.testing.expectEqualDeep(identity, event.command.identity);
            if (event.kind == .accepted) {
                accepted += 1;
            } else {
                try expect(event.command.id == last_terminal + 1);
                last_terminal = event.command.id;
                terminated += 1;
                try stress.box.acknowledgeTerminal(event.command.id);
            }
        }
        if (stress.box.status.read()) |snapshot| {
            try std.testing.expectEqualDeep(identity, snapshot.value.identity);
            try expect(snapshot.value.count <= total);
        }
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(usize, total), accepted);
}

const CloseInterleaving = struct {
    box: *Box,
    observed_empty: bool = false,
    observed_not_drained: bool = false,
    observed_closed_rejected: bool = false,
    fn whilePublishing(self: *CloseInterleaving) void {
        self.box.requestClose(identity.epoch) catch unreachable;
        self.observed_empty = self.box.popCommand() == null;
        self.observed_not_drained = !self.box.admissionDrained();
        self.box.publishClosed() catch |err| {
            self.observed_closed_rejected = err == error.InvalidState;
        };
    }
};

test "Close cannot pass an empty queue while prior UI publication holds custody" {
    var box = try Box.init(identity);
    var interleaving: CloseInterleaving = .{ .box = &box };
    const command = try box.testSubmitObserved(identity, .stop, &interleaving, CloseInterleaving.whilePublishing);
    try expect(interleaving.observed_empty);
    try expect(interleaving.observed_not_drained);
    try expect(interleaving.observed_closed_rejected);
    // Publication won admission before Close, so its reserved command must
    // still be canceled even though Control previously observed an empty ring.
    try expect(box.closeRequested());
    try expect(!box.admissionDrained());
    try expectError(error.AdmissionClosed, box.submit(identity, .stop));
    try std.testing.expectEqualDeep(command, box.popCommand().?);
    try expect(box.admissionDrained());
    try box.publishTerminal(command, .cancelled, null);
    try box.publishClosed();
    try box.acknowledgeClosed();
    try expect(!box.allAcknowledged());
    const terminal = box.popEvent().?;
    try expect(terminal.kind == .terminal and terminal.command.id == command.id);
    try box.acknowledgeTerminal(command.id);
    try expect(box.allAcknowledged());
}

test "failed UI submission releases admission custody while preserving concurrent Close" {
    var box = try Box.init(identity);
    box.next_command = 0;
    var interleaving: CloseInterleaving = .{ .box = &box };
    try expectError(error.SequenceExhausted, box.testSubmitObserved(identity, .stop, &interleaving, CloseInterleaving.whilePublishing));
    try expect(interleaving.observed_not_drained);
    try expect(box.admissionDrained());
    try box.publishClosed();
    try box.acknowledgeClosed();
    try expect(box.allAcknowledged());
}

test "recovery commands retain exact device epoch and copied terminal across later status" {
    const Recovery = struct { device_epoch: u64, executed_frame: u64 };
    const RecoveryBox = live.MailboxWithRecovery(Identity, Receipt, Status, Recovery);
    var box = try RecoveryBox.init(identity);
    const command = try box.submitRecovery(identity, 7);
    try std.testing.expectEqual(@as(u64, 7), command.device_epoch);
    try std.testing.expectEqualDeep(command, box.popCommand().?);
    try box.publishHostAccepted(command);
    var proof: Recovery = .{ .device_epoch = 7, .executed_frame = 96000 };
    try box.publishRecoveryTerminal(command, .executed, proof);
    proof = .{ .device_epoch = 8, .executed_frame = 192000 };
    try expect(box.status.publish(.{ .identity = identity, .count = proof.device_epoch }));
    const accepted = box.popEvent().?;
    try expect(accepted.receipt == null and accepted.kind == .accepted);
    try expectError(error.TerminalNotConsumed, box.acknowledgeTerminal(command.id));
    const terminal = box.popEvent().?;
    try expect(terminal.receipt == null and terminal.terminal.? == .executed);
    try std.testing.expectEqual(@as(u64, 7), terminal.recovery.?.device_epoch);
    try std.testing.expectEqual(@as(u64, 96000), terminal.recovery.?.executed_frame);
    try expectError(error.DuplicateEvent, box.publishRecoveryTerminal(command, .failed, proof));
    try box.acknowledgeTerminal(command.id);
    try expectError(error.UnknownCommand, box.acknowledgeTerminal(command.id));
}

test "recovery epoch forgery cannot consume another command or bypass Close credits" {
    const Recovery = struct { device_epoch: u64 };
    const RecoveryBox = live.MailboxWithRecovery(Identity, Receipt, Status, Recovery);
    var box = try RecoveryBox.init(identity);
    try expectError(error.InvalidEpoch, box.submitRecovery(identity, 0));
    for (0..live.command_capacity) |i| _ = try box.submitRecovery(identity, i + 1);
    try expectError(error.QueueFull, box.submitRecovery(identity, 9));
    try box.requestClose(identity.epoch);
    while (box.popCommand()) |command| {
        var forged = command;
        forged.device_epoch += 1;
        try expectError(error.UnknownCommand, box.publishRecoveryTerminal(forged, .executed, .{ .device_epoch = forged.device_epoch }));
        try box.publishRecoveryTerminal(command, .cancelled, null);
    }
    var count: usize = 0;
    while (box.popEvent()) |event| {
        try expect(event.kind == .terminal and event.terminal.? == .cancelled and event.recovery == null);
        try box.acknowledgeTerminal(event.command.id);
        count += 1;
    }
    try std.testing.expectEqual(live.command_capacity, count);
    try box.publishClosed();
    try box.acknowledgeClosed();
    try expect(box.allAcknowledged());
    try expectError(error.AdmissionClosed, box.submitRecovery(identity, 9));
}

test "deferred Worker call does not satisfy destroy retry progress" {
    var gate = try live.WorkerGate.init(identity.epoch);
    const park = try gate.requestPark(identity.epoch);
    try std.testing.expectEqualDeep(live.WorkerGate.Action{ .park = park }, try gate.workerAction(identity.epoch));
    try gate.acknowledgePark(identity.epoch, park);
    try gate.resumeAfterPending(identity.epoch, park);
    try std.testing.expectEqual(live.WorkerGate.Action.work, try gate.workerAction(identity.epoch));
    try expectError(error.InvalidEpoch, gate.workerDeferred(identity.epoch + 1));
    try gate.workerDeferred(identity.epoch);
    try expectError(error.InvalidState, gate.workerDeferred(identity.epoch));
    try expectError(error.ProgressPending, gate.requestPark(identity.epoch));
    try std.testing.expectEqual(live.WorkerGate.Action.work, try gate.workerAction(identity.epoch));
    try gate.workerCompleted(identity.epoch);
    const next = try gate.requestPark(identity.epoch);
    try std.testing.expectEqualDeep(live.WorkerGate.Action{ .park = next }, try gate.workerAction(identity.epoch));
    try gate.acknowledgePark(identity.epoch, next);
    try gate.stopAfterDestroyed(identity.epoch, next);
    try std.testing.expectEqual(live.WorkerGate.Action.stop, try gate.workerAction(identity.epoch));
}

// Later-slice protocol model only. No MusicRuntime state is fabricated and no
// production final-seal/attachment API is introduced. Gate actions below are
// the actual WorkerGate methods; retirement fields model the still-unproved
// destroyQuiescent boundary, not an engine drain or a provider close result.
const FinalFreeGateModel = struct {
    const Runtime = @import("bugu_audio").music.MusicRuntime;
    const ActualShutdownReport = @typeInfo(@typeInfo(@TypeOf(Runtime.destroyQuiescent)).@"fn".return_type.?).error_union.payload;
    const Phase = enum { active, retiring, retired, boundary, sealed, detached, freed };
    const Capability = struct {
        model: *const FinalFreeGateModel,
        lifetime: u64,
        service: *const u8,
        session: *const u8,
        epoch: u64,
        park: u64,
        nonce: u64,
    };
    // These are real test threads and real joins. They are deliberately NOT
    // the production Host/Worker/consumer; only storage retention is tested.
    const Joins = struct {
        threads: [3]?std.Thread = @splat(null),
        fn run() void {}
        fn start(self: *Joins) !void {
            errdefer self.joinAll();
            for (&self.threads) |*thread| thread.* = try std.Thread.spawn(.{}, run, .{});
        }
        fn joinOne(self: *Joins, index: usize) void {
            if (self.threads[index]) |thread| {
                thread.join();
                self.threads[index] = null;
            }
        }
        fn joinAll(self: *Joins) void {
            for (0..self.threads.len) |index| self.joinOne(index);
        }
        fn complete(self: *const Joins) bool {
            for (self.threads) |thread| if (thread != null) return false;
            return true;
        }
    };
    gate: live.WorkerGate,
    phase: Phase = .active,
    lifetime: u64,
    service_anchor: u8 = 0,
    session_anchor: u8 = 0,
    service_binding: ?*const u8 = null,
    capability: ?Capability = null,
    joins: *Joins,
    callback_storage_live: bool = true,
    owner_live: bool = true,
    service_live: bool = true,
    worker_operation: bool = false,
    end_attempts: u64 = 0,
    capture_failed: bool = false,
    // Abstract destruction facts; see README's exact production mapping.
    control_torn_down: bool = false,
    callbacks_stopped: bool = false,
    sources_owed: u32 = 1,
    source_close_results: u32 = 0,
    service_leases: u32 = 0,

    fn initInPlace(self: *FinalFreeGateModel, joins: *Joins, lifetime: u64) !void {
        self.* = .{ .gate = try live.WorkerGate.init(identity.epoch), .lifetime = lifetime, .joins = joins };
        self.service_binding = &self.session_anchor;
    }
    fn enterWorker(self: *FinalFreeGateModel) !void {
        if ((try self.gate.workerAction(identity.epoch)) != .work) return error.NotWorkerWork;
        if (self.worker_operation) return error.WorkerOperationActive;
        self.worker_operation = true;
    }
    fn workerClose(self: *FinalFreeGateModel) !void {
        if (!self.worker_operation or !self.gate.in_call or self.phase != .retiring or self.sources_owed == 0)
            return error.InvalidRetirement;
        self.sources_owed -= 1;
        self.source_close_results += 1;
        if (self.sources_owed == 0) self.phase = .retired;
    }
    fn endWorker(self: *FinalFreeGateModel, deferred: bool) !void {
        if (!self.worker_operation) return error.NoWorkerOperation;
        // End is attempted before gate progress/ACK, even after capture poison.
        self.end_attempts += 1;
        self.worker_operation = false;
        if (deferred) try self.gate.workerDeferred(identity.epoch) else try self.gate.workerCompleted(identity.epoch);
    }
    fn acknowledge(self: *FinalFreeGateModel, park: u64) !void {
        if (self.worker_operation) return error.WorkerOperationActive;
        if ((try self.gate.workerAction(identity.epoch)) != .park) return error.NotParked;
        try self.gate.acknowledgePark(identity.epoch, park);
    }
    fn prepareFinalFree(self: *FinalFreeGateModel, park: u64) !Capability {
        if (!self.gate.parked(identity.epoch, park) or self.worker_operation) return error.NotParked;
        if (!self.callbacks_stopped) return error.CallbacksRunning;
        if (self.phase == .boundary) {
            if (self.capability.?.park != park) return error.ForeignCapability;
            return self.capability.?;
        }
        if (self.phase == .active) {
            self.control_torn_down = true;
            self.phase = .retiring;
            return error.DrainPending;
        }
        if (self.phase != .retired or !self.control_torn_down or self.sources_owed != 0 or self.service_leases != 0)
            return error.DrainPending;
        if (self.service_binding != &self.session_anchor) return error.ForeignBinding;
        const value: Capability = .{ .model = self, .lifetime = self.lifetime, .service = &self.service_anchor, .session = &self.session_anchor, .epoch = identity.epoch, .park = park, .nonce = 1 };
        self.capability = value;
        self.phase = .boundary;
        return value;
    }
    fn checkCapability(self: *const FinalFreeGateModel, value: Capability) !void {
        const actual = self.capability orelse return error.NoCapability;
        if (value.model != self or value.lifetime != self.lifetime or value.service != &self.service_anchor or
            value.session != &self.session_anchor or !std.meta.eql(value, actual)) return error.ForeignCapability;
    }
    fn seal(self: *FinalFreeGateModel, value: Capability) !void {
        try self.checkCapability(value);
        if (self.phase != .boundary) return error.CapabilityConsumed;
        if (!self.gate.parked(value.epoch, value.park) or self.gate.stopped.load(.acquire)) return error.NotParked;
        if (self.worker_operation or !self.callbacks_stopped or self.sources_owed != 0 or self.service_leases != 0)
            return error.NotFinalFree;
        if (self.service_binding != &self.session_anchor) return error.ForeignBinding;
        // The only proposed transition, LOCAL TO THIS MODEL. Never call the
        // existing stopAfterDestroyed before its real destruction precondition.
        self.gate.stopped.store(true, .release);
        self.phase = .sealed;
    }
    fn detach(self: *FinalFreeGateModel, value: Capability) !void {
        try self.checkCapability(value);
        if (self.phase != .sealed or !self.gate.stopped.load(.acquire)) return error.NotSealed;
        if (self.service_binding != &self.session_anchor) return error.ForeignBinding;
        self.service_binding = null;
        self.phase = .detached;
    }
    fn finalFree(self: *FinalFreeGateModel, value: Capability) !ActualShutdownReport {
        try self.checkCapability(value);
        if (self.phase != .detached or !self.gate.stopped.load(.acquire) or self.service_binding != null)
            return error.NotDetached;
        if (self.service_leases != 0) return error.DrainPending;
        self.owner_live = false;
        self.service_live = false;
        self.phase = .freed;
        // Only the real return TYPE is reused. This is a modeled result, not a
        // replacement for the actual destroyQuiescent call or resource proof.
        return .{ .sample_leases = 0, .live_instances = 0 };
    }
    fn freeCallbackStorage(self: *FinalFreeGateModel) !void {
        if (self.phase != .freed or !self.joins.complete()) return error.JoinsPending;
        self.callback_storage_live = false;
    }
    fn reachBoundary(self: *FinalFreeGateModel) !Capability {
        self.callbacks_stopped = true; // Abstract genuine backend-stop fact.
        const first = try self.gate.requestPark(identity.epoch);
        try self.acknowledge(first);
        try expectError(error.DrainPending, self.prepareFinalFree(first));
        try self.gate.resumeAfterPending(identity.epoch, first);
        try self.enterWorker();
        try self.workerClose();
        try self.endWorker(false);
        const second = try self.gate.requestPark(identity.epoch);
        try self.acknowledge(second);
        return self.prepareFinalFree(second);
    }
};

test "model final-free boundary preserves real gate retry and capture poison cannot stop retirement" {
    var joins: FinalFreeGateModel.Joins = .{}; try joins.start(); defer joins.joinAll();
    var model: FinalFreeGateModel = undefined; try model.initInPlace(&joins, 1);
    model.capture_failed = true;
    const first = try model.gate.requestPark(identity.epoch);
    try model.acknowledge(first);
    try expectError(error.CallbacksRunning, model.prepareFinalFree(first));
    model.callbacks_stopped = true;
    try expectError(error.DrainPending, model.prepareFinalFree(first));
    try expect(model.capability == null and model.service_binding != null and model.owner_live and model.callback_storage_live);
    try model.gate.resumeAfterPending(identity.epoch, first);
    try model.enterWorker();
    try expectError(error.WorkerOperationActive, model.acknowledge(first));
    try model.endWorker(true); // A no-work defer must not satisfy retry progress.
    try expectError(error.ProgressPending, model.gate.requestPark(identity.epoch));
    try model.enterWorker(); try model.workerClose(); try model.endWorker(false);
    try std.testing.expectEqual(@as(u64, 2), model.end_attempts);
    try std.testing.expectEqual(@as(u32, 1), model.source_close_results);
    const second = try model.gate.requestPark(identity.epoch);
    try expectError(error.NotParked, model.prepareFinalFree(second));
    try model.acknowledge(second);
    const cap = try model.prepareFinalFree(second);
    try expect(std.meta.eql(cap, try model.prepareFinalFree(second)));
    try expect(model.owner_live and model.service_live and model.callback_storage_live);
    try model.seal(cap);
    try expectError(error.CapabilityConsumed, model.seal(cap));
    try expectError(error.InvalidState, model.gate.resumeAfterPending(identity.epoch, first));
    try expectError(error.InvalidState, model.gate.resumeAfterPending(identity.epoch, second));
    try expectError(error.InvalidState, model.gate.requestPark(identity.epoch));
    try expect((try model.gate.workerAction(identity.epoch)) == .stop);
    try model.detach(cap); _ = try model.finalFree(cap);
    try expect(!model.owner_live and !model.service_live and model.callback_storage_live);
    try expectError(error.JoinsPending, model.freeCallbackStorage());
    joins.joinAll(); try model.freeCallbackStorage();
    try expect(!model.callback_storage_live);
}

test "model final seal rejects foreign capability stale ACK and binding without mutation" {
    var joins: FinalFreeGateModel.Joins = .{}; try joins.start(); defer joins.joinAll();
    var model: FinalFreeGateModel = undefined; try model.initInPlace(&joins, 7);
    const cap = try model.reachBoundary();
    var foreign: FinalFreeGateModel = undefined; try foreign.initInPlace(&joins, 7);
    try expectError(error.NoCapability, foreign.seal(cap));
    _ = try foreign.reachBoundary();
    try expectError(error.ForeignCapability, foreign.seal(cap));
    inline for (.{ "lifetime", "epoch", "park", "nonce" }) |field| {
        var changed = cap; @field(changed, field) += 1;
        try expectError(error.ForeignCapability, model.seal(changed));
        try expect(!model.gate.stopped.load(.acquire) and model.phase == .boundary and model.service_binding != null);
    }
    const marker: u8 = 0;
    var wrong_service = cap; wrong_service.service = &marker;
    try expectError(error.ForeignCapability, model.seal(wrong_service));
    var wrong_session = cap; wrong_session.session = &marker;
    try expectError(error.ForeignCapability, model.seal(wrong_session));
    model.service_binding = &marker;
    try expectError(error.ForeignBinding, model.seal(cap));
    try expect(model.service_binding == &marker and !model.gate.stopped.load(.acquire));
    model.service_binding = &model.session_anchor;
    // A reversible resume invalidates the old ACK. This malformed protocol
    // sequence is rejected rather than transformed into a terminal seal.
    try model.gate.resumeAfterPending(identity.epoch, cap.park);
    try expectError(error.NotParked, model.seal(cap));
    try expect(model.owner_live and model.service_live and model.callback_storage_live and model.phase == .boundary);
}

test "model errors after terminal seal retain every allocation and joins precede callback storage free" {
    var joins: FinalFreeGateModel.Joins = .{}; try joins.start(); defer joins.joinAll();
    var model: FinalFreeGateModel = undefined; try model.initInPlace(&joins, 11);
    const cap = try model.reachBoundary(); try model.seal(cap);
    const foreign: u8 = 0;
    model.service_binding = &foreign; // Negative inventory corruption, not engine work.
    try expectError(error.ForeignBinding, model.detach(cap));
    try expect(model.owner_live and model.service_live and model.callback_storage_live and model.service_binding == &foreign);
    try expectError(error.InvalidState, model.gate.resumeAfterPending(identity.epoch, cap.park));
    model.service_binding = &model.session_anchor;
    try model.detach(cap);
    model.service_leases = 1; // Negative final validation failure; never cleared by finalFree.
    try expectError(error.DrainPending, model.finalFree(cap));
    try expect(model.service_leases == 1 and model.owner_live and model.service_live and model.callback_storage_live);
    try expect((try model.gate.workerAction(identity.epoch)) == .stop);
    model.service_leases = 0; _ = try model.finalFree(cap);
    try expectError(error.NotDetached, model.finalFree(cap));
    try expectError(error.JoinsPending, model.freeCallbackStorage());
    joins.joinOne(0); try expectError(error.JoinsPending, model.freeCallbackStorage());
    joins.joinOne(1); try expectError(error.JoinsPending, model.freeCallbackStorage());
    joins.joinOne(2); try model.freeCallbackStorage();
    try expect(!model.callback_storage_live);
}
