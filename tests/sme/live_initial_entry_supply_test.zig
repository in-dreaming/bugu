//! Actual cold-entry supply frame mismatch after four real admitted prefixes.
//! Controlled offline causal regression, not a Windows scheduling claim.
const std = @import("std");
const f = @import("sme-stream-reload-fixture");
const source = @import("sme-author-preview-v1").source;
const stream = @import("sme-streaming").stream;
const t = std.testing;
const a = t.allocator;

const Rig = struct {
    engine: *f.Rig,
    provider: *source.Provider,
    fn create(bytes: []const u8) !Rig {
        const provider = try source.Provider.create(a, bytes, .{});
        errdefer provider.destroy() catch @panic("provider retained");
        const engine = try f.Rig.createWithConfig(.{ .kind = .authoring, .control_driver = .integrated, .quantum_frames = 256 });
        errdefer engine.finish() catch @panic("owner retained");
        try engine.enableWorkerThread();
        const ticket = try engine.run.owner.loadBankWithSources(bytes, provider.provider());
        for (0..128) |_| {
            _ = try engine.workerOne();
            switch (try engine.run.owner.pollLoad(ticket)) {
                .pending => {},
                .failed => return error.LoadFailed,
                .ready => |loaded| {
                    engine.run.bank = loaded.bank;
                    try engine.run.owner.acknowledgeLoad(ticket);
                    return .{ .engine = engine, .provider = provider };
                },
            }
        }
        return error.LoadDidNotFinish;
    }
    fn finish(self: Rig, alive: *bool) !void {
        try self.engine.finishChronology();
        alive.* = false; // Owner/Worker are gone even if provider destruction fails.
        std.debug.print("ENTRY_SUPPLY_CLEANUP worker_joined=true sample_leases=0 live_instances=0 provider_opened={d} provider_closed={d} provider_live={d}\n", .{ self.provider.counts.opened, self.provider.counts.closed, self.provider.counts.live });
        try self.provider.destroy();
    }
};
fn bank() ![]u8 {
    const text = try std.mem.replaceOwned(u8, a, f.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer a.free(text);
    return f.buildSource(.a, text, null);
}

const Probe = struct {
    owner: *f.music.MusicRuntime,
    renderer: *f.runtime.audio.RuntimeRenderer,
    request_id: u64,
    enabled: bool = true,
    failure: ?anyerror = null,
    count: usize = 0,
    records: [4]struct { requested: u64, rendered: u64, handles: [4]stream.Handle, acknowledged: [4]u64 } = undefined,

    fn hook(raw: *anyopaque, stage: f.music.MusicRuntime.TickStage) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (stage != .before_stream_supply or !self.enabled or self.count == self.records.len or self.failure != null) return;
        self.advanceIfReady() catch |err| {
            self.failure = err;
        };
    }
    fn advanceIfReady(self: *Probe) !void {
        const generation = self.owner.generation orelse return error.MissingGeneration;
        const service = generation.service orelse return error.MissingService;
        if (self.owner.active_group != null) return;
        var handles: [4]stream.Handle = undefined;
        var prefixes: [4]u64 = undefined;
        var count: usize = 0;
        var coordinate: ?struct { segment: u64, cue: u64, occurrence: u16 } = null;
        // These windows and receipt-derived prefixes belong to this Control.
        // Do not call entryBindings: it writes the runtime's scratch array.
        for (generation.windows) |item| if (item) |window| {
            if (window.retiring or window.scope != .request or window.request_id != self.request_id or window.binding.cue == 0) continue;
            if (window.group != null) return error.UnexpectedBoundEntry;
            if (count == handles.len) return error.TooManyEntryBindings;
            const binding = window.binding;
            if (coordinate) |value| {
                if (value.segment != binding.segment or value.cue != binding.cue or value.occurrence != binding.occurrence) return error.MixedEntryCoordinates;
            } else coordinate = .{ .segment = binding.segment, .cue = binding.cue, .occurrence = binding.occurrence };
            for (handles[0..count]) |previous| if (std.meta.eql(previous, binding.handle)) return error.DuplicateEntryHandle;
            handles[count] = binding.handle;
            prefixes[count] = try service.acknowledgedVisiblePrefix(binding.handle);
            count += 1;
        };
        if (count != 4) return;
        for (prefixes) |prefix| if (prefix < service.profile.high_frames) return;
        const requested = self.owner.control_frame;
        var pcm: [128]f32 = undefined;
        // Direct real DSP only, never the offline adapter's pre-generated quantum.
        self.renderer.render(&pcm, 64, 2);
        self.records[self.count] = .{ .requested = requested, .rendered = self.renderer.renderFrame(), .handles = handles, .acknowledged = prefixes };
        self.count += 1;
    }
};

test "chronology cold entry makes progress with actual admitted high water despite supply frame movement" {
    const bytes = try bank();
    defer a.free(bytes);
    var oracle = try f.Oracle.decode(bytes);
    defer oracle.deinit();
    const rig = try Rig.create(bytes);
    var alive = true;
    defer if (alive) rig.finish(&alive) catch @panic("entry fixture retained actual custody");
    const owner = rig.engine.run.owner;
    const renderer = rig.engine.run.renderer;
    const ticket = try owner.start(rig.engine.run.bank.?, f.state);
    var probe: Probe = .{ .owner = owner, .renderer = renderer, .request_id = ticket.request_id };
    owner.test_tick_hook = .{ .context = &probe, .call = Probe.hook };
    defer if (alive) {
        owner.test_tick_hook = null;
    };
    var entry_defers: usize = 0;
    var play_frame: ?u64 = null;
    var terminal_count: usize = 0;
    var rejected = false;
    var shape_ok = true;
    var background_progress_ok = true;
    var background_defers: usize = 0;
    var loop_end: enum { exhausted, probe_failure, intervention_limit, terminal } = .exhausted;
    // Natural Play/Control/Worker/Render supply until real receipt prefixes arm
    // the one existing hook. No direct Service requests or invented readiness.
    for (0..512) |_| {
        const before = probe.count;
        const outcome = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        if (probe.count != before) {
            const record = probe.records[before];
            if (outcome.deferred) |deferred| {
                if (deferred.stage == .entry_supply) entry_defers += 1;
                std.debug.print("ENTRY_SUPPLY_BASELINE attempt={d} stage={s} reason={s} requested={?d} observed={?d} hook_requested={d} actual_rendered={d} active={}\n", .{ before, @tagName(deferred.stage), @tagName(deferred.observation.reason), deferred.observation.requested_frame, deferred.observation.observed_frame, record.requested, record.rendered, owner.active_group != null });
                const matching_cut = deferred.observation.reason == .frame_mismatch and deferred.observation.requested_frame == record.requested and deferred.observation.observed_frame == record.rendered;
                switch (deferred.stage) {
                    .entry_supply => shape_ok = shape_ok and matching_cut,
                    .background_supply => {
                        background_defers += 1;
                        // A later label alone is not progress: StreamNotReady
                        // can also fall through to background. Require the
                        // actual original request's published pending block.
                        const pending = owner.pending;
                        const original_pending = if (pending) |value| if (value.request_ticket) |actual| std.meta.eql(ticket, actual) else false else false;
                        const block_present = if (pending) |value| value.block.generation != 0 else false;
                        const preparation_finished = owner.preparing == null;
                        background_progress_ok = background_progress_ok and original_pending and block_present and preparation_finished;
                        shape_ok = shape_ok and matching_cut;
                        std.debug.print("ENTRY_SUPPLY_PUBLISHED_PENDING attempt={d} pending={} original_ticket={} block_present={} block_index={?d} block_generation={?d} preparing_null={}\n", .{ before, pending != null, original_pending, block_present, if (pending) |value| @as(?u16, value.block.index) else null, if (pending) |value| @as(?u64, value.block.generation) else null, preparation_finished });
                    },
                    else => shape_ok = false,
                }
            } else std.debug.print("ENTRY_SUPPLY_BASELINE attempt={d} defer=false requested={d} actual_rendered={d}\n", .{ before, record.requested, record.rendered });
            for (record.handles, record.acknowledged, 0..) |handle, prefix, i| std.debug.print("ENTRY_SUPPLY_PREFIX attempt={d} layer_index={d} slot={d} generation={d} acknowledged={d}\n", .{ before, i, handle.index, handle.generation, prefix });
        }
        while (try owner.pollReceiptV1()) |receipt| {
            if (!std.meta.eql(ticket, receipt.ticket)) return error.UnexpectedReceipt;
            if (receipt.event == .terminal) {
                terminal_count += 1;
                if (receipt.event.terminal == .executed) play_frame = receipt.event.terminal.executed.effective_frame else rejected = true;
            }
        }
        if (probe.count != before) std.debug.print("ENTRY_SUPPLY_TERMINAL attempt={d} count={d} executed={} rejected={}\n", .{ before, terminal_count, play_frame != null, rejected });
        if (probe.failure != null) {
            loop_end = .probe_failure;
            break;
        }
        if (terminal_count != 0) {
            loop_end = .terminal;
            break;
        }
        if (probe.count == 4) {
            loop_end = .intervention_limit;
            break;
        }
        try rig.engine.workers();
        var pcm: [128]f32 = undefined;
        renderer.render(&pcm, 64, 2);
    }
    // Record the decisive result BEFORE removing interference. Recovery after
    // disabling the hook remains useful cleanup evidence, not a repair oracle.
    const executed_while_enabled = probe.enabled and play_frame != null and !rejected;
    std.debug.print("ENTRY_SUPPLY_ENABLED_END reason={s} enabled={} interventions={d} terminal_count={d} executed={} rejected={} probe_failed={} background_defers={d} background_progress_ok={}\n", .{ @tagName(loop_end), probe.enabled, probe.count, terminal_count, executed_while_enabled, rejected, probe.failure != null, background_defers, background_progress_ok });
    // Always remove interference before proving recovery and real cleanup.
    probe.enabled = false;
    owner.test_tick_hook = null;
    for (0..512) |_| {
        if (play_frame != null or rejected) break;
        try rig.engine.workers();
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        var pcm: [128]f32 = undefined;
        renderer.render(&pcm, 64, 2);
        while (try owner.pollReceiptV1()) |receipt| {
            if (!std.meta.eql(ticket, receipt.ticket)) return error.UnexpectedReceipt;
            if (receipt.event == .terminal) {
                terminal_count += 1;
                if (receipt.event.terminal == .executed) play_frame = receipt.event.terminal.executed.effective_frame else rejected = true;
            }
        }
    }
    var pcm_evidence: f.Oracle.Evidence = .{};
    var pcm_failure: ?anyerror = null;
    if (play_frame) |start| {
        for (0..16) |_| {
            try rig.engine.workers();
            _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
            const first = renderer.renderFrame();
            var pcm: [128]f32 = undefined;
            renderer.render(&pcm, 64, 2);
            pcm_evidence.expectPcm(&oracle, first, start, &pcm) catch |err| {
                if (pcm_failure == null) pcm_failure = err;
            };
        }
    }
    const stop = try owner.submitV1(rig.engine.run.bank.?, .{ .stop = .emergency_ramp });
    var stopped = false;
    for (0..512) |_| {
        try rig.engine.workers();
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        var pcm: [128]f32 = undefined;
        renderer.render(&pcm, 64, 2);
        while (try owner.pollReceiptV1()) |receipt| {
            if (!std.meta.eql(stop, receipt.ticket)) return error.UnexpectedReceipt;
            if (receipt.event == .terminal and receipt.event.terminal == .executed) stopped = true;
        }
        if (stopped) break;
    }
    // Cleanup succeeds BEFORE the desired-progress assertion makes this known
    // bug red. Provider destruction validates actual source-close custody.
    try rig.finish(&alive);
    std.debug.print("ENTRY_SUPPLY_RESULT interventions={d} entry_defers={d} terminals={d} recovered={} stopped={} pcm_frames={d} nonzero={d} pcm_ok={} cleanup_complete=true\n", .{ probe.count, entry_defers, terminal_count, play_frame != null, stopped, pcm_evidence.frames, pcm_evidence.nonzero, pcm_failure == null });
    try t.expect(probe.failure == null);
    try t.expect(probe.count > 0);
    try t.expect(shape_ok and background_progress_ok);
    try t.expect(loop_end == .terminal and executed_while_enabled);
    try t.expectEqual(@as(usize, 1), terminal_count);
    try t.expect(play_frame != null and !rejected and stopped);
    try t.expect(pcm_failure == null and pcm_evidence.frames == 1024 and pcm_evidence.nonzero > 0);
    // Unchanged production is expected to report four real frame-mismatch
    // deferrals. Do NOT turn the known starvation behavior into a passing test.
    try t.expectEqual(@as(usize, 0), entry_defers);
}

// Observes real lifecycle states through the existing valid prepare Tick.
// Invalid arguments are detached query inputs, never engine-state mutations.
const EligibilityProbe = struct {
    owner: *f.music.MusicRuntime,
    request_id: u64,
    handle: ?stream.Handle = null,
    eligible_seen: bool = false,
    wrong_request_rejected: bool = false,
    stale_tick_rejected: bool = false,
    pending_seen: bool = false,
    active_seen: bool = false,
    executed_seen: bool = false,
    failure: bool = false,
    fn hook(raw: *anyopaque, stage: f.music.MusicRuntime.TickStage) void {
        const self: *EligibilityProbe = @ptrCast(@alignCast(raw));
        const scope = self.owner.tick_scope orelse return;
        if (stage == .before_stream_supply and !self.eligible_seen) {
            const generation = self.owner.generation orelse return;
            for (generation.windows) |item| if (item) |window| {
                if (window.retiring or window.scope != .request or window.request_id != self.request_id or window.binding.cue == 0) continue;
                self.handle = window.binding.handle;
                break;
            };
            const handle = self.handle orelse return;
            scope.validateInitialEntryV1(self.request_id, handle) catch {
                self.failure = true;
                return;
            };
            self.eligible_seen = true;
            if (scope.validateInitialEntryV1(self.request_id + 1, handle)) |_| {
                self.failure = true;
            } else |err| {
                self.wrong_request_rejected = err == error.InvalidState;
                if (!self.wrong_request_rejected) self.failure = true;
            }
            var stale = scope;
            stale.serial = 0;
            if (stale.validateInitialEntryV1(self.request_id, handle)) |_| {
                self.failure = true;
            } else |err| {
                self.stale_tick_rejected = err == error.InvalidState;
                if (!self.stale_tick_rejected) self.failure = true;
            }
        }
        if (stage == .before_background_supply) {
            const handle = self.handle orelse return;
            const pending = self.owner.pending != null;
            const active = self.owner.active_group != null;
            const executed = self.owner.has_executed;
            if (!pending and !active and !executed) return;
            // Distinguish lifecycle rejection from an invalid Tick/phase:
            // this exact native scope must still be a valid prepare capability.
            scope.requirePhase(.prepare) catch {
                self.failure = true;
                return;
            };
            self.pending_seen = self.pending_seen or pending;
            self.active_seen = self.active_seen or active;
            self.executed_seen = self.executed_seen or executed;
            if (scope.validateInitialEntryV1(self.request_id, handle)) |_| {
                self.failure = true;
            } else |err| {
                if (err != error.InvalidState) self.failure = true;
            }
        }
    }
};

// Withhold actual service opportunities, not counters or fabricated readiness.
// Raw decoded PCM alone must not replace real Render visibility admission.
test "initial entry still waits for actual Worker completion and Render acknowledged headroom" {
    const bytes = try bank();
    defer a.free(bytes);
    var oracle = try f.Oracle.decode(bytes);
    defer oracle.deinit();
    const rig = try Rig.create(bytes);
    var alive = true;
    defer if (alive) rig.finish(&alive) catch @panic("headroom negative retained actual custody");
    const owner = rig.engine.run.owner;
    const service = owner.owned_streaming.?;
    const renderer = rig.engine.run.renderer;
    const ticket = try owner.start(rig.engine.run.bank.?, f.state);
    var eligibility: EligibilityProbe = .{ .owner = owner, .request_id = ticket.request_id };
    owner.test_tick_hook = .{ .context = &eligibility, .call = EligibilityProbe.hook };
    defer if (alive) {
        owner.test_tick_hook = null;
    };
    // Loading already joined each registered Worker call. Do not offer any
    // further Worker step yet: actual newly queued decodes remain uncompleted.
    for (0..3) |_| {
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        try t.expect(owner.active_group == null and owner.pending == null and !owner.has_executed);
        while (try owner.pollReceiptV1()) |receipt| {
            try t.expectEqualDeep(ticket, receipt.ticket);
            try t.expect(receipt.event != .terminal);
        }
    }
    var windows: usize = 0;
    for (owner.generation.?.windows) |item| if (item) |window| {
        if (window.scope != .request or window.request_id != ticket.request_id or window.retiring or window.binding.cue == 0) continue;
        windows += 1;
        try t.expectEqual(@as(u64, 0), try service.acknowledgedVisiblePrefix(window.binding.handle));
    };
    try t.expectEqual(@as(usize, 4), windows);
    // Real decode and actual Control acceptance, but no Render admission yet.
    try rig.engine.workers();
    _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
    var published: usize = 0;
    for (owner.generation.?.windows) |item| if (item) |window| {
        if (window.scope != .request or window.request_id != ticket.request_id or window.retiring or window.binding.cue == 0) continue;
        // Worker calls have returned and no Render is running; this is a
        // local real publication check, not a concurrent/global snapshot.
        const ring = try service.ringFor(window.binding.handle);
        if (ring.produced.load(.acquire) > 0) published += 1;
        try t.expectEqual(@as(u64, 0), try service.acknowledgedVisiblePrefix(window.binding.handle));
    };
    try t.expectEqual(@as(usize, 4), published);
    try t.expect(owner.active_group == null and owner.pending == null and !owner.has_executed);
    while (try owner.pollReceiptV1()) |receipt| {
        try t.expectEqualDeep(ticket, receipt.ticket);
        try t.expect(receipt.event != .terminal);
    }
    // Release only by offering real Render/Worker/Control work; the original
    // ticket must eventually execute rather than requiring a replacement Play.
    var executed = false;
    var play_frame: u64 = 0;
    for (0..512) |_| {
        var pcm: [128]f32 = undefined;
        renderer.render(&pcm, 64, 2);
        try rig.engine.workers();
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        while (try owner.pollReceiptV1()) |receipt| {
            try t.expectEqualDeep(ticket, receipt.ticket);
            if (receipt.event == .terminal) {
                try t.expect(receipt.event.terminal == .executed);
                executed = true;
                play_frame = receipt.event.terminal.executed.effective_frame;
            }
        }
        if (executed) break;
    }
    var evidence: f.Oracle.Evidence = .{};
    var pcm_failure: ?anyerror = null;
    if (executed) for (0..16) |_| {
        try rig.engine.workers();
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        const first = renderer.renderFrame();
        var pcm: [128]f32 = undefined;
        renderer.render(&pcm, 64, 2);
        evidence.expectPcm(&oracle, first, play_frame, &pcm) catch |err| {
            if (pcm_failure == null) pcm_failure = err;
        };
    };
    const stop = try owner.submitV1(rig.engine.run.bank.?, .{ .stop = .emergency_ramp });
    var stopped = false;
    for (0..512) |_| {
        try rig.engine.workers();
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        var pcm: [128]f32 = undefined;
        renderer.render(&pcm, 64, 2);
        while (try owner.pollReceiptV1()) |receipt| {
            try t.expectEqualDeep(stop, receipt.ticket);
            if (receipt.event == .terminal and receipt.event.terminal == .executed) stopped = true;
        }
        if (stopped) break;
    }
    owner.test_tick_hook = null;
    try rig.finish(&alive);
    std.debug.print("ENTRY_HEADROOM_WAIT executed={} stopped={} pcm_frames={d} nonzero={d} pcm_ok={} cleanup_complete=true\n", .{ executed, stopped, evidence.frames, evidence.nonzero, pcm_failure == null });
    std.debug.print("ENTRY_ELIGIBILITY initial={} wrong_request_rejected={} stale_tick_rejected={} pending_seen={} active_seen={} executed_seen={} unexpected_result={}\n", .{ eligibility.eligible_seen, eligibility.wrong_request_rejected, eligibility.stale_tick_rejected, eligibility.pending_seen, eligibility.active_seen, eligibility.executed_seen, eligibility.failure });
    try t.expect(!eligibility.failure and eligibility.eligible_seen and eligibility.wrong_request_rejected and eligibility.stale_tick_rejected);
    try t.expect(eligibility.pending_seen and eligibility.active_seen and eligibility.executed_seen);
    try t.expect(executed and stopped);
    try t.expect(pcm_failure == null and evidence.frames == 1024 and evidence.nonzero > 0);
}
