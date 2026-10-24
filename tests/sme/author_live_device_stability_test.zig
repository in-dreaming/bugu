//! Explicitly opted-in ordinary-Host stability exercise. No semantic session,
//! Recorder, replay driver, manual Render, source substitution, or clock hook.
//! The real source compiler/decoder consumes the fixture's 16 generated WAVs.
//! Hardware is NEVER selected by default. System mode requires external plan
//! approval as well as the explicit environment below; a cloud null run is not
//! Windows, physical-device, speaker-acoustic, or OS-underrun evidence.
//!
//! Closed configuration (validated before bank construction/Host creation):
//! SME_DEVICE_STABILITY_MODE=system|null (absent => SkipZigTest)
//! SME_DEVICE_STABILITY_SECONDS=1..600 for system, 1..5 for null (required)
//! SME_DEVICE_STABILITY_CYCLES=1..4, <= seconds (optional, default 1)
//! SME_DEVICE_STABILITY_GAIN=0|0.01 (optional, default 0; final output safety)
//! Other SME_* variables are rejected when opted in. Duration is the sum of
//! monotonic active-Play targets, not rendered frames and not preparation time.
//! Play, Stop, Stop-tail, and Close each have a separate 20-second deadline.
//! The parser requires seconds + 80 * cycles <= 840, leaving 60 seconds of a
//! 900-second external watchdog for preparation and other overhead. This is a
//! configuration budget, not a bound on OS scheduling or blocking native calls.
//! SIGKILL cannot promise joined cleanup; failed cleanup retains its owners.
//! Multiple cycles mean genuine Stop -> Close/join/destroy -> NEW Host -> Play,
//! never transport pause/resume or a fabricated same-Host restart.
const std = @import("std");
const live = @import("sme-author-live-owner");
const f = @import("sme-stream-reload-fixture");
const t = std.testing;
const a = t.allocator;
const Backend = live.audio.RuntimeMiniaudioBackend;
const Safety = Backend.TestOutputSafety;
const ns_per_s = std.time.ns_per_s;
const command_deadline_ns = 20 * ns_per_s;
const heartbeat_deadline_ns = ns_per_s;
const poll_ms = 10;
const diagnostic_capacity = 610; // <=600 one-second observations +8 boundaries.
const supported_keys = [_][]const u8{
    "SME_DEVICE_STABILITY_MODE",   "SME_DEVICE_STABILITY_SECONDS",
    "SME_DEVICE_STABILITY_CYCLES", "SME_DEVICE_STABILITY_GAIN",
};

const Config = struct {
    mode: enum { system, null_backend },
    seconds: u16,
    cycles: u8 = 1,
    gain: f32 = 0,

    fn decimal(value: []const u8, maximum: u16) !u16 {
        if (value.len == 0 or value.len > 3 or value[0] == '0') return error.StabilityInvalidInteger;
        for (value) |byte| if (byte < '0' or byte > '9') return error.StabilityInvalidInteger;
        const number = std.fmt.parseInt(u16, value, 10) catch return error.StabilityInvalidInteger;
        if (number == 0 or number > maximum) return error.StabilityDurationOutOfBounds;
        return number;
    }
    fn parse(env: *const std.process.Environ.Map) !?Config {
        const mode_text = env.get(supported_keys[0]) orelse return null;
        for (env.keys()) |key| {
            if (key.len < 4 or !std.ascii.eqlIgnoreCase(key[0..4], "SME_")) continue;
            const supported = for (supported_keys) |known| {
                if (std.mem.eql(u8, key, known)) break true;
            } else false;
            if (!supported) return error.StabilityUnsupportedEnvironmentOption;
        }
        const mode: @FieldType(Config, "mode") = if (std.mem.eql(u8, mode_text, "system")) .system else if (std.mem.eql(u8, mode_text, "null")) .null_backend else return error.StabilityUnsupportedMode;
        const seconds = try decimal(env.get(supported_keys[1]) orelse return error.StabilityMissingDuration, if (mode == .system) 600 else 5);
        const cycles: u8 = if (env.get(supported_keys[2])) |value| @intCast(try decimal(value, 4)) else 1;
        if (cycles > seconds) return error.StabilityTooManyCycles;
        if (@as(u32, seconds) + 80 * @as(u32, cycles) > 840) return error.StabilityOuterBudgetExceeded;
        const gain: f32 = if (env.get(supported_keys[3])) |value| blk: {
            if (std.mem.eql(u8, value, "0")) break :blk 0;
            if (std.mem.eql(u8, value, "0.01")) break :blk 0.01;
            return error.StabilityUnsupportedGain;
        } else 0;
        return .{ .mode = mode, .seconds = seconds, .cycles = cycles, .gain = gain };
    }
    fn fromEnvironment() !?Config {
        var env = try std.process.Environ.createMap(t.environ, a);
        defer env.deinit();
        return parse(&env);
    }
    fn cycleTargetNs(self: Config, index: u8) u64 {
        const total = @as(u64, self.seconds) * ns_per_s;
        const base = total / self.cycles;
        return base + @as(u64, @intFromBool(index < total % self.cycles));
    }
};

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(t.io);
}
fn elapsed(start: std.Io.Timestamp, end: std.Io.Timestamp) !u64 {
    const duration = start.durationTo(end).nanoseconds;
    if (duration < 0 or duration > std.math.maxInt(u64)) return error.StabilityClockRegression;
    return @intCast(duration);
}
fn pause() !void {
    try std.Io.sleep(t.io, .fromMilliseconds(poll_ms), .awake);
}
fn buildBank() ![]u8 {
    const source = try std.mem.replaceOwned(u8, a, f.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer a.free(source);
    return f.buildSource(.a, source, null);
}
fn launch(bytes: []const u8) live.Launch {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.authored_source, &hash, .{});
    return .{ .document_id = 53, .revision = 1, .draft_hash = hash, .state = f.state, .compiled = bytes };
}

const Probe = struct {
    // Only Control installs/dereferences this; UI never accesses engine fields.
    owner: ?*f.music.MusicRuntime = null,
    stream_faults: std.atomic.Value(u64) = .init(0),
    control_observations: std.atomic.Value(u64) = .init(0),
    callbacks: std.atomic.Value(u64) = .init(0),
    samples: std.atomic.Value(u64) = .init(0),
    frames: std.atomic.Value(u64) = .init(0),
    callback_entries: std.atomic.Value(u64) = .init(0),
    callback_returns: std.atomic.Value(u64) = .init(0),
    callback_fallbacks: std.atomic.Value(u64) = .init(0),
    callback_error_code: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    counter_overflow: std.atomic.Value(bool) = .init(false),
    // Audio-owned scalars, read only after genuine device and thread joins.
    epoch: ?u64 = null,
    next_frame: ?u64 = null,
    discontinuities: u64 = 0,
    missing_frames: u64 = 0,
    backward_frames: u64 = 0,
    epoch_changes: u64 = 0,
    invalid_shape: bool = false,
    nonfinite_after: bool = false,

    // Each counter has exactly one writer; no callback retry loop or allocation.
    fn add(self: *Probe, counter: *std.atomic.Value(u64), amount: u64) void {
        const sum = @addWithOverflow(counter.load(.monotonic), amount);
        if (sum[1] != 0) {
            self.counter_overflow.store(true, .release);
            self.failed.store(true, .release);
            return;
        }
        counter.store(sum[0], .release);
    }
    fn install(raw: *anyopaque, owner: *f.music.MusicRuntime) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.owner = owner;
    }
    fn control(raw: *anyopaque, _: f.music.MusicRuntime.LiveControlTickOutcomeV1) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        const owner = self.owner orelse {
            self.failed.store(true, .release);
            return;
        };
        self.stream_faults.store(owner.stream_fault_count, .release);
        self.add(&self.control_observations, 1);
    }
    fn facts(raw: *anyopaque, event: Backend.TestCallbackEvent) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        switch (event) {
            .enter => self.add(&self.callback_entries, 1),
            .loss_acquired => |lost| if (lost) {
                self.failed.store(true, .release);
            },
            .returned => |value| {
                self.add(&self.callback_returns, 1);
                if (value.kind != .completed) {
                    self.add(&self.callback_fallbacks, 1);
                    self.failed.store(true, .release);
                }
                if (value.failure) |err| {
                    if (self.callback_error_code.load(.monotonic) == 0) self.callback_error_code.store(@intFromError(err), .release);
                    self.failed.store(true, .release);
                }
            },
        }
    }
    fn pcm(raw: *anyopaque, epoch: u64, first: u64, channels: u16, samples: []const f32) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (channels != 2 or samples.len % 2 != 0) {
            self.invalid_shape = true;
            self.failed.store(true, .release);
            return;
        }
        if (self.epoch) |previous| {
            if (previous != epoch) {
                self.epoch_changes +|= 1;
                self.next_frame = null;
                self.failed.store(true, .release);
            }
        }
        self.epoch = epoch;
        if (self.next_frame) |expected| {
            if (first != expected) {
                self.discontinuities +|= 1;
                if (first > expected) self.missing_frames +|= first - expected else self.backward_frames +|= expected - first;
                self.failed.store(true, .release);
            }
        } else if (first != 0) {
            self.discontinuities +|= 1;
            self.missing_frames +|= first;
            self.failed.store(true, .release);
        }
        const frame_count: u64 = @intCast(samples.len / 2);
        const next = @addWithOverflow(first, frame_count);
        if (next[1] != 0) {
            self.counter_overflow.store(true, .release);
            self.failed.store(true, .release);
        } else self.next_frame = next[0];
        for (samples) |sample| if (!std.math.isFinite(sample)) {
            self.nonfinite_after = true;
            self.failed.store(true, .release);
        };
        self.add(&self.samples, @intCast(samples.len));
        self.add(&self.frames, frame_count);
        self.add(&self.callbacks, 1); // release-published atomic heartbeat, no clock.
    }
};

const Heartbeat = struct {
    last_poll_ns: u64 = 0,
    last_progress_ns: u64 = 0,
    last_callbacks: u64 = 0,
    max_ui_poll_gap_ns: u64 = 0,
    max_ui_progress_gap_ns: u64 = 0,
    max_ui_no_progress_ns: u64 = 0,
    fn observe(self: *Heartbeat, time_ns: u64, callbacks: u64) !void {
        if (time_ns < self.last_poll_ns or callbacks < self.last_callbacks) return error.StabilityHeartbeatRegression;
        self.max_ui_poll_gap_ns = @max(self.max_ui_poll_gap_ns, time_ns - self.last_poll_ns);
        self.last_poll_ns = time_ns;
        if (callbacks != self.last_callbacks) {
            self.max_ui_progress_gap_ns = @max(self.max_ui_progress_gap_ns, time_ns - self.last_progress_ns);
            self.last_progress_ns = time_ns;
            self.last_callbacks = callbacks;
        } else {
            const quiet = time_ns - self.last_progress_ns;
            self.max_ui_no_progress_ns = @max(self.max_ui_no_progress_ns, quiet);
            if (quiet >= heartbeat_deadline_ns) return error.StabilityCallbackHeartbeatStalled;
        }
    }
};

const Diagnostic = struct {
    cycle: u8,
    active_ns: u64,
    status_present: bool,
    phase: live.Phase,
    callback_count: u64,
    sample_count: u64,
    frame_count: u64,
    stream_faults: u64,
    worker_calls: u64,
    lost_count: u64,
    skipped_status: u64,
    ui_poll_gap_ns: u64,
    ui_progress_gap_ns: u64,
};
const Diagnostics = struct {
    rows: [diagnostic_capacity]Diagnostic = undefined,
    len: usize = 0,
    overflow: bool = false,
    fn append(self: *Diagnostics, row: Diagnostic) !void {
        if (self.len == self.rows.len) {
            self.overflow = true;
            return error.StabilityDiagnosticCapacity;
        }
        self.rows[self.len] = row;
        self.len += 1;
    }
    fn record(self: *Diagnostics, cycle: u8, active_ns: u64, status: ?live.Status, probe: *const Probe, heartbeat: Heartbeat) !void {
        try self.append(.{
            .cycle = cycle,
            .active_ns = active_ns,
            .status_present = status != null,
            .phase = if (status) |value| value.phase else .opening,
            .callback_count = probe.callbacks.load(.acquire),
            .sample_count = probe.samples.load(.acquire),
            .frame_count = probe.frames.load(.acquire),
            .stream_faults = probe.stream_faults.load(.acquire),
            .worker_calls = if (status) |value| value.worker_calls else 0,
            .lost_count = if (status) |value| value.lost_count else 0,
            .skipped_status = if (status) |value| value.skipped_status else 0,
            .ui_poll_gap_ns = heartbeat.max_ui_poll_gap_ns,
            .ui_progress_gap_ns = heartbeat.max_ui_progress_gap_ns,
        });
    }
    fn report(self: *const Diagnostics) void {
        std.debug.print("DEVICE_STABILITY_DIAGNOSTICS schema=1 retained={d} capacity={d} overflow={} ui_observations_only=true callback_clock_reads=false exact_callback_jitter=false os_underruns_available=false acoustic_validation=false\n", .{ self.len, self.rows.len, self.overflow });
        for (self.rows[0..self.len]) |row| std.debug.print("DEVICE_STABILITY_SAMPLE schema=1 cycle={d} active_ns={d} status_present={} phase={s} callbacks={d} samples={d} frames={d} stream_faults={d} worker_calls={d} lost={d} skipped_status={d} ui_poll_gap_ns={d} ui_progress_gap_ns={d}\n", .{ row.cycle, row.active_ns, row.status_present, @tagName(row.phase), row.callback_count, row.sample_count, row.frame_count, row.stream_faults, row.worker_calls, row.lost_count, row.skipped_status, row.ui_poll_gap_ns, row.ui_progress_gap_ns });
    }
};

const Receipts = struct {
    ids: [2]u64 = @splat(0),
    accepted: [2]bool = @splat(false),
    terminal: [2]?f.music.MusicRuntimeReceiptV1 = @splat(null),
    acknowledgements: u8 = 0,
    fn collect(self: *Receipts, host: *live.Host) !void {
        while (host.popEvent()) |event| {
            if (event.kind == .terminal) {
                try host.acknowledgeTerminal(event.command.id);
                self.acknowledgements += 1;
            }
            const index: usize = for (self.ids, 0..) |id, i| {
                if (id != 0 and id == event.command.id) break i;
            } else return error.StabilityForeignCommand;
            if (!std.meta.eql(host.identity(), event.command.identity)) return error.StabilityReceiptIdentity;
            switch (event.kind) {
                .accepted => {
                    if (self.accepted[index] or self.terminal[index] != null) return error.StabilityDuplicateReceipt;
                    self.accepted[index] = true;
                },
                .terminal => {
                    if (self.terminal[index] != null) return error.StabilityDuplicateReceipt;
                    const receipt = event.receipt orelse return error.StabilityMissingReceipt;
                    if (event.terminal != .executed or receipt.event != .terminal or receipt.event.terminal != .executed or receipt.event.terminal.executed.outcome != .executed) return error.StabilityCommandNotExecuted;
                    self.terminal[index] = receipt;
                },
            }
        }
    }
};

fn healthy(host: *live.Host, probe: *const Probe) !?live.Status {
    const status = if (host.readStatus()) |value| value.value else null;
    if (status) |value| {
        if (value.first_error) |err| {
            std.debug.print("DEVICE_STABILITY_NATIVE_ERROR error={s} site={s} render_frame={d} callbacks={d} control_tick={d}\n", .{ @errorName(err), @tagName(value.first_error_site), value.error_render_frame, value.error_callback_count, value.error_control_tick });
            return err;
        }
        if (value.lost_count != 0 or value.reopen_count != 0 or value.loss_observed or value.loss_accepted) return error.StabilityUnexpectedDeviceLoss;
    }
    if (probe.stream_faults.load(.acquire) != 0) return error.StabilityStreamFault;
    if (probe.counter_overflow.load(.acquire)) return error.StabilityCounterOverflow;
    if (probe.failed.load(.acquire)) return error.StabilityCallbackObservationFailed;
    if (host.isClosed()) return error.StabilityUnexpectedClosed;
    return status;
}
fn awaitCommand(host: *live.Host, probe: *const Probe, receipts: *Receipts, index: usize) !u64 {
    const began = now();
    while (true) {
        try receipts.collect(host);
        _ = try healthy(host, probe);
        // A terminal received after a delayed wake cannot turn an expired
        // command into success, even if native execution happened earlier.
        if (try elapsed(began, now()) >= command_deadline_ns) return error.StabilityCommandTimedOut;
        if (receipts.terminal[index]) |receipt| {
            if (!receipts.accepted[index]) return error.StabilityMissingAcceptance;
            return receipt.event.terminal.executed.effective_frame;
        }
        try pause();
    }
}
fn drainTerminals(host: *live.Host) !void {
    while (host.popEvent()) |event| if (event.kind == .terminal) try host.acknowledgeTerminal(event.command.id);
}
fn closeActual(host: *live.Host) !live.Status {
    // Cancellation initiates cleanup rather than skipping actual close/join.
    const previous = t.io.swapCancelProtection(.blocked);
    defer _ = t.io.swapCancelProtection(previous);
    try host.requestClose(host.identity().epoch);
    const began = now();
    while (true) {
        try drainTerminals(host);
        if (host.isClosed()) {
            host.join() catch |err| switch (err) {
                error.CleanupPending => {
                    if (try elapsed(began, now()) >= command_deadline_ns) return error.StabilityJoinTimedOut;
                    try pause();
                    continue;
                },
                else => return err,
            };
            const status = (host.readStatus() orelse return error.StabilityMissingClosedStatus).value;
            try drainTerminals(host);
            // Check before transferring final custody/freeing Host. An expired
            // successful join remains safely retryable by error cleanup; never
            // throw a new timeout after destroy and leave a dangling errdefer.
            if (try elapsed(began, now()) >= command_deadline_ns) return error.StabilityCloseTimedOut;
            try host.acknowledgeClosed();
            try host.destroy();
            return status;
        }
        if (try elapsed(began, now()) >= command_deadline_ns) return error.StabilityCloseTimedOut;
        try pause();
    }
}

const Owned = struct { memory: live.TestAllocator = .init, probe: Probe = .{}, safety: Safety };
fn reportClosed(cycle: u8, status: live.Status, owned: *const Owned, active_ns: u64, heartbeat: Heartbeat) void {
    const stats = owned.safety.stats; // Caller has actually destroyed Host.
    const probe = &owned.probe;
    std.debug.print("DEVICE_STABILITY_CLOSED schema=1 cycle={d} active_ns={d} phase={s} worker_joined={} play_executed={} stop_executed={} first_error_present={} first_error={s} first_error_site={s} cleanup_error_present={} cleanup_error={s} provider_opened={d} provider_closed={d} provider_live={d} provider_reads={d} sample_leases={d} live_instances={d} host_callbacks={d} worker_calls={d} lost={d} reopened={d}\n", .{ cycle, active_ns, @tagName(status.phase), status.worker_joined, status.play_executed, status.stop_executed, status.first_error != null, if (status.first_error) |err| @errorName(err) else "none", @tagName(status.first_error_site), status.cleanup_error != null, if (status.cleanup_error) |err| @errorName(err) else "none", status.provider.opened, status.provider.closed, status.provider.live, status.provider.read_attempts, status.sample_leases, status.live_instances, status.callback_sequence, status.worker_calls, status.lost_count, status.reopen_count });
    std.debug.print("DEVICE_STABILITY_OUTPUT schema=1 cycle={d} final_callbacks={d} final_samples={d} peak_before={d} peak_after={d} finite_nonzero_before={d} nonfinite={d} clamped={d} no_output={d} invalid_buffer={d} fallback={d} pcm_callbacks={d} pcm_frames={d} callback_entries={d} callback_returns={d} callback_error_code={d} discontinuities={d} missing_frames={d} backward_frames={d} epoch_changes={d} invalid_shape={} nonfinite_after={} counter_overflow={} control_observations={d} stream_faults={d} ui_poll_gap_ns={d} ui_progress_gap_ns={d} ui_no_progress_ns={d}\n", .{ cycle, stats.callback_count, stats.sample_count, stats.peak_before, stats.peak_after, stats.nonzero_before_count, stats.nonfinite_count, stats.clamped_count, stats.no_output_count, stats.invalid_buffer_count, stats.fallback_count, probe.callbacks.load(.acquire), probe.frames.load(.acquire), probe.callback_entries.load(.acquire), probe.callback_returns.load(.acquire), probe.callback_error_code.load(.acquire), probe.discontinuities, probe.missing_frames, probe.backward_frames, probe.epoch_changes, probe.invalid_shape, probe.nonfinite_after, probe.counter_overflow.load(.acquire), probe.control_observations.load(.acquire), probe.stream_faults.load(.acquire), heartbeat.max_ui_poll_gap_ns, heartbeat.max_ui_progress_gap_ns, heartbeat.max_ui_no_progress_ns });
    if (status.output) |output| std.debug.print("DEVICE_STABILITY_NEGOTIATED schema=1 cycle={d} output_present=true requested_sample_rate=48000 native_channels={d} callback_channels={d} backend={s} reason={s}\n", .{ cycle, output.record.negotiated.layout.count, output.record.callback.layout.count, @tagName(output.record.backend), @tagName(output.record.reason) }) else std.debug.print("DEVICE_STABILITY_NEGOTIATED schema=1 cycle={d} output_present=false\n", .{cycle});
}

fn runCycle(config: Config, cycle: u8, bytes: []const u8, diagnostics: *Diagnostics) !u64 {
    const safety = try Safety.init(.{ .gain = config.gain });
    const owned = try a.create(Owned);
    owned.* = .{ .safety = safety };
    var safe_to_free = true;
    defer if (safe_to_free) {
        if (owned.memory.deinit() != .ok) @panic("device stability native allocations remain after genuine join");
        a.destroy(owned);
    };
    const host = try live.Host.createWithTestAllocator(&owned.memory, launch(bytes), .{
        .io = t.io,
        .device = .{ .backend = if (config.mode == .system) .system else .null_backend },
        .semantic = null,
        .test_capture = null,
        .test_output_safety = &owned.safety,
        .test_setup = .{ .context = &owned.probe, .call = Probe.install },
        .test_tick_outcome = .{ .context = &owned.probe, .call = Probe.control },
        .test_pcm = .{ .context = &owned.probe, .call = Probe.pcm },
        .test_callback_facts = .{ .context = &owned.probe, .call = Probe.facts },
    });
    var alive = true;
    var active_ns: u64 = 0;
    var heartbeat: Heartbeat = .{};
    errdefer if (alive) {
        if (closeActual(host)) |closed| {
            alive = false;
            reportClosed(cycle, closed, owned, active_ns, heartbeat);
            std.debug.print("DEVICE_STABILITY_FAILURE_CLEANUP schema=1 cycle={d} joined_destroyed=true resource_cleanup_verified={} retained=false\n", .{ cycle, closed.phase == .closed and closed.worker_joined and closed.cleanup_error == null and closed.provider.opened == closed.provider.closed and closed.provider.live == 0 and closed.sample_leases == 0 and closed.live_instances == 0 });
        } else |err| {
            safe_to_free = false;
            // Retain Host allocator + both borrowed observer contexts. Never
            // fabricate provider/lease zeroes or read callback-owned live stats.
            std.debug.print("DEVICE_STABILITY_FAILURE_CLEANUP schema=1 cycle={d} joined_destroyed=false resource_cleanup_verified=false retained=true control_joined={} error={s} final_counts_available=false\n", .{ cycle, host.joined, @errorName(err) });
        }
    };
    try t.expectEqual(live.PacingMode.notified_v1, host.pacingMode());
    try t.expect(host.options.semantic == null and host.options.test_capture == null and host.options.test_after_live_acceptance == null and host.options.test_wait_observer == null and host.options.test_retry_workload == null);
    var receipts: Receipts = .{};
    receipts.ids[0] = (try host.submit(host.identity(), .play)).id;
    const play_frame = try awaitCommand(host, &owned.probe, &receipts, 0);
    const active_start = now();
    const target_ns = config.cycleTargetNs(cycle);
    heartbeat.last_callbacks = owned.probe.callbacks.load(.acquire);
    var last_status = try healthy(host, &owned.probe);
    try diagnostics.record(cycle, 0, last_status, &owned.probe, heartbeat);
    var next_diagnostic_ns: u64 = ns_per_s;
    while (true) {
        try receipts.collect(host);
        last_status = try healthy(host, &owned.probe);
        active_ns = try elapsed(active_start, now());
        try heartbeat.observe(active_ns, owned.probe.callbacks.load(.acquire));
        if (active_ns >= target_ns) break;
        if (active_ns >= next_diagnostic_ns) {
            try diagnostics.record(cycle, active_ns, last_status, &owned.probe, heartbeat);
            // One row per UI observation, never a catch-up burst after a stall.
            next_diagnostic_ns = (active_ns / ns_per_s + 1) * ns_per_s;
        }
        try pause();
    }
    try diagnostics.record(cycle, active_ns, last_status, &owned.probe, heartbeat);
    receipts.ids[1] = (try host.submit(host.identity(), .stop)).id;
    const stop_frame = try awaitCommand(host, &owned.probe, &receipts, 1);
    // Receipt is Stop onset. Observe the genuine callback-delivered ramp and
    // some following silence before Close, without retaining any PCM samples.
    const stop_began = now();
    const tail_end = std.math.add(u64, stop_frame, f.rt.scheduler.default_profile.emergency_ramp_frames + 1) catch return error.StabilityFrameOverflow;
    while (owned.probe.frames.load(.acquire) < tail_end) {
        try receipts.collect(host);
        _ = try healthy(host, &owned.probe);
        if (try elapsed(stop_began, now()) >= command_deadline_ns) return error.StabilityStopTailTimedOut;
        try pause();
    }
    if (try elapsed(stop_began, now()) >= command_deadline_ns) return error.StabilityStopTailTimedOut;
    const closed = try closeActual(host);
    alive = false;
    reportClosed(cycle, closed, owned, active_ns, heartbeat);
    const stats = owned.safety.stats;
    try t.expectEqual(.closed, closed.phase);
    try t.expect(closed.first_error == null and closed.cleanup_error == null and closed.worker_joined);
    try t.expect(closed.play_executed and closed.stop_executed and closed.callback_sequence > 0 and closed.worker_calls > 0);
    try t.expect(closed.control_thread_id != 0 and closed.worker_thread_id != 0 and closed.control_thread_id != closed.worker_thread_id);
    try t.expectEqual(@as(usize, 16), closed.provider.opened);
    try t.expectEqual(closed.provider.opened, closed.provider.closed);
    try t.expect(closed.provider.read_attempts > 0);
    try t.expectEqual(@as(usize, 0), closed.provider.live);
    try t.expectEqual(@as(u64, 0), closed.sample_leases);
    try t.expectEqual(@as(u64, 0), closed.live_instances);
    try t.expectEqual(@as(u64, 0), closed.lost_count);
    try t.expectEqual(@as(u64, 0), closed.reopen_count);
    try t.expectEqual(@as(u8, 2), receipts.acknowledgements);
    const output = closed.output orelse return error.StabilityMissingNegotiatedOutput;
    const expected_backend: @FieldType(live.audio.device.NegotiationRecord, "backend") = if (config.mode == .system) .system else .null_backend;
    try t.expectEqual(expected_backend, output.record.backend);
    const layouts = live.audio.device.channel_layout;
    try t.expect(layouts.ChannelLayout.eql(layouts.stereo, output.record.requested));
    try t.expect(layouts.ChannelLayout.eql(layouts.stereo, output.record.target));
    try t.expect(layouts.ChannelLayout.eql(layouts.stereo, output.record.callback.layout));
    try t.expect(layouts.ChannelLayout.eql(layouts.stereo, output.record.negotiated.layout));
    try t.expect(stop_frame > play_frame and active_ns >= target_ns);
    try t.expect(stats.callback_count > 0 and stats.sample_count > 0 and stats.peak_before > 0 and stats.nonzero_before_count > 0);
    try t.expect(stats.peak_after <= config.gain);
    try t.expectEqual(@as(u64, 0), stats.nonfinite_count);
    try t.expectEqual(@as(u64, 0), stats.clamped_count);
    try t.expectEqual(@as(u64, 0), stats.no_output_count);
    try t.expectEqual(@as(u64, 0), stats.invalid_buffer_count);
    try t.expectEqual(@as(u64, 0), stats.fallback_count);
    try t.expectEqual(stats.callback_count, owned.probe.callbacks.load(.acquire));
    try t.expectEqual(stats.sample_count, owned.probe.samples.load(.acquire));
    try t.expectEqual(stats.callback_count, owned.probe.callback_entries.load(.acquire));
    try t.expectEqual(stats.callback_count, owned.probe.callback_returns.load(.acquire));
    try t.expect(!owned.probe.failed.load(.acquire));
    try t.expect(owned.probe.control_observations.load(.acquire) > 0);
    try t.expectEqual(@as(u64, 0), owned.probe.stream_faults.load(.acquire));
    return active_ns;
}

test "device stability requires explicit bounded opt in and exercises real ordinary Host lifecycle" {
    const config = (try Config.fromEnvironment()) orelse return error.SkipZigTest;
    const resolution = try std.Io.Clock.awake.resolution(t.io);
    if (resolution.nanoseconds <= 0) return error.StabilityClockUnavailable;
    std.debug.print("DEVICE_STABILITY_CONFIG schema=1 mode={s} target_active_seconds={d} cycles={d} final_output_gain={d} muted={} poll_ms={d} diagnostic_interval_ms=1000 outer_watchdog_required_seconds=900 semantic=false recorder=false callback_clock_hook=false lifecycle_cycles_not_pause_resume=true system_selection=default_output no_microphone=true no_pcm_retention=true no_volume_changes=true\n", .{ @tagName(config.mode), config.seconds, config.cycles, config.gain, config.gain == 0, poll_ms });
    const bytes = try buildBank();
    defer a.free(bytes);
    var diagnostics: Diagnostics = .{};
    defer diagnostics.report();
    const whole_start = now();
    var active_ns: u64 = 0;
    for (0..config.cycles) |cycle| active_ns += try runCycle(config, @intCast(cycle), bytes, &diagnostics);
    const wall_ns = try elapsed(whole_start, now());
    try t.expect(active_ns >= @as(u64, config.seconds) * ns_per_s);
    std.debug.print("DEVICE_STABILITY_COMPLETE schema=1 mode={s} cycles={d} target_active_seconds={d} measured_active_ns={d} host_lifecycle_wall_ns={d} source_preparation_excluded=true all_hosts_destroyed=true\n", .{ @tagName(config.mode), config.cycles, config.seconds, active_ns, wall_ns });
}

test "device stability configuration skips without mode and rejects unknown options before owners" {
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try t.expect((try Config.parse(&env)) == null);
    try env.put(supported_keys[0], "null");
    try t.expectError(error.StabilityMissingDuration, Config.parse(&env));
    try env.put(supported_keys[1], "2");
    const config = (try Config.parse(&env)).?;
    try t.expectEqual(@as(f32, 0), config.gain);
    try t.expectEqual(@as(u8, 1), config.cycles);
    for ([_][]const u8{ "", "NULL", "default", "wasapi", "system ", "capture" }) |bad| {
        try env.put(supported_keys[0], bad);
        try t.expectError(error.StabilityUnsupportedMode, Config.parse(&env));
    }
    try env.put(supported_keys[0], "system");
    for ([_][]const u8{ "SME_DEFAULT_CONTROL_DELAY_MS", "SME_DEFAULT_WORKER_DELAY_MS", "SME_DEVICE_STABILITY_CAPTURE", "SME_SEMANTIC_REPLAY", "sme_device_stability_unrecognized" }) |unknown| {
        try env.put(unknown, "0");
        try t.expectError(error.StabilityUnsupportedEnvironmentOption, Config.parse(&env));
        _ = env.swapRemove(unknown);
    }
}

test "device stability configuration has closed duration cycles and output gain bounds" {
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put(supported_keys[0], "system");
    for ([_][]const u8{ "", "0", "01", "+1", "-1", "1.0", " 1", "1 ", "1000", "nan" }) |bad| {
        try env.put(supported_keys[1], bad);
        try t.expectError(error.StabilityInvalidInteger, Config.parse(&env));
    }
    try env.put(supported_keys[1], "601");
    try t.expectError(error.StabilityDurationOutOfBounds, Config.parse(&env));
    try env.put(supported_keys[1], "600");
    try env.put(supported_keys[2], "4");
    try t.expectError(error.StabilityOuterBudgetExceeded, Config.parse(&env));
    try env.put(supported_keys[2], "3");
    const maximum = (try Config.parse(&env)).?;
    var total: u64 = 0;
    for (0..maximum.cycles) |i| total += maximum.cycleTargetNs(@intCast(i));
    try t.expectEqual(@as(u64, 600 * ns_per_s), total);
    try env.put(supported_keys[1], "520");
    try env.put(supported_keys[2], "4");
    try t.expectEqual(@as(u8, 4), (try Config.parse(&env)).?.cycles);
    try env.put(supported_keys[1], "521");
    try t.expectError(error.StabilityOuterBudgetExceeded, Config.parse(&env));
    try env.put(supported_keys[2], "5");
    try t.expectError(error.StabilityDurationOutOfBounds, Config.parse(&env));
    try env.put(supported_keys[0], "null");
    try env.put(supported_keys[1], "6");
    try t.expectError(error.StabilityDurationOutOfBounds, Config.parse(&env));
    try env.put(supported_keys[1], "2");
    try env.put(supported_keys[2], "3");
    try t.expectError(error.StabilityTooManyCycles, Config.parse(&env));
    try env.put(supported_keys[2], "2");
    for ([_][]const u8{ "0.1", "1", "-0.01", "0.010", "nan", "inf", "", "0.005" }) |bad| {
        try env.put(supported_keys[3], bad);
        try t.expectError(error.StabilityUnsupportedGain, Config.parse(&env));
    }
    try env.put(supported_keys[3], "0.01");
    try t.expectEqual(@as(f32, 0.01), (try Config.parse(&env)).?.gain);
    try env.put(supported_keys[3], "0");
    try t.expectEqual(@as(f32, 0), (try Config.parse(&env)).?.gain);
}

test "device stability final output safety mutes sanitizes and bounds detached output only" {
    var muted = try Safety.init(.{});
    var muted_samples = [_]f32{ 0, -0.5, 0.5, 1000, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    muted.apply(&muted_samples);
    for (muted_samples) |sample| try t.expectEqual(@as(f32, 0), sample);
    try t.expectEqual(@as(u64, 1), muted.stats.callback_count);
    try t.expectEqual(@as(u64, muted_samples.len), muted.stats.sample_count);
    try t.expectEqual(@as(u64, 3), muted.stats.nonfinite_count);
    try t.expectEqual(@as(f32, 0), muted.stats.peak_after);
    var bounded = try Safety.init(.{ .gain = 0.01 });
    var bounded_samples = [_]f32{ -1000, -1, -0.5, 0, 0.5, 1, 1000 };
    bounded.apply(&bounded_samples);
    for (bounded_samples) |sample| try t.expect(std.math.isFinite(sample) and @abs(sample) <= 0.01);
    try t.expectEqual(@as(f32, -0.005), bounded_samples[2]);
    try t.expectEqual(@as(f32, 0.005), bounded_samples[4]);
    try t.expectEqual(@as(u64, 2), bounded.stats.clamped_count);
    for ([_]f32{ -0.01, 0.01001, 1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |bad| {
        if (Safety.init(.{ .gain = bad })) |_| return error.StabilityInvalidSafetyGainAccepted else |_| {}
    }
}

test "device stability callback counters retain first discontinuity and fail overflow" {
    var probe: Probe = .{};
    const samples = [_]f32{ 0, 0, 0, 0 };
    Probe.pcm(&probe, 1, 0, 2, &samples);
    Probe.pcm(&probe, 1, 2, 2, &samples);
    try t.expectEqual(@as(u64, 2), probe.callbacks.load(.acquire));
    try t.expectEqual(@as(u64, 4), probe.frames.load(.acquire));
    try t.expectEqual(@as(u64, 0), probe.discontinuities);
    Probe.pcm(&probe, 1, 7, 2, &samples);
    try t.expectEqual(@as(u64, 1), probe.discontinuities);
    try t.expectEqual(@as(u64, 3), probe.missing_frames);
    try t.expect(probe.failed.load(.acquire));
    probe.samples.store(std.math.maxInt(u64), .release);
    Probe.pcm(&probe, 1, 9, 2, &samples);
    try t.expect(probe.counter_overflow.load(.acquire));
    try t.expectEqual(std.math.maxInt(u64), probe.samples.load(.acquire));
}

test "device stability heartbeat distinguishes UI polling gaps from unchanged callback progress" {
    var heartbeat: Heartbeat = .{};
    try heartbeat.observe(10 * std.time.ns_per_ms, 1);
    try heartbeat.observe(20 * std.time.ns_per_ms, 2);
    // A delayed UI poll with callback progress is not an audio-stall verdict.
    try heartbeat.observe(2 * ns_per_s, 100);
    try t.expectEqual(@as(u64, 1980 * std.time.ns_per_ms), heartbeat.max_ui_poll_gap_ns);
    try t.expectEqual(@as(u64, 0), heartbeat.max_ui_no_progress_ns);
    try t.expectError(error.StabilityCallbackHeartbeatStalled, heartbeat.observe(3 * ns_per_s, 100));
    try t.expectError(error.StabilityHeartbeatRegression, heartbeat.observe(2 * ns_per_s, 100));
}

test "device stability diagnostic capacity is fixed and overflow is a failure not truncation" {
    var diagnostics: Diagnostics = .{};
    const probe: Probe = .{};
    for (0..diagnostic_capacity) |i| try diagnostics.record(0, i, null, &probe, .{});
    try t.expectError(error.StabilityDiagnosticCapacity, diagnostics.record(0, diagnostic_capacity, null, &probe, .{}));
    try t.expectEqual(@as(usize, diagnostic_capacity), diagnostics.len);
    try t.expect(diagnostics.overflow);
    try t.expect(!diagnostics.rows[0].status_present);
    try t.expectEqual(@as(u64, diagnostic_capacity - 1), diagnostics.rows[diagnostic_capacity - 1].active_ns);
}

test "device stability guard and callback facts reject capture and invalid gain before bank admission" {
    var safety = try Safety.init(.{});
    var probe: Probe = .{};
    var session: live.semantic.Session = .{};
    // Intentionally uninitialized: Host must reject the incompatible observer
    // before touching the capture context or parsing this empty compiled bank.
    const capture = try a.create(live.TestCapture.Session);
    defer a.destroy(capture);
    const facts: Backend.TestCallbackFacts = .{ .context = &probe, .call = Probe.facts };
    inline for (.{ @as(@FieldType(live.semantic.Session, "mode"), .capture), @as(@FieldType(live.semantic.Session, "mode"), .replay) }) |mode| {
        session.mode = mode;
        try t.expectError(error.InvalidState, live.Host.create(launch(&.{}), .{ .io = t.io, .device = .{ .backend = .null_backend }, .semantic = &session, .test_output_safety = &safety }));
        try t.expectError(error.InvalidState, live.Host.create(launch(&.{}), .{ .io = t.io, .device = .{ .backend = .null_backend }, .semantic = &session, .test_callback_facts = facts }));
    }
    try t.expectError(error.InvalidState, live.Host.create(launch(&.{}), .{ .io = t.io, .device = .{ .backend = .null_backend }, .test_capture = capture, .test_output_safety = &safety }));
    try t.expectError(error.InvalidState, live.Host.create(launch(&.{}), .{ .io = t.io, .device = .{ .backend = .null_backend }, .test_capture = capture, .test_callback_facts = facts }));
    // Detached corruption is a negative preflight test, not a live gain change.
    safety.config.gain = 0.1;
    try t.expectError(error.InvalidArgument, live.Host.create(launch(&.{}), .{ .io = t.io, .device = .{ .backend = .null_backend }, .test_output_safety = &safety }));
    try t.expectEqual(@as(u64, 0), safety.stats.callback_count);
    try t.expectEqual(@as(u64, 0), probe.callback_entries.load(.acquire));
}

test "device stability disabled safety path preserves exact output bits" {
    try Backend.DriverTest.checkOutputSafetyDisabled();
}

test "device stability fallback initializes valid output and rejects unknown buffer shape" {
    try Backend.DriverTest.checkOutputSafetyFallback();
}

test "device stability safety binding rejects invalid startup and rebinding" {
    try Backend.DriverTest.checkOutputSafetyBinding();
}

test "device stability native callback safety covers no output missing negotiation and render failure" {
    try Backend.DriverTest.checkOutputSafetyNativeCallbacks();
}
