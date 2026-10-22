//! Finite Control-produced readiness/supply evidence, not a recording profile.
//! Attach/close/detach through ControlRuntime with exact peer owners pinned.
//! The host excludes consumers and lifecycle/request callers for lifecycle.
//! One producer, one consumer; copies only, no allocation, retry, or wait.
const std = @import("std");
const capture = @import("sme-capture-handoff-control");
const music = @import("music");
const trace = music.trace;
const scheduler = @import("sme-scheduler");
const music_group = @import("../mixer/music_group.zig");
pub const observation = @import("sme-streaming").stream.readiness_observation;
const frontier = @import("control_frontier_witness.zig");
const acceptance = @import("stream_acceptance_witness.zig");
const render = @import("render_causal_witness.zig");
pub const Phase = frontier.Phase;
pub const slot_capacity: usize = 256;
pub const events_per_tick: u32 = 256;
pub const events_per_interval: u64 = 4096;
pub const queries_per_tick: u32 = 48;
pub const max_event_bytes: usize = 512;
pub const Error = error{ InvalidState, StaleSession, Undrained, IdentityExhausted, ConcurrentLifecycle };
var next_incarnation: std.atomic.Value(u64) = .init(1);
pub const Peer = render.ControlSession;
pub const Manifest = struct {
    /// Frozen at attachment; the legacy readiness-only event stream is unchanged.
    capture_acquisitions: bool = false,
    capture_reconciliation: bool = false,
    interval_id: u64,
    control_frontier: Peer,
    stream_acceptance: Peer,
    render_incarnation: u64,
    render_generation: u64,
    renderer_identity: u64,
    music_handle_incarnation: u32,
    music_context: u64,
    transport_epoch: u64,
    asset_generation: u64,
    bank_hash: [32]u8,
    profile_hash: [32]u8,
    initial_frame: u64,
    initial_gate: u64,
    initial_call_sequence: u64,
    initial_observation_sequence: u64,
};
pub const Session = struct { bridge: *const Bridge, incarnation: u64, generation: u64, interval_id: u64 };
pub const Anchors = struct { plan_ordinal: u64 = 0, plan_sequence: u64 = 0, acceptance_ordinal: u64 = 0, acceptance_sequence: u64 = 0 };
pub const Output = struct { facts: trace.schema.readiness.Facts, projection: trace.schema.readiness.Projection };
/// Every entry describes one reached read, not a simultaneous snapshot. Empty
/// polls retain the exact independently acquired prefix and unchanged cursor.
/// Result payloads are observations only; reconstruction must run real Render.
pub const AcquisitionKind = enum {
    collect_frame,
    receipts_frame,
    phase_frame,
    schedule_result,
    schedule_admission,
    execution_receipt,
    plan_phase,
    source_switch,
    group_terminal,
    cancellation_result,
};
pub const Acquisition = struct {
    kind: AcquisitionKind,
    handle: scheduler.Handle = .{ .index = 0, .generation = 0 },
    plan: ?scheduler.Handle = null,
    token: ?music.PhaseToken = null,
    batch_id: u64 = 0,
    content_hash: [32]u8 = @splat(0),
    /// The existing handle-validation load, preceding the independent read.
    validation_state: ?scheduler.State = null,
    cursor_before: u16 = 0,
    cursor_after: u16 = 0,
    /// Actual frame, receipt/phase prefix, slot state, or cell publication bit.
    observed: u64 = 0,
    reached: bool = false,
    returned: bool = false,
    result_id: u64 = 0,
    effective_frame: u64 = 0,
    result_count: u16 = 0,
    error_code: u32 = 0,
    cell: union(enum) { none: void, source_switch: music_group.SourceSwitch, group_terminal: music_group.Terminal, cancellation: scheduler.render_observation.CancellationRead } = .{ .none = {} },
};
/// Owned resource lifetimes. Optional fields are only set after the original
/// operational read is reached. No pointer/PCM or expected replay input.
pub const ReconciliationKind = enum {
    completion_pop,
    terminal_scan,
    schedule_release,
    schedule_group_return,
    schedule_prepare,
    schedule_group_retain,
    schedule_group_bind,
    group_prepare,
    group_release,
    group_desired,
    instance_prepare,
    initial_stream_retain,
    initial_stream_return,
};
pub const Reconciliation = struct {
    kind: ReconciliationKind,
    parent_attempt: u64 = 0,
    handle: scheduler.Handle = .{ .index = 0, .generation = 0 },
    /// A retain precedes block construction; its later bind supplies the real
    /// returned block and sorted command ordinal under the same parent attempt.
    block: ?scheduler.Handle = null,
    command_id: u64 = 0,
    input_ordinal: ?u16 = null,
    command_count: u16 = 0,
    instance: scheduler.Handle = .{ .index = 0, .generation = 0 },
    stream: observation.Handle = .{ .index = 0, .generation = 0 },
    stream_index_known: bool = false,
    bank_generation: u64 = 0,
    reservation: u64 = 0,
    start_order: ?u64 = null,
    desired_start_order: ?u64 = null,
    read_position: u64 = 0,
    write_position: u64 = 0,
    cursor_after: u64 = 0,
    instance_state: ?u32 = null,
    instance_current: ?bool = null,
    desired_active: ?bool = null,
    instance_matches: ?bool = null,
    reservation_matches: ?bool = null,
    release_attempted: bool = false,
    release_cas: ?u32 = null,
    validation_state: ?scheduler.State = null,
    terminal_state: ?scheduler.State = null,
    invalidation_refs: ?u16 = null,
    queue_refs: ?u8 = null,
    pin_mask: ?u16 = null,
    references: ?u16 = null,
    references_after: ?u16 = null,
    start_scheduled: ?bool = null,
    first_slot: u16 = 0,
    scanned: u16 = 0,
    /// Two 4-bit State values per byte, in original scan order.
    states: [32]u8 = @splat(0),
    ordinal: u16 = 0,
    voice_count: u16 = 0,
    completion_reason: u8 = 0,
    present: bool = false,
    returned: bool = false,
    error_code: u32 = 0,
};
pub const Payload = union(enum) { tick_open: void, tick_close: u32, query_reads: observation.QueryRead, query_output: Output, supply: observation.SupplyRead, throughput: observation.ThroughputFold, acquisition: Acquisition, invalidation_publication: scheduler.render_observation.InvalidationPublication, reconciliation: Reconciliation, scheduler_control: scheduler.ControlObservation, stream_lifecycle: observation.LifecycleRead };
pub const Event = struct {
    incarnation: u64,
    generation: u64,
    sequence: u64 = 0,
    key: observation.QueryKey,
    anchors: Anchors,
    payload: Payload,
};
pub const Failure = enum(u8) { none, queue_full, tick_budget, interval_budget, query_budget, counter_exhausted, interrupted, representation_bound, cancelled, measurement_mismatch, frontier_mismatch, capture_failed };
pub const Status = struct { closed: bool, incomplete: bool, failure: Failure, events_attempted: u64, events_published: u64, events_consumed: u64, dropped_events: u64 };
pub const Terminal = struct { incarnation: u64, generation: u64, manifest: Manifest, incomplete: bool, failure: Failure, events_attempted: u64, events_published: u64, dropped_events: u64, ticks_opened: u64, ticks_closed: u64, final_frame: u64, final_call_sequence: u64, final_gate: u64, final_observation_sequence: u64 };
pub const MeasurementFact = struct { key: observation.QueryKey, measurement: observation.ReadinessMeasurement };
/// Strict sequential matching rejects removal, duplication, reordering and
/// absent/null ambiguity. The driver must also verify its peer identity map.
pub const MeasurementTape = struct {
    facts: []const MeasurementFact,
    cursor: usize = 0,
    failed: bool = false,
    pub fn source(self: *MeasurementTape) observation.MeasurementSource {
        return .{ .context = self, .select = select, .finish = finishSource };
    }
    fn select(context: *anyopaque, key: observation.QueryKey) error{IncompleteTrace}!observation.ReadinessMeasurement {
        const self: *MeasurementTape = @ptrCast(@alignCast(context));
        if (self.failed or key.interval_id == 0 or key.tick_serial == 0 or key.attempt_ordinal == 0 or self.cursor >= self.facts.len or !std.meta.eql(self.facts[self.cursor].key, key)) {
            self.failed = true;
            return error.IncompleteTrace;
        }
        if (self.cursor != 0) {
            const previous = self.facts[self.cursor - 1].key;
            if (key.interval_id != previous.interval_id or key.tick_serial < previous.tick_serial or (key.tick_serial == previous.tick_serial and key.attempt_ordinal <= previous.attempt_ordinal)) {
                self.failed = true;
                return error.IncompleteTrace;
            }
        }
        const result = self.facts[self.cursor].measurement;
        self.cursor += 1;
        return result;
    }
    fn finishSource(raw: *anyopaque) error{IncompleteTrace}!void {
        const self: *MeasurementTape = @ptrCast(@alignCast(raw));
        return self.finish();
    }
    pub fn finish(self: *const MeasurementTape) error{IncompleteTrace}!void {
        if (self.failed or self.cursor != self.facts.len) return error.IncompleteTrace;
    }
};
pub const PublishHook = struct { context: *anyopaque, call: *const fn (*anyopaque, *Bridge, Event) void };
pub const Bridge = struct {
    /// Detached setup field; changing it cannot alter an attached generation.
    configured_continuous: ?capture.Session = null,
    // Frozen producer binding. Only attach/detach may replace this handle.
    continuous: ?capture.Session = null,
    continuous_failed: bool = false,
    slots: [slot_capacity]Event = undefined,
    scratch: Event = undefined,
    /// Set only while detached. attachAtBoundary freezes this in the manifest.
    capture_acquisitions: bool = false,
    capture_reconciliation: bool = false,
    test_before_acquire_hook: if (@import("builtin").is_test) ?PublishHook else void = if (@import("builtin").is_test) null else {},
    test_before_publish_hook: if (@import("builtin").is_test) ?PublishHook else void = if (@import("builtin").is_test) null else {},
    test_measurement_source: if (@import("builtin").is_test) ?observation.MeasurementSource else void = if (@import("builtin").is_test) null else {},
    incarnation: std.atomic.Value(u64) = .init(0),
    generation: std.atomic.Value(u64) = .init(0),
    read_cursor: std.atomic.Value(u64) = .init(0),
    write_cursor: std.atomic.Value(u64) = .init(0),
    attempted: std.atomic.Value(u64) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),
    closed: std.atomic.Value(bool) = .init(true),
    failure: std.atomic.Value(Failure) = .init(.none),
    owner: ?*const anyopaque = null,
    manifest: Manifest = undefined,
    frontier_peer: ?*frontier.Bridge = null,
    acceptance_peer: ?*acceptance.Bridge = null,
    tick_open: bool = false,
    operation_open: bool = false,
    tick_serial: u64 = 0,
    control_tick: u64 = 0,
    phase: Phase = .idle,
    frame: u64 = 0,
    input_order: u64 = 0,
    current_control_epoch: u64 = 0,
    attempt_ordinal: u64 = 0,
    last_query_key: observation.QueryKey = .{},
    tick_events: u32 = 0,
    tick_queries: u32 = 0,
    ticks_opened: u64 = 0,
    ticks_closed: u64 = 0,
    terminal_value: Terminal = undefined,
    pub fn configureContinuous(self: *Bridge, session: ?capture.Session) Error!void {
        if (self.owner != null or !self.closed.load(.acquire)) return error.InvalidState;
        if (self.read_cursor.load(.acquire) != self.write_cursor.load(.acquire)) return error.Undrained;
        if (session) |value| try capture.validateAttachment(value, .readiness, value.descriptor.interval_id);
        self.configured_continuous = session;
        self.continuous_failed = false;
    }
    pub fn continuousSession(self: *const Bridge) Error!?capture.Session {
        const session = if (self.owner != null) self.continuous else self.configured_continuous;
        if (session) |value| try capture.validate(value);
        return session;
    }
    pub fn continuousDescriptor(self: *const Bridge) Error!?capture.Descriptor {
        return if (try self.continuousSession()) |session| session.descriptor else null;
    }
    fn observeContinuousFailure(self: *Bridge) bool {
        const session = self.continuous orelse return false;
        if ((capture.failure(session) catch .invalid_state) != .none) {
            self.continuous_failed = true;
            if (self.failure.load(.monotonic) == .none) self.failure.store(.capture_failed, .release);
        }
        return self.continuous_failed;
    }
    fn acknowledgeContinuousFailure(self: *Bridge) void {
        if (self.tick_open or self.operation_open or !self.observeContinuousFailure()) return;
        capture.acknowledgeProducer(self.continuous.?, .readiness, .{ .events_attempted = self.attempted.load(.monotonic), .events_published = self.write_cursor.load(.monotonic) }) catch {};
    }
    pub fn attachAtBoundary(self: *Bridge, owner: *const anyopaque, manifest: Manifest, f: *frontier.Bridge, a: *acceptance.Bridge) Error!Session {
        if (self.owner != null or !self.closed.load(.acquire) or manifest.interval_id == 0 or manifest.initial_call_sequence & 1 != 0 or manifest.initial_observation_sequence & 1 != 0 or manifest.control_frontier.interval_id != manifest.interval_id or manifest.stream_acceptance.interval_id != manifest.interval_id) return error.InvalidState;
        if (self.read_cursor.load(.acquire) != self.write_cursor.load(.acquire)) return error.Undrained;
        if (manifest.music_context == 0 or manifest.music_handle_incarnation == 0 or manifest.renderer_identity == 0 or manifest.render_incarnation == 0 or manifest.render_generation == 0 or trace.schema.isZero(manifest.bank_hash) or trace.schema.isZero(manifest.profile_hash) or f.owner != owner or a.owner != owner) return error.InvalidState;
        const fs = try f.status(.{ .bridge = f, .incarnation = manifest.control_frontier.incarnation, .generation = manifest.control_frontier.generation, .owner_identity = manifest.control_frontier.owner_identity, .interval_id = manifest.interval_id });
        const as = try a.status(.{ .bridge = a, .incarnation = manifest.stream_acceptance.incarnation, .generation = manifest.stream_acceptance.generation, .owner_identity = manifest.stream_acceptance.owner_identity, .interval_id = manifest.interval_id });
        if (fs.closed or fs.incomplete or as.closed or as.incomplete) return error.InvalidState;
        try capture.validatePeers(try self.continuousSession(), try f.continuousSession());
        try capture.validatePeers(try self.continuousSession(), try a.continuousSession());
        if (self.configured_continuous) |session| try capture.validateAttachment(session, .readiness, manifest.interval_id);
        const generation = self.generation.load(.monotonic);
        if (generation == std.math.maxInt(u64)) return error.IdentityExhausted;
        var incarnation = self.incarnation.load(.monotonic);
        if (incarnation == 0) {
            incarnation = next_incarnation.load(.acquire);
            if (incarnation == std.math.maxInt(u64)) return error.IdentityExhausted;
            if (next_incarnation.cmpxchgStrong(incarnation, incarnation + 1, .acq_rel, .acquire) != null) return error.ConcurrentLifecycle;
        }
        if (self.configured_continuous) |session| capture.bindProducer(session, .readiness);
        self.continuous = self.configured_continuous;
        self.configured_continuous = null; // consume the setup borrow
        self.continuous_failed = false;
        self.owner = owner;
        self.manifest = manifest;
        self.manifest.capture_acquisitions = self.capture_acquisitions;
        self.manifest.capture_reconciliation = self.capture_reconciliation;
        self.frontier_peer = f;
        self.acceptance_peer = a;
        self.tick_open = false;
        self.operation_open = false;
        self.tick_serial = 0;
        self.control_tick = 0;
        self.ticks_opened = 0;
        self.ticks_closed = 0;
        self.read_cursor.store(0, .monotonic);
        self.write_cursor.store(0, .monotonic);
        self.attempted.store(0, .monotonic);
        self.dropped.store(0, .monotonic);
        self.failure.store(.none, .monotonic);
        self.incarnation.store(incarnation, .monotonic);
        self.generation.store(generation + 1, .release);
        self.closed.store(false, .release);
        return .{ .bridge = self, .incarnation = incarnation, .generation = generation + 1, .interval_id = manifest.interval_id };
    }
    pub fn beginTick(self: *Bridge, serial: u64, tick: u64) void {
        if (self.closed.load(.acquire)) return;
        // Runtime has already admitted the real operation. Even if failure
        // predates this call, retain its end hook and acknowledge only there.
        _ = self.observeContinuousFailure();
        if (self.tick_open or serial <= self.tick_serial or tick <= self.control_tick) {
            self.markIncomplete(.interrupted);
            return;
        }
        self.tick_open = true;
        self.tick_serial = serial;
        self.control_tick = tick;
        self.attempt_ordinal = 0;
        self.tick_events = 0;
        self.tick_queries = 0;
        self.phase = .collect;
        self.frame = 0;
        self.input_order = 0;
        self.current_control_epoch = 0;
        self.ticks_opened = std.math.add(u64, self.ticks_opened, 1) catch {
            self.markIncomplete(.counter_exhausted);
            return;
        };
        self.publish(self.event(.{ .tick_open = {} }, .{}));
    }
    pub fn context(self: *Bridge, phase: Phase, frame: u64, order: u64) void {
        self.phase = phase;
        self.frame = frame;
        self.input_order = order;
    }
    fn anchors(self: *const Bridge) Anchors {
        // All producer-owned fields: no new engine/Render/Worker loads.
        return .{ .plan_ordinal = self.frontier_peer.?.query_ordinal, .plan_sequence = self.frontier_peer.?.events_attempted.load(.monotonic), .acceptance_ordinal = self.acceptance_peer.?.attempt_ordinal, .acceptance_sequence = self.acceptance_peer.?.events_attempted.load(.monotonic) };
    }
    fn event(self: *const Bridge, payload: Payload, key: observation.QueryKey) Event {
        var k = key;
        k.interval_id = self.manifest.interval_id;
        // Query fields are the attempted engine inputs, including invalid
        // zero values. Only implicit supply/tick records inherit owner context.
        if (payload != .query_reads) {
            if (k.context == 0) k.context = self.manifest.music_context;
            if (k.control_epoch == 0) k.control_epoch = self.current_control_epoch;
            k.position = .{ .accepted_control_frame = self.frame, .control_tick = self.control_tick, .input_order = self.input_order };
        }
        k.tick_serial = self.tick_serial;
        k.phase = @intCast(@intFromEnum(self.phase));
        k.transport_epoch = self.manifest.transport_epoch;
        return .{ .incarnation = self.incarnation.load(.monotonic), .generation = self.generation.load(.monotonic), .key = k, .anchors = self.anchors(), .payload = payload };
    }
    fn begin(self: *Bridge, payload: Payload, key: observation.QueryKey) bool {
        if (!self.tick_open or self.closed.load(.acquire) or self.observeContinuousFailure()) return false;
        if (self.attempt_ordinal == std.math.maxInt(u64)) {
            self.markIncomplete(.counter_exhausted);
            return false;
        }
        self.attempt_ordinal += 1;
        if (self.operation_open) {
            self.markIncomplete(.interrupted);
            return false;
        }
        self.scratch = self.event(payload, key);
        self.scratch.key.attempt_ordinal = self.attempt_ordinal;
        self.operation_open = true;
        return true;
    }
    pub fn beginReconciliation(self: *Bridge, kind: ReconciliationKind) ?*Reconciliation {
        if (!self.tick_open or self.closed.load(.acquire) or !self.manifest.capture_reconciliation) return null;
        if (!self.begin(.{ .reconciliation = .{ .kind = kind } }, .{})) return null;
        if (@import("builtin").is_test) if (self.test_before_acquire_hook) |hook| hook.call(hook.context, self, self.scratch);
        return &self.scratch.payload.reconciliation;
    }
    pub fn finishReconciliation(self: *Bridge) u64 {
        if (!self.operation_open or self.scratch.payload != .reconciliation) {
            self.markIncomplete(.interrupted);
            return 0;
        }
        const attempt = self.scratch.key.attempt_ordinal;
        self.publish(self.scratch);
        self.operation_open = false;
        return attempt;
    }
    pub fn observeSchedulerControl(self: *Bridge, value: scheduler.ControlObservation) void {
        if (!self.manifest.capture_reconciliation) return;
        if (value == .operation and value.operation.sequence_exhausted) self.markIncomplete(.counter_exhausted);
        if (!self.begin(.{ .scheduler_control = value }, .{})) return;
        self.publish(self.scratch);
        self.operation_open = false;
    }
    pub fn observeStreamLifecycle(self: *Bridge, value: observation.LifecycleRead) u64 {
        if (!self.manifest.capture_reconciliation or !self.begin(.{ .stream_lifecycle = value }, .{})) return 0;
        const attempt = self.scratch.key.attempt_ordinal;
        self.publish(self.scratch);
        self.operation_open = false;
        return attempt;
    }
    pub fn beginInvalidationPublication(self: *Bridge) ?*scheduler.render_observation.InvalidationPublication {
        if (!self.tick_open or self.closed.load(.acquire) or !self.manifest.capture_acquisitions) return null;
        if (!self.begin(.{ .invalidation_publication = .{} }, .{})) return null;
        return &self.scratch.payload.invalidation_publication;
    }
    pub fn finishInvalidationPublication(self: *Bridge) void {
        if (!self.operation_open or self.scratch.payload != .invalidation_publication) {
            self.markIncomplete(.interrupted);
            return;
        }
        self.publish(self.scratch);
        self.operation_open = false;
    }
    pub fn beginAcquisition(self: *Bridge, kind: AcquisitionKind, handle: scheduler.Handle, cursor: u16) ?*Acquisition {
        if (!self.tick_open or self.closed.load(.acquire) or !self.manifest.capture_acquisitions) return null;
        if (!self.begin(.{ .acquisition = .{ .kind = kind, .handle = handle, .cursor_before = cursor, .cursor_after = cursor } }, .{})) return null;
        // A barrier may advance actual publishers, but cannot supply an acquired
        // value, phase payload, source clock, schedule, or expected PCM.
        if (@import("builtin").is_test) if (self.test_before_acquire_hook) |hook| hook.call(hook.context, self, self.scratch);
        return &self.scratch.payload.acquisition;
    }
    pub fn finishAcquisition(self: *Bridge) void {
        if (!self.operation_open or self.scratch.payload != .acquisition) {
            self.markIncomplete(.interrupted);
            return;
        }
        self.publish(self.scratch);
        self.operation_open = false;
    }
    pub fn beginQuery(self: *Bridge, key: observation.QueryKey) ?*observation.QueryRead {
        self.tick_queries = std.math.add(u32, self.tick_queries, 1) catch {
            self.markIncomplete(.counter_exhausted);
            return null;
        };
        if (self.tick_queries > queries_per_tick) self.markIncomplete(.query_budget);
        self.last_query_key = key;
        self.last_query_key.interval_id = self.manifest.interval_id;
        self.last_query_key.tick_serial = self.tick_serial;
        self.last_query_key.phase = @intCast(@intFromEnum(self.phase));
        self.last_query_key.transport_epoch = self.manifest.transport_epoch;
        if (!self.begin(.{ .query_reads = .{} }, key)) {
            self.last_query_key.attempt_ordinal = if (self.attempt_ordinal == std.math.maxInt(u64)) 0 else self.attempt_ordinal;
            return null;
        }
        self.last_query_key = self.scratch.key;
        return &self.scratch.payload.query_reads;
    }
    pub fn queryKey(self: *const Bridge) observation.QueryKey {
        return self.last_query_key;
    }
    pub fn measurementSource(self: *Bridge) ?observation.MeasurementSource {
        if (@import("builtin").is_test) return self.test_measurement_source;
        return null;
    }
    pub fn finishQuery(self: *Bridge, output: ?*const trace.Input) void {
        if (!self.operation_open or self.scratch.payload != .query_reads) {
            self.markIncomplete(.interrupted);
            return;
        }
        if (!self.scratch.payload.query_reads.representation_complete) self.markIncomplete(.representation_bound);
        self.publish(self.scratch);
        self.operation_open = false;
        if (output) |value| {
            const snapshot = &value.payload.readiness_snapshot;
            self.scratch.payload = .{ .query_output = .{ .facts = snapshot.facts, .projection = snapshot.expected } };
            self.publish(self.scratch);
        }
    }
    pub fn supplySink(self: *Bridge) observation.SupplySink {
        return .{ .context = self, .begin = beginSupply, .finish = finishSupply, .throughput = observeThroughput };
    }
    fn beginSupply(raw: *anyopaque, kind: observation.SupplyKind, handle: observation.Handle, frame: ?u64, parent: u64) ?*observation.SupplyRead {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (!self.begin(.{ .supply = .{ .kind = kind, .parent_attempt = parent } }, .{ .handle = handle })) return null;
        self.scratch.payload.supply.availability.requested_frame = frame;
        return &self.scratch.payload.supply;
    }
    fn finishSupply(raw: *anyopaque) u64 {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (!self.operation_open or self.scratch.payload != .supply) {
            self.markIncomplete(.interrupted);
            return 0;
        }
        const ordinal = self.scratch.key.attempt_ordinal;
        const supply = &self.scratch.payload.supply;
        if (supply.availability.sequence_before != null) supply.reached |= observation.bit(.availability_sequence);
        if (supply.availability.frame != null) supply.reached |= observation.bit(.availability_frame);
        if (supply.availability.consumed != null) supply.reached |= observation.bit(.availability_consumed);
        if (supply.availability.produced != null) supply.reached |= observation.bit(.availability_produced);
        if (supply.availability.sequence_after != null) supply.reached |= observation.bit(.availability_after);
        self.publish(self.scratch);
        self.operation_open = false;
        return ordinal;
    }
    fn observeThroughput(raw: *anyopaque, fold: observation.ThroughputFold) void {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (!self.tick_open or self.closed.load(.acquire)) return;
        self.publish(self.event(.{ .throughput = fold }, .{}));
    }
    pub fn endTick(self: *Bridge, err: ?anyerror) void {
        if (!self.tick_open) return;
        if (self.operation_open) self.markIncomplete(.interrupted);
        self.phase = .publish;
        self.publish(self.event(.{ .tick_close = if (err) |value| @intFromError(value) else 0 }, .{}));
        self.tick_open = false;
        self.ticks_closed = std.math.add(u64, self.ticks_closed, 1) catch blk: {
            self.markIncomplete(.counter_exhausted);
            break :blk self.ticks_closed;
        };
        self.acknowledgeContinuousFailure();
    }
    /// Closure requires a genuinely quiescent renderer as well as idle Control;
    /// a stop request never manufactures that lifetime or final sequence proof.
    pub fn closeAtBoundary(self: *Bridge, session: Session, owner: *const anyopaque, frame: u64, call: u64, gate: u64, sequence: u64) Error!void {
        try self.validateOwner(session, owner);
        if (self.tick_open or self.operation_open or call & 1 != 0 or sequence & 1 != 0) return error.InvalidState;
        if (self.closed.load(.acquire)) return;
        _ = self.observeContinuousFailure();
        self.validateFinalFrontier(gate, sequence);
        if (@import("builtin").is_test) if (self.test_measurement_source) |source| source.finish(source.context) catch self.markIncomplete(.measurement_mismatch);
        const f = self.failure.load(.monotonic);
        self.terminal_value = .{ .incarnation = session.incarnation, .generation = session.generation, .manifest = self.manifest, .incomplete = f != .none, .failure = f, .events_attempted = self.attempted.load(.monotonic), .events_published = self.write_cursor.load(.monotonic), .dropped_events = self.dropped.load(.monotonic), .ticks_opened = self.ticks_opened, .ticks_closed = self.ticks_closed, .final_frame = frame, .final_call_sequence = call, .final_gate = gate, .final_observation_sequence = sequence };
        self.acknowledgeContinuousFailure();
        self.closed.store(true, .release);
    }
    fn validateFinalFrontier(self: *Bridge, gate: u64, sequence: u64) void {
        // In this direct-Render cut every completed gate contains exactly one
        // endRenderSpan. Checked arithmetic rejects wrap; parity alone cannot
        // distinguish a wrapped even frontier from an ordinary completed one.
        const spans = std.math.sub(u64, gate, self.manifest.initial_gate) catch {
            self.markIncomplete(.frontier_mismatch);
            return;
        };
        const increments = std.math.mul(u64, spans, 2) catch {
            self.markIncomplete(.frontier_mismatch);
            return;
        };
        const expected = std.math.add(u64, self.manifest.initial_observation_sequence, increments) catch {
            self.markIncomplete(.frontier_mismatch);
            return;
        };
        if (sequence != expected) self.markIncomplete(.frontier_mismatch);
    }
    pub fn detachAtBoundary(self: *Bridge, session: Session, owner: *const anyopaque) Error!void {
        try self.validateOwner(session, owner);
        if (!self.closed.load(.acquire) or self.tick_open or self.operation_open) return error.InvalidState;
        if (self.read_cursor.load(.acquire) != self.write_cursor.load(.acquire)) return error.Undrained;
        self.owner = null;
        self.continuous = null;
        self.configured_continuous = null; // no hidden borrow after detach
        self.frontier_peer = null;
        self.acceptance_peer = null;
    }
    pub fn pop(self: *Bridge, session: Session) Error!?Event {
        try self.validate(session);
        const read = self.read_cursor.load(.monotonic);
        if (read == self.write_cursor.load(.acquire)) return null;
        const result = self.slots[@intCast(read % slot_capacity)];
        self.read_cursor.store(read + 1, .release);
        return result;
    }
    pub fn status(self: *const Bridge, session: Session) Error!Status {
        try self.validate(session);
        const local_failure = self.failure.load(.acquire);
        const f: Failure = if (local_failure != .none) local_failure else if (self.continuous) |value| (if ((capture.failure(value) catch .invalid_state) != .none) .capture_failed else .none) else .none;
        return .{ .closed = self.closed.load(.acquire), .incomplete = f != .none, .failure = f, .events_attempted = self.attempted.load(.acquire), .events_published = self.write_cursor.load(.acquire), .events_consumed = self.read_cursor.load(.acquire), .dropped_events = self.dropped.load(.acquire) };
    }
    pub fn terminal(self: *const Bridge, session: Session) Error!?Terminal {
        try self.validate(session);
        if (!self.closed.load(.acquire)) return null;
        return self.terminal_value;
    }
    fn validate(self: *const Bridge, session: Session) Error!void {
        if (session.bridge != self or session.incarnation == 0 or session.incarnation != self.incarnation.load(.acquire) or session.generation == 0 or session.generation != self.generation.load(.acquire) or session.interval_id != self.manifest.interval_id) return error.StaleSession;
    }
    fn validateOwner(self: *const Bridge, session: Session, owner: *const anyopaque) Error!void {
        try self.validate(session);
        if (self.owner != owner) return error.InvalidState;
    }
    pub fn markIncomplete(self: *Bridge, f: Failure) void {
        if (self.closed.load(.monotonic) or f == .none) return;
        if (self.continuous) |session| {
            self.continuous_failed = true;
            capture.fail(session, .producer_failure) catch {};
        }
        if (self.failure.load(.monotonic) == .none) self.failure.store(f, .release);
    }
    fn publish(self: *Bridge, event_value: Event) void {
        if (self.observeContinuousFailure()) return;
        const n = self.attempted.load(.monotonic);
        if (n == std.math.maxInt(u64)) {
            self.markIncomplete(.counter_exhausted);
            return;
        }
        self.attempted.store(n + 1, .release);
        self.tick_events = std.math.add(u32, self.tick_events, 1) catch {
            self.markIncomplete(.counter_exhausted);
            return;
        };
        if (self.tick_events > events_per_tick) self.markIncomplete(.tick_budget);
        const limit = if (self.continuous) |session| session.descriptor.event_limit else events_per_interval;
        if (n >= limit) self.markIncomplete(.interval_budget);
        const write = self.write_cursor.load(.monotonic);
        if (write == std.math.maxInt(u64)) self.markIncomplete(.counter_exhausted);
        if (write - self.read_cursor.load(.acquire) >= slot_capacity) self.markIncomplete(.queue_full);
        if (self.failure.load(.monotonic) != .none) {
            const dropped = std.math.add(u64, self.dropped.load(.monotonic), 1) catch {
                self.markIncomplete(.counter_exhausted);
                return;
            };
            self.dropped.store(dropped, .release);
            return;
        }
        const slot = &self.slots[@intCast(write % slot_capacity)];
        slot.* = event_value;
        slot.sequence = n + 1;
        if (@import("builtin").is_test) if (self.test_before_publish_hook) |hook| hook.call(hook.context, self, slot.*);
        self.write_cursor.store(write + 1, .release);
    }
};
pub const event_bytes: usize = @sizeOf(Event);
pub const slot_storage_bytes: usize = slot_capacity * event_bytes;
pub const bridge_bytes: usize = @sizeOf(Bridge);
pub const scratch_bytes: usize = @sizeOf(Event);
pub const bridge_metadata_bytes: usize = bridge_bytes - slot_storage_bytes - scratch_bytes;
comptime {
    if (event_bytes > max_event_bytes or scratch_bytes > max_event_bytes or slot_storage_bytes > 128 * 1024 or bridge_metadata_bytes > 2048) @compileError("Readiness bridge representation budget exceeded");
}
