//! Actual independently scheduled author Host. File mode is explicit and each
//! invocation performs only recording OR replay, never an in-process substitute.
const std = @import("std");
const live = @import("sme-author-live-owner");
const fixture = @import("sme-stream-reload-fixture");
const recording = live.semantic_recording;
const format = recording.format;
const t = std.testing;
const allocator = t.allocator;
const observation_ns = 60 * std.time.ns_per_s;

fn pause() void {
    std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
}
fn expired(start: anytype) bool {
    return start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds > observation_ns;
}
fn executableHash() !format.Hash {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const length = try std.process.executablePath(t.io, &path);
    const file = try std.Io.Dir.openFileAbsolute(t.io, path[0..length], .{ .mode = .read_only });
    defer file.close(t.io);
    var buffer: [65536]u8 = undefined;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositionalAll(t.io, &buffer, offset);
        if (count == 0) break;
        if (offset > format.max_file_bytes - count) return error.ExecutableBound;
        offset += count;
        digest.update(buffer[0..count]);
    }
    var result: format.Hash = undefined;
    digest.final(&result);
    return result;
}
fn buildBank() ![]u8 {
    const source = try std.mem.replaceOwned(u8, allocator, fixture.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer allocator.free(source);
    return fixture.buildSource(.a, source, null);
}
fn launch(bytes: []const u8) live.Launch {
    return .{ .document_id = 19, .revision = 7, .draft_hash = format.hash(fixture.authored_source), .state = fixture.state, .compiled = bytes };
}
fn identity(bytes: []const u8) !format.Identity {
    var loaded = try @import("sme-bank").MusicBank.load(allocator, bytes);
    defer loaded.deinit();
    return .{ .build = try executableHash(), .bank = loaded.content_hash, .source = format.hash(bytes), .config = try recording.codec.configHash(live.admission.default_config) };
}
fn drain(recorder: *recording.Recorder) !bool {
    var any = false;
    for (0..256) |_| {
        const progressed = if (recorder.streaming_writer != null) try recorder.drainStreaming() else try recorder.drain();
        if (!progressed) return any;
        any = true;
    }
    return any;
}
/// Deliberately controlled workload coverage, not a natural timing witness.
/// The audio wrapper only forwards actual events and increments a counter.
/// Only the separate test Control seam can sleep, for at most250ms once.
const ControlledCrossFrame = struct {
    recorder: *recording.Recorder,
    audio: live.audio.device.SemanticAudioSink,
    callback_returns: std.atomic.Value(u64) = .init(0),
    armed: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    exit: enum { not_entered, callbacks_observed, cancelled, capture_unhealthy, timeout, sleep_error } = .not_entered,
    used: bool = false, // Control only; inspected only after genuine joins.
    tick: u64 = 0,
    first_frame: u64 = 0,
    later_frame: ?u64 = null,
    callbacks_before: u64 = 0,
    callbacks_after: u64 = 0,
    fn onAudio(raw: *anyopaque, event: live.audio.device.SemanticAudioEvent) void {
        const self: *ControlledCrossFrame = @ptrCast(@alignCast(raw));
        self.audio.call(self.audio.context, event);
        if (event == .callback_return) _ = self.callback_returns.fetchAdd(1, .release);
    }
    fn afterAcceptance(raw: *anyopaque, tick: u64, frame: u64) void {
        const self: *ControlledCrossFrame = @ptrCast(@alignCast(raw));
        if (self.used) {
            if (tick == self.tick and frame > self.first_frame and self.later_frame == null) self.later_frame = frame;
            return;
        }
        if (!self.armed.load(.acquire) or self.cancelled.load(.acquire)) return;
        self.used = true;
        self.tick = tick;
        self.first_frame = frame;
        self.callbacks_before = self.callback_returns.load(.acquire);
        const began = std.Io.Clock.awake.now(t.io);
        while (self.callback_returns.load(.acquire) - self.callbacks_before < 2) {
            if (self.cancelled.load(.acquire)) {
                self.exit = .cancelled;
                return;
            }
            if (!self.recorder.healthy()) {
                self.exit = .capture_unhealthy;
                return;
            }
            if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 250 * std.time.ns_per_ms) {
                self.exit = .timeout;
                self.timed_out.store(true, .release);
                return;
            }
            std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {
                self.exit = .sleep_error;
                self.timed_out.store(true, .release);
                return;
            };
        }
        self.callbacks_after = self.callback_returns.load(.acquire);
        self.exit = .callbacks_observed;
    }
    // Only after real Host destruction/join. Never read Control-owned fields
    // from the still-running UI collector.
    fn report(self: *const ControlledCrossFrame, directory: std.Io.Dir, multi_frame_ticks: u64) !void {
        const bytes = try std.fmt.allocPrint(allocator, "{{\"classification\":\"controlled\",\"used\":{},\"pause_exit\":\"{s}\",\"tick\":{d},\"first_frame\":{d},\"same_tick_acceptance\":{},\"later_frame_or_zero\":{d},\"callback_returns_before\":{d},\"callback_returns_after\":{d},\"multi_frame_ticks\":{d}}}\n", .{ self.used, @tagName(self.exit), self.tick, self.first_frame, self.later_frame != null, self.later_frame orelse 0, self.callbacks_before, self.callbacks_after, multi_frame_ticks });
        defer allocator.free(bytes);
        try writeFile(directory, "controlled-cross-frame.json", bytes);
        std.debug.print("SEMANTIC_CONTROLLED_CROSS_FRAME {s}", .{bytes});
    }
};
// One test-only native scheduling workload. Neither Recorder callback waits:
// waiting is confined to the explicit test seam after the original operation.
const RetryWorkload = struct {
    const stream = fixture.rt.streaming.stream;
    const FailureReason = enum(u8) {
        none,
        test_cancel,
        capture_unhealthy,
        worker_not_ready,
        wait_worker_ready_timeout,
        wait_odd_timeout,
        wait_release_timeout,
        wait_even_timeout,
        wait_second_timeout,
        first_selected_missing,
        first_not_ready,
        first_finished,
        first_defer_missing,
        first_defer_not_odd,
        first_wrong_outcome,
        first_accepted,
        first_publication,
        first_effects,
        second_selected_missing,
        second_not_finished,
        second_deferred,
        second_cut_missing,
        second_incoming_changed,
        second_selected_changed,
        second_accepted_missing,
        second_stale,
        second_pcm_missing,
        second_publication_effect_missing,
        second_publication_missing,
        admission_rejected,
        admission_hash_mismatch,
    };
    recorder: *recording.Recorder,
    audio: live.audio.device.SemanticAudioSink,
    output: fixture.music.MusicRuntime.SemanticOutputSinkV1,
    armed: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    failure_reason: std.atomic.Value(FailureReason) = .init(.none),
    target: std.atomic.Value(u64) = .init(0),
    worker_ready: std.atomic.Value(bool) = .init(false),
    waiting_odd: std.atomic.Value(bool) = .init(false),
    odd_held: std.atomic.Value(bool) = .init(false),
    release_render: std.atomic.Value(bool) = .init(false),
    even_observed: std.atomic.Value(bool) = .init(false),
    second_attempt_returned: std.atomic.Value(bool) = .init(false),
    succeeded: std.atomic.Value(bool) = .init(false),
    admitted: std.atomic.Value(bool) = .init(false),
    callback_returns: std.atomic.Value(u64) = .init(0),
    nonzero_submitted_samples: std.atomic.Value(u64) = .init(0),
    // Single-role fields: Control owns attempts/admission, Render owns sequence.
    begun: bool = false,
    first: ?stream.LiveAcceptanceAttemptV1 = null,
    second: ?stream.LiveAcceptanceAttemptV1 = null,
    first_finished: bool = false,
    second_finished: bool = false,
    first_effective_frame: u64 = 0,
    second_effective_frame: u64 = 0,
    publication: @FieldType(stream.observation.Acceptance, "publication") = null,
    publication_hash: [32]u8 = undefined,
    admission_frame: u64 = 0,
    odd_sequence: u64 = 0,
    even_sequence: u64 = 0,
    render_used: bool = false,
    fn fail(self: *RetryWorkload, reason: FailureReason) void {
        _ = self.failure_reason.cmpxchgStrong(.none, reason, .acq_rel, .acquire);
        self.failed.store(true, .release);
        self.cancelled.store(true, .release);
        self.release_render.store(true, .release);
    }
    fn require(self: *RetryWorkload, condition: bool, reason: FailureReason) bool {
        if (!condition) self.fail(reason);
        return condition;
    }
    fn wait(self: *RetryWorkload, flag: *std.atomic.Value(bool), timeout_reason: FailureReason) bool {
        const began = std.Io.Clock.awake.now(t.io);
        while (!flag.load(.acquire)) {
            if (self.cancelled.load(.acquire)) return false;
            if (!self.recorder.healthy()) {
                self.fail(.capture_unhealthy);
                return false;
            }
            if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 500 * std.time.ns_per_ms) {
                self.fail(timeout_reason);
                return false;
            }
            pause();
        }
        return !self.cancelled.load(.acquire);
    }
    fn event(raw: *anyopaque, value: stream.TestRetryWorkloadEvent) void {
        const self: *RetryWorkload = @ptrCast(@alignCast(raw));
        if (!self.armed.load(.acquire) or self.cancelled.load(.acquire)) return;
        switch (value) {
            .queue_before => |queued| {
                if (self.target.load(.acquire) == 0) self.target.store(queued.job, .release);
            },
            .worker_completed => |completed| {
                if (completed.job == self.target.load(.acquire)) {
                    if (completed.outcome != .ready) self.fail(.worker_not_ready) else self.worker_ready.store(true, .release);
                }
            },
            .before_attempt => {
                if (self.begun or self.target.load(.acquire) == 0) return;
                self.begun = true;
                if (!self.wait(&self.worker_ready, .wait_worker_ready_timeout)) return;
                self.waiting_odd.store(true, .release);
                _ = self.wait(&self.odd_held, .wait_odd_timeout);
            },
            .render_odd => |sequence| {
                if (self.render_used or !self.waiting_odd.load(.acquire)) return;
                self.render_used = true;
                self.odd_sequence = sequence;
                self.odd_held.store(true, .release);
                _ = self.wait(&self.release_render, .wait_release_timeout);
            },
            .render_even => |sequence| {
                if (self.render_used and !self.even_observed.load(.acquire)) {
                    self.even_sequence = sequence;
                    self.even_observed.store(true, .release);
                    // A real even publication is not a stable window by itself.
                    // Hold this one test Render until the actual second attempt
                    // returns; no engine state or acceptance result is supplied.
                    _ = self.wait(&self.second_attempt_returned, .wait_second_timeout);
                }
            },
            .after_attempt => |actual| {
                if (!self.begun or self.second != null) return;
                if (self.first == null) {
                    self.first = actual.attempt.*;
                    self.first_finished = actual.finished;
                    self.first_effective_frame = actual.effective_frame;
                    if (!self.require(actual.attempt.evidence.selected != null, .first_selected_missing)) return;
                    if (!self.require(actual.attempt.evidence.selected.?.outcome == .ready, .first_not_ready)) return;
                    if (!self.require(!actual.finished, .first_finished)) return;
                    if (!self.require(actual.attempt.deferred != null, .first_defer_missing)) return;
                    if (!self.require(actual.attempt.deferred.?.reason == .odd_sequence, .first_defer_not_odd)) return;
                    if (!self.require(actual.attempt.evidence.outcome == .availability_unavailable, .first_wrong_outcome)) return;
                    if (!self.require(actual.attempt.evidence.accepted == null, .first_accepted)) return;
                    if (!self.require(actual.attempt.evidence.publication == null, .first_publication)) return;
                    if (!self.require(std.meta.eql(actual.attempt.evidence.effects, stream.observation.Effects{}), .first_effects)) return;
                    self.release_render.store(true, .release);
                    _ = self.wait(&self.even_observed, .wait_even_timeout);
                } else {
                    // Even failure/no-selection returns release the even hold.
                    defer self.second_attempt_returned.store(true, .release);
                    self.second = actual.attempt.*;
                    self.second_finished = actual.finished;
                    self.second_effective_frame = actual.effective_frame;
                    if (!self.require(actual.attempt.evidence.selected != null, .second_selected_missing)) return;
                    if (!self.require(actual.finished, .second_not_finished)) return;
                    if (!self.require(actual.attempt.deferred == null, .second_deferred)) return;
                    if (!self.require(actual.attempt.cut != null, .second_cut_missing)) return;
                    if (!self.require(std.meta.eql(self.first.?.incoming, actual.attempt.incoming), .second_incoming_changed)) return;
                    if (!self.require(std.meta.eql(self.first.?.evidence.selected, actual.attempt.evidence.selected), .second_selected_changed)) return;
                    if (!self.require(actual.attempt.evidence.accepted != null, .second_accepted_missing)) return;
                    if (!self.require(!actual.attempt.evidence.accepted.?.stale, .second_stale)) return;
                    if (!self.require(actual.attempt.evidence.effects.pcm_published, .second_pcm_missing)) return;
                    if (!self.require(actual.attempt.evidence.effects.publication_published, .second_publication_effect_missing)) return;
                    if (!self.require(actual.attempt.evidence.publication != null, .second_publication_missing)) return;
                    self.publication = actual.attempt.evidence.publication;
                    const canonical = fixture.rt.streaming.visibility.encode(self.publication.?);
                    self.publication_hash = format.hash(&canonical);
                    self.succeeded.store(true, .release);
                }
            },
        }
    }
    fn onInput(raw: *anyopaque, value: fixture.music.trace.Input) void {
        const self: *RetryWorkload = @ptrCast(@alignCast(raw));
        self.output.input(self.output.context, value);
        if (value.payload == .admission) if (self.publication) |publication| {
            const admission = value.payload.admission;
            if (admission.batch_id == publication.batch_id and admission.kind == .stream_visibility) {
                if (!self.require(admission.disposition == .admitted, .admission_rejected)) return;
                if (!self.require(std.mem.eql(u8, &admission.content_hash, &self.publication_hash), .admission_hash_mismatch)) return;
                self.admission_frame = admission.frame;
                self.admitted.store(true, .release);
            }
        };
    }
    fn onSchedule(raw: *anyopaque, value: fixture.music.trace.ScheduleEntry) void {
        const self: *RetryWorkload = @ptrCast(@alignCast(raw));
        self.output.schedule(self.output.context, value);
    }
    fn invalidate(raw: *anyopaque) void {
        const self: *RetryWorkload = @ptrCast(@alignCast(raw));
        self.output.invalidate(self.output.context);
    }
    fn onAudio(raw: *anyopaque, value: live.audio.device.SemanticAudioEvent) void {
        const self: *RetryWorkload = @ptrCast(@alignCast(raw));
        self.audio.call(self.audio.context, value);
        if (value == .callback_return) _ = self.callback_returns.fetchAdd(1, .release);
        if (value == .pcm and value.pcm.disposition == .submitted and self.admitted.load(.acquire)) {
            var nonzero: u64 = 0;
            for (value.pcm.samples) |sample| if (sample != 0) {
                nonzero += 1;
            };
            _ = self.nonzero_submitted_samples.fetchAdd(nonzero, .release);
        }
    }
    fn writeAttempt(writer: *std.Io.Writer, label: []const u8, value: ?stream.LiveAcceptanceAttemptV1, finished: bool, effective_frame: u64) !void {
        try writer.print("attempt={s} present={} finished={} effective_frame={d}", .{ label, value != null, finished, effective_frame });
        const attempt = value orelse {
            try writer.writeAll("\n");
            return;
        };
        const evidence = attempt.evidence;
        try writer.print(" incoming_frame={d} incoming_tick={d} incoming_order={d} outcome={s} returned_error_present={} returned_error={s} cut_present={} defer_present={} defer_reason={s}", .{ attempt.incoming.accepted_control_frame, attempt.incoming.control_tick, attempt.incoming.input_order, @tagName(evidence.outcome), attempt.returned_error != null, if (attempt.returned_error) |err| @errorName(err) else "null", attempt.cut != null, attempt.deferred != null, if (attempt.deferred) |d| @tagName(d.reason) else "null" });
        if (attempt.cut) |cut| try writer.print(" cut_sequence={d} cut_frame={d} cut_consumed={d} cut_produced={d} cut_available={d}", .{ cut.sequence, cut.frame, cut.consumed, cut.produced, cut.available });
        if (attempt.deferred) |d| try writer.print(" defer_handle_index={d} defer_handle_generation={d} defer_before_present={} defer_before={d} defer_after_present={} defer_after={d} defer_frame_present={} defer_frame={d}", .{ d.handle.index, d.handle.generation, d.sequence_before != null, d.sequence_before orelse 0, d.sequence_after != null, d.sequence_after orelse 0, d.observed_frame != null, d.observed_frame orelse 0 });
        try writer.print(" selected_present={}", .{evidence.selected != null});
        if (evidence.selected) |selected| {
            const job = selected.descriptor;
            try writer.print(" selected_job={d} selected_outcome={s} selected_slot={d} selected_handle_index={d} selected_handle_generation={d} selected_ordinal={d} selected_count={d} selected_failure_code={d} selected_hash={s} selected_asset={d} selected_generation={d} selected_epoch={d} selected_operation={s} selected_group={d} selected_layer={d} selected_loop_epoch={d} selected_target_cursor={d} selected_realize_frame={d}", .{ job.job, @tagName(selected.outcome), selected.slot, selected.handle.index, selected.handle.generation, selected.ordinal, selected.count, selected.failure_code, std.fmt.bytesToHex(selected.content_hash, .lower), job.asset, job.generation, job.transport_epoch, @tagName(job.operation), job.group, job.layer, job.loop_epoch, job.target_cursor, job.realize_frame });
        }
        try writer.print(" accepted_present={} accepted_stale_present={} accepted_stale={}", .{ evidence.accepted != null, evidence.accepted != null, if (evidence.accepted) |accepted| accepted.stale else false });
        if (evidence.accepted) |accepted| if (accepted.input.payload == .worker) try writer.print(" accepted_worker_job={d} accepted_worker_state={s}", .{ accepted.input.payload.worker.job, @tagName(accepted.input.payload.worker.state) });
        const effects = evidence.effects;
        try writer.print(" effect_stale_completion={} effect_pcm_published={} effect_publication_published={} effect_stream_failed={} effect_stream_cancelled={} effect_job_released={} effect_throughput_observation={} publication_present={}", .{ effects.stale_completion_counted, effects.pcm_published, effects.publication_published, effects.stream_failed, effects.stream_cancelled, effects.job_released, effects.throughput_observation_attempted, evidence.publication != null });
        if (evidence.publication) |publication| {
            const canonical = fixture.rt.streaming.visibility.encode(publication);
            try writer.print(" publication_batch={d} publication_worker_job={d} publication_slot={d} publication_generation={d} publication_prefix_start={d} publication_prefix_end={d} publication_cursor={d} publication_loop_epoch={d} publication_pcm_hash={s} publication_descriptor_hash={s}", .{ publication.batch_id, publication.worker_job, publication.stream_slot, publication.stream_generation, publication.prefix_start, publication.prefix_end, publication.target_cursor, publication.loop_epoch, std.fmt.bytesToHex(publication.pcm_hash, .lower), std.fmt.bytesToHex(format.hash(&canonical), .lower) });
        }
        try writer.writeAll("\n");
    }
    // Called only after actual Control and Worker joins and device stop.
    fn report(self: *const RetryWorkload, directory: std.Io.Dir) !void {
        const first = self.first;
        const second = self.second;
        const bytes = try std.fmt.allocPrint(allocator, "{{\"classification\":\"controlled_retry\",\"target_job\":{d},\"selected_job\":{d},\"worker_ready\":{},\"first_seen\":{},\"second_seen\":{},\"same_incoming\":{},\"odd_sequence\":{d},\"even_sequence\":{d},\"succeeded\":{},\"admitted\":{},\"admission_frame\":{d},\"prefix_start\":{d},\"prefix_end\":{d},\"nonzero_submitted_samples_after_admission\":{d},\"failed\":{},\"failure_reason\":\"{s}\",\"second_attempt_returned\":{}}}\n", .{ self.target.load(.acquire), if (first) |v| if (v.evidence.selected) |v_selected| v_selected.descriptor.job else 0 else 0, self.worker_ready.load(.acquire), first != null, second != null, if (first != null and second != null) std.meta.eql(first.?.incoming, second.?.incoming) else false, self.odd_sequence, self.even_sequence, self.succeeded.load(.acquire), self.admitted.load(.acquire), self.admission_frame, if (self.publication) |p| p.prefix_start else 0, if (self.publication) |p| p.prefix_end else 0, self.nonzero_submitted_samples.load(.acquire), self.failed.load(.acquire), @tagName(self.failure_reason.load(.acquire)), self.second_attempt_returned.load(.acquire) });
        defer allocator.free(bytes);
        try writeFile(directory, "controlled-retry.json", bytes);
        std.debug.print("SEMANTIC_CONTROLLED_RETRY {s}", .{bytes});
        var details: std.Io.Writer.Allocating = .init(allocator);
        defer details.deinit();
        try writeAttempt(&details.writer, "first", self.first, self.first_finished, self.first_effective_frame);
        try writeAttempt(&details.writer, "second", self.second, self.second_finished, self.second_effective_frame);
        try details.writer.print("selected_equal={} incoming_equal={}\n", .{ if (first != null and second != null) std.meta.eql(first.?.evidence.selected, second.?.evidence.selected) else false, if (first != null and second != null) std.meta.eql(first.?.incoming, second.?.incoming) else false });
        try writeFile(directory, "controlled-retry-attempts.txt", details.written());
        std.debug.print("SEMANTIC_CONTROLLED_RETRY_ATTEMPTS {s}", .{details.written()});
    }
};

const Workload = enum { long, short_ui, retry, short_play };
fn workload() !Workload {
    const value = std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_WORKLOAD") orelse "long";
    if (std.mem.eql(u8, value, "long")) return .long;
    if (std.mem.eql(u8, value, "short-ui")) return .short_ui;
    if (std.mem.eql(u8, value, "retry")) return .retry;
    if (std.mem.eql(u8, value, "short-play")) return .short_play;
    return error.UnsupportedSemanticWorkload;
}
fn requestedPacing() !live.PacingMode {
    const value = std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_PACING") orelse "legacy_poll";
    return std.meta.stringToEnum(live.PacingMode, value) orelse error.InvalidPacingMode;
}
fn requestedAdmission() !recording.codec.AdmissionPolicy {
    const value = std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_ADMISSION") orelse "native_attempt";
    return std.meta.stringToEnum(recording.codec.AdmissionPolicy, value) orelse error.InvalidAdmissionPolicy;
}
// Offline evidence inspection after genuine joins; never supplies runtime data.
const ReferenceCoverage = struct { public_inputs: u64 = 0, schedules: u64 = 0, submitted_samples: u64 = 0, nonzero_submitted_samples: u64 = 0 };
fn referenceCoverage(reader: *const format.Reader) !ReferenceCoverage {
    var result: ReferenceCoverage = .{};
    inline for (std.meta.fields(format.Role)) |field| {
        var cursor = recording.codec.ComparisonCursor.init(reader, @enumFromInt(field.value));
        while (try cursor.next()) |reference| {
            if (reference.family == @intFromEnum(recording.codec.Family.public_input)) result.public_inputs += 1;
            if (reference.family == @intFromEnum(recording.codec.Family.schedule)) result.schedules += 1;
            if (reference.family == @intFromEnum(recording.codec.Family.pcm)) {
                var d: recording.codec.Decoder = .{ .wire = .{ .bytes = reference.bytes } };
                const pcm = try d.get(recording.codec.Native(recording.codec.Pcm));
                for (0..pcm.value.samples) |_| {
                    const bits = try d.wire.int(u32);
                    if (pcm.value.disposition == .submitted) {
                        result.submitted_samples += 1;
                        if (bits & 0x7fffffff != 0) result.nonzero_submitted_samples += 1;
                    }
                }
                try d.wire.finish();
            }
        }
    }
    return result;
}
const ReceiptLog = struct {
    ids: [32]u64 = @splat(0),
    accepted: [32]bool = @splat(false),
    executed: [32]bool = @splat(false),
    terminal: [32]bool = @splat(false),
    acknowledged: [32]bool = @splat(false),
    defer_ack: [32]bool = @splat(false),
    cancelled: usize = 0,
    fn acknowledge(self: *ReceiptLog, host: *live.Host, index: usize) !void {
        try host.acknowledgeTerminal(self.ids[index]);
        self.acknowledged[index] = true;
    }
    fn releaseDeferred(self: *ReceiptLog, host: *live.Host) !void {
        self.defer_ack = @splat(false);
        for (self.terminal, 0..) |terminal, index| if (terminal and !self.acknowledged[index]) try self.acknowledge(host, index);
    }
    fn collect(self: *ReceiptLog, host: *live.Host) !void {
        while (host.popEvent()) |event| {
            const index: usize = for (self.ids, 0..) |id, i| {
                if (id != 0 and id == event.command.id) break i;
            } else return error.ForeignCommand;
            switch (event.kind) {
                .accepted => {
                    if (self.accepted[index] or self.terminal[index]) return error.DuplicateAccepted;
                    self.accepted[index] = true;
                },
                .terminal => {
                    if (self.terminal[index]) return error.DuplicateTerminal;
                    self.terminal[index] = true;
                    if (event.terminal == .cancelled) self.cancelled += 1;
                    if (event.receipt) |receipt| self.executed[index] = receipt.event == .terminal and receipt.event.terminal == .executed;
                    if (!self.defer_ack[index]) try self.acknowledge(host, index);
                },
            }
        }
    }
};
fn awaitTerminals(host: *live.Host, recorder: *recording.Recorder, receipts: *ReceiptLog, indices: []const usize) !void {
    const start = std.Io.Clock.awake.now(t.io);
    while (true) {
        const backlog = try drain(recorder);
        try receipts.collect(host);
        if (!recorder.healthy()) return error.SemanticCaptureIncomplete;
        if (host.readStatus()) |snapshot| if (snapshot.value.first_error) |err| return err;
        const complete = for (indices) |index| {
            if (!receipts.terminal[index]) break false;
        } else true;
        if (complete) return;
        if (expired(start)) return error.ShortFixtureTerminalTimedOut;
        if (!backlog) pause();
    }
}
fn shortUiWorkload(host: *live.Host, recorder: *recording.Recorder, receipts: *ReceiptLog) !void {
    // No Play: all events and reservations below come from real rejected Stop
    // commands. No ticket is injected and no original UI/Control execution is
    // gated by a recording callback. Any native startup/silence audio remains
    // in the transcript and must be matched normally during fresh replay.
    try t.expectEqual(@as(?live.Mailbox.Event, null), host.popEvent());
    var wrong = host.identity();
    wrong.epoch += 1;
    try t.expectError(error.InvalidEpoch, host.submit(wrong, .stop));
    try t.expectError(error.InvalidState, host.submit(host.identity(), .recover));
    try t.expectError(error.UnknownCommand, host.acknowledgeTerminal(0));
    try t.expectError(error.InvalidEpoch, host.requestClose(wrong.epoch));
    const first = try host.submit(host.identity(), .stop);
    receipts.ids[0] = first.id;
    receipts.defer_ack[0] = true;
    try t.expectEqual(@as(u8, 0), first.slot);
    try t.expectError(error.TerminalNotConsumed, host.acknowledgeTerminal(first.id));
    try awaitTerminals(host, recorder, receipts, &.{0});
    const second = try host.submit(host.identity(), .stop);
    receipts.ids[1] = second.id;
    receipts.defer_ack[1] = true;
    try t.expectEqual(@as(u8, 1), second.slot);
    try receipts.acknowledge(host, 0);
    const third = try host.submit(host.identity(), .stop);
    receipts.ids[2] = third.id;
    receipts.defer_ack[2] = true;
    try t.expectEqual(first.slot, third.slot);
    try awaitTerminals(host, recorder, receipts, &.{ 1, 2 });
    try receipts.acknowledge(host, 2);
    try receipts.acknowledge(host, 1);
    try t.expectError(error.UnknownCommand, host.acknowledgeTerminal(first.id));
    // All eight actual reservations remain occupied without a UI pop/ACK,
    // independent of whether Control already dequeued or rejected a command.
    for (3..11) |index| receipts.ids[index] = (try host.submit(host.identity(), .stop)).id;
    try t.expectError(error.QueueFull, host.submit(host.identity(), .stop));
    try host.requestClose(host.identity().epoch);
    try t.expectError(error.AdmissionClosed, host.submit(host.identity(), .stop));
    try host.requestClose(host.identity().epoch);
}
fn closeActual(host: *live.Host, recorder: *recording.Recorder, receipts: *ReceiptLog) !live.Status {
    // Cleanup retains IDs from actual popped terminals, including deferred ACKs.
    try receipts.releaseDeferred(host);
    try host.requestClose(host.identity().epoch);
    const start = std.Io.Clock.awake.now(t.io);
    while (true) {
        const backlog = drain(recorder) catch false;
        try receipts.collect(host);
        if (host.isClosed()) {
            host.join() catch |err| switch (err) {
                error.CleanupPending => {
                    if (!backlog) pause();
                    continue;
                },
            };
            const status = (host.readStatus() orelse return error.MissingClosedStatus).value;
            try receipts.collect(host);
            try host.acknowledgeClosed();
            try host.destroy();
            return status;
        }
        if (expired(start)) return error.ActualCleanupStillPending;
        if (!backlog) pause();
    }
}
fn writeFile(directory: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try directory.createFile(t.io, name, .{ .exclusive = true });
    defer file.close(t.io);
    try file.writeStreamingAll(t.io, bytes);
    try file.sync(t.io);
}
// Test-owned raw file adapter: fault injection is not a production FileSink
// option. All buffering and irreversible flush-error behavior is production code.
const FileStream = struct {
    file: std.Io.File,
    closed: bool = false,
    written: u64 = 0,
    fail_after: ?u64 = null,
    output: live.semantic_file.BufferedSink,
    profile: ?*recording.collector_profile.Profile = null,
    raw_requested_bytes: u64 = 0,
    raw_clock_calls: u64 = 0,
    raw_counter_overflow: bool = false,
    fn init(self: *@This(), file: std.Io.File, fail_after: ?u64) void {
        self.file = file;
        self.closed = false;
        self.written = 0;
        self.fail_after = fail_after;
        self.profile = null;
        self.raw_requested_bytes = 0;
        self.raw_clock_calls = 0;
        self.raw_counter_overflow = false;
        self.output = live.semantic_file.BufferedSink.init(.{ .context = self, .write = rawWrite });
    }
    fn rawWrite(raw: *anyopaque, bytes: []const u8) !usize {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const started = if (self.profile != null) std.Io.Clock.awake.now(t.io) else null;
        var acknowledged: u64 = 0;
        var succeeded = false;
        defer if (self.profile) |profile| {
            const elapsed = started.?.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds;
            profile.report.raw_write.observe(elapsed, succeeded, acknowledged);
            self.raw_requested_bytes = std.math.add(u64, self.raw_requested_bytes, bytes.len) catch overflow: {
                self.raw_counter_overflow = true;
                break :overflow std.math.maxInt(u64);
            };
            self.raw_clock_calls = std.math.add(u64, self.raw_clock_calls, 2) catch overflow: {
                self.raw_counter_overflow = true;
                break :overflow std.math.maxInt(u64);
            };
        };
        if (self.closed) return error.StreamFileClosed;
        var count = bytes.len;
        if (self.fail_after) |bound| {
            if (self.written >= bound) return error.InjectedStreamIoFailure;
            count = @intCast(@min(count, bound - self.written));
        }
        const n = try self.file.writeStreaming(t.io, &.{}, &.{bytes[0..count]}, 1);
        self.written += n;
        acknowledged = n;
        succeeded = true;
        return n;
    }
    fn write(raw: *anyopaque, bytes: []const u8) !usize {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.closed) return error.StreamFileClosed;
        const sink = self.output.binding();
        return sink.write(sink.context, bytes);
    }
    fn flush(self: *@This()) !void {
        if (self.closed) return error.StreamFileClosed;
        try self.output.flush();
    }
    fn close(self: *@This()) void {
        if (!self.closed) self.file.close(t.io);
        self.closed = true;
    }
};
fn collectorProfilingEnabled(value: ?[]const u8, streaming: bool, scenario: Workload, pacing: live.semantic_recording.semantic.PacingMode, policy: recording.codec.AdmissionPolicy, controlled: bool, fail_text: ?[]const u8) !bool {
    const text = value orelse return false;
    if (!std.mem.eql(u8, text, "1")) return error.InvalidCollectorProfileMode;
    if (!streaming or scenario != .long or pacing != .notified_v1 or policy != .ordered_job_scans or controlled or fail_text != null) return error.UnsupportedCollectorProfileScope;
    return true;
}
fn recordProcess(directory: std.Io.Dir) !void {
    const scenario = try workload();
    const pacing = try requestedPacing();
    const policy = try requestedAdmission();
    const writer_mode = std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_WRITER") orelse "memory";
    const streaming = std.mem.eql(u8, writer_mode, "stream");
    if (!streaming and !std.mem.eql(u8, writer_mode, "memory")) return error.UnsupportedSemanticWriter;
    const fail_text = std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_STREAM_FAIL_AFTER");
    if (!streaming and fail_text != null) return error.StreamingWriterRequired;
    const controlled_text = std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_CONTROLLED_CROSS_FRAME");
    const controlled = if (controlled_text) |text| if (std.mem.eql(u8, text, "1")) true else return error.InvalidControlledCrossFrameMode else false;
    if (controlled and (!streaming or scenario != .long or fail_text != null)) return error.UnsupportedControlledCrossFrameScope;
    if (scenario == .retry and (!streaming or controlled or fail_text != null)) return error.UnsupportedRetryWorkloadScope;
    if (scenario == .short_play and (!streaming or controlled or fail_text != null)) return error.UnsupportedShortPlayScope;

    const profiling = try collectorProfilingEnabled(std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_COLLECTOR_PROFILE"), streaming, scenario, pacing, policy, controlled, fail_text);
    const bytes = try buildBank();
    defer allocator.free(bytes);
    const memory = try allocator.create(live.TestAllocator);
    memory.* = .init;
    var memory_owned = true;
    defer if (memory_owned) {
        const result = memory.deinit();
        allocator.destroy(memory);
        if (result != .ok) @panic("actual Host leaked native custody");
    };
    const recorder = try allocator.create(recording.Recorder);
    recorder.address = null;
    recorder.session = .{};
    var recorder_owned = true;
    defer if (recorder_owned) allocator.destroy(recorder);
    var corpus: ?[]u8 = null;
    var corpus_owned = true;
    defer if (corpus_owned) {
        if (corpus) |storage| allocator.free(storage);
    };
    var retry_context: ?*RetryWorkload = null;
    var retry_owned = true;
    defer if (retry_owned) if (retry_context) |context| allocator.destroy(context);
    var cross_frame: ?*ControlledCrossFrame = null;
    var cross_frame_owned = true;
    defer if (cross_frame_owned) if (cross_frame) |context| allocator.destroy(context);
    var file_stream: ?*FileStream = null;
    var stream_owned = true;
    defer if (stream_owned) {
        if (file_stream) |sink| {
            sink.close();
            allocator.destroy(sink);
        }
    };
    const profile = if (profiling) try allocator.create(recording.collector_profile.Profile) else null;
    var profile_owned = true;
    defer if (profile_owned) if (profile) |value| allocator.destroy(value);
    if (profile) |value| value.* = .init(t.io);
    var profile_started = false;
    var profile_joined = false;
    var profile_complete = false;
    var profile_status: ?live.Status = null;
    // Registered before Host cleanup; runs after cleanup and before borrowed
    // Recorder/FileStream/Profile destruction on both success and failure.
    defer if (profile) |value| {
        if (profile_joined) value.snapshot(&recorder.capture, .joined);
        const report = std.json.Stringify.valueAlloc(allocator, .{
            .schema = "bugu.collector-profile/v1",
            .host_started = profile_started,
            .host_joined_destroyed = profile_joined,
            .recording_complete = profile_complete,
            .cleanup = if (profile_status) |status| .{
                .closed = status.phase == .closed,
                .worker_joined = status.worker_joined,
                .first_error = if (status.first_error) |err| @errorName(err) else null,
                .cleanup_error = if (status.cleanup_error) |err| @errorName(err) else null,
                .provider_opened = status.provider.opened,
                .provider_closed = status.provider.closed,
                .provider_live = status.provider.live,
                .sample_leases = status.sample_leases,
                .live_instances = status.live_instances,
                .play_executed = status.play_executed,
                .stop_executed = status.stop_executed,
            } else null,
            .stats = if (profile_joined) recorder.finalStats() else @as(?recording.Stats, null),
            .collector = value.report,
            .raw_requested_bytes = if (file_stream) |sink| sink.raw_requested_bytes else 0,
            .raw_clock_calls = if (file_stream) |sink| sink.raw_clock_calls else 0,
            .raw_counter_overflow = if (file_stream) |sink| sink.raw_counter_overflow else false,
            .append_may_include_raw_write = true,
            .raw_coverage = "all_attempts_including_final_flush",
            .append_coverage = "sampled_records",
            .raw_write_excludes_sync_close = true,
            .wall_time_is_not_cpu_time = true,
        }, .{}) catch null;
        if (report) |bytes_report| {
            defer allocator.free(bytes_report);
            if (writeFile(directory, "collector-profile.json", bytes_report)) |_| {
                std.debug.print("COLLECTOR_PROFILE joined={} complete={} bytes={d}\n", .{ profile_joined, profile_complete, bytes_report.len });
            } else |err| std.debug.print("COLLECTOR_PROFILE_REPORT_FAILED {s}\n", .{@errorName(err)});
        } else std.debug.print("COLLECTOR_PROFILE_REPORT_FAILED OutOfMemory\n", .{});
    };
    if (streaming) {
        const fail_after = if (fail_text) |text| try std.fmt.parseInt(u64, text, 10) else null;
        const sink = try allocator.create(FileStream);
        const file = directory.createFile(t.io, "history.incomplete.bin", .{ .exclusive = true }) catch |err| {
            allocator.destroy(sink);
            return err;
        };
        sink.init(file, fail_after);
        file_stream = sink;
        sink.profile = profile;
        try recorder.initStreamingWithPacing(try identity(bytes), .{ .context = sink, .write = FileStream.write }, format.max_file_bytes, @sizeOf(FileStream) + (if (profiling) @sizeOf(recording.collector_profile.Profile) else @as(usize, 0)) + (if (controlled) @sizeOf(ControlledCrossFrame) else @as(usize, 0)) + (if (scenario == .retry) @sizeOf(RetryWorkload) else @as(usize, 0)), pacing);
    } else {
        corpus = try allocator.alloc(u8, recording.default_corpus_bytes);
        try recorder.initWithPacing(try identity(bytes), corpus.?, pacing);
    }
    recorder.test_collector_profile = profile;
    if (controlled) {
        const context = try allocator.create(ControlledCrossFrame);
        context.* = .{ .recorder = recorder, .audio = recorder.session.config.audio };
        cross_frame = context;
        recorder.session.config.audio = .{ .context = context, .call = ControlledCrossFrame.onAudio };
    }
    if (scenario == .retry) {
        const context = try allocator.create(RetryWorkload);
        context.* = .{ .recorder = recorder, .audio = recorder.session.config.audio, .output = recorder.session.config.output };
        retry_context = context;
        recorder.session.config.audio = .{ .context = context, .call = RetryWorkload.onAudio };
        recorder.session.config.output = .{ .context = context, .input = RetryWorkload.onInput, .schedule = RetryWorkload.onSchedule, .invalidate = RetryWorkload.invalidate };
    }
    const host = try live.Host.createWithTestAllocator(memory, launch(bytes), .{ .io = t.io, .device = .{ .backend = .null_backend }, .semantic = &recorder.session, .test_retry_workload = if (retry_context) |context| .{ .context = context, .call = RetryWorkload.event } else null, .test_after_live_acceptance = if (cross_frame) |context| .{ .context = context, .call = ControlledCrossFrame.afterAcceptance } else null });
    profile_started = true;
    var host_alive = true;
    var receipts: ReceiptLog = .{};
    defer if (host_alive) {
        if (cross_frame) |context| context.cancelled.store(true, .release);
        if (retry_context) |context| {
            context.cancelled.store(true, .release);
            context.release_render.store(true, .release);
        }
        const cleanup = closeActual(host, recorder, &receipts);
        if (cleanup) |closed| {
            profile_joined = true;
            profile_status = closed;
            if (retry_context) |context| context.report(directory) catch |err| std.debug.print("SEMANTIC_RETRY_REPORT_FAILED {s}\n", .{@errorName(err)});
            if (cross_frame) |context| context.report(directory, recorder.finalStats().multi_frame_ticks) catch |err| std.debug.print("SEMANTIC_CONTROLLED_REPORT_FAILED {s}\n", .{@errorName(err)});
            std.debug.print("SEMANTIC_REJECTED_CAPTURE healthy={any} stats={any} cleanup_worker_joined={any} provider={any} leases={d} instances={d}\n", .{ recorder.healthy(), recorder.finalStats(), closed.worker_joined, closed.provider, closed.sample_leases, closed.live_instances });
        } else |err| {
            std.debug.print("SEMANTIC_REJECTED_CAPTURE cleanup_pending={s}\n", .{@errorName(err)});
            // A deadline/failure never grants permission to free retained roles.
            profile_owned = false;
            memory_owned = false;
            recorder_owned = false;
            corpus_owned = false;
            stream_owned = false;
            cross_frame_owned = false;
            retry_owned = false;
        }
    };
    try t.expectEqual(pacing, host.pacingMode());
    std.debug.print("SEMANTIC_PACING actual={s} policy={s} workload={s}\n", .{ @tagName(host.pacingMode()), @tagName(policy), @tagName(scenario) });
    if (scenario == .short_ui) {
        try shortUiWorkload(host, recorder, &receipts);
    } else {
        const start = std.Io.Clock.awake.now(t.io);
        var start_frames: ?u64 = null;
        var retry_admitted_frames: ?u64 = null;
        var last_ui_poll: ?@TypeOf(start) = null;
        while (true) {
            // Drain every collector pass, even while the UI cadence is closed.
            // An empty-mailbox poll is itself recorded UI work; tying it to
            // backlog throughput makes observation amplify the capture load.
            const backlog = try drain(recorder);
            if (!recorder.healthy()) return error.SemanticCaptureIncomplete;
            if (cross_frame) |context| if (context.timed_out.load(.acquire)) return error.ControlledCrossFrameTimedOut;
            if (retry_context) |context| if (context.failed.load(.acquire)) return error.ControlledRetryFailed;
            const now = std.Io.Clock.awake.now(t.io);
            const poll_ui = if (last_ui_poll) |last| last.durationTo(now).nanoseconds >= std.time.ns_per_ms else true;
            if (poll_ui) {
                last_ui_poll = now;
                try receipts.collect(host);
                if (host.readStatus()) |snapshot| {
                    const status = snapshot.value;
                    if (status.first_error) |err| {
                        std.debug.print("semantic Host failure {s} at {s}, cleanup={any}\n", .{ @errorName(err), @tagName(status.first_error_site), status.cleanup_error });
                        return err;
                    }
                    if (status.phase == .ready and receipts.ids[0] == 0) receipts.ids[0] = (try host.submit(host.identity(), .play)).id;
                    const progress = recorder.progress();
                    if (status.play_executed and receipts.executed[0]) {
                        if (start_frames == null) start_frames = progress.submitted_frames;
                        if (retry_context) |context| if (context.callback_returns.load(.acquire) != 0) context.armed.store(true, .release);
                        if (cross_frame) |context| if (context.callback_returns.load(.acquire) != 0) context.armed.store(true, .release);
                    }
                    if (start_frames) |base| {
                        // Natural cross-frame ticks are reported coverage, not
                        // a reason to extend or retry an otherwise valid run.
                        if (scenario == .long) {
                            if (receipts.ids[1] == 0 and progress.submitted_frames >= base + 32768) receipts.ids[1] = (try host.submit(host.identity(), .stop)).id;
                        } else if (scenario == .short_play) {
                            // Independent minimal protocol loop. No forced timing
                            // hooks and no substitution for long >=32768 coverage.
                            if (receipts.ids[1] == 0 and progress.submitted_frames >= base + 8192) receipts.ids[1] = (try host.submit(host.identity(), .stop)).id;
                            if (progress.submitted_frames > base + 16384) return error.ShortPlayFrameBound;
                        } else if (retry_context) |context| {
                            if (context.succeeded.load(.acquire) and context.admitted.load(.acquire) and retry_admitted_frames == null) retry_admitted_frames = progress.submitted_frames;
                            if (retry_admitted_frames) |admitted_at| {
                                if (receipts.ids[1] == 0 and progress.submitted_frames >= admitted_at + 8192) receipts.ids[1] = (try host.submit(host.identity(), .stop)).id;
                            }
                            // Independent short workload bound, never extend the
                            // old long fixture or keep recording to seek luck.
                            if (progress.submitted_frames > base + 24576) return error.ControlledRetryFrameBound;
                        }
                    }
                    if (receipts.executed[1] and status.stop_executed) break;
                }
            }
            if (expired(start)) return error.SemanticPlaybackObservationTimedOut;
            if (!backlog) pause();
        }
    }
    if (cross_frame) |context| context.cancelled.store(true, .release);
    if (retry_context) |context| {
        context.cancelled.store(true, .release);
        context.release_render.store(true, .release);
    }
    const status = try closeActual(host, recorder, &receipts);
    host_alive = false;
    profile_joined = true;
    profile_status = status;
    try t.expect(status.worker_joined and status.phase == .closed);
    try t.expectEqual(@as(usize, 0), status.provider.live);
    try t.expectEqual(status.provider.opened, status.provider.closed);
    try t.expectEqual(@as(u64, 0), status.sample_leases);
    try t.expectEqual(@as(u64, 0), status.live_instances);
    // These exact-workload witnesses belong to this two-command fixture, not
    // production validity for every finite Play/Stop/Close/UI-attempt history.
    if (scenario == .long) {
        if (!status.play_executed or !status.stop_executed or !receipts.accepted[0] or !receipts.accepted[1] or
            !receipts.terminal[0] or !receipts.terminal[1] or !receipts.executed[0] or !receipts.executed[1]) return error.LongFixtureCommandWitnessMissing;
    } else if (scenario == .retry) {
        if (!status.play_executed or !status.stop_executed or !receipts.accepted[0] or !receipts.accepted[1] or
            !receipts.terminal[0] or !receipts.terminal[1] or !receipts.executed[0] or !receipts.executed[1]) return error.RetryFixtureCommandWitnessMissing;
        const context = retry_context.?;
        try context.report(directory);
        if (context.failed.load(.acquire) or !context.succeeded.load(.acquire) or !context.admitted.load(.acquire) or
            !context.worker_ready.load(.acquire) or context.nonzero_submitted_samples.load(.acquire) == 0 or
            context.even_sequence <= context.odd_sequence) return error.RetryFixtureWitnessMissing;
    } else if (scenario == .short_play) {
        if (!status.play_executed or !status.stop_executed or !receipts.accepted[0] or !receipts.accepted[1] or
            !receipts.terminal[0] or !receipts.terminal[1] or !receipts.executed[0] or !receipts.executed[1]) return error.ShortPlayCommandWitnessMissing;
    } else {
        if (status.play_executed or status.stop_executed) return error.ShortFixtureUnexpectedPlayback;
        for (0..11) |index| if (!receipts.terminal[index] or !receipts.acknowledged[index]) return error.ShortFixtureTerminalWitnessMissing;
        std.debug.print("SEMANTIC_SHORT_UI actual_submitted=11 actual_cancelled={d} deferred_ack=true slot_reuse=true queue_full=true\n", .{receipts.cancelled});
    }
    var readback_storage: ?[]u8 = null;
    defer if (readback_storage) |storage| allocator.free(storage);
    const sealed = if (file_stream) |sink| sealed: {
        const seal = try recorder.finishStreaming();
        try sink.flush();
        try sink.file.sync(t.io);
        sink.close();
        const storage = try directory.readFileAlloc(t.io, "history.incomplete.bin", allocator, .limited(format.max_file_bytes));
        readback_storage = storage;
        try t.expectEqual(seal.bytes, storage.len);
        try t.expectEqualSlices(u8, &seal.hash, storage[storage.len - 32 ..]);
        break :sealed storage;
    } else try recorder.finish();
    const stats = recorder.finalStats();
    if (cross_frame) |context| {
        try context.report(directory, stats.multi_frame_ticks);
        if (!context.used) return error.ControlledCrossFrameSeamUnreached;
        if (context.exit != .callbacks_observed or context.callbacks_after < context.callbacks_before + 2) return error.ControlledCrossFramePauseIncomplete;
        if (context.later_frame == null) return error.ControlledCrossFrameSecondAcceptanceAbsent;
        if (stats.multi_frame_ticks == 0) return error.ControlledCrossFrameTapeWitnessAbsent;
    }
    if (scenario == .long) {
        if (stats.command_submitted != 2 or stats.command_terminal != 2 or stats.terminal_acknowledged != 2) return error.LongFixtureCommandWitnessMissing;
        if (stats.submitted_frames < 32768 or stats.ui_calls == 0) return error.LongFixtureDurationWitnessMissing;
    } else if (scenario == .retry) {
        if (stats.command_submitted != 2 or stats.command_terminal != 2 or stats.terminal_acknowledged != 2 or stats.submitted_frames < 8192) return error.RetryFixtureCommandWitnessMissing;
    } else if (scenario == .short_play) {
        if (stats.command_submitted != 2 or stats.command_terminal != 2 or stats.terminal_acknowledged != 2 or stats.submitted_frames < 8192) return error.ShortPlayCommandWitnessMissing;
    } else {
        if (stats.command_submitted != 11 or stats.command_terminal != 11 or stats.terminal_acknowledged != 11) return error.ShortFixtureCommandWitnessMissing;
        // No Play is not a promise of zero native startup/silence audio.
        // Recorder/codec seal and the fresh driver verify all actual PCM.
    }
    const readback = try format.Reader.preflight(sealed, recorder.identity, recording.codec.validate);
    try t.expect(readback.counts.total > 0);
    const coverage = try referenceCoverage(&readback);
    if (scenario == .short_play and (coverage.public_inputs == 0 or coverage.schedules == 0 or coverage.nonzero_submitted_samples == 0)) return error.ShortPlayOutputWitnessMissing;
    std.debug.print("SEMANTIC_REFERENCE_COVERAGE public_inputs={d} schedules={d} submitted_samples={d} nonzero_submitted_samples={d}\n", .{ coverage.public_inputs, coverage.schedules, coverage.submitted_samples, coverage.nonzero_submitted_samples });
    const admission_result = recording.codec.validateInputsWithPolicy(&readback, recorder.identity, policy);
    const semantic_admitted = if (admission_result) |admitted| admitted: {
        std.debug.print("SEMANTIC_ADMISSION unresolved_scalar_overlaps={d} exact_replay_verified=false\n", .{admitted.unresolved_scalar_overlaps});
        break :admitted true;
    } else |_| false;
    try writeFile(directory, "bank.bin", bytes);
    if (streaming) {
        // A write/flush/readback/admission failure never publishes history.bin.
        // Keep uncertain temporary bytes for diagnosis, without a success report.
        _ = try admission_result;
        try directory.renamePreserve("history.incomplete.bin", directory, "history.bin", t.io);
        std.debug.print("SEMANTIC_STREAM finalized=true bytes={d} resident_capture_bytes={d}\n", .{ sealed.len, stats.allocation_bytes });
    } else try writeFile(directory, "history.bin", sealed);
    const report = try std.fmt.allocPrint(allocator, "{{\"profile\":9,\"wire_version\":{d},\"pacing\":\"{s}\",\"admission\":\"{s}\",\"framing_complete\":true,\"semantic_admitted\":{},\"fresh_replay_verified\":false,\"controlled_cross_frame\":{},\"submitted_frames\":{d},\"generated_frames\":{d},\"multi_frame_ticks\":{d},\"corpus_bytes\":{d},\"capture_allocation_bytes\":{d},\"occurrences\":{d},\"control_joined\":true,\"worker_joined\":true,\"control_thread\":{d},\"worker_thread\":{d},\"callback_thread\":{d},\"peak_records\":[{d},{d},{d},{d}],\"peak_bytes\":[{d},{d},{d},{d}],\"source_opened\":{d},\"source_closed\":{d}}}\n", .{ format.wire_version, @tagName(pacing), @tagName(policy), semantic_admitted, controlled, stats.submitted_frames, stats.generated_frames, stats.multi_frame_ticks, stats.corpus_bytes, stats.allocation_bytes, stats.occurrences, stats.control_thread_id, stats.worker_thread_id, stats.callback_thread_id, stats.lanes[0].peak_records, stats.lanes[1].peak_records, stats.lanes[2].peak_records, stats.lanes[3].peak_records, stats.lanes[0].peak_bytes, stats.lanes[1].peak_bytes, stats.lanes[2].peak_bytes, stats.lanes[3].peak_bytes, status.provider.opened, status.provider.closed });
    defer allocator.free(report);
    try writeFile(directory, "record-result.json", report);
    std.debug.print("SEMANTIC_RECORD {s}", .{report});
    profile_complete = true;
    _ = admission_result catch |err| {
        std.debug.print("SEMANTIC_RECORD_NOT_ADMITTED reason={s}\n", .{@errorName(err)});
        return err;
    };
}

fn replayProcess(directory: std.Io.Dir) !void {
    if (std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_COLLECTOR_PROFILE") != null) return error.CollectorProfileForbiddenDuringReplay;
    if (std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_CONTROLLED_CROSS_FRAME") != null) return error.ControlledPauseForbiddenDuringReplay;
    const scenario = try workload();
    const pacing = try requestedPacing();
    const policy = try requestedAdmission();
    const bytes = try directory.readFileAlloc(t.io, "bank.bin", allocator, .limited(format.max_file_bytes));
    var retained = false;
    defer if (!retained) allocator.free(bytes);
    const tape = try directory.readFileAlloc(t.io, "history.bin", allocator, .limited(format.max_file_bytes));
    defer if (!retained) allocator.free(tape);
    const expected_identity = try identity(bytes);
    const reader = try allocator.create(format.Reader);
    defer if (!retained) allocator.destroy(reader);
    reader.* = try format.Reader.preflight(tape, expected_identity, recording.codec.validate);
    const driver = try allocator.create(live.semantic_replay.Driver);
    driver.* = .{};
    defer if (!retained) allocator.destroy(driver);
    try driver.initWithPolicy(reader, expected_identity, t.io, policy);
    std.debug.print("SEMANTIC_PREFLIGHT admitted=true owner_effects_started=false\n", .{});
    const result = driver.runWithPacing(launch(bytes), .{ .backend = .null_backend }, pacing);
    retained = driver.running;
    if (result) |report| {
        if (scenario == .long) {
            if (report.command_submitted != 2 or report.command_accepted != 2 or report.command_terminal != 2 or report.terminal_acknowledged != 2) return error.LongFixtureCommandWitnessMissing;
            if (report.pcm_samples[@intFromEnum(live.audio.device.SemanticAudioPcmDisposition.submitted)] < 32768 * 2) return error.LongFixtureDurationWitnessMissing;
            if (!report.final_status.?.play_executed or !report.final_status.?.stop_executed) return error.LongFixtureCommandWitnessMissing;
        } else if (scenario == .retry) {
            if (report.command_submitted != 2 or report.command_accepted != 2 or report.command_terminal != 2 or report.terminal_acknowledged != 2 or
                !report.final_status.?.play_executed or !report.final_status.?.stop_executed or
                report.pcm_samples[@intFromEnum(live.audio.device.SemanticAudioPcmDisposition.submitted)] < 8192 * 2) return error.RetryFixtureCommandWitnessMissing;
        } else if (scenario == .short_play) {
            if (report.command_submitted != 2 or report.command_accepted != 2 or report.command_terminal != 2 or report.terminal_acknowledged != 2 or
                !report.final_status.?.play_executed or !report.final_status.?.stop_executed or
                report.pcm_samples[@intFromEnum(live.audio.device.SemanticAudioPcmDisposition.submitted)] < 8192 * 2) return error.ShortPlayCommandWitnessMissing;
            const coverage = try referenceCoverage(reader);
            if (coverage.public_inputs == 0 or coverage.schedules == 0 or coverage.nonzero_submitted_samples == 0) return error.ShortPlayOutputWitnessMissing;
            // Driver compares these canonical real outputs as well as all PCM,
            // UI outcomes and role EOF. These are not execution inputs.
            try t.expect(report.eof and report.host_joined and report.host_destroyed);
            std.debug.print("SEMANTIC_VERIFIED_REFERENCE_COVERAGE public_inputs={d} schedules={d} nonzero_submitted_samples={d} pacing={s}\n", .{ coverage.public_inputs, coverage.schedules, coverage.nonzero_submitted_samples, @tagName(pacing) });
        } else {
            if (report.command_submitted != 11 or report.command_accepted != 0 or report.command_terminal != 11 or report.terminal_acknowledged != 11) return error.ShortFixtureCommandWitnessMissing;
            if (report.final_status.?.play_executed or report.final_status.?.stop_executed) return error.ShortFixtureUnexpectedPlayback;
            // Match the captured startup/silence PCM normally, without imposing
            // a synthetic zero-callback or zero-frame requirement.
        }
        try t.expect(report.ui_calls > 0 and report.matched[3] > 0);
        const text = try std.fmt.allocPrint(allocator, "{{\"profile\":9,\"wire_version\":{d},\"pacing\":\"{s}\",\"admission\":\"{s}\",\"fresh_replay_verified\":true,\"matched_control\":{d},\"matched_worker\":{d},\"matched_render\":{d},\"matched_ui\":{d},\"submitted_samples\":{d},\"discarded_pending_samples\":{d},\"discarded_generated_samples\":{d},\"command_accepted\":{d},\"command_terminal\":{d},\"host_joined\":{},\"host_destroyed\":{},\"eof\":{}}}\n", .{ format.wire_version, @tagName(pacing), @tagName(policy), report.matched[0], report.matched[1], report.matched[2], report.matched[3], report.pcm_samples[0], report.pcm_samples[1], report.pcm_samples[2], report.command_accepted, report.command_terminal, report.host_joined, report.host_destroyed, report.eof });
        defer allocator.free(text);
        try writeFile(directory, "replay-result.json", text);
        std.debug.print("SEMANTIC_REPLAY {s}", .{text});
    } else |err| {
        std.debug.print("SEMANTIC_REPLAY_REJECTED reason={s} failure={any} report={any} retained={any}\n", .{ @errorName(err), driver.failure_value, driver.report, retained });
        return err;
    }
}

test "actual semantic Host process explicitly records or replays persisted history" {
    const mode = std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_MODE") orelse return error.SkipZigTest;
    const output = std.process.Environ.getPosix(t.environ, "SME_LIVE_SEMANTIC_DIR") orelse return error.SemanticDirectoryRequired;
    if (!std.fs.path.isAbsolute(output)) return error.SemanticAbsoluteDirectoryRequired;
    var directory = try std.Io.Dir.openDirAbsolute(t.io, output, .{ .follow_symlinks = false });
    defer directory.close(t.io);
    if (std.mem.eql(u8, mode, "record")) try recordProcess(directory) else if (std.mem.eql(u8, mode, "replay")) try replayProcess(directory) else return error.UnsupportedSemanticProcessMode;
}

test "collector file staging flushes exact bytes across fixed buffer boundaries" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var sink: FileStream = undefined;
    sink.init(try tmp.dir.createFile(t.io, "staged.bin", .{ .exclusive = true }), null);
    defer sink.close();
    const expected = try allocator.alloc(u8, sink.output.buffer.len * 2 + 71);
    defer allocator.free(expected);
    for (expected, 0..) |*byte, i| byte.* = @truncate(i * 19);
    var accepted: usize = 0;
    while (accepted < expected.len) accepted += try FileStream.write(&sink, expected[accepted..]);
    try t.expectEqual(@as(u64, sink.output.buffer.len * 2), sink.written);
    try t.expectEqual(@as(usize, 71), sink.output.buffered);
    try sink.flush();
    try sink.file.sync(t.io);
    sink.close();
    const actual = try tmp.dir.readFileAlloc(t.io, "staged.bin", allocator, .limited(expected.len + 1));
    defer allocator.free(actual);
    try t.expectEqual(expected.len, actual.len);
    try t.expectEqualSlices(u8, expected, actual);
}

test "collector final flush failure follows accepted buffered writes and preserves partial file" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var sink: FileStream = undefined;
    sink.init(try tmp.dir.createFile(t.io, "incomplete.bin", .{ .exclusive = true }), 13);
    defer sink.close();
    const payload = "buffered bytes not yet persisted to disk";
    try t.expectEqual(payload.len, try FileStream.write(&sink, payload));
    try t.expectEqual(@as(u64, 0), sink.written);
    try t.expectError(error.InjectedStreamIoFailure, sink.flush());
    try t.expectEqual(@as(u64, 13), sink.written);
    try t.expectError(error.InjectedStreamIoFailure, sink.flush());
    try t.expectError(error.InjectedStreamIoFailure, FileStream.write(&sink, "retry"));
    try t.expectEqual(@as(u64, 13), sink.written);
    sink.close();
    const actual = try tmp.dir.readFileAlloc(t.io, "incomplete.bin", allocator, .limited(payload.len));
    defer allocator.free(actual);
    try t.expectEqualSlices(u8, payload[0..13], actual);
}

test "production collector FileSink finalizes exact bytes and close is idempotent" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var sink: live.semantic_file.FileSink = undefined;
    sink.init(t.io, try tmp.dir.createFile(t.io, "production.bin", .{ .exclusive = true }));
    defer sink.close();
    const binding = sink.binding();
    const expected = "production collector file bytes";
    try t.expectEqual(expected.len, try binding.write(binding.context, expected));
    try sink.syncAndClose();
    try t.expect(sink.failure() == null);
    try t.expectError(error.StreamFileClosed, binding.write(binding.context, "late"));
    sink.close();
    const actual = try tmp.dir.readFileAlloc(t.io, "production.bin", allocator, .limited(expected.len + 1));
    defer allocator.free(actual);
    try t.expectEqual(expected.len, actual.len);
    try t.expectEqualSlices(u8, expected, actual);
}

test "UI transcript dispatch preserves native errors empty polls and reservation pressure" {
    try live.semantic_replay.UiTranscriptRegression.actualCallsAndComparisonOnlyResults(false);
}

test "UI result mismatch rejects without substituting a native error or ACK" {
    try live.semantic_replay.UiTranscriptRegression.actualCallsAndComparisonOnlyResults(true);
}

test "failed UI terminal pop keeps actual credit available for native cleanup" {
    try live.semantic_replay.UiTranscriptRegression.failedPopRetainsCleanupCredit();
}

test "launch argument mismatches reject before admission owner or native threads" {
    const driver = try allocator.create(live.semantic_replay.Driver);
    defer allocator.destroy(driver);
    driver.* = .{};
    // Isolate the pre-owner run guard. No Reader/Io/identity/native session is
    // initialized; reaching admission or Host creation would be a test bug.
    driver.address = driver;
    const original = launch("not an admitted bank");
    const device: live.audio.device.DeviceConfig = .{ .backend = .null_backend };
    driver.launch_descriptor = .{ .document_id = original.document_id, .revision = original.revision, .draft_hash = original.draft_hash, .state = original.state, .device = device };
    var changed = original;
    changed.document_id += 1;
    try t.expectError(error.WrongLaunch, driver.run(changed, device));
    changed = original;
    changed.revision += 1;
    try t.expectError(error.WrongLaunch, driver.run(changed, device));
    changed = original;
    changed.draft_hash[0] ^= 1;
    try t.expectError(error.WrongLaunch, driver.run(changed, device));
    changed = original;
    changed.state = @enumFromInt(@intFromEnum(original.state) + 1);
    try t.expectError(error.WrongLaunch, driver.run(changed, device));
    var wrong_device = device;
    wrong_device.period_frames = 128;
    try t.expectError(error.UnsupportedValue, driver.run(original, wrong_device));
    // Different supported backend also cannot reuse a launch descriptor.
    driver.launch_descriptor.device.backend = .system;
    try t.expectError(error.WrongLaunch, driver.run(original, device));
    driver.launch_descriptor.device = device;
    driver.launch_descriptor.pacing = .notified_v1;
    try t.expectError(error.WrongLaunch, driver.run(original, device));
    try t.expectError(error.WrongLaunch, driver.runWithPacing(original, device, .legacy_poll));
    driver.launch_descriptor.pacing = .legacy_poll;
    try t.expectError(error.WrongLaunch, driver.runWithPacing(original, device, .notified_v1));
    try t.expect(!driver.running and !driver.completed and !driver.report.host_joined and !driver.report.host_destroyed);
    try t.expect(driver.session.address == null);
}

test "retry workload rejects noncapture nonnull recovery and hidden service binding before owner creation" {
    const Noop = struct {
        fn event(_: *anyopaque, _: fixture.rt.streaming.stream.TestRetryWorkloadEvent) void {}
        fn acceptance(_: *anyopaque, _: u64, _: u64) void {}
    };
    var marker: u8 = 0;
    const hook: fixture.rt.streaming.stream.TestRetryWorkload = .{ .context = &marker, .call = Noop.event };
    var memory: live.TestAllocator = .init;
    defer {
        if (memory.deinit() != .ok) @panic("rejected retry workload allocated retained ownership");
    }
    // A genuinely initialized Recorder gives a fully defined Session, while
    // an empty bank proves these policy errors precede bank/owner admission.
    const recorder = try allocator.create(recording.Recorder);
    defer allocator.destroy(recorder);
    recorder.address = null;
    recorder.session = .{};
    var corpus: [4096]u8 = undefined;
    try recorder.init(.{ .build = @splat(1), .bank = @splat(2), .config = @splat(3), .source = @splat(4) }, &corpus);
    const session = &recorder.session;
    const invalid_launch = launch(&.{});
    try t.expectError(error.InvalidState, live.Host.createWithTestAllocator(&memory, invalid_launch, .{ .io = t.io, .device = .{ .backend = .null_backend }, .test_retry_workload = hook }));
    session.mode = .replay;
    try t.expectError(error.InvalidState, live.Host.createWithTestAllocator(&memory, invalid_launch, .{ .io = t.io, .device = .{ .backend = .null_backend }, .semantic = session, .test_retry_workload = hook }));
    session.mode = .capture;
    try t.expectError(error.InvalidState, live.Host.createWithTestAllocator(&memory, invalid_launch, .{ .io = t.io, .device = .{ .backend = .system }, .semantic = session, .test_retry_workload = hook }));
    try t.expectError(error.InvalidState, live.Host.createWithTestAllocator(&memory, invalid_launch, .{ .io = t.io, .device = .{ .backend = .null_backend }, .semantic = session, .recovery = .restart_at_bar, .test_retry_workload = hook }));
    try t.expectError(error.InvalidState, live.Host.createWithTestAllocator(&memory, invalid_launch, .{ .io = t.io, .device = .{ .backend = .null_backend }, .semantic = session, .test_retry_workload = hook, .test_after_live_acceptance = .{ .context = &marker, .call = Noop.acceptance } }));
    // A caller cannot smuggle the blocking seam through the passive config.
    session.config.service.test_retry_workload = hook;
    try t.expectError(error.InvalidState, live.Host.createWithTestAllocator(&memory, invalid_launch, .{ .io = t.io, .device = .{ .backend = .null_backend }, .semantic = session }));
    try t.expect(session.host == null and !session.used);
    var coordinator: RetryWorkload = .{ .recorder = recorder, .audio = session.config.audio, .output = session.config.output };
    var unmet: std.atomic.Value(bool) = .init(false);
    coordinator.fail(.test_cancel);
    coordinator.fail(.wait_second_timeout);
    try t.expect(!coordinator.wait(&unmet, .wait_second_timeout));
    try t.expect(coordinator.cancelled.load(.acquire) and coordinator.release_render.load(.acquire));
    try t.expectEqual(RetryWorkload.FailureReason.test_cancel, coordinator.failure_reason.load(.acquire));
}

test "retry attempt diagnostic writes actual flat fields and propagates truncated output" {
    var value: fixture.rt.streaming.stream.LiveAcceptanceAttemptV1 = .{ .incoming = .{ .accepted_control_frame = 4864, .control_tick = 66, .input_order = 1 } };
    value.evidence.outcome = .availability_unavailable;
    value.deferred = .{ .reason = .odd_sequence, .handle = .{ .index = 3, .generation = 4 }, .observed_frame = null, .sequence_before = 155, .sequence_after = null };
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try RetryWorkload.writeAttempt(&output.writer, "second", value, false, 4864);
    const text = output.written();
    for ([_][]const u8{ "attempt=second present=true finished=false", "incoming_tick=66 incoming_order=1", "outcome=availability_unavailable", "defer_reason=odd_sequence", "defer_before_present=true defer_before=155", "selected_present=false", "accepted_present=false accepted_stale_present=false", "effect_pcm_published=false effect_publication_published=false", "publication_present=false" }) |needle| try t.expect(std.mem.indexOf(u8, text, needle) != null);
    var tiny: [8]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&tiny);
    try t.expectError(error.WriteFailed, RetryWorkload.writeAttempt(&fixed, "second", value, false, 4864));
}

test "collector profiling is explicit long notified strict streaming scope only" {
    try t.expect(!try collectorProfilingEnabled(null, false, .short_ui, .legacy_poll, .native_attempt, false, null));
    try t.expect(try collectorProfilingEnabled("1", true, .long, .notified_v1, .ordered_job_scans, false, null));
    try t.expectError(error.InvalidCollectorProfileMode, collectorProfilingEnabled("0", true, .long, .notified_v1, .ordered_job_scans, false, null));
    try t.expectError(error.UnsupportedCollectorProfileScope, collectorProfilingEnabled("1", false, .long, .notified_v1, .ordered_job_scans, false, null));
    inline for (.{ Workload.short_ui, Workload.short_play, Workload.retry }) |scenario| {
        try t.expectError(error.UnsupportedCollectorProfileScope, collectorProfilingEnabled("1", true, scenario, .notified_v1, .ordered_job_scans, false, null));
    }
    try t.expectError(error.UnsupportedCollectorProfileScope, collectorProfilingEnabled("1", true, .long, .legacy_poll, .ordered_job_scans, false, null));
    try t.expectError(error.UnsupportedCollectorProfileScope, collectorProfilingEnabled("1", true, .long, .notified_v1, .native_attempt, false, null));
    try t.expectError(error.UnsupportedCollectorProfileScope, collectorProfilingEnabled("1", true, .long, .notified_v1, .ordered_job_scans, true, null));
    try t.expectError(error.UnsupportedCollectorProfileScope, collectorProfilingEnabled("1", true, .long, .notified_v1, .ordered_job_scans, false, "13"));
}

test "collector raw profile preserves real partial write and sticky failure" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const profile = try allocator.create(recording.collector_profile.Profile);
    defer allocator.destroy(profile);
    profile.* = .init(t.io);
    var sink: FileStream = undefined;
    sink.init(try tmp.dir.createFile(t.io, "profile-partial.bin", .{ .exclusive = true }), 13);
    defer sink.close();
    sink.profile = profile;
    const payload = "bounded profiler observes original partial write";
    try t.expectEqual(payload.len, try FileStream.write(&sink, payload));
    try t.expectEqual(@as(u64, 0), profile.report.raw_write.population);
    try t.expectError(error.InjectedStreamIoFailure, sink.flush());
    try t.expectEqual(@as(u64, 2), profile.report.raw_write.population);
    try t.expectEqual(@as(u64, 2), profile.report.raw_write.sample_count);
    try t.expectEqual(@as(u64, 1), profile.report.raw_write.errors);
    try t.expectEqual(@as(u64, 13), profile.report.raw_write.bytes);
    try t.expectEqual(@as(u64, 4), sink.raw_clock_calls);
    try t.expect(!sink.raw_counter_overflow);
    try t.expectEqual(@as(u64, payload.len * 2 - 13), sink.raw_requested_bytes);
    try t.expectError(error.InjectedStreamIoFailure, sink.flush());
    try t.expectEqual(@as(u64, 2), profile.report.raw_write.population);
    sink.close();
    const actual = try tmp.dir.readFileAlloc(t.io, "profile-partial.bin", allocator, .limited(payload.len));
    defer allocator.free(actual);
    try t.expectEqualSlices(u8, payload[0..13], actual);
}
