//! TASK-012 gain controller: stable M1 scalar mode and explicit prepared mode.
//! Control-owner only. The host grants exclusive writes to bound layer gains;
//! no global owner registry/public MusicRuntime integration is claimed here.
const std = @import("std");
const runtime = @import("bugu_audio").runtime;
const scheduler = @import("sme-scheduler");
const curves = @import("sme-layer-curves");
const schema = @import("sme-bank").schema;
pub const contract = @import("sme-layer-contract");
pub const timeline = @import("sme-layer-timeline");
pub const prepared_spans = @import("sme-layer-spans");
const span_compile = @import("sme-layer-span-compile");
const source_clock = @import("sme-clock");
pub const Error = runtime.RuntimeError || curves.Error || timeline.Error || span_compile.Error || error{ InvalidProfile, InvalidBinding, ConflictingWriters, UnsupportedField, PendingAutomation, NoPendingAutomation, StaleBinding, InvalidInputOrder, RollbackPending, UnsupportedSampleRate };
pub const Binding = struct {
    layer: schema.Layer,
    ordinal: u16,
    input_minimum: f64 = 0,
    input_maximum: f64 = 1,
    input_stage: contract.InputStage = .accepted_smoothed,
    output_policy: contract.OutputPolicy = .reject,
    ramps: contract.Ramps = .{},
};
pub const Instance = struct {
    source_incarnation: u64 = 1,
    group: runtime.GroupHandle,
    context: u64 = 1,
    bank_generation: u64,
    transport_epoch: u64 = 1,
    mutation_epoch: u64 = 1,
};
pub const Request = struct {
    execute_frame: u64,
    plan_id: u64,
    input_order: u64,
    bank_generation: u64,
    transport_epoch: u64 = 1,
    musical: ?timeline.MusicalStart = null,
};
pub const Update = struct { layer_id: u64, target: contract.LayerTarget };
pub const TargetState = struct { gain: f32, ramps: contract.Ramps };
pub const LayerState = struct {
    desired: TargetState,
    effective: TargetState,
    pending: ?TargetState = null,
    envelope: ?timeline.Span = null,
    effective_frame: u64 = 0,
    last_reason: scheduler.trace.Reason = .none,
    /// Prepared mode reports durable automation completion independently of installation.
    automation_terminal: ?prepared_spans.Terminal = null,
    /// M1 analytic prediction only. Prepared-mode effective.gain is the accepted
    /// target; query ControlRuntime observation for the actual live primitive.
    pub fn predictedGain(self: LayerState, frame: u64) f32 {
        return if (self.envelope) |span| span.valueAt(frame) else self.effective.gain;
    }
};
pub const Submission = union(enum) { unchanged, scheduled: struct { handle: scheduler.Handle, commands: u16, phases: u16, rounded_instant: bool } };
pub const TestStage = enum { after_receipt_drain, after_rollback_cancel };
pub const TestHook = struct { context: *anyopaque, call: *const fn (*anyopaque, TestStage) void };
pub const Poll = struct { receipts: u16 = 0, successful: u16 = 0, rejected: u16 = 0, complete: bool = false };
const PendingCommand = struct { layer: u16, span: timeline.Span, target: TargetState, command_id: u64 };
const Pending = struct {
    handle: scheduler.Handle,
    cursor: u16 = 0,
    commands: [32]PendingCommand,
    count: u16,
};
pub const LayerController = struct {
    allocator: std.mem.Allocator,
    owned_curves: curves.OwnedCurves,
    bindings: []const Binding,
    instance: Instance,
    profile: contract.Profile,
    states: [16]LayerState = undefined,
    pending: ?Pending = null,
    /// A failed submit whose local resource rollback could not complete stays
    /// retained for explicit retry; no desired/effective target is changed.
    rollback: ?scheduler.Handle = null,
    prepared: PreparedState = .{},
    last_input_order: u64 = 0,
    last_plan_id: u64 = 0,
    last_unsupported: contract.FieldMask = 0,
    submitted_commands: u64 = 0,
    test_hook: if (@import("builtin").is_test) ?TestHook else void = if (@import("builtin").is_test) null else {},
    fn hook(self: *LayerController, stage: TestStage) void {
        if (@import("builtin").is_test) if (self.test_hook) |h| h.call(h.context, stage);
    }

    pub fn init(allocator: std.mem.Allocator, instance: Instance, bindings: []const Binding, curve_table: []const schema.Curve, points: []const schema.CurvePoint, bank_profile: schema.Platform, profile: contract.Profile) Error!LayerController {
        try profile.validate();
        if (instance.source_incarnation == 0 or instance.group.generation == 0 or instance.context == 0 or instance.bank_generation == 0 or instance.transport_epoch == 0 or instance.mutation_epoch == 0 or bindings.len == 0 or bindings.len > profile.max_layers) return error.InvalidBinding;
        var owned = try curves.OwnedCurves.init(allocator, curve_table, points, bank_profile);
        errdefer owned.deinit();
        for (bindings, 0..) |binding, i| {
            if (binding.layer.key.id == 0 or binding.ordinal >= 16 or !std.math.isFinite(binding.layer.gain_db)) return error.InvalidBinding;
            _ = try curves.normalize(0, binding.input_minimum, binding.input_maximum);
            try validateDuration(binding.ramps.attack);
            try validateDuration(binding.ramps.release);
            _ = try initialGain(binding);
            for (bindings[0..i]) |prior| if (prior.ordinal == binding.ordinal or prior.layer.key.id == binding.layer.key.id) return error.ConflictingWriters;
            if (binding.layer.gain_curve != schema.none) {
                if (binding.layer.gain_curve >= owned.descriptors.len) return error.InvalidReference;
                const range = owned.descriptors[binding.layer.gain_curve].points;
                for (owned.points[range.first..][0..range.count]) |point| _ = try contract.validateGain(point.value, binding.output_policy);
            }
        }
        const copied = try allocator.dupe(Binding, bindings);
        var result: LayerController = .{ .allocator = allocator, .owned_curves = owned, .bindings = copied, .instance = instance, .profile = profile };
        for (bindings, 0..) |binding, i| {
            const target: TargetState = .{ .gain = try initialGain(binding), .ramps = binding.ramps };
            result.states[i] = .{ .desired = target, .effective = target };
        }
        return result;
    }
    /// Refuses to abandon outstanding scheduler leases. Active scalar ramps own
    /// no controller memory: their coefficients already live in Render.
    pub fn deinit(self: *LayerController) Error!void {
        if (self.pending != null or self.rollback != null or self.prepared.busy()) return error.PendingAutomation;
        if (self.prepared.suspended) |*saved| saved.owned.deinit();
        self.owned_curves.deinit();
        self.allocator.free(self.bindings);
        self.* = undefined;
    }
    pub fn preparedBusy(self: *const LayerController) bool {
        return self.pending != null or self.rollback != null or self.prepared.busy();
    }
    fn initialGain(binding: Binding) Error!f32 {
        return contract.validateGain(@floatCast(std.math.pow(f64, 10, @as(f64, binding.layer.gain_db) / 20)), .reject);
    }
    fn validateDuration(duration: contract.Duration) Error!void {
        if (duration == .quarter_beats and duration.quarter_beats.denominator == 0) return error.InvalidDuration;
    }
    fn index(self: *const LayerController, id: u64) Error!u16 {
        for (self.bindings, 0..) |binding, i| if (binding.layer.key.id == id) return @intCast(i);
        return error.InvalidBinding;
    }
    pub fn state(self: *const LayerController, layer_id: u64) Error!LayerState {
        return self.states[try self.index(layer_id)];
    }
    pub fn evaluate(self: *const LayerController, input: f64, output: []Update) Error![]Update {
        if (!std.math.isFinite(input)) return error.NonFiniteInput;
        if (output.len < self.bindings.len) return error.InvalidArgument;
        for (self.bindings, 0..) |binding, i| {
            const normalized = try curves.normalize(input, binding.input_minimum, binding.input_maximum);
            const gain = if (binding.layer.gain_curve == schema.none) try initialGain(binding) else try self.owned_curves.evaluate(binding.layer.gain_curve, normalized);
            output[i] = .{ .layer_id = binding.layer.key.id, .target = .{ .gain = try contract.validateGain(gain, binding.output_policy) } };
        }
        return output[0..self.bindings.len];
    }
    pub fn submitInput(self: *LayerController, control: *runtime.ControlRuntime, input: f64, request: Request) Error!Submission {
        var updates: [16]Update = undefined;
        return self.submitTargets(control, try self.evaluate(input, &updates), request);
    }
    pub fn submitTargets(self: *LayerController, control: *runtime.ControlRuntime, updates: []const Update, request: Request) Error!Submission {
        if (self.prepared.enabled) return error.InvalidState;
        if (updates.len > self.profile.max_layers) return error.TimelineBudgetExceeded;
        self.last_unsupported = 0;
        for (updates) |update| self.last_unsupported |= update.target.unsupported();
        if (self.last_unsupported != 0) return error.UnsupportedField;
        if (self.rollback != null) return error.RollbackPending;
        if (request.bank_generation != self.instance.bank_generation) return error.StaleAssetGeneration;
        if (request.transport_epoch != self.instance.transport_epoch) return error.StaleBinding;
        if (request.input_order == 0 or request.input_order < self.last_input_order) return error.InvalidInputOrder;
        var targets: [16]?TargetState = @splat(null);
        var changed = false;
        for (updates) |update| {
            const i = try self.index(update.layer_id);
            if (targets[i] != null) return error.ConflictingWriters;
            if (update.target.present() == 0) continue;
            const binding = self.bindings[i];
            const target: TargetState = .{
                .gain = try contract.validateGain(update.target.gain orelse try initialGain(binding), binding.output_policy),
                .ramps = .{ .attack = update.target.attack orelse binding.ramps.attack, .release = update.target.release orelse binding.ramps.release },
            };
            try validateDuration(target.ramps.attack);
            try validateDuration(target.ramps.release);
            targets[i] = target;
            const previous = self.states[i].pending orelse self.states[i].effective;
            if (!std.meta.eql(previous, target) or self.states[i].last_reason != .none) changed = true;
        }
        if (!changed) return .unchanged;
        if (request.input_order <= self.last_input_order or request.plan_id == 0 or request.plan_id <= self.last_plan_id) return error.InvalidInputOrder;
        if (self.pending != null) return error.PendingAutomation;
        const observation = try control.musicVoiceObservation(self.instance.group);
        if (observation.generation != self.instance.bank_generation) return error.StaleAssetGeneration;
        if (observation.transport_epoch != self.instance.transport_epoch or observation.mutation_epoch != self.instance.mutation_epoch or observation.paused or observation.state != .playing or request.execute_frame < observation.frame) return error.StaleBinding;
        var commands: [32]runtime.ScheduledCommand = undefined;
        var prepared: [32]PendingCommand = undefined;
        var count: u16 = 0;
        var rounded_instant = false;
        for (targets[0..self.bindings.len], 0..) |optional, i| if (optional) |target| {
            const previous = self.states[i].effective;
            if (std.meta.eql(previous, target) and self.states[i].last_reason == .none) continue;
            if (self.bindings[i].ordinal >= observation.layer_count) return error.InvalidBinding;
            // The first bound write must agree with the real prepared layer.
            if (self.states[i].envelope == null and observation.layers[self.bindings[i].ordinal].gain != previous.gain) return error.StaleBinding;
            const from = self.states[i].predictedGain(request.execute_frame);
            const duration = if (target.gain >= from) target.ramps.attack else target.ramps.release;
            if (duration == .quarter_beats and control.rendererSampleRate() != schema.sample_rate) return error.UnsupportedSampleRate;
            const spans = try timeline.compile(request.execute_frame, from, target.gain, duration, request.musical, self.profile.max_commands);
            if (@as(usize, count) + spans.count > self.profile.max_commands) return error.TimelineBudgetExceeded;
            rounded_instant = rounded_instant or spans.rounded_instant;
            for (spans.items()) |span| {
                prepared[count] = .{ .layer = @intCast(i), .span = span, .target = .{ .gain = span.to, .ramps = target.ramps }, .command_id = 0 };
                count += 1;
            }
        };
        std.mem.sort(PendingCommand, prepared[0..count], {}, struct {
            fn less(_: void, a: PendingCommand, b: PendingCommand) bool {
                return a.span.start_frame < b.span.start_frame or (a.span.start_frame == b.span.start_frame and a.layer < b.layer);
            }
        }.less);
        var phase: u16 = 0;
        var phase_writes: u16 = 0;
        var last_frame = request.execute_frame;
        for (prepared[0..count], 0..) |*p, i| {
            if (i != 0 and p.span.start_frame != last_frame) {
                phase += 1;
                phase_writes = 0;
            }
            phase_writes += 1;
            if (phase >= self.profile.max_phases or phase_writes > self.profile.max_writes_per_phase) return error.TimelineBudgetExceeded;
            if (i != 0 and p.span.start_frame == last_frame and p.layer == prepared[i - 1].layer) return error.ConflictingWriters;
            p.command_id = i + 1;
            commands[i] = .{ .identity = .{
                .command_id = p.command_id,
                .token = .{ .context = @enumFromInt(self.instance.context), .transport_epoch = @enumFromInt(request.transport_epoch), .plan_id = @enumFromInt(request.plan_id), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(@as(u64, phase) + 1), .asset_generation = @enumFromInt(request.bank_generation) },
                .phase_order = phase,
                .execute_frame = p.span.start_frame,
                .group_id = @as(u64, phase) + 1,
            }, .payload = .{ .group_layer_gain = .{ .group = self.instance.group, .layer = self.bindings[p.layer].ordinal, .gain = p.span.to, .ramp_frames = p.span.frames() } } };
            last_frame = p.span.start_frame;
        }
        const end = std.math.add(u64, last_frame, 1) catch return error.UnsafeFrameRange;
        const submitted_total = std.math.add(u64, self.submitted_commands, count) catch return error.UnsafeFrameRange;
        const handle = try control.prepareSchedule(request.execute_frame, end, commands[0..count]);
        control.submitSchedule(handle) catch |err| {
            self.rollback = handle;
            try self.retryRollback(control);
            return err;
        };
        self.pending = .{ .handle = handle, .commands = prepared, .count = count };
        for (targets[0..self.bindings.len], 0..) |target, i| if (target) |value| {
            self.states[i].desired = value;
            self.states[i].pending = value;
        };
        self.last_input_order = request.input_order;
        self.last_plan_id = request.plan_id;
        self.submitted_commands = submitted_total;
        return .{ .scheduled = .{ .handle = handle, .commands = count, .phases = phase + 1, .rounded_instant = rounded_instant } };
    }
    pub fn retryRollback(self: *LayerController, control: *runtime.ControlRuntime) Error!void {
        const handle = self.rollback orelse return;
        if (try control.scheduleResult(handle) == null) {
            const intent = try control.cancelSchedule(.{ .target = handle, .requested_frame = 0 });
            // Failed submit leaves a local prepared block under the exclusive
            // Control owner. No queued/async cancellation may be discarded.
            std.debug.assert(intent == null);
            self.hook(.after_rollback_cancel);
        }
        try control.releaseSchedule(handle);
        self.rollback = null;
    }
    pub fn poll(self: *LayerController, control: *runtime.ControlRuntime) Error!Poll {
        var result: Poll = .{};
        const pending = if (self.pending) |*p| p else return result;
        // Observe terminal before draining. If Render finishes just after this
        // acquire, defer release until the next poll instead of missing its
        // final newly-published receipts.
        const terminal = try control.scheduleResult(pending.handle);
        while (try control.pollExecutionReceipt(pending.handle, &pending.cursor)) |receipt| {
            if (receipt.command_id == 0 or receipt.command_id > pending.count) return error.InvalidState;
            const command = pending.commands[receipt.command_id - 1];
            const layer = &self.states[command.layer];
            result.receipts += 1;
            if (receipt.result == .success) {
                layer.effective = command.target;
                layer.envelope = command.span;
                layer.effective_frame = receipt.executed_frame;
                layer.last_reason = .none;
                result.successful += 1;
            } else {
                layer.last_reason = receipt.reason;
                result.rejected += 1;
            }
        }
        self.hook(.after_receipt_drain);
        if (terminal) |complete| {
            if (pending.cursor != complete.count) return error.InvalidState;
            try control.releaseSchedule(pending.handle);
            self.pending = null;
            for (self.states[0..self.bindings.len]) |*state_value| state_value.pending = null;
            result.complete = true;
        }
        return result;
    }
    /// Explicit opt-in; the M1 initializer and scheduler behavior stay unchanged.
    pub fn initPrepared(allocator: std.mem.Allocator, instance: Instance, bindings: []const Binding, curve_table: []const schema.Curve, points: []const schema.CurvePoint, bank_profile: schema.Platform, profile: contract.Profile, prepared_profile: prepared_spans.Profile) Error!LayerController {
        try prepared_profile.validate();
        if (@sizeOf(PreparedState) > prepared_profile.metadata_bytes) return error.LayerProgramBudgetExceeded;
        var result = try init(allocator, instance, bindings, curve_table, points, bank_profile, profile);
        result.prepared.enabled = true;
        result.prepared.profile = prepared_profile;
        return result;
    }
    /// Exact retained Control storage; runtime manager, curves/bindings and
    /// transient compilation are separate. Preparation admits its entire peak
    /// against this controller's metadata cap before allocating new arrays.
    pub fn preparedUsage(self: *const LayerController) PreparedUsage {
        var usage: PreparedUsage = .{ .fixed_bytes = @sizeOf(PreparedState), .metadata_limit = self.prepared.profile.metadata_bytes };
        for (self.prepared.leases) |lease| if (lease) |value| usage.add(value.owned.desc);
        if (self.prepared.suspended) |value| usage.add(value.owned.desc);
        if (self.prepared.rollback) |value| if (value.owned) |owned| usage.add(owned.desc);
        usage.total_retained_bytes = usage.fixed_bytes + usage.owned_heap_bytes;
        return usage;
    }
    pub fn preparedProgram(self: *const LayerController) ?prepared_spans.ProgramHandle {
        const i = self.prepared.active orelse return null;
        return self.prepared.leases[i].?.program;
    }
    /// Local bounded admission availability, not evidence of Render execution.
    /// A public owner may coalesce an internal driver observation while busy.
    pub fn preparedCanSubmit(self: *const LayerController) bool {
        return self.prepared.enabled and self.pending == null and self.rollback == null and
            self.prepared.pending == null and self.prepared.stop == null and self.prepared.cancel == null and
            self.prepared.rollback == null and self.prepared.unreported == null and
            (self.prepared.leases[0] == null or self.prepared.leases[1] == null);
    }
    pub fn submitPreparedInput(self: *LayerController, control: anytype, input: f64, request: PreparedRequest) Error!PreparedSubmission {
        var updates: [16]Update = undefined;
        return self.submitPreparedTargets(control, try self.evaluate(input, &updates), request);
    }
    pub fn submitPreparedTargets(self: *LayerController, control: anytype, updates: []const Update, request: PreparedRequest) Error!PreparedSubmission {
        return preparedSubmit(self, control, updates, request, null, false);
    }
    /// Resume only an acquired paused terminal. Its source-clock suffix is
    /// retained by Control and rebound atomically after group_pause(false).
    pub fn resumePrepared(self: *LayerController, control: anytype, request: PreparedRequest, next_transport_epoch: u64) Error!PreparedSubmission {
        if (self.prepared.suspended == null) return error.NoPendingAutomation;
        return preparedSubmit(self, control, &.{}, request, .{ .resume_group = true, .next_transport_epoch = next_transport_epoch }, true);
    }
    /// Explicit rebase compiles fresh targets under the post-mutation clock.
    /// A previously revoked generation must first be reconciled by pollPrepared.
    pub fn rebasePrepared(self: *LayerController, control: anytype, updates: []const Update, request: PreparedRequest, rebase: runtime.ControlRuntime.LayerProgramRebase) Error!PreparedSubmission {
        return preparedSubmit(self, control, updates, request, rebase, false);
    }
    pub fn pollPrepared(self: *LayerController, control: anytype) Error!PreparedPoll {
        return preparedPoll(self, control);
    }
    /// Exact-generation stop, independent of completed-install cancellation.
    pub fn stopPrepared(self: *LayerController, control: anytype, request: PreparedRequest) Error!scheduler.Handle {
        if (self.prepared.cancel != null) return error.PendingAutomation;
        return preparedStop(self, control, request);
    }
    /// Try pre-install cancellation and, if installation wins, use the supplied
    /// fresh host plan identity for an explicit stop at the next legal frontier.
    /// The actual cancellation receipt and any fallback stop are reported by poll.
    pub fn cancelPrepared(self: *LayerController, control: anytype, requested_frame: u64, fallback_stop: PreparedRequest) Error!?scheduler.Handle {
        return preparedCancel(self, control, requested_frame, fallback_stop);
    }
    pub fn retryPreparedRollback(self: *LayerController, control: anytype) Error!void {
        return preparedRollback(self, control);
    }
};

/// Every changing request gets a fresh ID from the host-wide plan owner. This
/// controller checks local ordering; it never manufactures a competing counter.
pub const PreparedRequest = struct {
    source_incarnation: u64 = 1,
    execute_frame: u64,
    plan_id: u64,
    plan_epoch: u64,
    phase_id: u64 = 1,
    phase_order: u32 = 0,
    input_order: u64,
    bank_generation: u64,
    transport_epoch: u64,
    mutation_epoch: u64,
    binding_revision: u64 = 1,
    expected_previous: ?prepared_spans.ProgramHandle = null,
    /// A real new driver binding must acquire its own installation receipt even
    /// when its first observed target equals the prior audible target. Default
    /// standalone diff behavior and unchanged-track suffixes stay unchanged.
    force_binding_install: bool = false,
    musical: ?source_clock.Map = null,
};
pub const PreparedSubmission = union(enum) {
    unchanged,
    scheduled: struct {
        handle: scheduler.Handle,
        program: prepared_spans.ProgramHandle,
        commands: u16,
        tracks: u16,
        spans: u32,
    },
};
pub const PreparedUsage = struct {
    fixed_bytes: usize,
    owned_programs: usize = 0,
    owned_tracks: usize = 0,
    owned_spans: usize = 0,
    owned_heap_bytes: usize = 0,
    total_retained_bytes: usize = 0,
    metadata_limit: usize,
    fn add(self: *PreparedUsage, desc: prepared_spans.ProgramDesc) void {
        self.owned_programs += 1;
        self.owned_tracks += desc.tracks.len;
        self.owned_spans += desc.spans.len;
        self.owned_heap_bytes += programHeapBytes(desc);
    }
};
fn programHeapBytes(desc: prepared_spans.ProgramDesc) usize {
    return desc.tracks.len * @sizeOf(prepared_spans.TrackDesc) + desc.spans.len * @sizeOf(prepared_spans.Span);
}
pub const PreparedTerminal = struct {
    program: prepared_spans.ProgramHandle,
    tracks: [16]prepared_spans.Terminal = undefined,
    track_count: u16,
    release_frontier: u64,
};
/// Copied from the real retained plan before its schedule can be released.
/// A rejected installation has no executed PhaseReceipt.
pub const PreparedInstallation = struct {
    program: prepared_spans.ProgramHandle,
    phase: ?@import("bugu_audio").music.PhaseReceipt,
    rejection: ?scheduler.trace.Reason,
};
pub const PreparedPoll = struct {
    installations: [2]PreparedInstallation = undefined,
    installation_count: u16 = 0,
    receipts: u16 = 0,
    successful: u16 = 0,
    rejected: u16 = 0,
    install_complete: bool = false,
    automation_terminal: bool = false,
    stop_complete: bool = false,
    cancellation: ?scheduler.trace.ScheduleRecord = null,
    fallback_stop: ?scheduler.Handle = null,
    terminal: ?PreparedTerminal = null,
    terminals: [2]PreparedTerminal = undefined,
    terminal_count: u16 = 0,
};
const PreparedLease = struct {
    program: prepared_spans.ProgramHandle,
    owned: span_compile.OwnedProgram,
    handle: ?scheduler.Handle,
    cursor: u16 = 0,
    install_command: u64,
    installed: bool = false,
    install_complete: bool = false,
    phase_cursor: u16 = 0,
    phase: ?@import("bugu_audio").music.PhaseReceipt = null,
    rejection: ?scheduler.trace.Reason = null,
    terminal_reported: bool = false,
    save_suffix: bool = false,
    targets: [16]TargetState = undefined,
    terminal: ?PreparedTerminal = null,
};
const Suspended = struct {
    owned: span_compile.OwnedProgram,
    targets: [16]TargetState,
    elapsed: [16]u64 = @splat(0),
};
const PreparedRollback = struct {
    program: ?prepared_spans.ProgramHandle = null,
    owned: ?span_compile.OwnedProgram = null,
    handle: ?scheduler.Handle = null,
};
const PreparedStop = struct {
    handle: scheduler.Handle,
    cursor: u16 = 0,
};
const PreparedCancel = struct {
    program: prepared_spans.ProgramHandle,
    handle: scheduler.Handle,
    intent: ?scheduler.Handle,
    fallback: PreparedRequest,
    result: ?scheduler.trace.ScheduleRecord = null,
};
const PreparedState = struct {
    enabled: bool = false,
    profile: prepared_spans.Profile = .{},
    // One live owner and one submitted successor. Retired generations are
    // reconciled before another successor can consume the second local slot.
    leases: [2]?PreparedLease = @splat(null),
    active: ?usize = null,
    pending: ?usize = null,
    suspended: ?Suspended = null,
    rollback: ?PreparedRollback = null,
    stop: ?PreparedStop = null,
    cancel: ?PreparedCancel = null,
    unreported: ?PreparedPoll = null,
    fn busy(self: *const PreparedState) bool {
        return self.leases[0] != null or self.leases[1] != null or self.rollback != null or self.stop != null or self.cancel != null or self.unreported != null;
    }
};
fn preparedIdentity(self: *const LayerController, request: PreparedRequest, command_id: u64) scheduler.CommandIdentity {
    return .{ .command_id = command_id, .token = .{
        .context = @enumFromInt(self.instance.context),
        .transport_epoch = @enumFromInt(request.transport_epoch),
        .plan_id = @enumFromInt(request.plan_id),
        .plan_epoch = @enumFromInt(request.plan_epoch),
        .phase_id = @enumFromInt(request.phase_id),
        .asset_generation = @enumFromInt(request.bank_generation),
    }, .phase_order = request.phase_order, .execute_frame = request.execute_frame, .group_id = request.phase_id };
}
fn preparedCheck(self: *const LayerController, request: PreparedRequest) Error!void {
    if (request.source_incarnation == 0 or request.source_incarnation != self.instance.source_incarnation) return error.StaleBinding;
    if (!self.prepared.enabled or self.pending != null or self.rollback != null) return error.InvalidState;
    if (self.prepared.rollback != null) return error.RollbackPending;
    if (self.prepared.unreported != null) return error.PendingAutomation;
    if (request.bank_generation != self.instance.bank_generation) return error.StaleAssetGeneration;
    if (request.input_order == 0 or request.input_order < self.last_input_order) return error.InvalidInputOrder;
    if (request.transport_epoch == 0 or request.mutation_epoch == 0 or request.binding_revision == 0) return error.StaleBinding;
}
fn preparedChanging(self: *const LayerController, request: PreparedRequest) Error!void {
    if (request.plan_id == 0 or request.plan_id <= self.last_plan_id or request.plan_epoch == 0 or request.phase_id == 0 or request.input_order <= self.last_input_order) return error.InvalidInputOrder;
}
fn predictedPrepared(track: prepared_spans.TrackDesc, values: []const prepared_spans.Span, elapsed: u64) f32 {
    var previous: u64 = 0;
    var from = track.initial_prediction;
    for (values) |span| {
        if (elapsed < span.end_offset) {
            const t = @as(f64, @floatFromInt(elapsed - previous)) / @as(f64, @floatFromInt(span.end_offset - previous));
            return @floatCast(@as(f64, from) + (@as(f64, span.target) - from) * t);
        }
        previous = span.end_offset;
        from = span.target;
    }
    return track.final_target;
}
/// Preserve numeric source-clock suffixes, including unequal track endpoints.
/// Carried tracks are explicitly frame-domain continuations of compiled spans;
/// their canonical musical endpoint remains as audit metadata. No caller map,
/// curve table, or controller pointer is borrowed by Render.
fn carrySuffix(self: *LayerController, owned: *span_compile.OwnedProgram, prior: *const span_compile.OwnedProgram, changed: [16]bool, elapsed: [16]u64) Error!void {
    var count: usize = 0;
    for (owned.desc.tracks, 0..) |track, i| {
        if (changed[i]) {
            count += track.spans.count;
        } else {
            const old = prior.desc.tracks[i];
            for (prior.desc.spans[old.spans.first..][0..old.spans.count]) |span| if (span.end_offset > elapsed[i]) {
                count += 1;
            };
        }
    }
    if (count > self.prepared.profile.spans) return error.LayerProgramBudgetExceeded;
    const retained = self.preparedUsage().total_retained_bytes;
    const limit = self.prepared.profile.metadata_bytes;
    const temporary = programHeapBytes(owned.desc);
    const replacement = owned.desc.tracks.len * @sizeOf(prepared_spans.TrackDesc) + count * @sizeOf(prepared_spans.Span);
    if (retained > limit or temporary > limit - retained or replacement > limit - retained - temporary or @sizeOf(prepared_spans.ProgramDesc) + replacement > limit) return error.LayerProgramBudgetExceeded;
    const tracks = try self.allocator.dupe(prepared_spans.TrackDesc, owned.desc.tracks);
    errdefer self.allocator.free(tracks);
    const values = try self.allocator.alloc(prepared_spans.Span, count);
    errdefer self.allocator.free(values);
    var cursor: usize = 0;
    for (tracks, 0..) |*track, i| {
        const first = cursor;
        if (changed[i]) {
            const source = owned.desc.spans[track.spans.first..][0..track.spans.count];
            @memcpy(values[cursor..][0..source.len], source);
            cursor += source.len;
        } else {
            const prediction = track.initial_prediction;
            track.* = prior.desc.tracks[i];
            for (prior.desc.spans[track.spans.first..][0..track.spans.count]) |span| if (span.end_offset > elapsed[i]) {
                values[cursor] = span;
                values[cursor].end_offset -= elapsed[i];
                cursor += 1;
            };
            track.initial_prediction = prediction;
            track.source_endpoint -|= elapsed[i];
            track.instant = track.source_endpoint == 0;
            track.domain = .frames;
            track.duration_numerator = track.source_endpoint;
            track.duration_denominator = 1;
            track.endpoint_rounding = .exact;
        }
        track.spans = .{ .first = @intCast(first), .count = @intCast(cursor - first) };
    }
    var desc = owned.desc;
    desc.tracks = tracks;
    desc.spans = values;
    desc.content_hash = prepared_spans.contentHash(desc);
    try prepared_spans.validate(desc);
    self.allocator.free(owned.desc.tracks);
    self.allocator.free(owned.desc.spans);
    owned.desc = desc;
}
fn preparedSubmit(self: *LayerController, control: anytype, updates: []const Update, request: PreparedRequest, rebase_: ?runtime.ControlRuntime.LayerProgramRebase, resume_suffix: bool) Error!PreparedSubmission {
    try preparedCheck(self, request);
    if (updates.len > self.bindings.len) return error.InvalidArgument;
    self.last_unsupported = 0;
    for (updates) |update| self.last_unsupported |= update.target.unsupported();
    if (self.last_unsupported != 0) return error.UnsupportedField;
    var targets: [16]TargetState = undefined;
    var changed: [16]bool = @splat(false);
    var seen: [16]bool = @splat(false);
    var any_changed = false;
    for (self.bindings, 0..) |_, i| targets[i] = self.states[i].pending orelse self.states[i].effective;
    if (self.prepared.pending) |pending| {
        targets = self.prepared.leases[pending].?.targets;
    } else if (self.prepared.active) |active| targets = self.prepared.leases[active].?.targets;
    if (resume_suffix) targets = self.prepared.suspended.?.targets;
    for (updates) |update| {
        const i = try self.index(update.layer_id);
        if (seen[i]) return error.ConflictingWriters;
        seen[i] = true;
        if (update.target.present() == 0) continue;
        const binding = self.bindings[i];
        const next: TargetState = .{
            .gain = try contract.validateGain(update.target.gain orelse try LayerController.initialGain(binding), binding.output_policy),
            .ramps = .{ .attack = update.target.attack orelse binding.ramps.attack, .release = update.target.release orelse binding.ramps.release },
        };
        try LayerController.validateDuration(next.ramps.attack);
        try LayerController.validateDuration(next.ramps.release);
        changed[i] = !std.meta.eql(next, targets[i]) or self.states[i].last_reason != .none;
        any_changed = any_changed or changed[i];
        targets[i] = next;
    }
    if (!any_changed and rebase_ == null and !request.force_binding_install) return .unchanged;
    try preparedChanging(self, request);
    if (self.prepared.pending != null or self.prepared.stop != null or self.prepared.cancel != null) return error.PendingAutomation;
    const free: usize = if (self.prepared.leases[0] == null) 0 else if (self.prepared.leases[1] == null) 1 else return error.PendingAutomation;
    if (!std.meta.eql(request.expected_previous, self.preparedProgram())) return error.StaleBinding;
    const observation = try control.musicVoiceObservation(self.instance.group);
    if (observation.source_incarnation != request.source_incarnation or observation.generation != request.bank_generation or observation.transport_epoch != request.transport_epoch or observation.mutation_epoch != request.mutation_epoch) return error.StaleBinding;
    var rebase = rebase_;
    if (rebase) |*value| value.expected_previous = request.expected_previous;
    const anchor = if (rebase) |value|
        try control.layerProgramRebaseAnchorForSource(self.instance.group, request.source_incarnation, request.execute_frame, self.instance.context, request.binding_revision, value)
    else
        try control.layerProgramAnchorForSource(self.instance.group, request.source_incarnation, request.execute_frame, self.instance.context, request.binding_revision, request.expected_previous);
    var prior: ?*const span_compile.OwnedProgram = null;
    var elapsed: [16]u64 = @splat(0);
    if (self.prepared.active) |active| {
        const lease = &self.prepared.leases[active].?;
        prior = &lease.owned;
        const live = try control.layerProgramObservation(lease.program);
        const origin = lease.owned.desc.anchor;
        // The immutable installation anchor remains original. An authenticated
        // all-layer continuity phase may advance effective epochs while this
        // exact program retains its live cursors and source-clock progress.
        // Require the same current publication used for this request; the loop
        // below separately proves each exact program/revision cursor binding.
        if (live.state != .active or live.group.paused or request.execute_frame < live.group.frame or live.group.frame <= origin.install_frame or live.group.mutation_epoch != request.mutation_epoch or live.group.transport_epoch != request.transport_epoch or live.group.generation != origin.bank_generation) return error.StaleBinding;
        // Success receipts can precede the next coherent group publication.
        // Require positive evidence of this generation; zero is not by itself
        // proof that a shorter sibling has emitted its endpoint.
        var observed_elapsed: ?u64 = null;
        for (self.bindings) |binding| {
            if (binding.ordinal >= live.group.layer_count) return error.StaleBinding;
            const layer = live.group.layers[binding.ordinal];
            if (layer.automation_generation == lease.program.generation and layer.automation_revision == origin.binding_revision) {
                if (observed_elapsed) |value| if (value != layer.automation_elapsed) return error.StaleBinding;
                observed_elapsed = layer.automation_elapsed;
            }
        }
        const source_elapsed = observed_elapsed orelse return error.StaleBinding;
        const future = request.execute_frame - live.group.frame;
        for (self.bindings, 0..) |binding, i| {
            const layer = live.group.layers[binding.ordinal];
            if (layer.automation_generation == lease.program.generation and layer.automation_revision == origin.binding_revision) {
                elapsed[i] = std.math.add(u64, source_elapsed, future) catch return error.UnsafeFrameRange;
            } else if (layer.automation_generation == 0 and source_elapsed > lease.owned.desc.tracks[i].source_endpoint) {
                elapsed[i] = lease.owned.desc.tracks[i].source_endpoint;
            } else return error.StaleBinding;
        }
    }
    if (resume_suffix) {
        prior = &self.prepared.suspended.?.owned;
        elapsed = self.prepared.suspended.?.elapsed;
    } else if (rebase != null) {
        // Seek/loop rebase interprets every target under the new source clock.
        prior = null;
        @memset(changed[0..self.bindings.len], true);
    }
    var track_requests: [16]span_compile.TrackRequest = undefined;
    for (self.bindings, 0..) |binding, i| {
        if (binding.ordinal >= observation.layer_count) return error.InvalidBinding;
        var from = observation.layers[binding.ordinal].gain;
        if (prior) |old| {
            const track = old.desc.tracks[i];
            from = predictedPrepared(track, old.desc.spans[track.spans.first..][0..track.spans.count], elapsed[i]);
        }
        track_requests[i] = .{ .ordinal = binding.ordinal, .stable_layer_id = binding.layer.key.id, .from = from, .to = targets[i].gain, .duration = if (changed[i]) (if (targets[i].gain >= from) targets[i].ramps.attack else targets[i].ramps.release) else .{ .frames = 0 } };
    }
    const usage = self.preparedUsage();
    if (usage.total_retained_bytes > usage.metadata_limit) return error.LayerProgramBudgetExceeded;
    var owned = try span_compile.compileWithHeapBudget(self.allocator, anchor, track_requests[0..self.bindings.len], request.musical, self.prepared.profile, usage.metadata_limit - usage.total_retained_bytes);
    var own_compile = true;
    defer if (own_compile) owned.deinit();
    if (prior) |old| try carrySuffix(self, &owned, old, changed, elapsed);
    const program = if (rebase) |value| try control.prepareLayerProgramRebased(self.allocator, owned.desc, value) else try control.prepareLayerProgram(self.allocator, owned.desc);
    self.prepared.rollback = .{ .program = program, .owned = owned };
    own_compile = false;
    var commands: [4]runtime.ScheduledCommand = undefined;
    var count: usize = 0;
    if (rebase) |value| {
        if (value.resume_group) {
            commands[count] = .{ .identity = preparedIdentity(self, request, count + 1), .payload = .{ .group_pause = .{ .group = self.instance.group, .paused = false, .next_transport_epoch = value.next_transport_epoch } } };
            count += 1;
        }
        if (value.seek) |cursor| {
            commands[count] = .{ .identity = preparedIdentity(self, request, count + 1), .payload = .{ .group_seek = .{ .group = self.instance.group, .cursor = cursor } } };
            count += 1;
        }
        if (value.loop_change != .unchanged) {
            const loop: ?runtime.music_group.Loop = if (value.loop_change == .set) .{ .start = value.loop_change.set.start, .end = value.loop_change.set.end } else null;
            commands[count] = .{ .identity = preparedIdentity(self, request, count + 1), .payload = .{ .group_loop = .{ .group = self.instance.group, .loop = loop } } };
            count += 1;
        }
    }
    const install_command = count + 1;
    commands[count] = .{ .identity = preparedIdentity(self, request, install_command), .payload = .{ .group_layer_automation = .{ .group = self.instance.group, .program = program, .expected_previous = request.expected_previous } } };
    count += 1;
    const end = std.math.add(u64, request.execute_frame, 1) catch {
        try preparedRollback(self, control);
        return error.UnsafeFrameRange;
    };
    const total = std.math.add(u64, self.submitted_commands, count) catch {
        try preparedRollback(self, control);
        return error.UnsafeFrameRange;
    };
    const handle = control.prepareSchedule(request.execute_frame, end, commands[0..count]) catch |err| {
        try preparedRollback(self, control);
        return err;
    };
    self.prepared.rollback.?.handle = handle;
    control.submitSchedule(handle) catch |err| {
        try preparedRollback(self, control);
        return err;
    };
    self.prepared.leases[free] = .{ .program = program, .owned = owned, .handle = handle, .install_command = install_command, .targets = targets };
    self.prepared.rollback = null;
    self.prepared.pending = free;
    for (self.states[0..self.bindings.len], 0..) |*state_value, i| {
        state_value.desired = targets[i];
        state_value.pending = targets[i];
    }
    self.last_input_order = request.input_order;
    self.last_plan_id = request.plan_id;
    self.submitted_commands = total;
    return .{ .scheduled = .{ .handle = handle, .program = program, .commands = @intCast(count), .tracks = @intCast(owned.desc.tracks.len), .spans = @intCast(owned.desc.spans.len) } };
}
fn preparedRollback(self: *LayerController, control: anytype) Error!void {
    const rollback = if (self.prepared.rollback) |*value| value else return;
    if (rollback.handle) |handle| {
        if (try control.scheduleResult(handle) == null) {
            const intent = try control.cancelSchedule(.{ .target = handle, .requested_frame = 0 });
            std.debug.assert(intent == null);
            self.hook(.after_rollback_cancel);
        }
        try control.releaseSchedule(handle);
        rollback.handle = null;
    }
    if (rollback.program) |program| {
        try control.releaseLayerProgram(program);
        rollback.program = null;
    }
    if (rollback.owned) |*owned| owned.deinit();
    self.prepared.rollback = null;
}
fn preparedStop(self: *LayerController, control: anytype, request: PreparedRequest) Error!scheduler.Handle {
    try preparedCheck(self, request);
    try preparedChanging(self, request);
    if (self.prepared.pending != null or self.prepared.stop != null) return error.PendingAutomation;
    const program = self.preparedProgram() orelse return error.NoPendingAutomation;
    if (!std.meta.eql(request.expected_previous, @as(?prepared_spans.ProgramHandle, program))) return error.StaleBinding;
    const observation = try control.musicVoiceObservation(self.instance.group);
    if (observation.source_incarnation != request.source_incarnation or observation.generation != request.bank_generation or observation.transport_epoch != request.transport_epoch or observation.mutation_epoch != request.mutation_epoch) return error.StaleBinding;
    const end = std.math.add(u64, request.execute_frame, 1) catch return error.UnsafeFrameRange;
    const total = std.math.add(u64, self.submitted_commands, 1) catch return error.UnsafeFrameRange;
    const handle = try control.prepareSchedule(request.execute_frame, end, &.{.{ .identity = preparedIdentity(self, request, 1), .payload = .{ .group_layer_automation_stop = .{ .group = self.instance.group, .program = program } } }});
    control.submitSchedule(handle) catch |err| {
        self.prepared.rollback = .{ .handle = handle };
        try preparedRollback(self, control);
        return err;
    };
    self.prepared.stop = .{ .handle = handle };
    self.last_input_order = request.input_order;
    self.last_plan_id = request.plan_id;
    self.submitted_commands = total;
    return handle;
}
fn preparedCancel(self: *LayerController, control: anytype, requested_frame: u64, fallback_: PreparedRequest) Error!?scheduler.Handle {
    try preparedCheck(self, fallback_);
    try preparedChanging(self, fallback_);
    if (self.prepared.cancel != null or self.prepared.stop != null) return error.PendingAutomation;
    const i = self.prepared.pending orelse self.prepared.active orelse return error.NoPendingAutomation;
    const lease = &self.prepared.leases[i].?;
    const handle = lease.handle orelse return error.NoPendingAutomation;
    const intent = try control.cancelSchedule(.{ .target = handle, .requested_frame = requested_frame });
    var fallback = fallback_;
    fallback.expected_previous = lease.program;
    fallback.musical = null; // Stop never retains or dereferences a caller map.
    self.prepared.cancel = .{ .program = lease.program, .handle = handle, .intent = intent, .fallback = fallback };
    return intent;
}
fn preparedPoll(self: *LayerController, control: anytype) Error!PreparedPoll {
    if (!self.prepared.enabled) return error.InvalidState;
    var result: PreparedPoll = self.prepared.unreported orelse .{};
    self.prepared.unreported = null;
    // Acquiring a receipt is durable even if a later owner/release call fails.
    // Keep the already-processed events until one successful poll returns them.
    errdefer self.prepared.unreported = result;
    if (self.prepared.cancel) |*cancel| {
        if (cancel.intent) |intent| {
            if (try control.cancellationResult(intent)) |done| {
                cancel.result = done.receipt;
                cancel.intent = null;
            }
        } else if (cancel.result == null) {
            if (try control.scheduleResult(cancel.handle)) |done| cancel.result = done.cancellation;
        }
    }
    // Stop references must retire before releasing the exact program owner.
    if (self.prepared.stop) |*stop| {
        const terminal = try control.scheduleResult(stop.handle);
        while (try control.pollExecutionReceipt(stop.handle, &stop.cursor)) |receipt| {
            result.receipts += 1;
            if (receipt.result == .success) result.successful += 1 else result.rejected += 1;
        }
        if (terminal) |done| {
            if (stop.cursor != done.count) return error.InvalidState;
            try control.releaseSchedule(stop.handle);
            self.prepared.stop = null;
            result.stop_complete = true;
        }
    }
    // Reconcile all installation receipts before old terminal metadata, so a
    // predecessor's superseded result cannot overwrite its successor's state.
    for (&self.prepared.leases, 0..) |*optional, i| if (optional.*) |*lease| {
        if (lease.install_complete) continue;
        const handle = lease.handle orelse return error.InvalidState;
        const terminal = try control.scheduleResult(handle);
        while (try control.pollExecutionReceipt(handle, &lease.cursor)) |receipt| {
            result.receipts += 1;
            if (receipt.result == .success) result.successful += 1 else result.rejected += 1;
            if (receipt.command_id != lease.install_command) continue;
            if (receipt.result != .success) lease.rejection = receipt.reason;
            if (receipt.result == .success) {
                lease.installed = true;
                self.prepared.active = i;
                self.instance.transport_epoch = lease.owned.desc.anchor.transport_epoch;
                self.instance.mutation_epoch = lease.owned.desc.anchor.mutation_epoch;
                for (self.states[0..self.bindings.len], 0..) |*state_value, j| {
                    state_value.effective = lease.targets[j];
                    state_value.effective_frame = receipt.executed_frame;
                    state_value.envelope = null;
                    state_value.last_reason = .none;
                    state_value.automation_terminal = null;
                }
                if (self.prepared.suspended) |*saved| saved.owned.deinit();
                self.prepared.suspended = null;
            } else {
                for (self.states[0..self.bindings.len]) |*state_value| state_value.last_reason = receipt.reason;
            }
        }
        const plan = try control.schedulePlan(handle);
        while (try control.pollPlanPhase(plan, &lease.phase_cursor)) |phase| {
            if (lease.phase != null) return error.InvalidState;
            lease.phase = phase;
        }
        self.hook(.after_receipt_drain);
        if (terminal) |done| {
            if (lease.cursor != done.count or (lease.installed and lease.phase == null)) return error.InvalidState;
            if (result.installation_count == result.installations.len) return error.InvalidState;
            result.installations[result.installation_count] = .{ .program = lease.program, .phase = lease.phase, .rejection = lease.rejection };
            result.installation_count += 1;
            lease.install_complete = true;
            result.install_complete = true;
            if (self.prepared.pending == i) {
                self.prepared.pending = null;
                for (self.states[0..self.bindings.len]) |*state_value| state_value.pending = null;
            }
        }
    };
    if (self.prepared.cancel) |cancel| {
        // A completed install cancellation is honestly too late. Only after
        // its receipt is reconciled may the exact program use reserved stop.
        if (cancel.result != null and self.prepared.pending == null) {
            if (cancel.result.?.result == .too_late and try control.layerProgramResult(cancel.program) == null) {
                var fallback = cancel.fallback;
                fallback.execute_frame = @max(fallback.execute_frame, try control.earliestPlanFrame());
                result.fallback_stop = try preparedStop(self, control, fallback);
            }
            result.cancellation = cancel.result;
            self.prepared.cancel = null;
        }
    }
    for (&self.prepared.leases, 0..) |*optional, i| if (optional.*) |*lease| {
        if (!lease.install_complete) continue;
        // Cancellation intent references have now been reconciled. Rejected
        // installations have no Render cursor: releasing their terminal block
        // publishes install_rejected before the durable result is queried.
        if (!lease.installed and self.prepared.cancel == null) if (lease.handle) |handle| {
            try control.releaseSchedule(handle);
            lease.handle = null;
        };
        if (lease.terminal == null) {
            const terminal = try control.layerProgramResult(lease.program) orelse continue;
            lease.terminal = .{ .program = terminal.program, .tracks = terminal.tracks, .track_count = terminal.track_count, .release_frontier = terminal.release_frontier };
        }
        const terminal = lease.terminal.?;
        if (!lease.terminal_reported) {
            result.automation_terminal = true;
            result.terminals[result.terminal_count] = terminal;
            result.terminal_count += 1;
            if (result.terminal == null or result.terminal.?.program.generation < terminal.program.generation) result.terminal = terminal;
            if (self.prepared.active == i) {
                self.prepared.active = null;
                for (self.states[0..self.bindings.len], 0..) |*state_value, j| {
                    const track = terminal.tracks[j];
                    state_value.automation_terminal = track;
                    state_value.effective.gain = @bitCast(track.gain_bits);
                    state_value.effective_frame = track.frame;
                    lease.save_suffix = lease.save_suffix or track.reason == .paused;
                }
            }
            lease.terminal_reported = true;
        }
        // Publication and reclamation are separate. Stop or future successor
        // references can keep terminal metadata retained after this event.
        if (self.prepared.stop != null or self.prepared.cancel != null) continue;
        if (lease.handle) |handle| {
            try control.releaseSchedule(handle);
            lease.handle = null;
        }
        control.releaseLayerProgram(lease.program) catch |err| {
            if (err == error.DrainPending) continue;
            return err;
        };
        if (lease.save_suffix) {
            if (self.prepared.suspended) |*saved| saved.owned.deinit();
            var saved: Suspended = .{ .owned = lease.owned, .targets = lease.targets };
            for (terminal.tracks[0..terminal.track_count], 0..) |track, j| saved.elapsed[j] = track.elapsed_source_frames;
            self.prepared.suspended = saved;
        } else lease.owned.deinit();
        optional.* = null;
    };
    return result;
}
