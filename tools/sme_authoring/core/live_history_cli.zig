//! Original UI workload plus immutable-tape replay, without test dependencies.
//! Profile9/v4 pins launch pacing, actual job predicates, and finite admission.
const std = @import("std");
const live = @import("sme-author-live-owner");
const recording = live.semantic_recording;
const codec = recording.codec;
const format = recording.format;
const replay = live.semantic_replay;
const FileSink = live.semantic_file.FileSink;
const max_script_bytes = 64 * 1024;
const json_arena_bytes = 256 * 1024;
const max_actions = 256;
const Mode = enum { record, replay };
const Options = struct {
    mode: Mode,
    admission: codec.AdmissionPolicy = .native_attempt,
    pacing: live.PacingMode = .legacy_poll,
    bank: []const u8,
    state: u64,
    script: ?[]const u8 = null,
    out: ?[]const u8 = null,
    tape: ?[]const u8 = null,
    action_cap: usize = max_actions,
    file_cap: u64 = format.max_file_bytes,
    capture_cap: usize = format.max_capture_bytes,
    deadline_ms: u64 = 60_000,
    frame_limit: u64 = 0,
};
const Action = struct {
    kind: enum { play, stop, pop, ack, close },
    at_frame: u64 = 0,
    at_ms: u64 = 0,
    ready: bool = false,
    command_id: u64 = 0,
};
const Script = struct { auto_events: bool = true, actions: []const Action };
fn number(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10) catch error.InvalidArgument;
}
fn options(args: []const []const u8) !Options {
    if (args.len == 0) return error.MissingMode;
    const mode = std.meta.stringToEnum(Mode, args[0]) orelse return error.InvalidMode;
    var bank: ?[]const u8 = null;
    var state: ?u64 = null;
    var result: Options = .{ .mode = mode, .bank = "", .state = 0 };
    var seen: u32 = 0;
    var i: usize = 1;
    const names = [_][]const u8{ "--bank", "--state", "--script", "--out", "--tape", "--action-cap", "--file-cap", "--capture-cap", "--deadline-ms", "--frame-limit", "--sample-rate", "--channels", "--period-frames", "--admission", "--pacing" };
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingArgument;
        var key: ?usize = null;
        for (names, 0..) |name, n| if (std.mem.eql(u8, name, args[i])) {
            key = n;
            break;
        };
        const n = key orelse return error.UnknownArgument;
        const bit = @as(u32, 1) << @as(u5, @intCast(n));
        if (seen & bit != 0) return error.DuplicateArgument;
        seen |= bit;
        const value = args[i + 1];
        switch (n) {
            0 => bank = value,
            1 => state = try number(u64, value),
            2 => result.script = value,
            3 => result.out = value,
            4 => result.tape = value,
            5 => result.action_cap = try number(usize, value),
            6 => result.file_cap = try number(u64, value),
            7 => result.capture_cap = try number(usize, value),
            8 => result.deadline_ms = try number(u64, value),
            9 => result.frame_limit = try number(u64, value),
            10 => if (try number(u32, value) != 48_000) return error.UnsupportedDeviceConfiguration,
            11 => if (try number(u16, value) != 2) return error.UnsupportedDeviceConfiguration,
            12 => if (try number(u32, value) != 256) return error.UnsupportedDeviceConfiguration,
            13 => result.admission = std.meta.stringToEnum(codec.AdmissionPolicy, value) orelse return error.InvalidAdmissionPolicy,
            14 => result.pacing = std.meta.stringToEnum(live.PacingMode, value) orelse return error.InvalidPacingMode,
            else => unreachable,
        }
    }
    result.bank = bank orelse return error.MissingBank;
    result.state = state orelse return error.MissingState;
    if (result.action_cap == 0 or result.action_cap > max_actions or result.file_cap > format.max_file_bytes or result.file_cap < format.header_size + format.trailer_size or result.capture_cap > format.max_capture_bytes or result.deadline_ms == 0 or result.deadline_ms > 60_000 or result.frame_limit > recording.max_generated_frames) return error.InvalidBudget;
    switch (mode) {
        .record => if (result.script == null or result.out == null or result.tape != null) return error.InvalidArgument,
        .replay => if (result.tape == null or result.script != null or result.out != null or result.frame_limit != 0 or seen & ((1 << 5) | (1 << 7) | (1 << 8)) != 0) return error.UnsupportedReplayOption,
    }
    return result;
}
fn executableHash(io: std.Io) !format.Hash {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.executablePath(io, &path);
    const file = try std.Io.Dir.openFileAbsolute(io, path[0..len], .{ .mode = .read_only });
    defer file.close(io);
    var buffer: [65536]u8 = undefined;
    var sha = format.IntegrityHasher.init(.{});
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buffer, offset);
        if (n == 0) break;
        if (offset > format.max_file_bytes - n) return error.ExecutableBound;
        offset += n;
        sha.update(buffer[0..n]);
    }
    var hash: format.Hash = undefined;
    sha.final(&hash);
    return hash;
}
fn pause(io: std.Io) void {
    std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
}
// True means the finite work batch was exhausted, not that producers stopped.
// A busy collector must immediately get another batch instead of imposing a
// one-millisecond sleep on every 256 passes (up to four records per pass).
fn drain(recorder: anytype) !bool {
    for (0..256) |_| if (!try recorder.drainStreaming()) return false;
    return true;
}
// UI policy has its own cadence. Faster collection must not create extra empty
// event polls, accelerate script submissions, or amplify cleanup ACK attempts.
const UiCadence = struct {
    next_ns: i128 = 0,
    fn due(self: *UiCadence, elapsed_ns: i128) bool {
        if (elapsed_ns < self.next_ns) return false;
        self.next_ns = elapsed_ns + std.time.ns_per_ms;
        return true;
    }
};
fn captureFailure(recorder: *const recording.Recorder, err: anyerror, output: *std.Io.Writer) !void {
    // Producers may still be alive. Never call finalStats or read byte_write
    // here: only atomic fields and sole-consumer output state are safe.
    try output.print("live.capture_failure error={s} recorder_failed={any} session_poisoned={any} output_error={s}\n", .{ @errorName(err), recorder.failed.load(.acquire), recorder.session.poisoned.load(.acquire), if (recorder.first_output_error) |failure| @errorName(failure) else "none" });
    for (&recorder.capture.lanes, 0..) |*lane, i| {
        try output.print("live.capture_lane role={s} poison={s} peak_bytes={d} peak_records={d}\n", .{ @tagName(@as(format.Role, @enumFromInt(i))), @tagName(lane.failure()), lane.peak_bytes.load(.monotonic), lane.peak_records.load(.monotonic) });
    }
}
fn reportCaptureFailure(io: std.Io, recorder: *const recording.Recorder, err: anyerror) void {
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
    captureFailure(recorder, err, &stderr.interface) catch {};
    stderr.interface.flush() catch {};
}
// A successful closeActual return follows real join, Closed acknowledgment and
// destruction. This reports that actual result, not capture validity or EOF.
fn captureCleanup(result: anyerror!live.Status, output: *std.Io.Writer) !void {
    if (result) |status| {
        try output.print("live.capture_cleanup native_teardown_complete=true host_joined=true host_destroyed=true retained=false phase={s} worker_joined={any} provider_opened={d} provider_closed={d} provider_live={d} sample_leases={d} live_instances={d} first_error={s} cleanup_error={s}\n", .{ @tagName(status.phase), status.worker_joined, status.provider.opened, status.provider.closed, status.provider.live, status.sample_leases, status.live_instances, if (status.first_error) |err| @errorName(err) else "none", if (status.cleanup_error) |err| @errorName(err) else "none" });
    } else |err| {
        try output.print("live.capture_cleanup native_teardown_complete=false retained=true error={s} host_joined=unknown host_destroyed=unknown\n", .{@errorName(err)});
    }
}
fn reportCaptureCleanup(io: std.Io, result: anyerror!live.Status) void {
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
    captureCleanup(result, &stderr.interface) catch {};
    stderr.interface.flush() catch {};
}
// Only called after Driver.run returned with native producer exclusion. These
// are observed failure/cleanup facts, never replay inputs or a success report.
fn replayFailure(err: anyerror, failure: ?replay.Failure, report: replay.Report, output: *std.Io.Writer) !void {
    try output.print("live.replay_failure error={s}\n", .{@errorName(err)});
    if (failure) |value| {
        try output.print("live.replay_mismatch reason={s} role={s} occurrence={d} family={s} byte_offset={any} expected_family={s} expected_tag={any} actual_tag={any}\n", .{ @errorName(value.reason), @tagName(value.role), value.occurrence, if (value.family) |family| @tagName(family) else "none", value.byte_offset, if (value.expected_family) |family| @tagName(family) else "none", value.expected_tag, value.actual_tag });
    } else try output.writeAll("live.replay_mismatch unavailable=no_recorded_failure\n");
    try output.print("live.replay_cleanup host_joined={any} host_destroyed={any} eof={any} command_submitted={d} command_accepted={d} command_terminal={d} terminal_acknowledged={d} matched={any} pcm_samples={any}\n", .{ report.host_joined, report.host_destroyed, report.eof, report.command_submitted, report.command_accepted, report.command_terminal, report.terminal_acknowledged, report.matched, report.pcm_samples });
    if (report.final_status) |status| {
        try output.print("live.replay_status phase={s} worker_joined={any} provider_opened={d} provider_closed={d} provider_live={d} sample_leases={d} live_instances={d} first_error={s} cleanup_error={s}\n", .{ @tagName(status.phase), status.worker_joined, status.provider.opened, status.provider.closed, status.provider.live, status.sample_leases, status.live_instances, if (status.first_error) |failure_| @errorName(failure_) else "none", if (status.cleanup_error) |failure_| @errorName(failure_) else "none" });
    } else try output.writeAll("live.replay_status unavailable=no_final_status\n");
}
fn reportReplayFailure(io: std.Io, driver: *const replay.Driver, err: anyerror) void {
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
    const retained = driver.running and !driver.completed;
    stderr.interface.print("live.replay_custody running={any} completed={any} retained={any}\n", .{ driver.running, driver.completed, retained }) catch {};
    if (retained) {
        // failure_value and the per-role report are not atomic. An incomplete
        // native return would not permit reading or freeing their storage.
        stderr.interface.print("live.replay_failure error={s} details_unavailable=native_roles_active\n", .{@errorName(err)}) catch {};
    } else replayFailure(err, driver.failure_value, driver.report, &stderr.interface) catch {};
    stderr.interface.flush() catch {};
}
// Bounded real terminal ledger permits explicit delayed ACK scripts. Each entry
// names an actually popped terminal; cleanup never fabricates event availability.
const Events = struct {
    terminals: [8]?u64 = @splat(null),
    fn pop(self: *Events, host: *live.Host, auto_ack: bool) !bool {
        const event = host.popEvent() orelse return false;
        if (event.kind == .terminal) {
            if (auto_ack) try host.acknowledgeTerminal(event.command.id) else {
                for (&self.terminals) |*slot| if (slot.* == null) {
                    slot.* = event.command.id;
                    return true;
                };
                return error.TerminalLedgerFull;
            }
        }
        return true;
    }
    fn acknowledge(self: *Events, host: *live.Host, id: u64) !void {
        // Invoke ordinary API even for invalid IDs, retaining its actual result.
        try host.acknowledgeTerminal(id);
        for (&self.terminals) |*slot| if (slot.* == id) {
            slot.* = null;
            return;
        };
    }
    fn cleanup(self: *Events, host: *live.Host) !void {
        for (&self.terminals) |*slot| if (slot.*) |id| {
            try host.acknowledgeTerminal(id);
            slot.* = null;
        };
        for (0..16) |_| if (!try self.pop(host, true)) return;
    }
};
// A failed recording still takes the native close/pop/ACK/join/destroy path.
// Timeout leaves retained custody; process exit is not reported as cleanup.
fn closeActual(io: std.Io, host: *live.Host, recorder: *recording.Recorder, events: *Events, deadline_ms: u64) !live.Status {
    try host.requestClose(host.identity().epoch);
    const began = std.Io.Clock.awake.now(io);
    var cadence: UiCadence = .{};
    while (true) {
        const backlog = drain(recorder) catch false;
        const elapsed = began.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        if (elapsed > deadline_ms * std.time.ns_per_ms) return error.CleanupRetained;
        if (!cadence.due(elapsed)) {
            if (!backlog) pause(io);
            continue;
        }
        try events.cleanup(host);
        if (host.isClosed()) {
            host.join() catch |err| switch (err) {
                error.CleanupPending => {
                    if (!backlog) pause(io);
                    continue;
                },
            };
            const status = (host.readStatus() orelse return error.MissingClosedStatus).value;
            try events.cleanup(host);
            try host.acknowledgeClosed();
            try host.destroy();
            return status;
        }
        if (began.durationTo(std.Io.Clock.awake.now(io)).nanoseconds > deadline_ms * std.time.ns_per_ms) return error.CleanupRetained;
        if (!backlog) pause(io);
    }
}
// Pure admission checks shared by the workload and source-local unit tests.
// Neither function opens a file, allocates a native owner, or emits UI actions.
fn validateScript(script: Script, opt: Options) !void {
    if (script.actions.len > opt.action_cap) return error.ActionBudgetExceeded;
    var closes: usize = 0;
    for (script.actions, 0..) |action, i| {
        if (action.at_frame > recording.max_generated_frames or action.at_ms > opt.deadline_ms) return error.InvalidTrigger;
        if (action.kind != .ack and action.command_id != 0) return error.InvalidArgument;
        if (script.auto_events and (action.kind == .pop or action.kind == .ack)) return error.MixedEventModes;
        if (action.kind == .close) {
            closes += 1;
            if (i + 1 != script.actions.len) return error.CloseMustBeLast;
        }
    }
    if (closes > 1 or (closes == 0 and opt.frame_limit == 0)) return error.MissingClose;
}
fn captureStaging(script_byte_count: usize, capture_cap: usize) !usize {
    const staging = @sizeOf(FileSink) + json_arena_bytes + script_byte_count + 64 * 1024 + 4096;
    if (@sizeOf(recording.Recorder) + staging > capture_cap) return error.CaptureBudgetExceeded;
    return staging;
}
fn record(allocator: std.mem.Allocator, io: std.Io, opt: Options, launch: live.Launch, identity: format.Identity, retained: *bool, output: *std.Io.Writer) anyerror!void {
    const script_bytes = try std.Io.Dir.cwd().readFileAlloc(io, opt.script.?, allocator, .limited(max_script_bytes + 1));
    defer allocator.free(script_bytes);
    if (script_bytes.len > max_script_bytes) return error.ScriptTooLarge;
    const arena = try allocator.alloc(u8, json_arena_bytes);
    defer allocator.free(arena);
    var fixed: std.heap.FixedBufferAllocator = .init(arena);
    const parsed = try std.json.parseFromSlice(Script, fixed.allocator(), script_bytes, .{ .ignore_unknown_fields = false, .allocate = .alloc_always });
    defer parsed.deinit();
    const script = parsed.value;
    try validateScript(script, opt);
    const staging = try captureStaging(script_bytes.len, opt.capture_cap);
    const temp = try std.fmt.allocPrint(allocator, "{s}.incomplete", .{opt.out.?});
    defer allocator.free(temp);
    const sink = try allocator.create(FileSink);
    var sink_owned = true;
    defer if (sink_owned and !retained.*) allocator.destroy(sink);
    const file = try std.Io.Dir.cwd().createFile(io, temp, .{ .exclusive = true });
    sink.init(io, file);
    defer if (sink_owned and !retained.*) sink.close();
    const recorder = try allocator.create(recording.Recorder);
    recorder.address = null;
    recorder.session = .{};
    var recorder_owned = true;
    defer if (recorder_owned and !retained.*) allocator.destroy(recorder);
    try recorder.initStreamingWithPacing(identity, sink.binding(), opt.file_cap, staging, opt.pacing);
    const host = try live.Host.create(launch, .{ .io = io, .device = .{ .backend = .null_backend }, .semantic = &recorder.session });
    var host_alive = true;
    var cleanup_status: ?live.Status = null;
    var events: Events = .{};
    defer if (host_alive) {
        const cleanup = closeActual(io, host, recorder, &events, opt.deadline_ms);
        if (cleanup) |_| {} else |_| retained.* = true;
        reportCaptureCleanup(io, cleanup);
    };
    // Runs before the native cleanup defer, preserving the first failure's
    // atomic capture diagnostics without claiming cleanup has completed. If
    // failure is after native destruction, retain that real returned status.
    errdefer |err| {
        if (recorder_owned) reportCaptureFailure(io, recorder, err);
        if (cleanup_status) |status| reportCaptureCleanup(io, status);
    }
    const began = std.Io.Clock.awake.now(io);
    var cadence: UiCadence = .{};
    var next: usize = 0;
    var close = false;
    while (!close) {
        const backlog = try drain(recorder);
        if (!recorder.healthy()) return error.SemanticCaptureIncomplete;
        const elapsed = began.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        if (elapsed > opt.deadline_ms * std.time.ns_per_ms) return error.ScriptTimedOut;
        if (!cadence.due(elapsed)) {
            if (!backlog) pause(io);
            continue;
        }
        if (script.auto_events) for (0..16) |_| if (!try events.pop(host, true)) break;
        if (host.readStatus()) |snapshot| {
            const status = snapshot.value;
            // Zig 0.16's error-capturing errdefer requires this return value to
            // be an error union even when the function explicitly uses anyerror.
            if (status.first_error) |err| return @as(anyerror!void, err);
            const frames = recorder.progress().submitted_frames;
            if (next < script.actions.len) {
                const action = script.actions[next];
                if ((!action.ready or status.phase == .ready) and frames >= action.at_frame and elapsed >= action.at_ms * std.time.ns_per_ms) {
                    switch (action.kind) {
                        .play => {
                            _ = host.submit(host.identity(), .play) catch null;
                        },
                        .stop => {
                            _ = host.submit(host.identity(), .stop) catch null;
                        },
                        .pop => {
                            _ = try events.pop(host, false);
                        },
                        .ack => events.acknowledge(host, action.command_id) catch {},
                        .close => {
                            try host.requestClose(host.identity().epoch);
                            close = true;
                        },
                    }
                    next += 1;
                }
            }
            if (!close and opt.frame_limit != 0 and frames >= opt.frame_limit) {
                try host.requestClose(host.identity().epoch);
                close = true;
            }
        }
        if (!close and !backlog) pause(io);
    }
    const status = try closeActual(io, host, recorder, &events, opt.deadline_ms);
    host_alive = false;
    cleanup_status = status;
    if (!status.worker_joined or status.provider.live != 0 or status.provider.opened != status.provider.closed or status.sample_leases != 0 or status.live_instances != 0 or status.cleanup_error != null) return error.CleanupIncomplete;
    const seal = try recorder.finishStreaming();
    try sink.syncAndClose();
    const stats = recorder.finalStats();
    allocator.destroy(recorder);
    recorder_owned = false;
    allocator.destroy(sink);
    sink_owned = false;
    // Native producers and their resident capture storage are gone before
    // bounded full-file verification allocates the immutable replay backing.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, temp, allocator, .limited(opt.file_cap + 1));
    defer allocator.free(bytes);
    if (bytes.len > opt.file_cap) return error.FileBudgetExceeded;
    const reader = try format.Reader.preflight(bytes, identity, codec.validate);
    _ = try codec.validateInputsWithPolicy(&reader, identity, opt.admission);
    if (bytes.len != seal.bytes) return error.InvalidLength;
    try std.Io.Dir.cwd().renamePreserve(temp, .cwd(), opt.out.?, io);
    try output.print("{{\"recording_complete\":true,\"admission\":\"{s}\",\"pacing\":\"{s}\",\"replay_verified\":false,\"wire_version\":{d},\"bytes\":{d},\"capture_bytes\":{d},\"actions_executed\":{d},\"host_joined_destroyed\":true}}\n", .{ @tagName(opt.admission), @tagName(opt.pacing), format.wire_version, seal.bytes, stats.allocation_bytes, next });
}
pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, output: *std.Io.Writer) !void {
    if (args.len == 0 or (args.len == 1 and std.mem.eql(u8, args[0], "--help"))) {
        try output.writeAll("sme-live-history record --bank FILE --state U64 --script JSON --out FILE [--action-cap 256 --file-cap BYTES --capture-cap BYTES --deadline-ms 60000 --frame-limit FRAMES --admission native_attempt|ordered_job_scans|joint_service_reads --pacing legacy_poll|notified_v1]\nsme-live-history replay --bank FILE --state U64 --tape FILE [--file-cap BYTES --admission native_attempt|ordered_job_scans|joint_service_reads --pacing legacy_poll|notified_v1]\nFixed supported null-device configuration:48000Hz, stereo,256 frames. One Host per process; replay requires the identical executable and explicit matching pacing (default legacy_poll). Wire v2/v3/v4/v5 need their original matching tools; this tool accepts v6 only.\n");
        return;
    }
    const opt = try options(args);
    var admission_log = std.Io.File.stderr().writerStreaming(io, &.{});
    admission_log.interface.print("live.admission mode={s} policy={s} pacing={s}\n", .{ @tagName(opt.mode), @tagName(opt.admission), @tagName(opt.pacing) }) catch {};
    admission_log.interface.flush() catch {};
    var retained = false;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, opt.bank, allocator, .limited(live.admission.default_config.capacity.max_bank_bytes + 1));
    defer if (!retained) allocator.free(bytes);
    if (bytes.len > live.admission.default_config.capacity.max_bank_bytes) return error.BankTooLarge;
    const source_hash = format.hash(bytes);
    const launch: live.Launch = .{ .document_id = 1, .revision = 1, .draft_hash = source_hash, .state = @enumFromInt(opt.state), .compiled = bytes };
    const selection = try live.admission.validate(allocator, bytes, launch.state, launch.config);
    const identity: format.Identity = .{ .build = try executableHash(io), .bank = selection.bank_hash, .source = source_hash, .config = try codec.configHash(launch.config) };
    if (opt.mode == .record) return record(allocator, io, opt, launch, identity, &retained, output);
    const tape = try std.Io.Dir.cwd().readFileAlloc(io, opt.tape.?, allocator, .limited(opt.file_cap + 1));
    defer if (!retained) allocator.free(tape);
    if (tape.len > opt.file_cap) return error.FileBudgetExceeded;
    const reader = try allocator.create(format.Reader);
    defer if (!retained) allocator.destroy(reader);
    reader.* = try format.Reader.preflight(tape, identity, codec.validate);
    const driver = try allocator.create(replay.Driver);
    driver.* = .{};
    defer if (!retained) allocator.destroy(driver);
    try driver.initWithPolicy(reader, identity, io, opt.admission);
    const report = driver.runWithPacing(launch, .{ .backend = .null_backend }, opt.pacing) catch |err| {
        retained = driver.running and !driver.completed;
        reportReplayFailure(io, driver, err);
        return err;
    };
    if (!report.eof or !report.host_joined or !report.host_destroyed) return error.ReplayIncomplete;
    try output.print("{{\"replay_verified\":true,\"admission\":\"{s}\",\"pacing\":\"{s}\",\"wire_version\":{d},\"eof\":true,\"host_joined_destroyed\":true}}\n", .{ @tagName(opt.admission), @tagName(opt.pacing), format.wire_version });
}

const cli_test_record = [_][]const u8{ "record", "--bank", "unopened-bank", "--state", "7", "--script", "unopened-script", "--out", "uncreated-output" };
const cli_test_replay = [_][]const u8{ "replay", "--bank", "unopened-bank", "--state", "7", "--tape", "unopened-tape" };
fn cliTestOptions(base: []const []const u8, extra: []const []const u8) !Options {
    var args: [40][]const u8 = undefined;
    std.debug.assert(base.len + extra.len <= args.len);
    @memcpy(args[0..base.len], base);
    @memcpy(args[base.len..][0..extra.len], extra);
    return options(args[0 .. base.len + extra.len]);
}
fn cliTestRecordNumber(flag: []const u8, value: u64) !Options {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    return cliTestOptions(&cli_test_record, &.{ flag, text });
}

test "live history options reject missing mode arguments and required paths before effects" {
    const t = std.testing;
    try t.expectError(error.MissingMode, options(&.{}));
    try t.expectError(error.InvalidMode, options(&.{"recover"}));
    try t.expectError(error.MissingArgument, options(&.{ "record", "--bank" }));
    try t.expectError(error.MissingBank, options(&.{"record"}));
    try t.expectError(error.MissingState, options(&.{ "record", "--bank", "unopened" }));
    try t.expectError(error.InvalidArgument, options(&.{ "record", "--bank", "unopened", "--state", "7" }));
    try t.expectError(error.InvalidArgument, options(&.{ "record", "--bank", "unopened", "--state", "7", "--script", "unopened" }));
    try t.expectError(error.InvalidArgument, options(&.{ "record", "--bank", "unopened", "--state", "7", "--out", "uncreated" }));
    try t.expectError(error.UnsupportedReplayOption, options(&.{ "replay", "--bank", "unopened", "--state", "7" }));
}

test "live history options reject unknown flags and every duplicate option" {
    const t = std.testing;
    try t.expectError(error.UnknownArgument, cliTestOptions(&cli_test_record, &.{ "--unknown", "value" }));
    try t.expectError(error.UnknownArgument, cliTestOptions(&cli_test_record, &.{ "positional", "value" }));
    try t.expectError(error.MissingArgument, cliTestOptions(&cli_test_record, &.{"--unknown"}));
    const entries = [_]struct { flag: []const u8, value: []const u8 }{
        .{ .flag = "--bank", .value = "unopened" },
        .{ .flag = "--state", .value = "7" },
        .{ .flag = "--script", .value = "unopened" },
        .{ .flag = "--out", .value = "uncreated" },
        .{ .flag = "--tape", .value = "unopened" },
        .{ .flag = "--action-cap", .value = "1" },
        .{ .flag = "--file-cap", .value = "4096" },
        .{ .flag = "--capture-cap", .value = "1048576" },
        .{ .flag = "--deadline-ms", .value = "1" },
        .{ .flag = "--frame-limit", .value = "0" },
        .{ .flag = "--sample-rate", .value = "48000" },
        .{ .flag = "--channels", .value = "2" },
        .{ .flag = "--period-frames", .value = "256" },
        .{ .flag = "--admission", .value = "native_attempt" },
        .{ .flag = "--pacing", .value = "legacy_poll" },
    };
    for (entries) |entry| try t.expectError(error.DuplicateArgument, options(&.{ "record", entry.flag, entry.value, entry.flag, entry.value }));
}

test "live history numeric arguments reject malformed negative and overflowing unsigned values" {
    const t = std.testing;
    const flags = [_][]const u8{ "--state", "--action-cap", "--file-cap", "--capture-cap", "--deadline-ms", "--frame-limit", "--sample-rate", "--channels", "--period-frames" };
    for (flags) |flag| {
        for ([_][]const u8{ "", "12x", "-1", "18446744073709551616" }) |value| {
            // Parse failure occurs before required-path validation, and does not
            // need a duplicate --state in the otherwise valid base arguments.
            try t.expectError(error.InvalidArgument, options(&.{ "record", flag, value }));
        }
    }
}

test "live history rejects unsupported native rate channel and period assertions" {
    const t = std.testing;
    const entries = [_]struct { flag: []const u8, value: []const u8 }{
        .{ .flag = "--sample-rate", .value = "44100" },
        .{ .flag = "--sample-rate", .value = "0" },
        .{ .flag = "--channels", .value = "1" },
        .{ .flag = "--channels", .value = "0" },
        .{ .flag = "--period-frames", .value = "128" },
        .{ .flag = "--period-frames", .value = "0" },
    };
    for (entries) |entry| {
        try t.expectError(error.UnsupportedDeviceConfiguration, cliTestOptions(&cli_test_record, &.{ entry.flag, entry.value }));
        try t.expectError(error.UnsupportedDeviceConfiguration, cliTestOptions(&cli_test_replay, &.{ entry.flag, entry.value }));
    }
    _ = try cliTestOptions(&cli_test_record, &.{ "--sample-rate", "48000", "--channels", "2", "--period-frames", "256" });
    _ = try cliTestOptions(&cli_test_replay, &.{ "--sample-rate", "48000", "--channels", "2", "--period-frames", "256" });
}

test "live history rejects zero and over-limit finite budgets" {
    const t = std.testing;
    const entries = [_]struct { flag: []const u8, value: u64 }{
        .{ .flag = "--action-cap", .value = 0 },
        .{ .flag = "--action-cap", .value = max_actions + 1 },
        .{ .flag = "--file-cap", .value = 0 },
        .{ .flag = "--file-cap", .value = format.header_size + format.trailer_size - 1 },
        .{ .flag = "--file-cap", .value = format.max_file_bytes + 1 },
        .{ .flag = "--capture-cap", .value = format.max_capture_bytes + 1 },
        .{ .flag = "--deadline-ms", .value = 0 },
        .{ .flag = "--deadline-ms", .value = 60_001 },
        .{ .flag = "--frame-limit", .value = recording.max_generated_frames + 1 },
    };
    for (entries) |entry| try t.expectError(error.InvalidBudget, cliTestRecordNumber(entry.flag, entry.value));
}

test "live history accepts exact option boundaries without opening named files" {
    const t = std.testing;
    const defaults = try options(&cli_test_record);
    try t.expectEqual(@as(usize, max_actions), defaults.action_cap);
    try t.expectEqual(@as(u64, format.max_file_bytes), defaults.file_cap);
    try t.expectEqual(@as(usize, format.max_capture_bytes), defaults.capture_cap);
    try t.expectEqual(@as(u64, 60_000), defaults.deadline_ms);
    try t.expectEqual(@as(u64, 0), defaults.frame_limit);
    try t.expectEqual(@as(usize, 1), (try cliTestRecordNumber("--action-cap", 1)).action_cap);
    try t.expectEqual(@as(usize, max_actions), (try cliTestRecordNumber("--action-cap", max_actions)).action_cap);
    try t.expectEqual(@as(u64, format.header_size + format.trailer_size), (try cliTestRecordNumber("--file-cap", format.header_size + format.trailer_size)).file_cap);
    _ = try cliTestRecordNumber("--file-cap", format.max_file_bytes);
    _ = try cliTestRecordNumber("--capture-cap", format.max_capture_bytes);
    try t.expectEqual(@as(u64, 1), (try cliTestRecordNumber("--deadline-ms", 1)).deadline_ms);
    _ = try cliTestRecordNumber("--deadline-ms", 60_000);
    _ = try cliTestRecordNumber("--frame-limit", recording.max_generated_frames);
    // Zero capture allowance is rejected by exact resident-size admission,
    // rather than pretending it is a syntactically invalid numeric option.
    const zero = try cliTestRecordNumber("--capture-cap", 0);
    try t.expectError(error.CaptureBudgetExceeded, captureStaging(0, zero.capture_cap));
}

test "live history record and replay reject incompatible mode-specific options" {
    const t = std.testing;
    try t.expectError(error.InvalidArgument, cliTestOptions(&cli_test_record, &.{ "--tape", "unopened" }));
    const entries = [_]struct { flag: []const u8, value: []const u8 }{
        .{ .flag = "--script", .value = "unopened" },
        .{ .flag = "--out", .value = "uncreated" },
        .{ .flag = "--action-cap", .value = "256" },
        .{ .flag = "--capture-cap", .value = "0" },
        .{ .flag = "--deadline-ms", .value = "60000" },
        .{ .flag = "--frame-limit", .value = "1" },
    };
    for (entries) |entry| try t.expectError(error.UnsupportedReplayOption, cliTestOptions(&cli_test_replay, &.{ entry.flag, entry.value }));
    // Existing contract permits an explicit disabled frame trigger in replay.
    const replay_options = try cliTestOptions(&cli_test_replay, &.{ "--frame-limit", "0", "--file-cap", "4096" });
    try t.expectEqual(Mode.replay, replay_options.mode);
    try t.expectEqual(@as(u64, 0), replay_options.frame_limit);
}

test "live history exact resident capture budget rejects before file and Host creation" {
    const t = std.testing;
    for ([_]usize{ 0, max_script_bytes }) |bytes| {
        const staging = @sizeOf(FileSink) + json_arena_bytes + bytes + 64 * 1024 + 4096;
        const required = @sizeOf(recording.Recorder) + staging;
        try t.expect(required <= format.max_capture_bytes);
        try t.expectError(error.CaptureBudgetExceeded, captureStaging(bytes, 0));
        try t.expectError(error.CaptureBudgetExceeded, captureStaging(bytes, required - 1));
        try t.expectEqual(staging, try captureStaging(bytes, required));
    }
}

test "live history script action cap and required final Close validate before owner effects" {
    const t = std.testing;
    const opt = try options(&cli_test_record);
    var limited = opt;
    limited.action_cap = 1;
    try t.expectError(error.ActionBudgetExceeded, validateScript(.{ .actions = &.{ .{ .kind = .stop }, .{ .kind = .close } } }, limited));
    try t.expectError(error.MissingClose, validateScript(.{ .actions = &.{} }, opt));
    try t.expectError(error.MissingClose, validateScript(.{ .actions = &.{.{ .kind = .play }} }, opt));
    try t.expectError(error.CloseMustBeLast, validateScript(.{ .actions = &.{ .{ .kind = .close }, .{ .kind = .play } } }, opt));
    try t.expectError(error.CloseMustBeLast, validateScript(.{ .actions = &.{ .{ .kind = .close }, .{ .kind = .close } } }, opt));
    try validateScript(.{ .actions = &.{.{ .kind = .close }} }, limited);
    var with_frame_close = opt;
    with_frame_close.frame_limit = 1;
    try validateScript(.{ .actions = &.{} }, with_frame_close);
}

test "live history script rejects over-limit triggers and non-ACK command IDs" {
    const t = std.testing;
    const opt = try options(&cli_test_record);
    try t.expectError(error.InvalidTrigger, validateScript(.{ .actions = &.{.{ .kind = .close, .at_frame = recording.max_generated_frames + 1 }} }, opt));
    try t.expectError(error.InvalidTrigger, validateScript(.{ .actions = &.{.{ .kind = .close, .at_ms = opt.deadline_ms + 1 }} }, opt));
    for ([_]@FieldType(Action, "kind"){ .play, .stop, .pop, .close }) |kind| {
        const invalid = [_]Action{ .{ .kind = kind, .command_id = 1 }, .{ .kind = .close } };
        try t.expectError(error.InvalidArgument, validateScript(.{ .auto_events = false, .actions = &invalid }, opt));
    }
    try validateScript(.{ .actions = &.{.{ .kind = .close, .at_frame = recording.max_generated_frames, .at_ms = opt.deadline_ms }} }, opt);
}

test "live history explicit event mode preserves native ACK errors rather than precomputing outcomes" {
    const t = std.testing;
    const opt = try options(&cli_test_record);
    try t.expectError(error.MixedEventModes, validateScript(.{ .actions = &.{ .{ .kind = .pop }, .{ .kind = .close } } }, opt));
    try t.expectError(error.MixedEventModes, validateScript(.{ .actions = &.{ .{ .kind = .ack, .command_id = 1 }, .{ .kind = .close } } }, opt));
    // Zero and unknown ids remain genuine UI inputs. No result is fabricated
    // here; the real Host's eventual acknowledgment return must be recorded.
    try validateScript(.{ .auto_events = false, .actions = &.{ .{ .kind = .stop }, .{ .kind = .pop }, .{ .kind = .ack, .command_id = 0 }, .{ .kind = .ack, .command_id = std.math.maxInt(u64) }, .{ .kind = .close } } }, opt);
}

test "live history script JSON rejects unknown fields and unsupported action kinds" {
    const t = std.testing;
    const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = false, .allocate = .alloc_always };
    try t.expectError(error.UnknownField, std.json.parseFromSlice(Script, t.allocator, "{\"unknown\":true,\"actions\":[]}", parse_options));
    try t.expectError(error.UnknownField, std.json.parseFromSlice(Script, t.allocator, "{\"actions\":[{\"kind\":\"close\",\"unknown\":1}]}", parse_options));
    try t.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Script, t.allocator, "{\"actions\":[{\"kind\":\"recover\"}]}", parse_options));
    try t.expectError(error.DuplicateField, std.json.parseFromSlice(Script, t.allocator, "{\"auto_events\":true,\"auto_events\":false,\"actions\":[]}", parse_options));
    const parsed = try std.json.parseFromSlice(Script, t.allocator, "{\"auto_events\":false,\"actions\":[{\"kind\":\"ack\",\"command_id\":0},{\"kind\":\"close\"}]}", parse_options);
    defer parsed.deinit();
    try validateScript(parsed.value, try options(&cli_test_record));
}

test "live history collector preserves bounded batches and reports remaining work" {
    const t = std.testing;
    const Fake = struct {
        remaining: usize,
        calls: usize = 0,
        failed: bool = false,
        fn drainStreaming(self: *@This()) !bool {
            self.calls += 1;
            if (self.failed) return error.DiskUnavailable;
            if (self.remaining == 0) return false;
            self.remaining -= 1;
            return true;
        }
    };
    var empty: Fake = .{ .remaining = 0 };
    try t.expect(!try drain(&empty));
    try t.expectEqual(@as(usize, 1), empty.calls);
    var short: Fake = .{ .remaining = 255 };
    try t.expect(!try drain(&short));
    try t.expectEqual(@as(usize, 256), short.calls);
    var busy: Fake = .{ .remaining = 257 };
    try t.expect(try drain(&busy));
    try t.expectEqual(@as(usize, 256), busy.calls);
    try t.expectEqual(@as(usize, 1), busy.remaining);
    try t.expect(!try drain(&busy));
    try t.expectEqual(@as(usize, 258), busy.calls);
    var failed: Fake = .{ .remaining = 1, .failed = true };
    try t.expectError(error.DiskUnavailable, drain(&failed));
    try t.expectEqual(@as(usize, 1), failed.calls);
}

test "live history UI cadence does not accelerate while collector remains busy" {
    const t = std.testing;
    var cadence: UiCadence = .{};
    try t.expect(cadence.due(0));
    for (0..1024) |_| try t.expect(!cadence.due(0));
    try t.expect(!cadence.due(std.time.ns_per_ms - 1));
    try t.expect(cadence.due(std.time.ns_per_ms));
    try t.expect(!cadence.due(std.time.ns_per_ms));
    // A delayed collector gets one policy turn, never catch-up UI bursts.
    try t.expect(cadence.due(10 * std.time.ns_per_ms));
    try t.expect(!cadence.due(10 * std.time.ns_per_ms));
    try t.expect(!cadence.due(11 * std.time.ns_per_ms - 1));
    try t.expect(cadence.due(11 * std.time.ns_per_ms));
}

test "live history failure diagnostics expose atomic lane poison without requiring producer exclusion" {
    const t = std.testing;
    const recorder = try t.allocator.create(recording.Recorder);
    defer t.allocator.destroy(recorder);
    recorder.capture.init(codec.validate);
    recorder.session = .{};
    recorder.failed = .init(true);
    recorder.first_output_error = error.DiskUnavailable;
    recorder.capture.lane(.worker).poison(.overflow);
    recorder.capture.lane(.worker).peak_bytes.store(4096, .monotonic);
    recorder.capture.lane(.worker).peak_records.store(256, .monotonic);
    // Other producer-owned fields intentionally remain uninitialized: this
    // diagnostic must not inspect them or claim a join/cleanup outcome.
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try captureFailure(recorder, error.Poisoned, &writer);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "error=Poisoned recorder_failed=true session_poisoned=false output_error=DiskUnavailable") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "role=worker poison=overflow peak_bytes=4096 peak_records=256") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "role=ui poison=none peak_bytes=0 peak_records=0") != null);
}

test "live history public entry compiles production record path and rejects before file effects" {
    const t = std.testing;
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    // Referencing only pure parser helpers did not analyze record's body. This
    // invokes the real public entry while its first validation rejects before
    // any bank/script read, file creation, allocation of a Host, or UI action.
    try t.expectError(error.InvalidMode, run(t.allocator, t.io, &.{"recover"}, &writer));
    try t.expectError(error.MissingBank, run(t.allocator, t.io, &.{"record"}, &writer));
    try t.expectError(error.MissingBank, run(t.allocator, t.io, &.{"replay"}, &writer));
    try t.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "live history replay diagnostic preserves first mismatch and separate cleanup evidence" {
    const t = std.testing;
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const failure: replay.Failure = .{ .reason = error.ReplayMismatch, .role = .ui, .occurrence = 37, .family = .ui_event, .byte_offset = 32, .expected_family = .ui_event, .expected_tag = 1, .actual_tag = 1 };
    const report: replay.Report = .{ .host_joined = true, .host_destroyed = true, .eof = false, .command_submitted = 2, .command_terminal = 1, .terminal_acknowledged = 1, .matched = .{ 11, 12, 13, 14 }, .pcm_samples = .{ 512, 0, 0 } };
    try replayFailure(error.ReplayMismatch, failure, report, &writer);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "reason=ReplayMismatch role=ui occurrence=37 family=ui_event byte_offset=32") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "host_joined=true host_destroyed=true eof=false") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "command_terminal=1 terminal_acknowledged=1") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "unavailable=no_final_status") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "replay_verified") == null);
    writer = std.Io.Writer.fixed(&buffer);
    try replayFailure(error.WrongLaunch, null, .{}, &writer);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "unavailable=no_recorded_failure") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "host_joined=false host_destroyed=false eof=false") != null);
}

test "live history capture failure reports actual cleanup separately without replacing original error" {
    const t = std.testing;
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const status: live.Status = .{
        .identity = .{ .epoch = 1, .document_id = 1, .revision = 1, .draft_hash = @splat(0), .artifact_hash = @splat(0), .state = @enumFromInt(1) },
        .phase = .closed,
        .worker_joined = true,
        .provider = .{ .opened = 3, .closed = 3, .live = 0 },
        .first_error = error.NativeFailure,
    };
    try captureCleanup(status, &writer);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "native_teardown_complete=true host_joined=true host_destroyed=true retained=false") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "worker_joined=true provider_opened=3 provider_closed=3 provider_live=0 sample_leases=0 live_instances=0") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "first_error=NativeFailure cleanup_error=none") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "recording_complete") == null);
    writer = std.Io.Writer.fixed(&buffer);
    const OriginalFailure = struct {
        fn run(output: *std.Io.Writer) !void {
            defer captureCleanup(error.CleanupRetained, output) catch {};
            return error.CaptureFailed;
        }
    };
    try t.expectError(error.CaptureFailed, OriginalFailure.run(&writer));
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "native_teardown_complete=false retained=true error=CleanupRetained host_joined=unknown host_destroyed=unknown") != null);
    try t.expect(std.mem.indexOf(u8, writer.buffered(), "host_joined=true") == null);
    // Failed diagnostic output must not replace the workload's first error.
    var no_space: [0]u8 = .{};
    writer = std.Io.Writer.fixed(&no_space);
    try t.expectError(error.CaptureFailed, OriginalFailure.run(&writer));
}

test "live history admission policy is explicit with compatible defaults" {
    const t = std.testing;
    inline for (.{ &cli_test_record, &cli_test_replay }) |base| {
        try t.expectEqual(codec.AdmissionPolicy.native_attempt, (try options(base)).admission);
        inline for (.{ "native_attempt", "ordered_job_scans", "joint_service_reads" }) |name| {
            try t.expectEqual(std.meta.stringToEnum(codec.AdmissionPolicy, name).?, (try cliTestOptions(base, &.{ "--admission", name })).admission);
        }
        try t.expectError(error.InvalidAdmissionPolicy, cliTestOptions(base, &.{ "--admission", "strict" }));
        try t.expectError(error.InvalidAdmissionPolicy, cliTestOptions(base, &.{ "--admission", "" }));
    }
}

test "live history pacing is explicit with legacy defaults and rejects unknown values" {
    const t = std.testing;
    inline for (.{ &cli_test_record, &cli_test_replay }) |base| {
        try t.expectEqual(live.PacingMode.legacy_poll, (try options(base)).pacing);
        inline for (.{ "legacy_poll", "notified_v1" }) |name| {
            try t.expectEqual(std.meta.stringToEnum(live.PacingMode, name).?, (try cliTestOptions(base, &.{ "--pacing", name })).pacing);
        }
        try t.expectError(error.InvalidPacingMode, cliTestOptions(base, &.{ "--pacing", "automatic" }));
        try t.expectError(error.InvalidPacingMode, cliTestOptions(base, &.{ "--pacing", "" }));
    }
}
