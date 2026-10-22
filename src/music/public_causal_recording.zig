//! Public, bounded direct-host causal recording. This owns driver threads, not
//! another runtime. A copied handle, an idle sample, and failure acknowledgements
//! never prove that a producer has returned or release its pinned storage.
const std = @import("std");
const rt = @import("bugu_audio").runtime;
const trace = @import("sme-trace");
const resident = @import("resident_runtime.zig");
const replay = @import("public_causal_replay.zig");
const contract = @import("contract.zig");
const v1 = @import("runtime_contract.zig");
pub const format = @import("causal_recording_format.zig");
pub const Validation = @import("public_causal_validation.zig");
const validation = Validation;
const handoff = rt.capture_handoff_control;
const transport = @import("sme-capture-page-transport");
const qw = rt.readiness_witness;
const cw = rt.control_frontier_witness;
const aw = rt.stream_acceptance_witness;
const rw = rt.render_causal_witness;
const stream = rt.streaming.stream;
const order = @import("sme-capture-order");
pub const OperationBinding = @import("order_operation_binding.zig");

pub const Format = format;
pub const Limits = format.Limits;
/// Rules 2 adds actual busy-claim evidence only where the original CAS can
/// carry a lock-free holder token. Rules 1 remains available for old tapes.
pub const current_rules_version: u16 = if (stream.supports_causal_claim_tokens) 2 else 1;
pub const Failure = handoff.Failure;
pub const max_pcm_frames: u32 = 4096;
/// Profile 5 records direct Render calls of at most this many frames. This is
/// independent of the engine quantum and PCM storage capacity. Larger valid
/// engine calls still render once, but permanently fail their recording.
pub const max_recordable_render_frames = format.max_recordable_render_frames;
pub const control_lane_cells = 256;
pub const render_lane_cells = 16;
pub const worker_lane_cells = 1024;
pub const render_progress_lane_cells = 256;
pub const render_progress_per_call = format.max_render_progress_per_call;
pub const Phase = enum(u8) { initialized, active, sealed, detached };
pub fn Invocation(comptime T: type) type {
    return union(enum) {
        not_started: anyerror,
        /// The original executed outcome, including any partial effects on
        /// failure. recording_failure is only the current recorder status;
        /// later assembly/sealing can still reject incomplete evidence.
        started: struct { engine_result: anyerror!T, recording_failure: Failure },
    };
}
pub const Comparator = struct { context: *anyopaque, record: *const fn (*anyopaque, format.Record) anyerror!void };
pub const Status = struct { phase: Phase, recording_failure: Failure, engine: v1.StatusV1, render_joined: bool, worker_joined: bool, complete: bool };
pub const DrainStatus = struct { engine_drained: bool, receipts_drained: bool, sources_retired: bool, render_joined: bool, worker_joined: bool };

/// A single non-RT consumer diagnostic, never an encoded/replayable record.
/// The cursor and validator counters are the assembler checkpoint after the
/// original failure, not a simultaneous engine snapshot or causal proof.
pub const AssemblyFailure = struct {
    pub const Stage = enum { normalize, cursor, validator, comparator, flush, encode };
    pub const LaneProgress = struct { published: u64, consumed: u64 };
    stage: Stage,
    actual_error: anyerror,
    lane: ?u8,
    raw_record: format.Record,
    cursor: format.Cursor,
    validator_ran: bool,
    validator_records: u64,
    validator_work: u64,
    validator_work_limit: u64,
    validator_pending: usize,
    validator_capacity: usize,
    validator_checks: u64,
    unsupported_cuts: u64,
    semantic_sequences: [4]u64,
    /// Independent acquire samples at first failure, never a coherent snapshot
    /// or permission to discard evidence. Null means the lane handle refused.
    lane_progress: [8]?LaneProgress = @splat(null),
};

/// One producer, one assembler consumer. Neither side retries or waits.
fn Lane(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Stamped = struct { value: T, endpoint: ?order.EndpointReceipt };
        items: [capacity]T = undefined,
        // Optional caller-owned sidecar. Immutable attachment, same SPSC cell
        // ownership and publication as items; never an independent fact queue.
        endpoint_cells: ?[]?order.EndpointReceipt = null,
        head: std.atomic.Value(u64) = .init(0),
        tail: std.atomic.Value(u64) = .init(0),
        fn push(self: *@This(), value: T) bool {
            return self.pushStamped(value, null);
        }
        fn pushStamped(self: *@This(), value: T, endpoint: ?order.EndpointReceipt) bool {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == std.math.maxInt(u64) or head - tail >= capacity) return false;
            if (self.endpoint_cells) |cells| {
                if (cells.len != capacity) return false;
                cells[head % capacity] = endpoint;
            } else if (endpoint != null) return false;
            self.items[head % capacity] = value;
            self.head.store(head + 1, .release);
            return true;
        }
        fn pop(self: *@This()) ?T {
            const stamped = self.popStamped() orelse return null;
            return stamped.value;
        }
        fn popStamped(self: *@This()) ?Stamped {
            const tail = self.tail.load(.monotonic);
            if (tail == self.head.load(.acquire)) return null;
            const result: Stamped = .{
                .value = self.items[tail % capacity],
                .endpoint = if (self.endpoint_cells) |cells| cells[tail % capacity] else null,
            };
            self.tail.store(tail + 1, .release);
            return result;
        }
        fn empty(self: *const @This()) bool {
            return self.tail.load(.acquire) == self.head.load(.acquire);
        }
    };
}
const RenderFact = union(enum) {
    scheduler_progress: @FieldType(format.Record, "scheduler_progress"),
    group_terminal: @FieldType(format.Record, "group_terminal"),
    group_event_queue: @FieldType(format.Record, "group_event_queue"),
    stream_consumed_range: @FieldType(format.Record, "stream_consumed_range"),
    stream_consumed_call_end: @FieldType(format.Record, "stream_consumed_call_end"),
};
const RenderCell = struct {
    key: format.OperationKey,
    frames: u32,
    before_frame: u64,
    after_frame: u64,
    before_sequence: u64,
    after_sequence: u64,
    completed: bool,
    begin_endpoint: ?order.EndpointReceipt = null,
    end_endpoint: ?order.EndpointReceipt = null,
    samples: [max_pcm_frames * 2]f32 = undefined,
};

/// Optional, caller-owned and pinned until genuine producer AND assembler
/// quiescence. Arrays follow the existing lane ownership, not another queue.
/// Default/old sessions do not allocate this object or attach these sidecars.
pub const OperationBindingStorage = struct {
    address: ?*OperationBindingStorage = null,
    used: bool = false,
    attached: bool = false,
    sink: OperationBinding.Sink = undefined,
    control: [control_lane_cells]?order.EndpointReceipt = undefined,
    worker: [worker_lane_cells]?order.EndpointReceipt = undefined,

    pub fn initInPlace(self: *OperationBindingStorage, sink: OperationBinding.Sink) !void {
        if (self.address != null) return error.AlreadyInitialized;
        self.sink = sink;
        self.address = self;
    }
    fn pristine(self: *const OperationBindingStorage) bool {
        return self.address == self and !self.used and !self.attached;
    }
};

/// All addresses remain pinned from init through producer AND exporter joins.
/// The host owns allocation. init never copies this large object or allocates.
pub const Storage = struct {
    address: ?*Storage = null,
    session_address: ?*Session = null,
    comparison_only: bool = false,
    /// Immutable non-publishing prerequisite mode, never a recording profile.
    order_prerequisite_only: bool = false,
    // Committed only after pin admission; a DrainRequired retry changes none
    // of this mode state. The eventual immutable header carries the same rule.
    rules_version: u16 = 1,
    comparator: ?Comparator = null,
    // Only the concrete replay driver can transfer a completed immutable proof.
    verified_replay: ?*replay.Session = null,
    export_claimed: std.atomic.Value(bool) = .init(false),
    export_joined: std.atomic.Value(bool) = .init(false),
    pin: handoff.PinFailureAtomic = .{},
    capture: ?handoff.Session = null,
    readiness: qw.Bridge = .{},
    frontier: cw.Bridge = .{},
    acceptance: aw.Bridge = .{},
    render_bridge: rw.Bridge = .{},
    qs: ?qw.Session = null,
    cs: ?cw.Session = null,
    as: ?aw.Session = null,
    rs: ?rw.Session = null,
    control_lane: Lane(format.Record, control_lane_cells) = .{},
    render_lane: Lane(RenderCell, render_lane_cells) = .{},
    render_progress_lane: Lane(RenderFact, render_progress_lane_cells) = .{},
    worker_lane: Lane(format.Record, worker_lane_cells) = .{},
    pool: transport.Pool = .{},
    assembler_bytes: [transport.page_bytes]u8 = undefined,
    record_bytes: [transport.page_bytes]u8 = undefined,
    header: ?format.Header = null,
    sealed_terminal: ?format.Terminal = null,
    chain: ?format.Chain = null,
    cursor: ?format.Cursor = null,
    validator: validation.Validator = undefined,
    next_lane: u8 = 0,
    // Consumer-only fairness, including across max_records=1 calls.
    control_priority_yield: bool = false,
    readiness_detached: bool = false,
    pcm: format.PcmAccumulator = format.PcmAccumulator.init(),
    page_used: usize = 0,
    page_records: u32 = 0,
    limits: Limits = .{},
    failure: std.atomic.Value(Failure) = .init(.none),
    // Sole assembler/Control ownership. Producers and the exporter never read
    // or write this slot; it survives subsequent failure/drain/close activity.
    assembly_failure: ?AssemblyFailure = null,

    pub fn requiredBytes() usize {
        return @sizeOf(Storage);
    }
    pub fn failExport(self: *Storage) void {
        self.fail(.writer_failure);
    }
    pub fn recordingFailure(self: *const Storage) Failure {
        return self.failureValue();
    }
    pub fn fail(self: *Storage, reason: Failure) void {
        // All attached producers and the writer race on the same first-failure
        // atomic. A later local writer error must never shadow its winner.
        if (self.capture) |capture| {
            handoff.fail(capture, reason) catch {
                _ = self.failure.cmpxchgStrong(.none, reason, .acq_rel, .acquire);
            };
            return;
        }
        _ = self.failure.cmpxchgStrong(.none, reason, .acq_rel, .acquire);
    }
    pub fn failureValue(self: *const Storage) Failure {
        if (self.capture) |capture| return handoff.failure(capture) catch {
            const fallback = self.failure.load(.acquire);
            return if (fallback != .none) fallback else .invalid_state;
        };
        const local = self.failure.load(.acquire);
        return local;
    }
};
pub const storage_bytes = @sizeOf(Storage);

const Driver = struct {
    thread: ?std.Thread = null,
    identity: std.atomic.Value(std.Thread.Id) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    pause: std.atomic.Value(bool) = .init(false),
    parked: std.atomic.Value(bool) = .init(false),
    returned: std.atomic.Value(bool) = .init(false),
    joined: bool = false,
    started: bool = false,
    ordinal: u64 = 0,
    driving: bool = false,
    // This handshake is in the host driver, outside every actual RT operation.
    // No live runtime/observer hook waits here.
    fn safePoint(self: *Driver) bool {
        if (self.pause.load(.acquire)) {
            self.parked.store(true, .release);
            while (self.pause.load(.acquire) and !self.stop.load(.acquire)) std.Thread.yield() catch {};
            self.parked.store(false, .release);
        }
        return !self.stop.load(.acquire);
    }
};

pub const RenderDriver = struct {
    session: *Session,
    pub fn keepRunning(self: *RenderDriver) bool {
        return self.session.render_driver.safePoint();
    }
    /// Recording supports 1..max_recordable_render_frames per call, even when
    /// the configured engine quantum is larger. An engine-legal oversized call
    /// returns started after rendering, with a permanent recording failure.
    pub fn render(self: *RenderDriver, output: []f32, frames: u32) Invocation(void) {
        return self.session.renderOwned(output, frames);
    }
};
pub const WorkerDriver = struct {
    session: *Session,
    pub fn keepRunning(self: *WorkerDriver) bool {
        return self.session.worker_driver.safePoint();
    }
    /// Before begin this pumps ordinary loading, without recording or changing
    /// its real Worker identity. During capture the same thread records work.
    pub fn workerOne(self: *WorkerDriver) Invocation(bool) {
        return self.session.workerOwned();
    }
};

pub const Session = struct {
    owner: *resident.MusicRuntime,
    storage: *Storage,
    control_thread: std.Thread.Id,
    phase: Phase = .initialized,
    control_ordinal: u64 = 0,
    control_events: u64 = 0,
    worker_events: u64 = 0,
    control_driving: bool = false,
    control_operation: ?std.meta.Tag(format.OperationArgs) = null,
    // Sole-role state, never a cross-thread allocator or lock-order clock.
    control_claim_ordinal: u64 = 0,
    worker_claim_ordinal: u64 = 0,
    sources_retiring: bool = false,
    /// Same pinned lanes across all directly wired subsystems. No asynchronous
    /// consumer is installed: serialized Control owns manual draining.
    prerequisite_order: ?order.Roles = null,
    operation_bindings: ?*OperationBindingStorage = null,
    order_attached: bool = false,
    control_key: ?format.OperationKey = null,
    worker_key: ?format.OperationKey = null,
    exclusion_witness: rt.streaming.stream.ServiceExclusionWitness = undefined,
    render_key: ?format.OperationKey = null,
    render_progress_count: u32 = 0,
    render_progress_total: u64 = 0,
    consumed_ranges: rt.streaming.stream.ConsumedRanges = .{},
    render_driver: Driver = .{},
    worker_driver: Driver = .{},
    render_fn: ?*const fn (*RenderDriver, *anyopaque) void = null,
    worker_fn: ?*const fn (*WorkerDriver, *anyopaque) void = null,
    render_context: ?*anyopaque = null,
    worker_context: ?*anyopaque = null,
    assembler_lane: ?u8 = null,
    test_render_terminal_gate_delta: if (@import("builtin").is_test) u64 else void = if (@import("builtin").is_test) 0 else {},
    test_diagnostics: if (@import("builtin").is_test) struct {
        tick_errors: u64 = 0,
        last_tick_error: ?anyerror = null,
        summary_reported: bool = false,
    } else void = if (@import("builtin").is_test) .{} else {},

    /// Must precede the first Worker/load call. This is intentionally separate
    /// from begin: existing Worker affinity is never reset or guessed from idle.
    pub fn init(owner: *resident.MusicRuntime, storage: *Storage) !Session {
        if (owner.control_thread != std.Thread.getCurrentId() or owner.worker_thread != null or
            owner.causal_driver_pin != null or storage.address != null) return error.InvalidState;
        storage.address = storage;
        owner.causal_driver_pin = storage;
        return .{ .owner = owner, .storage = storage, .control_thread = std.Thread.getCurrentId() };
    }
    fn requireControl(self: *const Session) !void {
        if (self.control_thread != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.storage.address != self.storage or self.owner.causal_driver_pin != @as(?*anyopaque, @ptrCast(self.storage)) or
            (self.storage.session_address != null and self.storage.session_address != self)) return error.StaleSession;
    }
    pub fn startWorker(self: *Session, context: *anyopaque, run: *const fn (*WorkerDriver, *anyopaque) void) !void {
        try self.requireControl();
        if (self.phase != .initialized or self.worker_driver.started) return error.InvalidState;
        self.storage.session_address = self;
        self.worker_context = context;
        self.worker_fn = run;
        self.worker_driver.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        self.worker_driver.started = true;
    }
    pub fn startRender(self: *Session, context: *anyopaque, run: *const fn (*RenderDriver, *anyopaque) void) !void {
        try self.requireControl();
        if (self.phase != .active or self.render_driver.started) return error.InvalidState;
        self.render_context = context;
        self.render_fn = run;
        self.render_driver.thread = try std.Thread.spawn(.{}, renderMain, .{self});
        self.render_driver.started = true;
    }
    fn workerMain(self: *Session) void {
        self.worker_driver.identity.store(std.Thread.getCurrentId(), .release);
        var driver: WorkerDriver = .{ .session = self };
        self.worker_fn.?(&driver, self.worker_context.?);
        self.worker_driver.returned.store(true, .release);
    }
    fn renderMain(self: *Session) void {
        self.render_driver.identity.store(std.Thread.getCurrentId(), .release);
        var driver: RenderDriver = .{ .session = self };
        self.render_fn.?(&driver, self.render_context.?);
        self.render_driver.returned.store(true, .release);
    }
    pub fn requestProducerStop(self: *Session) !void {
        try self.requireControl();
        if (self.phase == .active and (!self.sources_retiring or !self.owner.generation.?.retirementAcknowledged())) return error.DrainRequired;
        self.render_driver.stop.store(true, .release);
        self.worker_driver.stop.store(true, .release);
    }
    /// Actual OS-thread joins, never a caller-supplied assertion or idle sample.
    /// Does not stop playback or seal any evidence.
    pub fn joinProducers(self: *Session) !void {
        try self.requireControl();
        try self.requestProducerStop();
        if (self.render_driver.thread) |thread| {
            thread.join();
            self.render_driver.thread = null;
            self.render_driver.joined = true;
        } else if (!self.render_driver.started) self.render_driver.joined = true;
        if (self.worker_driver.thread) |thread| {
            thread.join();
            self.worker_driver.thread = null;
            self.worker_driver.joined = true;
        } else if (!self.worker_driver.started) self.worker_driver.joined = true;
    }
    /// Nonblocking handshake: the first call may return DrainRequired while
    /// the owned Worker reaches its operation-external safe point. Retry only
    /// that not_started result. No caller claim can supply the acknowledgement.
    const BeginMode = union(enum) {
        capture: u16,
        comparison: struct { comparator: Comparator, rules_version: u16 },
        verified: *replay.Session,
        prerequisite: struct { roles: order.Roles, bindings: ?*OperationBindingStorage = null },
    };
    pub fn begin(self: *Session, limits: Limits, interval_id: u64) Invocation(void) {
        return self.beginWithRules(limits, interval_id, current_rules_version);
    }
    /// Select wire rules explicitly without changing ordinary live validation.
    /// Unsupported token targets refuse rules 2 before any admission mutation.
    pub fn beginWithRules(self: *Session, limits: Limits, interval_id: u64, rules_version: u16) Invocation(void) {
        return self.beginMode(limits, interval_id, .{ .capture = rules_version });
    }
    fn beginMode(self: *Session, limits: Limits, interval_id: u64, mode: BeginMode) Invocation(void) {
        self.requireControl() catch |err| return .{ .not_started = err };
        limits.validate() catch |err| return .{ .not_started = err };
        if (self.phase != .initialized or self.storage.capture != null or interval_id == 0 or
            !self.worker_driver.started or self.worker_driver.returned.load(.acquire)) return .{ .not_started = error.InvalidState };
        if (mode != .capture and (self.owner.config_v1.kind != .offline or self.storage.export_claimed.load(.acquire))) return .{ .not_started = error.InvalidState };
        const rules_version = switch (mode) {
            .capture => |value| value,
            .prerequisite => current_rules_version,
            .comparison => |value| value.rules_version,
            .verified => |driver| driver.verifiedRulesVersion(self, limits, interval_id) catch |err| return .{ .not_started = err },
        };
        if (rules_version != 1 and rules_version != 2) return .{ .not_started = error.UnknownVersion };
        if (rules_version == 2 and !stream.supports_causal_claim_tokens) return .{ .not_started = error.UnsupportedOperation };
        if (mode == .prerequisite) {
            if (!order.supported_target or !mode.prerequisite.roles.pristine() or
                !self.orderBindingsClear())
                return .{ .not_started = error.InvalidState };
            if (mode.prerequisite.bindings) |bindings| if (!bindings.pristine())
                return .{ .not_started = error.InvalidState };
        }
        self.worker_driver.pause.store(true, .release);
        if (!self.worker_driver.parked.load(.acquire)) return .{ .not_started = error.DrainRequired };
        defer self.worker_driver.pause.store(false, .release);
        const identity = self.owner.requireCausalBeginV1() catch |err| return .{ .not_started = err };
        const service = self.owner.generation.?.service.?;
        if (service.profile.max_streams > format.consumed_slots) return .{ .not_started = error.UnsupportedCapacity };
        if (limits.pending_dependencies > format.default_pending_dependencies and service.profile.job_capacity > 48) return .{ .not_started = error.UnsupportedCapacity };
        if (service.next_generation != 1 or service.public_causal_consumed_sink != null) return .{ .not_started = error.InvalidState };
        if (identity.quantum_frames > limits.max_pcm_frames) return .{ .not_started = error.UnsupportedCapacity };
        const source_hash = self.owner.causalSourceSetHashV1() catch |err| return .{ .not_started = err };
        self.storage.limits = limits;
        self.storage.capture = self.storage.pin.initExclusive(interval_id) catch |err| return .{ .not_started = err };
        // Select a mode only after admission actually starts. A not_started
        // handshake cannot leak a verification bypass into a later generic begin.
        self.storage.comparison_only = mode != .capture;
        self.storage.order_prerequisite_only = mode == .prerequisite;
        self.prerequisite_order = if (mode == .prerequisite) mode.prerequisite.roles else null;
        self.operation_bindings = if (mode == .prerequisite) mode.prerequisite.bindings else null;
        self.storage.rules_version = rules_version;
        self.storage.comparator = if (mode == .comparison) mode.comparison.comparator else if (mode == .prerequisite)
            .{ .context = self, .record = prerequisiteRecord }
        else
            null;
        self.storage.verified_replay = if (mode == .verified) mode.verified else null;
        // Preserve a failure published before capture acquired its shared pin.
        const prior_failure = self.storage.failure.load(.acquire);
        if (prior_failure != .none) self.storage.fail(prior_failure);
        self.attach(identity, source_hash) catch |err| {
            self.storage.fail(.invalid_state);
            return .{ .started = .{ .engine_result = err, .recording_failure = self.storage.failureValue() } };
        };
        self.phase = .active;
        if (mode == .verified) mode.verified.acceptVerifiedAttachment(self) catch |err| {
            self.storage.fail(.invalid_state);
            return .{ .started = .{ .engine_result = err, .recording_failure = self.storage.failureValue() } };
        };
        return .{ .started = .{ .engine_result = {}, .recording_failure = self.storage.failureValue() } };
    }
    /// Test-only short-operation prerequisite. It deliberately retains the old
    /// operation/whole-history limits and cannot publish a complete recording.
    /// A future sustained profile must supply its own complete rule contract.
    pub fn beginOrderPrerequisiteForTest(self: *Session, limits: Limits, interval_id: u64, roles: order.Roles) Invocation(void) {
        if (!@import("builtin").is_test) @compileError("order prerequisite entry is test-only");
        return self.beginMode(limits, interval_id, .{ .prerequisite = .{ .roles = roles } });
    }
    pub fn beginBoundOrderPrerequisiteForTest(self: *Session, limits: Limits, interval_id: u64, roles: order.Roles, bindings: *OperationBindingStorage) Invocation(void) {
        if (!@import("builtin").is_test) @compileError("bound order prerequisite entry is test-only");
        return self.beginMode(limits, interval_id, .{ .prerequisite = .{ .roles = roles, .bindings = bindings } });
    }
    fn prerequisiteRecord(_: *anyopaque, _: format.Record) anyerror!void {
        // The unchanged live Validator already checked this short-operation
        // record. No comparison/replay equivalence claim is made by this sink.
    }
    fn orderBindingsClear(self: *const Session) bool {
        if (self.storage.control_lane.endpoint_cells != null or self.storage.worker_lane.endpoint_cells != null) return false;
        if (self.order_attached or self.owner.control.prerequisite_order != null or
            self.owner.renderer.prerequisite_order != null or self.owner.control.prerequisite_terminal_order != null or
            self.owner.control.scheduled.prerequisite_order != null or self.owner.group_events.order_control != null or
            self.owner.group_events.order_render != null) return false;
        if (self.owner.generation) |generation| if (generation.service) |service| if (service.prerequisite_order != null) return false;
        for (&self.owner.control.prepared_groups) |*group| if (group.terminal.prerequisite_order != null) return false;
        return true;
    }
    fn detachOrderPrerequisite(self: *Session) !void {
        if (!self.order_attached) return;
        const roles = self.prerequisite_order orelse return error.InvalidState;
        if (!self.render_driver.joined or !self.worker_driver.joined or self.control_driving or
            self.owner.control.prerequisite_order != roles.control or self.owner.renderer.prerequisite_order != roles.render or
            self.owner.control.prerequisite_terminal_order != roles.render) return error.DrainRequired;
        const scheduled = self.owner.control.scheduled.prerequisite_order orelse return error.InvalidState;
        if (scheduled.control != roles.control or scheduled.render != roles.render or scheduled.worker != roles.worker) return error.InvalidState;
        const events = &self.owner.group_events;
        const epoch = events.reset_epoch.load(.acquire);
        const control = events.order_control orelse return error.InvalidState;
        const render = events.order_render orelse return error.InvalidState;
        if (control.collector != roles.control or render.collector != roles.render or control.index != 0 or render.index != 0 or
            control.generation != epoch or render.generation != epoch) return error.InvalidState;
        // All checks precede any binding mutation. Genuine joins exclude cell
        // reuse here; publication itself never reads these cells after release.
        for (&self.owner.control.prepared_groups) |*group| if (group.terminal.prerequisite_order) |binding| {
            if (binding.collector != roles.render or binding.index != group.terminal.group.index or
                binding.generation != group.terminal.group.generation) return error.InvalidState;
        };
        if (self.operation_bindings) |bindings| {
            if (bindings.address != bindings or !bindings.attached or
                self.storage.control_lane.endpoint_cells == null or self.storage.worker_lane.endpoint_cells == null or
                self.storage.control_lane.endpoint_cells.?.ptr != &bindings.control or
                self.storage.worker_lane.endpoint_cells.?.ptr != &bindings.worker) return error.DrainRequired;
        }
        try self.owner.generation.?.service.?.detachOrderPrerequisiteQuiescent();
        self.owner.control.prerequisite_order = null;
        self.owner.renderer.prerequisite_order = null;
        self.owner.control.prerequisite_terminal_order = null;
        self.owner.control.scheduled.prerequisite_order = null;
        events.order_control = null;
        events.order_render = null;
        for (&self.owner.control.prepared_groups) |*group| group.terminal.prerequisite_order = null;
        self.order_attached = false;
    }
    fn detachOperationBindings(self: *Session) !void {
        const bindings = self.operation_bindings orelse return;
        if (self.order_attached or !self.render_driver.joined or !self.worker_driver.joined or self.control_driving or
            !self.storage.control_lane.empty() or !self.storage.worker_lane.empty() or !self.storage.render_lane.empty()) return error.DrainRequired;
        if (bindings.address != bindings or !bindings.attached or
            self.storage.control_lane.endpoint_cells == null or self.storage.worker_lane.endpoint_cells == null or
            self.storage.control_lane.endpoint_cells.?.ptr != &bindings.control or
            self.storage.worker_lane.endpoint_cells.?.ptr != &bindings.worker) return error.InvalidState;
        // Queued endpoint metadata stays borrowed until the sole assembler has
        // consumed it, including the bounded failed-recording cleanup path.
        self.storage.control_lane.endpoint_cells = null;
        self.storage.worker_lane.endpoint_cells = null;
        bindings.attached = false;
        // Later witness-close retries must not dereference released sidecars.
        self.operation_bindings = null;
    }
    fn bindingsDetached(self: *const Session) bool {
        return self.orderBindingsClear() and
            self.owner.causal_sink == null and self.owner.group_events.public_causal_sink == null and self.owner.control.readiness_binding == null and
            self.owner.control.control_frontier_binding == null and self.owner.control.stream_acceptance_binding == null and
            self.owner.renderer.render_causal_binding == null and
            (if (self.owner.generation) |generation| if (generation.service) |service| service.public_causal_consumed_sink == null else true else true);
    }
    /// Failed load/admission cleanup, only when capture never attached or its
    /// attachment fully rolled back. Keep the same Worker alive until true.
    pub fn shutdownUnstarted(self: *Session) !bool {
        try self.requireControl();
        if (self.phase != .initialized or self.storage.header != null or !self.bindingsDetached()) return error.InvalidState;
        // A caller may abandon the first not_started begin handshake. Release
        // that owned safe point so the same Worker can perform source cleanup.
        self.worker_driver.pause.store(false, .release);
        try self.owner.shutdown();
        if (self.owner.worker_guard.load(.acquire)) return false;
        if (self.owner.load.state.load(.acquire) != .idle or self.owner.load.candidate != null or self.owner.reload.ownsResources()) return false;
        if (self.owner.generation) |generation| {
            if (self.owner.active_group != null or self.owner.pending != null or self.owner.preparing != null or
                generation.windowCount() != 0 or self.owner.control.telemetry().live_instances != 0) return false;
            for (self.owner.retired_groups) |group| if (group != null) return false;
            generation.requestRetirement() catch return false;
            if (!generation.retirementAcknowledged()) return false;
        }
        return !self.owner.worker_guard.load(.acquire) and self.owner.active_producers.load(.acquire) == 0;
    }
    pub fn releaseUnstartedOwner(self: *Session) !void {
        try self.requireControl();
        if (self.phase != .initialized or self.storage.header != null or !self.bindingsDetached() or
            (self.worker_driver.started and !self.worker_driver.joined) or
            (self.render_driver.started and !self.render_driver.joined) or
            !self.owner.shutdown_requested.load(.acquire) or self.owner.load.state.load(.acquire) != .idle or
            self.owner.load.candidate != null or self.owner.reload.ownsResources()) return error.DrainRequired;
        if (self.owner.generation) |generation| if (!generation.retirementAcknowledged()) return error.DrainRequired;
        self.owner.causal_driver_pin = null;
        self.phase = .detached;
    }
    /// Offline reconstruction uses all genuine producers and validation, but
    /// cannot create a publishable recording or masquerade as a joined writer.
    pub fn beginForReplay(self: *Session, limits: Limits, interval_id: u64, comparator: Comparator) Invocation(void) {
        return self.beginForReplayWithRules(limits, interval_id, comparator, current_rules_version);
    }
    /// Generic comparators still run the full live Validator for either rule
    /// version. A caller-selected version never grants a verified replay proof.
    pub fn beginForReplayWithRules(self: *Session, limits: Limits, interval_id: u64, comparator: Comparator, rules_version: u16) Invocation(void) {
        return self.beginMode(limits, interval_id, .{ .comparison = .{ .comparator = comparator, .rules_version = rules_version } });
    }
    /// A fixed concrete driver, never an arbitrary comparator or caller boolean.
    /// Its completed preflight and pinned identities are checked before mutation.
    pub fn beginForVerifiedReplay(self: *Session, limits: Limits, interval_id: u64, driver: *replay.Session) Invocation(void) {
        return self.beginMode(limits, interval_id, .{ .verified = driver });
    }
    fn attach(self: *Session, identity: trace.Header, source_hash: format.Hash) !void {
        const storage = self.storage;
        const capture = storage.capture.?;
        try storage.frontier.configureContinuous(capture);
        try storage.acceptance.configureContinuous(capture);
        try storage.readiness.configureContinuous(capture);
        try storage.render_bridge.configureContinuous(capture);
        storage.readiness.capture_acquisitions = true;
        storage.readiness.capture_reconciliation = true;
        storage.render_bridge.capture_terminal_invalidations = true;
        storage.render_bridge.capture_reconciliation = true;
        storage.cs = try self.owner.control.attachControlFrontierWitness(&storage.frontier, capture.descriptor.interval_id);
        errdefer {
            self.owner.control.closeControlFrontierWitness(storage.cs.?) catch {};
            while ((storage.frontier.pop(storage.cs.?) catch null) != null) {}
            self.owner.control.detachControlFrontierWitness(storage.cs.?) catch {};
        }
        storage.as = try self.owner.control.attachStreamAcceptanceWitness(&storage.acceptance, capture.descriptor.interval_id);
        errdefer {
            self.owner.control.closeStreamAcceptanceWitness(storage.as.?) catch {};
            while ((storage.acceptance.pop(storage.as.?) catch null) != null) {}
            self.owner.control.detachStreamAcceptanceWitness(storage.as.?) catch {};
        }
        const token = try self.owner.renderer.acquireDeviceQuiescence();
        defer self.owner.renderer.releaseDeviceQuiescence(token) catch {};
        try self.owner.requireCausalGroupQueueInitialV1();
        const service = self.owner.generation.?.service.?;
        if (service.profile.max_streams > format.consumed_slots or service.next_generation != 1 or service.public_causal_consumed_sink != null) return error.InvalidState;
        storage.rs = try self.owner.renderer.attachRenderCausalWitness(&storage.render_bridge, token, capture.descriptor.interval_id);
        errdefer {
            self.owner.renderer.closeRenderCausalWitness(token, storage.rs.?) catch {};
            while ((storage.render_bridge.pop(storage.rs.?) catch null) != null) {}
            self.owner.renderer.detachRenderCausalWitness(token, storage.rs.?) catch {};
        }
        storage.qs = try self.owner.control.attachReadinessWitness(&storage.readiness, self.owner.renderer, token, capture.descriptor.interval_id);
        errdefer {
            self.owner.control.closeReadinessWitness(storage.qs.?, self.owner.renderer, token) catch {};
            while ((storage.readiness.pop(storage.qs.?) catch null) != null) {}
            self.owner.control.detachReadinessWitness(storage.qs.?) catch {};
        }
        const cs = storage.cs.?;
        const as = storage.as.?;
        const qs = storage.qs.?;
        const rs = storage.rs.?;
        const header: format.Header = .{
            .recording_profile = try format.recordingProfileForLimits(storage.limits),
            .identity = .{ .compiler_version = identity.compiler_version, .algorithm_version = identity.algorithm_version, .bank_content_hash = identity.bank_content_hash, .bank_profile = identity.profile, .seed = identity.seed, .initial_state_hash = identity.initial_state_hash, .sample_rate = identity.sample_rate, .quantum_frames = identity.quantum_frames, .bank_major = identity.bank_major, .bank_minor = identity.bank_minor, .bank_build_id = identity.bank_build_id, .generation = identity.generation, .capacity_profile_hash = identity.capacity_profile_hash, .source_set_hash = source_hash, .service_profile_hash = self.owner.generation.?.service.?.profile.hash(), .context = self.owner.config.context, .rules_version = storage.rules_version },
            .session = .{ .incarnation = capture.descriptor.incarnation, .interval_id = capture.descriptor.interval_id },
            .limits = storage.limits,
            .bindings = .{
                .frontier = .{ .incarnation = cs.incarnation, .generation = cs.generation, .owner_identity = cs.owner_identity, .interval_id = cs.interval_id },
                .acceptance = .{ .incarnation = as.incarnation, .generation = as.generation, .owner_identity = as.owner_identity, .interval_id = as.interval_id },
                .readiness = .{ .incarnation = qs.incarnation, .generation = qs.generation, .owner_identity = cs.owner_identity, .interval_id = qs.interval_id },
                .render = .{ .incarnation = rs.incarnation, .generation = rs.generation, .owner_identity = rs.renderer_identity, .interval_id = rs.interval_id },
                .readiness_manifest = storage.readiness.manifest,
                .render_manifest = storage.render_bridge.manifest,
            },
        };
        try header.validate();
        try storage.pool.initInPlace(capture.descriptor.incarnation);
        const encoded = try format.encodeHeader(header, &storage.record_bytes);
        if (!storage.comparison_only) try self.publishBytes(encoded);
        storage.chain = try format.Chain.init(header);
        storage.cursor = try format.Cursor.init(header);
        try storage.validator.initInto(header, storage.limits);
        // Still under the genuine Worker parked handshake and Render quiescence.
        // No subsequent fallible step follows these pointer publications.
        if (self.prerequisite_order) |roles| {
            const events = &self.owner.group_events;
            const epoch = events.reset_epoch.load(.acquire);
            if (epoch == 0 or !self.orderBindingsClear()) return error.InvalidState;
            if (self.operation_bindings) |bindings| {
                if (!bindings.pristine() or self.storage.control_lane.head.load(.acquire) != 0 or
                    self.storage.worker_lane.head.load(.acquire) != 0) return error.InvalidState;
            }
            try service.attachOrderPrerequisiteQuiescent(roles);
            if (self.operation_bindings) |bindings| {
                self.storage.control_lane.endpoint_cells = &bindings.control;
                self.storage.worker_lane.endpoint_cells = &bindings.worker;
                bindings.used = true;
                bindings.attached = true;
            }
            self.owner.control.prerequisite_order = roles.control;
            self.owner.renderer.prerequisite_order = roles.render;
            self.owner.control.prerequisite_terminal_order = roles.render;
            self.owner.control.scheduled.prerequisite_order = roles;
            events.order_control = .{ .collector = roles.control, .index = 0, .generation = epoch };
            events.order_render = .{ .collector = roles.render, .index = 0, .generation = epoch };
            for (&self.owner.control.prepared_groups) |*group| if (group.occupied) {
                group.terminal.prerequisite_order = .{ .collector = roles.render, .index = group.terminal.group.index, .generation = group.terminal.group.generation };
            };
            self.order_attached = true;
        }
        // These immutable values are initialized before releasing Worker pause
        // and before an exporter may start. They are never cleared at detach.
        storage.header = header;
        self.owner.causal_sink = .{ .context = self, .permitted = allowed, .input = inputFact, .schedule = scheduleFact, .invalidate = invalidate };
        self.owner.generation.?.service.?.public_causal_worker_sink = .{ .context = self, .emit = workerFact };
        // The initial pause still owns all callers here. Never reset this
        // pinned, lock-protected diagnostic sequence during active capture.
        self.exclusion_witness = .{ .sink = .{
            .context = self,
            .emit = exclusionFact,
            .overflow = exclusionOverflow,
            .claim_token = if (storage.rules_version == 2) claimToken else null,
            .claim_attempt = if (storage.rules_version == 2) claimAttempt else null,
            .worker_release = if (storage.rules_version == 2) workerRelease else null,
        } };
        self.owner.generation.?.service.?.public_causal_exclusion = &self.exclusion_witness;
        self.owner.control.scheduled.public_causal_publication_sink = .{ .context = self, .emit = schedulerPublication };
        self.owner.control.scheduled.public_causal_progress_sink = .{ .context = self, .emit = schedulerProgress };
        self.owner.control.public_causal_group_terminal_sink = .{ .context = self, .emit = groupTerminal };
        self.owner.control.public_causal_group_source_final_sink = .{ .context = self, .emit = groupSourceFinal };
        self.owner.group_events.public_causal_sink = .{ .context = self, .epoch = format.group_event_epoch, .emit = groupEventQueue, .invalidate = invalidate };
        service.public_causal_consumed_sink = .{ .context = self, .emit = consumedPublication };
    }
    fn publishBytes(self: *Session, bytes: []const u8) !void {
        if (self.storage.order_prerequisite_only) return error.UnsupportedOperation;
        const reservation = try self.storage.pool.reserveRecord(bytes.len);
        @memcpy(try self.storage.pool.writable(reservation), bytes);
        try self.storage.pool.commitRecord(reservation, bytes.len);
    }
    fn flushPage(self: *Session) !void {
        const storage = self.storage;
        if (storage.page_used == 0) return;
        const bytes = try storage.chain.?.encodePage(storage.assembler_bytes[0..storage.page_used], storage.page_records, &storage.record_bytes);
        try self.publishBytes(bytes);
        storage.page_used = 0;
        storage.page_records = 0;
    }
    fn assemble(self: *Session, raw_record: format.Record) anyerror!void {
        if (self.storage.failureValue() != .none) return;
        const storage = self.storage;
        var stage: AssemblyFailure.Stage = .normalize;
        errdefer |err| {
            if (storage.assembly_failure == null) {
                const validator = &storage.validator;
                storage.assembly_failure = .{
                    .stage = stage,
                    .actual_error = err,
                    .lane = self.assembler_lane,
                    .raw_record = raw_record,
                    .cursor = storage.cursor.?,
                    .validator_ran = storage.verified_replay == null,
                    .validator_records = validator.cursor.records,
                    .validator_work = validator.dependencies.work,
                    .validator_work_limit = validator.dependencies.work_limit,
                    .validator_pending = validator.dependencies.pending_total,
                    .validator_capacity = validator.dependencies.capacity,
                    .validator_checks = validator.checks,
                    .unsupported_cuts = validator.unsupported_cuts,
                    .semantic_sequences = validator.semantic_sequences,
                    .lane_progress = self.sampleAssemblyLaneProgress(),
                };
            }
            storage.fail(.dependency_budget);
        }
        // Convert only codec-defined actual observation outcomes to stable
        // wire codes. Unknown source errors remain unrecordable failures.
        const record = try format.normalizeRecordForRules(raw_record, storage.header.?.identity.rules_version);
        stage = .cursor;
        try storage.cursor.?.accept(record);
        stage = .validator;
        if (storage.verified_replay == null) try storage.validator.feed(record);
        if (storage.comparison_only) {
            stage = .comparator;
            if (storage.verified_replay) |driver| {
                try driver.compareVerifiedRecord(self, record);
            } else {
                const comparator = storage.comparator orelse return error.InvalidState;
                try comparator.record(comparator.context, record);
            }
            return;
        }
        // Flush before encoding, because record_bytes is also the frame output
        // buffer. No record span survives a buffer reuse.
        stage = .flush;
        if (storage.page_used + format.max_record_bytes > format.max_page_payload) try self.flushPage();
        stage = .encode;
        const bytes = try format.encodeRecord(record, &storage.record_bytes);
        @memcpy(storage.assembler_bytes[storage.page_used..][0..bytes.len], bytes);
        storage.page_used += bytes.len;
        storage.page_records += 1;
    }
    /// Optional host-side reporting, after serviceAssembler returns to Control.
    /// The caller decides whether to print; no live producer calls this method.
    pub fn diagnoseAssemblyFailure(self: *const Session) void {
        const failure = if (self.storage.assembly_failure) |*value| value else return;
        std.debug.print("first causal assembler source failure: stage={s} error={s} lane={any} validator_ran={any} cursor_records={d} cursor_steps={d} validator_records={d} validator_work={d}/{d} pending={d}/{d} checks={d} unsupported_cuts={d} semantic_sequences={any} raw_record={any}\n", .{
            @tagName(failure.stage),   @errorName(failure.actual_error), failure.lane,                 failure.validator_ran,     failure.cursor.records,     failure.cursor.steps,
            failure.validator_records, failure.validator_work,           failure.validator_work_limit, failure.validator_pending, failure.validator_capacity, failure.validator_checks,
            failure.unsupported_cuts,  failure.semantic_sequences,       failure.raw_record,
        });
        std.debug.print("first causal assembler lane progress (independent acquire samples, published/consumed): {any}\n", .{failure.lane_progress});
        switch (failure.raw_record) {
            .readiness => |value| diagnoseObservedErrors("readiness", value.payload),
            .acceptance => |value| diagnoseObservedErrors("acceptance", value),
            else => {},
        }
    }
    fn sampleAssemblyLaneProgress(self: *const Session) [8]?AssemblyFailure.LaneProgress {
        const storage = self.storage;
        var result: [8]?AssemblyFailure.LaneProgress = @splat(null);
        inline for (.{ "control_lane", "worker_lane", "render_lane", "render_progress_lane" }, .{ 0, 1, 2, 7 }) |name, index| {
            const lane = &@field(storage, name);
            result[index] = .{ .published = lane.head.load(.acquire), .consumed = lane.tail.load(.acquire) };
        }
        if (storage.cs) |session| {
            if (storage.frontier.status(session)) |value| result[3] = .{ .published = value.events_published, .consumed = value.events_consumed } else |_| {}
        }
        if (storage.as) |session| {
            if (storage.acceptance.status(session)) |value| result[4] = .{ .published = value.events_published, .consumed = value.events_consumed } else |_| {}
        }
        if (storage.qs) |session| {
            if (storage.readiness.status(session)) |value| result[5] = .{ .published = value.events_published, .consumed = value.events_consumed } else |_| {}
        }
        if (storage.rs) |session| {
            if (storage.render_bridge.status(session)) |value| result[6] = .{ .published = value.events_published, .consumed = value.events_consumed } else |_| {}
        }
        return result;
    }
    // Non-RT consumer diagnostic. Never called by a producer and
    // never changes admission, encoding, or the original failure result.
    fn observedErrorName(code: u32) []const u8 {
        inline for (.{ error.DrainPending, error.InvalidState, error.InvalidHandle, error.CapacityExceeded, error.StaleHandle, error.QueueFull, error.NotReady }) |known| {
            if (code == @intFromError(known)) return @errorName(known);
        }
        return "unmapped actual error";
    }
    fn diagnoseObservedErrors(label: []const u8, value: anytype) void {
        switch (@typeInfo(@TypeOf(value))) {
            .@"struct" => |info| inline for (info.fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "error_code") or std.mem.eql(u8, field.name, "last_error_code") or std.mem.eql(u8, field.name, "service_error")) {
                    const code = @field(value, field.name);
                    if (code != 0) std.debug.print("actual {s} {s}: {d} ({s}); payload={any}\n", .{ label, field.name, code, observedErrorName(code), value });
                } else diagnoseObservedErrors(label, @field(value, field.name));
            },
            .@"union" => |info| {
                const tag = std.meta.activeTag(value);
                inline for (info.fields) |field| if (std.mem.eql(u8, @tagName(tag), field.name)) diagnoseObservedErrors(label, @field(value, field.name));
            },
            .optional => if (value) |present| diagnoseObservedErrors(label, present),
            .array => for (value) |entry| diagnoseObservedErrors(label, entry),
            else => {},
        }
    }
    fn assembleStamped(self: *Session, value: format.Record, endpoint: ?order.EndpointReceipt) !void {
        if (self.storage.failureValue() != .none) return;
        if (self.operation_bindings) |bindings| {
            if (value == .begin or value == .end) {
                const receipt = endpoint orelse {
                    self.storage.fail(.producer_failure);
                    return error.IncompleteTrace;
                };
                bindings.sink.on_fact(bindings.sink.context, .{ .operation = .{ .receipt = receipt, .value = value } }) catch |err| {
                    self.storage.fail(.producer_failure);
                    return err;
                };
            } else if (endpoint != null) {
                self.storage.fail(.producer_failure);
                return error.IncompleteTrace;
            }
        } else if (endpoint != null) return error.InvalidState;
        try self.assemble(value);
    }
    fn assembleRender(self: *Session, cell: *const RenderCell) !void {
        if (self.storage.failureValue() != .none) return;
        try self.assembleStamped(.{ .begin = .{ .key = cell.key, .args = .{ .render = .{ .frames = cell.frames, .channels = 2 } } } }, cell.begin_endpoint);
        try self.assembleStamped(.{ .end = .{ .key = cell.key, .result = .{ .rendered = .{
            .frame_begin = cell.before_frame,
            .frame_end = cell.after_frame,
            .call_sequence_begin = cell.before_sequence,
            .call_sequence_end = cell.after_sequence,
            .completed = cell.completed,
        } } } }, cell.end_endpoint);
        const pcm = try self.storage.pcm.append(cell.key, cell.frames, 2, cell.samples[0 .. @as(usize, cell.frames) * 2]);
        if (self.operation_bindings) |bindings| {
            const begin_receipt = cell.begin_endpoint orelse return error.IncompleteTrace;
            const end_receipt = cell.end_endpoint orelse return error.IncompleteTrace;
            bindings.sink.on_fact(bindings.sink.context, .{
                .pcm = .{
                    .begin_receipt = begin_receipt,
                    .end_receipt = end_receipt,
                    .value = pcm,
                    // Borrow is synchronous and ends when the callback returns.
                    .samples = cell.samples[0 .. @as(usize, cell.frames) * 2],
                },
            }) catch |err| {
                self.storage.fail(.producer_failure);
                return err;
            };
        }
        try self.assemble(.{ .pcm = pcm });
    }
    /// The sole ring consumer/encoder. Bounded caller-selected work, round-robin
    /// across independent producer lanes; merge order is not causality. A failed
    /// session still drains its finite diagnostic queues for safe cleanup.
    pub fn serviceAssembler(self: *Session, max_records: u32) !usize {
        return self.serviceAssemblerInternal(max_records, false);
    }
    /// Sole-consumer reentry at an offline replay Control checkpoint. Live
    /// capture never permits this, and no Worker/Render caller can consume.
    pub fn serviceReplayAssembler(self: *Session, max_records: u32) !usize {
        if (!self.storage.comparison_only or self.owner.config_v1.kind != .offline) return error.UnsupportedOperation;
        return self.serviceAssemblerInternal(max_records, true);
    }
    const AssemblySelection = struct { lane: u8, control_record: ?Lane(format.Record, control_lane_cells).Stamped = null };
    fn publishedControlEnd(self: *const Session, pending: validation.Validator.PendingControlEnd) bool {
        const lane = &self.storage.control_lane;
        const tail = lane.tail.load(.monotonic);
        const head = lane.head.load(.acquire);
        if (head < tail or head - tail > control_lane_cells) return false;
        // A bounded snapshot of published FIFO cells. The sole consumer has
        // not released these cells; the producer cannot overwrite them here.
        for (0..@as(usize, @intCast(head - tail))) |offset| {
            const record = lane.items[(tail + offset) % control_lane_cells];
            if (record != .end or !std.meta.eql(record.end.key, pending.key)) continue;
            const serial = switch (record.end.result) {
                .ticked => |value| value.frontier_tick_serial,
                .tick_failed => |value| value.frontier_tick_serial,
                else => continue,
            };
            if (serial == pending.tick_serial) return true;
        }
        return false;
    }
    fn nextAssemblySelection(self: *Session, remaining: usize) ?AssemblySelection {
        if (remaining == 0) return null;
        const storage = self.storage;
        if (!storage.control_priority_yield and storage.failureValue() == .none and storage.verified_replay == null) {
            if (storage.validator.pendingControlEnd()) |pending| if (self.publishedControlEnd(pending)) {
                if (storage.control_lane.popStamped()) |record| {
                    storage.control_priority_yield = true;
                    // Lookahead creates no binding and supplies no proof. This
                    // ordinary FIFO pop must pass the unchanged assemble path.
                    return .{ .lane = 0, .control_record = record };
                }
            };
        }
        // One normal attempt follows each priority pop, even across calls.
        // Empty or still-insufficient lanes never wait for their producer.
        storage.control_priority_yield = false;
        const lane = storage.next_lane;
        storage.next_lane = (lane + 1) % 8;
        return .{ .lane = lane };
    }
    fn serviceAssemblerInternal(self: *Session, max_records: u32, replay_checkpoint: bool) !usize {
        try self.requireControl();
        if (self.phase != .active or (self.control_driving and !replay_checkpoint) or max_records == 0 or
            max_records > format.max_producer_events or
            (self.storage.failureValue() == .none and max_records > self.storage.limits.parser_steps)) return error.InvalidArgument;
        var consumed: usize = 0;
        var empty_lanes: u8 = 0;
        while (consumed < max_records and empty_lanes < 8) {
            const selection = self.nextAssemblySelection(max_records - consumed) orelse break;
            const lane = selection.lane;
            self.assembler_lane = lane;
            defer self.assembler_lane = null;
            var found = false;
            if (selection.control_record) |record| {
                found = true;
                try self.assembleStamped(record.value, record.endpoint);
            } else switch (lane) {
                0 => if (self.storage.control_lane.popStamped()) |record| {
                    found = true;
                    try self.assembleStamped(record.value, record.endpoint);
                },
                1 => if (self.storage.worker_lane.popStamped()) |record| {
                    found = true;
                    try self.assembleStamped(record.value, record.endpoint);
                },
                2 => if (self.storage.render_lane.pop()) |cell| {
                    found = true;
                    try self.assembleRender(&cell);
                },
                3 => if (try self.storage.frontier.pop(self.storage.cs.?)) |event| {
                    found = true;
                    try self.assemble(.{ .frontier = event });
                },
                4 => if (try self.storage.acceptance.pop(self.storage.as.?)) |event| {
                    found = true;
                    try self.assemble(.{ .acceptance = event });
                },
                5 => if (!self.storage.readiness_detached) {
                    if (try self.storage.readiness.pop(self.storage.qs.?)) |event| {
                        found = true;
                        try self.assemble(.{ .readiness = event });
                    }
                },
                6 => if (try self.storage.render_bridge.pop(self.storage.rs.?)) |event| {
                    found = true;
                    try self.assemble(.{ .render = event });
                },
                7 => if (self.storage.render_progress_lane.pop()) |fact| {
                    found = true;
                    switch (fact) {
                        .scheduler_progress => |value| try self.assemble(.{ .scheduler_progress = value }),
                        .group_terminal => |value| try self.assemble(.{ .group_terminal = value }),
                        .group_event_queue => |value| try self.assemble(.{ .group_event_queue = value }),
                        .stream_consumed_range => |value| try self.assemble(.{ .stream_consumed_range = value }),
                        .stream_consumed_call_end => |value| try self.assemble(.{ .stream_consumed_call_end = value }),
                    }
                },
                else => unreachable,
            }
            if (found) {
                consumed += 1;
                empty_lanes = 0;
            } else empty_lanes += 1;
        }
        return consumed;
    }
    /// Refusal is a pure lifecycle check: it does not issue stop, collect,
    /// retire sources, join a thread, close evidence or poison healthy capture.
    pub fn trySealQuiescent(self: *Session) Invocation(void) {
        if (self.storage.order_prerequisite_only) return .{ .not_started = error.UnsupportedOperation };
        return self.tryCloseQuiescent();
    }
    /// Cleanup only, after explicit audio stop, genuine drain and both joins.
    /// It never publishes a complete terminal or grants storage-consumer joins.
    pub fn finishOrderPrerequisiteForTest(self: *Session) Invocation(void) {
        if (!@import("builtin").is_test) @compileError("order prerequisite cleanup is test-only");
        if (!self.storage.order_prerequisite_only) return .{ .not_started = error.UnsupportedOperation };
        return self.tryCloseQuiescent();
    }
    fn tryCloseQuiescent(self: *Session) Invocation(void) {
        self.requireControl() catch |err| return .{ .not_started = err };
        if (self.phase != .active or self.control_driving) return .{ .not_started = error.InvalidState };
        if (!self.render_driver.joined or !self.worker_driver.joined or !self.sources_retiring or
            !self.owner.generation.?.retirementAcknowledged()) return .{ .not_started = error.DrainRequired };
        self.owner.requireCausalDrainV1() catch return .{ .not_started = error.DrainRequired };
        const token = self.owner.renderer.acquireDeviceQuiescence() catch return .{ .not_started = error.DrainRequired };
        defer self.owner.renderer.releaseDeviceQuiescence(token) catch self.storage.fail(.invalid_state);
        const result = self.closeJoined(token);
        if (result) |_| {} else |_| self.storage.fail(.invalid_state);
        return .{ .started = .{ .engine_result = result, .recording_failure = self.storage.failureValue() } };
    }
    fn drainFinalQueues(self: *Session) void {
        const maximum = control_lane_cells + worker_lane_cells + render_lane_cells + render_progress_lane_cells +
            cw.slot_capacity + aw.slot_capacity + qw.slot_capacity + rw.slot_capacity;
        var remaining: usize = maximum;
        while (remaining != 0) {
            const budget: u32 = @intCast(if (self.storage.failureValue() == .none)
                @min(remaining, self.storage.limits.parser_steps)
            else
                remaining);
            const count = self.serviceAssembler(budget) catch {
                self.storage.fail(.invalid_state);
                // Charge even a failed pop/parse so a broken bridge can never
                // turn final cleanup into an unbounded retry loop.
                remaining -= 1;
                continue;
            };
            if (count == 0) return;
            remaining -= count;
        }
    }
    fn closeJoined(self: *Session, token: rt.RuntimeRenderer.DeviceQuiescence) !void {
        const storage = self.storage;
        // End the operation interval only after real joins, before terminal
        // cleanup loads outside any active operation. The manual consumer has
        // no asynchronous in-flight request; its queued values remain owned.
        try self.detachOrderPrerequisite();
        // Fixed maximum number of resident queue cells; no producer can refill
        // them after the actual joins. Errors preserve failure and continue the
        // detach path rather than strand a failed recording's engine resources.
        self.drainFinalQueues();
        try self.detachOperationBindings();
        // Both real producers have joined. These terminal loads do not stand
        // in for any active pop/space read and never drain or reset the ring.
        const events = &self.owner.group_events;
        const queue_terminal: @FieldType(format.Record, "group_event_queue_terminal") = .{
            .epoch = events.reset_epoch.load(.acquire),
            .head = events.head.load(.acquire),
            .tail = events.tail.load(.acquire),
        };
        if (!events.enabled.load(.acquire) or events.incomplete.load(.acquire) or events.lost.load(.acquire) != 0) storage.fail(.invalid_state);
        self.assemble(.{ .group_event_queue_terminal = queue_terminal }) catch storage.fail(.invalid_state);
        try self.owner.control.closeReadinessWitness(storage.qs.?, self.owner.renderer, token);
        self.drainFinalQueues();
        const qt = (try storage.readiness.terminal(storage.qs.?)) orelse return error.IncompleteTrace;
        self.assemble(.{ .readiness_terminal = qt }) catch storage.fail(.invalid_state);
        try self.owner.control.detachReadinessWitness(storage.qs.?);
        storage.readiness_detached = true;
        try self.owner.renderer.closeRenderCausalWitness(token, storage.rs.?);
        try self.owner.control.closeControlFrontierWitness(storage.cs.?);
        try self.owner.control.closeStreamAcceptanceWitness(storage.as.?);
        self.drainFinalQueues();
        const ct = (try storage.frontier.terminal(storage.cs.?)) orelse return error.IncompleteTrace;
        const at = (try storage.acceptance.terminal(storage.as.?)) orelse return error.IncompleteTrace;
        var rt_terminal = (try storage.render_bridge.terminal(storage.rs.?)) orelse return error.IncompleteTrace;
        if (@import("builtin").is_test) rt_terminal.final_gate += self.test_render_terminal_gate_delta;
        self.assemble(.{ .frontier_terminal = ct }) catch storage.fail(.invalid_state);
        self.assemble(.{ .acceptance_terminal = at }) catch storage.fail(.invalid_state);
        self.assemble(.{ .render_terminal = rt_terminal }) catch storage.fail(.invalid_state);
        try self.owner.renderer.detachRenderCausalWitness(token, storage.rs.?);
        try self.owner.control.detachControlFrontierWitness(storage.cs.?);
        try self.owner.control.detachStreamAcceptanceWitness(storage.as.?);
        // No producer can call these after join. Keep storage.capture immutable:
        // the actual writer may still publish an asynchronous failure.
        self.owner.causal_sink = null;
        self.owner.group_events.public_causal_sink = null;
        self.owner.generation.?.service.?.public_causal_worker_sink = null;
        self.owner.generation.?.service.?.public_causal_exclusion = null;
        self.owner.generation.?.service.?.detachConsumedObserverQuiescent();
        self.owner.control.scheduled.public_causal_publication_sink = null;
        self.owner.control.scheduled.public_causal_progress_sink = null;
        self.owner.control.public_causal_group_terminal_sink = null;
        self.owner.control.public_causal_group_source_final_sink = null;
        for (&self.owner.control.prepared_groups) |*group| group.terminal.causal_publication_sink = null;
        if (storage.failureValue() == .none) {
            storage.cursor.?.finish() catch storage.fail(.invalid_state);
            if (storage.failureValue() == .none) {
                if (storage.verified_replay) |driver| {
                    driver.finishVerifiedReplay(self) catch {
                        storage.fail(.invalid_state);
                        return self.finishFailed();
                    };
                } else {
                    _ = storage.validator.finish() catch {
                        storage.fail(.invalid_state);
                        return self.finishFailed();
                    };
                }
            }
        }
        if (storage.failureValue() != .none) return self.finishFailed();
        if (storage.comparison_only) {
            self.phase = .sealed;
            return;
        }
        self.flushPage() catch {
            storage.fail(.transport_failure);
            return self.finishFailed();
        };
        const terminal = storage.chain.?.finish(storage.pcm.finish()) catch {
            storage.fail(.byte_budget);
            return self.finishFailed();
        };
        const bytes = format.encodeTerminal(terminal, &storage.record_bytes) catch {
            storage.fail(.transport_failure);
            return self.finishFailed();
        };
        self.publishBytes(bytes) catch {
            storage.fail(.transport_failure);
            return self.finishFailed();
        };
        try storage.pool.seal();
        try storage.pool.publishTerminal(.complete, 0);
        try storage.pool.producerHandoff();
        storage.sealed_terminal = terminal;
        self.phase = .sealed;
        self.summarizeTickErrors();
    }
    fn finishFailed(self: *Session) !void {
        self.summarizeTickErrors();
        if (self.storage.comparison_only) {
            self.phase = .sealed;
            return error.IncompleteTrace;
        }
        // A diagnostic prefix never receives a successful causal terminal.
        self.storage.pool.seal() catch {};
        try self.storage.pool.publishTerminal(.failed, @intFromEnum(self.storage.failureValue()));
        try self.storage.pool.producerHandoff();
        self.phase = .sealed;
        return error.IncompleteTrace;
    }
    /// Storage itself remains pinned for the exporter. This releases only the
    /// engine borrow after witness detach, actual producer joins and writer join.
    pub fn releaseOwner(self: *Session) !void {
        try self.requireControl();
        if (self.phase != .sealed or !self.render_driver.joined or !self.worker_driver.joined or
            (self.storage.export_claimed.load(.acquire) and !self.storage.export_joined.load(.acquire)) or
            !self.orderBindingsClear() or
            self.owner.causal_sink != null or self.owner.group_events.public_causal_sink != null or
            self.owner.generation.?.service.?.public_causal_consumed_sink != null) return error.DrainRequired;
        self.owner.causal_driver_pin = null;
        self.phase = .detached;
    }
    /// Explicit one-shot finalization; this never requests an audio stop. It
    /// refuses before mutation unless actual playback and host receipts drained.
    pub fn retireDrainedSources(self: *Session) Invocation(void) {
        self.requireControl() catch |err| return .{ .not_started = err };
        if (self.sources_retiring) return .{ .not_started = error.InvalidState };
        self.owner.requireCausalSourceRetirementV1() catch return .{ .not_started = error.DrainRequired };
        const key = self.startControl(.{ .retire_sources = {} }) catch |err| return .{ .not_started = err };
        self.sources_retiring = true;
        const result = self.owner.requestCausalSourceRetirementV1();
        self.endControl(key, if (result) |_| .{ .retirement_requested = {} } else |err| .{ .failed = resident.MusicRuntime.causalFailureCodeV1(err) }, orderResultCode(result));
        if (result) |_| {} else |_| self.storage.fail(.producer_failure);
        return .{ .started = .{ .engine_result = result, .recording_failure = self.storage.failureValue() } };
    }
    fn appendControl(self: *Session, value: format.Record) void {
        self.appendControlStamped(value, null);
    }
    fn appendControlStamped(self: *Session, value: format.Record, endpoint: ?order.EndpointReceipt) void {
        if (self.storage.failureValue() != .none) return;
        if (self.control_events >= self.storage.limits.producer_events) {
            self.storage.fail(.event_budget);
            return;
        }
        self.control_events += 1;
        if (!self.storage.control_lane.pushStamped(value, endpoint)) self.storage.fail(.queue_full);
    }
    fn appendWorker(self: *Session, value: format.Record) void {
        self.appendWorkerStamped(value, null);
    }
    fn appendWorkerStamped(self: *Session, value: format.Record, endpoint: ?order.EndpointReceipt) void {
        if (self.storage.failureValue() != .none) return;
        if (self.worker_events >= self.storage.limits.producer_events) {
            self.storage.fail(.event_budget);
            return;
        }
        self.worker_events += 1;
        if (!self.storage.worker_lane.pushStamped(value, endpoint)) self.storage.fail(.queue_full);
    }
    fn nextOperation(self: *Session, role: format.Role, ordinal: *u64) format.OperationKey {
        if (ordinal.* >= self.storage.limits.operations_per_role) {
            self.storage.fail(.event_budget);
        } else ordinal.* += 1;
        return .{ .role = role, .ordinal = ordinal.* };
    }
    fn startControl(self: *Session, args: format.OperationArgs) !format.OperationKey {
        try self.requireControl();
        if (self.phase != .active or self.control_driving or self.owner.control_guard.load(.acquire)) return error.InvalidState;
        const key = self.nextOperation(.control, &self.control_ordinal);
        self.control_driving = true;
        self.control_operation = std.meta.activeTag(args);
        self.control_key = key;
        var endpoint: ?order.EndpointReceipt = null;
        if (self.prerequisite_order) |roles| {
            if (self.operation_bindings != null) {
                endpoint = roles.control.beginReceipt(key.ordinal);
                if (endpoint == null) self.storage.fail(.producer_failure);
            } else roles.control.begin(key.ordinal);
        }
        self.appendControlStamped(.{ .begin = .{ .key = key, .args = args } }, endpoint);
        return key;
    }
    fn endControl(self: *Session, key: format.OperationKey, result: format.OperationResult, order_result: u32) void {
        if (self.operation_bindings != null) {
            const endpoint = self.prerequisite_order.?.control.endReceipt(OperationBinding.stableResultCode(result));
            if (endpoint == null) self.storage.fail(.producer_failure);
            self.appendControlStamped(.{ .end = .{ .key = key, .result = result } }, endpoint);
        } else {
            self.appendControl(.{ .end = .{ .key = key, .result = result } });
            if (self.prerequisite_order) |roles| roles.control.end(order_result);
        }
        self.control_driving = false;
        self.control_operation = null;
        self.control_key = null;
    }
    fn orderResultCode(result: anytype) u32 {
        // In-memory only: preserve the actual build-local engine error identity.
        // This is not a stable persisted error codec or a recording failure.
        return if (result) |_| 0 else |err| @intFromError(err);
    }
    fn allowed(raw: *anyopaque, role: resident.CausalRoleV1) bool {
        const self: *Session = @ptrCast(@alignCast(raw));
        return switch (role) {
            .control => std.Thread.getCurrentId() == self.control_thread and self.control_driving,
            .worker => std.Thread.getCurrentId() == self.worker_driver.identity.load(.acquire) and self.worker_driver.driving,
        };
    }
    fn inputFact(raw: *anyopaque, value: trace.Input) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (!allowed(raw, .control) or self.control_key == null) {
            self.storage.fail(.invalid_state);
            return;
        }
        self.appendControl(.{ .input = .{ .key = self.control_key.?, .value = value } });
    }
    fn scheduleFact(raw: *anyopaque, value: trace.ScheduleEntry) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (!allowed(raw, .control) or self.control_key == null) {
            self.storage.fail(.invalid_state);
            return;
        }
        self.appendControl(.{ .schedule = .{ .key = self.control_key.?, .value = value } });
    }
    fn invalidate(raw: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.storage.fail(.invalid_state);
    }
    fn schedulerProgress(raw: *anyopaque, value: rt.scheduler.CausalProgress) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (!self.admitRenderFact()) return;
        if (!self.storage.render_progress_lane.push(.{ .scheduler_progress = .{ .key = self.render_key.?, .value = value } })) self.storage.fail(.queue_full);
    }
    fn consumedPublication(raw: *anyopaque, value: rt.streaming.stream.Consumed) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (self.storage.failureValue() != .none) return;
        if (std.Thread.getCurrentId() != self.render_driver.identity.load(.acquire) or !self.render_driver.driving or self.render_key == null or value.index >= format.consumed_slots) {
            self.storage.fail(.invalid_state);
            return;
        }
        // This credit is already spent when call-end flush emits the range.
        if (self.consumed_ranges.entries[value.index] == null and !self.admitRenderFact()) return;
        self.consumed_ranges.append(value) catch self.storage.fail(.invalid_state);
    }
    fn flushConsumedRanges(self: *Session, key: format.OperationKey) void {
        if (self.storage.failureValue() != .none) return;
        // Fixed slot enumeration is serialization only, never cross-ring time.
        for (self.consumed_ranges.entries) |entry| if (entry) |range| {
            if (!self.storage.render_progress_lane.push(.{ .stream_consumed_range = .{ .key = key, .index = range.index, .generation = range.generation, .first = range.first, .last = range.last, .count = range.count } })) {
                self.storage.fail(.queue_full);
                return;
            }
        };
        if (!self.storage.render_progress_lane.push(.{ .stream_consumed_call_end = .{ .key = key, .ranges = self.consumed_ranges.ranges, .publications = self.consumed_ranges.publications } })) self.storage.fail(.queue_full);
    }
    fn groupEventQueue(raw: *anyopaque, epoch: u64, observation: trace.QueueObservation) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (epoch != format.group_event_epoch) {
            self.storage.fail(.invalid_state);
            return;
        }
        switch (observation) {
            .push => |value| {
                if (!value.enabled or !value.accepted or value.head_before == std.math.maxInt(u64) or value.head_after == null) {
                    self.storage.fail(.invalid_state);
                    return;
                }
                if (!self.admitRenderFact()) return;
                if (!self.storage.render_progress_lane.push(.{ .group_event_queue = .{ .key = self.render_key.?, .epoch = epoch, .observation = observation } })) self.storage.fail(.queue_full);
            },
            .pop => |value| {
                if (!allowed(raw, .control) or self.control_key == null or (value.present and value.tail_before == std.math.maxInt(u64))) {
                    self.storage.fail(.invalid_state);
                    return;
                }
                self.appendControl(.{ .group_event_queue = .{ .key = self.control_key.?, .epoch = epoch, .observation = observation } });
            },
        }
    }
    fn groupSourceFinal(raw: *anyopaque, value: rt.GroupSourceFinal) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (!allowed(raw, .control) or self.control_key == null) {
            self.storage.fail(.invalid_state);
            return;
        }
        self.appendControl(.{ .group_source_final = .{ .key = self.control_key.?, .value = value } });
    }
    fn groupTerminal(raw: *anyopaque, value: rt.music_group.Terminal) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (!self.admitRenderFact()) return;
        if (!self.storage.render_progress_lane.push(.{ .group_terminal = .{ .key = self.render_key.?, .value = value } })) self.storage.fail(.queue_full);
    }
    // One Render producer, one assembler consumer, and one shared hard budget
    // for scheduler progress and the actual mixer terminal publication.
    fn admitRenderFact(self: *Session) bool {
        if (std.Thread.getCurrentId() != self.render_driver.identity.load(.acquire) or !self.render_driver.driving or self.render_key == null) {
            self.storage.fail(.invalid_state);
            return false;
        }
        if (self.storage.failureValue() != .none) return false;
        if (self.render_progress_count >= render_progress_per_call or self.render_progress_total >= self.storage.limits.producer_events) {
            self.storage.fail(.event_budget);
            return false;
        }
        self.render_progress_count += 1;
        self.render_progress_total += 1;
        return true;
    }
    fn schedulerPublication(raw: *anyopaque, value: rt.scheduler.CausalPublication) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (!allowed(raw, .control) or self.control_key == null) {
            self.storage.fail(.invalid_state);
            return;
        }
        self.appendControl(.{ .scheduler_publication = .{ .key = self.control_key.?, .value = value } });
    }
    const max_claim_ordinal: u64 = std.math.maxInt(u64) >> 2;
    const ClaimRole = enum(u2) { control = 1, worker = 2 };
    fn claimRole(self: *Session, kind: stream.ServiceClaimKind) ?ClaimRole {
        const thread = std.Thread.getCurrentId();
        // Check identity before reading any role-private key, operation,
        // driving flag or counter. A foreign caller only touches atomics.
        switch (kind) {
            .stream_close => {
                if (thread != self.control_thread) {
                    self.storage.fail(.invalid_state);
                    return null;
                }
                if (!self.control_driving or self.control_operation != .tick or self.control_key == null or
                    self.control_key.?.role != .control or self.control_key.?.ordinal == 0)
                {
                    self.storage.fail(.invalid_state);
                    return null;
                }
                return .control;
            },
            .worker => {
                if (thread != self.worker_driver.identity.load(.acquire)) {
                    self.storage.fail(.invalid_state);
                    return null;
                }
                if (!self.worker_driver.driving or self.worker_key == null or
                    self.worker_key.?.role != .worker or self.worker_key.?.ordinal == 0)
                {
                    self.storage.fail(.invalid_state);
                    return null;
                }
                return .worker;
            },
            // Initial asset preparation occurs before attachment. The public
            // active-capture contract has no prepareAsset operation.
            .prepare_asset => {
                self.storage.fail(.invalid_state);
                return null;
            },
        }
    }
    fn claimToken(raw: *anyopaque, kind: stream.ServiceClaimKind) u64 {
        const self: *Session = @ptrCast(@alignCast(raw));
        const role = self.claimRole(kind) orelse return 1;
        const ordinal = switch (role) {
            .control => &self.control_claim_ordinal,
            .worker => &self.worker_claim_ordinal,
        };
        if (ordinal.* >= max_claim_ordinal) {
            ordinal.* = max_claim_ordinal;
            self.storage.fail(.event_budget);
            return 1;
        }
        // Every actual CAS consumes an ordinal, including a failed CAS.
        // Only this role writes its counter; tokens do not order acquisitions.
        ordinal.* += 1;
        return (ordinal.* << 2) | @intFromEnum(role);
    }
    fn claimAttempt(raw: *anyopaque, value: stream.ServiceClaimAttempt) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        const role = self.claimRole(value.kind) orelse return;
        const ordinal = switch (role) {
            .control => self.control_claim_ordinal,
            .worker => self.worker_claim_ordinal,
        };
        if (ordinal == 0 or ordinal > max_claim_ordinal or value.token != ((ordinal << 2) | @intFromEnum(role))) {
            self.storage.fail(.invalid_state);
            return;
        }
        // Preserve the actual observed holder, including a foreign/invalid
        // token: normalizing it would erase the evidence the Validator needs.
        switch (role) {
            .control => self.appendControl(.{ .service_claim = .{ .key = self.control_key.?, .value = value } }),
            .worker => self.appendWorker(.{ .service_claim = .{ .key = self.worker_key.?, .value = value } }),
        }
    }
    fn workerRelease(raw: *anyopaque, value: stream.ServiceWorkerRelease) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        // The core has already unlocked and published the actual release.
        // Validate the real Worker before any role-private key or counter read.
        if (self.claimRole(.worker) == null) return;
        const ordinal = self.worker_claim_ordinal;
        if (ordinal == 0 or ordinal > max_claim_ordinal or
            value.token != ((ordinal << 2) | @intFromEnum(ClaimRole.worker)) or value.ticket == 0)
        {
            self.storage.fail(.invalid_state);
            return;
        }
        self.appendWorker(.{ .service_worker_release = .{ .key = self.worker_key.?, .value = value } });
    }
    fn exclusionOverflow(raw: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.storage.fail(.event_budget);
    }
    fn exclusionFact(raw: *anyopaque, value: format.ServiceExclusion) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        switch (value.owner) {
            .stream_close => {
                if (!allowed(raw, .control) or self.control_key == null) {
                    self.storage.fail(.invalid_state);
                    return;
                }
                self.appendControl(.{ .service_exclusion = .{ .key = self.control_key.?, .value = value } });
            },
            .worker => {
                if (!allowed(raw, .worker) or self.worker_key == null) {
                    self.storage.fail(.invalid_state);
                    return;
                }
                self.appendWorker(.{ .service_exclusion = .{ .key = self.worker_key.?, .value = value } });
            },
            .prepare_asset => self.storage.fail(.invalid_state),
        }
    }
    fn workerFact(raw: *anyopaque, value: format.WorkerFact) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (!allowed(raw, .worker) or self.worker_key == null) {
            self.storage.fail(.invalid_state);
            return;
        }
        switch (value) {
            .clock => |fact| if (fact.error_code != 0) self.storage.fail(.producer_failure),
            .source_read => |fact| if (fact.error_code != 0) self.storage.fail(.producer_failure),
            else => {},
        }
        self.appendWorker(.{ .worker = .{ .key = self.worker_key.?, .value = value } });
    }
    pub fn submit(self: *Session, reference: v1.BankRefV1, payload: contract.MusicRequestPayload) Invocation(v1.RequestTicketV1) {
        self.requireControl() catch |err| return .{ .not_started = err };
        if (self.sources_retiring) return .{ .not_started = error.InvalidState };
        self.owner.requireCausalRequestV1(reference, payload) catch |err| return .{ .not_started = err };
        const request: trace.schema.RequestPayload = switch (payload) {
            .set_state => |value| .{ .set_state = .{ .state = value.state.value(), .priority = value.priority } },
            .stop => .stop_emergency,
            else => return .{ .not_started = error.UnsupportedOperation },
        };
        const key = self.startControl(.{ .submit = .{ .bank = reference, .request = request } }) catch |err| return .{ .not_started = err };
        const result = self.owner.submitV1(reference, payload);
        self.endControl(key, if (result) |ticket| .{ .submitted = ticket } else |err| .{ .failed = resident.MusicRuntime.causalFailureCodeV1(err) }, orderResultCode(result));
        return .{ .started = .{ .engine_result = result, .recording_failure = self.storage.failureValue() } };
    }
    pub fn controlTick(self: *Session, limit: u32) Invocation(usize) {
        if (limit > rt.max_control_drain) return .{ .not_started = error.UnsupportedCapacity };
        const key = self.startControl(.{ .tick = limit }) catch |err| return .{ .not_started = err };
        if (self.storage.header.?.identity.rules_version == 2) {
            // One genuine acquire before this tick can attempt any close.
            // The prefix ordinal prevents an earlier, late-arriving busy read
            // from being retired merely because this acquire saw progress.
            const token = self.owner.generation.?.service.?.readWorkerReleaseProgress(0);
            self.appendControl(.{ .service_release_observation = .{
                .key = key,
                .token = token,
                .after_claims = self.control_claim_ordinal,
            } });
        }
        const result: anyerror!usize = self.owner.controlTickV1(limit) catch |err| diagnosed: {
            if (@import("builtin").is_test) {
                self.test_diagnostics.tick_errors +|= 1;
                self.test_diagnostics.last_tick_error = err;
                if (self.test_diagnostics.tick_errors == 1) {
                    std.debug.print("first actual public causal Control tick failed: {s}\n", .{@errorName(err)});
                    if (@errorReturnTrace()) |error_trace| std.debug.dumpErrorReturnTrace(error_trace);
                }
            }
            break :diagnosed err;
        };
        self.endControl(key, if (result) |count| .{ .ticked = .{ .processed = @intCast(count), .control_tick = self.owner.tick, .frontier_tick_serial = self.storage.frontier.tick_serial } } else |err| if (err == error.InvalidState) .{ .tick_failed = .{
            .failure = resident.MusicRuntime.causalFailureCodeV1(err),
            .control_tick = self.owner.tick,
            .frontier_tick_serial = self.storage.frontier.tick_serial,
        } } else .{ .failed = resident.MusicRuntime.causalFailureCodeV1(err) }, orderResultCode(result));
        // This is an unverified candidate, never a declaration of recovery.
        // The assembler must prove its exact same-tick observation cause and
        // partial effects before the session can finish complete. The caller
        // receives this original error; any later tick is a new operation.
        if (result) |_| {} else |err| if (err != error.InvalidState) self.storage.fail(.producer_failure);
        return .{ .started = .{ .engine_result = result, .recording_failure = self.storage.failureValue() } };
    }
    fn summarizeTickErrors(self: *Session) void {
        if (@import("builtin").is_test) {
            if (self.test_diagnostics.summary_reported or self.test_diagnostics.tick_errors == 0) return;
            self.test_diagnostics.summary_reported = true;
            std.debug.print("public causal executed Control tick failures: count={d} last={s}\n", .{ self.test_diagnostics.tick_errors, @errorName(self.test_diagnostics.last_tick_error.?) });
        }
    }
    pub fn pollReceipt(self: *Session) Invocation(?v1.ReceiptV1) {
        const key = self.startControl(.{ .poll_receipt = {} }) catch |err| return .{ .not_started = err };
        const result = self.owner.pollReceiptV1();
        self.endControl(key, if (result) |receipt| .{ .receipt = receipt } else |err| .{ .failed = resident.MusicRuntime.causalFailureCodeV1(err) }, orderResultCode(result));
        return .{ .started = .{ .engine_result = result, .recording_failure = self.storage.failureValue() } };
    }
    pub fn pollPhaseReceipt(self: *Session) Invocation(?contract.PhaseReceipt) {
        const key = self.startControl(.{ .poll_phase_receipt = {} }) catch |err| return .{ .not_started = err };
        const result = self.owner.pollPhaseReceiptV1();
        self.endControl(key, if (result) |receipt| .{ .phase_receipt = receipt } else |err| .{ .failed = resident.MusicRuntime.causalFailureCodeV1(err) }, orderResultCode(result));
        return .{ .started = .{ .engine_result = result, .recording_failure = self.storage.failureValue() } };
    }
    fn workerOwned(self: *Session) Invocation(bool) {
        const driver = &self.worker_driver;
        if (driver.identity.load(.acquire) != std.Thread.getCurrentId() or driver.driving) return .{ .not_started = error.WrongThread };
        if (!driver.safePoint()) return .{ .not_started = error.DriverStopped };
        if (self.phase != .initialized and self.phase != .active) return .{ .not_started = error.InvalidState };
        driver.driving = true;
        defer driver.driving = false;
        if (self.phase == .initialized) {
            const result = self.owner.workerOneV1();
            return .{ .started = .{ .engine_result = result, .recording_failure = .none } };
        }
        const key = self.nextOperation(.worker, &driver.ordinal);
        self.worker_key = key;
        defer self.worker_key = null;
        var begin_endpoint: ?order.EndpointReceipt = null;
        if (self.prerequisite_order) |roles| {
            if (self.operation_bindings != null) {
                begin_endpoint = roles.worker.beginReceipt(key.ordinal);
                if (begin_endpoint == null) self.storage.fail(.producer_failure);
            } else roles.worker.begin(key.ordinal);
        }
        self.appendWorkerStamped(.{ .begin = .{ .key = key, .args = .{ .worker_one = {} } } }, begin_endpoint);
        const generation = self.owner.generation.?;
        const close_before = generation.close_cursor;
        const binding_before = generation.source_binding != null;
        const result = self.owner.workerOneV1();
        const close_after = generation.close_cursor;
        const closed_source: ?u64 = if (close_after > close_before and close_before < generation.sources.len)
            generation.loaded.tables.sounds[generation.sources[close_before].sound_index].key.id
        else
            null;
        const semantic_result: format.OperationResult = if (result) |worked| .{ .worked = .{
            .worked = worked,
            .closed_source = closed_source,
            .unbound = binding_before and generation.source_binding == null,
            .retirement_acknowledged = generation.retirementAcknowledged(),
        } } else |err| .{ .failed = resident.MusicRuntime.causalFailureCodeV1(err) };
        if (self.operation_bindings != null) {
            const endpoint = self.prerequisite_order.?.worker.endReceipt(OperationBinding.stableResultCode(semantic_result));
            if (endpoint == null) self.storage.fail(.producer_failure);
            self.appendWorkerStamped(.{ .end = .{ .key = key, .result = semantic_result } }, endpoint);
        } else {
            self.appendWorker(.{ .end = .{ .key = key, .result = semantic_result } });
            if (self.prerequisite_order) |roles| roles.worker.end(orderResultCode(result));
        }
        if (result) |_| {} else |_| self.storage.fail(.producer_failure);
        return .{ .started = .{ .engine_result = result, .recording_failure = self.storage.failureValue() } };
    }
    fn renderOwned(self: *Session, output: []f32, frames: u32) Invocation(void) {
        const driver = &self.render_driver;
        if (driver.identity.load(.acquire) != std.Thread.getCurrentId() or driver.driving) return .{ .not_started = error.WrongThread };
        if (driver.stop.load(.acquire)) return .{ .not_started = error.DriverStopped };
        if (self.phase != .active) return .{ .not_started = error.InvalidState };
        if (frames == 0 or frames > self.owner.config.quantum_frames or frames > self.storage.limits.max_pcm_frames or
            output.len != @as(usize, frames) * 2) return .{ .not_started = error.InvalidArgument };
        driver.driving = true;
        defer driver.driving = false;
        const key = self.nextOperation(.render, &driver.ordinal);
        self.render_key = key;
        var begin_endpoint: ?order.EndpointReceipt = null;
        if (self.prerequisite_order) |roles| {
            if (self.operation_bindings != null) {
                begin_endpoint = roles.render.beginReceipt(key.ordinal);
                if (begin_endpoint == null) self.storage.fail(.producer_failure);
            } else roles.render.begin(key.ordinal);
        }
        self.render_progress_count = 0;
        self.consumed_ranges.begin(frames);
        defer self.render_key = null;
        if (driver.ordinal > self.storage.limits.producer_events) self.storage.fail(.event_budget);
        if (frames > max_recordable_render_frames) self.storage.fail(.producer_failure);
        // Mandatory even for zero-touch calls, reserved from the same budget.
        _ = self.admitRenderFact();
        const before_frame = self.owner.renderer.renderFrame();
        const before = self.owner.renderer.callObservation();
        // From this point onward recording failure cannot suppress real audio.
        self.owner.renderer.render(output, frames, 2);
        const after_frame = self.owner.renderer.renderFrame();
        const after = self.owner.renderer.callObservation();
        const completed = !before.exhausted and !after.exhausted and before.sequence & 1 == 0 and
            after.sequence > before.sequence and after.sequence - before.sequence == 2 and
            after_frame >= before_frame and after_frame - before_frame == frames;
        if (!completed) self.storage.fail(.producer_failure);
        self.flushConsumedRanges(key);
        var cell: RenderCell = .{ .key = key, .frames = frames, .before_frame = before_frame, .after_frame = after_frame, .before_sequence = before.sequence, .after_sequence = after.sequence, .completed = completed, .begin_endpoint = begin_endpoint };
        if (self.storage.failureValue() == .none) {
            @memcpy(cell.samples[0..output.len], output);
        }
        if (self.operation_bindings != null) {
            // Obtain the actual endpoint before publishing the owned cell. A
            // later consumer may not reconstruct it or mutate the published cell.
            cell.end_endpoint = self.prerequisite_order.?.render.endReceipt(0);
            if (cell.end_endpoint == null) self.storage.fail(.producer_failure);
        }
        if (self.storage.failureValue() == .none) {
            if (!self.storage.render_lane.push(cell)) self.storage.fail(.queue_full);
        }
        // render() returns void; completion diagnostics remain a separate fact.
        if (self.operation_bindings == null) if (self.prerequisite_order) |roles| roles.render.end(0);
        return .{ .started = .{ .engine_result = {}, .recording_failure = self.storage.failureValue() } };
    }
    pub fn drainStatus(self: *Session) !DrainStatus {
        try self.requireControl();
        const drained = if (self.owner.requireCausalDrainV1()) |_| true else |_| false;
        return .{ .engine_drained = drained, .sources_retired = self.owner.generation != null and self.owner.generation.?.retirementAcknowledged(), .receipts_drained = self.owner.ingress.receipt_head.load(.acquire) == self.owner.ingress.receipt_tail.load(.acquire), .render_joined = self.render_driver.joined, .worker_joined = self.worker_driver.joined };
    }
    /// Cancel evidence only. Audio and genuine stop/drain cleanup remain live.
    /// Complete the same retire/join/seal path to release every actual borrower.
    pub fn cancel(self: *Session) !void {
        try self.requireControl();
        if (self.phase != .active) return error.InvalidState;
        self.storage.fail(.cancelled);
    }
    pub fn status(self: *const Session) !Status {
        try self.requireControl();
        return .{ .phase = self.phase, .engine = try self.owner.snapshotV1(), .recording_failure = self.storage.failureValue(), .render_joined = self.render_driver.joined, .worker_joined = self.worker_driver.joined, .complete = !self.storage.comparison_only and self.phase == .sealed and self.storage.failureValue() == .none };
    }
};

pub fn testClaimRoleOrdinalsAndHolders() !void {
    if (!@import("builtin").is_test) @compileError("test-only claim qualification");
    const t = std.testing;
    const storage = try t.allocator.create(Storage);
    defer t.allocator.destroy(storage);
    storage.* = .{};
    // Pure producer callback qualification: no owner or engine claim is
    // manufactured, and these records are not offered as a complete capture.
    var session: Session = .{ .owner = undefined, .storage = storage, .control_thread = std.Thread.getCurrentId() };
    session.control_driving = true;
    session.control_operation = .tick;
    session.control_key = .{ .role = .control, .ordinal = 1 };
    const close: stream.ServiceClaimKind = .{ .stream_close = .{ .handle = .{ .index = 0, .generation = 1 }, .parent_attempt = 1 } };
    const first = Session.claimToken(&session, close);
    Session.claimAttempt(&session, .{ .kind = close, .token = first, .observed = 0 });
    const second = Session.claimToken(&session, close);
    Session.claimAttempt(&session, .{ .kind = close, .token = second, .observed = 6 });
    try t.expectEqual(@as(u64, 5), first);
    try t.expectEqual(@as(u64, 9), second);
    try t.expectEqual(@as(u64, 2), session.control_claim_ordinal);
    try t.expectEqual(@as(u64, 0), storage.control_lane.pop().?.service_claim.value.observed);
    const busy_close = storage.control_lane.pop().?.service_claim;
    try t.expectEqual(session.control_key.?, busy_close.key);
    try t.expectEqual(@as(u64, 6), busy_close.value.observed);
    const Worker = struct {
        fn run(value: *Session) void {
            value.worker_driver.identity.store(std.Thread.getCurrentId(), .release);
            value.worker_driver.driving = true;
            value.worker_key = .{ .role = .worker, .ordinal = 1 };
            const a = Session.claimToken(value, .worker);
            Session.claimAttempt(value, .{ .kind = .worker, .token = a, .observed = 5 });
            const b = Session.claimToken(value, .worker);
            Session.claimAttempt(value, .{ .kind = .worker, .token = b, .observed = 0 });
            Session.workerRelease(value, .{ .token = b, .ticket = 1 });
            value.worker_key = null;
            value.worker_driver.driving = false;
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&session});
    worker.join();
    const busy_worker = storage.worker_lane.pop().?.service_claim;
    const idle_worker = storage.worker_lane.pop().?.service_claim;
    try t.expectEqual(@as(u64, 6), busy_worker.value.token);
    try t.expectEqual(@as(u64, 5), busy_worker.value.observed);
    try t.expectEqual(@as(u64, 10), idle_worker.value.token);
    try t.expectEqual(@as(u64, 0), idle_worker.value.observed);
    const release = storage.worker_lane.pop().?.service_worker_release;
    try t.expectEqual(format.OperationKey{ .role = .worker, .ordinal = 1 }, release.key);
    try t.expectEqual(@as(u64, 10), release.value.token);
    try t.expectEqual(@as(u64, 1), release.value.ticket);
    try t.expectEqual(@as(u64, 2), session.worker_claim_ordinal);
    try t.expectEqual(@as(u64, 2), session.control_claim_ordinal);
    try t.expectEqual(Failure.none, storage.failureValue());
}

pub fn testClaimForeignThread() !void {
    if (!@import("builtin").is_test) @compileError("test-only claim qualification");
    const t = std.testing;
    const storage = try t.allocator.create(Storage);
    defer t.allocator.destroy(storage);
    storage.* = .{};
    var session: Session = .{ .owner = undefined, .storage = storage, .control_thread = std.Thread.getCurrentId() };
    session.control_driving = true;
    session.control_operation = .tick;
    session.control_key = .{ .role = .control, .ordinal = 1 };
    session.control_claim_ordinal = 7;
    var returned_token: u64 = 0;
    const Foreign = struct {
        fn run(value: *Session, result: *u64) void {
            const close: stream.ServiceClaimKind = .{ .stream_close = .{ .handle = .{ .index = 0, .generation = 1 }, .parent_attempt = 1 } };
            result.* = Session.claimToken(value, close);
            Session.claimAttempt(value, .{ .kind = close, .token = 29, .observed = 0 });
            _ = Session.claimToken(value, .worker);
            Session.claimAttempt(value, .{ .kind = .worker, .token = 6, .observed = 0 });
            Session.workerRelease(value, .{ .token = 6, .ticket = 1 });
        }
    };
    const foreign = try std.Thread.spawn(.{}, Foreign.run, .{ &session, &returned_token });
    foreign.join();
    try t.expectEqual(@as(u64, 1), returned_token);
    try t.expectEqual(Failure.invalid_state, storage.failureValue());
    try t.expectEqual(@as(u64, 7), session.control_claim_ordinal);
    try t.expectEqual(@as(u64, 0), session.worker_claim_ordinal);
    try t.expect(storage.control_lane.empty() and storage.worker_lane.empty());
}

pub fn testClaimUnsupportedAndSaturated() !void {
    if (!@import("builtin").is_test) @compileError("test-only claim qualification");
    const t = std.testing;
    const storage = try t.allocator.create(Storage);
    defer t.allocator.destroy(storage);
    // Each case is an independent, unattached fixture with no running producer.
    for (0..3) |case| {
        storage.* = .{};
        var session: Session = .{ .owner = undefined, .storage = storage, .control_thread = std.Thread.getCurrentId() };
        session.control_driving = true;
        session.control_operation = if (case == 0) .poll_receipt else .tick;
        session.control_key = .{ .role = .control, .ordinal = 1 };
        const kind: stream.ServiceClaimKind = if (case == 1)
            .{ .prepare_asset = .{ .sound_index = 0, .asset = 1, .encoded_hash = @splat(1) } }
        else
            .{ .stream_close = .{ .handle = .{ .index = 0, .generation = 1 }, .parent_attempt = 1 } };
        if (case == 2) {
            session.control_claim_ordinal = Session.max_claim_ordinal - 1;
            try t.expectEqual((Session.max_claim_ordinal << 2) | 1, Session.claimToken(&session, kind));
            try t.expectEqual(Failure.none, storage.failureValue());
        }
        try t.expectEqual(@as(u64, 1), Session.claimToken(&session, kind));
        try t.expectEqual(if (case == 2) Failure.event_budget else Failure.invalid_state, storage.failureValue());
        try t.expectEqual(@as(u64, 1), Session.claimToken(&session, kind));
        try t.expectEqual(if (case == 2) Session.max_claim_ordinal else @as(u64, 0), session.control_claim_ordinal);
        try t.expect(storage.control_lane.empty() and storage.worker_lane.empty());
    }
}

pub fn testControlEndPreference(header_in: format.Header, scenario: enum { predicate, no_data, fairness_budget, ring_wrap, sustained_fairness, invalid_end, capacity }) !void {
    if (!@import("builtin").is_test) @compileError("test-only assembler selection qualification");
    const t = std.testing;
    const storage = try t.allocator.create(Storage);
    defer t.allocator.destroy(storage);
    storage.* = .{};
    var header = header_in;
    header.identity.rules_version = 2;
    header.bindings.readiness_manifest.capture_acquisitions = true;
    header.bindings.readiness_manifest.capture_reconciliation = true;
    header.bindings.render_manifest.capture_reconciliation = true;
    try storage.validator.initInto(header, header.limits);
    storage.header = header;
    storage.limits = header.limits;
    storage.address = storage;
    // No engine is constructed or executed. requireControl only needs this
    // pinned owner field; all operations below exercise consumer/validator code.
    const owner = try t.allocator.create(resident.MusicRuntime);
    defer t.allocator.destroy(owner);
    owner.causal_driver_pin = storage;
    var session: Session = .{ .owner = owner, .storage = storage, .control_thread = std.Thread.getCurrentId(), .phase = .active };
    var compared: usize = 0;
    const Compare = struct {
        fn record(raw: *anyopaque, _: format.Record) anyerror!void {
            const count: *usize = @ptrCast(@alignCast(raw));
            count.* += 1;
        }
    };
    storage.comparison_only = true;
    storage.comparator = .{ .context = &compared, .record = Compare.record };
    const key: format.OperationKey = .{ .role = .control, .ordinal = 1 };
    const begin: format.OperationBegin = .{ .key = key, .args = .{ .tick = 1 } };
    try storage.validator.feed(.{ .begin = begin });
    try storage.validator.feed(.{ .service_release_observation = .{ .key = key, .token = 0, .after_claims = 0 } });
    var frontier = std.mem.zeroes(format.frontier.Event);
    frontier.incarnation = header.bindings.frontier.incarnation;
    frontier.generation = header.bindings.frontier.generation;
    frontier.owner_identity = header.bindings.frontier.owner_identity;
    frontier.interval_id = header.bindings.frontier.interval_id;
    frontier.sequence = 1;
    frontier.kind = .tick_open;
    frontier.tick_serial = 87;
    frontier.control_tick = 87;
    try storage.validator.feed(.{ .frontier = frontier });
    storage.cursor = storage.validator.cursor;
    const ended: format.Record = .{ .end = .{ .key = key, .result = .{ .ticked = .{ .processed = 0, .control_tick = 87, .frontier_tick_serial = 87 } } } };
    const first: format.Record = .{ .service_claim = .{ .key = key, .value = .{
        .kind = .{ .stream_close = .{ .handle = .{ .index = 0, .generation = 1 }, .parent_attempt = 1 } },
        .token = 5,
        .observed = 6,
    } } };
    var second = first;
    second.service_claim.value.token = 9;
    second.service_claim.value.kind.stream_close.parent_attempt = 2;
    switch (scenario) {
        .predicate => {
            const validator = &storage.validator;
            const wanted = validator.pendingControlEnd().?;
            try t.expectEqual(key, wanted.key);
            try t.expectEqual(@as(u64, 87), wanted.tick_serial);
            validator.cursor.active[0] = null;
            try t.expect(validator.pendingControlEnd() == null);
            validator.cursor.active[0] = .{ .key = key, .args = .poll_receipt };
            try t.expect(validator.pendingControlEnd() == null);
            validator.cursor.active[0] = begin;
            validator.bindings[0] = .{ .key = key, .serial = 86, .args = begin.args, .result = ended.end.result };
            try t.expect(validator.pendingControlEnd() != null);
            validator.bindings[0].?.serial = 87;
            try t.expect(validator.pendingControlEnd() == null);
            validator.bindings[0] = null;
            validator.pending[0] = .{ .render = std.mem.zeroInit(format.render.Event, .{ .payload = @as(format.render.Payload, .{ .gate_end = 0 }) }) };
            try t.expect(validator.pendingControlEnd() == null);
            validator.pending[0] = .{ .acceptance = std.mem.zeroes(format.acceptance.Event) };
            validator.pending[0].acceptance.tick_serial = 88;
            try t.expectEqual(@as(u64, 88), validator.pendingControlEnd().?.tick_serial);
            validator.pending[0] = .{ .readiness = std.mem.zeroInit(format.readiness.Event, .{ .payload = @as(format.readiness.Payload, .tick_open) }) };
            validator.pending[0].readiness.key.tick_serial = 89;
            try t.expectEqual(@as(u64, 89), validator.pendingControlEnd().?.tick_serial);
            validator.pending_count = 0;
            try t.expect(validator.pendingControlEnd() == null);
        },
        .no_data => {
            storage.next_lane = 3;
            try t.expectEqual(@as(u8, 3), session.nextAssemblySelection(1).?.lane);
            try t.expect(storage.control_lane.push(first));
            // A prefix without its published exact end is insufficient.
            try t.expectEqual(@as(u8, 4), session.nextAssemblySelection(1).?.lane);
            var wrong = ended;
            wrong.end.key.ordinal += 1;
            try t.expect(storage.control_lane.push(wrong));
            wrong = ended;
            wrong.end.result.ticked.frontier_tick_serial += 1;
            try t.expect(storage.control_lane.push(wrong));
            wrong.end.result = .{ .receipt = null };
            try t.expect(storage.control_lane.push(wrong));
            try t.expectEqual(@as(u8, 5), session.nextAssemblySelection(1).?.lane);
            try t.expectEqual(@as(u64, 0), storage.control_lane.tail.load(.acquire));
            try t.expect(storage.control_lane.push(ended));
            const selected = session.nextAssemblySelection(1).?;
            try t.expectEqualDeep(first, selected.control_record.?);
            try t.expectEqual(@as(u8, 6), storage.next_lane);
            try t.expect(storage.validator.bindings[0] == null);
            try t.expectEqual(@as(u64, 0), storage.validator.semantic_sequences[0]);
            // Verified replay must not inspect the bypassed Validator at all.
            const replay_driver = try t.allocator.create(replay.Session);
            defer t.allocator.destroy(replay_driver);
            storage.verified_replay = replay_driver;
            storage.control_priority_yield = false;
            storage.validator = undefined;
            try t.expectEqual(@as(u8, 6), session.nextAssemblySelection(1).?.lane);
            try t.expectEqual(@as(u64, 1), storage.control_lane.tail.load(.acquire));
        },
        .fairness_budget => {
            storage.next_lane = 1;
            try t.expect(storage.control_lane.push(first));
            try t.expect(storage.control_lane.push(second));
            try t.expect(storage.control_lane.push(ended));
            try t.expect(session.nextAssemblySelection(0) == null);
            try t.expectEqual(@as(u64, 0), storage.control_lane.tail.load(.acquire));
            try t.expectEqual(@as(usize, 1), try session.serviceAssembler(1));
            try t.expectEqual(@as(u64, 1), storage.control_lane.tail.load(.acquire));
            try t.expectEqual(@as(u8, 1), storage.next_lane);
            try t.expect(storage.control_priority_yield);
            // A published Worker record wins the next normal turn even though
            // another preferred Control record is immediately available.
            try t.expect(storage.worker_lane.push(.{ .begin = .{ .key = .{ .role = .worker, .ordinal = 1 }, .args = .worker_one } }));
            try t.expectEqual(@as(usize, 1), try session.serviceAssembler(1));
            try t.expectEqual(@as(u64, 1), storage.worker_lane.tail.load(.acquire));
            try t.expectEqual(@as(u64, 1), storage.control_lane.tail.load(.acquire));
            try t.expectEqual(@as(u8, 2), storage.next_lane);
            try t.expectEqual(@as(usize, 1), try session.serviceAssembler(1));
            try t.expectEqual(@as(u64, 2), storage.control_lane.tail.load(.acquire));
            try t.expectEqual(@as(u8, 2), storage.next_lane);
            try t.expectEqual(@as(usize, 3), compared);
            try t.expectEqual(@as(u64, 2), storage.validator.exclusion_tickets.actual_claims[0]);
            try t.expect(storage.validator.bindings[0] == null);
            try t.expectEqual(@as(u64, 0), storage.validator.semantic_sequences[0]);
            // The following normal attempt is owed even when that lane is empty.
            const selected = session.nextAssemblySelection(1).?;
            try t.expectEqual(@as(u8, 2), selected.lane);
            try t.expect(selected.control_record == null);
            try t.expectEqual(@as(u64, 2), storage.control_lane.tail.load(.acquire));
        },
        .ring_wrap => {
            // Real FIFO reuse, without editing its cursors: the next head is
            // cell255; the exact end will be published beyond the wrap.
            for (0..control_lane_cells - 1) |_| {
                try t.expect(storage.control_lane.push(first));
                try t.expectEqualDeep(first, storage.control_lane.pop().?);
            }
            try t.expectEqual(@as(u64, control_lane_cells - 1), storage.control_lane.tail.load(.acquire));
            try t.expect(storage.control_lane.push(first));
            try t.expect(storage.control_lane.push(second));
            const pending = storage.validator.pendingControlEnd().?;
            try t.expect(!session.publishedControlEnd(pending));
            var wrong = ended;
            wrong.end.result.ticked.frontier_tick_serial += 1;
            try t.expect(storage.control_lane.push(wrong));
            try t.expect(!session.publishedControlEnd(pending));
            try t.expect(storage.control_lane.push(ended));
            try t.expect(session.publishedControlEnd(pending));
            storage.next_lane = 3;
            // These are selection-protocol records, not a valid capture. Even
            // the mismatched end remains FIFO; lookahead cannot skip it.
            for ([_]format.Record{ first, second, wrong, ended }) |expected| {
                const next_lane = storage.next_lane;
                const selected = session.nextAssemblySelection(1).?;
                try t.expectEqualDeep(expected, selected.control_record.?);
                try t.expectEqual(@as(u8, 0), selected.lane);
                try t.expectEqual(next_lane, storage.next_lane);
                const normal = session.nextAssemblySelection(1).?;
                try t.expectEqual(next_lane, normal.lane);
                try t.expect(normal.control_record == null);
            }
            try t.expect(storage.control_lane.empty());
            try t.expectEqual(@as(u64, control_lane_cells + 3), storage.control_lane.tail.load(.acquire));
            try t.expect(storage.validator.bindings[0] == null);
            try t.expectEqual(@as(u64, 0), storage.validator.semantic_sequences[0]);
        },
        .sustained_fairness => {
            // Keep the exact end available throughout two full RR rotations.
            // Only selection/FIFO mechanics run; no owner qualification or
            // semantic validation is inferred from these protocol records.
            for (0..20) |i| {
                var record = first;
                record.service_claim.value.token = @as(u64, @intCast(i)) * 4 + 5;
                record.service_claim.value.kind.stream_close.parent_attempt = i + 1;
                try t.expect(storage.control_lane.push(record));
            }
            try t.expect(storage.control_lane.push(ended));
            var normal_counts: [8]usize = @splat(0);
            var consumed: u64 = 0;
            for (0..16) |turn| {
                const wanted_lane: u8 = @intCast(turn % 8);
                const preferred = session.nextAssemblySelection(1).?;
                try t.expectEqual(@as(u8, 0), preferred.lane);
                try t.expectEqual(consumed * 4 + 5, preferred.control_record.?.service_claim.value.token);
                consumed += 1;
                try t.expectEqual(wanted_lane, storage.next_lane);
                // Exhausting a one-record call cannot erase the fairness debt.
                try t.expect(session.nextAssemblySelection(0) == null);
                try t.expect(storage.control_priority_yield);
                const normal = session.nextAssemblySelection(1).?;
                try t.expectEqual(wanted_lane, normal.lane);
                try t.expect(normal.control_record == null);
                normal_counts[normal.lane] += 1;
                if (normal.lane == 0) {
                    // Match the ordinary Control branch's FIFO pop as well.
                    try t.expectEqual(consumed * 4 + 5, storage.control_lane.pop().?.service_claim.value.token);
                    consumed += 1;
                }
                try t.expectEqual(consumed, storage.control_lane.tail.load(.acquire));
                try t.expect(session.publishedControlEnd(storage.validator.pendingControlEnd().?));
            }
            for (normal_counts) |count| try t.expectEqual(@as(usize, 2), count);
            try t.expectEqual(@as(u64, 18), consumed);
            try t.expectEqual(@as(u8, 0), storage.next_lane);
            try t.expect(storage.validator.bindings[0] == null);
            try t.expectEqual(@as(u64, 0), storage.validator.semantic_sequences[0]);
        },
        .invalid_end => {
            var wrong = ended;
            wrong.end.result.ticked.control_tick = 0;
            try t.expect(storage.control_lane.push(wrong));
            // Exact lookahead identity is only a scheduling hint. The normal
            // cursor still rejects this malformed matching end before binding.
            try t.expectError(error.InvalidRecord, session.serviceAssembler(1));
            try t.expectEqual(AssemblyFailure.Stage.cursor, storage.assembly_failure.?.stage);
            try t.expect(storage.validator.bindings[0] == null);
            try t.expectEqual(@as(u64, 0), storage.validator.semantic_sequences[0]);
            try t.expectEqual(@as(usize, 0), compared);
        },
        .capacity => {
            var index: u16 = 0;
            while (storage.validator.dependencies.pending_total < format.max_dependencies) : (index += 1) {
                try storage.validator.dependencies.publish(.{ .domain = .job_selected, .index = index, .generation = 1 }, .{
                    .role = .control,
                    .operation = 1,
                    .site = .job_queued,
                    .index = index,
                    .generation = 1,
                    .occurrence = 1,
                    .edge = .after,
                });
            }
            try t.expect(storage.control_lane.push(first));
            try t.expect(storage.control_lane.push(ended));
            try t.expectError(error.DependencyCapacity, session.serviceAssembler(1));
            try t.expectEqual(AssemblyFailure.Stage.validator, storage.assembly_failure.?.stage);
            try t.expectEqual(@as(usize, 256), storage.validator.dependencies.pending_total);
            try t.expectEqual(@as(u64, 1), storage.control_lane.tail.load(.acquire));
            try t.expect(storage.validator.bindings[0] == null);
            try t.expectEqual(@as(usize, 0), compared);
        },
    }
}
