//! TASK-008 control-only Director. Selection is intent; only an exact bound
//! successful target-entry PhaseReceipt changes committed state/history.
const std = @import("std");
const music = @import("music");
const bank = @import("sme-bank");
pub const s = bank.schema;
pub const logic = @import("sme-logic");
pub const selector = @import("sme-selector");
const recording = @import("sme-trace");
const clock_module = @import("sme-clock");
pub const resident_migration = @import("sme-resident-migration");
pub const trace = recording.schema;
pub const Error = bank.selection_validation.AdmissionError || resident_migration.Error || error{ InvalidOrder, BufferTooSmall };
pub const TransitionIntent = struct {
    request_id: u64,
    from: u64,
    to: u64,
    selector: u64,
    resolved_segment: u64,
    priority: u8,
    rule_id: u64,
    request_epoch: u64,
    selector_epoch: u64,
};
pub const Config = struct {
    tables: s.Tables,
    profile: s.Platform = .{},
    bank_build_id: u64,
    seed: u64,
    initial_state: u64,
    initial_segment: u64,
    context: u64,
    asset_generation: u64 = 1,
    transport_epoch: u64 = 1,
    initial_frame: u64 = 0,
    initial_bar: u64 = 0,
};
pub const ParameterState = struct {
    value: i32 = 0,
    target: i32 = 0,
    start: i32 = 0,
    start_frame: u64 = 0,
    duration: u32 = 0,
    fn advance(self: *ParameterState, frame: u64) Error!void {
        if (frame < self.start_frame) return error.InvalidOrder;
        const elapsed = frame - self.start_frame;
        if (elapsed >= self.duration) {
            self.value = self.target;
            return;
        }
        const numerator = @as(i128, self.target - @as(i64, self.start)) * elapsed;
        const denominator: i128 = self.duration;
        const lo = @divFloor(numerator, denominator);
        const remainder = @mod(numerator, denominator);
        const increment = lo + @intFromBool(remainder > denominator - remainder or (remainder == denominator - remainder and @mod(@as(i128, self.start) + lo, 2) != 0));
        self.value = @intCast(@as(i128, self.start) + increment);
    }
};
const Desired = struct { request_id: u64, target: u32, priority: u8, position: trace.Position, since_bar: u64 };
pub const IntentProvenance = enum(u8) { selector, rule_fallback };
/// Selection-time condition/weight observations, not authenticated historical
/// evidence. The same-build resident codec binds their candidate ordering.
const ResidentEligibility = struct {
    bits: [4]u64 = @splat(0),
    valid: bool = false,
    fn contains(self: *const ResidentEligibility, index: usize) bool {
        return (self.bits[index / 64] & (@as(u64, 1) << @intCast(index % 64))) != 0;
    }
};
const Pending = struct {
    provenance: IntentProvenance = .selector,
    active: bool = false,
    intent: TransitionIntent = undefined,
    selector_index: u32 = 0,
    target_state: u32 = 0,
    choice: selector.Choice = undefined,
    token: ?music.PhaseToken = null,
    superseded: bool = false,
    accepted_frame: u64 = 0,
    resident_eligibility: ResidentEligibility = .{},
};
/// Pointer-free owner identity. Callers retain and return this value unchanged;
/// the cancelled choice and its provenance remain private to the Director.
pub const SuspendedTargetEntry = struct { identity: [4]u64 };
const TransportAcceptance = struct {
    request_id: u64,
    position: trace.Position,
    request_epoch: u64,
};
const Suspended = struct {
    handle: SuspendedTargetEntry,
    pending: Pending,
    desired: ?Desired,
    committed_state: u32,
    committed_segment: u32,
    request_epoch: u64,
    transport_epoch: u64,
    pause: TransportAcceptance,
    invalidated: bool = false,
    /// An actual restore receipt installed this origin; no pause was accepted.
    restore_origin: ?TransportAcceptance = null,
};
pub const snapshot_version: u16 = 1;
pub const snapshot_capacity: usize = 160 * 1024;
/// Owned pointer-free value. Allocate this and Director on the control owner's
/// heap/workspace, not on a 512KiB audio thread stack. Capture allocates nothing.
pub const DirectorSelectorSnapshotV1 = struct {
    version: u16 = snapshot_version,
    length: u32 = 0,
    payload: [snapshot_capacity]u8 = @splat(0),
};
pub const snapshot_v2_version: u16 = 2;
pub const DirectorSelectorSnapshotV2 = struct {
    version: u16 = snapshot_v2_version,
    length: u32 = 0,
    payload: [snapshot_capacity]u8 = @splat(0),
};
/// Separate logical resident codec. No old request, token, plan or group is wire
/// authority. The owner stores this on the heap, never on a Worker/Render stack.
pub const resident_snapshot_version: u16 = 1;
pub const DirectorResidentSnapshotV1 = struct {
    version: u16 = resident_snapshot_version,
    length: u32 = 0,
    payload: [snapshot_capacity]u8 = @splat(0),
};
pub const ResidentPlaybackMode = enum(u8) { ready, playing, paused };
pub const ResidentCapturePlan = struct {
    phase_count: u8,
    baseline_executed_prefix: u8 = 0,
    target_phase_index: u8,
    target_token: music.PhaseToken,
};
/// Private, process-local retained baseline. Unlike the exported bytes, this
/// borrows only the immutable admitted tables; its owner must retain the bank.
pub const ResidentCaptureBaseline = struct {
    logical: Director,
    plan: ?ResidentCapturePlan = null,
    projected: bool = false,
};
pub const ResidentCaptureProjection = struct {
    frame: u64,
    bar: u64,
    mode: ResidentPlaybackMode,
    executed_prefix: u8 = 0,
    target_entry: ?music.PhaseReceipt = null,
    target_entry_bar: ?u64 = null,
};
pub const ResidentImportAnchor = struct {
    request_id: u64,
    position: trace.Position,
    context: u64,
    asset_generation: u64,
    transport_epoch: u64,
    plan_id: u64,
    plan_epoch: u64 = 1,
    frame: u64,
    bar: u64,
};
pub const ResidentImportResult = struct {
    /// Original decoded musical bar, before anchor.bar replaces current_bar.
    /// Envelope validators must compare against this saved fact, not the anchor.
    saved_bar: u64 = 0,
    /// Exact retained target for cross-checking physical route/occurrence data.
    reservation: ?TransitionIntent = null,
    intent: ?TransitionIntent = null,
    suspended: ?SuspendedTargetEntry = null,
    mode: ResidentPlaybackMode = .ready,
};
const ResidentOwnerStamp = struct {
    context: u64,
    asset_generation: u64,
    transport_epoch: u64,
    request_epoch: u64,
    last_request_id: u64,
    last_position: ?trace.Position,
    last_bound_plan_id: u64,
    suspension_nonce: u64,
    committed_state: u32,
    committed_segment: u32,
    paused: bool,
    logical_hash: u64,
};
pub const ResidentImportStaging = struct {
    logical: Director,
    result: ResidentImportResult = .{},
    anchor: ResidentImportAnchor = undefined,
    expected: ResidentOwnerStamp = undefined,
    prepared: bool = false,
};
/// Cross-bank staging is an owned logical copy, never a relabeled snapshot.
/// Only immutable tables/config are rebound to an independently validated bank.
pub const ResidentReloadStaging = struct {
    logical: Director,
    expected: ResidentOwnerStamp = undefined,
    anchor: ResidentImportAnchor = undefined,
    target_build_id: u64 = 0,
    prepared: bool = false,
};
const PreviewSeekOwnerStamp = struct {
    resident: ResidentOwnerStamp,
    other_hash: u64,
};
/// Same-owner, same-bank audition staging. This retains an owned logical copy;
/// it neither imports a snapshot nor reanchors the age of musical history.
pub const PreviewSeekStaging = struct {
    logical: Director,
    owner: *const Director = undefined,
    expected: PreviewSeekOwnerStamp = undefined,
    prepared_stamp: PreviewSeekOwnerStamp = undefined,
    anchor: ResidentImportAnchor = undefined,
    prepared: bool = false,
};
const ResidentReservation = struct {
    from: u64,
    to: u64,
    selector_id: u64,
    segment: u64,
    rule_id: u64,
    priority: u8,
    since_bar: u64,
    eligibility: [4]u64,
    candidate: u32,
    epoch: u64,
    history_revision: u64,
    reset_history: bool,
    fallback: bool,
    provenance: IntentProvenance,
};

pub const Director = struct {
    tables: s.Tables,
    profile: s.Platform,
    bank_build_id: u64,
    seed: u64,
    context: u64,
    asset_generation: u64,
    transport_epoch: u64,
    committed_state: u32,
    committed_segment: u32,
    entered_bar: u64,
    current_bar: u64,
    current_frame: u64,
    last_commit_frame: u64,
    request_epoch: u64 = 1,
    last_position: ?trace.Position = null,
    last_request_id: u64 = 0,
    last_bound_plan_id: u64 = 0,
    last_stop_tick: ?u64 = null,
    last_pause_tick: ?u64 = null,
    desired: ?Desired = null,
    paused: bool = false,
    // Resident-only logical source presence; absent from frozen V1/V2 codecs.
    resident_started: bool = false,
    rule_fallback_used: bool = false,
    parameters: [s.Limits.selection_parameters]ParameterState = @splat(.{}),
    values: [s.Limits.selection_parameters]i32 = @splat(0),
    contexts: [s.Limits.selection_contexts]logic.Value = @splat(.{ .boolean = false }),
    selectors: [s.Limits.selection_selectors]selector.State = @splat(.{}),
    last_left_bar: [s.Limits.selection_states]?u64 = @splat(null),
    pending: [s.Limits.director_pending]Pending = @splat(.{}),
    // Live control identities are deliberately absent from the V1/V2 wire.
    // Restore preserves the nonce high-water but clears acceptance authority.
    suspension_nonce: u64 = 0,
    suspended_target_entry: ?Suspended = null,
    pause_acceptance: ?TransportAcceptance = null,
    resume_acceptance: ?TransportAcceptance = null,
    pub fn init(self: *Director, allocator: std.mem.Allocator, config: Config) Error!void {
        if (config.bank_build_id == 0 or config.context == 0 or config.asset_generation == 0 or config.transport_epoch == 0) return error.InvalidState;
        try bank.selection_validation.validate(allocator, config.tables, config.profile);
        const state = try find(config.tables.states, config.initial_state);
        const segment = try find(config.tables.segments, config.initial_segment);
        self.* = .{ .tables = config.tables, .profile = config.profile, .bank_build_id = config.bank_build_id, .seed = config.seed, .context = config.context, .asset_generation = config.asset_generation, .transport_epoch = config.transport_epoch, .committed_state = state, .committed_segment = segment, .entered_bar = config.initial_bar, .current_bar = config.initial_bar, .current_frame = config.initial_frame, .last_commit_frame = config.initial_frame };
        for (config.tables.parameters, 0..) |p, i| {
            const q = try bank.selection_validation.quantize(p.initial);
            self.parameters[i] = .{ .value = q, .target = q, .start = q, .start_frame = config.initial_frame };
            self.values[i] = q;
        }
        for (config.tables.contexts, 0..) |c, i| self.contexts[i] = switch (c.kind) {
            .boolean => .{ .boolean = c.initial_integer != 0 },
            .integer => .{ .integer = c.initial_integer },
            .scalar => .{ .scalar = try bank.selection_validation.quantize(c.initial_scalar) },
            .id => .{ .id = c.initial_id },
        };
        for (config.tables.selectors, 0..) |v, i| self.selectors[i] = selector.State.init(v);
    }
    fn environment(self: *const Director) logic.Environment {
        return .{ .committed_state = self.committed_state, .parameters = self.values[0..self.tables.parameters.len], .contexts = self.contexts[0..self.tables.contexts.len] };
    }
    fn base(self: *const Director, kind: trace.ScheduleKind) trace.ScheduleRecord {
        var row: trace.ScheduleRecord = .{ .kind = kind, .context = self.context, .transport_epoch = self.transport_epoch, .asset_generation = self.asset_generation, .from_state = self.tables.states[self.committed_state].key.id, .source_segment = self.tables.segments[self.committed_segment].key.id };
        if (self.last_position) |p| {
            row.control_tick = p.control_tick;
            row.input_order = p.input_order;
            row.accepted_control_frame = p.accepted_control_frame;
        }
        return row;
    }
    fn desiredBase(self: *const Director, desired: Desired, kind: trace.ScheduleKind) trace.ScheduleRecord {
        var row = self.base(kind);
        row.request_id = desired.request_id;
        row.control_tick = desired.position.control_tick;
        row.input_order = desired.position.input_order;
        row.accepted_control_frame = desired.position.accepted_control_frame;
        return row;
    }
    pub fn advance(self: *Director, frame: u64, bar: u64) Error!void {
        if (frame < self.current_frame or bar < self.current_bar) return error.InvalidOrder;
        for (self.parameters[0..self.tables.parameters.len], 0..) |*parameter, i| {
            try parameter.advance(frame);
            self.values[i] = parameter.value;
        }
        self.current_frame = frame;
        self.current_bar = bar;
    }
    fn invalidate(self: *Director) Error!void {
        if (self.request_epoch == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
        self.request_epoch += 1;
        for (&self.pending) |*p| if (p.active) {
            p.superseded = true;
        };
    }
    /// Full ReplayInputV2 acceptance position is used. Arrival order is never
    /// canonicalized implicitly: caller must submit canonical tick/order facts.
    /// The batch is preflighted before any mutation. Per-tick capacity is fixed.
    pub fn accept(self: *Director, inputs: []const trace.Input, bar: u64, log: *selector.Trace) Error!void {
        if (inputs.len > s.Limits.director_requests) return error.ResourceLimitExceeded;
        if (bar < self.current_bar) return error.InvalidOrder;
        var previous = self.last_position;
        var request_id = self.last_request_id;
        for (inputs) |input| {
            input.validate() catch return error.InvalidMusicGraph;
            if (previous) |p| if (!trace.before(p, input.position) or input.position.accepted_control_frame < p.accepted_control_frame) return error.InvalidOrder;
            if (input.position.accepted_control_frame < self.current_frame) return error.InvalidOrder;
            if (input.payload != .request) return error.UnsupportedOperation;
            const r = input.payload.request;
            if (r.context != self.context or r.request_id <= request_id) return error.InvalidOrder;
            try self.preflight(r.payload);
            previous = input.position;
            request_id = r.request_id;
        }
        if (inputs.len > std.math.maxInt(u64) - self.request_epoch) return error.ResourceLimitExceeded;
        for (inputs) |input| {
            try self.advance(input.position.accepted_control_frame, bar);
            self.last_position = input.position;
            const r = input.payload.request;
            self.last_request_id = r.request_id;
            self.resume_acceptance = null;
            var row = self.base(.request_accepted);
            row.request_id = r.request_id;
            row.result = .success;
            switch (r.payload) {
                .set_state => |v| {
                    const target = try find(self.tables.states, v.state);
                    if (self.last_stop_tick != null and self.last_stop_tick.? == input.position.control_tick) {
                        row.result = .rejected;
                        row.reason = .lower_priority;
                    } else if (self.desired == null or v.priority >= self.desired.?.priority) {
                        const since = if (self.desired != null and self.desired.?.target == target) self.desired.?.since_bar else bar;
                        try self.invalidate();
                        if (self.suspended_target_entry) |*suspended| suspended.invalidated = true;
                        self.desired = .{ .request_id = r.request_id, .target = target, .priority = v.priority, .position = input.position, .since_bar = since };
                    } else {
                        row.result = .rejected;
                        row.reason = .lower_priority;
                    }
                    row.to_state = v.state;
                    row.candidate_priority = v.priority;
                },
                .set_parameter => |v| {
                    const index = try find(self.tables.parameters, v.parameter);
                    const def = self.tables.parameters[index];
                    var p = &self.parameters[index];
                    const q = std.math.clamp(v.value_q16, try bank.selection_validation.quantize(def.minimum), try bank.selection_validation.quantize(def.maximum));
                    p.start = p.value;
                    p.target = q;
                    p.start_frame = input.position.accepted_control_frame;
                    p.duration = if (q >= p.value) def.attack_frames else def.release_frames;
                    try p.advance(p.start_frame);
                    self.values[index] = p.value;
                    row.value_q16 = q;
                },
                .context_boolean => |v| self.contexts[try find(self.tables.contexts, v.key)] = .{ .boolean = v.value },
                .context_integer => |v| self.contexts[try find(self.tables.contexts, v.key)] = .{ .integer = v.value },
                .context_scalar => |v| self.contexts[try find(self.tables.contexts, v.key)] = .{ .scalar = v.value_q16 },
                .context_id => |v| self.contexts[try find(self.tables.contexts, v.key)] = .{ .id = v.value },
                .pause => {
                    self.last_pause_tick = input.position.control_tick;
                    self.paused = true;
                    try self.invalidate();
                    self.pause_acceptance = .{ .request_id = r.request_id, .position = input.position, .request_epoch = self.request_epoch };
                },
                .@"resume" => {
                    if (self.last_pause_tick != null and self.last_pause_tick.? == input.position.control_tick) {
                        row.result = .rejected;
                        row.reason = .lower_priority;
                    } else {
                        self.paused = false;
                        self.resume_acceptance = .{ .request_id = r.request_id, .position = input.position, .request_epoch = self.request_epoch };
                    }
                },
                .stop_boundary, .stop_emergency => {
                    self.last_stop_tick = input.position.control_tick;
                    self.desired = null;
                    try self.invalidate();
                    if (self.suspended_target_entry) |*suspended| suspended.invalidated = true;
                },
                else => unreachable,
            }
            log.emit(row);
        }
    }
    fn preflight(self: *const Director, payload: trace.RequestPayload) Error!void {
        switch (payload) {
            .set_state => |v| {
                _ = try find(self.tables.states, v.state);
            },
            .set_parameter => |v| {
                _ = try find(self.tables.parameters, v.parameter);
            },
            .context_boolean => |v| try self.contextType(v.key, .boolean),
            .context_integer => |v| try self.contextType(v.key, .integer),
            .context_scalar => |v| try self.contextType(v.key, .scalar),
            .context_id => |v| try self.contextType(v.key, .id),
            .pause, .@"resume", .stop_boundary, .stop_emergency => {},
            else => return error.UnsupportedOperation,
        }
    }
    fn contextType(self: *const Director, id: u64, kind: s.ContextKind) Error!void {
        if (self.tables.contexts[try find(self.tables.contexts, id)].kind != kind) return error.InvalidMusicGraph;
    }
    /// Hysteresis is continuous desired-target dwell. Hold starts at actual
    /// source entry; cooldown starts at actual target exit. All are musical bars.
    pub fn resolve(self: *Director, frame: u64, bar: u64, log: *selector.Trace) Error!?TransitionIntent {
        try self.advance(frame, bar);
        const desired = self.desired orelse return null;
        if (self.paused or self.suspended_target_entry != null) return null;
        if (desired.target == self.committed_state) {
            // An unopposed no-op is complete after tick arbitration. A bound
            // superseded target can still really execute, so keep the latest
            // desire until that receipt resolves and correct it if necessary.
            var conflicting_bound = false;
            for (self.pending) |pending| if (pending.active and pending.token != null and pending.target_state != desired.target) {
                conflicting_bound = true;
                break;
            };
            if (!conflicting_bound) self.desired = null;
            return null;
        }
        for (self.pending) |p| if (p.active and !p.superseded and p.intent.request_epoch == self.request_epoch) return null;
        var free: ?usize = null;
        for (self.pending, 0..) |p, i| if (!p.active) {
            free = i;
            break;
        };
        if (free == null) return error.ResourceLimitExceeded;
        const target = self.tables.states[desired.target];
        const current = self.tables.states[self.committed_state];
        var reason: trace.Reason = .none;
        if (bar - self.entered_bar < current.minimum_hold_bars) reason = .minimum_hold else if (self.last_left_bar[desired.target]) |left| {
            if (bar - left < target.cooldown_bars) reason = .cooldown;
        }
        if (reason == .none and bar - desired.since_bar < target.hysteresis_bars) reason = .hysteresis;
        if (reason != .none) {
            var row = self.desiredBase(desired, .rejected);
            row.request_id = desired.request_id;
            row.to_state = target.key.id;
            row.reason = reason;
            row.result = .deferred;
            log.emit(row);
            return null;
        }
        var winner: ?usize = null;
        for (self.tables.transitions, 0..) |rule, i| {
            if (rule.from != self.committed_state or rule.to != desired.target) continue;
            var rejection: trace.Reason = .none;
            if (bar - self.entered_bar < rule.minimum_hold_bars) rejection = .minimum_hold else if (!try logic.evaluateAdmitted(self.tables, rule.condition, self.environment())) rejection = .condition_false;
            var row = self.desiredBase(desired, .rule_candidate);
            row.request_id = desired.request_id;
            row.rule_id = rule.key.id;
            row.to_state = target.key.id;
            row.candidate_priority = rule.priority;
            row.candidate_specificity = rule.specificity;
            row.authored_order = rule.authored_order;
            row.reason = rejection;
            row.result = if (rejection == .none) .none else .rejected;
            log.emit(row);
            if (rejection == .none and (winner == null or better(rule, self.tables.transitions[winner.?]))) winner = i;
        }
        const selected = winner orelse {
            var row = self.desiredBase(desired, .rejected);
            row.request_id = desired.request_id;
            row.to_state = target.key.id;
            row.reason = .transition_not_found;
            row.result = .rejected;
            log.emit(row);
            return error.TransitionNotFound;
        };
        const rule = self.tables.transitions[selected];
        // Every eligible losing rule receives an explicit tie-break rejection.
        for (self.tables.transitions, 0..) |other, i| {
            if (i == selected or other.from != self.committed_state or other.to != desired.target or bar - self.entered_bar < other.minimum_hold_bars) continue;
            if (!try logic.evaluateAdmitted(self.tables, other.condition, self.environment())) continue;
            var row = self.desiredBase(desired, .rule_candidate);
            row.request_id = desired.request_id;
            row.rule_id = other.key.id;
            row.to_state = target.key.id;
            row.reason = .lower_priority;
            row.result = .rejected;
            row.candidate_priority = other.priority;
            row.candidate_specificity = other.specificity;
            row.authored_order = other.authored_order;
            log.emit(row);
        }
        log.base = self.desiredBase(desired, .selector_choice);
        log.base.request_id = desired.request_id;
        log.base.rule_id = rule.key.id;
        log.base.to_state = target.key.id;
        const eligibility = try self.residentEligibility(rule.selector);
        const choice = try selector.choose(self.tables, self.profile, rule.selector, &self.selectors[rule.selector], self.seed, self.environment(), log);
        const intent: TransitionIntent = .{ .request_id = desired.request_id, .from = current.key.id, .to = target.key.id, .selector = self.tables.selectors[rule.selector].key.id, .resolved_segment = self.tables.segments[choice.segment].key.id, .priority = desired.priority, .rule_id = rule.key.id, .request_epoch = self.request_epoch, .selector_epoch = choice.epoch };
        self.pending[free.?] = .{ .active = true, .intent = intent, .selector_index = rule.selector, .target_state = desired.target, .choice = choice, .accepted_frame = desired.position.accepted_control_frame, .resident_eligibility = eligibility };
        return intent;
    }
    /// First audible entry uses the authored state's real selector. It has no
    /// source transition rule, but follows the same pending-token/receipt ledger.
    /// The runtime may call this only before any group has executed.
    pub fn resolveStart(self: *Director, frame: u64, log: *selector.Trace) Error!?TransitionIntent {
        try self.advance(frame, self.current_bar);
        const desired = self.desired orelse return null;
        if (self.paused or self.suspended_target_entry != null) return null;
        for (self.pending) |p| if (p.active and !p.superseded and p.intent.request_epoch == self.request_epoch) return null;
        const free = for (self.pending, 0..) |p, i| {
            if (!p.active) break i;
        } else return error.ResourceLimitExceeded;
        const target = self.tables.states[desired.target];
        log.base = self.desiredBase(desired, .selector_choice);
        log.base.to_state = target.key.id;
        const eligibility = try self.residentEligibility(target.selector);
        const choice = try selector.choose(self.tables, self.profile, target.selector, &self.selectors[target.selector], self.seed, self.environment(), log);
        const intent: TransitionIntent = .{ .request_id = desired.request_id, .from = self.tables.states[self.committed_state].key.id, .to = target.key.id, .selector = self.tables.selectors[target.selector].key.id, .resolved_segment = self.tables.segments[choice.segment].key.id, .priority = desired.priority, .rule_id = 0, .request_epoch = self.request_epoch, .selector_epoch = choice.epoch };
        self.pending[free] = .{ .active = true, .intent = intent, .selector_index = target.selector, .target_state = desired.target, .choice = choice, .accepted_frame = desired.position.accepted_control_frame, .resident_eligibility = eligibility };
        return intent;
    }

    /// Explicit rule-level fallback replaces exactly one current unbound
    /// selector choice. It keeps the requested target STATE, uses the authored
    /// fallback SEGMENT, and consumes a fresh attempt without committing history.
    pub fn authorizeRuleFallback(self: *Director, original: TransitionIntent, log: *selector.Trace) Error!TransitionIntent {
        if (self.paused or self.desired == null or original.request_epoch != self.request_epoch) return error.InvalidState;
        const desired = self.desired.?;
        for (&self.pending) |*pending| if (pending.active and std.meta.eql(pending.intent, original)) {
            if (pending.superseded or pending.token != null or pending.provenance != .selector or desired.request_id != original.request_id or desired.target != pending.target_state or desired.priority != original.priority or pending.accepted_frame != desired.position.accepted_control_frame or original.from != self.tables.states[self.committed_state].key.id) return error.InvalidState;
            const rule = self.tables.transitions[try find(self.tables.transitions, original.rule_id)];
            if (rule.fallback != .segment or rule.fallback_segment >= self.tables.segments.len or rule.from != self.committed_state or rule.to != pending.target_state or rule.selector != pending.selector_index or rule.fallback_segment == pending.choice.segment) return error.InvalidState;
            const state = &self.selectors[pending.selector_index];
            if (state.epoch == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
            const epoch = state.epoch + 1;
            var replacement = original;
            replacement.selector_epoch = epoch;
            replacement.resolved_segment = self.tables.segments[rule.fallback_segment].key.id;
            // No fallible work remains. Trace is observational, even if disabled.
            state.epoch = epoch;
            pending.intent = replacement;
            pending.choice = .{ .segment = rule.fallback_segment, .candidate = s.none, .epoch = epoch, .history_revision = state.revision, .reset_history = false, .fallback = true };
            pending.provenance = .rule_fallback;
            self.rule_fallback_used = true;
            var row = self.desiredBase(desired, .selector_choice);
            row.rule_id = original.rule_id;
            row.selector_id = original.selector;
            row.selector_epoch = epoch;
            row.target_segment = replacement.resolved_segment;
            row.to_state = replacement.to;
            row.result = .success;
            row.reason = .rule_fallback;
            log.emit(row);
            return replacement;
        };
        return error.InvalidState;
    }
    pub fn intentProvenance(self: *const Director, intent: TransitionIntent) Error!IntentProvenance {
        for (self.pending) |pending| if (pending.active and std.meta.eql(pending.intent, intent)) return pending.provenance;
        return error.InvalidState;
    }
    /// Planner binds precisely its target-entry phase. Fill phases must never
    /// bind here. Rebinding, reused tokens, stale intent/generation are rejected.
    pub fn bindTargetEntry(self: *Director, intent: TransitionIntent, token: music.PhaseToken) Error!void {
        const index = try self.targetEntrySlot(intent, token);
        self.pending[index].token = token;
        self.last_bound_plan_id = token.plan_id.value();
    }
    /// Read-only preflight for a serialized Control publication. The caller must
    /// not mutate this Director between validation and the actual binding.
    pub fn validateTargetEntry(self: *const Director, intent: TransitionIntent, token: music.PhaseToken) Error!void {
        _ = try self.targetEntrySlot(intent, token);
    }
    fn targetEntrySlot(self: *const Director, intent: TransitionIntent, token: music.PhaseToken) Error!usize {
        try token.validate();
        if (token.context.value() != self.context or token.transport_epoch.value() != self.transport_epoch or token.asset_generation.value() != self.asset_generation) return error.StaleAssetGeneration;
        if (self.last_bound_plan_id == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
        if (token.plan_id.value() <= self.last_bound_plan_id) return error.InvalidState;
        for (self.pending) |p| if (p.active and p.token != null and std.meta.eql(p.token.?, token)) return error.InvalidState;
        for (self.pending, 0..) |p, index| if (p.active and std.meta.eql(p.intent, intent)) {
            if (p.token != null or p.superseded) return error.InvalidState;
            return index;
        };
        return error.InvalidState;
    }
    /// Stronger owner policy than the low-level scheduler: each target-entry
    /// binding needs a fresh PlanId, even if a previous plan had a new epoch.
    pub fn nextPlanIdFloor(self: *const Director) Error!music.PlanId {
        if (self.last_bound_plan_id == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
        return @enumFromInt(self.last_bound_plan_id + 1);
    }
    pub fn isCurrent(self: *const Director, intent: TransitionIntent) bool {
        if (intent.request_epoch != self.request_epoch) return false;
        for (self.pending) |pending| if (pending.active and !pending.superseded and std.meta.eql(pending.intent, intent)) return true;
        return false;
    }
    /// Unpublished/unbound intents may be abandoned. Published phases require
    /// their real receipt; invalidation alone is never a cancellation claim.
    pub fn abandonPrepared(self: *Director, intent: TransitionIntent) Error!void {
        for (&self.pending) |*p| if (p.active and std.meta.eql(p.intent, intent)) {
            if (p.token != null) return error.InvalidState;
            p.active = false;
            return;
        };
        return error.InvalidState;
    }
    /// Retain only an actually cancelled target entry after its accepted pause.
    /// The old bound pending identity is consumed here, not on pause intent.
    /// This neither selects again nor commits any selector history.
    pub fn suspendTargetEntry(self: *Director, receipt: music.PhaseReceipt) Error!SuspendedTargetEntry {
        try receipt.token.validate();
        if (receipt.token.context.value() != self.context or receipt.token.asset_generation.value() != self.asset_generation) return error.StaleAssetGeneration;
        if (receipt.outcome != .cancelled or !self.paused or self.suspended_target_entry != null) return error.InvalidState;
        const pause = self.pause_acceptance orelse return error.InvalidState;
        const desired = self.desired;
        if (pause.request_epoch != self.request_epoch) return error.InvalidState;
        if (receipt.effective_frame < pause.position.accepted_control_frame or receipt.effective_frame > self.current_frame) return error.InvalidOrder;
        if (self.suspension_nonce == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
        for (&self.pending) |*pending| if (pending.active and pending.token != null and std.meta.eql(pending.token.?, receipt.token)) {
            if (!pending.superseded or pending.intent.request_epoch != self.request_epoch - 1 or pause.request_id <= pending.intent.request_id or pending.intent.from != self.tables.states[self.committed_state].key.id) return error.InvalidState;
            if (desired) |value| if (value.request_id != pending.intent.request_id or value.target != pending.target_state or value.priority != pending.intent.priority or value.position.accepted_control_frame != pending.accepted_frame) return error.InvalidState;
            const state = self.selectors[pending.selector_index];
            if (state.epoch != pending.choice.epoch or state.revision != pending.choice.history_revision) return error.InvalidState;
            const handle: SuspendedTargetEntry = .{ .identity = .{ self.context, self.asset_generation, self.bank_build_id, self.suspension_nonce + 1 } };
            self.suspended_target_entry = .{ .handle = handle, .pending = pending.*, .desired = desired, .committed_state = self.committed_state, .committed_segment = self.committed_segment, .request_epoch = self.request_epoch, .transport_epoch = self.transport_epoch, .pause = pause };
            self.suspension_nonce += 1;
            pending.active = false;
            return handle;
        };
        return error.InvalidState;
    }
    /// Anchor the retained suffix to an actual pause's newer transport epoch.
    /// The same accepted pause may first be anchored after its cancellation;
    /// later accepted pauses can interrupt an in-flight resume without redrawing.
    /// A strictly newer pause may retain the same transport epoch only when the
    /// caller has confirmed that cancellation kept the physical group paused;
    /// this unchanged-group case does not claim another execution receipt.
    pub fn refreshSuspendedPause(self: *Director, handle: SuspendedTargetEntry) Error!void {
        const suspended = if (self.suspended_target_entry) |*value| value else return error.InvalidState;
        if (!std.meta.eql(handle, suspended.handle)) return error.InvalidState;
        if (handle.identity[0] != self.context or handle.identity[1] != self.asset_generation or handle.identity[2] != self.bank_build_id) return error.StaleAssetGeneration;
        if (!self.paused or suspended.invalidated or self.transport_epoch < suspended.transport_epoch or self.committed_state != suspended.committed_state or self.committed_segment != suspended.committed_segment or !std.meta.eql(self.desired, suspended.desired)) return error.InvalidState;
        const pause = self.pause_acceptance orelse return error.InvalidState;
        if (pause.request_id != self.last_request_id or pause.request_epoch != self.request_epoch or self.last_position == null or !std.meta.eql(pause.position, self.last_position.?)) return error.InvalidState;
        const origin = suspended.restore_origin orelse suspended.pause;
        if (suspended.restore_origin == null and std.meta.eql(pause, origin)) {
            if (self.transport_epoch == suspended.transport_epoch) return error.InvalidState;
        } else if (pause.request_id <= origin.request_id or pause.request_epoch <= suspended.request_epoch or !trace.before(origin.position, pause.position)) return error.InvalidState;
        const state = self.selectors[suspended.pending.selector_index];
        if (state.epoch != suspended.pending.choice.epoch or state.revision != suspended.pending.choice.history_revision) return error.InvalidState;
        suspended.pause = pause;
        suspended.restore_origin = null;
        suspended.request_epoch = self.request_epoch;
        suspended.transport_epoch = self.transport_epoch;
    }
    /// The runtime calls this only after its actual resume receipt has applied a
    /// new transport epoch. The public resume ticket is already terminal; this
    /// fresh unbound intent owns only the remaining automatic target suffix.
    pub fn resumeTargetEntry(self: *Director, handle: SuspendedTargetEntry, request_id: u64) Error!TransitionIntent {
        const suspended = self.suspended_target_entry orelse return error.InvalidState;
        if (!std.meta.eql(handle, suspended.handle)) return error.InvalidState;
        if (handle.identity[0] != self.context or handle.identity[1] != self.asset_generation or handle.identity[2] != self.bank_build_id) return error.StaleAssetGeneration;
        if (self.paused or suspended.invalidated or self.request_epoch != suspended.request_epoch or self.transport_epoch <= suspended.transport_epoch or self.committed_state != suspended.committed_state or self.committed_segment != suspended.committed_segment) return error.InvalidState;
        const accepted = self.resume_acceptance orelse return error.InvalidState;
        const origin = suspended.restore_origin orelse suspended.pause;
        if (accepted.request_id != request_id or request_id != self.last_request_id or request_id <= origin.request_id or accepted.request_epoch != suspended.request_epoch or self.last_position == null or !std.meta.eql(accepted.position, self.last_position.?) or !trace.before(origin.position, accepted.position)) return error.InvalidState;
        if (!std.meta.eql(self.desired, suspended.desired)) return error.InvalidState;
        const state = self.selectors[suspended.pending.selector_index];
        if (state.epoch != suspended.pending.choice.epoch or state.revision != suspended.pending.choice.history_revision) return error.InvalidState;
        const free = for (self.pending, 0..) |pending, index| {
            if (!pending.active) break index;
        } else return error.ResourceLimitExceeded;
        var pending = suspended.pending;
        pending.active = true;
        pending.intent.request_id = request_id;
        pending.intent.request_epoch = self.request_epoch;
        pending.token = null;
        pending.superseded = false;
        pending.accepted_frame = accepted.position.accepted_control_frame;
        const desired: Desired = .{ .request_id = request_id, .target = pending.target_state, .priority = pending.intent.priority, .position = accepted.position, .since_bar = if (suspended.desired) |value| value.since_bar else self.current_bar };
        // No fallible work remains: consume the handle only with its replacement.
        self.pending[free] = pending;
        self.desired = desired;
        self.suspended_target_entry = null;
        self.resume_acceptance = null;
        return pending.intent;
    }
    /// Disposal releases no selector history and never resurrects the old token.
    /// A matching handle may be discarded even after its context became stale.
    pub fn discardSuspendedTargetEntry(self: *Director, handle: SuspendedTargetEntry) Error!void {
        const suspended = self.suspended_target_entry orelse return error.InvalidState;
        if (!std.meta.eql(handle, suspended.handle)) return error.InvalidState;
        if (self.desired) |desired| if (desired.request_id == suspended.pending.intent.request_id) {
            self.desired = null;
        };
        self.suspended_target_entry = null;
    }
    pub fn targetEntryReceipt(self: *Director, receipt: music.PhaseReceipt, entry_bar: u64) Error!void {
        try receipt.token.validate();
        for (&self.pending) |*p| if (p.active and p.token != null and std.meta.eql(p.token.?, receipt.token)) {
            if (receipt.outcome == .executed) {
                if (receipt.effective_frame < self.last_commit_frame or receipt.effective_frame < p.accepted_frame or receipt.effective_frame > self.current_frame or entry_bar < self.entered_bar or entry_bar > self.current_bar) return error.InvalidOrder;
                if (self.request_epoch == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
                if (p.provenance == .rule_fallback) {
                    try selector.commitRuleFallback(self.tables, p.selector_index, &self.selectors[p.selector_index], p.choice, try find(self.tables.transitions, p.intent.rule_id), .rule_fallback);
                } else try selector.commit(self.tables, p.selector_index, &self.selectors[p.selector_index], p.choice);
                try self.invalidate();
                self.last_left_bar[self.committed_state] = entry_bar;
                self.resident_started = true;
                self.committed_state = p.target_state;
                self.committed_segment = p.choice.segment;
                self.entered_bar = entry_bar;
                self.last_commit_frame = receipt.effective_frame;
                if (self.desired != null and self.desired.?.request_id == p.intent.request_id) self.desired = null;
            }
            p.active = false;
            return;
        };
        return error.InvalidState;
    }

    /// Converts pickup (-1) and loop-local bar ordinals to a checked monotonic
    /// transport count. Clock validation proves loop endpoints are bar lines.
    pub fn barAtClock(clock: clock_module.Clock, frame: u64) Error!u64 {
        const position = clock.position(frame) catch return error.InvalidTempo;
        const pickup: i128 = @intFromBool(clock.map.tempo.pickup_ticks > 0);
        var serial: i128 = @as(i128, position.bar) + pickup;
        if (position.loop_epoch != 0) {
            const start_frame = clock.map.frameAtTick(clock.map.tempo.loop_start_tick) catch return error.InvalidTempo;
            const end_frame = clock.map.frameAtTick(clock.map.tempo.loop_end_tick) catch return error.InvalidTempo;
            const start = clock.map.positionAtFrame(start_frame) catch return error.InvalidTempo;
            const end = clock.map.positionAtFrame(end_frame) catch return error.InvalidTempo;
            const bars: i128 = @as(i128, end.bar) - start.bar;
            if (bars <= 0) return error.InvalidTempo;
            serial += @as(i128, position.loop_epoch) * bars;
        }
        if (serial < 0 or serial > std.math.maxInt(u64)) return error.ResourceLimitExceeded;
        return @intCast(serial);
    }
    pub fn acceptAtClock(self: *Director, input: trace.Input, clock: clock_module.Clock, log: *selector.Trace) Error!void {
        try self.accept((&input)[0..1], try barAtClock(clock, input.position.accepted_control_frame), log);
    }
    pub fn resolveAtClock(self: *Director, frame: u64, clock: clock_module.Clock, log: *selector.Trace) Error!?TransitionIntent {
        return self.resolve(frame, try barAtClock(clock, frame), log);
    }
    pub fn targetEntryReceiptAtClock(self: *Director, receipt: music.PhaseReceipt, clock: clock_module.Clock) Error!void {
        return self.targetEntryReceipt(receipt, try barAtClock(clock, receipt.effective_frame));
    }
    pub fn capture(self: *const Director, out: *DirectorSelectorSnapshotV1) Error!void {
        if (self.rule_fallback_used) return error.UnsupportedCapability;
        return self.captureVersion(out, snapshot_version);
    }
    pub fn captureV2(self: *const Director, out: *DirectorSelectorSnapshotV2) Error!void {
        return self.captureVersion(out, snapshot_v2_version);
    }
    fn captureVersion(self: *const Director, out: anytype, comptime version: u16) Error!void {
        if (self.suspended_target_entry != null) return error.UnsupportedCapability;
        out.version = version;
        out.length = 0;
        @memset(&out.payload, 0);
        var e: recording.codec.Encoder = .{ .bytes = &out.payload };
        try put(&e, @as(u64, 0x3150414e53454d53));
        try put(&e, version);
        try put(&e, selector.algorithm_version);
        try put(&e, self.bank_build_id);
        try put(&e, self.seed);
        try put(&e, self.context);
        try put(&e, self.asset_generation);
        try put(&e, self.transport_epoch);
        try put(&e, self.tables.states[self.committed_state].key.id);
        try put(&e, self.tables.segments[self.committed_segment].key.id);
        try put(&e, self.entered_bar);
        try put(&e, self.current_bar);
        try put(&e, self.current_frame);
        try put(&e, self.last_commit_frame);
        try put(&e, self.request_epoch);
        try put(&e, self.last_position);
        try put(&e, self.last_request_id);
        try put(&e, self.last_bound_plan_id);
        try put(&e, self.last_stop_tick);
        try put(&e, self.last_pause_tick);
        try put(&e, self.paused);
        if (version >= 2) try put(&e, self.rule_fallback_used);
        try put(&e, self.desired != null);
        if (self.desired) |desired| {
            try put(&e, desired.request_id);
            try put(&e, self.tables.states[desired.target].key.id);
            try put(&e, desired.priority);
            try put(&e, desired.position);
            try put(&e, desired.since_bar);
        }
        try put(&e, @as(u16, @intCast(self.tables.parameters.len)));
        for (self.tables.parameters, 0..) |p, i| {
            try put(&e, p.key.id);
            try put(&e, self.parameters[i]);
        }
        try put(&e, @as(u16, @intCast(self.tables.contexts.len)));
        for (self.tables.contexts, 0..) |c, i| {
            try put(&e, c.key.id);
            try put(&e, self.contexts[i]);
        }
        try put(&e, @as(u16, @intCast(self.tables.states.len)));
        for (self.tables.states, 0..) |state, i| {
            try put(&e, state.key.id);
            try put(&e, self.last_left_bar[i]);
        }
        try put(&e, @as(u16, @intCast(self.tables.selectors.len)));
        for (self.selectors[0..self.tables.selectors.len]) |state| {
            try put(&e, state.stable_id);
            try put(&e, state.kind);
            try put(&e, state.capacity);
            try put(&e, state.epoch);
            const payload_length: u16 = 8 + 2 + @as(u16, state.history_len) * 8 + @as(u16, if (state.kind == .sequence) 4 else 0);
            try put(&e, payload_length);
            try put(&e, state.revision);
            if (state.kind == .sequence) try put(&e, state.sequence_cursor);
            try put(&e, state.history_len);
            for (state.history[0..state.history_len]) |id| try put(&e, id);
        }
        try put(&e, @as(u16, @intCast(self.pendingCount())));
        for (self.pending) |p| if (p.active) {
            try put(&e, p.intent);
            try put(&e, self.tables.selectors[p.selector_index].key.id);
            try put(&e, self.tables.states[p.target_state].key.id);
            try put(&e, self.tables.segments[p.choice.segment].key.id);
            try put(&e, p.choice.candidate);
            try put(&e, p.choice.epoch);
            try put(&e, p.choice.history_revision);
            try put(&e, p.choice.reset_history);
            try put(&e, p.choice.fallback);
            if (version >= 2) try put(&e, p.provenance);
            try put(&e, if (p.token) |token| @as(?TokenRecord, TokenRecord.from(token)) else @as(?TokenRecord, null));
            try put(&e, p.superseded);
            try put(&e, p.accepted_frame);
        };
        out.length = @intCast(e.offset);
    }
    /// Atomic restore through bounded heap staging. No pointer or bank index is
    /// decoded. Different builds require a TASK-016 migration map and explicitly
    /// fail here rather than guessing index/kind/capacity conversions.
    pub fn restore(self: *Director, allocator: std.mem.Allocator, snapshot: *const DirectorSelectorSnapshotV1) Error!void {
        if (self.rule_fallback_used) return error.UnsupportedCapability;
        return self.restoreVersion(allocator, snapshot, snapshot_version);
    }
    pub fn restoreV2(self: *Director, allocator: std.mem.Allocator, snapshot: *const DirectorSelectorSnapshotV2) Error!void {
        return self.restoreVersion(allocator, snapshot, snapshot_v2_version);
    }
    fn restoreVersion(self: *Director, allocator: std.mem.Allocator, snapshot: anytype, comptime version: u16) Error!void {
        if (self.suspended_target_entry != null) return error.UnsupportedCapability;
        if (snapshot.version != version) return error.UnsupportedCapability;
        if (snapshot.length == 0 or snapshot.length > snapshot_capacity) return error.InvalidMusicGraph;
        // A maximum-density history may resolve8192 IDs against65536 segments.
        // Build one bounded heap lookup instead of quadratic repeated scans.
        const segment_lookup = try allocator.alloc(IdIndex, self.tables.segments.len);
        defer allocator.free(segment_lookup);
        for (self.tables.segments, 0..) |segment, index| segment_lookup[index] = .{ .id = segment.key.id, .index = @intCast(index) };
        std.mem.sort(IdIndex, segment_lookup, {}, IdIndex.less);
        const tmp = try allocator.create(Director);
        defer allocator.destroy(tmp);
        tmp.* = self.*;
        tmp.pause_acceptance = null;
        tmp.resume_acceptance = null;
        var d: recording.codec.Decoder = .{ .bytes = snapshot.payload[0..snapshot.length] };
        if (try get(&d, u64) != 0x3150414e53454d53) return error.InvalidMusicGraph;
        if (try get(&d, u16) != version or try get(&d, u16) != selector.algorithm_version) return error.UnsupportedCapability;
        if (try get(&d, u64) != self.bank_build_id) return error.UnsupportedCapability;
        tmp.seed = try get(&d, u64);
        if (try get(&d, u64) != self.context or try get(&d, u64) != self.asset_generation or try get(&d, u64) != self.transport_epoch) return error.InvalidState;
        tmp.committed_state = try find(self.tables.states, try get(&d, u64));
        tmp.committed_segment = try lookup(segment_lookup, try get(&d, u64));
        tmp.entered_bar = try get(&d, u64);
        tmp.current_bar = try get(&d, u64);
        tmp.current_frame = try get(&d, u64);
        tmp.last_commit_frame = try get(&d, u64);
        tmp.request_epoch = try get(&d, u64);
        tmp.last_position = try get(&d, ?trace.Position);
        tmp.last_request_id = try get(&d, u64);
        const saved_plan_high_water = try get(&d, u64);
        // Restoring older musical state in the same owner cannot recycle an
        // identity that might still arrive as an old terminal receipt.
        tmp.last_bound_plan_id = @max(self.last_bound_plan_id, saved_plan_high_water);
        tmp.last_stop_tick = try get(&d, ?u64);
        tmp.last_pause_tick = try get(&d, ?u64);
        tmp.paused = try get(&d, bool);
        tmp.rule_fallback_used = if (version >= 2) try get(&d, bool) else false;
        if (self.rule_fallback_used and !tmp.rule_fallback_used) return error.InvalidState;
        if (tmp.entered_bar > tmp.current_bar or tmp.last_commit_frame > tmp.current_frame or tmp.request_epoch == 0) return error.InvalidMusicGraph;
        if ((tmp.last_position == null) != (tmp.last_request_id == 0)) return error.InvalidMusicGraph;
        if (tmp.last_position) |position| if (position.accepted_control_frame > tmp.current_frame) return error.InvalidMusicGraph;
        for ([_]?u64{ tmp.last_stop_tick, tmp.last_pause_tick }) |tick| if (tick) |value| {
            if (tmp.last_position == null or value > tmp.last_position.?.control_tick) return error.InvalidMusicGraph;
        };
        if (!tmp.paused and tmp.last_pause_tick != null and tmp.last_position != null and tmp.last_pause_tick.? == tmp.last_position.?.control_tick) return error.InvalidMusicGraph;
        tmp.desired = null;
        if (try get(&d, bool)) {
            tmp.desired = .{ .request_id = try get(&d, u64), .target = try find(self.tables.states, try get(&d, u64)), .priority = try get(&d, u8), .position = try get(&d, trace.Position), .since_bar = try get(&d, u64) };
            const desired = tmp.desired.?;
            const last = tmp.last_position orelse return error.InvalidMusicGraph;
            if (tmp.last_stop_tick != null and tmp.last_stop_tick.? == last.control_tick) return error.InvalidMusicGraph;
            if ((!trace.before(desired.position, last) and !std.meta.eql(desired.position, last)) or desired.position.accepted_control_frame > last.accepted_control_frame or ((desired.request_id == tmp.last_request_id) != std.meta.eql(desired.position, last))) return error.InvalidMusicGraph;
            if (desired.request_id == 0 or desired.request_id > tmp.last_request_id or desired.since_bar > tmp.current_bar or desired.position.accepted_control_frame > tmp.current_frame) return error.InvalidMusicGraph;
        }
        if (try get(&d, u16) != self.tables.parameters.len) return error.UnsupportedCapability;
        var seen_parameters: [s.Limits.selection_parameters]bool = @splat(false);
        for (self.tables.parameters) |_| {
            const index = try find(self.tables.parameters, try get(&d, u64));
            if (seen_parameters[index]) return error.InvalidMusicGraph;
            seen_parameters[index] = true;
            const state = try get(&d, ParameterState);
            const def = self.tables.parameters[index];
            const lo = try bank.selection_validation.quantize(def.minimum);
            const hi = try bank.selection_validation.quantize(def.maximum);
            if (state.value < lo or state.value > hi or state.target < lo or state.target > hi or state.start < lo or state.start > hi or state.start_frame > tmp.current_frame) return error.InvalidMusicGraph;
            if ((state.target > state.start and state.duration != def.attack_frames) or (state.target < state.start and state.duration != def.release_frames) or (state.target == state.start and state.duration != 0 and state.duration != def.attack_frames)) return error.InvalidMusicGraph;
            var expected = state;
            try expected.advance(tmp.current_frame);
            if (expected.value != state.value) return error.InvalidMusicGraph;
            tmp.parameters[index] = state;
            tmp.values[index] = state.value;
        }
        if (try get(&d, u16) != self.tables.contexts.len) return error.UnsupportedCapability;
        var seen_contexts: [s.Limits.selection_contexts]bool = @splat(false);
        for (self.tables.contexts) |_| {
            const index = try find(self.tables.contexts, try get(&d, u64));
            if (seen_contexts[index]) return error.InvalidMusicGraph;
            seen_contexts[index] = true;
            const value = try get(&d, logic.Value);
            if (std.meta.activeTag(value) != bank.selection_validation.contextKind(self.tables.contexts[index].kind) or (value == .id and value.id == 0)) return error.InvalidMusicGraph;
            tmp.contexts[index] = value;
        }
        if (try get(&d, u16) != self.tables.states.len) return error.UnsupportedCapability;
        var seen_states: [s.Limits.selection_states]bool = @splat(false);
        for (self.tables.states) |_| {
            const index = try find(self.tables.states, try get(&d, u64));
            if (seen_states[index]) return error.InvalidMusicGraph;
            seen_states[index] = true;
            const left = try get(&d, ?u64);
            if (left != null and left.? > tmp.current_bar) return error.InvalidMusicGraph;
            tmp.last_left_bar[index] = left;
        }
        if (try get(&d, u16) != self.tables.selectors.len) return error.UnsupportedCapability;
        var seen_selectors: [s.Limits.selection_selectors]bool = @splat(false);
        for (self.tables.selectors) |_| {
            const index = try find(self.tables.selectors, try get(&d, u64));
            if (seen_selectors[index]) return error.InvalidMusicGraph;
            seen_selectors[index] = true;
            const raw_kind = try get(&d, u8);
            const kind = std.enums.fromInt(s.SelectorKind, raw_kind) orelse return error.UnsupportedCapability;
            const capacity = try get(&d, u16);
            const def = self.tables.selectors[index];
            if (kind != def.kind or capacity != def.history_capacity) return error.UnsupportedCapability;
            var state = selector.State.init(def);
            state.epoch = try get(&d, u64);
            const payload_length = try get(&d, u16);
            const start = d.offset;
            if (payload_length > d.bytes.len - start) return error.InvalidMusicGraph;
            state.revision = try get(&d, u64);
            if (state.revision > state.epoch) return error.InvalidMusicGraph;
            if (kind == .sequence) {
                state.sequence_cursor = try get(&d, u32);
                if (state.sequence_cursor > def.candidates.count) return error.InvalidMusicGraph;
            }
            state.history_len = try get(&d, u16);
            if (state.history_len > capacity or state.history_len > s.Limits.selector_history or state.history_len > state.revision or (state.sequence_cursor != 0 and state.revision == 0)) return error.InvalidMusicGraph;
            for (state.history[0..state.history_len], 0..) |*id, i| {
                id.* = try get(&d, u64);
                const segment = try lookup(segment_lookup, id.*);
                var member = kind != .shuffle and def.exhaustion == .fallback and def.fallback_segment == segment;
                for (try bank.selection_validation.items(s.Candidate, self.tables.candidates, def.candidates)) |candidate| if (candidate.segment == segment) {
                    member = true;
                };
                if (!member and kind != .shuffle and tmp.rule_fallback_used) for (self.tables.transitions) |rule| {
                    if (rule.selector == index and rule.fallback == .segment and rule.fallback_segment == segment) member = true;
                };
                if (!member) return error.InvalidMusicGraph;
                if (kind == .shuffle) for (state.history[0..i]) |prior| if (prior == id.*) return error.InvalidMusicGraph;
            }
            if (d.offset - start != payload_length) return error.InvalidMusicGraph;
            if (self.rule_fallback_used and (state.epoch < self.selectors[index].epoch or state.revision < self.selectors[index].revision)) return error.InvalidState;
            tmp.selectors[index] = state;
        }
        if (tmp.rule_fallback_used) {
            var possible = false;
            for (self.tables.transitions) |rule| if (rule.fallback == .segment and rule.selector < self.tables.selectors.len and rule.fallback_segment < self.tables.segments.len and tmp.selectors[rule.selector].epoch >= 2) {
                const definition = self.tables.selectors[rule.selector];
                for (try bank.selection_validation.items(s.Candidate, self.tables.candidates, definition.candidates)) |candidate| if (candidate.segment != rule.fallback_segment) {
                    possible = true;
                };
                if (definition.exhaustion == .fallback and definition.fallback_segment != rule.fallback_segment) possible = true;
            };
            if (!possible) return error.InvalidMusicGraph;
        }
        const pending_count = try get(&d, u16);
        if (pending_count > s.Limits.director_pending) return error.InvalidMusicGraph;
        for (&tmp.pending) |*p| p.* = .{};
        for (tmp.pending[0..pending_count], 0..) |*p, i| {
            p.active = true;
            p.intent = try get(&d, TransitionIntent);
            p.selector_index = try find(self.tables.selectors, try get(&d, u64));
            p.target_state = try find(self.tables.states, try get(&d, u64));
            p.choice = .{ .segment = try lookup(segment_lookup, try get(&d, u64)), .candidate = try get(&d, u32), .epoch = try get(&d, u64), .history_revision = try get(&d, u64), .reset_history = try get(&d, bool), .fallback = try get(&d, bool) };
            p.provenance = if (version >= 2) try get(&d, IntentProvenance) else .selector;
            p.token = if (try get(&d, ?TokenRecord)) |token| token.value() else null;
            p.superseded = try get(&d, bool);
            p.accepted_frame = try get(&d, u64);
            if (p.accepted_frame > tmp.current_frame) return error.InvalidMusicGraph;
            const def = self.tables.selectors[p.selector_index];
            if (p.choice.history_revision >= p.choice.epoch or (p.choice.reset_history and (p.choice.history_revision == 0 or p.choice.fallback or def.exhaustion != .reset or (def.kind != .sequence and def.kind != .shuffle and def.kind != .no_repeat and def.kind != .history)))) return error.InvalidMusicGraph;
            if (tmp.last_position == null or p.accepted_frame > tmp.last_position.?.accepted_control_frame) return error.InvalidMusicGraph;
            if (p.intent.request_id == 0 or p.intent.request_id > tmp.last_request_id or p.intent.request_epoch == 0 or p.intent.request_epoch > tmp.request_epoch or p.intent.selector_epoch != p.choice.epoch or p.choice.epoch == 0 or p.choice.epoch > tmp.selectors[p.selector_index].epoch or p.choice.history_revision > tmp.selectors[p.selector_index].revision or p.intent.selector != def.key.id or p.intent.to != self.tables.states[p.target_state].key.id or p.intent.resolved_segment != self.tables.segments[p.choice.segment].key.id or (!p.superseded and p.intent.request_epoch != tmp.request_epoch)) return error.InvalidMusicGraph;
            const from_index = try find(self.tables.states, p.intent.from);
            const rule_index = try find(self.tables.transitions, p.intent.rule_id);
            const rule = self.tables.transitions[rule_index];
            if (rule.from != from_index or rule.to != p.target_state or rule.selector != p.selector_index) return error.InvalidMusicGraph;
            // A superseded phase can retain a historical source, but cannot
            // borrow the identity of a different currently desired request.
            if (tmp.desired) |desired| if (p.intent.request_id == desired.request_id and (p.target_state != desired.target or p.intent.priority != desired.priority or p.accepted_frame != desired.position.accepted_control_frame)) return error.InvalidMusicGraph;
            if (!p.superseded and (tmp.paused or tmp.desired == null or tmp.desired.?.request_id != p.intent.request_id or tmp.desired.?.target != p.target_state or from_index != tmp.committed_state or p.target_state == tmp.committed_state or p.intent.priority != tmp.desired.?.priority or p.accepted_frame != tmp.desired.?.position.accepted_control_frame)) return error.InvalidMusicGraph;
            if (p.provenance == .rule_fallback) {
                if (!tmp.rule_fallback_used or rule.fallback != .segment or rule.fallback_segment != p.choice.segment or !p.choice.fallback or p.choice.reset_history or p.choice.candidate != s.none or p.choice.epoch < 2) return error.InvalidMusicGraph;
            } else if (p.choice.fallback) {
                if (def.exhaustion != .fallback or def.fallback_segment != p.choice.segment or p.choice.candidate != s.none) return error.InvalidMusicGraph;
            } else {
                const pool = try bank.selection_validation.items(s.Candidate, self.tables.candidates, def.candidates);
                if (p.choice.candidate >= pool.len or pool[p.choice.candidate].segment != p.choice.segment) return error.InvalidMusicGraph;
            }
            if (p.provenance == .rule_fallback and self.rule_fallback_used and p.choice.epoch <= self.selectors[p.selector_index].epoch) {
                var still_active = false;
                for (self.pending) |current| if (current.active and current.provenance == .rule_fallback and std.meta.eql(current.intent, p.intent) and std.meta.eql(current.choice, p.choice) and std.meta.eql(current.token, p.token) and current.accepted_frame == p.accepted_frame) {
                    still_active = true;
                    break;
                };
                if (!still_active) return error.InvalidState;
            }
            if (p.token) |token| {
                token.validate() catch return error.InvalidMusicGraph;
                if (token.plan_id.value() > saved_plan_high_water) return error.InvalidMusicGraph;
                if (token.plan_id.value() <= self.last_bound_plan_id) {
                    var still_outstanding = false;
                    for (self.pending) |current| if (current.active and current.token != null and std.meta.eql(current.token.?, token) and std.meta.eql(current.intent, p.intent) and std.meta.eql(current.choice, p.choice) and current.accepted_frame == p.accepted_frame and current.provenance == p.provenance) {
                        still_outstanding = true;
                        break;
                    };
                    if (!still_outstanding) return error.InvalidState;
                }
                if (token.context.value() != self.context or token.asset_generation.value() != self.asset_generation or token.transport_epoch.value() != self.transport_epoch) return error.InvalidMusicGraph;
            }
            for (tmp.pending[0..i]) |prior| if (prior.intent.request_epoch == p.intent.request_epoch or (prior.selector_index == p.selector_index and prior.choice.epoch == p.choice.epoch) or (p.token != null and prior.token != null and std.meta.eql(prior.token.?, p.token.?))) return error.InvalidMusicGraph;
        }
        for (tmp.selectors[0..self.tables.selectors.len], 0..) |state, index| {
            var outstanding: u64 = 0;
            for (tmp.pending[0..pending_count]) |pending| if (pending.selector_index == index) {
                outstanding += 1;
            };
            if (outstanding > state.epoch - state.revision) return error.InvalidMusicGraph;
        }
        d.finish() catch return error.InvalidMusicGraph;
        self.* = tmp.*;
    }
    fn residentStamp(self: *const Director) ResidentOwnerStamp {
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, self.seed);
        std.hash.autoHash(&hash, self.resident_started);
        std.hash.autoHash(&hash, self.rule_fallback_used);
        std.hash.autoHash(&hash, self.entered_bar);
        std.hash.autoHash(&hash, self.desired);
        for (self.selectors[0..self.tables.selectors.len]) |*state| std.hash.autoHash(&hash, state.*);
        for (self.parameters[0..self.tables.parameters.len]) |*state| std.hash.autoHash(&hash, state.*);
        for (self.contexts[0..self.tables.contexts.len]) |*value| std.hash.autoHash(&hash, value.*);
        for (self.last_left_bar[0..self.tables.states.len]) |bar| std.hash.autoHash(&hash, bar);
        for (self.pending) |p| {
            std.hash.autoHash(&hash, p.active);
            if (p.active) std.hash.autoHash(&hash, p);
        }
        std.hash.autoHash(&hash, self.suspended_target_entry != null);
        if (self.suspended_target_entry) |*suspended| {
            std.hash.autoHash(&hash, suspended.transport_epoch);
            std.hash.autoHash(&hash, suspended.request_epoch);
            std.hash.autoHash(&hash, suspended.handle);
            std.hash.autoHash(&hash, suspended.invalidated);
            std.hash.autoHash(&hash, suspended.pending);
            std.hash.autoHash(&hash, suspended.restore_origin orelse suspended.pause);
        }
        return .{ .context = self.context, .asset_generation = self.asset_generation, .transport_epoch = self.transport_epoch, .request_epoch = self.request_epoch, .last_request_id = self.last_request_id, .last_position = self.last_position, .last_bound_plan_id = self.last_bound_plan_id, .suspension_nonce = self.suspension_nonce, .committed_state = self.committed_state, .committed_segment = self.committed_segment, .paused = self.paused, .logical_hash = hash.final() };
    }
    fn residentMode(self: *const Director) ResidentPlaybackMode {
        return if (!self.resident_started) .ready else if (self.paused) .paused else .playing;
    }
    fn residentPending(self: *const Director) Error!?Pending {
        var result: ?Pending = null;
        for (self.pending) |p| if (p.active) {
            if (result != null or p.superseded or p.intent.request_epoch != self.request_epoch or self.paused) return error.UnsupportedCapability;
            result = p;
        };
        if (self.suspended_target_entry) |suspended| {
            if (result != null or suspended.invalidated or !self.paused or suspended.committed_state != self.committed_state or suspended.committed_segment != self.committed_segment or suspended.request_epoch != self.request_epoch) return error.UnsupportedCapability;
            result = suspended.pending;
        }
        return result;
    }
    fn residentEligibility(self: *const Director, index: u32) Error!ResidentEligibility {
        const def = self.tables.selectors[index];
        const pool = try bank.selection_validation.items(s.Candidate, self.tables.candidates, def.candidates);
        if (pool.len > s.Limits.selector_candidates) return error.ResourceLimitExceeded;
        var result: ResidentEligibility = .{ .valid = true };
        for (pool, 0..) |candidate, i| {
            const weighted = def.kind == .weighted_random or def.kind == .no_repeat;
            if (try logic.evaluateAdmitted(self.tables, candidate.condition, self.environment()) and (!weighted or candidate.weight != 0)) result.bits[i / 64] |= @as(u64, 1) << @intCast(i % 64);
        }
        return result;
    }
    fn residentHistoryExcludes(def: s.Selector, state: *const selector.State, candidate: usize, id: u64) bool {
        if (def.kind == .sequence) return candidate < state.sequence_cursor;
        const window: usize = switch (def.kind) {
            .shuffle => state.history_len,
            .no_repeat, .history => @min(state.history_len, def.no_repeat_window),
            else => return false,
        };
        for (state.history[state.history_len - window .. state.history_len]) |previous| if (previous == id) return true;
        return false;
    }
    fn validateResidentEligibility(self: *const Director, p: Pending) Error!void {
        const facts = &p.resident_eligibility;
        // Frozen V1/V2 never carried these observations. Their playback and
        // restore remain unchanged, but such pending values cannot be exported
        // through this separately bounded resident format without new facts.
        if (!facts.valid) return error.UnsupportedCapability;
        const def = self.tables.selectors[p.selector_index];
        const state = &self.selectors[p.selector_index];
        if (state.history_len > state.capacity or state.history_len > s.Limits.selector_history) return error.InvalidMusicGraph;
        const pool = try bank.selection_validation.items(s.Candidate, self.tables.candidates, def.candidates);
        if (pool.len > s.Limits.selector_candidates) return error.InvalidMusicGraph;
        for (pool.len..s.Limits.selector_candidates) |i| if (facts.contains(i)) return error.InvalidMusicGraph;
        var unreset_count: usize = 0;
        for (pool, 0..) |candidate, i| {
            const observed = facts.contains(i);
            const zero_weight = (def.kind == .weighted_random or def.kind == .no_repeat) and candidate.weight == 0;
            if ((zero_weight and observed) or (!zero_weight and candidate.condition == s.none and !observed)) return error.InvalidMusicGraph;
            if (observed and !residentHistoryExcludes(def, state, i, self.tables.segments[candidate.segment].key.id)) unreset_count += 1;
        }
        // An authored rule fallback deliberately bypasses selector eligibility;
        // its independent explicit provenance is checked below by the commit API.
        if (p.provenance == .rule_fallback) return;
        if (p.choice.fallback) {
            if (unreset_count != 0) return error.InvalidMusicGraph;
        } else {
            if (p.choice.candidate >= pool.len or !facts.contains(p.choice.candidate)) return error.InvalidMusicGraph;
            if (p.choice.reset_history) {
                if (unreset_count != 0) return error.InvalidMusicGraph;
            } else if (residentHistoryExcludes(def, state, p.choice.candidate, self.tables.segments[p.choice.segment].key.id)) return error.InvalidMusicGraph;
        }
    }
    fn validateResidentChoice(self: *const Director, p: Pending) Error!void {
        if (p.selector_index >= self.tables.selectors.len or p.target_state >= self.tables.states.len or p.choice.segment >= self.tables.segments.len) return error.InvalidMusicGraph;
        const def = self.tables.selectors[p.selector_index];
        const state = &self.selectors[p.selector_index];
        if (p.intent.from != self.tables.states[self.committed_state].key.id or p.intent.to != self.tables.states[p.target_state].key.id or p.intent.selector != def.key.id or p.intent.resolved_segment != self.tables.segments[p.choice.segment].key.id or p.intent.selector_epoch != p.choice.epoch or p.choice.epoch == 0 or p.choice.epoch != state.epoch or p.choice.history_revision != state.revision or state.revision >= state.epoch) return error.InvalidMusicGraph;
        if (p.choice.reset_history and (p.choice.history_revision == 0 or p.choice.fallback or def.exhaustion != .reset or (def.kind != .sequence and def.kind != .shuffle and def.kind != .no_repeat and def.kind != .history))) return error.InvalidMusicGraph;
        if (p.intent.rule_id == 0) {
            if (self.resident_started or p.provenance != .selector or self.tables.states[p.target_state].selector != p.selector_index) return error.InvalidMusicGraph;
        } else {
            const rule = self.tables.transitions[try find(self.tables.transitions, p.intent.rule_id)];
            if (rule.from != self.committed_state or rule.to != p.target_state or rule.selector != p.selector_index) return error.InvalidMusicGraph;
        }
        try self.validateResidentEligibility(p);
        // Commit against a small scratch selector proves exact candidate/fallback
        // membership without consuming the retained attempt or history.
        var state_copy = state.*;
        if (p.provenance == .rule_fallback) {
            if (!self.rule_fallback_used or p.intent.rule_id == 0) return error.InvalidMusicGraph;
            try selector.commitRuleFallback(self.tables, p.selector_index, &state_copy, p.choice, try find(self.tables.transitions, p.intent.rule_id), .rule_fallback);
        } else try selector.commit(self.tables, p.selector_index, &state_copy, p.choice);
    }
    fn validateResidentLogical(self: *const Director) Error!void {
        if (self.tables.states.len > s.Limits.selection_states or self.tables.parameters.len > s.Limits.selection_parameters or self.tables.contexts.len > s.Limits.selection_contexts or self.tables.selectors.len > s.Limits.selection_selectors or self.committed_state >= self.tables.states.len or self.committed_segment >= self.tables.segments.len or self.entered_bar > self.current_bar) return error.InvalidMusicGraph;
        if (!self.resident_started and self.paused) return error.UnsupportedCapability;
        for (self.tables.parameters, 0..) |def, i| {
            const p = self.parameters[i];
            if (p.value != p.target) return error.UnsupportedCapability;
            if (p.value != self.values[i] or p.value < try bank.selection_validation.quantize(def.minimum) or p.value > try bank.selection_validation.quantize(def.maximum)) return error.InvalidMusicGraph;
        }
        for (self.tables.contexts, 0..) |def, i| {
            const value = self.contexts[i];
            if (std.meta.activeTag(value) != bank.selection_validation.contextKind(def.kind) or (value == .id and value.id == 0)) return error.InvalidMusicGraph;
        }
        for (self.last_left_bar[0..self.tables.states.len]) |bar| if (bar != null and bar.? > self.current_bar) return error.InvalidMusicGraph;
        for (self.tables.selectors, 0..) |def, i| {
            const state = &self.selectors[i];
            if (state.stable_id != def.key.id or state.kind != def.kind or state.capacity != def.history_capacity or state.capacity > s.Limits.selector_history or state.history_len > state.capacity or state.history_len > state.revision or state.revision > state.epoch or state.sequence_cursor > def.candidates.count or (state.kind != .sequence and state.sequence_cursor != 0) or (state.revision == 0 and state.sequence_cursor != 0)) return error.InvalidMusicGraph;
            const pool = try bank.selection_validation.items(s.Candidate, self.tables.candidates, def.candidates);
            for (state.history[0..state.history_len], 0..) |id, h| {
                var member = false;
                for (pool) |candidate| if (self.tables.segments[candidate.segment].key.id == id) {
                    member = true;
                };
                if (state.kind != .shuffle) {
                    if (def.exhaustion == .fallback and def.fallback_segment < self.tables.segments.len and self.tables.segments[def.fallback_segment].key.id == id) member = true;
                    if (self.rule_fallback_used) for (self.tables.transitions) |rule| {
                        if (rule.selector == i and rule.fallback == .segment and rule.fallback_segment < self.tables.segments.len and self.tables.segments[rule.fallback_segment].key.id == id) member = true;
                    };
                }
                if (!member) return error.InvalidMusicGraph;
                if (state.kind == .shuffle) for (state.history[0..h]) |previous| if (previous == id) return error.InvalidMusicGraph;
            }
        }
        if (self.rule_fallback_used) {
            var possible = false;
            for (self.tables.transitions) |rule| {
                if (rule.fallback == .segment and rule.selector < self.tables.selectors.len and rule.fallback_segment < self.tables.segments.len and self.selectors[rule.selector].epoch >= 2) {
                    const def = self.tables.selectors[rule.selector];
                    for (try bank.selection_validation.items(s.Candidate, self.tables.candidates, def.candidates)) |candidate| if (candidate.segment != rule.fallback_segment) {
                        possible = true;
                    };
                    if (def.exhaustion == .fallback and def.fallback_segment != rule.fallback_segment) possible = true;
                }
            }
            if (!possible) return error.InvalidMusicGraph;
        }
        const pending = try self.residentPending();
        if (pending) |p| {
            try self.validateResidentChoice(p);
            if (self.desired) |desired| {
                if (desired.target != p.target_state or desired.priority != p.intent.priority or desired.since_bar > self.current_bar) return error.InvalidMusicGraph;
            } else if (self.suspended_target_entry == null) return error.InvalidMusicGraph;
        } else if (self.desired != null) return error.UnsupportedCapability;
    }
    /// Clone before publishing the ordered gate. Never reconstruct a baseline
    /// from the live Director after collecting potentially later receipts.
    pub fn beginResidentCapture(self: *const Director, out: *ResidentCaptureBaseline, plan: ?ResidentCapturePlan) Error!void {
        try self.validateResidentLogical();
        if (plan) |value| {
            try value.target_token.validate();
            if (value.phase_count == 0 or value.phase_count > 3 or value.target_phase_index != value.phase_count - 1 or value.baseline_executed_prefix > value.phase_count) return error.InvalidMusicGraph;
            if (value.baseline_executed_prefix <= value.target_phase_index) {
                const p = (try self.residentPending()) orelse return error.InvalidState;
                if (p.token == null or !std.meta.eql(p.token.?, value.target_token) or self.suspended_target_entry != null) return error.InvalidState;
            }
        }
        out.logical = self.*;
        out.plan = plan;
        out.projected = false;
    }
    /// Prefix membership comes from the acquired Render fence, not from a frame
    /// comparison. Same-frame target/fence ties therefore remain unambiguous.
    pub fn projectResidentCapture(baseline: *ResidentCaptureBaseline, fact: ResidentCaptureProjection) Error!void {
        if (baseline.projected) return error.InvalidState;
        const d = &baseline.logical;
        if (fact.frame < d.current_frame or fact.bar < d.current_bar) return error.InvalidOrder;
        var commit = false;
        if (baseline.plan) |plan| {
            if (fact.executed_prefix < plan.baseline_executed_prefix or fact.executed_prefix > plan.phase_count) return error.InvalidMusicGraph;
            commit = plan.baseline_executed_prefix <= plan.target_phase_index and fact.executed_prefix > plan.target_phase_index;
            if (commit) {
                const receipt = fact.target_entry orelse return error.InvalidMusicGraph;
                const entry_bar = fact.target_entry_bar orelse return error.InvalidMusicGraph;
                const p = (try d.residentPending()) orelse return error.InvalidState;
                if (receipt.outcome != .executed or !std.meta.eql(receipt.token, plan.target_token) or receipt.effective_frame > fact.frame or receipt.effective_frame < d.last_commit_frame or receipt.effective_frame < p.accepted_frame or entry_bar > fact.bar or entry_bar < d.entered_bar or fact.mode == .ready) return error.InvalidMusicGraph;
                if (d.request_epoch == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
                try d.validateResidentChoice(p);
            }
        } else if (fact.executed_prefix != 0) return error.InvalidMusicGraph;
        if (!commit and (fact.target_entry != null or fact.target_entry_bar != null)) return error.InvalidMusicGraph;
        if (fact.mode == .paused and d.suspended_target_entry == null and try d.residentPending() != null) return error.UnsupportedCapability;
        try d.advance(fact.frame, fact.bar);
        if (commit) try d.targetEntryReceipt(fact.target_entry.?, fact.target_entry_bar.?);
        d.resident_started = fact.mode != .ready;
        d.paused = fact.mode == .paused;
        baseline.projected = true;
    }
    /// Independent canonical format; V1/V2 captureVersion is deliberately not
    /// reused because it contains historical live authority and no suspension.
    pub fn exportResident(self: *const Director, out: *DirectorResidentSnapshotV1) Error!void {
        try self.validateResidentLogical();
        const reservation = try self.residentPending();
        out.version = resident_snapshot_version;
        out.length = 0;
        @memset(&out.payload, 0);
        var e: recording.codec.Encoder = .{ .bytes = &out.payload };
        try put(&e, @as(u64, 0x31524453454d53));
        try put(&e, resident_snapshot_version);
        try put(&e, selector.algorithm_version);
        try put(&e, self.bank_build_id);
        try put(&e, self.seed);
        try put(&e, self.residentMode());
        try put(&e, self.tables.states[self.committed_state].key.id);
        try put(&e, self.tables.segments[self.committed_segment].key.id);
        try put(&e, self.entered_bar);
        try put(&e, self.current_bar);
        try put(&e, self.rule_fallback_used);
        try put(&e, @as(u16, @intCast(self.tables.parameters.len)));
        for (self.tables.parameters, 0..) |def, i| {
            try put(&e, def.key.id);
            try put(&e, self.values[i]);
        }
        try put(&e, @as(u16, @intCast(self.tables.contexts.len)));
        for (self.tables.contexts, 0..) |def, i| {
            try put(&e, def.key.id);
            try put(&e, self.contexts[i]);
        }
        try put(&e, @as(u16, @intCast(self.tables.states.len)));
        for (self.tables.states, 0..) |def, i| {
            try put(&e, def.key.id);
            try put(&e, self.last_left_bar[i]);
        }
        try put(&e, @as(u16, @intCast(self.tables.selectors.len)));
        for (self.selectors[0..self.tables.selectors.len]) |*state| {
            try put(&e, state.stable_id);
            try put(&e, state.kind);
            try put(&e, state.capacity);
            try put(&e, state.epoch);
            try put(&e, state.revision);
            try put(&e, state.sequence_cursor);
            try put(&e, state.history_len);
            for (state.history[0..state.history_len]) |id| try put(&e, id);
        }
        try put(&e, reservation != null);
        if (reservation) |p| {
            const desired = if (self.suspended_target_entry) |suspended| suspended.desired else self.desired;
            try put(&e, ResidentReservation{ .from = p.intent.from, .to = p.intent.to, .selector_id = p.intent.selector, .segment = p.intent.resolved_segment, .rule_id = p.intent.rule_id, .priority = p.intent.priority, .since_bar = if (desired) |v| v.since_bar else self.current_bar, .eligibility = p.resident_eligibility.bits, .candidate = p.choice.candidate, .epoch = p.choice.epoch, .history_revision = p.choice.history_revision, .reset_history = p.choice.reset_history, .fallback = p.choice.fallback, .provenance = p.provenance });
        }
        out.length = @intCast(e.offset);
    }
    fn validateResidentAnchor(self: *const Director, anchor: ResidentImportAnchor) Error!void {
        if (anchor.context != self.context or anchor.asset_generation != self.asset_generation) return error.StaleAssetGeneration;
        if (anchor.plan_epoch == 0) return error.InvalidState;
        if (anchor.transport_epoch <= self.transport_epoch or anchor.plan_id <= self.last_bound_plan_id or anchor.request_id <= self.last_request_id or anchor.position.accepted_control_frame > anchor.frame or anchor.frame < self.current_frame) return error.InvalidOrder;
        if (self.last_position) |previous| if (!trace.before(previous, anchor.position) or anchor.position.accepted_control_frame < previous.accepted_control_frame) return error.InvalidOrder;
        if (self.request_epoch == std.math.maxInt(u64) or self.suspension_nonce == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
    }
    /// Decode into caller-owned heap staging. Failure may dirty staging but never
    /// changes the live Director or consumes an ingress ID/selector attempt.
    pub fn stageResidentImport(self: *const Director, snapshot: *const DirectorResidentSnapshotV1, anchor: ResidentImportAnchor, staged: *ResidentImportStaging) Error!void {
        staged.prepared = false;
        if (snapshot.version != resident_snapshot_version) return error.UnsupportedCapability;
        if (snapshot.length == 0 or snapshot.length > snapshot_capacity) return error.InvalidMusicGraph;
        try self.validateResidentAnchor(anchor);
        const tmp = &staged.logical;
        tmp.* = self.*;
        tmp.pending = @splat(.{});
        tmp.desired = null;
        tmp.suspended_target_entry = null;
        tmp.pause_acceptance = null;
        tmp.resume_acceptance = null;
        tmp.last_stop_tick = null;
        tmp.last_pause_tick = null;
        tmp.request_epoch = self.request_epoch + 1;
        tmp.context = anchor.context;
        tmp.asset_generation = anchor.asset_generation;
        tmp.transport_epoch = anchor.transport_epoch;
        tmp.last_position = anchor.position;
        tmp.last_request_id = anchor.request_id;
        tmp.current_frame = anchor.frame;
        tmp.last_commit_frame = anchor.frame;
        var decoder: recording.codec.Decoder = .{ .bytes = snapshot.payload[0..snapshot.length] };
        const d = &decoder;
        if (try get(d, u64) != 0x31524453454d53) return error.InvalidMusicGraph;
        if (try get(d, u16) != resident_snapshot_version or try get(d, u16) != selector.algorithm_version or try get(d, u64) != self.bank_build_id) return error.UnsupportedCapability;
        tmp.seed = try get(d, u64);
        const mode = try get(d, ResidentPlaybackMode);
        tmp.resident_started = mode != .ready;
        tmp.paused = mode == .paused;
        tmp.committed_state = try find(self.tables.states, try get(d, u64));
        tmp.committed_segment = try find(self.tables.segments, try get(d, u64));
        tmp.entered_bar = try get(d, u64);
        tmp.current_bar = try get(d, u64);
        const saved_bar = tmp.current_bar;
        tmp.rule_fallback_used = try get(d, bool);
        if (try get(d, u16) != self.tables.parameters.len) return error.UnsupportedCapability;
        var seen_parameters: [s.Limits.selection_parameters]bool = @splat(false);
        for (self.tables.parameters) |_| {
            const i = try find(self.tables.parameters, try get(d, u64));
            if (seen_parameters[i]) return error.InvalidMusicGraph;
            seen_parameters[i] = true;
            const value = try get(d, i32);
            tmp.parameters[i] = .{ .value = value, .start = value, .target = value, .start_frame = anchor.frame };
            tmp.values[i] = value;
        }
        if (try get(d, u16) != self.tables.contexts.len) return error.UnsupportedCapability;
        var seen_contexts: [s.Limits.selection_contexts]bool = @splat(false);
        for (self.tables.contexts) |_| {
            const i = try find(self.tables.contexts, try get(d, u64));
            if (seen_contexts[i]) return error.InvalidMusicGraph;
            seen_contexts[i] = true;
            tmp.contexts[i] = try get(d, logic.Value);
        }
        if (try get(d, u16) != self.tables.states.len) return error.UnsupportedCapability;
        var seen_states: [s.Limits.selection_states]bool = @splat(false);
        for (self.tables.states) |_| {
            const i = try find(self.tables.states, try get(d, u64));
            if (seen_states[i]) return error.InvalidMusicGraph;
            seen_states[i] = true;
            tmp.last_left_bar[i] = try get(d, ?u64);
        }
        if (try get(d, u16) != self.tables.selectors.len) return error.UnsupportedCapability;
        var seen_selectors: [s.Limits.selection_selectors]bool = @splat(false);
        for (self.tables.selectors) |_| {
            const i = try find(self.tables.selectors, try get(d, u64));
            if (seen_selectors[i]) return error.InvalidMusicGraph;
            seen_selectors[i] = true;
            const state = &tmp.selectors[i];
            state.* = selector.State.init(self.tables.selectors[i]);
            state.kind = try get(d, s.SelectorKind);
            state.capacity = try get(d, u16);
            state.epoch = try get(d, u64);
            state.revision = try get(d, u64);
            state.sequence_cursor = try get(d, u32);
            state.history_len = try get(d, u16);
            if (state.history_len > s.Limits.selector_history or state.history_len > state.capacity) return error.InvalidMusicGraph;
            for (state.history[0..state.history_len]) |*id| id.* = try get(d, u64);
        }
        staged.result = .{ .mode = mode, .saved_bar = saved_bar };
        if (try get(d, bool)) {
            // Import consumes one private request epoch. Its inevitable target
            // receipt needs one more, including after a paused restore/resume.
            if (tmp.request_epoch == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
            if (mode == .paused and (anchor.transport_epoch == std.math.maxInt(u64) or anchor.plan_id == std.math.maxInt(u64) or anchor.request_id == std.math.maxInt(u64))) return error.ResourceLimitExceeded;
            const value = try get(d, ResidentReservation);
            if (value.since_bar > saved_bar) return error.InvalidMusicGraph;
            var p: Pending = .{ .active = true, .selector_index = try find(self.tables.selectors, value.selector_id), .target_state = try find(self.tables.states, value.to), .provenance = value.provenance, .accepted_frame = anchor.position.accepted_control_frame, .intent = .{ .request_id = anchor.request_id, .from = value.from, .to = value.to, .selector = value.selector_id, .resolved_segment = value.segment, .priority = value.priority, .rule_id = value.rule_id, .request_epoch = tmp.request_epoch, .selector_epoch = value.epoch }, .choice = .{ .segment = try find(self.tables.segments, value.segment), .candidate = value.candidate, .epoch = value.epoch, .history_revision = value.history_revision, .reset_history = value.reset_history, .fallback = value.fallback }, .resident_eligibility = .{ .bits = value.eligibility, .valid = true } };
            try tmp.validateResidentChoice(p);
            staged.result.reservation = p.intent;
            const desired: Desired = .{ .request_id = anchor.request_id, .target = p.target_state, .priority = value.priority, .position = anchor.position, .since_bar = try reanchorResidentBar(value.since_bar, saved_bar, anchor.bar) };
            tmp.desired = desired;
            if (mode == .paused) {
                tmp.suspension_nonce += 1;
                const handle: SuspendedTargetEntry = .{ .identity = .{ self.context, self.asset_generation, self.bank_build_id, tmp.suspension_nonce } };
                p.active = false;
                tmp.suspended_target_entry = .{ .handle = handle, .pending = p, .desired = desired, .committed_state = tmp.committed_state, .committed_segment = tmp.committed_segment, .request_epoch = tmp.request_epoch, .transport_epoch = tmp.transport_epoch, .pause = undefined, .restore_origin = .{ .request_id = anchor.request_id, .position = anchor.position, .request_epoch = tmp.request_epoch } };
                staged.result.suspended = handle;
            } else {
                tmp.pending[0] = p;
                staged.result.intent = p.intent;
            }
        }
        d.finish() catch return error.InvalidMusicGraph;
        tmp.entered_bar = try reanchorResidentBar(tmp.entered_bar, saved_bar, anchor.bar);
        for (tmp.last_left_bar[0..self.tables.states.len]) |*bar| if (bar.*) |value| {
            bar.* = try reanchorResidentBar(value, saved_bar, anchor.bar);
        };
        tmp.current_bar = anchor.bar;
        try tmp.validateResidentLogical();
        staged.expected = self.residentStamp();
        staged.anchor = anchor;
        staged.prepared = true;
    }
    /// Called again immediately before publication and after the actual install
    /// receipt. While published, the runtime queues ordinary ingress and retires
    /// old receipts without applying their logical commits. Unrelated advancing
    /// observations are allowed; later ingress,
    /// selector commits, plan bindings and suspension changes invalidate staging.
    pub fn validateResidentImport(self: *const Director, staged: *const ResidentImportStaging, anchor: ResidentImportAnchor) Error!void {
        if (!staged.prepared or !std.meta.eql(staged.anchor, anchor) or !std.meta.eql(staged.expected, self.residentStamp())) return error.InvalidState;
        const tmp = &staged.logical;
        if (tmp.tables.states.ptr != self.tables.states.ptr or tmp.tables.segments.ptr != self.tables.segments.ptr or tmp.bank_build_id != self.bank_build_id or tmp.context != anchor.context or tmp.asset_generation != anchor.asset_generation or tmp.transport_epoch != anchor.transport_epoch or tmp.last_request_id != anchor.request_id or tmp.request_epoch != self.request_epoch + 1 or tmp.current_frame != anchor.frame or tmp.current_bar != anchor.bar or tmp.last_position == null or !std.meta.eql(tmp.last_position.?, anchor.position)) return error.InvalidState;
        try tmp.validateResidentLogical();
        if (tmp.residentMode() != staged.result.mode) return error.InvalidState;
        if (try tmp.residentPending()) |p| {
            if (staged.result.reservation == null or !std.meta.eql(staged.result.reservation.?, p.intent)) return error.InvalidState;
            if (tmp.request_epoch == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
            if (staged.result.mode == .paused) {
                if (staged.result.intent != null or staged.result.suspended == null or tmp.suspended_target_entry == null or !std.meta.eql(staged.result.suspended.?, tmp.suspended_target_entry.?.handle) or tmp.suspended_target_entry.?.restore_origin == null) return error.InvalidState;
            } else if (staged.result.suspended != null or staged.result.intent == null or !std.meta.eql(staged.result.intent.?, p.intent)) return error.InvalidState;
            if (p.token) |token| {
                try token.validate();
                if (token.context.value() != anchor.context or token.asset_generation.value() != anchor.asset_generation or token.transport_epoch.value() != anchor.transport_epoch or token.plan_id.value() != anchor.plan_id or token.plan_epoch.value() != anchor.plan_epoch or token.phase_id.value() <= 1 or tmp.last_bound_plan_id != anchor.plan_id) return error.InvalidState;
            } else if (tmp.last_bound_plan_id != self.last_bound_plan_id) return error.InvalidState;
        } else if (tmp.last_bound_plan_id != self.last_bound_plan_id or staged.result.reservation != null or staged.result.intent != null or staged.result.suspended != null) return error.InvalidState;
    }
    /// The caller invokes this only for the exact executed atomic-restore
    /// receipt. Preparation never installs a fake pause acceptance or old token.
    pub fn importResident(self: *Director, staged: *ResidentImportStaging, anchor: ResidentImportAnchor, receipt: music.PhaseReceipt) Error!ResidentImportResult {
        try self.validateResidentImport(staged, anchor);
        try receipt.token.validate();
        if (receipt.outcome != .executed or receipt.effective_frame != anchor.frame or receipt.token.context.value() != anchor.context or receipt.token.asset_generation.value() != anchor.asset_generation or receipt.token.transport_epoch.value() != anchor.transport_epoch or receipt.token.plan_id.value() != anchor.plan_id or receipt.token.plan_epoch.value() != anchor.plan_epoch or receipt.token.phase_id.value() != 1) return error.InvalidState;
        const observed_frame = self.current_frame;
        self.* = staged.logical;
        self.current_frame = @max(observed_frame, anchor.frame);
        self.last_bound_plan_id = anchor.plan_id;
        staged.prepared = false;
        return staged.result;
    }

    /// Narrow first reload profile: the logical/clock/routing catalogs and
    /// selector algorithms/order are exactly unchanged. Only resident media and
    /// its independently validated import/quality reports may differ.
    pub fn validateResidentReloadTopology(self: *const Director, target: *const Director) Error!void {
        inline for (std.meta.fields(s.Tables)) |field| {
            if (comptime !std.mem.eql(u8, field.name, "blob") and !std.mem.eql(u8, field.name, "sounds") and !std.mem.eql(u8, field.name, "import_reports") and !std.mem.eql(u8, field.name, "quality_reports")) {
                const old = @field(self.tables, field.name);
                const fresh = @field(target.tables, field.name);
                if (old.len != fresh.len) return error.UnsupportedCapability;
                for (old, fresh) |a, b| if (!std.meta.eql(a, b)) return error.UnsupportedCapability;
            }
        }
        if (self.tables.sounds.len != target.tables.sounds.len or !std.meta.eql(self.profile, target.profile)) return error.UnsupportedCapability;
        for (self.tables.sounds, target.tables.sounds) |a, b| {
            if (a.storage != .resident or b.storage != .resident or !std.meta.eql(a.key, b.key) or a.codec != b.codec or a.layout != b.layout or a.channels != b.channels or a.channel_mask != b.channel_mask or a.sample_rate_hz != b.sample_rate_hz or a.frames != b.frames or a.blob_length != b.blob_length or !std.meta.eql(a.chunks, b.chunks) or !std.meta.eql(a.seeks, b.seeks)) return error.UnsupportedCapability;
        }
    }
    pub fn stageResidentReload(self: *const Director, target: *const Director, anchor: ResidentImportAnchor, staged: *ResidentReloadStaging) Error!void {
        try self.validateResidentReloadTopology(target);
        return self.stageResidentReloadProjected(target, anchor, staged, null);
    }
    pub fn stageMappedResidentReload(self: *const Director, target: *const Director, anchor: ResidentImportAnchor, projection: *const resident_migration.Projection, staged: *ResidentReloadStaging) Error!void {
        try projection.validateFor(self.tables, target.tables, self.bank_build_id, target.bank_build_id);
        try projection.validateProfile(self.profile, target.profile);
        return self.stageResidentReloadProjected(target, anchor, staged, projection);
    }
    fn stageResidentReloadProjected(self: *const Director, target: *const Director, anchor: ResidentImportAnchor, staged: *ResidentReloadStaging, projection: ?*const resident_migration.Projection) Error!void {
        // A valid exhausted owner must reject before touching caller output.
        const next_transport_epoch = std.math.add(u64, self.transport_epoch, 1) catch return error.ResourceLimitExceeded;
        staged.prepared = false;
        try self.validateResidentLogical();
        if (self.residentMode() != .playing or self.pendingCount() != 0 or self.desired != null or self.suspended_target_entry != null or self.pause_acceptance != null or self.resume_acceptance != null) return error.UnsupportedCapability;
        if (anchor.context != self.context or anchor.context != target.context or anchor.asset_generation != target.asset_generation or anchor.asset_generation <= self.asset_generation or anchor.transport_epoch != next_transport_epoch or anchor.request_id <= self.last_request_id or anchor.plan_id <= self.last_bound_plan_id or anchor.plan_epoch != 1 or anchor.frame < self.current_frame or anchor.bar < self.current_bar) return error.InvalidState;
        if (self.request_epoch == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
        for (self.parameters[0..self.tables.parameters.len]) |parameter| if (parameter.value != parameter.target) return error.UnsupportedCapability;
        staged.logical = self.*;
        const next = &staged.logical;
        next.tables = target.tables;
        next.profile = target.profile;
        next.bank_build_id = target.bank_build_id;
        if (projection) |mapping| {
            next.committed_state = try mapping.state(self.committed_state);
            next.committed_segment = try mapping.segment(self.committed_segment);
            next.last_left_bar = @splat(null);
            for (self.last_left_bar[0..self.tables.states.len], 0..) |bar, i| next.last_left_bar[try mapping.state(@intCast(i))] = bar;
            next.selectors = @splat(.{});
            for (self.selectors[0..self.tables.selectors.len], 0..) |value, i| next.selectors[try mapping.selectorIndex(@intCast(i))] = try mapping.convertSelector(@intCast(i), value);
        }
        next.asset_generation = anchor.asset_generation;
        next.transport_epoch = anchor.transport_epoch;
        next.request_epoch += 1;
        next.last_request_id = anchor.request_id;
        next.last_position = anchor.position;
        next.last_bound_plan_id = anchor.plan_id;
        try next.advance(anchor.frame, anchor.bar);
        try next.validateResidentLogical();
        staged.expected = self.residentStamp();
        staged.anchor = anchor;
        staged.target_build_id = target.bank_build_id;
        staged.prepared = true;
    }
    pub fn validateResidentReload(self: *const Director, target: *const Director, staged: *const ResidentReloadStaging) Error!void {
        if (!staged.prepared or !std.meta.eql(staged.expected, self.residentStamp())) return error.InvalidState;
        if (staged.logical.tables.states.ptr != target.tables.states.ptr or staged.logical.tables.segments.ptr != target.tables.segments.ptr or staged.target_build_id != target.bank_build_id or staged.logical.bank_build_id != target.bank_build_id or staged.logical.asset_generation != target.asset_generation or staged.logical.transport_epoch != staged.anchor.transport_epoch or staged.logical.context != self.context) return error.InvalidState;
        try staged.logical.validateResidentLogical();
    }
    /// Exact executed replacement receipt is the sole authority to install the
    /// staged logical state. The old owner and its tables remain untouched.
    pub fn commitResidentReload(self: *const Director, target: *Director, staged: *ResidentReloadStaging, receipt: music.PhaseReceipt) Error!void {
        try self.validateResidentReload(target, staged);
        const anchor = staged.anchor;
        try receipt.token.validate();
        if (receipt.outcome != .executed or receipt.effective_frame != anchor.frame or receipt.token.context.value() != anchor.context or receipt.token.asset_generation.value() != anchor.asset_generation or receipt.token.transport_epoch.value() != anchor.transport_epoch or receipt.token.plan_id.value() != anchor.plan_id or receipt.token.plan_epoch.value() != anchor.plan_epoch or receipt.token.phase_id.value() != 1) return error.InvalidState;
        target.* = staged.logical;
        staged.prepared = false;
    }

    fn previewSeekStamp(self: *const Director) PreviewSeekOwnerStamp {
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, self.bank_build_id);
        std.hash.autoHash(&hash, self.profile);
        std.hash.autoHash(&hash, self.current_frame);
        std.hash.autoHash(&hash, self.current_bar);
        std.hash.autoHash(&hash, self.last_commit_frame);
        std.hash.autoHash(&hash, self.last_stop_tick);
        std.hash.autoHash(&hash, self.last_pause_tick);
        std.hash.autoHash(&hash, self.pause_acceptance);
        std.hash.autoHash(&hash, self.resume_acceptance);
        for (self.values[0..self.tables.parameters.len]) |value| std.hash.autoHash(&hash, value);
        inline for (std.meta.fields(s.Tables)) |field| {
            const table = @field(self.tables, field.name);
            std.hash.autoHash(&hash, @intFromPtr(table.ptr));
            std.hash.autoHash(&hash, table.len);
        }
        return .{ .resident = self.residentStamp(), .other_hash = hash.final() };
    }
    fn validatePreviewSeekStable(self: *const Director) Error!void {
        if (self.residentMode() != .playing or self.desired != null or self.pendingCount() != 0 or self.suspended_target_entry != null or self.pause_acceptance != null or self.resume_acceptance != null) return error.UnsupportedCapability;
        try self.validateResidentLogical();
        for (self.parameters[0..self.tables.parameters.len]) |parameter| {
            if (parameter.start_frame > self.current_frame) return error.InvalidOrder;
            // Integer rounding may reach target before the ramp actually ends.
            if (parameter.start != parameter.target and self.current_frame - parameter.start_frame < parameter.duration) return error.UnsupportedCapability;
        }
    }
    /// The runtime supplies an install-frame logical bar at least as large as
    /// both the old playback bar and the target's physical bar. A forward seek
    /// may therefore advance hold/cooldown; a backward audition never rewinds
    /// entered/last-left bars, context, or selector state. This only advances an
    /// owned copy and cannot resolve an automatic transition under these guards.
    pub fn stagePreviewSeek(self: *const Director, anchor: ResidentImportAnchor, staged: *PreviewSeekStaging) Error!void {
        staged.prepared = false;
        const next_transport_epoch = std.math.add(u64, self.transport_epoch, 1) catch return error.ResourceLimitExceeded;
        try self.validatePreviewSeekStable();
        if (anchor.context != self.context or anchor.asset_generation != self.asset_generation) return error.StaleAssetGeneration;
        if (anchor.transport_epoch != next_transport_epoch or anchor.plan_epoch != 1) return error.InvalidState;
        if (anchor.request_id <= self.last_request_id or anchor.plan_id <= self.last_bound_plan_id or anchor.position.accepted_control_frame > anchor.frame or anchor.frame < self.current_frame or anchor.bar < self.current_bar) return error.InvalidOrder;
        if (self.last_position) |previous| if (!trace.before(previous, anchor.position) or anchor.position.accepted_control_frame < previous.accepted_control_frame) return error.InvalidOrder;
        if (self.request_epoch == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
        staged.logical = self.*;
        const next = &staged.logical;
        next.transport_epoch = anchor.transport_epoch;
        next.request_epoch += 1;
        next.last_request_id = anchor.request_id;
        next.last_position = anchor.position;
        next.last_bound_plan_id = anchor.plan_id;
        try next.advance(anchor.frame, anchor.bar);
        try next.validatePreviewSeekStable();
        staged.owner = self;
        staged.expected = self.previewSeekStamp();
        staged.prepared_stamp = next.previewSeekStamp();
        staged.anchor = anchor;
        staged.prepared = true;
    }
    /// Validate before publication and again for the real gate result. The
    /// owner freezes advance/accept/resolve while published: old-clock time is
    /// not a valid observation of the seek clock. Any live or staged mutation
    /// invalidates the copy; advance from the new clock after exact commit.
    pub fn validatePreviewSeek(self: *const Director, staged: *const PreviewSeekStaging) Error!void {
        if (!staged.prepared or staged.owner != self or !std.meta.eql(staged.expected, self.previewSeekStamp())) return error.InvalidState;
        try self.validatePreviewSeekStable();
        const next = &staged.logical;
        const anchor = staged.anchor;
        if (!std.meta.eql(staged.prepared_stamp, next.previewSeekStamp()) or next.context != anchor.context or next.asset_generation != anchor.asset_generation or next.transport_epoch != anchor.transport_epoch or next.last_request_id != anchor.request_id or next.last_bound_plan_id != anchor.plan_id or anchor.plan_epoch != 1 or next.current_frame != anchor.frame or next.current_bar != anchor.bar or next.last_position == null or !std.meta.eql(next.last_position.?, anchor.position)) return error.InvalidState;
        try next.validatePreviewSeekStable();
    }
    /// Only the exact executed seek receipt installs the logical copy, once.
    /// A delayed receipt does not invent post-install old-clock observations.
    pub fn commitPreviewSeek(self: *Director, staged: *PreviewSeekStaging, receipt: music.PhaseReceipt) Error!void {
        try self.validatePreviewSeek(staged);
        const anchor = staged.anchor;
        try receipt.token.validate();
        if (receipt.outcome != .executed or receipt.effective_frame != anchor.frame or receipt.token.context.value() != anchor.context or receipt.token.asset_generation.value() != anchor.asset_generation or receipt.token.transport_epoch.value() != anchor.transport_epoch or receipt.token.plan_id.value() != anchor.plan_id or receipt.token.plan_epoch.value() != anchor.plan_epoch or receipt.token.phase_id.value() != 1) return error.InvalidState;
        self.* = staged.logical;
        staged.prepared = false;
    }

    pub fn pendingCount(self: *const Director) usize {
        var n: usize = 0;
        for (self.pending) |p| if (p.active) {
            n += 1;
        };
        return n;
    }
};
fn find(records: anytype, id: u64) Error!u32 {
    for (records, 0..) |record, i| if (record.key.id == id) return @intCast(i);
    return error.InvalidMusicGraph;
}
fn better(a: s.Transition, b: s.Transition) bool {
    if (a.priority != b.priority) return a.priority > b.priority;
    if (a.specificity != b.specificity) return a.specificity > b.specificity;
    return a.authored_order < b.authored_order;
}

fn put(e: *recording.codec.Encoder, value: anytype) Error!void {
    e.put(value) catch return error.BufferTooSmall;
}
fn get(d: *recording.codec.Decoder, comptime T: type) Error!T {
    return d.get(T) catch return error.InvalidMusicGraph;
}
pub const owned_state_bytes = @sizeOf(Director);
pub const owned_snapshot_bytes = @sizeOf(DirectorSelectorSnapshotV1);

const TokenRecord = struct {
    context: u64,
    transport_epoch: u64,
    plan_id: u64,
    plan_epoch: u64,
    phase_id: u64,
    asset_generation: u64,
    fn from(token: music.PhaseToken) TokenRecord {
        return .{ .context = token.context.value(), .transport_epoch = token.transport_epoch.value(), .plan_id = token.plan_id.value(), .plan_epoch = token.plan_epoch.value(), .phase_id = token.phase_id.value(), .asset_generation = token.asset_generation.value() };
    }
    fn value(token: TokenRecord) music.PhaseToken {
        return .{ .context = @enumFromInt(token.context), .transport_epoch = @enumFromInt(token.transport_epoch), .plan_id = @enumFromInt(token.plan_id), .plan_epoch = @enumFromInt(token.plan_epoch), .phase_id = @enumFromInt(token.phase_id), .asset_generation = @enumFromInt(token.asset_generation) };
    }
};
/// Conservative exact-width upper bound, independent of native ABI layout.
pub const maximum_encoded_snapshot_bytes: usize = 256 +
    s.Limits.selection_parameters * (8 + recording.codec.maxSize(ParameterState)) +
    s.Limits.selection_contexts * (8 + recording.codec.maxSize(logic.Value)) +
    s.Limits.selection_states * (8 + recording.codec.maxSize(?u64)) +
    s.Limits.selection_selectors * (8 + 1 + 2 + 8 + 2 + 8 + 4 + 2 + s.Limits.selector_history * 8) +
    s.Limits.director_pending * (recording.codec.maxSize(TransitionIntent) + 3 * 8 + 4 + 2 * 8 + 2 + recording.codec.maxSize(?TokenRecord) + 1 + 1 + 8);
comptime {
    if (maximum_encoded_snapshot_bytes > snapshot_capacity) @compileError("snapshot capacity cannot hold the release profile");
}

const IdIndex = struct {
    id: u64,
    index: u32,
    fn less(_: void, a: IdIndex, b: IdIndex) bool {
        return a.id < b.id;
    }
};
fn lookup(index: []const IdIndex, id: u64) Error!u32 {
    var lo: usize = 0;
    var hi = index.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (index[mid].id < id) lo = mid + 1 else hi = mid;
    }
    if (lo == index.len or index[lo].id != id) return error.InvalidMusicGraph;
    return index[lo].index;
}
pub const maximum_restore_scratch_bytes: usize = @sizeOf(Director) + s.Limits.records * @sizeOf(IdIndex);

fn reanchorResidentBar(value: u64, previous: u64, current: u64) Error!u64 {
    if (value > previous) return error.InvalidMusicGraph;
    const age = previous - value;
    if (age > current) return error.ResourceLimitExceeded;
    return current - age;
}
pub const owned_resident_snapshot_bytes = @sizeOf(DirectorResidentSnapshotV1);
pub const owned_resident_baseline_bytes = @sizeOf(ResidentCaptureBaseline);
pub const owned_resident_staging_bytes = @sizeOf(ResidentImportStaging);

pub const maximum_encoded_resident_snapshot_bytes: usize = 128 +
    s.Limits.selection_parameters * 12 +
    s.Limits.selection_contexts * (8 + recording.codec.maxSize(logic.Value)) +
    s.Limits.selection_states * (8 + recording.codec.maxSize(?u64)) +
    s.Limits.selection_selectors * (8 + 1 + 2 + 8 + 8 + 4 + 2 + s.Limits.selector_history * 8) +
    recording.codec.maxSize(ResidentReservation);
comptime {
    if (maximum_encoded_resident_snapshot_bytes > snapshot_capacity) @compileError("resident snapshot capacity cannot hold the release profile");
}

/// Fact payload plus its private validity flag/alignment are included in the
/// actual Director/baseline/staging size constants above, never uncounted scratch.
pub const resident_eligibility_fact_bytes: usize = @sizeOf([4]u64);
pub const owned_resident_eligibility_slot_bytes: usize = @sizeOf(ResidentEligibility);
comptime {
    if (s.Limits.selector_candidates != 256) @compileError("resident eligibility wire requires the 256-candidate profile");
}
