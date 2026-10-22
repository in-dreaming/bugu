//! Production, output-only semantic observation of the actual author Live Host.
//! No test capture, diagnostic collector, expected result, replay driver, or
//! cleanup capability is reachable through the capture interface. Capture
//! callbacks synchronously make bounded owned copies, with no allocation, IO,
//! locks, waiting, reentry or retries. Explicit replay callbacks may coordinate
//! replay-owned threads at these boundaries, never return expected outcomes.
//! Capture failure invalidates evidence, never native work.
const std = @import("std");
const audio = @import("bugu_audio");
const music = audio.music;
const mailbox = @import("sme-author-live-mailbox");
const source = @import("sme-author-preview-v1").source;
pub const Owner = music.MusicRuntime;
pub const Identity = struct {
    epoch: u64,
    document_id: u64,
    revision: u64,
    draft_hash: [32]u8,
    artifact_hash: [32]u8,
    state: music.MusicStateId,
};
pub const Command = struct { id: u64, identity: Identity, kind: mailbox.CommandKind, slot: u8, device_epoch: u64 };
/// UI inputs and outcomes are copied by value. No Host, reservation, queue or
/// runtime pointer is observable through this interface. Operation tags and
/// native errors are semantic values, not a promised wire representation.
pub const UiOperation = enum { submit, pop_event, acknowledge_terminal, request_close };
pub const UiCall = union(UiOperation) {
    submit: struct { identity: Identity, kind: mailbox.CommandKind },
    pop_event,
    acknowledge_terminal: u64,
    request_close: u64,
};
pub const UiMailboxEvent = struct {
    command: Command,
    kind: enum { accepted, terminal },
    receipt: ?music.MusicRuntimeReceiptV1,
    terminal: ?mailbox.Terminal,
    recovery: ?music.DeviceRecoveryV1.Status,
};
/// Comparison-only copies of actual returns. In particular, an actual empty
/// event poll and failed ACK are not permission to consume or release credits.
pub const UiResult = union(UiOperation) {
    submit: mailbox.Error!Command,
    pop_event: ?UiMailboxEvent,
    acknowledge_terminal: mailbox.Error!void,
    request_close: mailbox.Error!void,
};
pub const UiEvent = union(enum) {
    enter: struct { call_id: u64, call: UiCall },
    end: struct { call_id: u64, value: UiResult },
};
pub const UiSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, UiEvent) void };
pub const TickMode = enum { playback, chronology_cleanup, initial_cleanup };
pub const ControlCall = union(enum) {
    provider_create: struct { source_hash: [32]u8, source_bytes: usize },
    owner_create: music.MusicRuntimeConfigV1,
    bind_output,
    bind_live,
    startup_quiescence,
    bind_audio,
    release_quiescence,
    load: struct { source_hash: [32]u8, source_bytes: usize },
    poll_load: music.MusicLoadTicketV1,
    acknowledge_load: music.MusicLoadTicketV1,
    device_open: audio.device.DeviceConfig,
    device_start,
    play: struct { command: u64, bank: music.MusicBankRefV1, state: music.MusicStateId },
    stop: struct { command: u64, bank: music.MusicBankRefV1 },
    tick: struct { mode: TickMode, limit: usize },
    receipt,
    snapshot,
    drain_status,
    shutdown,
    device_stop,
    cleanup_render: struct { frames: u32, channels: u16 },
    destroy_unbound: u64,
    provider_release: source.Counts,
    final_quiescence,
    detach_audio,
    stop_progress,
};
pub const ControlResult = union(enum) {
    done,
    owner_created: struct { context: u64 },
    failure: anyerror,
    quiescence: struct { incarnation: u64 },
    load_ticket: music.MusicLoadTicketV1,
    load_status: music.MusicLoadStatusV1,
    request_ticket: music.MusicRequestTicketV1,
    output: ?audio.device.NegotiatedOutput,
    device_stopped: struct { state: audio.device.RuntimeDeviceState, output: ?audio.device.NegotiatedOutput },
    cleanup_render: audio.device.RuntimeAccounting,
    tick: Owner.LiveControlTickOutcomeV1,
    receipt: ?music.MusicRuntimeReceiptV1,
    snapshot: music.MusicRuntimeStatusV1,
    drain_status: music.MusicRuntimeDrainStatusV1,
    destroyed: @typeInfo(@typeInfo(@TypeOf(Owner.destroyQuiescent)).@"fn".return_type.?).error_union.payload,
    stop_progress: music.MusicRuntimeStopProgressV1,
};
pub const GateControl = union(enum) {
    request_begin,
    request: anyerror!u64,
    poll_begin: u64,
    poll: struct { sequence: u64, parked: bool },
    resume_begin: u64,
    resume_return: struct { sequence: u64, failure: ?anyerror },
    stop_begin: u64,
    stop_return: struct { sequence: u64, failure: ?anyerror },
};
pub const ControlEvent = union(enum) {
    started: struct { thread: u64, identity: Identity, config: music.MusicRuntimeConfigV1, device: audio.device.DeviceConfig },
    enter: struct { call_id: u64, call: ControlCall },
    result: struct { call_id: u64, value: ControlResult },
    end: struct { call_id: u64, failed: bool },
    ready: struct { attached: bool },
    command_dequeue_attempt,
    command_dequeued: ?Command,
    command_emitted: struct { command: Command, kind: enum { accepted, terminal }, receipt: ?music.MusicRuntimeReceiptV1, terminal: ?mailbox.Terminal },
    close_poll,
    close_polled: bool,
    close_observed,
    gate: GateControl,
    worker_join_begin,
    worker_joined,
    closed,
    returned,
    /// Emitted by the joining UI only after the actual Control thread join.
    control_joined,
};
pub const WorkerEvent = union(enum) {
    started: u64,
    ready_acquired,
    startup_aborted,
    gate_poll,
    enter: u64,
    result: struct { call_id: u64, value: anyerror!Owner.LiveWorkerOutcomeV1 },
    end: struct { call_id: u64, failed: bool },
    gate: union(enum) {
        action: anyerror!mailbox.WorkerGate.Action,
        acknowledgment_begin: u64,
        acknowledgment: struct { sequence: u64, failure: ?anyerror },
        completion_begin: struct { call_id: u64, deferred: bool },
        completed: struct { call_id: u64, deferred: bool, failure: ?anyerror },
    },
    returned,
};
pub const ControlSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, ControlEvent) void };
pub const WorkerSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, WorkerEvent) void };
pub const Config = struct {
    output: Owner.SemanticOutputSinkV1,
    service: audio.runtime.streaming.stream.LiveSemanticHooks,
    audio: audio.device.SemanticAudioSink,
    acceptance: audio.ControlRuntime.LiveAcceptanceSinkV1,
    source: source.SemanticSink,
    control: ControlSink,
    worker: WorkerSink,
    /// One non-reentrant UI producer, separate from Control/Worker/Render.
    /// A null sink preserves existing observers without a UI transcript.
    ui: ?UiSink = null,
    /// Immutable from native Mailbox construction through Host destruction.
    /// Capture observes actual availability cuts; callbacks cannot supply loads.
    mailbox: ?mailbox.Observer = null,
    /// Fixed native park/progress protocol, observed without changing atomics.
    worker_gate: ?mailbox.WorkerGateObserver = null,
    context: *anyopaque,
    invalidate: *const fn (*anyopaque) void,
};
/// Caller initializes in final storage and lends the immutable config/context
/// through Host.destroy, after both actual native joins. The same designated UI
/// owner must finish its calls before destroy and exclude future calls before
/// sealing a UI sink. A result hook never runs after destruction of its Host.
/// No observer health flag is consulted to decide native UI work or ownership.
pub const Session = struct {
    address: ?*Session = null,
    /// Immutable for the entire borrowed Host lifetime.
    mode: enum { capture, replay } = .capture,
    config: Config = undefined,
    host: ?*anyopaque = null,
    used: bool = false,
    poisoned: std.atomic.Value(bool) = .init(false),
    // Control-owned attachment/call state. Worker only reads pinned config.
    live_attached: bool = false,
    audio_attached: bool = false,
    close_observed: bool = false,
    control_calls: u64 = 0,
    active_control: ?u64 = null,
    // Worker-owned through its actual join.
    worker_calls: u64 = 0,
    // UI-only, non-reentrant observation state. Never inspected by Control.
    ui_calls: u64 = 0,
    active_ui: ?struct { call_id: u64, operation: UiOperation } = null,

    pub fn init(self: *Session, config: Config) !void {
        if (self.address != null or config.service.clock != null or config.service.consume != null or config.audio.wait_callback != null) return error.InvalidState;
        self.* = .{ .address = self, .config = config };
    }
    /// Offline-only constructor. A pinned, initially valid clock is mandatory;
    /// the Host additionally requires its genuine null backend. This separate
    /// entry never makes capture callbacks blocking or changes capture failure.
    pub fn initReplay(self: *Session, config: Config) !void {
        if (self.address != null) return error.InvalidState;
        const clock = config.service.clock orelse return error.InvalidState;
        try clock.validateInitial();
        self.* = .{ .address = self, .mode = .replay, .config = config };
    }
    pub fn pristine(self: *const Session) bool {
        return self.address == self and self.host == null and !self.used and !self.poisoned.load(.acquire) and
            self.control_calls == 0 and self.worker_calls == 0 and self.active_control == null and
            self.ui_calls == 0 and self.active_ui == null and
            !self.live_attached and !self.audio_attached and
            (if (self.mode == .capture) self.config.service.clock == null and self.config.service.consume == null and self.config.audio.wait_callback == null else self.config.service.clock != null and self.config.service.clock.?.address == self.config.service.clock.? and !self.config.service.clock.?.failed.load(.acquire));
    }
    pub fn poison(self: *Session) void {
        if (!self.poisoned.swap(true, .acq_rel)) {
            // Recorded clock inputs cease before the callback releases offline
            // waits. Genuine native cleanup cannot be held by a failed tape.
            if (self.mode == .replay) if (self.config.service.clock) |clock| clock.abort();
            self.config.invalidate(self.config.context);
        }
    }
    pub fn emitControl(self: *Session, event: ControlEvent) void {
        self.config.control.emit(self.config.control.context, event);
    }
    pub fn emitWorker(self: *Session, event: WorkerEvent) void {
        self.config.worker.emit(self.config.worker.context, event);
    }
    /// A missing token means observation is disabled or invalid, never that the
    /// caller may skip its native operation. Capture callbacks cannot reenter.
    pub fn beginUi(self: *Session, call: UiCall) ?u64 {
        const sink = self.config.ui orelse return null;
        if (self.active_ui != null or self.ui_calls == std.math.maxInt(u64)) {
            self.poison();
            return null;
        }
        self.ui_calls += 1;
        const call_id = self.ui_calls;
        self.active_ui = .{ .call_id = call_id, .operation = std.meta.activeTag(call) };
        sink.emit(sink.context, .{ .enter = .{ .call_id = call_id, .call = call } });
        return call_id;
    }
    pub fn endUi(self: *Session, call_id: u64, value: UiResult) void {
        const sink = self.config.ui orelse return;
        const active = self.active_ui orelse {
            self.poison();
            return;
        };
        if (call_id != active.call_id or std.meta.activeTag(value) != active.operation) {
            self.poison();
            return;
        }
        // Retain the active bracket through the callback to detect forbidden
        // observer reentry; the observer can neither replace nor return value.
        sink.emit(sink.context, .{ .end = .{ .call_id = call_id, .value = value } });
        self.active_ui = null;
    }
    pub fn beginControl(self: *Session, call: ControlCall) void {
        if (self.active_control != null or self.control_calls == std.math.maxInt(u64)) {
            self.poison();
            return;
        }
        self.control_calls += 1;
        self.active_control = self.control_calls;
        self.emitControl(.{ .enter = .{ .call_id = self.control_calls, .call = call } });
    }
    pub fn resultControl(self: *Session, value: ControlResult) void {
        const id = self.active_control orelse {
            self.poison();
            return;
        };
        self.emitControl(.{ .result = .{ .call_id = id, .value = value } });
    }
    pub fn endControl(self: *Session, failed: bool) void {
        const id = self.active_control orelse {
            self.poison();
            return;
        };
        self.emitControl(.{ .end = .{ .call_id = id, .failed = failed } });
        self.active_control = null;
    }
    pub fn beginWorker(self: *Session) u64 {
        if (self.worker_calls == std.math.maxInt(u64)) {
            self.poison();
            return 0;
        }
        self.worker_calls += 1;
        self.emitWorker(.{ .enter = self.worker_calls });
        return self.worker_calls;
    }
};
