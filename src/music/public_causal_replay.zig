//! Bounded fresh-owner replay through genuine Control, Render and Worker calls.
//! Raw external clock samples are the only substituted numerical input. Source
//! reads, SHA verification, Opus, planning, queues, admissions and PCM remain real.
const std = @import("std");
const rt = @import("bugu_audio").runtime;
const resident = @import("resident_runtime.zig");
const recording = @import("public_causal_recording.zig");
pub const format = @import("causal_recording_format.zig");
pub const validation = @import("public_causal_validation.zig");
const contract = @import("contract.zig");
const v1 = @import("runtime_contract.zig");
const stream = rt.streaming.stream;
const Hash = std.crypto.hash.sha2.Sha256;
pub const max_operations_per_role = format.max_operations_per_role;
pub const max_dependencies = 65536;
pub const max_checks = 65536;
pub const max_occurrence_keys = 1024;
pub const point_index_capacity = 131072;
pub const point_probe_limit = 64;
const no_index = std.math.maxInt(u32);
/// The caller keeps context pinned and the complete byte range immutable through
/// preflight, recomputation and actual producer joins. Reads must return the same
/// bytes on every call; replacing a backing file violates this API contract.
pub const ImmutableSource = struct {
    context: *anyopaque,
    length: u64,
    read_at: *const fn (*anyopaque, u64, []u8) anyerror!void,
};
pub const Options = struct { limits: format.Limits = .{}, wait_steps: u64 = 10_000_000 };
pub const State = enum { unused, loading, preflight, running, complete, failed };
pub const Result = struct { operations: [3]u64, pcm: format.PcmSummary, joined: bool, fresh_owner: bool };
const StoredOperation = struct {
    begin: format.OperationBegin,
    end: ?format.OperationEnd = null,
    clock: [2]?struct { job: u64, sample: stream.OfflineClockSample } = @splat(null),
};
const StoredDependency = struct { value: validation.Dependency, source_seen: bool = false, target_seen: bool = false, next_in: u32 = no_index, next_out: u32 = no_index, target_node: u32 };
const StoredConsumedRange = struct {
    value: validation.ConsumedCuts.Range,
    seen: u32 = 0,
    before_pending: bool = false,
};
const ConsumedCall = struct { first: u32 = 0, count: u16 = 0, publications: u32 = 0, sealed: bool = false };
const StoredCheck = struct { value: validation.Check, seen: bool = false, next: u32 = no_index };
const PointNode = struct { occupied: bool = false, point: validation.Point = undefined, incoming: u32 = no_index, outgoing: u32 = no_index, checks: u32 = no_index, blocked: u32 = 0, seen: bool = false };
const Occurrence = struct { site: validation.Site, index: u64, count: u32 };
const MailState = enum(u8) { idle, pending, released };
const Mailbox = struct {
    state: std.atomic.Value(MailState) = .init(.idle),
    point: validation.Point = undefined,
    value: u64 = 0,
    occurrences: [max_occurrence_keys]Occurrence = undefined,
    used: usize = 0,
};
// Test-only per-lane scans of the already validated immutable recording.
// Each cursor visits each file byte/record at most once; no whole-history index.
const DiagnosticCursor = struct {
    page: [format.page_bytes]u8 = undefined,
    next_page: u64 = format.header_bytes,
    iterator: ?format.RecordIterator = null,
    records: u64 = 0,
    ended: bool = false,
};
const RecordDiagnostic = struct {
    source: ?ImmutableSource = null,
    cursors: [8]DiagnosticCursor = @splat(.{}),
    codec: [format.max_record_bytes]u8 = undefined,
    reported: bool = false,
};
/// Fixed maximum storage, independent of file length or caller data. Smaller
/// file/operation/checkpoint budgets are checked before any owner mutation.
/// This object, Session, immutable source and source providers stay pinned until
/// actual producer joins. A wait budget never authorizes freeing live storage.
pub const Storage = struct {
    capture: recording.Storage = .{},
    diagnostic: if (@import("builtin").is_test) RecordDiagnostic else void = if (@import("builtin").is_test) .{} else {},
    preflight_validator: validation.Validator = undefined,
    preflight_reader: ?format.Reader = null,
    operations: [3][max_operations_per_role]StoredOperation = undefined,
    counts: [3]usize = @splat(0),
    graph: [max_dependencies]StoredDependency = undefined,
    graph_count: usize = 0,
    point_index: [point_index_capacity]PointNode = @splat(.{}),
    checks: [max_checks]StoredCheck = undefined,
    check_count: usize = 0,
    consumed_ranges: [max_checks]StoredConsumedRange = undefined,
    consumed_range_count: usize = 0,
    consumed_calls: [max_operations_per_role]ConsumedCall = @splat(.{}),
    expected_hash: [8]Hash = @splat(.init(.{})),
    actual_hash: [8]Hash = @splat(.init(.{})),
    expected_counts: [8]u64 = @splat(0),
    actual_counts: [8]u64 = @splat(0),
    page: [format.page_bytes]u8 = undefined,
    codec: [format.max_record_bytes]u8 = undefined,
    pcm: [format.max_pcm_frames * 2]f32 = undefined,
    mail: [3]Mailbox = @splat(.{}),
    pub fn requiredBytes() usize {
        return @sizeOf(Storage);
    }
};
pub const storage_bytes = @sizeOf(Storage);
const DiagnosticStage = enum(u8) { unused, loading, preflight, preflight_done, admission, admission_wait, admitted, running, roles_finished, joining, joined, complete, cleanup };
const Failure = enum(u8) { none, budget, dependency, comparator, engine, input, invariant };
const VerifiedProof = struct {
    driver: *Session,
    storage: *Storage,
    recorder: *recording.Session,
    owner: *resident.MusicRuntime,
    header: format.Header,
    terminal: format.Terminal,
    pcm: format.PcmProof,
    actual_header: ?format.Header = null,
    complete: bool = false,
};
pub const Session = struct {
    state: State = .unused,
    verified_proof: ?VerifiedProof = null,
    // Test-only host barrier before the real Worker safe point, never in an engine hook.
    test_worker_host_gate: if (@import("builtin").is_test) std.atomic.Value(u8) else void = if (@import("builtin").is_test) .init(0) else {},
    owner: *resident.MusicRuntime = undefined,
    storage: *Storage = undefined,
    recorder: recording.Session = undefined,
    header: format.Header = undefined,
    terminal: format.Terminal = undefined,
    proof: format.PcmProof = undefined,
    options: Options = .{},
    control_thread: std.Thread.Id = undefined,
    worker_thread: std.atomic.Value(std.Thread.Id) = .init(0),
    render_thread: std.atomic.Value(std.Thread.Id) = .init(0),
    run: std.atomic.Value(bool) = .init(false),
    abort: std.atomic.Value(bool) = .init(false),
    diagnostic_stage: std.atomic.Value(DiagnosticStage) = .init(.unused),
    diagnostic_seen: u32 = 0, // Control-only, one message per stage.
    diagnostic_budget_dumped: bool = false,
    failure: std.atomic.Value(Failure) = .init(.none),
    operation: [3]std.atomic.Value(u64) = @splat(.init(0)),
    finished: [3]std.atomic.Value(bool) = @splat(.init(false)),
    load_request: std.atomic.Value(u64) = .init(0),
    load_returned: std.atomic.Value(u64) = .init(0),
    load_result: anyerror!bool = false,
    steps: u64 = 0,
    checkpoint_work: u64 = 0,
    assembler_active: bool = false,
    hooks_installed: bool = false,
    cleanup_complete: bool = false,
    cleanup_work: u64 = 0,
    cleanup_budget_exhausted: bool = false,
    cleanup_late_error: ?anyerror = null,
    cleanup_worker_consumed: u64 = 0,
    cleanup_render_consumed: u64 = 0,
    cleanup_stop_started: bool = false,
    render_request: std.atomic.Value(u64) = .init(0),
    render_returned: std.atomic.Value(u64) = .init(0),
    recovery_frames: u32 = 0,
    recovery_render_result: anyerror!void = {},

    /// Establishes Worker ownership before independent loading. An owner
    /// already used by any other Worker is rejected; affinity is never reset.
    pub fn init(self: *Session, owner: *resident.MusicRuntime, storage: *Storage) !void {
        if (self.state != .unused or owner.config_v1.kind != .offline) return error.InvalidState;
        self.owner = owner;
        self.storage = storage;
        self.control_thread = std.Thread.getCurrentId();
        self.recorder = try recording.Session.init(owner, &storage.capture);
        self.state = .loading;
        self.diagnosticStage(.loading);
        self.recorder.startWorker(self, workerMain) catch |err| {
            self.state = .failed;
            return err;
        };
    }
    pub fn workerOneForLoad(self: *Session) !bool {
        if (self.state != .loading or std.Thread.getCurrentId() != self.control_thread or self.abort.load(.acquire)) return error.InvalidState;
        const previous = self.load_request.load(.acquire);
        if (previous != self.load_returned.load(.acquire) or previous == std.math.maxInt(u64)) return error.InvalidState;
        self.load_request.store(previous + 1, .release);
        var work: u64 = 0;
        while (self.load_returned.load(.acquire) != previous + 1) {
            if (work == self.options.wait_steps) {
                self.fail(.budget);
                return error.WorkBudget;
            }
            work += 1;
            std.Thread.yield() catch {};
        }
        self.cleanup_worker_consumed = previous + 1;
        return self.load_result;
    }
    fn diagnosticStage(self: *Session, stage: DiagnosticStage) void {
        self.diagnostic_stage.store(stage, .release);
        if (!@import("builtin").is_test) return;
        const bit: u32 = @as(u32, 1) << @intCast(@intFromEnum(stage));
        if (self.diagnostic_seen & bit != 0) return;
        self.diagnostic_seen |= bit;
        std.debug.print("causal replay stage={s} steps={d} checkpoint_work={d} graph={d} checks={d}\n", .{ @tagName(stage), self.steps, self.checkpoint_work, self.storage.graph_count, self.storage.check_count });
    }
    fn fail(self: *Session, reason: Failure) void {
        const previous = self.failure.cmpxchgStrong(.none, reason, .acq_rel, .acquire);
        // May run on any owned role. Read only atomic diagnostic fields here.
        if (@import("builtin").is_test and previous == null) {
            std.debug.print("causal replay first failure={s} stage={s} operations={d}/{d}/{d} finished={any}/{any}/{any}\n", .{ @tagName(reason), @tagName(self.diagnostic_stage.load(.acquire)), self.operation[0].load(.acquire), self.operation[1].load(.acquire), self.operation[2].load(.acquire), self.finished[0].load(.acquire), self.finished[1].load(.acquire), self.finished[2].load(.acquire) });
        }
        self.abort.store(true, .release);
    }
    fn check(self: *Session) !void {
        return switch (self.failure.load(.acquire)) {
            .none => {},
            .budget => error.WorkBudget,
            .dependency => error.DependencyMismatch,
            .comparator => error.OutputMismatch,
            .engine => error.EngineFailure,
            .input => error.InvalidInput,
            .invariant => error.InvalidState,
        };
    }
    fn workerMain(driver: *recording.WorkerDriver, raw: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.worker_thread.store(std.Thread.getCurrentId(), .release);
        while (true) {
            if (@import("builtin").is_test) {
                if (self.test_worker_host_gate.load(.acquire) == 1) {
                    self.test_worker_host_gate.store(2, .release);
                    while (self.test_worker_host_gate.load(.acquire) == 2 and !self.abort.load(.acquire)) std.Thread.yield() catch {};
                }
            }
            if (!driver.keepRunning()) break;
            if (self.run.load(.acquire)) break;
            const request = self.load_request.load(.acquire);
            if (request != self.load_returned.load(.acquire)) {
                self.load_result = engine(bool, driver.workerOne());
                self.load_returned.store(request, .release);
            } else std.Thread.yield() catch {};
        }
        if (self.run.load(.acquire)) for (self.storage.operations[2][0..self.storage.counts[2]]) |op| {
            if (self.abort.load(.acquire) or !driver.keepRunning()) break;
            self.startOperation(op.begin.key);
            _ = invocation(bool, driver.workerOne()) catch {
                self.fail(.engine);
                break;
            };
            self.endOperation(op.begin.key);
        };
        self.finished[2].store(true, .release);
        // A failed replay keeps its unique Worker alive for explicit cleanup.
        // Checkpoint cancellation is not permission to abandon source custody.
        while (driver.keepRunning()) {
            const request = self.load_request.load(.acquire);
            if (request != self.load_returned.load(.acquire)) {
                self.load_result = engine(bool, driver.workerOne());
                self.load_returned.store(request, .release);
            } else std.Thread.yield() catch {};
        }
    }
    fn renderMain(driver: *recording.RenderDriver, raw: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.render_thread.store(std.Thread.getCurrentId(), .release);
        while (!self.run.load(.acquire) and !self.abort.load(.acquire) and driver.keepRunning()) std.Thread.yield() catch {};
        for (self.storage.operations[1][0..self.storage.counts[1]]) |op| {
            if (self.abort.load(.acquire) or !driver.keepRunning()) break;
            const args = op.begin.args.render;
            self.startOperation(op.begin.key);
            invocation(void, driver.render(self.storage.pcm[0 .. @as(usize, args.frames) * args.channels], args.frames)) catch {
                self.fail(.engine);
                break;
            };
            self.endOperation(op.begin.key);
        }
        self.finished[1].store(true, .release);
        while (driver.keepRunning()) {
            const request = self.render_request.load(.acquire);
            if (request != self.render_returned.load(.acquire)) {
                self.recovery_render_result = engine(void, driver.render(self.storage.pcm[0 .. @as(usize, self.recovery_frames) * 2], self.recovery_frames));
                self.render_returned.store(request, .release);
            } else std.Thread.yield() catch {};
        }
    }
    fn engine(comptime T: type, value: recording.Invocation(T)) anyerror!T {
        return switch (value) {
            .not_started => |err| err,
            .started => |started| started.engine_result,
        };
    }
    fn invocation(comptime T: type, value: recording.Invocation(T)) anyerror!T {
        return switch (value) {
            .not_started => |err| err,
            .started => |started| blk: {
                const result = try started.engine_result;
                if (started.recording_failure != .none) return error.IncompleteTrace;
                break :blk result;
            },
        };
    }
    fn startOperation(self: *Session, key: format.OperationKey) void {
        const role_index = @intFromEnum(key.role);
        self.operation[role_index].store(key.ordinal, .release);
        self.storage.mail[role_index].used = 0;
        self.arrive(.{ .role = key.role, .operation = key.ordinal, .site = .operation, .edge = .before }, 0);
    }
    fn endOperation(self: *Session, key: format.OperationKey) void {
        self.arrive(.{ .role = key.role, .operation = key.ordinal, .site = .operation, .edge = .after }, 0);
    }
    fn role(self: *Session) ?format.Role {
        const id = std.Thread.getCurrentId();
        if (id == self.control_thread) return .control;
        if (id == self.worker_thread.load(.acquire)) return .worker;
        if (id == self.render_thread.load(.acquire)) return .render;
        return null;
    }
    fn checkpoint(self: *Session, value: anytype) void {
        const r = self.role() orelse {
            self.fail(.invariant);
            return;
        };
        const site = std.meta.stringToEnum(validation.Site, @tagName(value.site)) orelse {
            self.fail(.dependency);
            return;
        };
        const edge: validation.Edge = if (value.edge == .before) .before else .after;
        const mailbox = &self.storage.mail[@intFromEnum(r)];
        var counter: ?*Occurrence = null;
        for (mailbox.occurrences[0..mailbox.used]) |*entry| if (entry.site == site and entry.index == value.index) {
            counter = entry;
            break;
        };
        if (counter == null) {
            if (mailbox.used == mailbox.occurrences.len or edge != .before) {
                self.fail(.dependency);
                return;
            }
            mailbox.occurrences[mailbox.used] = .{ .site = site, .index = value.index, .count = 0 };
            counter = &mailbox.occurrences[mailbox.used];
            mailbox.used += 1;
        }
        if (edge == .before) {
            if (counter.?.count == std.math.maxInt(u32)) {
                self.fail(.budget);
                return;
            }
            counter.?.count += 1;
        }
        self.arrive(.{ .role = r, .operation = self.operation[@intFromEnum(r)].load(.acquire), .site = site, .index = value.index, .generation = value.generation, .occurrence = counter.?.count, .edge = edge }, value.value);
    }
    fn streamPoint(raw: *anyopaque, point: stream.OfflineCheckpoint) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.checkpoint(point);
    }
    fn schedulerPoint(raw: *anyopaque, point: rt.scheduler.OfflineCheckpoint) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.checkpoint(point);
    }
    fn runtimePoint(raw: *anyopaque, point: rt.CausalReplayPoint) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.checkpoint(point);
    }
    fn rawClock(raw: *anyopaque, stage: stream.WorkerClockStage, job: u64) stream.OfflineClockSample {
        const self: *Session = @ptrCast(@alignCast(raw));
        const ordinal = self.operation[2].load(.acquire);
        if (ordinal == 0 or ordinal > self.storage.counts[2]) {
            self.fail(.input);
            return .{ .value = 0, .available = false };
        }
        const stored = self.storage.operations[2][@intCast(ordinal - 1)].clock[@intFromEnum(stage)] orelse {
            self.fail(.input);
            return .{ .value = 0, .available = false };
        };
        if (stored.job != job) {
            self.fail(.input);
            return .{ .value = 0, .available = false };
        }
        return stored.sample;
    }
    fn arrive(self: *Session, point: validation.Point, value: u64) void {
        if (self.abort.load(.acquire)) return;
        const mail = &self.storage.mail[@intFromEnum(point.role)];
        if (mail.state.load(.acquire) != .idle) {
            self.fail(.invariant);
            return;
        }
        mail.point = point;
        mail.value = value;
        mail.state.store(.pending, .release);
        while (mail.state.load(.acquire) != .released and !self.abort.load(.acquire)) {
            if (point.role == .control) self.pump() catch |err| {
                // This failure-only report is Control-owned. No extra tape
                // scans or synchronization run on the successful path.
                if (self.failure.load(.acquire) == .none) std.debug.print("causal replay Control pump error={s} point={any} value={d}\n", .{ @errorName(err), point, value });
                self.fail(.dependency);
            };
            std.Thread.yield() catch {};
        }
        mail.state.store(.idle, .release);
    }
    /// Only Control owns the graph. Snapshot pending mail after its acquire,
    /// before publishing abort; no charge/reentrant failure or role-thread I/O.
    fn dumpBlockedBudget(self: *Session) void {
        if (std.Thread.getCurrentId() != self.control_thread or self.diagnostic_budget_dumped) return;
        if (self.failure.load(.acquire) != .none or self.abort.load(.acquire)) return;
        self.diagnostic_budget_dumped = true;
        std.debug.print("causal replay budget wait graph: steps={d} work={d}\n", .{ self.steps, self.checkpoint_work });
        for (&self.storage.mail, 0..) |*mail, role_index| {
            const state = mail.state.load(.acquire);
            if (state != .pending) {
                std.debug.print("  role={d} mail={s}\n", .{ role_index, @tagName(state) });
                continue;
            }
            const point = mail.point;
            const value = mail.value;
            var found: ?usize = null;
            const first = pointHash(point);
            // Same fixed probe bound as ordinary lookup, without spending or
            // resetting the exhausted operational work budget.
            for (0..point_probe_limit) |probe| {
                const index = (first + probe) & (point_index_capacity - 1);
                const node = &self.storage.point_index[index];
                if (!node.occupied) break;
                if (std.meta.eql(node.point, point)) {
                    found = index;
                    break;
                }
            }
            if (found) |index| {
                const node = &self.storage.point_index[index];
                std.debug.print("  role={d} pending={any} value={d} blocked={d} seen={any}\n", .{ role_index, point, value, node.blocked, node.seen });
                var printed: usize = 0;
                // A finite table scan also cannot loop on corrupt linked lists.
                for (self.storage.graph[0..@min(self.storage.graph_count, self.storage.graph.len)]) |edge| {
                    if (edge.target_node != index or edge.source_seen) continue;
                    std.debug.print("    unmet predecessor={any}\n", .{edge.value.before});
                    printed += 1;
                    if (printed == 4) break;
                }
            } else std.debug.print("  role={d} pending={any} value={d} graph_node=absent\n", .{ role_index, point, value });
        }
    }
    /// Final Control-only diagnostic after real producer joins. Checks remain
    /// mandatory; list only eight identities and count the finite remainder.
    fn dumpMissingChecks(self: *Session) void {
        if (std.Thread.getCurrentId() != self.control_thread) return;
        var missing: usize = 0;
        for (self.storage.checks[0..self.storage.check_count], 0..) |check_value, check_index| {
            if (check_value.seen) continue;
            missing += 1;
            if (missing > 8) continue;
            var node: ?*const PointNode = null;
            const first = pointHash(check_value.value.point);
            for (0..point_probe_limit) |probe| {
                const candidate = &self.storage.point_index[(first + probe) & (point_index_capacity - 1)];
                if (!candidate.occupied) break;
                if (std.meta.eql(candidate.point, check_value.value.point)) {
                    node = candidate;
                    break;
                }
            }
            if (node) |found| {
                std.debug.print("causal replay missing check index={d} point={any} expected={d} node_seen={any} blocked={d}\n", .{ check_index, check_value.value.point, check_value.value.value, found.seen, found.blocked });
            } else std.debug.print("causal replay missing check index={d} point={any} expected={d} node=absent\n", .{ check_index, check_value.value.point, check_value.value.value });
        }
        std.debug.print("causal replay missing checks total={d}/{d} (printed at most8)\n", .{ missing, self.storage.check_count });
    }
    fn charge(self: *Session, amount: u64) !void {
        if (amount > self.options.limits.checkpoint_steps -| self.checkpoint_work) {
            self.dumpBlockedBudget();
            self.fail(.budget);
            return error.WorkBudget;
        }
        self.checkpoint_work += amount;
    }
    fn pointHash(point: validation.Point) usize {
        var h: u64 = 14695981039346656037;
        inline for (.{ @as(u64, @intFromEnum(point.role)), point.operation, @as(u64, @intFromEnum(point.site)), point.index, point.generation, @as(u64, point.occurrence), @as(u64, @intFromEnum(point.edge)) }) |value| {
            h = (h ^ value) *% 1099511628211;
            h ^= h >> 32;
        }
        return @intCast(h & (point_index_capacity - 1));
    }
    fn pointIndex(self: *Session, point: validation.Point, create: bool) !?u32 {
        const first = pointHash(point);
        for (0..point_probe_limit) |probe| {
            try self.charge(1);
            const index = (first + probe) & (point_index_capacity - 1);
            const node = &self.storage.point_index[index];
            if (!node.occupied) {
                if (!create) return null;
                node.* = .{ .occupied = true, .point = point };
                return @intCast(index);
            }
            if (std.meta.eql(node.point, point)) return @intCast(index);
        }
        std.debug.print("causal replay point-index probe exhausted: create={any} point={any} graph={d} checks={d} probe_limit={d}\n", .{ create, point, self.storage.graph_count, self.storage.check_count, point_probe_limit });
        return error.DependencyCapacity;
    }
    fn releaseNode(self: *Session, index: u32, value: u64) !void {
        const node = &self.storage.point_index[index];
        if (node.seen or node.blocked != 0) return error.DependencyMismatch;
        var check_cursor = node.checks;
        while (check_cursor != no_index) {
            try self.charge(1);
            const expected = &self.storage.checks[check_cursor];
            if (expected.seen or expected.value.value != value) return error.OutputMismatch;
            expected.seen = true;
            check_cursor = expected.next;
        }
        var incoming = node.incoming;
        while (incoming != no_index) {
            try self.charge(1);
            const edge = &self.storage.graph[incoming];
            if (!edge.source_seen) return error.DependencyMismatch;
            edge.target_seen = true;
            incoming = edge.next_in;
        }
        var outgoing = node.outgoing;
        while (outgoing != no_index) {
            try self.charge(1);
            const edge = &self.storage.graph[outgoing];
            if (edge.source_seen) return error.DependencyMismatch;
            edge.source_seen = true;
            const target = &self.storage.point_index[edge.target_node];
            if (target.blocked == 0) return error.DependencyMismatch;
            target.blocked -= 1;
            outgoing = edge.next_out;
        }
        node.seen = true;
    }
    fn pump(self: *Session) !void {
        if (self.steps >= self.options.wait_steps) {
            self.dumpBlockedBudget();
            self.fail(.budget);
            return error.WorkBudget;
        }
        self.steps += 1;
        try self.charge(1);
        if (!self.assembler_active) {
            self.assembler_active = true;
            defer self.assembler_active = false;
            _ = try self.recorder.serviceReplayAssembler(4096);
        }
        for (&self.storage.mail) |*mail| {
            if (mail.state.load(.acquire) != .pending) continue;
            if (try self.pointIndex(mail.point, false)) |index| {
                if (self.storage.point_index[index].blocked != 0) continue;
                try self.consumedCheckpoint(mail.point, mail.value);
                try self.releaseNode(index, mail.value);
            } else try self.consumedCheckpoint(mail.point, mail.value);
            mail.state.store(.released, .release);
        }
    }
    fn consumedCheckpoint(self: *Session, at: validation.Point, value: u64) !void {
        if (at.role != .render or (at.site != .stream_consumed_release and at.site != .operation)) return;
        if (at.operation == 0 or at.operation > self.storage.counts[1]) return error.InvalidOrder;
        const call = self.storage.consumed_calls[@intCast(at.operation - 1)];
        if (!call.sealed) return error.MissingTerminal;
        if (at.site == .operation) {
            if (at.edge == .before) return;
            var total: u64 = 0;
            for (self.storage.consumed_ranges[call.first .. @as(usize, call.first) + call.count]) |range| {
                try self.charge(1);
                if (range.before_pending or range.seen != range.value.count) return error.MissingCheckpoint;
                total += range.seen;
            }
            if (total != call.publications) return error.MissingCheckpoint;
            return;
        }
        for (self.storage.consumed_ranges[call.first .. @as(usize, call.first) + call.count]) |*range| {
            try self.charge(1);
            if (at.index != range.value.index) continue;
            if (at.generation != range.value.generation or at.occurrence == 0 or at.occurrence > range.value.count or at.occurrence != range.seen + 1) return error.OutputMismatch;
            const expected = std.math.add(u64, range.value.first, at.occurrence - 1) catch return error.OutputMismatch;
            if (value != expected) return error.OutputMismatch;
            if (at.edge == .before) {
                if (range.before_pending) return error.OutputMismatch;
                range.before_pending = true;
            } else {
                if (!range.before_pending) return error.OutputMismatch;
                range.before_pending = false;
                range.seen += 1;
            }
            return;
        }
        return error.OutputMismatch;
    }
    fn dependency(raw: *anyopaque, value: validation.Dependency) error{DependencyCapacity}!void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (self.storage.graph_count == self.storage.graph.len) return error.DependencyCapacity;
        const before = (self.pointIndex(value.before, true) catch return error.DependencyCapacity).?;
        const after = (self.pointIndex(value.after, true) catch return error.DependencyCapacity).?;
        const source = &self.storage.point_index[before];
        const target = &self.storage.point_index[after];
        self.storage.graph[self.storage.graph_count] = .{ .value = value, .next_in = target.incoming, .next_out = source.outgoing, .target_node = after };
        source.outgoing = @intCast(self.storage.graph_count);
        target.incoming = @intCast(self.storage.graph_count);
        target.blocked += 1;
        self.storage.graph_count += 1;
    }
    fn expectedCheck(raw: *anyopaque, value: validation.Check) error{DependencyCapacity}!void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (self.storage.check_count + self.storage.consumed_range_count >= max_checks) return error.DependencyCapacity;
        const index = (self.pointIndex(value.point, true) catch return error.DependencyCapacity).?;
        const node = &self.storage.point_index[index];
        self.storage.checks[self.storage.check_count] = .{ .value = value, .next = node.checks };
        node.checks = @intCast(self.storage.check_count);
        self.storage.check_count += 1;
    }
    fn lane(record: format.Record) usize {
        return switch (record) {
            .begin => |v| @intFromEnum(v.key.role),
            .end => |v| @intFromEnum(v.key.role),
            .input, .schedule, .scheduler_publication, .group_source_final => 0,
            .worker => 2,
            .service_exclusion => |v| @intFromEnum(v.key.role),
            .service_claim => |v| @intFromEnum(v.key.role),
            .service_worker_release => |v| @intFromEnum(v.key.role),
            .service_release_observation => |v| @intFromEnum(v.key.role),
            .pcm => 1,
            .scheduler_progress, .group_terminal, .stream_consumed_range, .stream_consumed_call_end => 7,
            .group_event_queue => |v| if (v.key.role == .render) 7 else 0,
            .group_event_queue_terminal => 7,
            .frontier => 3,
            .acceptance => 4,
            .readiness => 5,
            .render => 6,
            .frontier_terminal => 3,
            .acceptance_terminal => 4,
            .readiness_terminal => 5,
            .render_terminal => 6,
        };
    }
    fn normalizePeer(peer: anytype) void {
        peer.incarnation = 0;
        peer.generation = 0;
        peer.owner_identity = 0;
    }
    fn normalizeManifest(manifest: anytype) void {
        normalizePeer(&manifest.control_frontier);
        normalizePeer(&manifest.stream_acceptance);
        manifest.renderer_identity = 0;
        manifest.music_handle_incarnation = 0;
        if (@hasField(@TypeOf(manifest.*), "render_incarnation")) {
            manifest.render_incarnation = 0;
            manifest.render_generation = 0;
        }
    }
    fn normalizedHeader(header: format.Header) format.Header {
        var value = header;
        value.session.incarnation = 0;
        inline for (.{ "frontier", "acceptance", "readiness", "render" }) |field| normalizePeer(&@field(value.bindings, field));
        normalizeManifest(&value.bindings.readiness_manifest);
        normalizeManifest(&value.bindings.render_manifest);
        return value;
    }
    fn normalized(record: format.Record) format.Record {
        var value = record;
        switch (value) {
            .begin => |*v| if (v.args == .submit) {
                v.args.submit.bank.handle.generation = 0;
            },
            .end => |*v| switch (v.result) {
                .submitted => |*ticket| ticket.bank.handle.generation = 0,
                .receipt => |*maybe| if (maybe.*) |*receipt| {
                    receipt.ticket.bank.handle.generation = 0;
                },
                else => {},
            },
            .frontier => |*v| {
                v.incarnation = 0;
                v.generation = 0;
                v.owner_identity = 0;
            },
            .acceptance => |*v| {
                v.incarnation = 0;
                v.generation = 0;
                v.owner_identity = 0;
            },
            .readiness => |*v| {
                v.incarnation = 0;
                v.generation = 0;
            },
            .render => |*v| {
                v.incarnation = 0;
                v.generation = 0;
            },
            .frontier_terminal => |*v| normalizePeer(v),
            .acceptance_terminal => |*v| normalizePeer(v),
            .readiness_terminal => |*v| {
                v.incarnation = 0;
                v.generation = 0;
                normalizeManifest(&v.manifest);
            },
            .render_terminal => |*v| {
                v.incarnation = 0;
                v.generation = 0;
                normalizeManifest(&v.manifest);
            },
            .input, .schedule, .worker, .pcm, .scheduler_publication, .scheduler_progress, .group_terminal, .service_exclusion, .service_claim, .service_worker_release, .service_release_observation, .group_source_final, .group_event_queue, .group_event_queue_terminal, .stream_consumed_range, .stream_consumed_call_end => {},
        }
        return value;
    }
    fn hashRecord(self: *Session, record: format.Record, actual: bool) !void {
        const index = lane(record);
        const bytes = try format.encodeRecord(normalized(record), &self.storage.codec);
        if (actual) {
            self.diagnoseRecord(index, record, bytes);
            self.storage.actual_hash[index].update(bytes);
            self.storage.actual_counts[index] += 1;
        } else {
            self.storage.expected_hash[index].update(bytes);
            self.storage.expected_counts[index] += 1;
        }
    }
    fn diagnosticExpected(self: *Session, index: usize) !?format.Record {
        const source = self.storage.diagnostic.source orelse return error.InvalidState;
        const cursor = &self.storage.diagnostic.cursors[index];
        while (!cursor.ended) {
            if (cursor.iterator) |*iterator| {
                while (try iterator.next()) |record| {
                    if (cursor.records == self.terminal.record_count) return error.WorkBudget;
                    cursor.records += 1;
                    if (lane(record) == index) return record;
                }
                cursor.iterator = null;
            }
            const offset = cursor.next_page;
            try read(source, offset, cursor.page[0..8]);
            if (std.mem.eql(u8, cursor.page[0..8], "SMECTM01")) {
                if (source.length - offset != format.terminal_bytes) return error.TrailingBytes;
                cursor.ended = true;
                return null;
            }
            try read(source, offset + 8, cursor.page[8..format.page_header_bytes]);
            var decoder: format.Decoder = .{ .bytes = cursor.page[0..format.page_header_bytes] };
            const header = try decoder.get(format.PageHeader);
            if (!std.mem.eql(u8, &header.magic, "SMECPG01") or header.payload_bytes == 0 or header.payload_bytes > format.max_page_payload) return error.InvalidLength;
            const length = format.page_header_bytes + @as(usize, header.payload_bytes);
            try read(source, offset + format.page_header_bytes, cursor.page[format.page_header_bytes..length]);
            cursor.next_page += length;
            cursor.iterator = .{ .bytes = cursor.page[format.page_header_bytes..length], .remaining = header.record_count };
        }
        return null;
    }
    fn diagnoseRecord(self: *Session, index: usize, actual: format.Record, actual_bytes: []const u8) void {
        if (!@import("builtin").is_test) return;
        const diagnostic = &self.storage.diagnostic;
        if (diagnostic.reported or diagnostic.source == null) return;
        // assemble/compareRecord is Control-owned. Immutable-source I/O never
        // runs in an audio hook or producer, and uses a separate fixed budget:
        // at most eight forward file scans / eight terminal record counts.
        const expected = self.diagnosticExpected(index) catch |err| {
            diagnostic.reported = true;
            std.debug.print("causal replay record diagnostic unavailable: lane={d} error={s}\n", .{ index, @errorName(err) });
            return;
        };
        const ordinal = self.storage.actual_counts[index] + 1;
        if (expected == null) {
            diagnostic.reported = true;
            std.debug.print("causal replay first differing record: lane={d} ordinal={d} expected=EOF actual={any}\n", .{ index, ordinal, normalized(actual) });
            return;
        }
        const expected_bytes = format.encodeRecord(normalized(expected.?), &diagnostic.codec) catch |err| {
            diagnostic.reported = true;
            std.debug.print("causal replay record diagnostic unavailable: lane={d} error={s}\n", .{ index, @errorName(err) });
            return;
        };
        if (std.mem.eql(u8, expected_bytes, actual_bytes)) return;
        diagnostic.reported = true;
        var offset: usize = 0;
        while (offset < @min(expected_bytes.len, actual_bytes.len) and expected_bytes[offset] == actual_bytes[offset]) : (offset += 1) {}
        std.debug.print("causal replay first differing record: lane={d} ordinal={d} expected_tag={s} actual_tag={s} first_byte={d} lengths={d}/{d}\n", .{ index, ordinal, @tagName(expected.?), @tagName(actual), offset, expected_bytes.len, actual_bytes.len });
        std.debug.print("causal replay expected normalized={any}\ncausal replay actual normalized={any}\n", .{ normalized(expected.?), normalized(actual) });
        // Canonical bytes preserve every actual field even where Zig's nested
        // pretty-printer abbreviates payloads. One record pair only, bounded
        // by max_record_bytes per side; no per-event log or field suppression.
        std.debug.print("causal replay expected encoded={any}\ncausal replay actual encoded={any}\n", .{ expected_bytes, actual_bytes });
    }
    fn compareRecord(raw: *anyopaque, record: format.Record) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.hashRecord(record, true);
    }
    fn storeRecord(self: *Session, record: format.Record) !void {
        try self.hashRecord(record, false);
        switch (record) {
            .stream_consumed_range => |range| {
                if (range.key.role != .render or range.key.ordinal == 0 or range.key.ordinal > max_operations_per_role or self.storage.check_count + self.storage.consumed_range_count >= max_checks) return error.DependencyCapacity;
                const call = &self.storage.consumed_calls[@intCast(range.key.ordinal - 1)];
                if (call.sealed or call.count == 48) return error.InvalidOrder;
                if (call.count == 0) call.first = @intCast(self.storage.consumed_range_count);
                if (@as(usize, call.first) + call.count != self.storage.consumed_range_count) return error.InvalidOrder;
                self.storage.consumed_ranges[self.storage.consumed_range_count] = .{ .value = range };
                self.storage.consumed_range_count += 1;
                call.count += 1;
            },
            .stream_consumed_call_end => |value| {
                if (value.key.role != .render or value.key.ordinal == 0 or value.key.ordinal > max_operations_per_role) return error.InvalidOrder;
                const call = &self.storage.consumed_calls[@intCast(value.key.ordinal - 1)];
                if (call.sealed or call.count != value.ranges) return error.InvalidOrder;
                call.sealed = true;
                call.publications = value.publications;
            },
            .begin => |begin| {
                const role_index = @intFromEnum(begin.key.role);
                const index = self.storage.counts[role_index];
                if (index == max_operations_per_role or begin.key.ordinal != index + 1) return error.OperationBudget;
                self.storage.operations[role_index][index] = .{ .begin = begin };
                self.storage.counts[role_index] += 1;
            },
            .end => |end| {
                const role_index = @intFromEnum(end.key.role);
                if (end.key.ordinal == 0 or end.key.ordinal > self.storage.counts[role_index]) return error.InvalidOrder;
                self.storage.operations[role_index][@intCast(end.key.ordinal - 1)].end = end;
            },
            .worker => |fact| if (fact.value == .clock) {
                const clock = fact.value.clock;
                if (fact.key.role != .worker or fact.key.ordinal == 0 or fact.key.ordinal > self.storage.counts[2] or clock.error_code != 0) return error.InvalidInput;
                const op = &self.storage.operations[2][@intCast(fact.key.ordinal - 1)];
                const stage = @intFromEnum(clock.stage);
                if (op.clock[stage] != null) return error.InvalidInput;
                op.clock[stage] = .{ .job = clock.job, .sample = .{ .value = clock.value, .available = clock.available, .error_code = clock.error_code } };
            },
            else => {},
        }
    }
    fn read(source: ImmutableSource, offset: u64, bytes: []u8) !void {
        if (offset > source.length or bytes.len > source.length - offset) return error.Truncated;
        try source.read_at(source.context, offset, bytes);
    }
    fn preflight(self: *Session, source: ImmutableSource) !void {
        if (source.length > self.options.limits.file_bytes or source.length < format.header_bytes + format.terminal_bytes) return error.InvalidLength;
        try read(source, 0, self.storage.page[0..format.header_bytes]);
        self.header = try format.decodeHeader(self.storage.page[0..format.header_bytes]);
        // A file cannot opt its caller into the larger resource contract.
        // Legacy tighter budgets retain their existing validation behavior.
        if (self.header.limits.pending_dependencies > format.default_pending_dependencies and
            self.options.limits.pending_dependencies < self.header.limits.pending_dependencies) return error.InvalidLimits;
        self.storage.preflight_reader = try format.Reader.init(self.header);
        const reader = &self.storage.preflight_reader.?;
        try self.storage.preflight_validator.initInto(self.header, self.options.limits);
        const validator = &self.storage.preflight_validator;
        try validator.setDependencySink(.{ .context = self, .emit = dependency });
        try validator.setCheckSink(.{ .context = self, .emit = expectedCheck });
        var offset: u64 = format.header_bytes;
        while (offset < source.length) {
            try read(source, offset, self.storage.page[0..8]);
            if (std.mem.eql(u8, self.storage.page[0..8], "SMECTM01")) {
                if (source.length - offset != format.terminal_bytes) return error.TrailingBytes;
                try read(source, offset, self.storage.page[0..format.terminal_bytes]);
                self.terminal = try reader.acceptTerminal(self.storage.page[0..format.terminal_bytes]);
                offset += format.terminal_bytes;
                break;
            }
            try read(source, offset, self.storage.page[0..format.page_header_bytes]);
            var decoder: format.Decoder = .{ .bytes = self.storage.page[0..format.page_header_bytes] };
            const page = try decoder.get(format.PageHeader);
            if (page.payload_bytes > format.max_page_payload) return error.InvalidLength;
            const length = format.page_header_bytes + @as(usize, page.payload_bytes);
            try read(source, offset, self.storage.page[0..length]);
            var iterator = try reader.acceptPage(self.storage.page[0..length]);
            while (try iterator.next()) |record| {
                try validator.feed(record);
                try self.storeRecord(record);
            }
            offset += length;
        }
        if (offset != source.length) return error.TrailingBytes;
        _ = try reader.finishEOF();
        _ = try validator.finish();
        for (self.storage.operations[1][0..self.storage.counts[1]], 0..) |op, index| {
            const call = self.storage.consumed_calls[index];
            if (!call.sealed) return error.MissingTerminal;
            var total: u64 = 0;
            for (self.storage.consumed_ranges[call.first .. @as(usize, call.first) + call.count]) |range| {
                if (range.value.count > op.begin.args.render.frames) return error.InvalidInput;
                total += range.value.count;
            }
            if (total != call.publications or total > @as(u64, op.begin.args.render.frames) * 48) return error.InvalidInput;
        }
        try self.proof.requireBinding(self.header, self.terminal);
        // Mint eligibility only after real EOF, full semantic closure, consumed
        // coverage and the exact independently supplied PCM proof all succeeded.
        self.verified_proof = .{ .driver = self, .storage = self.storage, .recorder = &self.recorder, .owner = self.owner, .header = self.header, .terminal = self.terminal, .pcm = self.proof };
    }
    fn groupTerminalPoint(context: *anyopaque, point: rt.music_group.TerminalReplayPoint) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.checkpoint(.{ .site = validation.Site.group_terminal_publish, .edge = point.edge, .index = @as(u64, point.group.index), .generation = point.group.generation, .value = @as(u64, @intFromBool(point.published)) });
    }
    fn groupEventPoint(raw: *anyopaque, point: @import("sme-trace").QueueCheckpoint) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.checkpoint(point);
    }
    fn installHooks(self: *Session) void {
        self.owner.control.offline_causal_replay = .{ .context = self, .checkpoint = runtimePoint };
        self.owner.control.offline_causal_group_terminal = .{ .context = self, .checkpoint = groupTerminalPoint };
        self.owner.renderer.offline_causal_replay = .{ .context = self, .checkpoint = runtimePoint };
        self.owner.control.scheduled.offline_causal_replay = .{ .context = self, .checkpoint = schedulerPoint };
        self.owner.generation.?.service.?.offline_causal_replay = .{ .context = self, .checkpoint = streamPoint, .clock = rawClock };
        self.owner.group_events.offline_causal_hooks = .{ .context = self, .epoch = 1, .checkpoint = groupEventPoint };
        self.hooks_installed = true;
    }
    fn removeHooks(self: *Session) void {
        if (!self.hooks_installed) return;
        self.owner.group_events.offline_causal_hooks = null;
        self.owner.control.offline_causal_replay = null;
        self.owner.control.offline_causal_group_terminal = null;
        // Failed cleanup may retain prepared cells until original resources
        // drain. Clear their offline callbacks after in-flight roles parked.
        for (&self.owner.control.prepared_groups) |*slot| slot.terminal.offline_causal_replay = null;
        self.owner.renderer.offline_causal_replay = null;
        self.owner.control.scheduled.offline_causal_replay = null;
        self.owner.generation.?.service.?.offline_causal_replay = null;
        self.hooks_installed = false;
    }
    fn controlOperation(self: *Session, args: format.OperationArgs, expected: format.OperationResult) !void {
        switch (args) {
            .submit => |submit| {
                const request: contract.MusicRequestPayload = switch (submit.request) {
                    .set_state => |state| .{ .set_state = .{ .state = @enumFromInt(state.state), .priority = state.priority } },
                    .stop_emergency => .{ .stop = .emergency_ramp },
                    else => return error.UnsupportedOperation,
                };
                // This is the independently loaded owner's real BankRef. The
                // recorded handle incarnation is never installed in the owner.
                const bank: v1.BankRefV1 = .{ .context = self.owner.config.context, .handle = .{ .index = 0, .generation = self.owner.handle_incarnation }, .asset_generation = self.owner.generation.?.runtime_generation };
                _ = try invocation(v1.RequestTicketV1, self.recorder.submit(bank, request));
            },
            .tick => |limit| {
                const actual = self.recorder.controlTick(limit);
                if (expected == .tick_failed) {
                    // Execute once. The original engine must independently
                    // reach its real failing acquire, including partial effects.
                    switch (actual) {
                        .not_started => |err| return err,
                        .started => |result| {
                            if (result.recording_failure != .none) return error.IncompleteTrace;
                            if (result.engine_result) |_| {
                                return error.OutputMismatch;
                            } else |err| {
                                if (err != error.InvalidState or resident.MusicRuntime.causalFailureCodeV1(err) != expected.tick_failed.failure) return error.OutputMismatch;
                                if (self.owner.tick != expected.tick_failed.control_tick or self.storage.capture.frontier.tick_serial != expected.tick_failed.frontier_tick_serial) return error.OutputMismatch;
                            }
                        },
                    }
                } else {
                    _ = try invocation(usize, actual);
                }
            },
            .poll_receipt => {
                _ = try invocation(?v1.ReceiptV1, self.recorder.pollReceipt());
            },
            .poll_phase_receipt => {
                _ = try invocation(?contract.PhaseReceipt, self.recorder.pollPhaseReceipt());
            },
            .retire_sources => try invocation(void, self.recorder.retireDrainedSources()),
            else => return error.UnsupportedOperation,
        }
    }
    /// Serialized witness counters are process-local labels, not globally
    /// unique owner identities. Freshness comes from the virgin-owner checks
    /// before begin and this actual Session's live attachment and storage pin.
    fn requireFreshOwnerBinding(self: *Session, expected: format.Header) !void {
        const capture = &self.storage.capture;
        const actual = capture.header orelse return error.FreshOwnerMismatch;
        if (!std.meta.eql(normalizedHeader(actual), normalizedHeader(expected)) or
            self.recorder.owner != self.owner or self.recorder.storage != capture or
            self.recorder.phase != .active or !capture.comparison_only or
            capture.address != capture or capture.session_address != &self.recorder or
            self.owner.causal_driver_pin != @as(?*anyopaque, @ptrCast(capture))) return error.FreshOwnerMismatch;
        const session = capture.rs orelse return error.FreshOwnerMismatch;
        const binding = self.owner.renderer.render_causal_binding orelse return error.FreshOwnerMismatch;
        if (session.bridge != &capture.render_bridge or binding.bridge != &capture.render_bridge or
            binding.music_owner != self.owner or !std.meta.eql(binding.session, session) or
            actual.bindings.render.incarnation != session.incarnation or
            actual.bindings.render.generation != session.generation or
            actual.bindings.render.owner_identity != session.renderer_identity or
            actual.bindings.render.interval_id != session.interval_id) return error.FreshOwnerMismatch;
    }
    fn requirePreflightProof(self: *Session, recorder: *recording.Session) !void {
        const proof = self.verified_proof orelse return error.InvalidState;
        if (proof.driver != self or proof.storage != self.storage or proof.recorder != recorder or recorder != &self.recorder or
            proof.owner != self.owner or recorder.owner != self.owner or recorder.storage != &self.storage.capture or
            self.control_thread != std.Thread.getCurrentId() or self.abort.load(.acquire) or self.failure.load(.acquire) != .none or
            self.cleanup_complete or self.state == .failed or self.state == .complete or proof.complete or
            !std.meta.eql(proof.header, self.header) or !std.meta.eql(proof.terminal, self.terminal) or !std.meta.eql(proof.pcm, self.proof)) return error.InvalidState;
        if (self.storage.preflight_reader == null) return error.InvalidState;
        const reader = &self.storage.preflight_reader.?;
        const validator = &self.storage.preflight_validator;
        if (reader.failed or !validator.finished or validator.failed or validator.cursor.records != self.terminal.record_count or
            !std.meta.eql(reader.chain.header, self.header) or !std.meta.eql(validator.header, self.header) or
            !std.meta.eql(try reader.finishEOF(), self.terminal)) return error.InvalidState;
        const edges = validator.dependencies.sink orelse return error.InvalidState;
        const checks = validator.check_sink orelse return error.InvalidState;
        if (edges.context != @as(*anyopaque, @ptrCast(self)) or edges.emit != dependency or checks.context != @as(*anyopaque, @ptrCast(self)) or checks.emit != expectedCheck) return error.InvalidState;
        try self.proof.requireBinding(self.header, self.terminal);
    }
    /// Cross-module entry points accept only this driver's actual pinned recorder.
    /// No caller-supplied sink or finished flag grants the recording fast path.
    pub fn requireVerifiedAdmission(self: *Session, recorder: *recording.Session, limits: format.Limits, interval_id: u64) !void {
        try self.requirePreflightProof(recorder);
        if (self.state != .preflight or self.verified_proof.?.actual_header != null or recorder.phase != .initialized or
            !std.meta.eql(limits, self.header.limits) or interval_id != self.header.session.interval_id or
            self.storage.capture.address != &self.storage.capture or self.storage.capture.session_address != recorder or
            self.owner.causal_driver_pin != @as(?*anyopaque, @ptrCast(&self.storage.capture))) return error.InvalidState;
    }
    /// Read the source rule only through the completed, full-header-bound
    /// preflight capability. No current-capture default can rewrite an old tape.
    pub fn verifiedRulesVersion(self: *Session, recorder: *recording.Session, limits: format.Limits, interval_id: u64) !u16 {
        try self.requireVerifiedAdmission(recorder, limits, interval_id);
        return self.verified_proof.?.header.identity.rules_version;
    }
    pub fn acceptVerifiedAttachment(self: *Session, recorder: *recording.Session) !void {
        try self.requirePreflightProof(recorder);
        if (self.state != .preflight or self.verified_proof.?.actual_header != null or self.storage.capture.verified_replay != self) return error.InvalidState;
        try self.requireFreshOwnerBinding(self.header);
        self.verified_proof.?.actual_header = self.storage.capture.header.?;
    }
    pub fn compareVerifiedRecord(self: *Session, recorder: *recording.Session, record: format.Record) !void {
        const proof = self.verified_proof orelse return error.InvalidState;
        if (proof.driver != self or proof.storage != self.storage or proof.recorder != recorder or recorder != &self.recorder or
            proof.actual_header == null or proof.complete or self.state != .running or self.abort.load(.acquire) or
            self.failure.load(.acquire) != .none or self.storage.capture.verified_replay != self or self.storage.capture.comparator != null) return error.InvalidState;
        try self.hashRecord(record, true);
    }
    fn requireComparedRecords(self: *Session) !void {
        if (!std.meta.eql(self.storage.expected_counts, self.storage.actual_counts)) {
            std.debug.print("causal replay lane count mismatch: expected={any} actual={any}\n", .{ self.storage.expected_counts, self.storage.actual_counts });
            return error.OutputMismatch;
        }
        for (self.storage.expected_hash, self.storage.actual_hash, 0..) |expected, actual, index| {
            var eh = expected;
            var ah = actual;
            var eb: [32]u8 = undefined;
            var ab: [32]u8 = undefined;
            eh.final(&eb);
            ah.final(&ab);
            if (!std.mem.eql(u8, &eb, &ab)) {
                std.debug.print("causal replay lane digest mismatch: lane={d} count={d}\n", .{ index, self.storage.actual_counts[index] });
                return error.OutputMismatch;
            }
        }
    }
    /// Called after real joins, queue drain, witness terminal creation/detach and
    /// Cursor.finish, but before the recorder may claim a successful seal.
    pub fn finishVerifiedReplay(self: *Session, recorder: *recording.Session) !void {
        errdefer |err| {
            self.fail(.comparator);
            std.debug.print("causal replay proof finalizer failed: error={s}\n", .{@errorName(err)});
        }
        try self.requirePreflightProof(recorder);
        const capture = &self.storage.capture;
        const actual = self.verified_proof.?.actual_header orelse return error.InvalidState;
        if (self.state != .running or self.hooks_installed or recorder.phase != .active or
            !recorder.render_driver.joined or !recorder.worker_driver.joined or !recorder.sources_retiring or
            !self.owner.generation.?.retirementAcknowledged() or capture.verified_replay != self or
            !capture.comparison_only or capture.comparator != null or capture.export_claimed.load(.acquire) or capture.failureValue() != .none or
            capture.address != capture or capture.session_address != recorder or self.owner.causal_driver_pin != @as(?*anyopaque, @ptrCast(capture)) or
            !std.meta.eql(actual, capture.header orelse return error.InvalidState) or
            !std.meta.eql(normalizedHeader(actual), normalizedHeader(self.header)) or
            self.owner.causal_sink != null or self.owner.renderer.render_causal_binding != null or
            self.owner.control.readiness_binding != null or self.owner.control.control_frontier_binding != null or
            self.owner.control.stream_acceptance_binding != null or self.owner.group_events.public_causal_sink != null or
            self.owner.generation.?.service.?.public_causal_consumed_sink != null) return error.InvalidState;
        const rs = capture.rs orelse return error.InvalidState;
        if (rs.bridge != &capture.render_bridge or rs.incarnation != actual.bindings.render.incarnation or
            rs.generation != actual.bindings.render.generation or rs.renderer_identity != actual.bindings.render.owner_identity or
            rs.interval_id != actual.bindings.render.interval_id) return error.FreshOwnerMismatch;
        for (&self.finished) |*finished| if (!finished.load(.acquire)) return error.MissingCheckpoint;
        try self.owner.requireCausalDrainV1();
        try capture.cursor.?.finish();
        for (self.storage.graph[0..self.storage.graph_count]) |edge| if (!edge.source_seen or !edge.target_seen) return error.MissingCheckpoint;
        for (self.storage.checks[0..self.storage.check_count]) |value| if (!value.seen) {
            self.dumpMissingChecks();
            return error.MissingCheckpoint;
        };
        for (self.storage.consumed_ranges[0..self.storage.consumed_range_count]) |range| if (range.before_pending or range.seen != range.value.count) return error.MissingCheckpoint;
        try self.requireComparedRecords();
        try self.proof.requirePcm(capture.pcm.finish());
        self.verified_proof.?.complete = true;
    }
    pub fn testCleanupWorker(self: *Session) !void {
        if (!@import("builtin").is_test) @compileError("test-only owned Worker drain");
        try self.cleanupWorker();
    }
    pub fn testNormalizedHeader(header: format.Header) format.Header {
        if (!@import("builtin").is_test) @compileError("test-only normalized header qualification");
        return normalizedHeader(header);
    }
    pub fn testComparedRecords(self: *Session, expected: []const format.Record, actual: []const format.Record) !void {
        if (!@import("builtin").is_test) @compileError("test-only complete record comparison");
        self.storage.expected_hash = @splat(.init(.{}));
        self.storage.actual_hash = @splat(.init(.{}));
        self.storage.expected_counts = @splat(0);
        self.storage.actual_counts = @splat(0);
        for (expected) |record| try self.hashRecord(record, false);
        for (actual) |record| try self.hashRecord(record, true);
        try self.requireComparedRecords();
    }
    pub fn testPreflightForAdmission(self: *Session, source: ImmutableSource, proof: format.PcmProof) !void {
        if (!@import("builtin").is_test) @compileError("test-only actual completed preflight qualification");
        if (self.state != .loading or std.Thread.getCurrentId() != self.control_thread or
            self.load_request.load(.acquire) != self.load_returned.load(.acquire)) return error.InvalidState;
        try self.owner.validateCausalReplayOwnerV1();
        self.proof = proof;
        self.state = .preflight;
        errdefer {
            self.state = .failed;
            self.abort.store(true, .release);
        }
        try self.preflight(source);
    }
    /// Qualification of the same live check, without rewriting an input tape or
    /// resetting process-local identity counters to manufacture a collision.
    pub fn testRequireFreshOwnerBinding(self: *Session, expected: format.Header) !void {
        if (!@import("builtin").is_test) @compileError("test-only fresh owner binding qualification");
        try self.requireFreshOwnerBinding(expected);
    }
    /// Full immutable-file preflight precedes witness attachment and every
    /// recorded operation. A started operation is executed exactly once, even
    /// when a later checkpoint, comparator or work budget fails.
    pub fn recompute(self: *Session, source: ImmutableSource, proof: format.PcmProof, options: Options) anyerror!Result {
        return self.recomputeImpl(source, proof, options) catch |err| {
            self.recorder.diagnoseAssemblyFailure();
            std.debug.print("causal replay original error={s} stage={s} steps={d} checkpoint_work={d} reason={s} operations={d}/{d}/{d}\n", .{ @errorName(err), @tagName(self.diagnostic_stage.load(.acquire)), self.steps, self.checkpoint_work, @tagName(self.failure.load(.acquire)), self.operation[0].load(.acquire), self.operation[1].load(.acquire), self.operation[2].load(.acquire) });
            return err;
        };
    }
    fn recomputeImpl(self: *Session, source: ImmutableSource, proof: format.PcmProof, options: Options) anyerror!Result {
        if (self.state != .loading or std.Thread.getCurrentId() != self.control_thread or self.load_request.load(.acquire) != self.load_returned.load(.acquire)) return error.InvalidState;
        try options.limits.validate();
        if (options.wait_steps == 0 or options.wait_steps > 100_000_000) return error.InvalidLimits;
        self.options = options;
        self.proof = proof;
        self.state = .preflight;
        self.diagnosticStage(.preflight);
        errdefer {
            self.state = .failed;
            self.abort.store(true, .release);
        }
        try self.owner.validateCausalReplayOwnerV1();
        try self.preflight(source);
        if (@import("builtin").is_test) self.storage.diagnostic.source = source;
        self.diagnosticStage(.preflight_done);
        self.diagnosticStage(.admission);
        var begun = false;
        var begin_steps: u64 = 0;
        while (!begun) {
            if (begin_steps == options.wait_steps) return error.WorkBudget;
            begin_steps += 1;
            switch (self.recorder.beginForVerifiedReplay(self.header.limits, self.header.session.interval_id, self)) {
                .not_started => |err| {
                    if (err != error.DrainRequired) return err;
                    self.diagnosticStage(.admission_wait);
                    if (@import("builtin").is_test and begin_steps == 1) std.debug.print("causal replay begin handshake pause={any} parked={any} load={d}/{d}\n", .{ self.recorder.worker_driver.pause.load(.acquire), self.recorder.worker_driver.parked.load(.acquire), self.load_request.load(.acquire), self.load_returned.load(.acquire) });
                    std.Thread.yield() catch {};
                },
                .started => |value| {
                    try value.engine_result;
                    if (value.recording_failure != .none) return error.IncompleteTrace;
                    begun = true;
                },
            }
        }
        self.diagnosticStage(.admitted);
        try self.requireFreshOwnerBinding(self.header);
        self.installHooks();
        try self.recorder.startRender(self, renderMain);
        self.state = .running;
        self.diagnosticStage(.running);
        self.run.store(true, .release);
        for (self.storage.operations[0][0..self.storage.counts[0]]) |op| {
            try self.check();
            self.startOperation(op.begin.key);
            try self.check();
            try self.controlOperation(op.begin.args, (op.end orelse return error.InvalidOrder).result);
            self.endOperation(op.begin.key);
            try self.pump();
        }
        self.finished[0].store(true, .release);
        while (!self.finished[1].load(.acquire) or !self.finished[2].load(.acquire)) {
            try self.check();
            try self.pump();
            std.Thread.yield() catch {};
        }
        try self.check();
        // Final pin/job/receipt checks still run on the real owner. A terminal
        // record or parked thread is never a substitute for these joins.
        self.diagnosticStage(.roles_finished);
        try self.owner.requireCausalDrainV1();
        self.diagnosticStage(.joining);
        try self.recorder.joinProducers();
        self.diagnosticStage(.joined);
        self.removeHooks();
        try invocation(void, self.recorder.trySealQuiescent());
        // Deferred quiescence release can latch a failure after the Invocation
        // value was formed. Never certify that newly failed capture.
        if (self.storage.capture.failureValue() != .none) return error.IncompleteTrace;
        const verified = self.verified_proof orelse return error.InvalidState;
        if (!verified.complete) return error.IncompleteTrace;
        const pcm = self.storage.capture.pcm.finish();
        try self.recorder.releaseOwner();
        self.state = .complete;
        self.diagnosticStage(.complete);
        return .{ .operations = .{ self.storage.counts[0], self.storage.counts[1], self.storage.counts[2] }, .pcm = pcm, .joined = true, .fresh_owner = true };
    }
    /// One allowance for this Session's entire cleanup, including caller retries.
    /// Exhaustion retains every borrowed object and never authorizes new work.
    pub fn cleanupBudgetExhausted(self: *const Session) bool {
        return self.cleanup_budget_exhausted;
    }
    fn chargeCleanup(self: *Session) !void {
        if (self.cleanup_work >= self.options.wait_steps) {
            if (@import("builtin").is_test and !self.cleanup_budget_exhausted) std.debug.print("causal replay cleanup budget exhausted work={d} limit={d}\n", .{ self.cleanup_work, self.options.wait_steps });
            self.cleanup_budget_exhausted = true;
            return error.DrainPending;
        }
        self.cleanup_work += 1;
    }
    fn consumeCompletedCleanup(self: *Session) void {
        const worker = self.load_request.load(.acquire);
        if (worker > self.cleanup_worker_consumed and self.load_returned.load(.acquire) == worker) {
            self.cleanup_worker_consumed = worker;
            _ = self.load_result catch |err| failed: {
                if (self.cleanup_late_error == null) self.cleanup_late_error = err;
                break :failed false;
            };
        }
        const render = self.render_request.load(.acquire);
        if (render > self.cleanup_render_consumed and self.render_returned.load(.acquire) == render) {
            self.cleanup_render_consumed = render;
            self.recovery_render_result catch |err| {
                if (self.cleanup_late_error == null) self.cleanup_late_error = err;
            };
        }
    }
    fn waitCounter(self: *Session, counter: *std.atomic.Value(u64), expected: u64) !void {
        while (counter.load(.acquire) != expected) {
            try self.chargeCleanup();
            std.Thread.yield() catch {};
        }
    }
    fn cleanupWorker(self: *Session) !void {
        const previous = self.load_request.load(.acquire);
        if (previous > self.cleanup_worker_consumed) {
            // Consume a late invocation exactly once, whether success or error.
            // A subsequent explicit cleanup step may issue a NEW Worker call.
            try self.waitCounter(&self.load_returned, previous);
            self.cleanup_worker_consumed = previous;
            _ = try self.load_result;
            return;
        }
        if (previous == std.math.maxInt(u64)) return error.WorkBudget;
        try self.chargeCleanup();
        self.load_request.store(previous + 1, .release);
        try self.waitCounter(&self.load_returned, previous + 1);
        self.cleanup_worker_consumed = previous + 1;
        _ = try self.load_result;
    }
    fn cleanupRender(self: *Session) !void {
        const previous = self.render_request.load(.acquire);
        if (previous > self.cleanup_render_consumed) {
            try self.waitCounter(&self.render_returned, previous);
            self.cleanup_render_consumed = previous;
            try self.recovery_render_result;
            return;
        }
        if (previous == std.math.maxInt(u64)) return error.WorkBudget;
        try self.chargeCleanup();
        self.recovery_frames = self.owner.config.quantum_frames;
        self.render_request.store(previous + 1, .release);
        try self.waitCounter(&self.render_returned, previous + 1);
        self.cleanup_render_consumed = previous + 1;
        try self.recovery_render_result;
    }
    /// Explicit failure cleanup: cancels replay waits, then performs a NEW
    /// ordinary stop/drain and source retirement on the original role threads.
    /// No executed failed command is retried and no comparison success is given.
    /// DrainPending/close failure keeps this object and all borrowed storage
    /// pinned. Retries share one wait_steps allowance; after exhaustion they
    /// may consume an already-returned call but never issue new work.
    pub fn abortAndJoin(self: *Session) anyerror!void {
        if (self.state == .unused or std.Thread.getCurrentId() != self.control_thread) return error.InvalidState;
        if (self.cleanup_complete or self.state == .complete) return;
        self.diagnosticStage(.cleanup);
        errdefer |cleanup_error| std.debug.print("causal replay cleanup error={s} stop_started={any} work={d}\n", .{ @errorName(cleanup_error), self.cleanup_stop_started, self.cleanup_work });
        self.abort.store(true, .release);
        self.state = .failed;
        self.consumeCompletedCleanup();
        try self.chargeCleanup();
        if (self.cleanup_late_error) |err| return @as(anyerror!void, err);
        if (self.recorder.phase == .sealed) {
            self.removeHooks();
            try self.recorder.releaseOwner();
            self.cleanup_complete = true;
            return;
        }
        if (self.recorder.phase == .initialized) {
            // Shutdown polls settle loading/retirement on this original Worker.
            // No already executed Worker call is retried after a late return.
            var work: u64 = 0;
            while (true) {
                try self.chargeCleanup();
                if (try self.recorder.shutdownUnstarted()) break;
                if (work == 4096) return error.DrainPending;
                work += 1;
                try self.cleanupWorker();
            }
            try self.recorder.joinProducers();
            try self.recorder.releaseUnstartedOwner();
            self.cleanup_complete = true;
            return;
        }
        if (!self.recorder.render_driver.started) {
            try self.chargeCleanup();
            try self.recorder.startRender(self, renderMain);
        }
        if (self.run.load(.acquire)) {
            while (!self.finished[1].load(.acquire) or !self.finished[2].load(.acquire)) {
                try self.chargeCleanup();
                std.Thread.yield() catch {};
            }
        }
        self.removeHooks();
        self.storage.capture.fail(.cancelled);
        self.cleanup_stop_started = self.cleanup_stop_started or self.owner.state == .stopping;
        var drained = false;
        for (0..4096) |_| {
            // Collect the last completed Render before testing the real drain.
            // Polling host receipts alone cannot advance collected_call_sequence.
            try self.chargeCleanup();
            _ = try engine(usize, self.recorder.controlTick(rt.max_control_drain));
            while (true) {
                try self.chargeCleanup();
                if (try engine(?v1.ReceiptV1, self.recorder.pollReceipt()) == null) break;
            }
            while (true) {
                try self.chargeCleanup();
                if (try engine(?contract.PhaseReceipt, self.recorder.pollPhaseReceipt()) == null) break;
            }
            if (self.owner.requireCausalDrainV1()) |_| {
                drained = true;
                break;
            } else |_| {}
            if (!self.cleanup_stop_started) {
                const bank: v1.BankRefV1 = .{ .context = self.owner.config.context, .handle = .{ .index = 0, .generation = self.owner.handle_incarnation }, .asset_generation = self.owner.generation.?.runtime_generation };
                try self.chargeCleanup();
                switch (self.recorder.submit(bank, .{ .stop = .emergency_ramp })) {
                    .not_started => |err| {
                        // No stop ran. Pending preparation needs NEW bounded
                        // owner operations before a later admission attempt.
                        if (err != error.UnsupportedCapability and err != error.InvalidState and err != error.DrainPending and err != error.DrainRequired) return @as(anyerror!void, err);
                    },
                    .started => |result| {
                        self.cleanup_stop_started = true;
                        _ = try result.engine_result;
                    },
                }
            }
            try self.cleanupWorker();
            const control_needs_render = if (self.owner.control.drainStatus()) |_| false else |err| switch (err) {
                error.DrainPending => true,
                else => return @as(anyerror!void, err),
            };
            // Match the production host: an unread PCM publication still needs
            // a real gate even after ordinary Control obligations are clear.
            const stream_service = self.owner.control.streaming_service;
            const visibility_needs_render = if (stream_service) |service| service.hasPendingRenderVisibility() else false;
            if (control_needs_render or visibility_needs_render) try self.cleanupRender();
        }
        if (!drained) return error.DrainPending;
        if (!self.recorder.sources_retiring) {
            try self.chargeCleanup();
            try engine(void, self.recorder.retireDrainedSources());
        }
        var work: u64 = 0;
        while (!self.owner.generation.?.retirementAcknowledged()) {
            if (work == 4096) return error.DrainPending;
            work += 1;
            try self.cleanupWorker();
        }
        try self.recorder.joinProducers();
        engine(void, self.recorder.trySealQuiescent()) catch |err| if (err != error.IncompleteTrace) return @as(anyerror!void, err);
        try self.recorder.releaseOwner();
        self.cleanup_complete = true;
    }
};

pub fn testConsumedRangeComparators() !void {
    if (!@import("builtin").is_test) @compileError("test-only affine release regression");
    const t = std.testing;
    std.debug.print("causal consumed fixed storage: range_entry={d} range_table={d} call_table={d} ledger={d} total={d} shared_check_limit={d}\n", .{ @sizeOf(StoredConsumedRange), @sizeOf([max_checks]StoredConsumedRange), @sizeOf([max_operations_per_role]ConsumedCall), @sizeOf(validation.ConsumedCuts), Storage.requiredBytes(), max_checks });
    const storage = try t.allocator.create(Storage);
    defer t.allocator.destroy(storage);
    // Initialize only the bounded fields touched by this pure mailbox proof.
    storage.counts = .{ 0, 2, 0 };
    storage.consumed_calls[0] = .{ .first = 0, .count = 1, .publications = 4, .sealed = true };
    storage.consumed_calls[1] = .{ .first = 1, .count = 0, .publications = 0, .sealed = true };
    storage.consumed_ranges[0] = .{ .value = .{ .key = .{ .role = .render, .ordinal = 1 }, .index = 0, .generation = 3, .first = 17, .last = 20, .count = 4 } };
    var session: Session = .{ .storage = storage };
    var at: validation.Point = .{ .role = .render, .operation = 1, .site = .stream_consumed_release, .index = 0, .generation = 3, .occurrence = 1, .edge = .before };
    try t.expectError(error.OutputMismatch, session.consumedCheckpoint(at, 18));
    var wrong = at;
    wrong.generation = 4;
    try t.expectError(error.OutputMismatch, session.consumedCheckpoint(wrong, 17));
    wrong = at;
    wrong.occurrence = 2;
    try t.expectError(error.OutputMismatch, session.consumedCheckpoint(wrong, 18));
    const end: validation.Point = .{ .role = .render, .operation = 1, .site = .operation, .edge = .after };
    try t.expectError(error.MissingCheckpoint, session.consumedCheckpoint(end, 0));
    for (0..4) |index| {
        at.occurrence = @intCast(index + 1);
        at.edge = .before;
        try session.consumedCheckpoint(at, 17 + index);
        try t.expectError(error.OutputMismatch, session.consumedCheckpoint(at, 17 + index));
        at.edge = .after;
        try session.consumedCheckpoint(at, 17 + index);
        try t.expectError(error.OutputMismatch, session.consumedCheckpoint(at, 17 + index));
    }
    try session.consumedCheckpoint(end, 0);
    var zero_end = end;
    zero_end.operation = 2;
    try session.consumedCheckpoint(zero_end, 0);
    storage.consumed_calls[1].sealed = false;
    try t.expectError(error.MissingTerminal, session.consumedCheckpoint(zero_end, 0));
}

pub fn testClaimComparatorIdentity() !void {
    if (!@import("builtin").is_test) @compileError("test-only claim qualification");
    const t = std.testing;
    const control: format.Record = .{ .service_claim = .{
        .key = .{ .role = .control, .ordinal = 1 },
        .value = .{ .kind = .{ .stream_close = .{ .handle = .{ .index = 0, .generation = 1 }, .parent_attempt = 1 } }, .token = 5, .observed = 6 },
    } };
    const worker: format.Record = .{ .service_claim = .{
        .key = .{ .role = .worker, .ordinal = 1 },
        .value = .{ .kind = .worker, .token = 6, .observed = 5 },
    } };
    try t.expectEqual(@as(usize, 0), Session.lane(control));
    try t.expectEqual(@as(usize, 2), Session.lane(worker));
    try t.expectEqualDeep(control, Session.normalized(control));
    try t.expectEqualDeep(worker, Session.normalized(worker));
    const release: format.Record = .{ .service_worker_release = .{
        .key = .{ .role = .worker, .ordinal = 1 },
        .value = .{ .token = 6, .ticket = 1 },
    } };
    const observed: format.Record = .{ .service_release_observation = .{
        .key = .{ .role = .control, .ordinal = 2 },
        .token = 6,
        .after_claims = 1,
    } };
    try t.expectEqual(@as(usize, 2), Session.lane(release));
    try t.expectEqual(@as(usize, 0), Session.lane(observed));
    try t.expectEqualDeep(release, Session.normalized(release));
    try t.expectEqualDeep(observed, Session.normalized(observed));
}
