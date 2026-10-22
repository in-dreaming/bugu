//! Default live Host qualification against an actual Control-held Service
//! claim. The real null-device callback, fixed Worker and Control all run;
//! no busy bit, job state, receipt, Render call or PCM is manufactured.
const std = @import("std");
const live = @import("sme-author-live-owner");
const f = @import("sme-stream-reload-fixture");
const stream = f.rt.streaming.stream;
const t = std.testing;
const a = t.allocator;
const observation_turns = 20_000;

fn pause() !void {
    try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
}
fn buildBank() ![]u8 {
    const source = try std.mem.replaceOwned(u8, a, f.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer a.free(source);
    return f.buildSource(.a, source, null);
}
fn launch(bytes: []const u8) live.Launch {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.authored_source, &hash, .{});
    return .{ .document_id = 37, .revision = 13, .draft_hash = hash, .state = f.state, .compiled = bytes };
}

const Probe = struct {
    // Installed before worker_ready, then read only by the registered Worker.
    owner: ?*f.music.MusicRuntime = null,
    // Set by that Worker before publishing load.completed. Control receives
    // this pointer through the real load acquisition; UI never dereferences it.
    service: ?*f.rt.streaming.Service = null,
    installed: std.atomic.Value(bool) = .init(false),
    setup_failed: std.atomic.Value(bool) = .init(false),
    armed: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    abort: std.atomic.Value(bool) = .init(false),
    compared: std.atomic.Value(bool) = .init(false),
    failed_claims: std.atomic.Value(u64) = .init(0),
    scans_while_held: std.atomic.Value(u64) = .init(0),
    job_effects_while_held: std.atomic.Value(u64) = .init(0),
    worker_thread: std.atomic.Value(u64) = .init(0),
    control_thread: u64 = 0,
    states: [256]u8 = undefined,
    pending: [64]?u16 = undefined,
    next_job: u64 = 0,
    free_jobs: usize = 0,
    unchanged: bool = false,
    runtime_failure_after_claim: u8 = 0,
    callback_frames: std.atomic.Value(u64) = .init(0),
    audible_frames: std.atomic.Value(u64) = .init(0),
    callback_thread: std.atomic.Value(u64) = .init(0),
    invalid_pcm: std.atomic.Value(bool) = .init(false),

    fn install(raw: *anyopaque, owner: *f.music.MusicRuntime) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.owner = owner;
        // initial_bank_only has no Service at createV1. The load Worker owns
        // its newly prepared Service exclusively until it publishes completed.
        owner.test_load_hook = .{ .context = self, .call = loaded };
    }
    fn loaded(raw: *anyopaque, stage: f.music.MusicRuntime.LoadStage) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (stage != .prepared) return;
        const candidate = self.owner.?.load.candidate orelse {
            self.setup_failed.store(true, .release);
            return;
        };
        const service = candidate.service orelse {
            self.setup_failed.store(true, .release);
            return;
        };
        self.service = service;
        service.test_checkpoint_hook = .{ .context = self, .call = checkpoint };
        self.installed.store(true, .release);
        // Immutable until the actual Service destruction. Neither UI nor
        // Control installs or detaches a pointer while Worker can read it.
    }
    fn wait(self: *Probe, comptime field: []const u8) bool {
        const began = std.Io.Clock.awake.now(t.io);
        while (!@field(self, field).load(.acquire)) {
            if (self.abort.load(.acquire)) return false;
            if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds > 5 * std.time.ns_per_s) {
                self.abort.store(true, .release);
                return false;
            }
            // Test-only non-RT barrier, bounded and abortable. No transient
            // production retry or tight busy-loop is added to either owner.
            pause() catch {
                self.abort.store(true, .release);
                return false;
            };
        }
        return true;
    }
    fn checkpoint(raw: *anyopaque, point: stream.OfflineCheckpoint) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (!self.armed.load(.acquire) or self.abort.load(.acquire)) return;
        if (point.site == .worker_claim and point.edge == .before) {
            // Permit only the first actual failed CAS during the held claim.
            // Later Host calls wait here, outside Service exclusion, so they
            // cannot obscure that invocation or affect the observed job set.
            if (self.failed_claims.load(.acquire) == 0) {
                _ = self.wait("entered");
            } else _ = self.wait("released");
            return;
        }
        if (point.site == .stream_close_claim and point.edge == .after and point.value == 0 and !self.entered.load(.acquire)) {
            const service = self.service.?;
            self.control_thread = @intCast(std.Thread.getCurrentId());
            self.next_job = service.next_job;
            self.free_jobs = service.free_job_count;
            for (service.jobs, 0..) |*job, i| self.states[i] = @intFromEnum(job.state.load(.acquire));
            for (service.slots, 0..) |slot, i| self.pending[i] = slot.pending_job;
            // The original successful Control CAS already owns exclusion.
            // Only now can the real Host Worker cross its original CAS.
            self.entered.store(true, .release);
            _ = self.wait("released");
            var same = service.next_job == self.next_job and service.free_job_count == self.free_jobs;
            for (service.jobs, 0..) |*job, i| same = same and self.states[i] == @intFromEnum(job.state.load(.acquire));
            for (service.slots, 0..) |slot, i| same = same and self.pending[i] == slot.pending_job;
            self.runtime_failure_after_claim = self.owner.?.worker_failure.load(.acquire);
            self.unchanged = same;
            self.compared.store(true, .release);
            return;
        }
        if (!self.entered.load(.acquire) or self.released.load(.acquire)) return;
        switch (point.site) {
            .worker_claim => if (point.edge == .after and point.value != 0) {
                self.worker_thread.store(@intCast(std.Thread.getCurrentId()), .release);
                _ = self.failed_claims.fetchAdd(1, .release);
            },
            .worker_scan => _ = self.scans_while_held.fetchAdd(1, .monotonic),
            .worker_running, .worker_completed, .job_queued, .job_free => _ = self.job_effects_while_held.fetchAdd(1, .monotonic),
            else => {},
        }
    }
    fn pcm(raw: *anyopaque, _: u64, _: u64, channels: u16, samples: []const f32) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.callback_thread.store(@intCast(std.Thread.getCurrentId()), .release);
        if (channels != 2 or samples.len % 2 != 0) {
            self.invalid_pcm.store(true, .release);
            return;
        }
        var audible: u64 = 0;
        for (0..samples.len / 2) |i| {
            if (!std.math.isFinite(samples[i * 2]) or !std.math.isFinite(samples[i * 2 + 1])) self.invalid_pcm.store(true, .release);
            if (@abs(samples[i * 2]) > f.Oracle.tolerance or @abs(samples[i * 2 + 1]) > f.Oracle.tolerance) audible += 1;
        }
        _ = self.callback_frames.fetchAdd(samples.len / 2, .release);
        _ = self.audible_frames.fetchAdd(audible, .release);
    }
};

const Log = struct {
    const Entry = struct {
        command: live.Mailbox.Command,
        accepted: ?f.music.MusicRuntimeReceiptV1 = null,
        terminal: ?live.mailbox.Terminal = null,
        receipt: ?f.music.MusicRuntimeReceiptV1 = null,

        fn executed(self: Entry) bool {
            const receipt = self.receipt orelse return false;
            return self.accepted != null and self.terminal == .executed and
                receipt.event == .terminal and receipt.event.terminal == .executed and
                receipt.event.terminal.executed.outcome == .executed;
        }
    };
    entries: [2]Entry = undefined,
    len: usize = 0,
    fn add(self: *Log, command: live.Mailbox.Command) void {
        self.entries[self.len] = .{ .command = command };
        self.len += 1;
    }
    fn drain(self: *Log, host: *live.Host) !void {
        while (host.popEvent()) |event| {
            var found = false;
            for (self.entries[0..self.len]) |*entry| {
                if (entry.command.id != event.command.id) continue;
                found = true;
                try t.expectEqualDeep(entry.command, event.command);
                switch (event.kind) {
                    .accepted => {
                        try t.expect(entry.accepted == null and entry.terminal == null);
                        const receipt = event.receipt orelse return error.MissingAcceptedReceipt;
                        try t.expect(receipt.event == .accepted);
                        entry.accepted = receipt;
                    },
                    .terminal => {
                        try t.expect(entry.terminal == null);
                        entry.terminal = event.terminal orelse return error.MissingTerminal;
                        entry.receipt = event.receipt;
                        if (event.receipt) |receipt| {
                            try t.expect(receipt.event == .terminal);
                            if (entry.accepted) |accepted| try t.expectEqualDeep(accepted.ticket, receipt.ticket);
                        }
                        try host.acknowledgeTerminal(event.command.id);
                    },
                }
                break;
            }
            try t.expect(found);
        }
    }
};
fn awaitPlaying(host: *live.Host, probe: *Probe, log: *Log) !void {
    for (0..observation_turns) |_| {
        try log.drain(host);
        if (host.readStatus()) |snapshot| {
            if (snapshot.value.first_error) |err| return err;
            if (snapshot.value.play_executed and snapshot.value.callback_sequence > 0 and probe.audible_frames.load(.acquire) > 0) return;
        }
        try pause();
    }
    return error.PlayObservationTimedOut;
}
fn awaitClosed(host: *live.Host) !live.Status {
    for (0..observation_turns) |_| {
        if (host.isClosed()) {
            host.join() catch |err| switch (err) {
                error.CleanupPending => {
                    try pause();
                    continue;
                },
            };
            if (host.readStatus()) |snapshot| return snapshot.value;
        }
        try pause();
    }
    return error.CloseObservationTimedOut;
}
fn cleanup(host: *live.Host, probe: *Probe) bool {
    probe.abort.store(true, .release);
    probe.released.store(true, .release);
    host.requestClose(host.identity().epoch) catch return false;
    _ = awaitClosed(host) catch return false;
    while (host.popEvent()) |event| if (event.kind == .terminal) host.acknowledgeTerminal(event.command.id) catch {};
    host.acknowledgeClosed() catch return false;
    host.destroy() catch return false;
    return true;
}
fn releaseMemory(memory: *live.TestAllocator) !void {
    const check = memory.deinit();
    a.destroy(memory);
    try t.expectEqual(std.heap.Check.ok, check);
}
const Case = enum { resume_after_release, close_while_deferred, later_provider_error };
fn runClaim(bytes: []const u8, case: Case) !void {
    const memory = try a.create(live.TestAllocator);
    memory.* = .init;
    var release_memory = true;
    errdefer if (release_memory) releaseMemory(memory) catch {};
    const probe = try a.create(Probe);
    probe.* = .{};
    var release_probe = true;
    defer if (release_probe) a.destroy(probe);
    var options: live.Options = .{
        .io = t.io,
        .device = .{ .backend = .null_backend },
        .test_before_worker = .{ .context = probe, .call = Probe.install },
        .test_pcm = .{ .context = probe, .call = Probe.pcm },
    };
    // Deliberately leave the real default recovery=.close unchanged.
    try t.expectEqual(.close, options.recovery);
    if (case == .later_provider_error) options.source_fault.fail_close_call = 1;
    const host = try live.Host.createWithTestAllocator(memory, launch(bytes), options);
    var alive = true;
    errdefer if (alive and !cleanup(host, probe)) {
        // A failed observation never grants permission to free borrowed hook
        // context or allocator storage while any actual owner retains custody.
        release_memory = false;
        release_probe = false;
    };
    var log: Log = .{};
    log.add(try host.submit(host.identity(), .play));
    try awaitPlaying(host, probe, &log);
    try t.expect(probe.installed.load(.acquire) and !probe.setup_failed.load(.acquire));
    const before_deferred = host.worker_deferred.load(.acquire);
    probe.armed.store(true, .release);
    log.add(try host.submit(host.identity(), .stop));
    var returned = false;
    var forced_error: u32 = 0;
    for (0..observation_turns) |_| {
        if (probe.abort.load(.acquire)) return error.ClaimBarrierAborted;
        if (probe.failed_claims.load(.acquire) != 0) {
            forced_error = host.worker_error.load(.acquire);
            if (forced_error != 0 or host.worker_deferred.load(.acquire) > before_deferred) {
                returned = true;
                break;
            }
        }
        try pause();
    }
    try t.expect(returned);
    // Control is still inside the real successful close claim. This call's
    // typed result/error has reached Host; no subsequent Service pump can run.
    if (case == .close_while_deferred) {
        try host.requestClose(host.identity().epoch);
        try t.expectError(error.CleanupPending, host.join());
        try t.expectError(error.CleanupPending, host.destroy());
    }
    const calls_at_release = host.worker_calls.load(.acquire);
    probe.released.store(true, .release);
    var execution_observed = false;
    if (forced_error == 0 and case != .close_while_deferred) {
        for (0..observation_turns) |_| {
            try log.drain(host);
            if (host.readStatus()) |snapshot| {
                // Status is latest-value telemetry, not a retained phase log.
                // The original runtime terminal is retained by the mailbox;
                // unchanged/control_applied/cancelled are not real Stop execution.
                if (log.entries[1].executed() and snapshot.value.stop_executed and
                    snapshot.value.worker_deferred > before_deferred and snapshot.value.worker_calls > calls_at_release)
                {
                    execution_observed = true;
                    break;
                }
                if (snapshot.value.first_error != null) break;
            }
            try pause();
        }
    }
    try host.requestClose(host.identity().epoch);
    const closed = try awaitClosed(host);
    try log.drain(host);
    const terminal_worker_error = host.worker_error.load(.acquire);
    try t.expect(host.joined and closed.worker_joined and closed.phase == .closed);
    try t.expectEqual(@as(usize, 0), closed.provider.live);
    try t.expectEqual(closed.provider.opened, closed.provider.closed);
    try t.expectEqual(@as(u64, 0), closed.sample_leases);
    try t.expectEqual(@as(u64, 0), closed.live_instances);
    for (log.entries[0..log.len]) |entry| try t.expect(entry.terminal != null);
    try t.expect(probe.compared.load(.acquire) and probe.unchanged);
    try t.expect(!probe.abort.load(.acquire));
    try t.expectEqual(@as(u64, 1), probe.failed_claims.load(.acquire));
    try t.expectEqual(@as(u64, 0), probe.scans_while_held.load(.acquire));
    try t.expectEqual(@as(u64, 0), probe.job_effects_while_held.load(.acquire));
    try t.expectEqual(closed.control_thread_id, probe.control_thread);
    try t.expectEqual(closed.worker_thread_id, probe.worker_thread.load(.acquire));
    try t.expect(closed.control_thread_id != 0 and closed.worker_thread_id != 0 and closed.control_thread_id != closed.worker_thread_id);
    const callback = probe.callback_thread.load(.acquire);
    try t.expect(callback != 0 and callback != closed.control_thread_id and callback != closed.worker_thread_id);
    try t.expect(callback != @as(u64, @intCast(std.Thread.getCurrentId())));
    try t.expect(!probe.invalid_pcm.load(.acquire) and probe.callback_frames.load(.acquire) > 0 and probe.audible_frames.load(.acquire) > 0);
    try t.expectError(error.CleanupPending, host.destroy());
    try host.acknowledgeClosed();
    try host.destroy();
    alive = false;
    release_memory = false;
    try releaseMemory(memory);
    if (case != .close_while_deferred and !execution_observed) {
        std.debug.print("claim {s}: final status={any}\n", .{ @tagName(case), closed });
        for (log.entries[0..log.len]) |entry| std.debug.print("  command={any} accepted={any} terminal={any} receipt={any}\n", .{
            entry.command, entry.accepted, entry.terminal, entry.receipt,
        });
    }
    // In the unfixed default Host this reports the captured initial WorkerBusy
    // only AFTER normal cancellation, callback/Worker/Control joins and free.
    if (forced_error != 0) return @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(forced_error)));
    try t.expectEqual(@as(u8, 0), probe.runtime_failure_after_claim);
    try t.expect(closed.worker_deferred > before_deferred);
    // Check the later failure independently, before execution evidence, so a
    // missing Stop cannot conceal the error that default recovery preserved.
    if (case == .later_provider_error) {
        try t.expectEqual(@as(u32, @intFromError(error.SourceCloseFailed)), terminal_worker_error);
        try t.expectEqual(@as(?anyerror, error.SourceCloseFailed), closed.cleanup_error);
        try t.expect(closed.provider.close_attempts > closed.provider.closed);
    } else {
        try t.expectEqual(@as(u32, 0), terminal_worker_error);
        try t.expect(closed.first_error == null and closed.cleanup_error == null);
    }
    if (case != .close_while_deferred) {
        // Cleanup cannot turn an observation timeout into successful resumption.
        try t.expect(execution_observed);
        try t.expect(log.entries[0].executed());
        try t.expect(log.entries[1].executed());
        try t.expect(closed.stop_executed);
        try t.expect(closed.worker_calls > calls_at_release);
    }
}

test "default live Host defers actual initial Worker claim then resumes Stop and joins" {
    const bytes = try buildBank();
    defer a.free(bytes);
    try runClaim(bytes, .resume_after_release);
}
test "default live Host Close during typed initial Worker defer retains custody until joins" {
    const bytes = try buildBank();
    defer a.free(bytes);
    try runClaim(bytes, .close_while_deferred);
}
test "default live Host initial defer does not swallow later actual provider retirement error" {
    const bytes = try buildBank();
    defer a.free(bytes);
    try runClaim(bytes, .later_provider_error);
}
