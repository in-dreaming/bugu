//! Explicit recovery of the actual live null device. PCM is copied only from
//! installed device callbacks; tests never call Render or inspect Host owners.
const std = @import("std");
const live = @import("sme-author-live-owner");
const f = @import("sme-stream-reload-fixture");
const t = std.testing;
const a = t.allocator;
const turns = 20_000;
fn pause() !void {
    try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
}
fn build() ![]u8 {
    const source = try std.mem.replaceOwned(u8, a, f.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer a.free(source);
    return f.buildSource(.a, source, null);
}
fn launch(bytes: []const u8) live.Launch {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.authored_source, &hash, .{});
    return .{ .document_id = 29, .revision = 11, .draft_hash = hash, .state = f.state, .compiled = bytes };
}
const Capture = struct {
    // Fixed allocation, callback sole writer, UI reads only after device and
    // Control/Worker joins. Overflow is failure, never permission to overwrite.
    const Record = struct { epoch: u64, first: u64, offset: usize, count: usize, thread: u64 };
    samples: [48_000 * 24 * 2]f32 = undefined,
    records: [8192]Record = undefined,
    len: usize = 0,
    used: usize = 0,
    overflow: bool = false,
    enabled: std.atomic.Value(bool) = .init(true),
    fn observe(raw: *anyopaque, epoch: u64, first: u64, channels: u16, pcm: []const f32) void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        if (!self.enabled.load(.acquire)) return;
        if (channels != 2 or pcm.len % 2 != 0 or self.len == self.records.len or pcm.len > self.samples.len - self.used) {
            self.overflow = true;
            return;
        }
        @memcpy(self.samples[self.used..][0..pcm.len], pcm);
        self.records[self.len] = .{ .epoch = epoch, .first = first, .offset = self.used, .count = pcm.len / 2, .thread = @intCast(std.Thread.getCurrentId()) };
        self.len += 1;
        self.used += pcm.len;
    }
    fn check(self: *const Capture, oracle: *const f.Oracle, epoch: u64, restart: u64, closed: live.Status) !void {
        try t.expect(!self.overflow);
        var silent: usize = 0;
        var sounded: usize = 0;
        var nonzero: usize = 0;
        var wrong_cursor_difference: f32 = 0;
        for (self.records[0..self.len]) |record| {
            if (record.epoch != epoch) continue;
            try t.expect(record.thread != closed.control_thread_id and record.thread != closed.worker_thread_id);
            try t.expect(record.thread != @as(u64, @intCast(std.Thread.getCurrentId())));
            for (0..record.count) |i| {
                const frame = record.first + i;
                const expected = if (frame < restart) @as(f32, 0) else oracle.sampleAt((frame - restart) % f.loop_frames);
                try t.expectApproxEqAbs(expected, self.samples[record.offset + i * 2], f.Oracle.tolerance);
                try t.expectApproxEqAbs(expected, self.samples[record.offset + i * 2 + 1], f.Oracle.tolerance);
                if (frame < restart) {
                    silent += 1;
                } else {
                    sounded += 1;
                    if (@abs(expected) > f.Oracle.tolerance) nonzero += 1;
                    wrong_cursor_difference = @max(wrong_cursor_difference, @abs(expected - oracle.sampleAt((frame - restart + 1) % f.loop_frames)));
                }
            }
        }
        try t.expect(silent > 0 and sounded >= 256 and nonzero > 0);
        try t.expect(wrong_cursor_difference > f.Oracle.tolerance);
    }
};
const Log = struct {
    const Entry = struct { command: live.Mailbox.Command, accepted: bool = false, terminal: ?live.mailbox.Terminal = null, receipt: ?f.music.MusicRuntimeReceiptV1 = null };
    entries: [32]Entry = undefined,
    len: usize = 0,
    fn add(self: *Log, command: live.Mailbox.Command) usize {
        const index = self.len;
        self.entries[index] = .{ .command = command };
        self.len += 1;
        return index;
    }
    fn drain(self: *Log, host: *live.Host, ack: bool) !void {
        while (host.popEvent()) |event| {
            try t.expectEqualDeep(host.identity(), event.command.identity);
            var found = false;
            for (self.entries[0..self.len]) |*entry| {
                if (entry.command.id != event.command.id) continue;
                found = true;
                try t.expectEqualDeep(entry.command, event.command);
                switch (event.kind) {
                    .accepted => {
                        try t.expect(!entry.accepted and entry.terminal == null);
                        entry.accepted = true;
                        if (event.command.kind == .recover) try t.expect(event.receipt == null);
                    },
                    .terminal => {
                        try t.expect(entry.terminal == null);
                        entry.terminal = event.terminal orelse return error.MissingTerminal;
                        entry.receipt = event.receipt;
                        if (event.command.kind == .recover) {
                            try t.expect(event.receipt == null);
                            if (event.recovery) |recovery| {
                                try t.expectEqual(event.command.device_epoch, recovery.device_epoch);
                                if (entry.terminal == .executed) {
                                    try t.expectEqual(.recovered, recovery.stage);
                                    try t.expect(recovery.phase != null and recovery.phase.?.outcome == .executed);
                                }
                            } else try t.expect(entry.terminal != .executed);
                        }
                        if (ack) try host.acknowledgeTerminal(event.command.id);
                    },
                }
                break;
            }
            try t.expect(found);
        }
    }
};
fn dump(v: live.Status) void {
    std.debug.print("RECOVERY STATUS phase={s} first={s} site={s} cleanup={s} lossAccepted={} callbacks={d} worker={d} destroy={d} reopened={d}\n", .{
        @tagName(v.phase), if (v.first_error) |e| @errorName(e) else "none", @tagName(v.first_error_site), if (v.cleanup_error) |e| @errorName(e) else "none", v.loss_accepted, v.callback_sequence, v.worker_calls, v.destroy_attempts, v.reopen_count,
    });
    if (v.recovery) |r| std.debug.print("RECOVERY epoch={d} stage={s} failure={s} prep={s} accepted={d} restart={?d} phase={}\n", .{ r.device_epoch, @tagName(r.stage), if (r.failure) |e| @tagName(e) else "none", if (r.preparation_failure) |e| @tagName(e) else "none", r.accepted_frame, r.restart_frame, r.phase != null });
}
// Control-only owner observation. UI exchanges only atomic requests/results.
const RecoveryGate = struct {
    owner: ?*f.music.MusicRuntime = null,
    held: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    abort: std.atomic.Value(bool) = .init(false),
    fn install(raw: *anyopaque, owner: *f.music.MusicRuntime) void {
        const self: *RecoveryGate = @ptrCast(@alignCast(raw));
        self.owner = owner;
    }
    fn outcome(raw: *anyopaque, _: f.music.MusicRuntime.LiveControlTickOutcomeV1) void {
        const self: *RecoveryGate = @ptrCast(@alignCast(raw));
        if (self.held.load(.acquire) or self.abort.load(.acquire)) return;
        const recovery = self.owner.?.deviceRecoveryStatusV1() catch return;
        if (recovery.device_epoch != 2 or recovery.stage != .scheduled) return;
        self.held.store(true, .release);
        const began = std.Io.Clock.awake.now(t.io);
        while (!self.release.load(.acquire)) {
            if (self.abort.load(.acquire)) return;
            if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds > 5 * std.time.ns_per_s) {
                self.abort.store(true, .release);
                return;
            }
            std.atomic.spinLoopHint();
        }
    }
    fn awaitHeld(self: *RecoveryGate) !void {
        for (0..turns) |_| {
            if (self.abort.load(.acquire)) return error.GateAborted;
            if (self.held.load(.acquire)) return;
            try pause();
        }
        return error.GateObservationTimedOut;
    }
};
const stream = f.rt.streaming.stream;
const RecoveryCut = struct {
    const Mode = enum { supply, supply_partial, scheduled_supply, readiness, cancelled_source };
    const Candidate = @typeInfo(@FieldType(f.music.MusicRuntime, "device_stream_candidate")).optional.child;
    mode: Mode,
    close_on_defer: bool = false,
    owner: ?*f.music.MusicRuntime = null, // Control only.
    armed: bool = false, // Control only.
    triggered: std.atomic.Value(bool) = .init(false),
    waiting_callback: std.atomic.Value(bool) = .init(false),
    advanced: std.atomic.Value(bool) = .init(false),
    captured: std.atomic.Value(bool) = .init(false),
    allow_control: std.atomic.Value(bool) = .init(false),
    abort: std.atomic.Value(bool) = .init(false),
    callback_thread: std.atomic.Value(u64) = .init(0),
    target_frame: std.atomic.Value(u64) = .init(0),
    cancelled: bool = false, // Read only after actual joins.
    retained: bool = false,
    window_id: u64 = 0,
    epoch: u64 = 0,
    generation_address: usize = 0,
    tick_number: u64 = 0,
    handles: [4]f.rt.streaming.Handle = undefined,
    before: ?Candidate = null,
    supply_reads: usize = 0,
    supply_handle: ?f.rt.streaming.Handle = null,
    prefix_handle: ?f.rt.streaming.Handle = null,
    prefix_job: ?u64 = null,
    prefix_slot: ?u16 = null,
    worker_hold: std.atomic.Value(bool) = .init(false),
    worker_release: std.atomic.Value(bool) = .init(false),
    preparation_leases: u32 = 0,
    pending_leases: u32 = 0,
    deferred: ?f.music.MusicRuntime.LiveTickDeferV1 = null,
    fn install(raw: *anyopaque, owner: *f.music.MusicRuntime) void {
        const self: *RecoveryCut = @ptrCast(@alignCast(raw));
        self.owner = owner;
        owner.test_tick_hook = .{ .context = self, .call = tick };
        owner.owned_streaming.?.test_frontier_hook = .{ .context = self, .call = frontier };
        owner.owned_streaming.?.test_readiness_hook = .{ .context = self, .call = readiness };
        owner.owned_streaming.?.test_availability_hook = .{ .context = self, .call = availability };
        if (self.mode == .supply_partial or self.mode == .cancelled_source) {
            owner.owned_streaming.?.test_supply_hook = .{ .context = self, .call = supply };
            owner.owned_streaming.?.test_worker_hook = .{ .context = self, .call = worker };
        }
    }
    fn wait(self: *RecoveryCut, comptime field: []const u8) void {
        const began = std.Io.Clock.awake.now(t.io);
        while (!@field(self, field).load(.acquire)) {
            if (self.abort.load(.acquire)) return;
            if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds > 5 * std.time.ns_per_s) {
                self.abort.store(true, .release);
                return;
            }
            std.atomic.spinLoopHint();
        }
    }
    fn tick(raw: *anyopaque, stage: f.music.MusicRuntime.TickStage) void {
        const self: *RecoveryCut = @ptrCast(@alignCast(raw));
        if (self.triggered.load(.acquire) or self.abort.load(.acquire)) return;
        if (stage == .after_recovery_readiness or
            (stage == .before_recovery_readiness and self.mode != .readiness and self.mode != .cancelled_source))
        {
            self.armed = false;
            return;
        }
        const target: f.music.MusicRuntime.TickStage = if (self.mode == .readiness) .before_recovery_readiness else .before_recovery_supply;
        if (stage != target) return;
        self.armed = false;
        const owner = self.owner.?;
        if (self.mode != .supply_partial and self.mode != .cancelled_source and !owner.renderer.device_callbacks_active.load(.acquire)) return;
        const candidate = owner.device_stream_candidate orelse return;
        if (candidate.device_epoch != 2 or !candidate.windows_opened) return;
        if (self.mode == .scheduled_supply) {
            if (candidate.stage != .scheduled or candidate.committed) return;
        } else if (candidate.stage != .opening) return;
        const bindings = candidate.generation.requestBindingsScoped(.device_recovery, candidate.window_id);
        if (bindings.len != 4) return;
        self.before = candidate;
        self.supply_reads = 0;
        self.window_id = candidate.window_id;
        self.epoch = candidate.device_epoch;
        self.generation_address = @intFromPtr(candidate.generation);
        self.tick_number = owner.tick;
        self.preparation_leases = candidate.generation.preparation_leases;
        self.pending_leases = candidate.generation.pending_plan_leases;
        for (bindings, 0..) |binding, i| self.handles[i] = binding.handle;
        self.target_frame.store(owner.control_frame, .release);
        self.armed = true;
        if (self.mode == .supply_partial or self.mode == .cancelled_source)
            self.worker_hold.store(true, .release);
    }
    fn worker(raw: *anyopaque, _: u64) void {
        const self: *RecoveryCut = @ptrCast(@alignCast(raw));
        if (self.worker_hold.load(.acquire)) self.wait("worker_release");
    }
    fn supply(raw: *anyopaque, point: stream.TestSupplyPoint) void {
        const self: *RecoveryCut = @ptrCast(@alignCast(raw));
        if (point.stage == .prefetch_begin or point.stage == .request_begin) self.supply_handle = point.handle;
        if (!self.armed) return;
        if (self.mode == .cancelled_source and point.stage == .request_begin and !self.triggered.load(.acquire) and
            self.owner.?.renderer.device_callbacks_active.load(.acquire))
        {
            // Exact real request boundary before its cancel read. No runtime
            // readiness witness sink or fabricated result is installed.
            self.triggered.store(true, .release);
            self.owner.?.owned_streaming.?.cancel(point.handle) catch {
                self.abort.store(true, .release);
                self.worker_release.store(true, .release);
                return;
            };
            self.cancelled = true;
            self.worker_release.store(true, .release);
        }
        if (self.mode == .supply_partial and point.stage == .request_queued and self.prefix_job == null) {
            self.prefix_handle = point.handle;
            self.prefix_slot = point.job_slot;
            self.prefix_job = point.job;
        }
    }

    fn cross(self: *RecoveryCut) void {
        if (!self.armed or self.triggered.swap(true, .acq_rel)) return;
        self.waiting_callback.store(true, .release);
        self.wait("advanced");
    }
    fn readiness(raw: *anyopaque, stage: stream.readiness_observation.ReadStage, _: u64) void {
        const self: *RecoveryCut = @ptrCast(@alignCast(raw));
        if (self.mode == .readiness and stage == .before_outer_before) self.cross();
    }
    fn availability(raw: *anyopaque, stage: stream.AvailabilityStage, _: u64) void {
        const self: *RecoveryCut = @ptrCast(@alignCast(raw));
        if (self.mode == .readiness or self.mode == .cancelled_source or stage != .before_sequence or !self.armed) return;
        self.supply_reads += 1;
        if (self.mode == .supply_partial) {
            if (!self.owner.?.renderer.device_callbacks_active.load(.acquire)) return;
            const prefix = self.prefix_handle orelse return;
            const current = self.supply_handle orelse return;
            if (std.meta.eql(prefix, current)) return;
            const service = self.owner.?.owned_streaming.?;
            const pending = service.slots[prefix.index].pending_job orelse return;
            if (pending != self.prefix_slot.? or service.jobs[pending].descriptor.job != self.prefix_job.?) return;
        }
        self.cross();
    }
    fn frontier(raw: *anyopaque, stage: stream.readiness_observation.FrontierStage, frame: u64) void {
        const self: *RecoveryCut = @ptrCast(@alignCast(raw));
        if (stage != .after_runtime_frame or !self.waiting_callback.load(.acquire) or self.advanced.load(.acquire)) return;
        if (frame <= self.target_frame.load(.acquire)) return;
        self.callback_thread.store(@intCast(std.Thread.getCurrentId()), .release);
        self.advanced.store(true, .release);
    }
    fn outcome(raw: *anyopaque, result: f.music.MusicRuntime.LiveControlTickOutcomeV1) void {
        const self: *RecoveryCut = @ptrCast(@alignCast(raw));
        if (!self.triggered.load(.acquire) or self.mode == .cancelled_source or self.captured.load(.acquire)) return;
        const deferred = result.deferred orelse return;
        if (deferred.control_tick != self.tick_number) return;
        const expected: @FieldType(f.music.MusicRuntime.LiveTickDeferV1, "stage") = if (self.mode == .readiness) .recovery_readiness else .recovery_supply;
        if (deferred.stage != expected or (self.mode == .readiness and deferred.observation.reason != .frame_mismatch)) {
            self.abort.store(true, .release);
            return;
        }
        const candidate = self.owner.?.device_stream_candidate orelse {
            self.abort.store(true, .release);
            return;
        };
        const bindings = candidate.generation.requestBindingsScoped(.device_recovery, candidate.window_id);
        var same = candidate.window_id == self.window_id and candidate.device_epoch == self.epoch and
            @intFromPtr(candidate.generation) == self.generation_address and bindings.len == 4 and
            candidate.generation.preparation_leases == self.preparation_leases and
            candidate.generation.pending_plan_leases == self.pending_leases;
        if (self.mode == .scheduled_supply) {
            same = same and candidate.pending_lease and candidate.published and !candidate.preparation_lease and
                std.meta.eql(candidate.block, self.before.?.block) and std.meta.eql(candidate.plan, self.before.?.plan) and
                self.before.?.block != null and self.before.?.plan != null;
        } else {
            same = same and candidate.preparation_lease and !candidate.pending_lease and !candidate.published and
                candidate.block == null and candidate.plan == null;
        }
        if (bindings.len == 4) for (bindings, 0..) |binding, i| {
            same = same and std.meta.eql(binding.handle, self.handles[i]);
        };
        if (self.mode == .supply_partial) {
            const service = self.owner.?.owned_streaming.?;
            const prefix = self.prefix_handle orelse {
                self.abort.store(true, .release);
                return;
            };
            const pending = service.slots[prefix.index].pending_job;
            same = same and self.prefix_job != null and pending != null and pending == self.prefix_slot;
            if (pending) |slot| same = same and service.jobs[slot].descriptor.job == self.prefix_job.?;
        }
        self.worker_release.store(true, .release);
        self.retained = same;
        self.deferred = deferred;
        self.captured.store(true, .release);
        if (self.close_on_defer) self.wait("allow_control");
    }
    fn awaitCaptured(self: *RecoveryCut) !void {
        for (0..turns) |_| {
            if (self.abort.load(.acquire)) return error.RecoveryCutAborted;
            if (self.captured.load(.acquire)) return;
            try pause();
        }
        return error.RecoveryCutObservationTimedOut;
    }
};

const Rig = struct {
    host: *live.Host,
    memory: *live.TestAllocator,
    capture: *Capture,
    log: Log = .{},
    closed_status: ?live.Status = null,
    gate: ?*RecoveryGate = null,
    cut: ?*RecoveryCut = null,
    fn create(bytes: []const u8, fault: @FieldType(live.Options, "test_fault")) !Rig {
        return createObserved(bytes, fault, false, null, false);
    }
    fn createGated(bytes: []const u8, fault: @FieldType(live.Options, "test_fault"), gated: bool) !Rig {
        return createObserved(bytes, fault, gated, null, false);
    }
    fn createObserved(bytes: []const u8, fault: @FieldType(live.Options, "test_fault"), gated: bool, mode: ?RecoveryCut.Mode, close_on_defer: bool) !Rig {
        const memory = try a.create(live.TestAllocator);
        memory.* = .init;
        errdefer {
            _ = memory.deinit();
            a.destroy(memory);
        }
        const capture = try a.create(Capture);
        capture.* = .{};
        errdefer a.destroy(capture);
        const gate: ?*RecoveryGate = if (gated) try a.create(RecoveryGate) else null;
        if (gate) |value| value.* = .{};
        errdefer if (gate) |value| a.destroy(value);
        const cut: ?*RecoveryCut = if (mode != null) try a.create(RecoveryCut) else null;
        if (cut) |value| value.* = .{ .mode = mode.?, .close_on_defer = close_on_defer };
        errdefer if (cut) |value| a.destroy(value);
        const host = try live.Host.createWithTestAllocator(memory, launch(bytes), .{
            .io = t.io,
            .device = .{ .backend = .null_backend },
            .recovery = .restart_at_bar,
            .test_fault = fault,
            .test_pcm = .{ .context = capture, .call = Capture.observe },
            .test_setup = if (gate) |value| .{ .context = value, .call = RecoveryGate.install } else if (cut) |value| .{ .context = value, .call = RecoveryCut.install } else null,
            .test_tick_outcome = if (gate) |value| .{ .context = value, .call = RecoveryGate.outcome } else if (cut) |value| .{ .context = value, .call = RecoveryCut.outcome } else null,
        });
        return .{ .host = host, .memory = memory, .capture = capture, .gate = gate, .cut = cut };
    }
    fn request(self: *Rig, epoch: u64) !live.Mailbox.Command {
        for (0..turns) |_| {
            return self.host.requestRecovery(self.host.identity(), epoch) catch |err| switch (err) {
                error.ProgressPending => {
                    try pause();
                    continue;
                },
                else => return err,
            };
        }
        return error.RequestObservationTimedOut;
    }
    fn expectInvalidEpoch(self: *Rig, epoch: u64) !void {
        for (0..turns) |_| {
            _ = self.host.requestRecovery(self.host.identity(), epoch) catch |err| switch (err) {
                error.ProgressPending => {
                    try pause();
                    continue;
                },
                error.InvalidEpoch => return,
                else => return err,
            };
            return error.UnexpectedEpochAdmission;
        }
        return error.EpochObservationTimedOut;
    }
    fn readProgress(self: *Rig) !?live.Status {
        try self.log.drain(self.host, true);
        if (self.host.readStatus()) |snapshot| {
            if (snapshot.value.first_error) |err| {
                dump(snapshot.value);
                return err;
            }
            return snapshot.value;
        }
        return null;
    }
    fn play(self: *Rig) !u64 {
        const index = self.log.add(try self.host.submit(self.host.identity(), .play));
        for (0..turns) |_| {
            if (try self.readProgress()) |status| if (status.play_executed and self.log.entries[index].terminal == .executed) {
                const receipt = self.log.entries[index].receipt orelse return error.MissingPlayReceipt;
                return receipt.event.terminal.executed.effective_frame;
            };
            try pause();
        }
        return error.PlayObservationTimedOut;
    }
    fn waiting(self: *Rig, after: u64) !live.Status {
        for (0..turns) |_| {
            if (try self.readProgress()) |status| if (status.phase == .waiting_for_recovery) {
                const recovery = status.recovery orelse return error.MissingRecovery;
                if (recovery.device_epoch > after and status.loss_accepted) return status;
            };
            try pause();
        }
        return error.LossObservationTimedOut;
    }
    fn recovered(self: *Rig, epoch: u64, index: usize) !live.Status {
        for (0..turns) |_| {
            if (try self.readProgress()) |status| if (status.recovery) |recovery| {
                if (recovery.device_epoch == epoch and recovery.stage == .recovered and self.log.entries[index].terminal == .executed) {
                    try t.expect(recovery.phase != null and self.log.entries[index].accepted);
                    // More real callbacks after the execution gate give the PCM
                    // oracle a nontrivial span. Sleep never authorizes release.
                    try std.Io.sleep(t.io, .fromMilliseconds(60), .awake);
                    return status;
                }
            };
            try pause();
        }
        return error.RecoveryObservationTimedOut;
    }
    fn close(self: *Rig) !live.Status {
        if (self.closed_status) |status| return status;
        try self.host.requestClose(self.host.identity().epoch);
        for (0..turns) |_| {
            if (self.host.isClosed()) {
                self.host.join() catch {
                    try pause();
                    continue;
                };
                try t.expect(self.host.joined);
                try self.log.drain(self.host, true);
                const status = (self.host.readStatus() orelse return error.MissingClosedStatus).value;
                try t.expectEqual(.closed, status.phase);
                try t.expect(status.worker_joined);
                try t.expect(status.control_thread_id != 0 and status.worker_thread_id != 0);
                try t.expect(status.control_thread_id != status.worker_thread_id);
                try t.expectEqual(@as(usize, 0), status.provider.live);
                try t.expectEqual(status.provider.opened, status.provider.closed);
                try t.expectEqual(@as(u64, 0), status.sample_leases);
                try t.expectEqual(@as(u64, 0), status.live_instances);
                for (self.log.entries[0..self.log.len]) |entry| try t.expect(entry.terminal != null);
                try t.expectError(error.CleanupPending, self.host.destroy());
                try self.host.acknowledgeClosed();
                self.closed_status = status;
                return status;
            }
            try pause();
        }
        if (self.host.readStatus()) |snapshot| dump(snapshot.value);
        return error.CloseObservationTimedOut;
    }
    fn destroy(self: *Rig) !void {
        try self.host.destroy();
        a.destroy(self.capture);
        if (self.gate) |gate| a.destroy(gate);
        if (self.cut) |cut| a.destroy(cut);
        const check = self.memory.deinit();
        a.destroy(self.memory);
        try t.expectEqual(std.heap.Check.ok, check);
    }
    // Failed observation retains every borrowed buffer unless actual joins and
    // all normal acknowledgment gates succeed. A deadline grants no custody.
    fn cleanup(self: *Rig) void {
        if (self.gate) |gate| gate.abort.store(true, .release);
        if (self.cut) |cut| cut.abort.store(true, .release);
        _ = self.close() catch return;
        self.destroy() catch {};
    }
};

test "live explicit recovery reopens actual null callbacks with legal bar four-stem PCM and exact epochs" {
    const bytes = try build();
    defer a.free(bytes);
    var oracle = try f.Oracle.decode(bytes);
    defer oracle.deinit();
    var rig = try Rig.create(bytes, .none);
    var alive = true;
    defer if (alive) rig.cleanup();
    const start = try rig.play();
    const identity = rig.host.identity();
    try rig.host.testRequestLoss();
    const waiting = try rig.waiting(1);
    const epoch = waiting.recovery.?.device_epoch;
    try t.expectError(error.InvalidEpoch, rig.host.requestRecovery(identity, 0));
    try rig.expectInvalidEpoch(epoch - 1);
    try rig.expectInvalidEpoch(epoch + 1);
    var wrong = identity;
    wrong.revision += 1;
    try t.expectError(error.IdentityMismatch, rig.host.requestRecovery(wrong, epoch));
    const index = rig.log.add(try rig.request(epoch));
    const first = (try rig.recovered(epoch, index)).recovery.?;
    try t.expectEqual(first.restart_frame.?, first.phase.?.effective_frame);
    try t.expect(first.restart_frame.? > first.accepted_frame);
    try t.expectEqual(@as(u64, 0), (first.restart_frame.? - start) % f.bar_frames);
    try t.expectEqualDeep(identity, rig.host.identity());
    // A further actual loss after recovery needs a fresh explicit command.
    try rig.host.testRequestLoss();
    const again = try rig.waiting(epoch);
    const next_epoch = again.recovery.?.device_epoch;
    try t.expectEqual(epoch + 1, next_epoch);
    try rig.expectInvalidEpoch(epoch);
    const next = rig.log.add(try rig.request(next_epoch));
    const second = (try rig.recovered(next_epoch, next)).recovery.?;
    rig.capture.enabled.store(false, .release);
    const closed = try rig.close();
    try t.expect(closed.first_error == null);
    try t.expectEqual(@as(u64, 2), closed.reopen_count);
    try rig.capture.check(&oracle, epoch, first.restart_frame.?, closed);
    try rig.capture.check(&oracle, next_epoch, second.restart_frame.?, closed);
    alive = false;
    try rig.destroy();
}

test "live recovery waiting Close bypasses eight retained command credits and joins" {
    const bytes = try build();
    defer a.free(bytes);
    var rig = try Rig.create(bytes, .none);
    var alive = true;
    defer if (alive) rig.cleanup();
    _ = try rig.play();
    try rig.host.testRequestLoss();
    _ = try rig.waiting(1);
    for (0..8) |_| _ = rig.log.add(try rig.host.submit(rig.host.identity(), .stop));
    try t.expectError(error.QueueFull, rig.host.submit(rig.host.identity(), .stop));
    try rig.host.requestClose(rig.host.identity().epoch);
    const closed = try rig.close();
    try t.expect(closed.first_error == null);
    alive = false;
    try rig.destroy();
}

test "live recovery Close immediately after explicit command retains genuine cleanup gates" {
    const bytes = try build();
    defer a.free(bytes);
    var rig = try Rig.create(bytes, .none);
    var alive = true;
    defer if (alive) rig.cleanup();
    _ = try rig.play();
    try rig.host.testRequestLoss();
    const waiting = try rig.waiting(1);
    const index = rig.log.add(try rig.request(waiting.recovery.?.device_epoch));
    try rig.host.requestClose(rig.host.identity().epoch);
    _ = try rig.close();
    try t.expectEqual(if (rig.log.entries[index].accepted) live.mailbox.Terminal.interrupted else live.mailbox.Terminal.cancelled, rig.log.entries[index].terminal.?);
    alive = false;
    try rig.destroy();
}

test "live reopened callback before failed start closes and joins without synthetic success" {
    const bytes = try build();
    defer a.free(bytes);
    var rig = try Rig.create(bytes, .reopen_after_callback);
    var alive = true;
    defer if (alive) rig.cleanup();
    _ = try rig.play();
    try rig.host.testRequestLoss();
    const waiting = try rig.waiting(1);
    const index = rig.log.add(try rig.request(waiting.recovery.?.device_epoch));
    // Wait for failure-driven Close; do not replace it with a test Close race.
    for (0..turns) |_| {
        if (rig.host.isClosed()) break;
        try pause();
    }
    try t.expect(rig.host.isClosed());
    const closed = try rig.close();
    try t.expect(closed.first_error != null);
    try t.expectEqual(live.mailbox.Terminal.failed, rig.log.entries[index].terminal.?);
    alive = false;
    try rig.destroy();
}

test "live scheduled recovery second loss or Close interrupts one accepted command with actual joins" {
    const bytes = try build();
    defer a.free(bytes);
    for ([_]bool{ false, true }) |close_at_cut| {
        var rig = try Rig.createGated(bytes, .none, true);
        var alive = true;
        defer if (alive) rig.cleanup();
        _ = try rig.play();
        try rig.host.testRequestLoss();
        const waiting = try rig.waiting(1);
        const epoch = waiting.recovery.?.device_epoch;
        try t.expectEqual(@as(u64, 2), epoch);
        const first = rig.log.add(try rig.request(epoch));
        try rig.gate.?.awaitHeld();
        if (close_at_cut) {
            try rig.host.requestClose(rig.host.identity().epoch);
        } else {
            try rig.host.testRequestLoss();
        }
        rig.gate.?.release.store(true, .release);
        if (!close_at_cut) {
            const next_waiting = try rig.waiting(epoch);
            try t.expectEqual(epoch + 1, next_waiting.recovery.?.device_epoch);
            try t.expect(rig.log.entries[first].accepted);
            try t.expectEqual(live.mailbox.Terminal.interrupted, rig.log.entries[first].terminal.?);
            try rig.expectInvalidEpoch(epoch);
            const next = rig.log.add(try rig.request(epoch + 1));
            _ = try rig.recovered(epoch + 1, next);
        }
        const closed = try rig.close();
        try t.expect(!rig.gate.?.abort.load(.acquire));
        try t.expect(rig.log.entries[first].accepted);
        try t.expectEqual(live.mailbox.Terminal.interrupted, rig.log.entries[first].terminal.?);
        try t.expect(closed.first_error == null);
        try t.expectEqual(@as(u64, if (close_at_cut) 1 else 2), closed.reopen_count);
        alive = false;
        try rig.destroy();
    }
}

test "live recovery actual readiness and supply read cuts retain exact candidate windows leases and command" {
    const bytes = try build();
    defer a.free(bytes);
    const cases = [_]struct { mode: RecoveryCut.Mode, close: bool }{
        .{ .mode = .readiness, .close = false },
        .{ .mode = .readiness, .close = true },
        .{ .mode = .supply, .close = false },
        .{ .mode = .supply_partial, .close = false },
        .{ .mode = .scheduled_supply, .close = false },
    };
    for (cases) |case| {
        var rig = try Rig.createObserved(bytes, .none, false, case.mode, case.close);
        var alive = true;
        defer if (alive) rig.cleanup();
        _ = try rig.play();
        try rig.host.testRequestLoss();
        const waiting = try rig.waiting(1);
        const epoch = waiting.recovery.?.device_epoch;
        const index = rig.log.add(try rig.request(epoch));
        try rig.cut.?.awaitCaptured();
        if (case.close) {
            try rig.host.requestClose(rig.host.identity().epoch);
            rig.cut.?.allow_control.store(true, .release);
        } else {
            _ = try rig.recovered(epoch, index);
        }
        const closed = try rig.close();
        const cut = rig.cut.?;
        try t.expect(!cut.abort.load(.acquire));
        try t.expect(cut.retained and cut.advanced.load(.acquire));
        try t.expectEqual(epoch, cut.epoch);
        try t.expect(cut.deferred != null and cut.deferred.?.control_tick == cut.tick_number);
        try t.expect(cut.callback_thread.load(.acquire) != 0);
        try t.expect(cut.callback_thread.load(.acquire) != closed.control_thread_id);
        try t.expect(cut.callback_thread.load(.acquire) != closed.worker_thread_id);
        try t.expect(cut.callback_thread.load(.acquire) != @as(u64, @intCast(std.Thread.getCurrentId())));
        try t.expect(rig.log.entries[index].accepted);
        try t.expectEqual(if (case.close) live.mailbox.Terminal.interrupted else live.mailbox.Terminal.executed, rig.log.entries[index].terminal.?);
        try t.expect(closed.first_error == null);
        alive = false;
        try rig.destroy();
    }
}

test "live recovery genuinely cancelled candidate source remains a failure rather than a typed defer" {
    const bytes = try build();
    defer a.free(bytes);
    var rig = try Rig.createObserved(bytes, .none, false, .cancelled_source, false);
    var alive = true;
    defer if (alive) rig.cleanup();
    _ = try rig.play();
    try rig.host.testRequestLoss();
    const waiting = try rig.waiting(1);
    const index = rig.log.add(try rig.request(waiting.recovery.?.device_epoch));
    for (0..turns) |_| {
        if (rig.host.isClosed()) break;
        try pause();
    }
    try t.expect(rig.host.isClosed());
    const closed = try rig.close();
    try t.expect(rig.cut.?.cancelled and rig.cut.?.triggered.load(.acquire));
    try t.expect(!rig.cut.?.captured.load(.acquire) and !rig.cut.?.abort.load(.acquire));
    try t.expectEqual(@as(anyerror, error.DeviceRecoveryFailed), closed.first_error.?);
    try t.expectEqual(.invalid_state, closed.recovery.?.preparation_failure.?);
    try t.expect(rig.log.entries[index].accepted);
    try t.expectEqual(live.mailbox.Terminal.failed, rig.log.entries[index].terminal.?);
    alive = false;
    try rig.destroy();
}
