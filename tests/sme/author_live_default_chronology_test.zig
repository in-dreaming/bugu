//! Ordinary Host regression: no semantic session, Recorder, Driver or manual
//! Render. Control has one cross-frame pause plus an optional diagnostic-only
//! cadence delay; actual null callbacks supply all PCM.
const std = @import("std");
const live = @import("sme-author-live-owner");
const f = @import("sme-stream-reload-fixture");
const t = std.testing;
const a = t.allocator;
const trace = f.music.trace;
const Position = trace.schema.Position;
const stream = f.rt.streaming.stream;
const deadline_ns = 20 * std.time.ns_per_s;
const playback_frames = 32768;
// Diagnostic experiment only. This does not reproduce a Windows timer or
// change the default regression's acceptance conditions.
fn controlDelayMilliseconds() !u8 {
    const value = std.process.Environ.getAlloc(t.environ, a, "SME_DEFAULT_CONTROL_DELAY_MS") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return 0,
        else => return err,
    };
    defer a.free(value);
    if (std.mem.eql(u8, value, "0")) return 0;
    if (std.mem.eql(u8, value, "16")) return 16;
    return error.DefaultUnsupportedControlDelay;
}
// Fixed diagnostic workload selection, validated before bank/Host creation.
fn workerDelayMilliseconds() !u8 {
    const value = std.process.Environ.getAlloc(t.environ, a, "SME_DEFAULT_WORKER_DELAY_MS") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return 1,
        else => return err,
    };
    defer a.free(value);
    if (std.mem.eql(u8, value, "1")) return 1;
    if (std.mem.eql(u8, value, "16")) return 16;
    return error.DefaultUnsupportedWorkerDelay;
}
fn pause() void {
    std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
}
fn expired(start: anytype) bool {
    return start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= deadline_ns;
}
fn buildBank() ![]u8 {
    const source = try std.mem.replaceOwned(u8, a, f.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer a.free(source);
    return f.buildSource(.a, source, null);
}
fn launch(bytes: []const u8) live.Launch {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.authored_source, &hash, .{});
    return .{ .document_id = 19, .revision = 7, .draft_hash = hash, .state = f.state, .compiled = bytes };
}
// Stable diagnostic text v1. Only owned typed fields are accepted: no pointer
// or free-string formatter can hide data or insert unescaped token separators.
// Dotted keys, explicit optional presence/null, tagged payloads, decimal scalar
// values, enum name+code, and complete lowercase hex bytes have no depth limit.
const FlatDiagnostic = struct {
    fn fields(writer: *std.Io.Writer, comptime key: []const u8, value: anytype) std.Io.Writer.Error!void {
        @setEvalBranchQuota(100_000);
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .bool => try writer.print(" {s}={}", .{ key, value }),
            .int, .comptime_int => try writer.print(" {s}={d}", .{ key, value }),
            .float, .comptime_float => try writer.print(" {s}={d}", .{ key, value }),
            .@"enum" => try writer.print(" {s}={s} {s}.code={d}", .{ key, std.enums.tagName(T, value) orelse "unnamed", key, @intFromEnum(value) }),
            .error_set => try writer.print(" {s}={s}", .{ key, @errorName(value) }),
            .optional => {
                try writer.print(" {s}.present={}", .{ key, value != null });
                if (value) |child| try fields(writer, key, child) else try writer.print(" {s}=null", .{key});
            },
            .@"struct" => |info| inline for (info.fields) |field| {
                try fields(writer, key ++ "." ++ field.name, @field(value, field.name));
            },
            .@"union" => |info| {
                const Tag = info.tag_type orelse @compileError("diagnostic unions must be tagged");
                const tag = std.meta.activeTag(value);
                try writer.print(" {s}.tag={s}", .{ key, @tagName(tag) });
                inline for (info.fields) |field| {
                    if (tag == @field(Tag, field.name)) try fields(writer, key ++ "." ++ field.name, @field(value, field.name));
                }
            },
            .array => |info| {
                if (info.child == u8) {
                    try writer.print(" {s}=", .{key});
                    for (value) |byte| try writer.print("{x:0>2}", .{byte});
                } else {
                    inline for (0..info.len) |i| {
                        try fields(writer, std.fmt.comptimePrint("{s}[{d}]", .{ key, i }), value[i]);
                    }
                }
            },
            .void => try writer.print(" {s}=void", .{key}),
            else => @compileError("unsupported diagnostic field type: " ++ @typeName(T)),
        }
    }
    fn line(writer: *std.Io.Writer, comptime marker: []const u8, comptime key: []const u8, value: anytype) std.Io.Writer.Error!void {
        try writer.writeAll(marker ++ " schema=1");
        try fields(writer, key, value);
        try writer.writeByte('\n');
    }
    // All callers are post-join paths. Buffering streams to stderr; there is no
    // fixed output-length cap or allocator, and writer errors are not success.
    fn stderrLine(comptime marker: []const u8, comptime key: []const u8, value: anytype) void {
        var buffer: [1024]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();
        const writer = &stderr.file_writer.interface;
        const result: std.Io.Writer.Error!void = blk: {
            line(writer, marker, key, value) catch |err| break :blk err;
            break :blk writer.flush();
        };
        result catch {
            stderr.file_writer.interface.writeAll("\nDEFAULT_HOST_DIAGNOSTIC_WRITE_ERROR schema=1 output_incomplete=true\n") catch {};
        };
    }
};
const Pcm = struct {
    const Record = struct { epoch: u64, first: u64, offset: usize, frames: usize, thread: u64 };
    /// Callback-owned scalars only. Preserve the first failure before publishing
    /// failed; UI reads them only after genuine callback and Control joins.
    const Failure = struct {
        epoch: u64,
        first_frame: u64,
        channels: u16,
        sample_count: usize,
        stored_records: usize,
        record_capacity: usize,
        used_samples: usize,
        sample_capacity: usize,
        remaining_samples: usize,
        captured_callbacks_before: u64,
        captured_frames_before: u64,
        invalid_channels: bool,
        odd_sample_count: bool,
        records_full: bool,
        sample_capacity_exceeded: bool,
    };
    samples: []f32,
    records: [1024]Record = undefined,
    len: usize = 0,
    used: usize = 0,
    failure: ?Failure = null,
    callbacks: std.atomic.Value(u64) = .init(0),
    submitted_frames: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    fn observe(raw: *anyopaque, epoch: u64, first: u64, channels: u16, samples: []const f32) void {
        const self: *Pcm = @ptrCast(@alignCast(raw));
        if (channels != 2 or samples.len % 2 != 0 or self.len == self.records.len or samples.len > self.samples.len - self.used) {
            if (self.failure == null) self.failure = .{
                .epoch = epoch,
                .first_frame = first,
                .channels = channels,
                .sample_count = samples.len,
                .stored_records = self.len,
                .record_capacity = self.records.len,
                .used_samples = self.used,
                .sample_capacity = self.samples.len,
                .remaining_samples = self.samples.len - self.used,
                .captured_callbacks_before = self.callbacks.load(.acquire),
                .captured_frames_before = self.submitted_frames.load(.acquire),
                .invalid_channels = channels != 2,
                .odd_sample_count = samples.len % 2 != 0,
                .records_full = self.len == self.records.len,
                .sample_capacity_exceeded = samples.len > self.samples.len - self.used,
            };
            self.failed.store(true, .release);
            return;
        }
        @memcpy(self.samples[self.used..][0..samples.len], samples);
        self.records[self.len] = .{ .epoch = epoch, .first = first, .offset = self.used, .frames = samples.len / 2, .thread = @intCast(std.Thread.getCurrentId()) };
        self.len += 1;
        self.used += samples.len;
        _ = self.submitted_frames.fetchAdd(samples.len / 2, .release);
        _ = self.callbacks.fetchAdd(1, .release);
    }
    fn reportFailureAfterJoin(self: *const Pcm) void {
        FlatDiagnostic.stderrLine("DEFAULT_HOST_PCM_CAPACITY_OR_SHAPE", "failure", self.failure);
    }
    fn check(self: *const Pcm, oracle: *const f.Oracle, play: u64, stop: u64, closed: live.Status) !void {
        if (self.failed.load(.acquire)) return error.DefaultPcmCapacityOrShape;
        try t.expect(self.len > 0 and stop >= play + playback_frames);
        var next: u64 = 0;
        var audible: u64 = 0;
        var nonzero: u64 = 0;
        var ramp: u64 = 0;
        var silent_after: u64 = 0;
        var missing_difference: [4]f64 = @splat(0);
        var wrong_cursor: f32 = 0;
        const release: u64 = f.rt.scheduler.default_profile.emergency_ramp_frames;
        for (self.records[0..self.len]) |record| {
            try t.expectEqual(@as(u64, 1), record.epoch);
            try t.expectEqual(next, record.first);
            next += record.frames;
            try t.expect(record.thread != closed.control_thread_id and record.thread != closed.worker_thread_id and record.thread != @as(u64, @intCast(std.Thread.getCurrentId())));
            for (0..record.frames) |i| {
                const frame = record.first + i;
                const sounding = frame >= play and frame < stop + release;
                const cursor = if (sounding) (frame - play) % f.loop_frames else 0;
                const gain: f32 = if (frame < stop) 1 else if (frame < stop + release) 1 - @as(f32, @floatFromInt(frame - stop)) / @as(f32, @floatFromInt(release)) else 0;
                const expected = if (sounding) oracle.sampleAt(cursor) * gain else @as(f32, 0);
                for (self.samples[record.offset + i * 2 ..][0..2]) |actual| {
                    if (!std.math.isFinite(actual) or @abs(actual - expected) > f.Oracle.tolerance) {
                        std.debug.print("DEFAULT_HOST_PCM_MISMATCH frame={d} play={d} stop={d} actual={d} expected={d}\n", .{ frame, play, stop, actual, expected });
                        return error.DefaultFourStemPcmMismatch;
                    }
                }
                if (frame >= play and frame < stop) {
                    audible += 1;
                    if (@abs(expected) > f.Oracle.tolerance) nonzero += 1;
                    for (&missing_difference, 0..) |*difference, stem| difference.* = @max(difference.*, @abs(oracle.stemAt(stem, cursor)));
                    wrong_cursor = @max(wrong_cursor, @abs(expected - oracle.sampleAt((cursor + 1) % f.loop_frames)));
                } else if (frame >= stop and frame < stop + release) ramp += 1 else if (frame >= stop + release) silent_after += 1;
            }
        }
        try t.expect(audible >= playback_frames and nonzero > 0 and ramp == release and silent_after > 0);
        for (missing_difference) |difference| try t.expect(difference > f.Oracle.tolerance * 8);
        try t.expect(wrong_cursor > f.Oracle.tolerance * 8);
        std.debug.print("DEFAULT_HOST_PCM frames={d} audible={d} nonzero={d} ramp={d} silence_after={d} all_four_stems=true\n", .{ next, audible, nonzero, ramp, silent_after });
    }
};
// Each role owns its tail and counters exclusively. No merged/global clock is
// implied: Worker completion publication can precede its completion callback.
fn DiagnosticTail(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Entry = struct { ordinal: u64, value: T };
        entries: [capacity]Entry = undefined,
        next: u64 = 0,
        len: usize = 0,
        overwritten: u64 = 0,
        counter_exhausted: bool = false,
        fn append(self: *@This(), value: T) void {
            if (self.next == std.math.maxInt(u64)) {
                self.counter_exhausted = true;
                return;
            }
            self.entries[@intCast(self.next % capacity)] = .{ .ordinal = self.next, .value = value };
            self.next += 1;
            if (self.len < capacity) self.len += 1 else self.overwritten +|= 1;
        }
        fn at(self: *const @This(), retained_index: usize) Entry {
            std.debug.assert(retained_index < self.len);
            return self.entries[@intCast((self.next - self.len + retained_index) % capacity)];
        }
    };
}
// Test-only passive Host sleep observations, not a scheduler or sleep-result
// certificate. Each role exclusively owns its state until actual native joins.
const WaitDiagnostics = struct {
    const capacity = 64;
    const Sample = struct { clock_ready: bool, clock: stream.OfflineClockSample };
    const Observation = struct { point: live.TestWaitPoint, sample: Sample };
    const Pair = struct {
        id: ?u64 = null,
        before: ?Observation = null,
        after: ?Observation = null,
        missing_before: bool = false,
        missing_after: bool = false,
        metadata_mismatch: bool = false,
        pair_invalid: bool = false,
        nonmonotonic: bool = false,
    };
    const RoleState = struct {
        next_id: u64 = 0,
        id_exhausted: bool = false,
        pending: ?Pair = null,
        tail: DiagnosticTail(Pair, capacity) = .{},
        fn observe(self: *@This(), point: live.TestWaitPoint, sample: Sample) void {
            const observation: Observation = .{ .point = point, .sample = sample };
            if (point.edge == .before) {
                if (self.pending) |pending| {
                    var missing = pending;
                    missing.missing_after = true;
                    missing.pair_invalid = true;
                    self.tail.append(missing);
                }
                var id: ?u64 = null;
                if (self.next_id == std.math.maxInt(u64)) {
                    self.id_exhausted = true;
                } else {
                    id = self.next_id;
                    self.next_id += 1;
                }
                self.pending = .{ .id = id, .before = observation };
            } else {
                var pair = self.pending orelse Pair{ .missing_before = true };
                pair.after = observation;
                if (pair.before) |before| {
                    var normalized = point;
                    normalized.edge = .before;
                    pair.metadata_mismatch = !std.meta.eql(before.point, normalized);
                    const first = before.sample.clock;
                    const last = sample.clock;
                    pair.nonmonotonic = before.sample.clock_ready and sample.clock_ready and first.available and last.available and first.error_code == 0 and last.error_code == 0 and last.value < first.value;
                }
                pair.pair_invalid = pair.missing_before or pair.metadata_mismatch or pair.id == null;
                self.tail.append(pair);
                self.pending = null;
            }
        }
    };
    control: RoleState = .{},
    worker: RoleState = .{},

    fn writeAfterJoin(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        inline for (.{ "control", "worker" }) |role| {
            const state = &@field(self, role);
            try writer.print("DEFAULT_HOST_WAIT_TAIL schema=1 role={s}", .{role});
            try FlatDiagnostic.fields(writer, "wait", .{
                .capacity = capacity,
                .retained = state.tail.len,
                .next = state.tail.next,
                .overwritten = state.tail.overwritten,
                .tail_counter_exhausted = state.tail.counter_exhausted,
                .next_id = state.next_id,
                .id_exhausted = state.id_exhausted,
                .pending = state.pending,
                .completeness_asserted = false,
                .units = @as(enum { ns }, .ns),
                .interval_not_pure_sleep = true,
                .after_not_sleep_success = true,
            });
            try writer.writeByte('\n');
            for (0..state.tail.len) |i| {
                const entry = state.tail.at(i);
                try writer.print("DEFAULT_HOST_WAIT_EVENT schema=1 role={s} ordinal={d}", .{ role, entry.ordinal });
                try FlatDiagnostic.fields(writer, "pair", entry.value);
                try writer.writeByte('\n');
            }
        }
    }
};
const NativeDiagnostics = struct {
    const control_capacity = 256;
    const worker_capacity = 128;
    const JobIdentity = struct {
        slot: u16,
        handle: stream.Handle,
        descriptor: trace.schema.readiness.JobDescriptor,
        ordinal: u64,
        count: u32,
    };
    const Supply = struct {
        point: stream.TestSupplyPoint,
        group: u64,
        layer: u64,
        pending_job: ?u16,
        queued: ?JobIdentity = null,
    };
    const Acceptance = struct {
        incoming: Position,
        effective_frame: u64,
        runtime_finished: bool,
        batch_id: u64,
        job_slots: usize,
        scanned: usize,
        representation_complete: bool,
        states_valid_len: usize,
        states_truncated: bool,
        states_inconsistent: bool,
        states_projection_complete: bool,
        // Sequential acquired slot observations, NOT a coherent snapshot.
        // 0 free, 1 queued, 2 running, 3 completed; 255 means unobserved.
        // Fixed storage adds at most roughly 64 KiB across the Control tail.
        states: [256]u8,
        outcome: stream.observation.Outcome,
        error_code: u32,
        returned_error: ?stream.Error,
        cut: ?stream.CompletedDspCutV1,
        deferred: @FieldType(stream.LiveAcceptanceAttemptV1, "deferred"),
        selected: ?struct { identity: JobIdentity, outcome: trace.schema.Readiness, failure_code: u16 },
        availability: stream.observation.Availability,
        ring_capacity: ?u32,
        publication_preflight: ?stream.observation.PublicationCut,
        publication: ?struct {
            batch_id: u64,
            handle: stream.Handle,
            worker_job: u64,
            prefix_start: u64,
            prefix_end: u64,
            target_cursor: u64,
            loop_epoch: u64,
        },
        effects: stream.observation.Effects,
        accepted: ?struct { handle: stream.Handle, position: Position, worker: trace.schema.Worker },
    };
    const ControlEvent = struct {
        // Supply/tick entries use the current Control position, not a claimed
        // operation-local accepted frame. Public inputs retain their own position.
        position: Position,
        observed_clock: ?stream.OfflineClockSample = null,
        value: union(enum) {
            supply: Supply,
            supply_return: stream.TestSupplyReturn,
            acceptance: Acceptance,
            public_worker: trace.schema.Worker,
            admission: trace.schema.Admission,
            tick: f.music.MusicRuntime.LiveControlTickOutcomeV1,
        },
    };
    const WorkerTiming = struct {
        job: ?u64 = null,
        begin: ?stream.OfflineClockSample = null,
        end: ?stream.OfflineClockSample = null,
        pair_invalid: bool = false,
        nonmonotonic: bool = false,
    };
    const WorkerEvent = struct { kind: enum { running, completed }, job: u64, identity: ?JobIdentity = null, timing: ?WorkerTiming = null };
    // Exact pre-timing field layouts, used only to report added diagnostic
    // storage including array alignment rather than claiming nominal bytes.
    const LegacyControlEvent = struct { position: Position, value: @FieldType(ControlEvent, "value") };
    const LegacyWorkerEvent = struct { kind: @FieldType(WorkerEvent, "kind"), job: u64, identity: ?JobIdentity = null };
    const LegacyDiagnostics = struct {
        owner: ?*f.music.MusicRuntime,
        service: ?*f.rt.streaming.Service,
        installed: bool,
        setup_failed: bool,
        worker_identity_missing: u64,
        control: DiagnosticTail(LegacyControlEvent, control_capacity),
        worker: DiagnosticTail(LegacyWorkerEvent, worker_capacity),
        first_control_failure: @FieldType(NativeDiagnostics, "first_control_failure"),
        control_after_failure_omitted: u64,
    };
    // Exact previous passive-clock diagnostic layout, before wait tails.
    const BeforeWaitDiagnostics = struct {
        owner: ?*f.music.MusicRuntime,
        service: ?*f.rt.streaming.Service,
        installed: bool,
        setup_failed: bool,
        worker_identity_missing: u64,
        diagnostic_clock: ?trace.metrics.Clock,
        worker_timing: WorkerTiming,
        worker_timing_orphans: u64,
        control: ControlTail,
        worker: WorkerTail,
        first_control_failure: @FieldType(NativeDiagnostics, "first_control_failure"),
        control_after_failure_omitted: u64,
    };
    const ControlTail = DiagnosticTail(ControlEvent, control_capacity);
    const WorkerTail = DiagnosticTail(WorkerEvent, worker_capacity);
    // Set on Control before worker_ready, then immutable. Service is installed
    // by the initial load Worker before its actual load.completed release.
    owner: ?*f.music.MusicRuntime = null,
    service: ?*f.rt.streaming.Service = null,
    installed: bool = false, // Worker only until joins.
    setup_failed: bool = false, // Worker only until joins.
    worker_identity_missing: u64 = 0,
    // Copied once by load Worker before load.completed release, immutable for
    // Control thereafter. Same Clock/frequency/domain as native Worker samples.
    diagnostic_clock: ?trace.metrics.Clock = null,
    clock_ready: std.atomic.Value(bool) = .init(false),
    waits: WaitDiagnostics = .{},
    worker_timing: WorkerTiming = .{}, // Worker owned until genuine join.
    worker_timing_orphans: u64 = 0,
    control: ControlTail = .{},
    worker: WorkerTail = .{},
    first_control_failure: ?struct { next_ordinal: u64, position: Position, failure: anyerror } = null,
    control_after_failure_omitted: u64 = 0,

    fn beforeWorker(raw: *anyopaque, owner: *f.music.MusicRuntime) void {
        const self: *NativeDiagnostics = @ptrCast(@alignCast(raw));
        self.owner = owner;
        owner.test_load_hook = .{ .context = self, .call = loaded };
    }
    fn loaded(raw: *anyopaque, stage: f.music.MusicRuntime.LoadStage) void {
        const self: *NativeDiagnostics = @ptrCast(@alignCast(raw));
        if (stage != .prepared) return;
        const candidate = self.owner.?.load.candidate orelse {
            self.setup_failed = true;
            return;
        };
        const service = candidate.service orelse {
            self.setup_failed = true;
            return;
        };
        if (self.installed) {
            self.setup_failed = true;
            return;
        }
        if (service.test_worker_clock_hook != null or service.offline_causal_replay != null or service.live_semantic_hooks != null) {
            self.setup_failed = true;
            return;
        }
        self.service = service;
        self.diagnostic_clock = service.clock;
        self.clock_ready.store(true, .release);
        service.test_worker_clock_observer = .{ .context = self, .observe = workerClock };
        service.test_supply_hook = .{ .context = self, .call = supply };
        service.test_supply_return_hook = .{ .context = self, .call = supplyReturn };
        service.test_worker_hook = .{ .context = self, .call = running };
        service.test_worker_stage_hook = .{ .context = self, .call = workerStage };
        self.installed = true;
    }
    fn waitSample(self: *const NativeDiagnostics) WaitDiagnostics.Sample {
        // Host startup waits can precede prepared. Never read Clock before HB.
        const ready = self.clock_ready.load(.acquire);
        return .{ .clock_ready = ready, .clock = if (ready) self.controlClock() else .{ .value = 0, .available = false } };
    }
    fn hostWait(raw: *anyopaque, point: live.TestWaitPoint) void {
        const self: *NativeDiagnostics = @ptrCast(@alignCast(raw));
        const sample = self.waitSample();
        switch (point.role) {
            .control => self.waits.control.observe(point, sample),
            .worker => self.waits.worker.observe(point, sample),
        }
    }
    fn position(self: *const NativeDiagnostics) Position {
        const owner = self.owner.?;
        return .{ .control_tick = owner.control.stream_control_tick, .input_order = owner.control.stream_input_order, .accepted_control_frame = owner.control.tick_v1.frame };
    }
    fn appendControl(self: *NativeDiagnostics, value: ControlEvent) void {
        if (self.first_control_failure != null) {
            self.control_after_failure_omitted +|= 1;
            return;
        }
        self.control.append(value);
    }
    fn freezeControl(self: *NativeDiagnostics, failure: anyerror) void {
        if (self.first_control_failure == null) self.first_control_failure = .{ .next_ordinal = self.control.next, .position = self.position(), .failure = failure };
    }
    fn supply(raw: *anyopaque, point: stream.TestSupplyPoint) void {
        const self: *NativeDiagnostics = @ptrCast(@alignCast(raw));
        const observed_clock = if (point.stage == .request_queued) self.controlClock() else null;
        const service = self.service.?;
        // get(handle) succeeded before the hook; these fields are Control-owned.
        const slot = &service.slots[point.handle.index];
        var value: Supply = .{ .point = point, .group = slot.options.group, .layer = slot.options.layer, .pending_job = slot.pending_job };
        if (point.stage == .request_queued) {
            const index = point.job_slot.?;
            const job = &service.jobs[index];
            // Worker may now run, but cannot modify these immutable request
            // fields; this sole Control cannot retire/reuse while in the hook.
            value.queued = .{ .slot = index, .handle = job.handle, .descriptor = job.descriptor, .ordinal = job.ordinal, .count = job.count };
        }
        self.appendControl(.{ .position = self.position(), .observed_clock = observed_clock, .value = .{ .supply = value } });
    }
    fn supplyReturn(raw: *anyopaque, value: stream.TestSupplyReturn) void {
        const self: *NativeDiagnostics = @ptrCast(@alignCast(raw));
        // The Service supplies only owned facts from reached locals. In
        // particular, null availability is not a measured zero.
        self.appendControl(.{ .position = self.position(), .value = .{ .supply_return = value } });
    }
    fn running(raw: *anyopaque, id: u64) void {
        const self: *NativeDiagnostics = @ptrCast(@alignCast(raw));
        self.worker_timing = .{ .job = id };
        var value: WorkerEvent = .{ .kind = .running, .job = id };
        // Only inspect the one running job while this Worker owns its claim.
        // Never read free/completed descriptors or Control's diagnostic lane.
        // Validated Service profiles bound this search to at most 256 slots.
        // This test-only observer has real overhead and can perturb timing.
        for (self.service.?.jobs, 0..) |*job, i| {
            if (job.state.load(.acquire) != .running) continue;
            if (job.descriptor.job != id) continue;
            value.identity = .{ .slot = @intCast(i), .handle = job.handle, .descriptor = job.descriptor, .ordinal = job.ordinal, .count = job.count };
            break;
        }
        if (value.identity == null) self.worker_identity_missing +|= 1;
        self.worker.append(value);
    }
    fn workerStage(raw: *anyopaque, stage: stream.WorkerStage, id: u64) void {
        const self: *NativeDiagnostics = @ptrCast(@alignCast(raw));
        if (stage != .after_completed) return;
        // The released slot may already be reused. Only the argument is safe.
        var timing = self.worker_timing;
        if (timing.job != id or timing.begin == null or timing.end == null) timing.pair_invalid = true;
        if (timing.begin) |begin| if (timing.end) |end| {
            timing.nonmonotonic = begin.available and end.available and begin.error_code == 0 and end.error_code == 0 and end.value < begin.value;
        };
        self.worker.append(.{ .kind = .completed, .job = id, .timing = timing });
        self.worker_timing = .{};
    }
    fn controlClock(self: *const NativeDiagnostics) stream.OfflineClockSample {
        const clock = self.diagnostic_clock orelse return .{ .value = 0, .available = false, .error_code = 0 };
        const value = clock.now() catch return .{ .value = 0, .available = true, .error_code = @intFromEnum(stream.WorkerExternalError.clock_failure) };
        return .{ .value = value, .available = true, .error_code = 0 };
    }
    fn workerClock(raw: *anyopaque, stage: stream.WorkerClockStage, job: u64, sample: stream.OfflineClockSample) void {
        const self: *NativeDiagnostics = @ptrCast(@alignCast(raw));
        // No clock acquisition here. These are the Service's already obtained
        // native samples, not timestamps of running/completed release stores.
        if (self.worker_timing.job != job) {
            self.worker_timing.pair_invalid = true;
            self.worker_timing_orphans +|= 1;
            return;
        }
        switch (stage) {
            .begin => {
                if (self.worker_timing.begin != null or self.worker_timing.end != null) self.worker_timing.pair_invalid = true;
                if (self.worker_timing.begin == null) self.worker_timing.begin = sample;
            },
            .end => {
                if (self.worker_timing.begin == null or self.worker_timing.end != null) self.worker_timing.pair_invalid = true;
                if (self.worker_timing.end == null) self.worker_timing.end = sample;
            },
        }
        // Preserve nonmonotonic samples verbatim. No subtraction/clamping and
        // no inference of CPU duration or atomic-store linearization time.
    }
    fn attemptSummary(attempt: *const stream.LiveAcceptanceAttemptV1, frame: u64, finished: bool) Acceptance {
        const evidence = &attempt.evidence;
        var states: [256]u8 = @splat(255);
        const valid_len = @min(evidence.scanned, evidence.job_slots, states.len);
        // Copy only already observed evidence; never reload Service job state.
        for (evidence.states[0..valid_len], 0..) |state, i| states[i] = switch (state) {
            .free => 0,
            .queued => 1,
            .running => 2,
            .completed => 3,
        };
        return .{
            .incoming = attempt.incoming,
            .effective_frame = frame,
            .runtime_finished = finished,
            .batch_id = evidence.batch_id,
            .job_slots = evidence.job_slots,
            .scanned = evidence.scanned,
            .representation_complete = evidence.representation_complete,
            .states_valid_len = valid_len,
            .states_truncated = evidence.scanned > states.len,
            .states_inconsistent = evidence.scanned > evidence.job_slots,
            .states_projection_complete = evidence.representation_complete and evidence.scanned <= states.len and evidence.scanned <= evidence.job_slots,
            .states = states,
            .outcome = evidence.outcome,
            .error_code = evidence.error_code,
            .returned_error = attempt.returned_error,
            .cut = attempt.cut,
            .deferred = attempt.deferred,
            .selected = if (evidence.selected) |selected| .{ .identity = .{ .slot = selected.slot, .handle = selected.handle, .descriptor = selected.descriptor, .ordinal = selected.ordinal, .count = selected.count }, .outcome = selected.outcome, .failure_code = selected.failure_code } else null,
            .availability = evidence.availability,
            .ring_capacity = evidence.ring_capacity,
            .publication_preflight = evidence.publication_preflight,
            .publication = if (evidence.publication) |value| .{ .batch_id = value.batch_id, .handle = .{ .index = value.stream_slot, .generation = value.stream_generation }, .worker_job = value.worker_job, .prefix_start = value.prefix_start, .prefix_end = value.prefix_end, .target_cursor = value.target_cursor, .loop_epoch = value.loop_epoch } else null,
            .effects = evidence.effects,
            .accepted = if (evidence.accepted) |value| .{ .handle = value.handle, .position = value.input.position, .worker = value.input.payload.worker } else null,
        };
    }
    fn acceptance(raw: *anyopaque, attempt: *const stream.LiveAcceptanceAttemptV1, frame: u64, finished: bool) void {
        const self: *NativeDiagnostics = @ptrCast(@alignCast(raw));
        const observed_clock = if (attempt.evidence.selected != null) self.controlClock() else null;
        self.appendControl(.{ .position = attempt.incoming, .observed_clock = observed_clock, .value = .{ .acceptance = attemptSummary(attempt, frame, finished) } });
    }
    fn publicInputs(self: *NativeDiagnostics, inputs: []const trace.Input) void {
        for (inputs) |input| switch (input.payload) {
            .worker => |value| self.appendControl(.{ .position = input.position, .value = .{ .public_worker = value } }),
            .admission => |value| self.appendControl(.{ .position = input.position, .value = .{ .admission = value } }),
            else => {},
        };
    }
    fn writeControlEvent(writer: *std.Io.Writer, entry: ControlTail.Entry) std.Io.Writer.Error!void {
        try writer.print("DEFAULT_HOST_CONTROL_EVENT schema=1 ordinal={d}", .{entry.ordinal});
        try FlatDiagnostic.fields(writer, "position", entry.value.position);
        try FlatDiagnostic.fields(writer, "observed_clock", entry.value.observed_clock);
        try FlatDiagnostic.fields(writer, "event", entry.value.value);
        try writer.writeByte('\n');
    }
    fn writeWorkerEvent(writer: *std.Io.Writer, entry: WorkerTail.Entry) std.Io.Writer.Error!void {
        try writer.print("DEFAULT_HOST_WORKER_EVENT schema=1 ordinal={d}", .{entry.ordinal});
        try FlatDiagnostic.fields(writer, "event", entry.value);
        try writer.writeByte('\n');
    }
    fn writeAfterJoin(self: *const NativeDiagnostics, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        // Event-tail coverage only; not a timing completeness certificate.
        const incomplete = !self.installed or self.setup_failed or self.worker_identity_missing != 0 or self.control.overwritten != 0 or self.worker.overwritten != 0 or self.control.counter_exhausted or self.worker.counter_exhausted or self.control_after_failure_omitted != 0;
        try writer.print("DEFAULT_HOST_EVENT_TAIL schema=1 selected_hooks_only=true global_order=false replay_certificate=false supply_return_observer=true reached_locals_only=true null_availability_not_zero=true worker_lookup_max_slots=256 acceptance_states_coherent=false acceptance_states_encoding=hex_u8_0free_1queued_2running_3completed_255unobserved acceptance_states_capacity=256 timing_perturbation=true incomplete={} storage_bytes={d} installed={} setup_failed={} worker_identity_missing={d} control_capacity={d} control_retained={d} control_next={d} control_overwritten={d} control_counter_exhausted={} control_after_failure_omitted={d} worker_capacity={d} worker_retained={d} worker_next={d} worker_overwritten={d} worker_counter_exhausted={}\n", .{ incomplete, @sizeOf(NativeDiagnostics), self.installed, self.setup_failed, self.worker_identity_missing, control_capacity, self.control.len, self.control.next, self.control.overwritten, self.control.counter_exhausted, self.control_after_failure_omitted, worker_capacity, self.worker.len, self.worker.next, self.worker.overwritten, self.worker.counter_exhausted });
        try FlatDiagnostic.line(writer, "DEFAULT_HOST_TIMING", "timing", .{
            .units = @as(enum { ns }, .ns),
            .domain = @as(enum { linux_monotonic, windows_qpc_scaled, unsupported }, switch (@import("builtin").os.tag) {
                .linux => .linux_monotonic,
                .windows => .windows_qpc_scaled,
                else => .unsupported,
            }),
            .clock_available = self.diagnostic_clock != null,
            .completeness_asserted = false,
            .post_store_observation_not_store = true,
            .worker_sample_interval_not_cpu_time = true,
            .worker_begin_may_precede_queued_observation = true,
            .no_completion_has_no_clock_sample = true,
            .worker_timing_orphans = self.worker_timing_orphans,
            .pending_worker_timing = self.worker_timing,
            .storage_before_bytes = @sizeOf(LegacyDiagnostics),
            .storage_after_bytes = @sizeOf(NativeDiagnostics),
            .storage_added_bytes = @sizeOf(NativeDiagnostics) - @sizeOf(LegacyDiagnostics),
            .control_tail_added_bytes = @sizeOf(ControlTail) - @sizeOf(DiagnosticTail(LegacyControlEvent, control_capacity)),
            .worker_tail_added_bytes = @sizeOf(WorkerTail) - @sizeOf(DiagnosticTail(LegacyWorkerEvent, worker_capacity)),
        });
        try FlatDiagnostic.line(writer, "DEFAULT_HOST_WAIT_STORAGE", "storage", .{
            .before_bytes = @sizeOf(BeforeWaitDiagnostics),
            .after_bytes = @sizeOf(NativeDiagnostics),
            .added_bytes = @sizeOf(NativeDiagnostics) - @sizeOf(BeforeWaitDiagnostics),
            .pair_tails_bytes = @sizeOf(WaitDiagnostics),
            .control_capacity = control_capacity,
            .worker_capacity = worker_capacity,
            .wait_capacity_per_role = WaitDiagnostics.capacity,
        });
        try self.waits.writeAfterJoin(writer);
        try FlatDiagnostic.line(writer, "DEFAULT_HOST_EVENT_FAILURE", "failure", self.first_control_failure);
        for (0..self.control.len) |i| try writeControlEvent(writer, self.control.at(i));
        for (0..self.worker.len) |i| try writeWorkerEvent(writer, self.worker.at(i));
    }
    fn reportAfterJoin(self: *const NativeDiagnostics) void {
        var buffer: [1024]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();
        const writer = &stderr.file_writer.interface;
        const result: std.Io.Writer.Error!void = blk: {
            self.writeAfterJoin(writer) catch |err| break :blk err;
            break :blk writer.flush();
        };
        result catch {
            stderr.file_writer.interface.writeAll("\nDEFAULT_HOST_DIAGNOSTIC_WRITE_ERROR schema=1 output_incomplete=true\n") catch {};
        };
    }
};
const Probe = struct {
    const Accepted = struct { position: Position, job: u64 };
    const Request = struct { id: u64, context: u64, position: Position };
    /// First failing observation only. Control copies owned facts; UI prints
    /// them only after a genuine join, never from a native audio callback.
    const RuntimeDiagnostic = struct {
        status: f.music.MusicRuntimeStatusV1,
        control_delay_ms: u8,
        tick: u64,
        control_frame: u64,
        tick_frame: u64,
        chronology_frontier: ?u64,
        owner_observation_sequence: u64,
        owner_stream_fault_count: u64,
        pause_armed: bool,
        pause_used: bool,
        cancelled: bool,
        first: ?Accepted,
        later: ?Accepted,
        callbacks_before: u64,
        callbacks_after: u64,
        callbacks_at_failure: u64,
        submitted_frames: u64,
        input_begin: u64,
        input_count: usize,
        schedule_begin: u64,
        schedule_count: usize,
    };
    owner: ?*f.music.MusicRuntime = null, // Control only, never read by UI.
    pcm: *Pcm,
    diagnostics: *NativeDiagnostics,
    control_delay_ms: u8 = 0,
    inputs: []trace.Input,
    schedule: []trace.ScheduleEntry,
    armed: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null, // Control only until genuine joins.
    runtime_diagnostic: ?RuntimeDiagnostic = null,
    used: bool = false,
    first: ?Accepted = null,
    later: ?Accepted = null,
    first_drained: bool = false,
    later_drained: bool = false,
    callbacks_before: u64 = 0,
    callbacks_after: u64 = 0,
    input_count: u64 = 0,
    schedule_count: u64 = 0,
    worker_inputs: u64 = 0,
    last_input: ?Position = null,
    requests: [8]Request = undefined,
    request_count: usize = 0,
    request_schedules: u64 = 0,
    executed_schedules: u64 = 0,
    provenance_checks: u64 = 0,
    legacy_diagnostic_incomplete: u64 = 0,
    legacy_rejected: bool = false,
    fn fail(self: *Probe, err: anyerror) void {
        self.diagnostics.freezeControl(err);
        if (self.failure == null) self.failure = err;
        self.failed.store(true, .release);
    }
    fn install(raw: *anyopaque, owner: *f.music.MusicRuntime) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.owner = owner;
        owner.control.test_live_acceptance_attempt = .{ .context = self.diagnostics, .call = NativeDiagnostics.acceptance };
    }
    fn acceptance(raw: *anyopaque, tick: u64, frame: u64) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.accept(tick, frame) catch |err| self.fail(err);
    }
    fn accept(self: *Probe, tick: u64, frame: u64) !void {
        const owner = self.owner orelse return error.DefaultMissingOwner;
        const inputs = owner.replayInputs();
        if (inputs.len == 0) return error.DefaultMissingPublicWorkerInput;
        const actual = inputs[inputs.len - 1];
        if (actual.payload != .worker or actual.position.control_tick != tick or actual.position.accepted_control_frame != frame or owner.control_frame != frame or owner.control.tick_v1.frame != frame) return error.DefaultAcceptanceFrameIncoherent;
        if (self.used) {
            if (tick == self.first.?.position.control_tick and frame > self.first.?.position.accepted_control_frame and self.later == null)
                self.later = .{ .position = actual.position, .job = actual.payload.worker.job };
            return;
        }
        if (!self.armed.load(.acquire) or self.cancelled.load(.acquire)) return;
        self.used = true;
        self.first = .{ .position = actual.position, .job = actual.payload.worker.job };
        self.callbacks_before = self.pcm.callbacks.load(.acquire);
        const began = std.Io.Clock.awake.now(t.io);
        while (self.pcm.callbacks.load(.acquire) - self.callbacks_before < 2) {
            if (self.cancelled.load(.acquire)) return;
            if (self.pcm.failed.load(.acquire)) return error.DefaultPcmCapacityOrShape;
            if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 250 * std.time.ns_per_ms) return error.DefaultAcceptancePauseTimedOut;
            try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
        }
        self.callbacks_after = self.pcm.callbacks.load(.acquire);
    }
    fn outcome(raw: *anyopaque, value: f.music.MusicRuntime.LiveControlTickOutcomeV1) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.diagnostics.appendControl(.{ .position = self.diagnostics.position(), .value = .{ .tick = value } });
        if (self.failed.load(.acquire)) return;
        self.collect() catch |err| {
            self.fail(err);
            return;
        };
        if (self.pcm.failed.load(.acquire)) self.diagnostics.freezeControl(error.DefaultPcmCapacityOrShape);
        // The Host invokes this after a successful real live tick. Trace
        // collection and every original assertion run before the delay.
        // Cancellation prevents adding further delay to genuine cleanup.
        if (self.control_delay_ms == 16 and !self.cancelled.load(.acquire)) {
            std.Io.sleep(t.io, .fromMilliseconds(16), .awake) catch |err| {
                self.fail(err);
                return;
            };
        }
    }
    fn collect(self: *Probe) !void {
        const owner = self.owner orelse return error.DefaultMissingOwner;
        const result = try owner.copyAndDrainTraceWithProvenanceV1(self.inputs, self.schedule);
        const batch = result.batch;
        // Copy the actual drained failure-tick prefix before the original
        // status guard can return. Diagnostic copies do not advance test counts.
        self.diagnostics.publicInputs(self.inputs[0..batch.input_count]);
        if (batch.inputs_dropped != 0 or batch.schedule_dropped != 0 or batch.counter_exhausted) return error.DefaultPublicTraceLost;
        try t.expectEqual(self.input_count, batch.input_begin);
        try t.expectEqual(self.schedule_count, batch.schedule_begin);
        if (result.requirements.replay_contract != .live_chronology_v1 or result.requirements.live_capture != .unavailable) return error.DefaultWrongHistoryContract;
        if (owner.semantic_output_sink != null or owner.live_semantic_service_hooks != null or owner.causal_sink != null or owner.public_recording.phase != .disabled) return error.DefaultUnexpectedCapture;
        if (owner.control_frame != owner.control.tick_v1.frame) return error.DefaultFinalFrameIncoherent;
        self.provenance_checks += 1;
        if (!self.legacy_rejected) {
            var bytes: [0]u8 = .{};
            try t.expectError(error.LiveChronologyRequired, owner.exportReplayV1(&bytes));
            self.legacy_rejected = true;
        }
        const status = try owner.snapshotV1();
        // The legacy serial-trace concurrency flag may mark diagnostics incomplete
        // without losing these retained prefixes. Verify actual loss separately.
        if (!status.diagnostics_complete) self.legacy_diagnostic_incomplete += 1;
        if (status.complete or status.stream_fault_count != 0) {
            if (self.runtime_diagnostic == null) self.runtime_diagnostic = .{
                .status = status,
                .control_delay_ms = self.control_delay_ms,
                .tick = owner.tick,
                .control_frame = owner.control_frame,
                .tick_frame = owner.control.tick_v1.frame,
                .chronology_frontier = owner.live_chronology_frontier,
                .owner_observation_sequence = owner.observation_sequence,
                .owner_stream_fault_count = owner.stream_fault_count,
                .pause_armed = self.armed.load(.acquire),
                .pause_used = self.used,
                .cancelled = self.cancelled.load(.acquire),
                .first = self.first,
                .later = self.later,
                .callbacks_before = self.callbacks_before,
                .callbacks_after = self.callbacks_after,
                .callbacks_at_failure = self.pcm.callbacks.load(.acquire),
                .submitted_frames = self.pcm.submitted_frames.load(.acquire),
                .input_begin = batch.input_begin,
                .input_count = batch.input_count,
                .schedule_begin = batch.schedule_begin,
                .schedule_count = batch.schedule_count,
            };
            return error.DefaultRuntimeDiagnostics;
        }
        for (self.inputs[0..batch.input_count]) |input| {
            if (self.last_input) |previous| {
                if (!trace.schema.before(previous, input.position) or input.position.accepted_control_frame < previous.accepted_control_frame) return error.DefaultInputPositionRegression;
            }
            self.last_input = input.position;
            if (input.payload == .worker) {
                self.worker_inputs += 1;
                if (self.first) |value| if (value.job == input.payload.worker.job and std.meta.eql(value.position, input.position)) {
                    self.first_drained = true;
                };
                if (self.later) |value| if (value.job == input.payload.worker.job and std.meta.eql(value.position, input.position)) {
                    self.later_drained = true;
                };
            }
            if (input.payload == .request) {
                if (self.request_count == self.requests.len) return error.DefaultRequestBound;
                self.requests[self.request_count] = .{ .id = input.payload.request.request_id, .context = input.payload.request.context, .position = input.position };
                self.request_count += 1;
            }
        }
        for (self.schedule[0..batch.schedule_count]) |entry| switch (entry) {
            .event => |event| {
                if (event.kind == .request_accepted) {
                    const request = for (self.requests[0..self.request_count]) |value| {
                        if (value.id == event.request_id) break value;
                    } else return error.DefaultScheduleWithoutInput;
                    const actual: Position = .{ .control_tick = event.control_tick, .input_order = event.input_order, .accepted_control_frame = event.accepted_control_frame };
                    if (event.context != request.context or !std.meta.eql(request.position, actual)) return error.DefaultPublicScheduleFrameIncoherent;
                    self.request_schedules += 1;
                }
                if (event.kind == .executed) self.executed_schedules += 1;
            },
            else => {},
        };
        self.input_count += batch.input_count;
        self.schedule_count += batch.schedule_count;
    }
    fn check(self: *const Probe) !void {
        if (self.failure) |err| return err;
        if (!self.used or self.first == null or self.later == null or !self.first_drained or !self.later_drained) return error.DefaultMissingCrossFramePublicInputs;
        try t.expect(self.callbacks_after >= self.callbacks_before + 2);
        try t.expect(self.later.?.position.accepted_control_frame > self.first.?.position.accepted_control_frame);
        try t.expectEqual(self.first.?.position.control_tick, self.later.?.position.control_tick);
        try t.expect(self.worker_inputs > 0 and self.request_schedules >= 2 and self.executed_schedules >= 2 and self.provenance_checks > 0 and self.legacy_rejected);
        std.debug.print("DEFAULT_HOST_CHRONOLOGY tick={d} first={d} later={d} callbacks={d}->{d} inputs={d} schedule={d} request_matches={d} executed={d} legacy_diagnostic_incomplete={d} capture=unavailable\n", .{ self.first.?.position.control_tick, self.first.?.position.accepted_control_frame, self.later.?.position.accepted_control_frame, self.callbacks_before, self.callbacks_after, self.input_count, self.schedule_count, self.request_schedules, self.executed_schedules, self.legacy_diagnostic_incomplete });
    }
    fn reportFailureAfterJoin(self: *const Probe) void {
        FlatDiagnostic.stderrLine("DEFAULT_HOST_RUNTIME_DIAGNOSTICS", "runtime", self.runtime_diagnostic);
        FlatDiagnostic.stderrLine("DEFAULT_HOST_PROBE_ERROR", "failure", self.failure);
    }
};
const Receipts = struct {
    ids: [2]u64 = @splat(0),
    accepted: [2]bool = @splat(false),
    terminal: [2]?f.music.MusicRuntimeReceiptV1 = @splat(null),
    fn collect(self: *Receipts, host: *live.Host) !void {
        while (host.popEvent()) |event| {
            // Release actual terminal custody even if a subsequent assertion
            // fails. Expected IDs are never used to manufacture cleanup facts.
            if (event.kind == .terminal) try host.acknowledgeTerminal(event.command.id);
            const index: usize = for (self.ids, 0..) |id, i| {
                if (id != 0 and id == event.command.id) break i;
            } else return error.DefaultForeignCommand;
            try t.expectEqualDeep(host.identity(), event.command.identity);
            switch (event.kind) {
                .accepted => {
                    try t.expect(!self.accepted[index] and self.terminal[index] == null);
                    self.accepted[index] = true;
                },
                .terminal => {
                    try t.expect(self.terminal[index] == null);
                    const receipt = event.receipt orelse return error.DefaultMissingReceipt;
                    if (receipt.event != .terminal or receipt.event.terminal != .executed) return error.DefaultCommandNotExecuted;
                    self.terminal[index] = receipt;
                },
            }
        }
    }
    fn await(self: *Receipts, host: *live.Host, probe: *Probe, index: usize) !u64 {
        const began = std.Io.Clock.awake.now(t.io);
        while (true) {
            try self.collect(host);
            try healthy(host, probe);
            if (self.terminal[index]) |receipt| {
                try t.expect(self.accepted[index]);
                return receipt.event.terminal.executed.effective_frame;
            }
            if (expired(began)) return error.DefaultCommandTimedOut;
            pause();
        }
    }
};
fn healthy(host: *live.Host, probe: *Probe) !void {
    if (probe.failed.load(.acquire)) return error.DefaultControlProbeFailed;
    if (probe.pcm.failed.load(.acquire)) return error.DefaultPcmCapacityOrShape;
    if (host.readStatus()) |status| if (status.value.first_error) |err| {
        std.debug.print("DEFAULT_HOST_NATIVE_ERROR {s} site={s}\n", .{ @errorName(err), @tagName(status.value.first_error_site) });
        return err;
    };
}
fn closeActual(host: *live.Host) !live.Status {
    try host.requestClose(host.identity().epoch);
    const began = std.Io.Clock.awake.now(t.io);
    while (true) {
        while (host.popEvent()) |event| if (event.kind == .terminal) try host.acknowledgeTerminal(event.command.id);
        if (host.isClosed()) {
            host.join() catch {
                if (expired(began)) return error.DefaultJoinTimedOut;
                pause();
                continue;
            };
            const status = (host.readStatus() orelse return error.DefaultMissingClosedStatus).value;
            while (host.popEvent()) |event| if (event.kind == .terminal) try host.acknowledgeTerminal(event.command.id);
            try host.acknowledgeClosed();
            try host.destroy();
            return status;
        }
        if (expired(began)) return error.DefaultCloseTimedOut;
        pause();
    }
}

test "default Host without capture accepts cross-frame completions and preserves four-stem PCM" {
    const control_delay_ms = try controlDelayMilliseconds();
    const worker_delay_ms = try workerDelayMilliseconds();
    if (worker_delay_ms != 1) std.debug.print("DEFAULT_HOST_WORKER_CADENCE_EXPERIMENT classification=controlled_dual_cadence control_delay_ms={d} worker_wait_ms={d} windows_reproduction=false acceptance=false\n", .{ control_delay_ms, worker_delay_ms });
    if (control_delay_ms != 0) std.debug.print("DEFAULT_HOST_CONTROL_CADENCE_EXPERIMENT classification=controlled_cadence_experiment delay_ms={d} windows_reproduction=false acceptance=false\n", .{control_delay_ms});
    const bytes = try buildBank();
    defer a.free(bytes);
    var oracle = try f.Oracle.decode(bytes);
    defer oracle.deinit();
    // All borrowed observer storage is allocated before Host.create and is
    // retained if genuine failure cleanup cannot release native custody.
    var safe_to_free = true;
    const samples = try a.alloc(f32, 48_000 * 4 * 2);
    defer if (safe_to_free) a.free(samples);
    const pcm = try a.create(Pcm);
    defer if (safe_to_free) a.destroy(pcm);
    pcm.* = .{ .samples = samples };
    const inputs = try a.alloc(trace.Input, @typeInfo(@FieldType(f.music.MusicRuntime, "inputs")).array.len);
    defer if (safe_to_free) a.free(inputs);
    const schedule = try a.alloc(trace.ScheduleEntry, @typeInfo(@FieldType(f.music.MusicRuntime, "observations")).array.len);
    defer if (safe_to_free) a.free(schedule);
    const diagnostics = try a.create(NativeDiagnostics);
    defer if (safe_to_free) a.destroy(diagnostics);
    diagnostics.* = .{};
    const probe = try a.create(Probe);
    defer if (safe_to_free) a.destroy(probe);
    probe.* = .{ .pcm = pcm, .diagnostics = diagnostics, .inputs = inputs, .schedule = schedule, .control_delay_ms = control_delay_ms };
    const memory = try a.create(live.TestAllocator);
    defer if (safe_to_free) {
        if (memory.deinit() != .ok) @panic("default Host leaked native allocations");
        a.destroy(memory);
    };
    memory.* = .init;
    const options: live.Options = .{
        .io = t.io,
        .device = .{ .backend = .null_backend },
        .semantic = null,
        .test_capture = null,
        .test_worker_wait_ms = worker_delay_ms,
        .test_wait_observer = .{ .context = diagnostics, .call = NativeDiagnostics.hostWait },
        .test_before_worker = .{ .context = diagnostics, .call = NativeDiagnostics.beforeWorker },
        .test_setup = .{ .context = probe, .call = Probe.install },
        .test_tick_outcome = .{ .context = probe, .call = Probe.outcome },
        .test_after_live_acceptance = .{ .context = probe, .call = Probe.acceptance },
        .test_pcm = .{ .context = pcm, .call = Pcm.observe },
    };
    const host = try live.Host.createWithTestAllocator(memory, launch(bytes), options);
    var alive = true;
    var diagnostics_reported = false;
    errdefer {
        probe.cancelled.store(true, .release);
        var joined_for_report = !alive;
        if (alive) {
            if (closeActual(host)) |closed| {
                joined_for_report = true;
                FlatDiagnostic.stderrLine("DEFAULT_HOST_FAILURE_CLEANUP", "cleanup", .{ .worker_joined = closed.worker_joined, .provider = closed.provider, .sample_leases = closed.sample_leases, .live_instances = closed.live_instances, .cleanup_error = closed.cleanup_error });
            } else |cleanup_error| {
                std.debug.print("DEFAULT_HOST_FAILURE_CLEANUP_FAILED error={s} joined={} cleanup_complete=false\n", .{ @errorName(cleanup_error), host.joined });
                safe_to_free = false;
                // A failure after join (for example an unread Close credit)
                // retains storage but no longer has a concurrent producer.
                joined_for_report = host.joined;
            }
        }
        if (joined_for_report) {
            if (!diagnostics_reported) diagnostics.reportAfterJoin();
            pcm.reportFailureAfterJoin();
            probe.reportFailureAfterJoin();
        }
    }
    try t.expect(host.options.semantic == null and host.options.test_capture == null);
    try t.expectEqual(live.PacingMode.notified_v1, host.pacingMode());
    std.debug.print("DEFAULT_HOST_PACING schema=1 mode={s} ordinary=true\n", .{@tagName(host.pacingMode())});
    var receipts: Receipts = .{};
    receipts.ids[0] = (try host.submit(host.identity(), .play)).id;
    const play = try receipts.await(host, probe, 0);
    probe.armed.store(true, .release);
    const began = std.Io.Clock.awake.now(t.io);
    while (pcm.submitted_frames.load(.acquire) < play + playback_frames) {
        try receipts.collect(host);
        try healthy(host, probe);
        if (expired(began)) return error.DefaultPlaybackTimedOut;
        pause();
    }
    // Fixed workload endpoint. Never extend playback or retry for a witness.
    receipts.ids[1] = (try host.submit(host.identity(), .stop)).id;
    const stop = try receipts.await(host, probe, 1);
    // The executed receipt marks Stop onset, not submitted tail delivery. Wait
    // for the actual callback surface to include its ramp and some silence.
    const stopped_at = std.Io.Clock.awake.now(t.io);
    while (pcm.submitted_frames.load(.acquire) < stop + f.rt.scheduler.default_profile.emergency_ramp_frames + 1) {
        try receipts.collect(host);
        try healthy(host, probe);
        if (expired(stopped_at)) return error.DefaultStopPcmTimedOut;
        pause();
    }
    probe.cancelled.store(true, .release);
    const closed = try closeActual(host);
    alive = false;
    diagnostics.reportAfterJoin();
    diagnostics_reported = true;
    try t.expectEqual(.closed, closed.phase);
    try t.expect(closed.first_error == null and closed.cleanup_error == null and closed.worker_joined);
    try t.expect(closed.play_executed and closed.stop_executed and closed.callback_sequence > 0 and closed.worker_calls > 0);
    try t.expect(closed.control_thread_id != 0 and closed.worker_thread_id != 0 and closed.control_thread_id != closed.worker_thread_id);
    try t.expectEqual(@as(usize, 16), closed.provider.opened);
    try t.expectEqual(closed.provider.opened, closed.provider.closed);
    try t.expectEqual(@as(usize, 0), closed.provider.live);
    try t.expectEqual(@as(u64, 0), closed.sample_leases);
    try t.expectEqual(@as(u64, 0), closed.live_instances);
    try probe.check();
    try pcm.check(&oracle, play, stop, closed);
}

test "PCM diagnostic preserves the first shape or capacity failure without overwriting it" {
    // Isolated observer cases, not engine state or a substitute native run.
    const Cause = enum { channels, odd_samples, records, samples };
    for (std.enums.values(Cause)) |cause| {
        var storage: [4]f32 = undefined;
        var pcm: Pcm = .{ .samples = &storage };
        Pcm.observe(&pcm, 1, 0, 2, &.{ 0, 0 });
        if (cause == .records) pcm.len = pcm.records.len;
        const input: []const f32 = switch (cause) {
            .odd_samples => &.{0},
            .samples => &.{ 0, 0, 0, 0 },
            else => &.{ 0, 0 },
        };
        const channels: u16 = if (cause == .channels) 1 else 2;
        Pcm.observe(&pcm, 7, 11, channels, input);
        try t.expect(pcm.failed.load(.acquire));
        const first = pcm.failure orelse return error.MissingPcmFailureDiagnostic;
        try t.expectEqual(@as(u64, 7), first.epoch);
        try t.expectEqual(@as(u64, 11), first.first_frame);
        try t.expectEqual(channels, first.channels);
        try t.expectEqual(input.len, first.sample_count);
        try t.expectEqual(if (cause == .records) @as(usize, 1024) else 1, first.stored_records);
        try t.expectEqual(@as(usize, 1024), first.record_capacity);
        try t.expectEqual(@as(usize, 2), first.used_samples);
        try t.expectEqual(@as(usize, 4), first.sample_capacity);
        try t.expectEqual(@as(usize, 2), first.remaining_samples);
        try t.expectEqual(@as(u64, 1), first.captured_callbacks_before);
        try t.expectEqual(@as(u64, 1), first.captured_frames_before);
        try t.expectEqual(cause == .channels, first.invalid_channels);
        try t.expectEqual(cause == .odd_samples, first.odd_sample_count);
        try t.expectEqual(cause == .records, first.records_full);
        try t.expectEqual(cause == .samples, first.sample_capacity_exceeded);
        Pcm.observe(&pcm, 99, 123, 9, &.{0});
        try t.expectEqualDeep(first, pcm.failure.?);
        var text: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&text);
        try FlatDiagnostic.line(&writer, "DEFAULT_HOST_PCM_CAPACITY_OR_SHAPE", "failure", pcm.failure);
        try FlatFixture.tokens(writer.buffered(), &.{
            "DEFAULT_HOST_PCM_CAPACITY_OR_SHAPE schema=1 failure.present=true",
            "failure.epoch=7",
            "failure.first_frame=11",
            "failure.record_capacity=1024",
            "failure.used_samples=2",
            "failure.sample_capacity=4",
            "failure.remaining_samples=2",
            "failure.captured_callbacks_before=1",
            "failure.captured_frames_before=1",
        });
    }
}

test "diagnostic role tails retain exact rolling ordinals and mark truncation" {
    var tail: DiagnosticTail(u64, 2) = .{};
    tail.append(10);
    tail.append(20);
    tail.append(30);
    try t.expectEqual(@as(usize, 2), tail.len);
    try t.expectEqual(@as(u64, 3), tail.next);
    try t.expectEqual(@as(u64, 1), tail.overwritten);
    try t.expectEqual(@as(u64, 1), tail.at(0).ordinal);
    try t.expectEqual(@as(u64, 20), tail.at(0).value);
    try t.expectEqual(@as(u64, 2), tail.at(1).ordinal);
    try t.expectEqual(@as(u64, 30), tail.at(1).value);
    // Detached bookkeeping only, not a native engine counter.
    tail.next = std.math.maxInt(u64);
    tail.append(40);
    try t.expect(tail.counter_exhausted);
}

test "acceptance diagnostic copies initialized optional facts without retaining the attempt" {
    var attempt: stream.LiveAcceptanceAttemptV1 = .{
        .incoming = .{ .control_tick = 3, .input_order = 4, .accepted_control_frame = 512 },
        .deferred = .{ .reason = .odd_sequence, .handle = .{ .index = 2, .generation = 9 }, .observed_frame = null, .sequence_before = 17, .sequence_after = null },
    };
    attempt.evidence.outcome = .availability_unavailable;
    const owned = NativeDiagnostics.attemptSummary(&attempt, 512, false);
    attempt.deferred = null;
    attempt.evidence.outcome = .failed;
    try t.expectEqual(.availability_unavailable, owned.outcome);
    try t.expectEqual(.odd_sequence, owned.deferred.?.reason);
    try t.expectEqual(@as(?u64, 17), owned.deferred.?.sequence_before);
    try t.expect(!owned.runtime_finished and owned.selected == null and owned.accepted == null and owned.publication == null);
}

// Detached text fixtures exercise exactly the post-join writers. These are not
// native execution evidence and are never installed in an engine or observer.
const FlatFixture = struct {
    const position: Position = .{ .control_tick = 43, .input_order = 7, .accepted_control_frame = 12288 };
    const handle: stream.Handle = .{ .index = 2, .generation = 9 };
    const identity: NativeDiagnostics.JobIdentity = .{
        .slot = 7,
        .handle = handle,
        .descriptor = .{ .job = 101, .asset = 11, .generation = 13, .transport_epoch = 17, .operation = .decode, .group = 19, .layer = 23, .loop_epoch = 29, .target_cursor = 11264, .realize_frame = 31 },
        .ordinal = 1024,
        .count = 1024,
    };
    const worker: trace.schema.Worker = .{
        .job = 101,
        .asset = 11,
        .generation = 13,
        .transport_epoch = 17,
        .operation = .decode,
        .state = .ready,
        .pcm_start = 11264,
        .pcm_end = 12288,
        .available_frames = 1024,
        .channel_count = 2,
        .content_hash = @splat(0xab),
        .readiness_version = 37,
        .failure_code = 0,
        .group = 19,
        .layer = 23,
        .loop_epoch = 29,
        .target_cursor = 11264,
        .realize_frame = 31,
        .job_descriptor_hash = @splat(0xcd),
    };
    const observation: stream.LiveObservationDeferV1 = .{ .reason = .sequence_changed, .operation = .prefetch, .handle = handle, .requested_frame = 12288, .observed_frame = 12352, .sequence_before = 40, .sequence_after = 42 };
    const stop: f.music.MusicRuntime.LiveStopDeferV1 = .{
        .control_tick = 43,
        .accepted_control_frame = 12288,
        .ticket = .{ .context = 53, .request_id = 59, .bank = .{ .context = 53, .handle = .{ .index = 3, .generation = 61 }, .asset_generation = 13 } },
        .group = .{ .index = 5, .generation = 67 },
        .plan_id = 71,
        .prepare = .{ .start_frame = 12352, .end_frame = 12416, .observed_horizon = 12416, .minimum_frame = 12480 },
    };
    fn acceptance() NativeDiagnostics.Acceptance {
        var attempt: stream.LiveAcceptanceAttemptV1 = .{ .incoming = position };
        var result = NativeDiagnostics.attemptSummary(&attempt, 12352, true);
        result.batch_id = 55;
        result.outcome = .accepted;
        result.cut = .{ .sequence = 42, .frame = 12352, .consumed = 11264, .produced = 12288, .available = 1024 };
        result.selected = .{ .identity = identity, .outcome = .ready, .failure_code = 0 };
        result.availability = .{ .attached = true, .requested_frame = 12352, .sequence_before = 42, .frame = 12352, .consumed = 11264, .produced = 12288, .sequence_after = 42, .available = 1024 };
        result.ring_capacity = 4096;
        result.publication_preflight = .{ .head = 57, .tail = 56, .capacity = 64 };
        result.publication = .{ .batch_id = 55, .handle = handle, .worker_job = 101, .prefix_start = 11264, .prefix_end = 12288, .target_cursor = 11264, .loop_epoch = 29 };
        result.effects = .{ .pcm_published = true, .publication_published = true, .job_released = true };
        result.accepted = .{ .handle = handle, .position = position, .worker = worker };
        return result;
    }
    fn tokens(text: []const u8, expected: []const []const u8) !void {
        try t.expect(std.mem.indexOf(u8, text, "...") == null);
        try t.expect(std.mem.indexOf(u8, text, ".{") == null);
        for (expected) |token| {
            if (std.mem.indexOf(u8, text, token) == null) {
                std.debug.print("missing flat diagnostic token: {s}\n", .{token});
                return error.MissingFlatDiagnosticToken;
            }
        }
    }
};

test "flat role output preserves every event kind and deep causal identity without ellipsis" {
    var buffer: [32768]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const values = [_]NativeDiagnostics.ControlEvent{
        .{ .position = FlatFixture.position, .value = .{ .supply = .{ .point = .{ .stage = .request_queued, .handle = FlatFixture.handle, .job_slot = 7, .job = 101 }, .group = 19, .layer = 23, .pending_job = 7, .queued = FlatFixture.identity } } },
        .{ .position = FlatFixture.position, .value = .{ .supply_return = .{ .operation = .request, .handle = FlatFixture.handle, .nested_prefetch = true, .reason = .queued, .available = 0, .pending_observed = true, .job_slot = 7, .job = 101 } } },
        .{ .position = FlatFixture.position, .value = .{ .acceptance = FlatFixture.acceptance() } },
        .{ .position = FlatFixture.position, .value = .{ .public_worker = FlatFixture.worker } },
        .{ .position = FlatFixture.position, .value = .{ .admission = .{ .batch_id = 55, .content_hash = @splat(0xef), .kind = .stream_visibility, .gate = 73, .frame = 12416, .commit_horizon = 12480, .gate_order = 3, .disposition = .admitted } } },
        .{ .position = FlatFixture.position, .value = .{ .tick = .{ .drained = 1, .deferred = .{ .stage = .background_supply, .control_tick = 43, .accepted_control_frame = 12288, .observation = FlatFixture.observation }, .stop_deferred = FlatFixture.stop, .cold_start_deferred = FlatFixture.stop } } },
    };
    for (values, 0..) |value, i| try NativeDiagnostics.writeControlEvent(&writer, .{ .ordinal = i, .value = value });
    try NativeDiagnostics.writeWorkerEvent(&writer, .{ .ordinal = 4, .value = .{ .kind = .running, .job = 101, .identity = FlatFixture.identity } });
    try NativeDiagnostics.writeWorkerEvent(&writer, .{ .ordinal = 5, .value = .{ .kind = .completed, .job = 101 } });
    try FlatFixture.tokens(writer.buffered(), &.{
        "DEFAULT_HOST_CONTROL_EVENT schema=1 ordinal=0 position.accepted_control_frame=12288 position.control_tick=43 position.input_order=7 observed_clock.present=false observed_clock=null event.tag=supply",
        "event.supply.point.stage=request_queued",
        "event.supply.point.handle.generation=9",
        "event.supply.queued.present=true",
        "event.supply.queued.slot=7",
        "event.supply.queued.descriptor.job=101",
        "event.supply.queued.descriptor.target_cursor=11264",
        "event.supply.queued.ordinal=1024",
        "event.supply.queued.count=1024",
        "event.tag=supply_return",
        "event.supply_return.operation=request",
        "event.supply_return.reason=queued",
        "event.supply_return.available.present=true event.supply_return.available=0",
        "event.supply_return.pending_observed=true",
        "event.supply_return.pending_job.present=false event.supply_return.pending_job=null",
        "event.supply_return.returned_error.present=false",
        "event.supply_return.deferred.present=false",
        "event.tag=acceptance",
        "event.acceptance.cut.available=1024",
        "event.acceptance.selected.identity.handle.index=2",
        "event.acceptance.selected.identity.handle.generation=9",
        "event.acceptance.selected.identity.descriptor.job=101",
        "event.acceptance.selected.outcome=ready",
        "event.acceptance.availability.sequence_after=42",
        "event.acceptance.publication_preflight.capacity=64",
        "event.acceptance.publication.batch_id=55",
        "event.acceptance.publication.worker_job=101",
        "event.acceptance.publication.prefix_end=12288",
        "event.acceptance.accepted.worker.job=101",
        "event.acceptance.accepted.worker.job_descriptor_hash=" ++ "cd" ** 32,
        "event.tag=public_worker event.public_worker.job=101",
        "event.public_worker.content_hash=" ++ "ab" ** 32,
        "event.tag=admission event.admission.batch_id=55",
        "event.admission.content_hash=" ++ "ef" ** 32,
        "event.admission.kind=stream_visibility",
        "event.admission.disposition=admitted",
        "event.tag=tick",
        "event.tick.deferred.observation.handle.generation=9",
        "event.tick.deferred.observation.sequence_after=42",
        "event.tick.stop_deferred.ticket.bank.handle.generation=61",
        "event.tick.stop_deferred.group.generation=67",
        "event.tick.stop_deferred.prepare.observed_horizon=12416",
        "event.tick.cold_start_deferred.ticket.request_id=59",
        "event.tick.cold_start_deferred.prepare.minimum_frame=12480",
        "DEFAULT_HOST_WORKER_EVENT schema=1 ordinal=4 event.kind=running",
        "event.identity.descriptor.job=101",
        "event.identity.descriptor.generation=13",
        "event.identity.descriptor.layer=23",
        "event.identity.ordinal=1024",
        "event.identity.count=1024",
        "DEFAULT_HOST_WORKER_EVENT schema=1 ordinal=5 event.kind=completed",
        "event.identity.present=false event.identity=null",
    });
}

test "flat diagnostic return and defer output distinguishes absent from measured zero and errors" {
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var value: NativeDiagnostics.ControlEvent = .{ .position = FlatFixture.position, .value = .{ .supply_return = .{ .operation = .prefetch, .handle = FlatFixture.handle, .reason = .availability_error, .deferred = FlatFixture.observation, .returned_error = error.IncompleteTrace } } };
    try NativeDiagnostics.writeControlEvent(&writer, .{ .ordinal = 0, .value = value });
    var attempt: stream.LiveAcceptanceAttemptV1 = .{ .incoming = FlatFixture.position, .deferred = .{ .reason = .odd_sequence, .handle = FlatFixture.handle, .observed_frame = null, .sequence_before = 0, .sequence_after = null }, .returned_error = error.IncompleteTrace };
    attempt.evidence.outcome = .availability_unavailable;
    value.value = .{ .acceptance = NativeDiagnostics.attemptSummary(&attempt, 12288, false) };
    try NativeDiagnostics.writeControlEvent(&writer, .{ .ordinal = 1, .value = value });
    try FlatFixture.tokens(writer.buffered(), &.{
        "event.supply_return.available.present=false event.supply_return.available=null", "event.supply_return.pending_observed=false",                             "event.supply_return.deferred.present=true",       "event.supply_return.deferred.reason=sequence_changed", "event.supply_return.deferred.operation=prefetch",                                                      "event.supply_return.deferred.handle.index=2",                                                        "event.supply_return.returned_error.present=true event.supply_return.returned_error=IncompleteTrace",
        "event.acceptance.runtime_finished=false",                                        "event.acceptance.outcome=availability_unavailable",                      "event.acceptance.deferred.present=true",          "event.acceptance.deferred.reason=odd_sequence",        "event.acceptance.deferred.observed_frame.present=false event.acceptance.deferred.observed_frame=null", "event.acceptance.deferred.sequence_before.present=true event.acceptance.deferred.sequence_before=0", "event.acceptance.deferred.sequence_after.present=false",
        "event.acceptance.selected.present=false event.acceptance.selected=null",         "event.acceptance.accepted.present=false event.acceptance.accepted=null", "event.acceptance.returned_error=IncompleteTrace",
    });
}

test "flat runtime failure output retains actual fault identity and complete optional status" {
    var buffer: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const runtime: ?Probe.RuntimeDiagnostic = .{
        .status = .{ .context = 53, .kind = .authoring, .state = .playing, .bank = FlatFixture.stop.ticket.bank, .bank_content_hash = @splat(0xff), .committed_state = @enumFromInt(79), .committed_segment = @enumFromInt(83), .render_frame = 12416, .transport_epoch = 17, .pending = false, .outstanding_sample_leases = 4, .observation_sequence = 42, .complete = false, .dropped_observations = 0, .stream_fault_count = 1, .stream_fault = .{ .group_index = 5, .group_incarnation = 67, .asset_generation = 13, .segment = @enumFromInt(83), .boundary_frame = 12416, .last_sample_frame = 12415, .cursor = 11264, .loop_epoch = 29, .layer = 2 }, .source_switch = .{ .group_index = 5, .group_incarnation = 67, .asset_generation = 13, .original_segment = @enumFromInt(83), .fallback_segment = @enumFromInt(89), .frame = 12416, .cursor = 11264, .loop_epoch = 29, .layer = 2, .source_incarnation = 97 } },
        .control_delay_ms = 16,
        .tick = 43,
        .control_frame = 12288,
        .tick_frame = 12288,
        .chronology_frontier = 12288,
        .owner_observation_sequence = 42,
        .owner_stream_fault_count = 1,
        .pause_armed = true,
        .pause_used = true,
        .cancelled = false,
        .first = .{ .position = FlatFixture.position, .job = 101 },
        .later = null,
        .callbacks_before = 40,
        .callbacks_after = 42,
        .callbacks_at_failure = 48,
        .submitted_frames = 12288,
        .input_begin = 100,
        .input_count = 4,
        .schedule_begin = 10,
        .schedule_count = 2,
    };
    try FlatDiagnostic.line(&writer, "DEFAULT_HOST_RUNTIME_DIAGNOSTICS", "runtime", runtime);
    try FlatDiagnostic.line(&writer, "DEFAULT_HOST_PROBE_ERROR", "failure", @as(?anyerror, error.DefaultRuntimeDiagnostics));
    try FlatFixture.tokens(writer.buffered(), &.{
        "DEFAULT_HOST_RUNTIME_DIAGNOSTICS schema=1 runtime.present=true", "runtime.status.state=playing", "runtime.status.bank.handle.generation=61", "runtime.status.bank_content_hash=" ++ "ff" ** 32, "runtime.status.committed_state=unnamed runtime.status.committed_state.code=79", "runtime.status.complete=false", "runtime.status.stream_fault_count=1", "runtime.status.stream_fault.present=true", "runtime.status.stream_fault.group_index=5", "runtime.status.stream_fault.group_incarnation=67", "runtime.status.stream_fault.asset_generation=13", "runtime.status.stream_fault.segment.code=83", "runtime.status.stream_fault.boundary_frame=12416", "runtime.status.stream_fault.last_sample_frame=12415", "runtime.status.stream_fault.cursor.present=true runtime.status.stream_fault.cursor=11264", "runtime.status.stream_fault.loop_epoch=29", "runtime.status.stream_fault.layer=2", "runtime.status.source_switch.fallback_segment.code=89", "runtime.status.source_switch.source_incarnation=97", "runtime.first.position.input_order=7", "runtime.later.present=false runtime.later=null", "runtime.input_count=4", "failure.present=true failure=DefaultRuntimeDiagnostics",
    });
}

test "flat tail report emits retained ordinal order pinned failure and bounded truncation" {
    const diagnostics = try a.create(NativeDiagnostics);
    defer a.destroy(diagnostics);
    diagnostics.* = .{ .installed = true };
    for (0..NativeDiagnostics.control_capacity + 2) |_| diagnostics.control.append(.{ .position = FlatFixture.position, .value = .{ .tick = .{ .drained = 0 } } });
    diagnostics.worker.append(.{ .kind = .completed, .job = 101 });
    diagnostics.first_control_failure = .{ .next_ordinal = diagnostics.control.next, .position = FlatFixture.position, .failure = error.DefaultRuntimeDiagnostics };
    diagnostics.control_after_failure_omitted = 3;
    var writer: std.Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    try diagnostics.writeAfterJoin(&writer.writer);
    const text = writer.written();
    try FlatFixture.tokens(text, &.{
        "DEFAULT_HOST_EVENT_TAIL schema=1", "supply_return_observer=true", "reached_locals_only=true", "incomplete=true", "control_capacity=256 control_retained=256 control_next=258 control_overwritten=2", "control_after_failure_omitted=3", "worker_capacity=128", "DEFAULT_HOST_EVENT_FAILURE schema=1 failure.present=true failure.next_ordinal=258", "failure.position.control_tick=43", "failure.failure=DefaultRuntimeDiagnostics", "DEFAULT_HOST_CONTROL_EVENT schema=1 ordinal=2 ", "DEFAULT_HOST_CONTROL_EVENT schema=1 ordinal=257 ",
    });
    const first = std.mem.indexOf(u8, text, "DEFAULT_HOST_CONTROL_EVENT schema=1 ordinal=2 ").?;
    const last = std.mem.indexOf(u8, text, "DEFAULT_HOST_CONTROL_EVENT schema=1 ordinal=257 ").?;
    try t.expect(first < last);
    try t.expect(std.mem.indexOf(u8, text, "DEFAULT_HOST_CONTROL_EVENT schema=1 ordinal=0 ") == null);
    var tiny: [1]u8 = undefined;
    var bounded: std.Io.Writer = .fixed(&tiny);
    try t.expectError(error.WriteFailed, diagnostics.writeAfterJoin(&bounded));
    var hash_buffer: [128]u8 = undefined;
    var hashes: std.Io.Writer = .fixed(&hash_buffer);
    try FlatDiagnostic.line(&hashes, "TEST_HASH", "bytes", [_]u8{ 0, 1, 15, 16, 127, 128, 255 });
    try t.expectEqualStrings("TEST_HASH schema=1 bytes=00010f107f80ff\n", hashes.buffered());
}

// Detached projection/output tests, not fabricated native execution evidence.
test "acceptance scan projection and flat bytes distinguish unobserved partial and truncated states" {
    const Case = struct { scanned: usize, slots: usize };
    for ([_]Case{ .{ .scanned = 0, .slots = 257 }, .{ .scanned = 4, .slots = 257 }, .{ .scanned = 256, .slots = 257 }, .{ .scanned = 257, .slots = 257 }, .{ .scanned = 4, .slots = 2 } }) |case| {
        const scanned = case.scanned;
        var attempt: stream.LiveAcceptanceAttemptV1 = .{ .incoming = FlatFixture.position };
        attempt.evidence.job_slots = case.slots;
        attempt.evidence.scanned = scanned;
        attempt.evidence.representation_complete = scanned <= 256;
        // Non-free unused tail proves that projection ignores unobserved data.
        attempt.evidence.states = @splat(.completed);
        attempt.evidence.states[0] = .free;
        attempt.evidence.states[1] = .queued;
        attempt.evidence.states[2] = .running;
        const projected = NativeDiagnostics.attemptSummary(&attempt, 0, false);
        const valid_len = @min(scanned, case.slots, 256);
        try t.expectEqual(case.slots, projected.job_slots);
        try t.expectEqual(scanned, projected.scanned);
        try t.expectEqual(scanned <= 256, projected.representation_complete);
        try t.expectEqual(valid_len, projected.states_valid_len);
        try t.expectEqual(scanned > 256, projected.states_truncated);
        try t.expectEqual(scanned > case.slots, projected.states_inconsistent);
        try t.expectEqual(scanned <= 256 and scanned <= case.slots, projected.states_projection_complete);
        // Projection owns the copy, not a borrowed reference to the attempt.
        attempt.evidence.states = @splat(.free);
        var buffer: [8192]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try NativeDiagnostics.writeControlEvent(&writer, .{ .ordinal = 0, .value = .{ .position = FlatFixture.position, .value = .{ .acceptance = projected } } });
        const output = writer.buffered();
        const key = " event.acceptance.states=";
        const start = (std.mem.indexOf(u8, output, key) orelse return error.MissingFlatStates) + key.len;
        const end = start + 512;
        try t.expect(output.len > end and output[end] == ' ');
        for (0..256) |i| {
            const actual = try std.fmt.parseInt(u8, output[start + i * 2 ..][0..2], 16);
            const expected: u8 = if (i >= valid_len) 255 else if (i < 3) @intCast(i) else 3;
            try t.expectEqual(expected, projected.states[i]);
            try t.expectEqual(expected, actual);
        }
        var metadata: [512]u8 = undefined;
        const expected_metadata = try std.fmt.bufPrint(&metadata, "event.acceptance.job_slots={d} event.acceptance.scanned={d} event.acceptance.representation_complete={} event.acceptance.states_valid_len={d} event.acceptance.states_truncated={} event.acceptance.states_inconsistent={} event.acceptance.states_projection_complete={}", .{ case.slots, scanned, scanned <= 256, valid_len, scanned > 256, scanned > case.slots, scanned <= 256 and scanned <= case.slots });
        try FlatFixture.tokens(output, &.{expected_metadata});
    }
}

// Detached samples exercise passive copy/pairing and the actual post-join
// writer. They are never installed as clock inputs in a native engine.
test "passive diagnostic timing preserves raw samples missing errors ordering and exact output bytes" {
    const diagnostics = try a.create(NativeDiagnostics);
    defer a.destroy(diagnostics);
    diagnostics.* = .{};
    try t.expectEqual(@as(usize, 256), NativeDiagnostics.control_capacity);
    try t.expectEqual(@as(usize, 128), NativeDiagnostics.worker_capacity);
    diagnostics.worker_timing = .{ .job = 41 };
    NativeDiagnostics.workerClock(diagnostics, .begin, 41, .{ .value = 0, .available = true });
    NativeDiagnostics.workerClock(diagnostics, .end, 41, .{ .value = 17, .available = true });
    NativeDiagnostics.workerStage(diagnostics, .after_completed, 41);
    const zero = diagnostics.worker.at(0).value;
    try t.expectEqual(@as(u64, 0), zero.timing.?.begin.?.value);
    try t.expect(zero.timing.?.begin.?.available and !zero.timing.?.pair_invalid);
    diagnostics.worker_timing = .{ .job = 42 };
    NativeDiagnostics.workerClock(diagnostics, .begin, 42, .{ .value = 100, .available = true });
    NativeDiagnostics.workerClock(diagnostics, .end, 42, .{ .value = 90, .available = true });
    NativeDiagnostics.workerStage(diagnostics, .after_completed, 42);
    try t.expect(diagnostics.worker.at(1).value.timing.?.nonmonotonic);
    diagnostics.worker_timing = .{ .job = 43 };
    NativeDiagnostics.workerClock(diagnostics, .begin, 43, .{ .value = 0, .available = false });
    NativeDiagnostics.workerClock(diagnostics, .end, 43, .{ .value = 0, .available = true, .error_code = 1 });
    NativeDiagnostics.workerStage(diagnostics, .after_completed, 43);
    diagnostics.worker_timing = .{ .job = 44 };
    NativeDiagnostics.workerClock(diagnostics, .begin, 45, .{ .value = 999, .available = true });
    NativeDiagnostics.workerStage(diagnostics, .after_completed, 44);
    try t.expectEqual(@as(u64, 1), diagnostics.worker_timing_orphans);
    try t.expect(diagnostics.worker.at(3).value.timing.?.pair_invalid);
    try t.expect(diagnostics.worker.at(3).value.timing.?.begin == null);
    var output: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try diagnostics.writeAfterJoin(&writer);
    try FlatFixture.tokens(writer.buffered(), &.{
        "timing.completeness_asserted=false",
        "timing.units=ns",
        "timing.post_store_observation_not_store=true",
        "timing.worker_sample_interval_not_cpu_time=true",
        "event.job=41",
        "event.timing.begin.present=true event.timing.begin.value=0 event.timing.begin.available=true event.timing.begin.error_code=0",
        "event.timing.end.value=90",
        "event.timing.nonmonotonic=true",
        "event.timing.begin.value=0 event.timing.begin.available=false",
        "event.timing.end.value=0 event.timing.end.available=true event.timing.end.error_code=1",
        "event.timing.begin.present=false event.timing.begin=null",
        "event.timing.pair_invalid=true",
    });
    const Parser = struct {
        fn token(line: []const u8, key: []const u8) ![]const u8 {
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            while (words.next()) |word| {
                if (word.len > key.len and std.mem.startsWith(u8, word, key) and word[key.len] == '=') return word[key.len + 1 ..];
            }
            return error.MissingTimingField;
        }
        fn number(line: []const u8, key: []const u8) !u64 {
            return std.fmt.parseInt(u64, try token(line, key), 10);
        }
        fn boolean(line: []const u8, key: []const u8) !bool {
            const value = try token(line, key);
            if (std.mem.eql(u8, value, "true")) return true;
            if (std.mem.eql(u8, value, "false")) return false;
            return error.InvalidTimingBoolean;
        }
        fn sample(line: []const u8, comptime key: []const u8) !?stream.OfflineClockSample {
            if (!try boolean(line, key ++ ".present")) {
                try t.expectEqualStrings("null", try token(line, key));
                return null;
            }
            return .{ .value = try number(line, key ++ ".value"), .available = try boolean(line, key ++ ".available"), .error_code = @intCast(try number(line, key ++ ".error_code")) };
        }
    };
    var lines = std.mem.splitScalar(u8, writer.buffered(), '\n');
    var parsed_workers: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "DEFAULT_HOST_WORKER_EVENT ")) continue;
        const expected = diagnostics.worker.at(parsed_workers).value;
        try t.expectEqual(expected.job, try Parser.number(line, "event.job"));
        try t.expectEqualDeep(expected.timing.?.begin, try Parser.sample(line, "event.timing.begin"));
        try t.expectEqualDeep(expected.timing.?.end, try Parser.sample(line, "event.timing.end"));
        try t.expectEqual(expected.timing.?.pair_invalid, try Parser.boolean(line, "event.timing.pair_invalid"));
        try t.expectEqual(expected.timing.?.nonmonotonic, try Parser.boolean(line, "event.timing.nonmonotonic"));
        parsed_workers += 1;
    }
    try t.expectEqual(@as(usize, 4), parsed_workers);
    // Parse actual writer scalar, including padding/layout in the size delta.
    const key = " timing.storage_added_bytes=";
    const start = (std.mem.indexOf(u8, writer.buffered(), key) orelse return error.MissingTimingSize) + key.len;
    const stop = std.mem.indexOfScalarPos(u8, writer.buffered(), start, ' ') orelse return error.MissingTimingSizeEnd;
    const size = try std.fmt.parseInt(usize, writer.buffered()[start..stop], 10);
    try t.expectEqual(@sizeOf(NativeDiagnostics) - @sizeOf(NativeDiagnostics.LegacyDiagnostics), size);
    std.debug.print("DEFAULT_HOST_TIMING_STORAGE before={d} after={d} added={d} control_capacity=256 worker_capacity=128\n", .{ @sizeOf(NativeDiagnostics.LegacyDiagnostics), @sizeOf(NativeDiagnostics), size });
    writer = .fixed(&output);
    const value: NativeDiagnostics.ControlEvent = .{ .position = FlatFixture.position, .observed_clock = .{ .value = 123, .available = true }, .value = .{ .acceptance = FlatFixture.acceptance() } };
    try NativeDiagnostics.writeControlEvent(&writer, .{ .ordinal = 7, .value = value });
    try FlatFixture.tokens(writer.buffered(), &.{ "observed_clock.present=true observed_clock.value=123 observed_clock.available=true observed_clock.error_code=0", "event.tag=acceptance" });
    const control_line = std.mem.trimEnd(u8, writer.buffered(), "\n");
    try t.expectEqualDeep(value.observed_clock, try Parser.sample(control_line, "observed_clock"));
    var attempt: stream.LiveAcceptanceAttemptV1 = .{ .incoming = FlatFixture.position };
    NativeDiagnostics.acceptance(diagnostics, &attempt, 0, false);
    try t.expect(diagnostics.control.at(0).value.observed_clock == null);
    const unavailable = diagnostics.controlClock();
    try t.expect(!unavailable.available and unavailable.error_code == 0);
}

test "Host passive wait diagnostics preserve raw pairs unavailable errors mismatch and bounded tails" {
    const diagnostics = try a.create(NativeDiagnostics);
    defer a.destroy(diagnostics);
    diagnostics.* = .{};
    const early = diagnostics.waitSample();
    try t.expect(!early.clock_ready and !early.clock.available);
    diagnostics.clock_ready.store(true, .release); // published null Clock, no engine.
    const unavailable = diagnostics.waitSample();
    try t.expect(unavailable.clock_ready and !unavailable.clock.available);
    const before: live.TestWaitPoint = .{ .role = .worker, .edge = .before, .reason = .burst_budget, .calls = 4, .worked = 3, .requested_ms = 1 };
    var after = before;
    after.edge = .after;
    const Sample = WaitDiagnostics.Sample;
    const zero: Sample = .{ .clock_ready = true, .clock = .{ .value = 0, .available = true } };
    const later: Sample = .{ .clock_ready = true, .clock = .{ .value = 19, .available = true } };
    const failed: Sample = .{ .clock_ready = true, .clock = .{ .value = 0, .available = true, .error_code = 1 } };
    const state = &diagnostics.waits.worker;
    state.observe(before, early);
    state.observe(after, unavailable);
    state.observe(before, zero);
    state.observe(after, later);
    state.observe(before, later);
    state.observe(after, zero); // raw backwards observation, no delta/clamp.
    state.observe(before, failed);
    var mismatch = after;
    mismatch.requested_ms = 16;
    state.observe(mismatch, later);
    state.observe(after, later); // no before, no fabricated ID.
    state.observe(before, zero);
    state.observe(before, later); // missing after retained before replacement.
    state.observe(after, failed);
    state.next_id = std.math.maxInt(u64);
    state.observe(before, zero);
    state.observe(after, later);
    try t.expectEqual(@as(usize, 8), state.tail.len);
    try t.expect(state.id_exhausted);
    try t.expect(state.tail.at(2).value.nonmonotonic);
    try t.expect(state.tail.at(3).value.metadata_mismatch);
    try t.expect(state.tail.at(4).value.missing_before);
    try t.expect(state.tail.at(5).value.missing_after);
    try t.expect(state.tail.at(7).value.id == null);
    // Actual flat writer bytes round-trip every raw sample and reason flag.
    var output: [262144]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try diagnostics.waits.writeAfterJoin(&writer);
    const Parser = struct {
        fn token(line: []const u8, key: []const u8) ![]const u8 {
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            while (words.next()) |word| {
                if (word.len > key.len and std.mem.startsWith(u8, word, key) and word[key.len] == '=') return word[key.len + 1 ..];
            }
            return error.MissingWaitField;
        }
        fn number(line: []const u8, key: []const u8) !u64 {
            return std.fmt.parseInt(u64, try token(line, key), 10);
        }
        fn boolean(line: []const u8, key: []const u8) !bool {
            const value = try token(line, key);
            if (std.mem.eql(u8, value, "true")) return true;
            if (std.mem.eql(u8, value, "false")) return false;
            return error.InvalidWaitBoolean;
        }
        fn observation(line: []const u8, comptime key: []const u8, expected: ?WaitDiagnostics.Observation) !void {
            try t.expectEqual(expected != null, try boolean(line, key ++ ".present"));
            if (expected) |value| {
                try t.expectEqual(value.sample.clock_ready, try boolean(line, key ++ ".sample.clock_ready"));
                try t.expectEqual(value.sample.clock.value, try number(line, key ++ ".sample.clock.value"));
                try t.expectEqual(value.sample.clock.available, try boolean(line, key ++ ".sample.clock.available"));
                try t.expectEqual(value.sample.clock.error_code, try number(line, key ++ ".sample.clock.error_code"));
                try t.expectEqualStrings(@tagName(value.point.reason), try token(line, key ++ ".point.reason"));
                try t.expectEqualStrings(@tagName(value.point.mode), try token(line, key ++ ".point.mode"));
                try t.expectEqual(value.point.requested_ms, try number(line, key ++ ".point.requested_ms"));
                try t.expectEqual(value.point.calls, try number(line, key ++ ".point.calls"));
                try t.expectEqual(value.point.worked, try number(line, key ++ ".point.worked"));
                try t.expectEqual(value.point.failed, try number(line, key ++ ".point.failed"));
            } else try t.expectEqualStrings("null", try token(line, key));
        }
    };
    var lines = std.mem.splitScalar(u8, writer.buffered(), '\n');
    var parsed: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "DEFAULT_HOST_WAIT_EVENT ")) continue;
        try t.expectEqualStrings("worker", try Parser.token(line, "role"));
        const expected = state.tail.at(parsed);
        try t.expectEqual(expected.ordinal, try Parser.number(line, "ordinal"));
        try t.expectEqual(expected.value.id != null, try Parser.boolean(line, "pair.id.present"));
        if (expected.value.id) |id| try t.expectEqual(id, try Parser.number(line, "pair.id")) else try t.expectEqualStrings("null", try Parser.token(line, "pair.id"));
        try Parser.observation(line, "pair.before", expected.value.before);
        try Parser.observation(line, "pair.after", expected.value.after);
        inline for (.{ "missing_before", "missing_after", "metadata_mismatch", "pair_invalid", "nonmonotonic" }) |field| try t.expectEqual(@field(expected.value, field), try Parser.boolean(line, "pair." ++ field));
        parsed += 1;
    }
    try t.expectEqual(state.tail.len, parsed);
    var control_before = before;
    control_before.role = .control;
    var control_after = control_before;
    control_after.edge = .after;
    for (0..WaitDiagnostics.capacity + 2) |_| {
        diagnostics.waits.control.observe(control_before, zero);
        diagnostics.waits.control.observe(control_after, later);
    }
    try t.expectEqual(@as(usize, 64), diagnostics.waits.control.tail.len);
    try t.expectEqual(@as(u64, 2), diagnostics.waits.control.tail.overwritten);
    writer = .fixed(&output);
    try diagnostics.waits.writeAfterJoin(&writer);
    var overflow_lines = std.mem.splitScalar(u8, writer.buffered(), '\n');
    const overflow_header = overflow_lines.next().?;
    try t.expectEqual(@as(u64, 2), try Parser.number(overflow_header, "wait.overwritten"));
    try t.expectEqual(@as(u64, 64), try Parser.number(overflow_header, "wait.retained"));
    diagnostics.waits.control.observe(control_before, zero); // unfinished at join explicit.
    diagnostics.waits.control.tail.next = std.math.maxInt(u64);
    diagnostics.waits.control.observe(control_after, later);
    try t.expect(diagnostics.waits.control.tail.counter_exhausted);
    // Counter-exhaustion state is synthetic diagnostic-only; do not traverse it.
    diagnostics.waits.control = .{};
    diagnostics.waits.control.observe(control_before, zero);
    writer = .fixed(&output);
    try diagnostics.writeAfterJoin(&writer);
    try FlatFixture.tokens(writer.buffered(), &.{ "wait.pending.present=true", "wait.completeness_asserted=false", "wait.interval_not_pure_sleep=true", "storage.wait_capacity_per_role=64", "storage.control_capacity=256", "storage.worker_capacity=128" });
    var size_lines = std.mem.splitScalar(u8, writer.buffered(), '\n');
    var found_size = false;
    while (size_lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "DEFAULT_HOST_WAIT_STORAGE ")) continue;
        const added = try Parser.number(line, "storage.added_bytes");
        try t.expectEqual(@sizeOf(NativeDiagnostics) - @sizeOf(NativeDiagnostics.BeforeWaitDiagnostics), added);
        try t.expectEqual(@sizeOf(NativeDiagnostics), try Parser.number(line, "storage.after_bytes"));
        found_size = true;
        std.debug.print("DEFAULT_HOST_WAIT_STORAGE_TEST added={d} wait_capacity_per_role=64 control_capacity=256 worker_capacity=128\n", .{added});
    }
    try t.expect(found_size);
}

test "default fixture passive wait observer rejects semantic and legacy capture before owners" {
    const Noop = struct {
        fn call(_: *anyopaque, _: live.TestWaitPoint) void {}
    };
    var marker: u8 = 0;
    var session: live.semantic.Session = .{};
    // Deliberately uninitialized: options rejection precedes any capture borrow.
    const capture = try a.create(live.TestCapture.Session);
    defer a.destroy(capture);
    const observer: live.TestWaitObserver = .{ .context = &marker, .call = Noop.call };
    inline for (.{ @as(@FieldType(live.semantic.Session, "mode"), .capture), @as(@FieldType(live.semantic.Session, "mode"), .replay) }) |mode| {
        session.mode = mode;
        try t.expectError(error.InvalidState, live.Host.create(launch(&.{}), .{ .io = t.io, .device = .{ .backend = .null_backend }, .semantic = &session, .test_wait_observer = observer }));
    }
    try t.expectError(error.InvalidState, live.Host.create(launch(&.{}), .{ .io = t.io, .test_capture = capture, .test_wait_observer = observer }));
}
