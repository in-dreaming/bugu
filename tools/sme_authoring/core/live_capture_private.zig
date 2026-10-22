//! Private actual Host binding data and passive producer facts. This module
//! does not own a Worker, invoke an engine, encode a tape, or qualify replay.
//! The real live_owner.Host implements the fixed registered adapter.
const std = @import("std");
const audio = @import("bugu_audio");
const music = audio.music;
const mailbox = @import("sme-author-live-mailbox");
const source = @import("sme-author-preview-v1").source;
pub const Owner = music.MusicRuntime;
pub const Binding = Owner.FinalizationTests;
pub const order = audio.runtime.capture_order;

pub const ControlCall = union(enum) {
    provider_create: struct { source_hash: [32]u8, source_bytes: usize },
    owner_create: music.MusicRuntimeConfigV1,
    startup_quiescence,
    bind,
    load: struct { source_hash: [32]u8, source_bytes: usize },
    poll_load: music.MusicLoadTicketV1,
    acknowledge_load: music.MusicLoadTicketV1,
    device_open: audio.device.DeviceConfig,
    device_start,
    play: struct { command: u64, bank: music.MusicBankRefV1, state: music.MusicStateId },
    stop: struct { command: u64, bank: music.MusicBankRefV1 },
    tick: struct { mode: enum { playback, chronology_cleanup, initial_cleanup }, limit: usize },
    receipt,
    snapshot,
    drain_status,
    shutdown,
    device_stop,
    final_quiescence,
    release_quiescence,
    cleanup_render: struct { frames: u32, channels: u16 },
    prepare: u64,
    finalize: struct { sequence: u64, nonce: u64 },
    destroy_empty: u64,
    destroy_unbound: u64,
    provider_release: source.Counts,
};
pub const ControlResult = union(enum) {
    done,
    owner_created: struct { context: u64 },
    failure: anyerror,
    quiescence: audio.RuntimeRenderer.DeviceQuiescence,
    load_ticket: music.MusicLoadTicketV1,
    load_status: music.MusicLoadStatusV1,
    request_ticket: music.MusicRequestTicketV1,
    output: ?audio.device.NegotiatedOutput,
    device_stopped: struct { state: audio.device.RuntimeDeviceState, output: ?audio.device.NegotiatedOutput },
    tick: Owner.LiveControlTickOutcomeV1,
    receipt: ?music.MusicRuntimeReceiptV1,
    snapshot: music.MusicRuntimeStatusV1,
    drain_status: music.MusicRuntimeDrainStatusV1,
    prepare: Binding.Outcome,
    destroyed: Binding.Report,
};
pub const ControlEntry = struct { call_id: u64, operation: ?u64, begin: ?order.EndpointReceipt, call: ControlCall };
pub const ControlEnd = struct { call_id: u64, operation: ?u64, end: ?order.EndpointReceipt, failed: bool };
pub const ControlEvent = union(enum) {
    enter: ControlEntry,
    result: struct { call_id: u64, operation: ?u64, value: ControlResult },
    end: ControlEnd,
    ready: struct { committed: bool },
    close_observed,
    worker_joined,
    boundary: struct { owner_alive: bool, control_torn_down: ?bool, phase: Binding.Session.Phase, report: ?Binding.Report },
    gate: struct { ordinal: u64, value: GateControl },
};
pub const GateControl = union(enum) {
    request: anyerror!u64,
    poll: struct { sequence: u64, parked: bool },
    resume_return: struct { sequence: u64, failure: ?anyerror },
    seal: struct { sequence: u64, nonce: u64, failure: ?anyerror },
    stop_empty: struct { sequence: u64, failure: ?anyerror },
};
pub const WorkerEvent = union(enum) {
    ready_acquired: struct { committed: bool },
    rejected_entry: struct { attempt: u64, failure: anyerror },
    enter: struct { operation: u64, begin: ?order.EndpointReceipt },
    result: struct { operation: u64, value: anyerror!Owner.LiveWorkerOutcomeV1 },
    end: struct { operation: u64, end: ?order.EndpointReceipt, failed: bool },
    gate: struct { ordinal: u64, value: GateWorker },
};
pub const GateWorker = union(enum) {
    action: anyerror!mailbox.WorkerGate.Action,
    acknowledgment: struct { sequence: u64, failure: ?anyerror },
    completed: ?anyerror,
    deferred: ?anyerror,
};
pub const RenderEvent = union(enum) {
    enter: struct { operation: u64, begin: ?order.EndpointReceipt, source: enum { callback, shutdown } },
    callback: struct { operation: u64, value: audio.RuntimeMiniaudioBackend.TestCallbackEvent },
    /// Borrowed only during this passive callback; the consumer must copy now.
    cleanup_pcm: struct { operation: u64, epoch: u64, first_frame: u64, channels: u16, samples: []const f32 },
    end: struct { operation: u64, end: ?order.EndpointReceipt, failed: bool },
};
pub const ControlSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, ControlEvent) void };
pub const WorkerSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, WorkerEvent) void };
pub const RenderSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, RenderEvent) void };
pub const Config = struct {
    roles: order.Roles,
    hooks: Binding.Hooks,
    control: ControlSink,
    worker: WorkerSink,
    render: RenderSink,
    tick: audio.runtime.ControlRuntime.LiveAcceptanceSinkV1,
    pcm: audio.RuntimeMiniaudioBackend.TestPcm,
};
pub const Session = struct {
    address: ?*Session = null,
    config: Config = undefined,
    host: ?*anyopaque = null,
    host_thread: ?std.Thread.Id = null,
    finalization: Binding.Session = .{},
    bootstrap: Owner.BootstrapTests.Session = .{},
    // Written before worker_ready release, then immutable through all joins.
    committed: bool = false,
    owner: ?*Owner = null,
    backend: ?*audio.RuntimeMiniaudioBackend = null,
    // Control-only lifetime and invocation state. Never used by Worker/callback.
    owner_alive: bool = false,
    quiescence: ?audio.RuntimeRenderer.DeviceQuiescence = null,
    sealed: ?Binding.Capability = null,
    engine_borrows_ended: bool = false,
    close_observed: bool = false,
    control_calls: u64 = 0,
    control_operations: u64 = 0,
    control_gate_events: u64 = 0,
    active_control: ?ControlEntry = null,
    tick_request: ?Binding.TickRequest = null,
    tick_in_progress: bool = false,
    empty_destroyed: bool = false,
    // Worker-only; Control may inspect these only after exact real Gate ACK.
    worker_gate_events: u64 = 0,
    worker_begin_attempts: u64 = 0,
    worker_end_attempts: u64 = 0,
    ack_end_attempts: u64 = 0,
    // Callback-only until backend.stop joins it, then Control's shutdown Render.
    render_operations: u64 = 0,
    render_active: bool = false,
    // One explicit deterministic precommit fault, used only by source tests.
    fail_before_commit: bool = false,

    pub fn init(self: *Session, config: Config) !void {
        if (self.address != null or !config.roles.pristine() or config.hooks.native == null or config.hooks.native.?.birth == null) return error.InvalidState;
        try config.hooks.validateInitial();
        self.* = .{ .address = self, .config = config };
    }
    pub fn beginControl(self: *Session, call: ControlCall) void {
        std.debug.assert(self.address == self and self.active_control == null);
        self.control_calls = std.math.add(u64, self.control_calls, 1) catch exhausted: {
            self.config.roles.control.invalidateSource();
            break :exhausted self.control_calls;
        };
        var operation: ?u64 = null;
        var receipt: ?order.EndpointReceipt = null;
        if (self.committed) {
            self.control_operations = std.math.add(u64, self.control_operations, 1) catch exhausted: {
                self.config.roles.control.invalidateSource();
                break :exhausted self.control_operations;
            };
            operation = self.control_operations;
            receipt = self.config.roles.control.beginReceipt(operation.?);
        }
        const entry: ControlEntry = .{ .call_id = self.control_calls, .operation = operation, .begin = receipt, .call = call };
        self.active_control = entry;
        self.config.control.emit(self.config.control.context, .{ .enter = entry });
    }
    pub fn resultControl(self: *Session, result: ControlResult) void {
        const entry = self.active_control.?;
        self.config.control.emit(self.config.control.context, .{ .result = .{ .call_id = entry.call_id, .operation = entry.operation, .value = result } });
    }
    pub fn endControl(self: *Session, failed: bool) void {
        const entry = self.active_control.?;
        std.debug.assert(!self.tick_in_progress and !self.finalization.tick_executing);
        const receipt = if (entry.operation != null) self.config.roles.control.endReceipt(@intFromBool(failed)) else null;
        self.config.control.emit(self.config.control.context, .{ .end = .{ .call_id = entry.call_id, .operation = entry.operation, .end = receipt, .failed = failed } });
        self.active_control = null;
    }
    pub fn controlGate(self: *Session, value: GateControl) void {
        self.control_gate_events = std.math.add(u64, self.control_gate_events, 1) catch exhausted: {
            self.config.roles.control.invalidateSource();
            break :exhausted self.control_gate_events;
        };
        self.config.control.emit(self.config.control.context, .{ .gate = .{ .ordinal = self.control_gate_events, .value = value } });
    }
    pub fn workerGate(self: *Session, value: GateWorker) void {
        self.worker_gate_events = std.math.add(u64, self.worker_gate_events, 1) catch exhausted: {
            self.config.roles.worker.invalidateSource();
            break :exhausted self.worker_gate_events;
        };
        self.config.worker.emit(self.config.worker.context, .{ .gate = .{ .ordinal = self.worker_gate_events, .value = value } });
    }
    pub fn beginRender(self: *Session, source_kind: @FieldType(@FieldType(RenderEvent, "enter"), "source")) void {
        std.debug.assert(!self.render_active);
        self.render_active = true;
        self.render_operations = std.math.add(u64, self.render_operations, 1) catch exhausted: {
            self.config.roles.render.invalidateSource();
            break :exhausted self.render_operations;
        };
        const receipt = self.config.roles.render.beginReceipt(self.render_operations);
        self.config.render.emit(self.config.render.context, .{ .enter = .{ .operation = self.render_operations, .begin = receipt, .source = source_kind } });
    }
    pub fn endRender(self: *Session, failed: bool) void {
        std.debug.assert(self.render_active);
        const receipt = self.config.roles.render.endReceipt(@intFromBool(failed));
        self.config.render.emit(self.config.render.context, .{ .end = .{ .operation = self.render_operations, .end = receipt, .failed = failed } });
        self.render_active = false;
    }
    pub fn callback(raw: *anyopaque, value: audio.RuntimeMiniaudioBackend.TestCallbackEvent) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (value == .enter) self.beginRender(.callback);
        self.config.render.emit(self.config.render.context, .{ .callback = .{ .operation = self.render_operations, .value = value } });
        if (value == .returned) self.endRender(value.returned.kind != .completed or value.returned.failure != null);
    }
};
