//! App-specific, immutable four-stream author audition. No offline pump is used.
//! Public methods are UI-only; runtime pointers are exclusively Control-owned.
const std = @import("std");
pub const audio = @import("bugu_audio");
const music = audio.music;
pub const admission = @import("sme-author-live-admission");
pub const mailbox = @import("sme-author-live-mailbox");
pub const source = @import("sme-author-preview-v1").source;
pub const semantic = @import("live_semantic.zig");
pub const semantic_recording = @import("live_semantic_recording.zig");
pub const semantic_file = @import("live_semantic_file.zig");
pub const semantic_replay = @import("live_semantic_replay.zig");
// PageAllocator has no unsynchronized per-instance allocation bookkeeping; its
// mappings may be allocated/freed by Control and the fixed Worker concurrently.
const default_allocator = std.heap.page_allocator;
pub const TestAllocator = std.heap.DebugAllocator(.{ .thread_safe = true, .enable_memory_limit = true });
var next_epoch = std.atomic.Value(u64).init(1);
pub const Identity = semantic.Identity;
pub const Launch = struct {
    document_id: u64,
    revision: u64,
    draft_hash: [32]u8,
    state: music.MusicStateId,
    compiled: []const u8,
    config: music.MusicRuntimeConfigV1 = admission.default_config,
};
pub const TestSetup = struct { context: *anyopaque, call: *const fn (*anyopaque, *music.MusicRuntime) void };
pub const TestCapture = if (@import("builtin").is_test) @import("live_capture_private.zig") else struct {};
pub const TestTickOutcome = struct { context: *anyopaque, call: *const fn (*anyopaque, music.MusicRuntime.LiveControlTickOutcomeV1) void };
/// Passive test observation of one existing wait invocation. Role-local pair
/// and burst identifiers belong to the test collector, with explicit overflow.
/// An after edge reports return from the existing catch, not successful sleep.
pub const PacingMode = semantic.PacingMode;
/// One consumer resets before checking real work; any producer may notify.
/// A notification is a persistent hint, never an engine readiness result.
pub const WakeSignal = struct {
    event: std.Io.Event = .unset,
    pub fn beginTurn(self: *WakeSignal) void {
        // std.Event.reset is a monotonic store. Consume any earlier release
        // notification and keep subsequent real work checks after this clear.
        // Only the sole consumer calls this, with no wait still in flight.
        _ = @atomicRmw(std.Io.Event, &self.event, .Xchg, .unset, .acquire);
    }
    pub fn notify(self: *WakeSignal, io: std.Io) void {
        self.event.set(io);
    }
    pub fn wait(self: *WakeSignal, io: std.Io, milliseconds: u8) void {
        // Do not reset here: work-to-wait notifications must remain pending.
        self.event.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => {
                // Preserve bounded pacing under cancellation, then allow the
                // consumer's normal lifecycle checks to decide its next step.
                const previous = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(previous);
                std.Io.sleep(io, .fromMilliseconds(milliseconds), .awake) catch {};
            },
        };
    }
};
pub const TestWaitPoint = struct {
    mode: PacingMode = .legacy_poll,
    role: enum { control, worker },
    edge: enum { before, after },
    reason: enum { startup, burst_budget, claim_deferred, park, gate_error, control_turn },
    calls: u8 = 0,
    /// Normal workerStep returns of true; never the catch fallback.
    worked: u8 = 0,
    /// workerStep errors only, not gate/ack errors or ordinary false returns.
    failed: u8 = 0,
    deferred: bool = false,
    requested_ms: u8,
};
pub const TestWaitObserver = struct { context: *anyopaque, call: *const fn (*anyopaque, TestWaitPoint) void };
const WaitProgress = struct {
    value: if (@import("builtin").is_test) TestWaitPoint else void = if (@import("builtin").is_test) .{ .role = .worker, .edge = .before, .reason = .burst_budget, .requested_ms = 1 } else {},
    inline fn reason(self: *WaitProgress, value: @FieldType(TestWaitPoint, "reason")) void {
        if (comptime @import("builtin").is_test) self.value.reason = value;
    }
    inline fn failed(self: *WaitProgress) void {
        if (comptime @import("builtin").is_test) self.value.failed += 1;
    }
    inline fn completed(self: *WaitProgress, worked: bool, deferred: bool) void {
        if (comptime @import("builtin").is_test) {
            // Exactly one update per returned call in the existing four-call loop.
            self.value.calls += 1;
            self.value.worked += @intFromBool(worked);
            self.value.deferred = self.value.deferred or deferred;
            if (deferred) self.value.reason = .claim_deferred;
        }
    }
};
pub const Options = struct {
    /// Borrowed thread-safe Io; must outlive both actual thread joins. Used only
    /// for synchronous waits, never async work or device callback execution.
    io: std.Io,
    /// Explicit production observer. Borrowed final storage and immutable config
    /// must outlive Host.destroy, including both real native producer joins.
    semantic: ?*semantic.Session = null,
    device: audio.device.DeviceConfig = .{},
    source_fault: source.Fault = .{},
    recovery: enum { close, restart_at_bar } = .close,
    test_pcm: if (@import("builtin").is_test) ?audio.RuntimeMiniaudioBackend.TestPcm else void = if (@import("builtin").is_test) null else {},
    /// Explicit test-only final device-output protection. Caller owns immutable
    /// configuration and callback-owned counters through actual Host.destroy.
    /// Not compatible with capture/replay; production has no storage or branch.
    test_output_safety: if (@import("builtin").is_test) ?*audio.RuntimeMiniaudioBackend.TestOutputSafety else void = if (@import("builtin").is_test) null else {},
    /// Read-only branch observation, with borrowed lifetime through both joins.
    test_callback_facts: if (@import("builtin").is_test) ?audio.RuntimeMiniaudioBackend.TestCallbackFacts else void = if (@import("builtin").is_test) null else {},
    /// Test-only setup before the release publication that admits Worker.
    /// Use this for immutable hooks that Worker reads through its real lifetime.
    test_before_worker: if (@import("builtin").is_test) ?TestSetup else void = if (@import("builtin").is_test) null else {},
    /// Control-only hook installation after Ready, before device open. The
    /// borrowed context must remain alive through both actual joins.
    test_setup: if (@import("builtin").is_test) ?TestSetup else void = if (@import("builtin").is_test) null else {},
    /// Test-only bounded observation of the exact returned tick value.
    test_tick_outcome: if (@import("builtin").is_test) ?TestTickOutcome else void = if (@import("builtin").is_test) null else {},
    /// Controlled cross-frame workload only. Bound before publication; caller
    /// owns bounded cancellation and context through real Host destruction.
    test_after_live_acceptance: if (@import("builtin").is_test) ?audio.ControlRuntime.TestAfterLiveAcceptance else void = if (@import("builtin").is_test) null else {},
    /// Explicit capture-only retry workload; immutable through actual joins.
    test_retry_workload: if (@import("builtin").is_test) ?audio.runtime.streaming.stream.TestRetryWorkload else void = if (@import("builtin").is_test) null else {},
    /// Test-only actual Worker polling delay; never changes Control or Audio.
    test_worker_wait_ms: if (@import("builtin").is_test) u8 else void = if (@import("builtin").is_test) 1 else {},
    /// Passive before/after wait callbacks. Install before threads start and
    /// retain through both joins; no waits, I/O, or engine access in callbacks.
    test_wait_observer: if (@import("builtin").is_test) ?TestWaitObserver else void = if (@import("builtin").is_test) null else {},
    test_capture: if (@import("builtin").is_test) ?*TestCapture.Session else void = if (@import("builtin").is_test) null else {},
    test_fault: enum { none, open, start_after_callback, loss_after_start, reopen_after_callback } = .none,
};
pub const Phase = enum { opening, ready, running, stopped, waiting_for_recovery, recovering, closing, destroying, provider_release, closed };
pub const ErrorSite = enum { none, provider_create, control_create, renderer_create, backend_init, worker_spawn, runtime_create, load_submit, load_poll, device_open, device_start, request_submit, control_tick, receipts, worker, loss, shutdown, device_stop, quiescent_drain, drain_status, destroy, provider_release };
pub const Status = struct {
    identity: Identity,
    phase: Phase = .opening,
    first_error: ?anyerror = null,
    first_error_site: ErrorSite = .none,
    error_render_frame: u64 = 0,
    error_callback_count: u64 = 0,
    error_control_tick: u64 = 0,
    live_tick_deferred: u64 = 0,
    last_live_defer: ?music.MusicRuntime.LiveTickDeferV1 = null,
    live_cold_start_deferred: u64 = 0,
    last_cold_start_defer: ?music.MusicRuntime.LiveColdStartDeferV1 = null,
    live_stop_deferred: u64 = 0,
    last_stop_defer: ?music.MusicRuntime.LiveStopDeferV1 = null,
    cleanup_error: ?anyerror = null,
    load_failure: ?music.MusicRuntimeFailureV1 = null,
    callback_sequence: u64 = 0,
    cleanup_render_sequence: u64 = 0,
    play_executed: bool = false,
    stop_executed: bool = false,
    worker_joined: bool = false,
    provider: source.Counts = .{},
    sample_leases: u64 = 0,
    live_instances: u64 = 0,
    lost_count: u64 = 0,
    reopen_count: u64 = 0,
    loss_observed: bool = false,
    loss_accepted: bool = false,
    recovery: ?music.DeviceRecoveryV1.Status = null,
    receipt_budget_saturated: u64 = 0,
    skipped_status: u64 = 0,
    worker_calls: u64 = 0,
    worker_deferred: u64 = 0,
    control_thread_id: u64 = 0,
    worker_thread_id: u64 = 0,
    destroy_attempts: u64 = 0,
    output: ?audio.device.NegotiatedOutput = null,
};
pub const Mailbox = mailbox.MailboxWithRecovery(Identity, music.MusicRuntimeReceiptV1, Status, music.DeviceRecoveryV1.Status);
const Pending = struct { command: Mailbox.Command, ticket: music.MusicRequestTicketV1 };
pub const Host = struct {
    allocator: std.mem.Allocator,
    launch_identity: Identity,
    bytes: []const u8,
    config: music.MusicRuntimeConfigV1,
    options: Options,
    channel: Mailbox,
    gate: mailbox.WorkerGate,
    control_thread: ?std.Thread = null,
    worker_thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    // Single-consumer persistent hints. Storage survives both actual joins.
    control_wake: WakeSignal = .{},
    worker_wake: WakeSignal = .{},
    worker_ready: std.atomic.Value(bool) = .init(false),
    startup_abort: std.atomic.Value(bool) = .init(false),
    worker_error: std.atomic.Value(u32) = .init(0),
    worker_calls: std.atomic.Value(u64) = .init(0),
    worker_deferred: std.atomic.Value(u64) = .init(0),
    worker_id: std.atomic.Value(u64) = .init(0),
    joined: bool = false,
    recovery_requested: std.atomic.Value(bool) = .init(false),
    test_loss_requested: if (@import("builtin").is_test) std.atomic.Value(bool) else void = if (@import("builtin").is_test) .init(false) else {},
    // Below here is accessed only by Control (Worker receives owner once through
    // worker_ready). UI must never inspect these even after requesting Close.
    provider: ?*source.Provider = null,
    control: ?*audio.ControlRuntime = null,
    renderer: ?*audio.RuntimeRenderer = null,
    owner: ?*music.MusicRuntime = null,
    backend: ?audio.RuntimeMiniaudioBackend = null,
    load_ticket: ?music.MusicLoadTicketV1 = null,
    bank: ?music.MusicBankRefV1 = null,
    pending: [8]?Pending = @splat(null),
    recovery_command: ?Mailbox.Command = null,
    serviced_loss_epoch: u64 = 0,
    terminal_stop_sent: bool = false,
    started: bool = false,
    start_attempted: bool = false,
    park_sequence: ?u64 = null,
    status: Status,
    operation: ErrorSite = .none,

    pub fn create(launch: Launch, options: Options) !*Host {
        return createInternal(default_allocator, launch, options);
    }
    /// Test-only concrete allocator type proves thread-safe configuration. Caller
    /// retains it through successful Host.destroy and may then detectLeaks.
    pub fn createWithTestAllocator(memory: *TestAllocator, launch: Launch, options: Options) !*Host {
        if (!@import("builtin").is_test) return error.TestOnly;
        return createInternal(memory.allocator(), launch, options);
    }
    fn createInternal(allocator: std.mem.Allocator, launch: Launch, options: Options) !*Host {
        if (options.device.sample_rate != 48_000 or options.device.channels != 2 or options.device.period_frames != 256 or options.device.output_layout_request != null) return error.UnsupportedDeviceConfiguration;
        if (!@import("builtin").is_test and (options.test_fault != .none or (options.device.backend == .null_backend and options.semantic == null))) return error.TestOnly;
        if (@import("builtin").is_test) if (options.test_worker_wait_ms != 1 and options.test_worker_wait_ms != 16) return error.InvalidState;
        if (@import("builtin").is_test) {
            if (options.test_output_safety != null or options.test_callback_facts != null) {
                if (options.semantic != null or options.test_capture != null) return error.InvalidState;
            }
            if (options.test_output_safety) |safety| try safety.validate();
        }
        if (@import("builtin").is_test) if (options.test_wait_observer != null and (options.semantic != null or options.test_capture != null)) return error.InvalidState;
        if (@import("builtin").is_test) if (options.test_retry_workload != null) {
            const session = options.semantic orelse return error.InvalidState;
            if (session.mode != .capture or options.device.backend != .null_backend or options.recovery != .close or options.test_after_live_acceptance != null) return error.InvalidState;
        };
        if (options.semantic) |session| {
            if (@import("builtin").is_test) if (session.config.service.test_retry_workload != null) return error.InvalidState;
            if (session.mode == .replay and options.device.backend != .null_backend) return error.UnsupportedDeviceConfiguration;
            if (!session.pristine() or options.recovery != .close or options.test_fault != .none or !std.meta.eql(options.source_fault, @as(source.Fault, .{}))) return error.InvalidState;
            if (@import("builtin").is_test) if (options.test_capture != null or options.test_before_worker != null or options.test_setup != null or options.test_tick_outcome != null or options.test_pcm != null or options.test_worker_wait_ms != 1) return error.InvalidState;
        }
        if (@import("builtin").is_test) if (options.test_capture) |capture| {
            if (capture.address != capture or capture.host != null or capture.committed or capture.control_calls != 0 or capture.owner != null or options.recovery != .close or
                options.test_before_worker != null or options.test_setup != null or options.test_tick_outcome != null or options.test_pcm != null or
                options.test_fault != .none or options.test_worker_wait_ms != 1) return error.InvalidState;
        };
        _ = try admission.validate(allocator, launch.compiled, launch.state, launch.config);
        const bytes = try allocator.dupe(u8, launch.compiled);
        errdefer allocator.free(bytes);
        var epoch = next_epoch.load(.acquire);
        while (true) {
            if (epoch == 0 or epoch == std.math.maxInt(u64)) return error.EpochExhausted;
            if (next_epoch.cmpxchgWeak(epoch, epoch + 1, .acq_rel, .acquire)) |observed| epoch = observed else break;
        }
        const id: Identity = .{ .epoch = epoch, .document_id = launch.document_id, .revision = launch.revision, .draft_hash = launch.draft_hash, .artifact_hash = hash(bytes), .state = launch.state };
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        const channel = try Mailbox.initObserved(id, if (options.semantic) |session| session.config.mailbox else null);
        const gate = try mailbox.WorkerGate.initObserved(epoch, if (options.semantic) |session| session.config.worker_gate else null);
        self.* = .{ .allocator = allocator, .launch_identity = id, .bytes = bytes, .config = launch.config, .options = options, .channel = channel, .gate = gate, .status = .{ .identity = id } };
        if (@import("builtin").is_test) {
            if (options.test_capture) |capture| {
                capture.host = self;
            }
        }
        errdefer {
            if (@import("builtin").is_test) {
                if (options.test_capture) |capture| {
                    capture.host = null;
                }
            }
        }
        if (options.semantic) |session| session.host = self;
        errdefer if (options.semantic) |session| {
            session.host = null;
        };
        // Use std.Thread's documented platform default stack, never 512 KiB.
        self.control_thread = try std.Thread.spawn(.{}, controlMain, .{self});
        return self;
    }
    /// Semantic owners use their pinned launch configuration. Existing semantic
    /// constructors and private capture retain polling; ordinary owners notify.
    pub fn pacingMode(self: *const Host) PacingMode {
        if (self.options.semantic) |session| return session.config.pacing;
        if (@import("builtin").is_test) if (self.options.test_capture != null) return .legacy_poll;
        return .notified_v1;
    }
    fn notifyControl(self: *Host) void {
        if (self.pacingMode() == .notified_v1) self.control_wake.notify(self.options.io);
    }
    fn notifyWorker(self: *Host) void {
        if (self.pacingMode() == .notified_v1) self.worker_wake.notify(self.options.io);
    }
    fn abortStartupWorker(self: *Host) void {
        self.startup_abort.store(true, .release);
        self.notifyWorker();
    }
    fn workerCompletedNotification(self: *Host, worked: bool) void {
        if (worked) self.notifyControl();
    }
    fn workerError(self: *Host, err: anyerror) void {
        // Worker is the sole writer. Preserve the original last-error store;
        // only the first error wakes Control, preventing persistent-error pingpong.
        const first = self.worker_error.load(.acquire) == 0;
        self.worker_error.store(@intFromError(err), .release);
        if (first) self.notifyControl();
    }
    pub fn identity(self: *const Host) Identity {
        return self.launch_identity;
    }
    pub fn submit(self: *Host, id: Identity, kind: mailbox.CommandKind) !Mailbox.Command {
        const session = self.options.semantic;
        const call_id = if (session) |value| value.beginUi(.{ .submit = .{ .identity = id, .kind = kind } }) else null;
        const command = self.channel.submit(id, kind) catch |err| {
            if (call_id) |seq| session.?.endUi(seq, .{ .submit = err });
            return err;
        };
        if (call_id) |seq| session.?.endUi(seq, .{ .submit = semanticCommand(command) });
        self.notifyControl();
        return command;
    }
    /// UI reads only copied status; Control revalidates at admission.
    pub fn requestRecovery(self: *Host, id: Identity, device_epoch: u64) !Mailbox.Command {
        if (!std.meta.eql(id, self.launch_identity)) return error.IdentityMismatch;
        if (device_epoch == 0) return error.InvalidEpoch;
        if (self.options.recovery != .restart_at_bar) return error.InvalidState;
        const snapshot = self.readStatus() orelse return error.ProgressPending;
        const recovery = snapshot.value.recovery orelse return error.InvalidState;
        if (recovery.device_epoch != device_epoch) return error.InvalidEpoch;
        if (snapshot.value.phase != .waiting_for_recovery or !snapshot.value.loss_accepted) return error.InvalidState;
        if (self.recovery_requested.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return error.ProgressPending;
        errdefer self.recovery_requested.store(false, .release);
        const command = try self.channel.submitRecovery(id, device_epoch);
        self.notifyControl();
        return command;
    }
    /// UI-safe test injection. Only Control ever accesses the backend.
    pub fn testRequestLoss(self: *Host) !void {
        if (@import("builtin").is_test) {
            // Unsupported semantic test injection must not let this UI caller
            // publish a Control-labelled mailbox observation concurrently.
            if (self.options.semantic) |session| session.poison();
            if (self.channel.closeRequested()) return error.AdmissionClosed;
            self.test_loss_requested.store(true, .release);
            self.notifyControl();
        } else return error.TestOnly;
    }
    pub fn requestClose(self: *Host, epoch: u64) !void {
        const session = self.options.semantic;
        const call_id = if (session) |value| value.beginUi(.{ .request_close = epoch }) else null;
        self.channel.requestClose(epoch) catch |err| {
            if (call_id) |seq| session.?.endUi(seq, .{ .request_close = err });
            return err;
        };
        if (call_id) |seq| session.?.endUi(seq, .{ .request_close = {} });
        self.notifyControl();
    }
    pub fn popEvent(self: *Host) ?Mailbox.Event {
        const session = self.options.semantic;
        const call_id = if (session) |value| value.beginUi(.pop_event) else null;
        const event = self.channel.popEvent();
        if (call_id) |seq| session.?.endUi(seq, .{ .pop_event = if (event) |value| semanticUiEvent(value) else null });
        if (event != null) self.notifyControl();
        return event;
    }
    pub fn acknowledgeTerminal(self: *Host, id: u64) !void {
        const session = self.options.semantic;
        const call_id = if (session) |value| value.beginUi(.{ .acknowledge_terminal = id }) else null;
        self.channel.acknowledgeTerminal(id) catch |err| {
            if (call_id) |seq| session.?.endUi(seq, .{ .acknowledge_terminal = err });
            return err;
        };
        if (call_id) |seq| session.?.endUi(seq, .{ .acknowledge_terminal = {} });
        self.notifyControl();
    }
    pub fn readStatus(self: *Host) ?mailbox.StatusCell(Status).Versioned {
        return self.channel.status.read();
    }
    pub fn isClosed(self: *Host) bool {
        return self.channel.closed();
    }
    pub fn acknowledgeClosed(self: *Host) !void {
        try self.channel.acknowledgeClosed();
    }
    /// Isolated custody tests exercise the same park/scope/resume helpers;
    /// they never fabricate an engine drain result in a real Host.
    pub const SnapshotBoundaryTests = if (@import("builtin").is_test) struct {
        pub fn initProbe(host: *Host, epoch: u64) !void {
            host.* = undefined;
            host.launch_identity.epoch = epoch;
            host.options = .{ .io = std.testing.io };
            host.control_wake = .{};
            host.worker_wake = .{};
            host.worker_error = .init(0);
            host.startup_abort = .init(false);
            host.worker_ready = .init(false);
            host.worker_id = .init(0);
            host.park_sequence = null;
            host.gate = try mailbox.WorkerGate.init(epoch);
            host.status.phase = .closing;
            host.status.cleanup_error = null;
        }
        pub fn startupWorker(host: *Host) void {
            host.workerMain();
        }
        pub fn abortStartup(host: *Host) void {
            host.abortStartupWorker();
        }
        pub fn completedNotification(host: *Host, worked: bool) void {
            host.workerCompletedNotification(worked);
        }
        pub fn errorNotification(host: *Host, err: anyerror) void {
            host.workerError(err);
        }
        pub fn inspect(host: *Host, comptime callback: fn (*Host) anyerror!bool) !void {
            return host.withParkedSnapshot(callback);
        }
        pub fn resumePending(host: *Host) !void {
            return host.resumeWorker();
        }
    } else struct {};
    pub const TestCaptureTests = if (@import("builtin").is_test) struct {
        /// Negative tests call only on the genuine Control thread after actual
        /// empty-owner free. No stop, clear, free or custody transition occurs.
        pub fn validateDestroyedEmpty(host: *Host) !void {
            return CaptureAdapter.validateDestroyedEmpty(host);
        }
    } else struct {};
    pub fn join(self: *Host) !void {
        if (!self.finished.load(.acquire)) return error.CleanupPending;
        if (!self.joined) {
            self.control_thread.?.join();
            self.control_thread = null;
            self.joined = true;
            // Final producer handoff: Control is genuinely joined, so this is
            // not a concurrent producer or a guessed finished/zero-drain fact.
            if (self.options.semantic) |session| session.emitControl(.control_joined);
        }
    }
    pub fn destroy(self: *Host) !void {
        if (!self.joined or !self.channel.allAcknowledged()) return error.CleanupPending;
        if (!self.channel.status.seal()) return error.ReadersPending;
        if (@import("builtin").is_test) {
            if (self.options.test_capture) |capture| {
                capture.host = null;
            }
        }
        if (self.options.semantic) |session| session.host = null;
        self.allocator.free(self.bytes);
        self.allocator.destroy(self);
    }
    fn fail(self: *Host, err: anyerror) void {
        if (self.options.semantic) |session| session.poison();
        self.finishRecovery(.failed) catch |failure| {
            self.status.cleanup_error = failure;
        };
        if (self.status.first_error == null) {
            self.status.first_error = err;
            self.status.first_error_site = self.operation;
        }
        self.channel.requestCloseFromControl(self.launch_identity.epoch) catch unreachable;
        if (self.status.phase != .destroying and self.status.phase != .provider_release) self.status.phase = .closing;
    }
    fn publish(self: *Host) bool {
        if (self.backend) |*backend| {
            self.status.lost_count = backend.lost_count;
            self.status.reopen_count = backend.reopen_count;
        }
        self.status.worker_calls = self.worker_calls.load(.acquire);
        self.status.worker_deferred = self.worker_deferred.load(.acquire);
        self.status.worker_thread_id = self.worker_id.load(.acquire);
        const err = self.worker_error.load(.acquire);
        if (err != 0) self.status.cleanup_error = @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(err)));
        if (self.channel.status.publish(self.status)) return true;
        self.status.skipped_status +|= 1;
        return false;
    }
    fn controlMain(self: *Host) void {
        self.status.control_thread_id = @intCast(std.Thread.getCurrentId());
        if (self.options.semantic) |session| {
            session.used = true;
            session.emitControl(.{ .started = .{ .thread = self.status.control_thread_id, .identity = self.launch_identity, .config = self.config, .device = self.options.device, .pacing = self.pacingMode() } });
        }
        if (@import("builtin").is_test) {
            if (self.options.test_capture) |capture| {
                capture.host_thread = std.Thread.getCurrentId();
            }
        }
        self.construct() catch |err| self.fail(err);
        while (true) {
            if (self.pacingMode() == .notified_v1) self.control_wake.beginTurn();
            self.turn() catch |err| {
                self.status.cleanup_error = err;
                self.finishRecovery(.failed) catch {};
                self.fail(err);
            };
            const published = self.publish();
            self.notifyWorker();
            if (self.status.phase == .closed and published) break;
            self.waitTurn();
        }
        self.channel.publishClosed() catch unreachable;
        if (self.options.semantic) |session| {
            session.emitControl(.closed);
            session.emitControl(.returned);
        }
        self.finished.store(true, .release);
    }
    fn CallPayload(comptime function: anytype) type {
        return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload;
    }
    fn playbackCall(call: semantic.ControlCall) bool {
        return switch (call) {
            .device_open, .device_start, .play, .stop => true,
            .tick => |args| args.mode == .playback,
            else => false,
        };
    }
    fn captureCall(self: *Host, call: semantic.ControlCall, comptime function: anytype, args: anytype) anyerror!CallPayload(function) {
        // A comparison failure can suppress only a subsequent offline playback
        // invocation. It never rewrites a call's already-computed return value
        // and never blocks the original native shutdown/destruction operations.
        if (self.replayFailed() and playbackCall(call)) return error.SemanticReplayAborted;
        if (@import("builtin").is_test) if (self.options.test_capture) |capture| {
            const legacy_call: TestCapture.ControlCall = switch (call) {
                inline else => |value, tag| if (@hasField(TestCapture.ControlCall, @tagName(tag))) legacyArgs(tag, value) else unreachable,
            };
            capture.beginControl(legacy_call);
            var failed = true;
            defer capture.endControl(failed);
            const value = @call(.auto, function, args) catch |err| {
                capture.resultControl(.{ .failure = err });
                return @as(anyerror!CallPayload(function), err);
            };
            const Payload = CallPayload(function);
            if (Payload == *music.MusicRuntime) capture.resultControl(.{ .owner_created = .{ .context = value.config.context } }) else if (Payload == music.MusicLoadTicketV1) capture.resultControl(.{ .load_ticket = value }) else if (Payload == music.MusicLoadStatusV1) capture.resultControl(.{ .load_status = value }) else if (Payload == music.MusicRequestTicketV1) capture.resultControl(.{ .request_ticket = value }) else if (Payload == music.MusicRuntime.LiveControlTickOutcomeV1) capture.resultControl(.{ .tick = value }) else if (Payload == ?music.MusicRuntimeReceiptV1) capture.resultControl(.{ .receipt = value }) else if (Payload == music.MusicRuntimeStatusV1) capture.resultControl(.{ .snapshot = value }) else if (Payload == music.MusicRuntimeDrainStatusV1) capture.resultControl(.{ .drain_status = value }) else if (Payload == audio.RuntimeRenderer.DeviceQuiescence) capture.resultControl(.{ .quiescence = value }) else {
                // Constructor pointers remain native custody; the actual
                // successful call and immutable constructor args identify it.
                if (call == .device_open) capture.resultControl(.{ .output = self.backend.?.output }) else capture.resultControl(.done);
            }
            failed = false;
            return value;
        };
        if (self.options.semantic) |session| {
            session.beginControl(call);
            var failed = true;
            defer session.endControl(failed);
            // The entry comparator itself may have rejected this invocation.
            // Suppress it before native effects, not after a computed return.
            if (self.replayFailed() and playbackCall(call)) {
                session.resultControl(.{ .failure = error.SemanticReplayAborted });
                return error.SemanticReplayAborted;
            }
            const value = @call(.auto, function, args) catch |err| {
                session.resultControl(.{ .failure = err });
                return @as(anyerror!CallPayload(function), err);
            };
            const Payload = CallPayload(function);
            if (Payload == *music.MusicRuntime) session.resultControl(.{ .owner_created = .{ .context = value.config.context } }) else if (Payload == music.MusicLoadTicketV1) session.resultControl(.{ .load_ticket = value }) else if (Payload == music.MusicLoadStatusV1) session.resultControl(.{ .load_status = value }) else if (Payload == music.MusicRequestTicketV1) session.resultControl(.{ .request_ticket = value }) else if (Payload == music.MusicRuntime.LiveControlTickOutcomeV1) session.resultControl(.{ .tick = value }) else if (Payload == ?music.MusicRuntimeReceiptV1) session.resultControl(.{ .receipt = value }) else if (Payload == music.MusicRuntimeStatusV1) session.resultControl(.{ .snapshot = value }) else if (Payload == music.MusicRuntimeStopProgressV1) session.resultControl(.{ .stop_progress = value }) else if (Payload == music.MusicRuntimeDrainStatusV1) session.resultControl(.{ .drain_status = value }) else if (Payload == audio.RuntimeRenderer.DeviceQuiescence) session.resultControl(.{ .quiescence = .{ .incarnation = value.incarnation } }) else {
                if (call == .device_open) session.resultControl(.{ .output = self.backend.?.output }) else if (call == .cleanup_render) session.resultControl(.{ .cleanup_render = self.backend.?.adapter.accounting() }) else session.resultControl(.done);
            }
            failed = false;
            return value;
        }
        return @call(.auto, function, args);
    }
    fn captureArgs(comptime kind: anytype, value: anytype) semantic.ControlCall {
        const Payload = @FieldType(semantic.ControlCall, @tagName(kind));
        if (@TypeOf(value) != Payload and @typeInfo(Payload) == .@"struct" and @typeInfo(@TypeOf(value)) == .@"struct") {
            comptime {
                if (std.meta.fields(Payload).len != std.meta.fields(@TypeOf(value)).len) @compileError("Actual Host call payload field count changed");
                for (std.meta.fields(Payload)) |field| if (!@hasField(@TypeOf(value), field.name)) @compileError("Actual Host call payload field set changed");
            }
            var typed: Payload = undefined;
            inline for (std.meta.fields(Payload)) |field| @field(typed, field.name) = @field(value, field.name);
            return @unionInit(semantic.ControlCall, @tagName(kind), typed);
        }
        return @unionInit(semantic.ControlCall, @tagName(kind), value);
    }
    fn legacyArgs(comptime kind: anytype, value: anytype) if (@import("builtin").is_test) TestCapture.ControlCall else void {
        if (@import("builtin").is_test) {
            const Payload = @FieldType(TestCapture.ControlCall, @tagName(kind));
            if (@TypeOf(value) != Payload and @typeInfo(Payload) == .@"struct" and @typeInfo(@TypeOf(value)) == .@"struct") {
                // Zig does not coerce a previously inferred anonymous struct.
                // Require the complete exact field set before copying each
                // actual value; no supplied or newly added field is discarded.
                comptime {
                    if (std.meta.fields(Payload).len != std.meta.fields(@TypeOf(value)).len)
                        @compileError("Actual Host call payload field count changed");
                    for (std.meta.fields(Payload)) |field| if (!@hasField(@TypeOf(value), field.name))
                        @compileError("Actual Host call payload field set changed");
                }
                var typed: Payload = undefined;
                inline for (std.meta.fields(Payload)) |field| {
                    if (@typeInfo(field.type) == .@"enum") @field(typed, field.name) = @enumFromInt(@intFromEnum(@field(value, field.name))) else @field(typed, field.name) = @field(value, field.name);
                }
                return @unionInit(TestCapture.ControlCall, @tagName(kind), typed);
            }
            return @unionInit(TestCapture.ControlCall, @tagName(kind), value);
        }
    }
    fn construct(self: *Host) !void {
        self.operation = .provider_create;
        self.provider = try self.captureCall(captureArgs(.provider_create, .{ .source_hash = self.launch_identity.artifact_hash, .source_bytes = self.bytes.len }), source.Provider.createObserved, .{ self.allocator, self.bytes, self.options.source_fault, if (self.options.semantic) |session| @as(?source.SemanticSink, session.config.source) else null });
        self.operation = .control_create;
        self.control = try audio.ControlRuntime.create(self.allocator);
        if (@import("builtin").is_test) self.control.?.test_after_live_acceptance = self.options.test_after_live_acceptance;
        self.operation = .renderer_create;
        self.renderer = try self.allocator.create(audio.RuntimeRenderer);
        self.renderer.?.* = audio.RuntimeRenderer.init(self.control.?, 48_000);
        self.operation = .backend_init;
        self.backend = try audio.RuntimeMiniaudioBackend.init(self.renderer.?, 256, 2);
        if (@import("builtin").is_test) {
            self.backend.?.test_pcm = self.options.test_pcm;
            self.backend.?.test_output_safety = self.options.test_output_safety;
            self.backend.?.test_callback_facts = self.options.test_callback_facts;
        }
        // Establish the one fixed Worker before owner creation: spawn failure
        // cannot strand an owner whose retirement requires a Worker.
        self.operation = .worker_spawn;
        self.worker_thread = try std.Thread.spawn(.{}, workerMain, .{self});
        self.operation = .runtime_create;
        self.owner = try self.captureCall(captureArgs(.owner_create, self.config), music.MusicRuntime.createV1, .{ self.allocator, self.control.?, self.renderer.?, self.config });
        if (@import("builtin").is_test) if (self.options.test_before_worker) |setup| setup.call(setup.context, self.owner.?);
        if (@import("builtin").is_test) if (self.options.test_capture) |capture| {
            CaptureAdapter.bind(self, capture) catch |err| {
                // Option A: exact precommit failure retains no engine borrow.
                // Release real startup Q before ordinary unbound cleanup and
                // publish ready once so its original Worker can retire owner.
                try CaptureAdapter.releaseFailed(self, capture);
                CaptureAdapter.ready(self, capture);
                return err;
            };
            // Load error after commit still releases the actual waiting Worker;
            // joined started-empty cleanup owns every retained component.
            defer CaptureAdapter.ready(self, capture);
            self.operation = .load_submit;
            self.load_ticket = try self.captureCall(captureArgs(.load, .{ .source_hash = self.launch_identity.artifact_hash, .source_bytes = self.bytes.len }), music.MusicRuntime.loadBankWithSources, .{ self.owner.?, self.bytes, self.provider.?.provider() });
            return;
        };
        if (self.options.semantic) |session| {
            // Observer failure poisons evidence only. Never strand the actual
            // Worker or make a capture failure request engine shutdown.
            self.bindSemantic(session);
        }
        self.worker_ready.store(true, .release);
        self.notifyWorker();
        if (self.options.semantic) |session| session.emitControl(.{ .ready = .{ .attached = session.live_attached and session.audio_attached } });
        self.operation = .load_submit;
        self.load_ticket = try self.captureCall(captureArgs(.load, .{ .source_hash = self.launch_identity.artifact_hash, .source_bytes = self.bytes.len }), music.MusicRuntime.loadBankWithSources, .{ self.owner.?, self.bytes, self.provider.?.provider() });
    }
    fn bindSemantic(self: *Host, session: *semantic.Session) void {
        const service_hooks = blk: {
            if (@import("builtin").is_test) {
                var hooks = session.config.service;
                hooks.test_retry_workload = self.options.test_retry_workload;
                break :blk hooks;
            }
            break :blk session.config.service;
        };
        self.captureCall(.bind_output, music.MusicRuntime.attachSemanticOutputSinkV1, .{ self.owner.?, session.config.output }) catch {
            session.poison();
            return;
        };
        if (session.mode == .replay) {
            self.captureCall(.bind_live, music.MusicRuntime.attachLiveSemanticReplayV1, .{ self.owner.?, service_hooks }) catch {
                session.poison();
                return;
            };
        } else self.captureCall(.bind_live, music.MusicRuntime.attachLiveSemanticV1, .{ self.owner.?, service_hooks }) catch {
            session.poison();
            return;
        };
        session.live_attached = true;
        const token = self.captureCall(.startup_quiescence, audio.RuntimeRenderer.acquireDeviceQuiescence, .{self.renderer.?}) catch {
            session.poison();
            return;
        };
        defer self.captureCall(.release_quiescence, audio.RuntimeRenderer.releaseDeviceQuiescence, .{ self.renderer.?, token }) catch {
            session.poison();
        };
        if (session.mode == .replay) {
            self.captureCall(.bind_audio, audio.RuntimeMiniaudioBackend.attachSemanticAudioReplayQuiescent, .{ &self.backend.?, session.config.audio, token }) catch {
                session.poison();
                return;
            };
        } else self.captureCall(.bind_audio, audio.RuntimeMiniaudioBackend.attachSemanticAudioQuiescent, .{ &self.backend.?, session.config.audio, token }) catch {
            session.poison();
            return;
        };
        session.audio_attached = true;
    }
    fn workerMain(self: *Host) void {
        self.worker_id.store(@intCast(std.Thread.getCurrentId()), .release);
        if (self.options.semantic) |session| session.emitWorker(.{ .started = @intCast(std.Thread.getCurrentId()) });
        defer if (self.options.semantic) |session| session.emitWorker(.returned);
        while (true) {
            if (self.pacingMode() == .notified_v1) self.worker_wake.beginTurn();
            if (self.worker_ready.load(.acquire)) break;
            if (self.startup_abort.load(.acquire)) {
                if (self.options.semantic) |session| session.emitWorker(.startup_aborted);
                return;
            }
            var startup_wait: WaitProgress = .{};
            startup_wait.reason(.startup);
            self.waitWorkerTurn(startup_wait);
        }
        // This pointer is never loaded or dereferenced again after a park ACK
        // until a matching resume. Terminal stop takes precedence over resume.
        const owner = self.owner.?;
        if (self.options.semantic) |session| session.emitWorker(.ready_acquired);
        if (@import("builtin").is_test) if (self.options.test_capture) |capture|
            capture.config.worker.emit(capture.config.worker.context, .{ .ready_acquired = .{ .committed = capture.committed } });
        var acknowledged: u64 = 0;
        while (true) {
            if (self.pacingMode() == .notified_v1) self.worker_wake.beginTurn();
            var wait_progress: WaitProgress = .{};
            for (0..4) |_| {
                if (self.options.semantic) |session| session.emitWorker(.gate_poll);
                const action = self.gate.workerAction(self.launch_identity.epoch) catch |err| {
                    if (@import("builtin").is_test) if (self.options.test_capture) |capture| capture.workerGate(.{ .action = err });
                    if (self.options.semantic) |session| session.emitWorker(.{ .gate = .{ .action = err } });
                    self.workerError(err);
                    wait_progress.reason(.gate_error);
                    break;
                };
                if (@import("builtin").is_test) if (self.options.test_capture) |capture| capture.workerGate(.{ .action = action });
                if (self.options.semantic) |session| session.emitWorker(.{ .gate = .{ .action = action } });
                switch (action) {
                    .stop => return,
                    .park => |seq| {
                        wait_progress.reason(.park);
                        if (seq != acknowledged) {
                            if (@import("builtin").is_test) {
                                if (self.options.test_capture) |capture| {
                                    capture.ack_end_attempts = capture.worker_end_attempts;
                                }
                            }
                            var failure: ?anyerror = null;
                            if (self.options.semantic) |session| session.emitWorker(.{ .gate = .{ .acknowledgment_begin = seq } });
                            self.gate.acknowledgePark(self.launch_identity.epoch, seq) catch |err| {
                                failure = err;
                                self.workerError(err);
                            };
                            // ACK may allow Control to free the engine now;
                            // this callback touches only retained role storage.
                            if (@import("builtin").is_test) if (self.options.test_capture) |capture| capture.workerGate(.{ .acknowledgment = .{ .sequence = seq, .failure = failure } });
                            if (self.options.semantic) |session| session.emitWorker(.{ .gate = .{ .acknowledgment = .{ .sequence = seq, .failure = failure } } });
                            if (failure == null) {
                                acknowledged = seq;
                                self.notifyControl();
                            }
                        }
                        break;
                    },
                    .work => {
                        var deferred = false;
                        const worked = self.workerStep(owner, &deferred) catch |err| blk: {
                            wait_progress.failed();
                            if (@import("builtin").is_test and self.worker_error.load(.acquire) == 0) {
                                std.debug.print("live Worker first error: {s}\n", .{@errorName(err)});
                                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                            }
                            self.workerError(err);
                            break :blk false;
                        };
                        wait_progress.completed(worked, deferred);
                        _ = self.worker_calls.fetchAdd(1, .release);
                        var completion_failure: ?anyerror = null;
                        if (self.options.semantic) |session| session.emitWorker(.{ .gate = .{ .completion_begin = .{ .call_id = session.worker_calls, .deferred = deferred } } });
                        if (deferred) {
                            self.gate.workerDeferred(self.launch_identity.epoch) catch |err| {
                                completion_failure = err;
                                self.workerError(err);
                            };
                        } else self.gate.workerCompleted(self.launch_identity.epoch) catch |err| {
                            completion_failure = err;
                            self.workerError(err);
                        };
                        if (@import("builtin").is_test) if (self.options.test_capture) |capture|
                            capture.workerGate(if (deferred) .{ .deferred = completion_failure } else .{ .completed = completion_failure });
                        if (self.options.semantic) |session| session.emitWorker(.{ .gate = .{ .completed = .{ .call_id = session.worker_calls, .deferred = deferred, .failure = completion_failure } } });
                        // Publish both the real work result and its gate progress
                        // before waking Control, still once per actual call.
                        self.workerCompletedNotification(worked);
                        // A failed initial Service claim did no job work. End
                        // this actual call before yielding to the usual sleep;
                        // don't spend the rest of this burst retrying its CAS.
                        if (deferred) break;
                    },
                }
            }
            self.waitWorkerTurn(wait_progress);
        }
    }
    fn workerStep(self: *Host, owner: *music.MusicRuntime, deferred: *bool) !bool {
        // Device-loss policy does not remove concurrent Control Service claims.
        // Every admitted live Host uses the same-call initial-claim defer;
        // later failures still propagate, and ordinary runtime APIs are unchanged.
        const outcome = if (@import("builtin").is_test and self.options.test_capture != null and self.options.test_capture.?.committed)
            try CaptureAdapter.worker(self, owner)
        else if (self.options.semantic) |session| observed: {
            const id = session.beginWorker();
            var failed = true;
            defer session.emitWorker(.{ .end = .{ .call_id = id, .failed = failed } });
            const value = owner.workerOneLiveV1() catch |err| {
                session.emitWorker(.{ .result = .{ .call_id = id, .value = err } });
                session.poison();
                return err;
            };
            session.emitWorker(.{ .result = .{ .call_id = id, .value = value } });
            failed = false;
            break :observed value;
        } else try owner.workerOneLiveV1();
        if (outcome.deferred != null) {
            deferred.* = true;
            _ = self.worker_deferred.fetchAdd(1, .release);
        }
        return outcome.worked;
    }
    fn observeWait(self: *Host, point: TestWaitPoint) void {
        if (comptime @import("builtin").is_test) if (self.options.test_wait_observer) |observer|
            observer.call(observer.context, point);
    }
    fn waitWorkerTurn(self: *Host, progress: WaitProgress) void {
        const milliseconds = if (@import("builtin").is_test) self.options.test_worker_wait_ms else 1;
        if (comptime @import("builtin").is_test) {
            var point = progress.value;
            point.requested_ms = milliseconds;
            point.mode = self.pacingMode();
            self.observeWait(point);
        }
        self.waitPaced(&self.worker_wake, milliseconds);
        if (comptime @import("builtin").is_test) {
            var point = progress.value;
            point.requested_ms = milliseconds;
            point.mode = self.pacingMode();
            point.edge = .after;
            self.observeWait(point);
        }
    }
    fn waitTurn(self: *Host) void {
        if (comptime @import("builtin").is_test) self.observeWait(.{ .mode = self.pacingMode(), .role = .control, .edge = .before, .reason = .control_turn, .requested_ms = 1 });
        self.waitPaced(&self.control_wake, 1);
        if (comptime @import("builtin").is_test) self.observeWait(.{ .mode = self.pacingMode(), .role = .control, .edge = .after, .reason = .control_turn, .requested_ms = 1 });
    }
    fn waitPaced(self: *Host, signal: *WakeSignal, milliseconds: u8) void {
        if (self.pacingMode() == .legacy_poll) {
            std.Io.sleep(self.options.io, .fromMilliseconds(milliseconds), .awake) catch {};
            return;
        }
        signal.wait(self.options.io, milliseconds);
    }
    fn replayFailed(self: *const Host) bool {
        const session = self.options.semantic orelse return false;
        return session.mode == .replay and session.poisoned.load(.acquire);
    }
    fn turn(self: *Host) !void {
        if (self.status.phase == .closed) return;
        if (self.replayFailed()) self.channel.requestCloseFromControl(self.launch_identity.epoch) catch unreachable;
        if (self.status.phase == .destroying) return self.destroyTurn();
        if (self.status.phase == .provider_release) return self.releaseTurn();
        if (self.owner == null) return self.releaseTurn();
        const owner = self.owner.?;
        const backend = &self.backend.?;
        if (@import("builtin").is_test) if (self.test_loss_requested.swap(false, .acq_rel)) {
            if (self.started) _ = backend.signalLost();
        };
        // Close is sticky and independent of command/event credits.
        if (self.closeRequestedObserved()) {
            if (self.options.semantic) |session| if (!session.close_observed) {
                session.close_observed = true;
                session.emitControl(.close_observed);
            };
            if (@import("builtin").is_test) if (self.options.test_capture) |capture| if (!capture.close_observed) {
                capture.close_observed = true;
                capture.config.control.emit(capture.config.control.context, .close_observed);
            };
            self.status.phase = .closing;
        }
        if (self.status.phase == .closing) return self.closeTurn();
        if (backend.loss_signal.pending.load(.acquire)) {
            if (self.options.semantic) |session| session.poison();
            self.status.loss_observed = true;
            self.operation = .loss;
            if (self.options.recovery == .close) {
                self.fail(error.DeviceLost);
                backend.serviceDeviceLoss(.restart_at_bar) catch |err| {
                    self.status.cleanup_error = err;
                };
                return self.closeTurn();
            }
            // pending remains set until reopen. Servicing the same loss is
            // idempotent and must never cancel its own retained command.
            var ingress_pending = false;
            backend.serviceDeviceLoss(.restart_at_bar) catch |err| {
                if (err != error.CommandQueueFull) return err;
                ingress_pending = true;
            };
            const epoch = backend.adapter.device_epoch;
            if (epoch != self.serviced_loss_epoch) {
                try self.finishRecovery(.interrupted);
                self.serviced_loss_epoch = epoch;
                self.status.loss_accepted = false;
                self.status.phase = .waiting_for_recovery;
            }
            if (ingress_pending) {
                // The real new loss is retained by the backend. Drain the
                // occupied ingress with the uninterrupted live tick protocol;
                // never admit commands or reopen until service succeeds.
                if (self.closeRequestedObserved()) {
                    self.status.phase = .closing;
                    return self.closeTurn();
                }
                self.operation = .control_tick;
                try self.tick(owner, true);
                try self.collect();
                try self.recoveryTurn();
                self.status.callback_sequence = self.renderer.?.telemetry.callback_count.load(.acquire);
                return;
            }
        }
        if (self.status.phase == .recovering and backend.loss_signal.pending.load(.acquire)) {
            const command = self.recovery_command orelse return error.InvalidState;
            if (self.closeRequestedObserved()) return;
            self.operation = .device_start;
            if (@import("builtin").is_test and self.options.test_fault == .reopen_after_callback) backend.test_start_driver = audio.RuntimeMiniaudioBackend.DriverTest.renderThenFailStart;
            backend.reopenEpoch(command.device_epoch) catch |err| {
                try self.finishRecovery(.failed);
                self.fail(err);
                return; // retain any NEW loss created by partially-started reopen
            };
            self.status.output = backend.output;
            if (backend.loss_signal.pending.load(.acquire)) return;
        }
        if (self.worker_error.load(.acquire) != 0) {
            self.operation = .worker;
            self.fail(error.WorkerFailed);
            return;
        }
        if (self.load_ticket != null) {
            try self.pollLoad();
            if (self.load_ticket != null or self.status.phase == .closing) return;
            self.status.phase = .ready;
        }
        for (0..2) |_| {
            if (self.closeRequestedObserved()) break;
            if (backend.loss_signal.pending.load(.acquire) and self.status.phase != .waiting_for_recovery and self.status.phase != .recovering) break;
            const command = self.popCommandObserved() orelse break;
            self.admit(command) catch |err| {
                if (command.kind == .recover and self.recovery_command != null) {
                    try self.finishRecovery(.failed);
                } else try self.publishTerminalObserved(command, .failed, null);
                self.fail(err);
                break;
            };
        }
        // A start error or injected/real loss must not reach a normal tick.
        if (self.closeRequestedObserved()) return;
        if (backend.loss_signal.pending.load(.acquire) and self.status.phase != .waiting_for_recovery) return;
        self.operation = .control_tick;
        try self.tick(owner, true);
        try self.collect();
        try self.recoveryTurn();
        self.status.callback_sequence = self.renderer.?.telemetry.callback_count.load(.acquire);
        if (self.status.stop_executed and self.status.phase != .waiting_for_recovery and self.status.phase != .recovering) {
            self.operation = .drain_status;
            // The legacy test protocol retains its original diagnostic call.
            // Production observes only Control-owned progress while Render runs.
            const progress: music.MusicRuntimeStopProgressV1 = if (@import("builtin").is_test and self.options.test_capture != null) blk: {
                const snapshot = try self.captureCall(captureArgs(.snapshot, {}), music.MusicRuntime.snapshotV1, .{owner});
                const drain = try self.captureCall(captureArgs(.drain_status, {}), music.MusicRuntime.drainStatusV1, .{owner});
                break :blk .{ .state = snapshot.state, .active_music_groups = drain.active_music_groups, .retired_music_groups = drain.retired_music_groups, .live_instances = drain.live_instances };
            } else try self.captureCall(captureArgs(.stop_progress, {}), music.MusicRuntime.stopProgressV1, .{owner});
            if (progress.state == .ready and progress.active_music_groups == 0 and progress.retired_music_groups == 0 and progress.live_instances == 0) self.status.phase = .stopped;
        }
    }
    fn semanticCommand(command: Mailbox.Command) semantic.Command {
        return .{ .id = command.id, .identity = command.identity, .kind = command.kind, .slot = command.slot, .device_epoch = command.device_epoch };
    }
    fn semanticUiEvent(event: Mailbox.Event) semantic.UiMailboxEvent {
        return .{
            .command = semanticCommand(event.command),
            .kind = switch (event.kind) {
                .accepted => .accepted,
                .terminal => .terminal,
            },
            .receipt = event.receipt,
            .terminal = event.terminal,
            .recovery = event.recovery,
        };
    }
    fn closeRequestedObserved(self: *Host) bool {
        if (self.options.semantic) |session| session.emitControl(.close_poll);
        const closed = self.channel.closeRequested();
        if (self.options.semantic) |session| session.emitControl(.{ .close_polled = closed });
        return closed;
    }
    fn popCommandObserved(self: *Host) ?Mailbox.Command {
        if (self.options.semantic) |session| session.emitControl(.command_dequeue_attempt);
        const command = self.channel.popCommand();
        if (self.options.semantic) |session| {
            if (command) |value| if (value.kind == .recover) {
                session.poison();
            };
            session.emitControl(.{ .command_dequeued = if (command) |value| semanticCommand(value) else null });
        }
        return command;
    }
    fn publishAcceptedObserved(self: *Host, command: Mailbox.Command, receipt: music.MusicRuntimeReceiptV1) !void {
        try self.channel.publishAccepted(command, receipt);
        if (self.options.semantic) |session| session.emitControl(.{ .command_emitted = .{ .command = semanticCommand(command), .kind = .accepted, .receipt = receipt, .terminal = null } });
    }
    fn publishTerminalObserved(self: *Host, command: Mailbox.Command, terminal: mailbox.Terminal, receipt: ?music.MusicRuntimeReceiptV1) !void {
        try self.channel.publishTerminal(command, terminal, receipt);
        if (self.options.semantic) |session| session.emitControl(.{ .command_emitted = .{ .command = semanticCommand(command), .kind = .terminal, .receipt = receipt, .terminal = terminal } });
    }
    fn finishRecovery(self: *Host, terminal: mailbox.Terminal) !void {
        if (self.recovery_command) |command| {
            const evidence = if (self.status.recovery) |recovery|
                (if (recovery.device_epoch == command.device_epoch) recovery else null)
            else
                null;
            try self.channel.publishRecoveryTerminal(command, terminal, evidence);
            self.recovery_command = null;
            self.recovery_requested.store(false, .release);
        }
    }
    fn recoveryTurn(self: *Host) !void {
        if (self.options.recovery != .restart_at_bar or self.serviced_loss_epoch == 0) return;
        const recovery = try self.owner.?.deviceRecoveryStatusV1();
        self.status.recovery = recovery;
        self.status.loss_accepted = self.owner.?.deviceEpochAcceptedV1(self.serviced_loss_epoch);
        if (recovery.device_epoch != self.serviced_loss_epoch) return;
        if (recovery.failure != null or recovery.preparation_failure != null or recovery.stage == .policy_required or recovery.stage == .stopped) {
            try self.finishRecovery(.failed);
            self.operation = .loss;
            self.fail(error.DeviceRecoveryFailed);
            return;
        }
        if (self.recovery_command) |command| {
            if (recovery.device_epoch == command.device_epoch and recovery.stage == .recovered) {
                if (recovery.phase) |phase| if (phase.outcome == .executed) {
                    try self.finishRecovery(.executed);
                    self.status.phase = .running;
                };
            }
        }
    }
    // Ordinary Live owns multi-cut chronology independently of capture. Keep
    // legacy fallback dispatch separate for existing private replay profiles.
    fn defaultTickCall(owner: *music.MusicRuntime, live: bool) !music.MusicRuntime.LiveControlTickOutcomeV1 {
        if (live or owner.live_chronology_frontier != null)
            return owner.controlTickLiveChronologyV1(audio.runtime.max_control_drain, null);
        return tickCall(owner, false);
    }
    fn tickCall(owner: *music.MusicRuntime, live: bool) !music.MusicRuntime.LiveControlTickOutcomeV1 {
        if (live) return owner.controlTickLiveV1(audio.runtime.max_control_drain);
        // Called only after backend.stop has joined callbacks. Preserve the
        // original shutdown API, including never-loaded constructor failures.
        return .{ .drained = try owner.controlTickV1(audio.runtime.max_control_drain), .deferred = null };
    }
    fn semanticTickCall(owner: *music.MusicRuntime, live: bool, session: *semantic.Session) !music.MusicRuntime.LiveControlTickOutcomeV1 {
        if (!session.live_attached) return tickCall(owner, live);
        if (live or owner.live_chronology_frontier != null) return owner.controlTickLiveSemanticV1(audio.runtime.max_control_drain, session.config.acceptance);
        return owner.controlTickSemanticInitialCleanupV1(audio.runtime.max_control_drain);
    }
    fn tick(self: *Host, owner: *music.MusicRuntime, live: bool) !void {
        const outcome = (if (@import("builtin").is_test and self.options.test_capture != null)
            self.captureCall(captureArgs(.tick, .{ .mode = @as(semantic.TickMode, if (live) .playback else if (owner.live_chronology_frontier != null) .chronology_cleanup else .initial_cleanup), .limit = audio.runtime.max_control_drain }), CaptureAdapter.tick, .{ self, owner, live })
        else if (self.options.semantic) |session|
            self.captureCall(captureArgs(.tick, .{ .mode = @as(semantic.TickMode, if (live) .playback else if (owner.live_chronology_frontier != null) .chronology_cleanup else .initial_cleanup), .limit = audio.runtime.max_control_drain }), semanticTickCall, .{ owner, live, session })
        else
            defaultTickCall(owner, live)) catch |err| {
            if (self.status.first_error == null) {
                self.status.error_render_frame = self.renderer.?.renderFrame();
                self.status.error_callback_count = self.renderer.?.telemetry.callback_count.load(.acquire);
                self.status.error_control_tick = self.control.?.stream_control_tick;
                if (@import("builtin").is_test) if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            }
            return err;
        };
        if (@import("builtin").is_test and live) if (self.options.test_tick_outcome) |hook| hook.call(hook.context, outcome);
        // A deferred observation is not a request terminal or playback result.
        // The caller still collects real receipts and retries on a later turn.
        if (outcome.deferred) |deferred| {
            self.status.live_tick_deferred +|= 1;
            self.status.last_live_defer = deferred;
        }
        // A precise pre-allocation Stop deferral retains the same runtime
        // ticket. No host retry queue, resubmission, or terminal is created.
        if (outcome.cold_start_deferred) |deferred| {
            self.status.live_cold_start_deferred +|= 1;
            self.status.last_cold_start_defer = deferred;
        }
        if (outcome.stop_deferred) |deferred| {
            self.status.live_stop_deferred +|= 1;
            self.status.last_stop_defer = deferred;
        }
    }
    fn pollLoad(self: *Host) !void {
        const ticket = self.load_ticket orelse return;
        if (@import("builtin").is_test) if (self.options.test_capture) |capture| if (capture.committed) {
            if (!try CaptureAdapter.park(self)) return;
        };
        self.operation = .load_poll;
        errdefer {
            if (@import("builtin").is_test) if (self.options.test_capture) |capture| if (capture.committed and self.park_sequence != null and !capture.finalization.blocked()) {
                CaptureAdapter.resumePending(self) catch {};
            };
        }
        switch (try self.captureCall(captureArgs(.poll_load, ticket), music.MusicRuntime.pollLoad, .{ self.owner.?, ticket })) {
            .pending => {},
            .ready => |value| {
                self.bank = value.bank;
                try self.captureCall(captureArgs(.acknowledge_load, ticket), music.MusicRuntime.acknowledgeLoad, .{ self.owner.?, ticket });
                self.load_ticket = null;
                if (@import("builtin").is_test) if (!self.closeRequestedObserved()) {
                    if (self.options.test_setup) |setup| setup.call(setup.context, self.owner.?);
                };
            },
            .failed => |reason| {
                self.status.load_failure = reason;
                try self.captureCall(captureArgs(.acknowledge_load, ticket), music.MusicRuntime.acknowledgeLoad, .{ self.owner.?, ticket });
                self.load_ticket = null;
                if (self.status.phase != .closing) self.fail(error.LoadFailed);
            },
        }
        if (@import("builtin").is_test) if (self.options.test_capture) |capture| if (capture.committed)
            try CaptureAdapter.resumePending(self);
    }
    fn admit(self: *Host, command: Mailbox.Command) !void {
        if (self.replayFailed()) self.channel.requestCloseFromControl(self.launch_identity.epoch) catch unreachable;
        if (!std.meta.eql(command.identity, self.launch_identity)) {
            try self.publishTerminalObserved(command, .rejected, null);
            return;
        }
        if (self.closeRequestedObserved()) {
            try self.publishTerminalObserved(command, .cancelled, null);
            return;
        }
        if (command.kind == .recover) {
            if (self.options.recovery != .restart_at_bar or self.status.phase != .waiting_for_recovery or self.recovery_command != null or command.device_epoch != self.serviced_loss_epoch or !self.owner.?.deviceEpochAcceptedV1(command.device_epoch)) {
                try self.publishTerminalObserved(command, .rejected, null);
                self.recovery_requested.store(false, .release);
                return;
            }
            self.recovery_command = command;
            try self.channel.publishHostAccepted(command);
            // A later Control turn lets priority Close cancel before reopen.
            self.status.phase = .recovering;
            return;
        }
        if (self.status.phase == .waiting_for_recovery or self.status.phase == .recovering) {
            try self.publishTerminalObserved(command, .rejected, null);
            return;
        }
        var slot: ?usize = null;
        for (self.pending, 0..) |item, i| if (item == null) {
            slot = i;
            break;
        };
        if (slot == null) return error.CommandLedgerFull;
        const owner = self.owner.?;
        const ticket = switch (command.kind) {
            .recover => unreachable,
            .play => blk: {
                if (self.started) {
                    try self.publishTerminalObserved(command, .rejected, null);
                    return;
                }
                self.started = true;
                var device = self.options.device;
                if (@import("builtin").is_test and self.options.test_fault == .open) device.sample_rate = 0;
                if (@import("builtin").is_test) if (self.options.test_capture) |capture| if (capture.committed) {
                    const token = capture.quiescence orelse return error.InvalidState;
                    try self.captureCall(captureArgs(.release_quiescence, {}), audio.RuntimeRenderer.releaseDeviceQuiescence, .{ self.renderer.?, token });
                    capture.quiescence = null;
                };
                self.operation = .device_open;
                try self.captureCall(captureArgs(.device_open, device), audio.RuntimeMiniaudioBackend.open, .{ &self.backend.?, device });
                self.status.output = self.backend.?.output;
                if (@import("builtin").is_test and self.options.test_fault == .start_after_callback) self.backend.?.test_start_driver = audio.RuntimeMiniaudioBackend.DriverTest.renderThenFailStart;
                self.start_attempted = true;
                self.operation = .device_start;
                try self.captureCall(captureArgs(.device_start, {}), audio.RuntimeMiniaudioBackend.start, .{&self.backend.?});
                if (@import("builtin").is_test and self.options.test_fault == .loss_after_start) _ = self.backend.?.signalLost();
                if (self.backend.?.loss_signal.pending.load(.acquire)) return error.DeviceLost;
                // Admission follows actual ready load and successful start.
                self.operation = .request_submit;
                break :blk try self.captureCall(captureArgs(.play, .{ .command = command.id, .bank = self.bank.?, .state = self.launch_identity.state }), music.MusicRuntime.start, .{ owner, self.bank.?, self.launch_identity.state });
            },
            .stop => blk: {
                if (!self.started or self.status.stop_executed) {
                    try self.publishTerminalObserved(command, .rejected, null);
                    return;
                }
                self.operation = .request_submit;
                break :blk try self.captureCall(captureArgs(.stop, .{ .command = command.id, .bank = self.bank.? }), music.MusicRuntime.submitV1, .{ owner, self.bank.?, music.MusicRequestPayload{ .stop = .emergency_ramp } });
            },
        };
        self.pending[slot.?] = .{ .command = command, .ticket = ticket };
    }
    fn collect(self: *Host) !void {
        for (0..64) |_| {
            self.operation = .receipts;
            const receipt = (try self.captureCall(captureArgs(.receipt, {}), music.MusicRuntime.pollReceiptV1, .{self.owner.?})) orelse return;
            for (&self.pending) |*entry| {
                const pending = entry.* orelse continue;
                if (!std.meta.eql(pending.ticket, receipt.ticket)) continue;
                switch (receipt.event) {
                    .accepted => try self.publishAcceptedObserved(pending.command, receipt),
                    .terminal => |terminal| {
                        if (@import("builtin").is_test) {
                            if (self.options.semantic == null and self.options.test_capture == null and
                                pending.command.kind == .stop and terminal == .rejected)
                                self.reportRejectedStopForTest(receipt);
                        }
                        const result: mailbox.Terminal = switch (terminal) {
                            .executed, .unchanged, .control_applied => .executed,
                            .rejected => .rejected,
                            .cancelled_before_entry => .cancelled,
                        };
                        if (terminal == .executed) switch (pending.command.kind) {
                            .play => {
                                self.status.play_executed = true;
                                if (self.status.phase != .closing and self.status.phase != .waiting_for_recovery and self.status.phase != .recovering) self.status.phase = .running;
                            },
                            .stop => self.status.stop_executed = true,
                            .recover => unreachable,
                        };
                        try self.publishTerminalObserved(pending.command, result, receipt);
                        entry.* = null;
                    },
                }
                break;
            }
        }
        self.status.receipt_budget_saturated +|= 1;
    }
    /// Failure-only ordinary-Host diagnostics, on Control after a real receipt.
    /// No callback I/O, semantic observations, or replacement command outcome.
    fn reportRejectedStopForTest(self: *Host, receipt: music.MusicRuntimeReceiptV1) void {
        if (!@import("builtin").is_test) return;
        const owner = self.owner.?;
        // Keep the error union as diagnostic data: snapshot failure must not
        // escape collect(), alter the terminal, or skip normal ledger cleanup.
        const published = owner.snapshotV1();
        std.debug.print("DEFAULT_HOST_REJECTED_STOP host_phase={s} play_executed={} state={s} active_group={} pending={} action={any} tick={d} frame={d} last_error={any} fault_count={d} fault={any} receipt={any} published={any}\n", .{
            @tagName(self.status.phase),
            self.status.play_executed,
            @tagName(owner.state),
            owner.active_group != null,
            owner.pending != null,
            owner.action,
            owner.tick,
            owner.control_frame,
            owner.last_error,
            owner.stream_fault_count,
            owner.last_stream_fault,
            receipt,
            published,
        });
    }
    fn closeTurn(self: *Host) !void {
        // An outstanding park is retained custody: finish its snapshot or
        // resume before any further fallible shutdown/tick work.
        if (self.park_sequence != null and !(@import("builtin").is_test and self.options.test_capture != null)) return self.closeSnapshot();
        const owner = self.owner.?;
        const backend = &self.backend.?;
        try self.finishRecovery(.interrupted);
        // Preserve loss publication before shutdown even when sticky Close and
        // a device notification arrive together. Pressure retains backend custody
        // and shutdown below consumes the occupied ingress before the next turn.
        if (backend.loss_signal.pending.load(.acquire)) {
            if (self.options.semantic) |session| session.poison();
            self.status.loss_observed = true;
            self.operation = .loss;
            backend.serviceDeviceLoss(.restart_at_bar) catch |err| {
                self.status.cleanup_error = err;
            };
        }
        // At most two cancellation dequeues per turn, even with a stalled UI.
        for (0..2) |_| {
            const command = self.popCommandObserved() orelse break;
            try self.publishTerminalObserved(command, .cancelled, null);
        }
        self.operation = .shutdown;
        self.captureCall(captureArgs(.shutdown, {}), music.MusicRuntime.shutdown, .{owner}) catch |err| {
            self.status.cleanup_error = err;
            if (err != error.CommandQueueFull) return err;
        };
        self.operation = .device_stop;
        if (@import("builtin").is_test and self.options.test_capture != null) {
            const capture = self.options.test_capture.?;
            capture.beginControl(.device_stop);
            backend.stop(); // real driver stop/join, including native loss behavior
            capture.resultControl(.{ .device_stopped = .{ .state = backend.state, .output = backend.output } });
            capture.endControl(false);
            if (capture.committed and capture.quiescence == null)
                capture.quiescence = try self.captureCall(captureArgs(.final_quiescence, {}), audio.RuntimeRenderer.acquireDeviceQuiescence, .{self.renderer.?});
        } else if (self.options.semantic) |session| {
            session.beginControl(.device_stop);
            backend.stop(); // actual driver stop/join, never an observer grant
            session.resultControl(.{ .device_stopped = .{ .state = backend.state, .output = backend.output } });
            session.endControl(false);
        } else backend.stop(); // joins driver; may itself create a new retained loss
        self.status.callback_sequence = self.renderer.?.telemetry.callback_count.load(.acquire);
        if (backend.loss_signal.pending.load(.acquire)) {
            if (self.options.semantic) |session| session.poison();
            self.status.loss_observed = true;
            backend.serviceDeviceLoss(.restart_at_bar) catch |err| {
                self.status.cleanup_error = err;
            };
            // No tick/preparation between loss publication and shutdown intent.
            self.operation = .shutdown;
            self.captureCall(captureArgs(.shutdown, {}), music.MusicRuntime.shutdown, .{owner}) catch |err| {
                self.status.cleanup_error = err;
            };
        }
        self.operation = .control_tick;
        try self.tick(owner, false);
        try self.pollLoad();
        try self.collect();
        // Keep the UI's recovery copy truthful during cleanup, too. A candidate
        // without a schedule block is not counted by pending_plans; only the
        // public stopped stage proves that recovery candidate has retired.
        if (self.status.loss_observed) self.status.recovery = try owner.deviceRecoveryStatusV1();
        const consumed_shutdown = self.control.?.scheduled.shutdown_requested.load(.acquire);
        if (!consumed_shutdown) return;
        if (backend.loss_signal.pending.load(.acquire)) {
            self.status.loss_accepted = backend.loss_queued and owner.deviceEpochAcceptedV1(backend.adapter.device_epoch);
            if (!self.status.loss_accepted) return;
        }
        self.operation = .quiescent_drain;
        const before = self.renderer.?.callObservation().sequence;
        if (@import("builtin").is_test and self.options.test_capture != null and self.options.test_capture.?.committed) {
            try CaptureAdapter.cleanupRender(self);
        } else if (self.options.semantic != null) {
            try self.captureCall(captureArgs(.cleanup_render, .{ .frames = backend.adapter.quantum_frames, .channels = backend.adapter.channels }), cleanupRenderNative, .{self});
        } else try self.cleanupRenderNative();
        self.status.cleanup_render_sequence +|= self.renderer.?.callObservation().sequence - before;
        if (!(@import("builtin").is_test and self.options.test_capture != null)) return self.closeSnapshot();
        self.operation = .drain_status;
        const drain = try self.captureCall(captureArgs(.drain_status, {}), music.MusicRuntime.drainStatusV1, .{owner});
        if (!drained(drain) or !self.channel.admissionDrained()) return;
        if (self.serviced_loss_epoch != 0) {
            const recovery = self.status.recovery orelse return;
            if (recovery.stage != .stopped) return;
        }
        for (self.pending) |entry| if (entry != null) return;
        // close admission means there can only be the original eight entries;
        // do not destroy while cancellation terminals are still owed.

        self.status.phase = .destroying;
    }
    /// Real lifecycle snapshot: Render has joined and synchronous cleanup has
    /// returned. The Worker acknowledges only between actual engine calls.
    fn closeSnapshot(self: *Host) !void {
        return self.withParkedSnapshot(closeSnapshotReady);
    }
    fn withParkedSnapshot(self: *Host, comptime inspect: fn (*Host) anyerror!bool) !void {
        if (!try self.parkWorker()) return;
        var handoff = false;
        defer if (!handoff) self.resumeWorker() catch |err| {
            // Failed resume retains the sequence/custody for an explicit retry.
            self.status.cleanup_error = err;
        };
        if (!try inspect(self)) return;
        self.status.phase = .destroying;
        handoff = true; // The same acknowledged sequence protects destroyTurn.
    }
    fn closeSnapshotReady(self: *Host) !bool {
        self.operation = .drain_status;
        const drain = try self.captureCall(captureArgs(.drain_status, {}), music.MusicRuntime.drainStatusV1, .{self.owner.?});
        if (!drained(drain) or !self.channel.admissionDrained()) return false;
        if (self.serviced_loss_epoch != 0) {
            const recovery = self.status.recovery orelse return false;
            if (recovery.stage != .stopped) return false;
        }
        for (self.pending) |entry| if (entry != null) return false;
        return true;
    }
    fn cleanupRenderNative(self: *Host) !void {
        const backend = &self.backend.?;
        if (backend.state == .closed) {
            // Only the genuinely never-started branch may drain closed state.
            if (self.start_attempted or backend.callback_registered or backend.context_initialized or backend.adapter.pending_len != 0) return error.InvalidState;
            const token = try self.renderer.?.acquireDeviceQuiescence();
            defer self.renderer.?.releaseDeviceQuiescence(token) catch unreachable;
            try backend.adapter.drainShutdownQuiescent(token);
        } else try backend.drainShutdown();
    }
    fn drained(d: music.MusicRuntimeDrainStatusV1) bool {
        return d.queued_requests == 0 and d.active_producers == 0 and d.in_flight_requests == 0 and d.load_transactions == 0 and !d.worker_active and d.pending_plans == 0 and d.prepared_stream_windows == 0 and d.active_music_groups == 0 and d.retired_music_groups == 0 and d.live_instances == 0 and d.snapshot_readers == 0 and d.control_drained and d.preview_seek_transactions == 0 and d.resident_reload_transactions == 0 and d.resident_state_transactions == 0 and d.layer_controller_lifetimes == 0 and d.policy_request_slots == 0 and d.policy_occupied_slots == 0 and d.policy_retained_results == 0 and d.policy_physical_lifetimes == 0 and !d.policy_graph_retained and d.event_instances == 0 and d.event_terminal_credits == 0;
    }
    fn parkWorker(self: *Host) !bool {
        const epoch = self.launch_identity.epoch;
        const seq = self.park_sequence orelse blk: {
            if (self.options.semantic) |session| session.emitControl(.{ .gate = .request_begin });
            const value = self.gate.requestPark(epoch) catch |err| {
                if (self.options.semantic) |session| session.emitControl(.{ .gate = .{ .request = err } });
                if (err == error.ProgressPending) return false;
                return err;
            };
            if (self.options.semantic) |session| session.emitControl(.{ .gate = .{ .request = value } });
            self.park_sequence = value;
            self.notifyWorker();
            break :blk value;
        };
        if (self.options.semantic) |session| session.emitControl(.{ .gate = .{ .poll_begin = seq } });
        const parked = self.gate.parked(epoch, seq);
        if (self.options.semantic) |session| session.emitControl(.{ .gate = .{ .poll = .{ .sequence = seq, .parked = parked } } });
        return parked;
    }
    fn resumeWorker(self: *Host) !void {
        const epoch = self.launch_identity.epoch;
        const seq = self.park_sequence orelse return error.InvalidState;
        if (self.options.semantic) |session| session.emitControl(.{ .gate = .{ .resume_begin = seq } });
        self.gate.resumeAfterPending(epoch, seq) catch |failure| {
            if (self.options.semantic) |session| session.emitControl(.{ .gate = .{ .resume_return = .{ .sequence = seq, .failure = failure } } });
            return failure;
        };
        if (self.options.semantic) |session| session.emitControl(.{ .gate = .{ .resume_return = .{ .sequence = seq, .failure = null } } });
        self.park_sequence = null;
        self.notifyWorker();
    }
    fn destroyTurn(self: *Host) !void {
        if (@import("builtin").is_test) if (self.options.test_capture) |capture| if (capture.committed)
            return CaptureAdapter.destroyTurn(self);
        const epoch = self.launch_identity.epoch;
        if (!try self.parkWorker()) return;
        const seq = self.park_sequence.?;
        self.status.destroy_attempts +|= 1;
        self.operation = .destroy;
        if (@import("builtin").is_test) if (self.options.test_capture) |capture| capture.beginControl(.{ .destroy_unbound = seq });
        var capture_failed = true;
        defer if (@import("builtin").is_test) {
            if (self.options.test_capture) |capture| capture.endControl(capture_failed);
        };
        if (self.options.semantic) |session| session.beginControl(.{ .destroy_unbound = seq });
        const report = self.owner.?.destroyQuiescent() catch |err| {
            if (self.options.semantic) |session| {
                session.resultControl(.{ .failure = err });
                session.endControl(true);
            }
            if (@import("builtin").is_test) if (self.options.test_capture) |capture| capture.resultControl(.{ .failure = err });
            self.status.cleanup_error = err;
            // Control may already be destroyed. Only same Worker progress and
            // fresh exact-sequence park/destroy retries are legal from now on.
            try self.resumeWorker();
            return;
        };
        self.owner = null;
        if (self.options.semantic) |session| {
            session.resultControl(.{ .destroyed = report });
            session.endControl(false);
            // Only this actual native return ends the Runtime binding borrow.
            session.live_attached = false;
        }
        if (@import("builtin").is_test) if (self.options.test_capture) |capture| {
            capture.owner_alive = false;
            capture.resultControl(.{ .destroyed = report });
        };
        capture_failed = false;
        self.status.phase = .provider_release;
        self.status.sample_leases = report.sample_leases;
        self.status.live_instances = report.live_instances;
        if (self.options.semantic) |session| session.emitControl(.{ .gate = .{ .stop_begin = seq } });
        self.gate.stopAfterDestroyed(epoch, seq) catch |err| {
            if (self.options.semantic) |session| session.emitControl(.{ .gate = .{ .stop_return = .{ .sequence = seq, .failure = err } } });
            return err;
        };
        if (self.options.semantic) |session| session.emitControl(.{ .gate = .{ .stop_return = .{ .sequence = seq, .failure = null } } });
        self.terminal_stop_sent = true;
        self.notifyWorker();
        if (self.options.semantic) |session| session.emitControl(.worker_join_begin);
        self.worker_thread.?.join();
        if (self.options.semantic) |session| session.emitControl(.worker_joined);
        self.worker_thread = null;
        self.status.worker_joined = true;
        self.status.phase = .provider_release;
    }
    fn releaseTurn(self: *Host) !void {
        if (@import("builtin").is_test) if (self.options.test_capture) |capture| if (capture.committed and !capture.owner_alive and !self.terminal_stop_sent)
            try CaptureAdapter.finishDestroyed(self);
        // Constructor failure before an owner exists also arrives here. A
        // waiting Worker sees startup_abort and never acquires an owner pointer.
        if (self.worker_thread) |thread| {
            if (self.worker_ready.load(.acquire) and !self.terminal_stop_sent) return error.WorkerStopPending;
            self.abortStartupWorker();
            if (self.options.semantic) |session| session.emitControl(.worker_join_begin);
            thread.join();
            if (self.options.semantic) |session| session.emitControl(.worker_joined);
            self.worker_thread = null;
            self.status.worker_joined = true;
        }
        self.status.phase = .provider_release;
        for (0..2) |_| {
            const command = self.popCommandObserved() orelse break;
            try self.publishTerminalObserved(command, .cancelled, null);
            return;
        }
        if (!self.channel.admissionDrained()) return;
        if (self.provider) |provider| {
            self.status.provider = provider.counts;
            if (provider.counts.live != 0 or provider.counts.opened != provider.counts.closed) return error.ProviderOwnershipMismatch;
            self.operation = .provider_release;
            try self.captureCall(captureArgs(.provider_release, provider.counts), source.Provider.destroy, .{provider});
            self.provider = null;
        }
        if (@import("builtin").is_test) if (self.options.test_capture) |capture| if (capture.quiescence) |token| {
            try self.captureCall(captureArgs(.release_quiescence, {}), audio.RuntimeRenderer.releaseDeviceQuiescence, .{ self.renderer.?, token });
            capture.quiescence = null;
        };
        if (self.options.semantic) |session| if (session.audio_attached) {
            // Native owner free and real Worker join already happened. The
            // final shutdown drain ended before this independently checked Q.
            self.detachSemanticAudio(session);
        };
        if (self.backend) |*backend| {
            backend.deinit();
            self.backend = null;
        }
        if (self.renderer) |renderer| {
            self.allocator.destroy(renderer);
            self.renderer = null;
        }
        if (self.control) |control| {
            // Successful owner destruction already destroyed Control contents.
            // Constructor failure owns an initialized, unattached empty Control.
            if (self.status.destroy_attempts == 0) try control.destroy();
            self.allocator.destroy(control);
            self.control = null;
        }
        self.status.phase = .closed;
        self.status.cleanup_error = null;
    }
    fn detachSemanticAudio(self: *Host, session: *semantic.Session) void {
        const token = self.captureCall(.final_quiescence, audio.RuntimeRenderer.acquireDeviceQuiescence, .{self.renderer.?}) catch {
            session.poison();
            return;
        };
        defer self.captureCall(.release_quiescence, audio.RuntimeRenderer.releaseDeviceQuiescence, .{ self.renderer.?, token }) catch {
            session.poison();
        };
        self.captureCall(.detach_audio, audio.RuntimeMiniaudioBackend.detachSemanticAudioQuiescent, .{ &self.backend.?, token }) catch {
            session.poison();
            return;
        };
        session.audio_attached = false;
    }
};

fn hash(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

/// Fixed adapter for this actual Host only. No callback-supplied parked flag,
/// fixture Driver, shared role router, or recorder-health admission exists here.
const CaptureAdapter = if (@import("builtin").is_test) struct {
    const Binding = music.MusicRuntime.FinalizationTests;
    const Capture = TestCapture.Session;
    fn from(raw: *anyopaque) *Host {
        return @ptrCast(@alignCast(raw));
    }
    fn get(host: *Host) *Capture {
        return host.options.test_capture.?;
    }
    fn identity(host: *Host) Binding.HostIdentity {
        return .{ .context = host, .gate = &host.gate, .epoch = host.launch_identity.epoch };
    }
    fn pinned(host: *Host, session: *const Binding.Session) !*Capture {
        const capture = get(host);
        if (capture.address != capture or capture.host != @as(*anyopaque, @ptrCast(host)) or !capture.committed or
            session != &capture.finalization or session.bootstrap != &capture.bootstrap or
            capture.bootstrap.combined != @as(?*anyopaque, @ptrCast(&capture.finalization)) or
            !std.meta.eql(capture.bootstrap.roles.?, capture.config.roles) or
            !std.meta.eql(capture.bootstrap.hooks, @as(?Binding.Hooks, capture.config.hooks))) return error.InvalidState;
        return capture;
    }
    fn backendHooks(host: *Host, ended: bool) !void {
        const capture = get(host);
        const backend = if (host.backend) |*value| value else return error.InvalidState;
        const expected: ?audio.RuntimeMiniaudioBackend.TestCallbackFacts = if (ended) null else .{ .context = capture, .call = Capture.callback };
        const pcm: ?audio.RuntimeMiniaudioBackend.TestPcm = if (ended) null else capture.config.pcm;
        if (capture.backend != backend or !std.meta.eql(backend.test_callback_facts, expected) or !std.meta.eql(backend.test_pcm, pcm) or
            backend.test_start_driver != null or backend.test_started_hook != null or backend.test_fail_stop_once or backend.adapter.witness != null) return error.InvalidState;
    }
    fn register(raw: *anyopaque, owner: *music.MusicRuntime, session: *Binding.Session, actual: Binding.HostIdentity) !void {
        const host = from(raw);
        const capture = get(host);
        if (capture.address != capture or capture.host != @as(*anyopaque, @ptrCast(host)) or capture.committed or capture.owner != owner or
            host.owner != owner or session != &capture.finalization or !std.meta.eql(actual, identity(host)) or
            capture.host_thread != std.Thread.getCurrentId() or host.worker_thread == null or host.worker_ready.load(.acquire) or
            host.startup_abort.load(.acquire) or host.gate.sequence != 0 or host.gate.request.load(.acquire) != 0 or
            host.gate.acknowledgment.load(.acquire) != 0 or host.gate.stopped.load(.acquire) or host.park_sequence != null or
            host.backend.?.state != .closed or host.backend.?.callback_registered or host.backend.?.context_initialized or
            host.backend.?.test_callback_facts != null or host.backend.?.test_pcm != null or host.backend.?.test_start_driver != null or host.backend.?.test_started_hook != null or host.backend.?.test_fail_stop_once or
            host.backend.?.adapter.witness != null) return error.InvalidState;
        try owner.renderer.validateDeviceQuiescence(capture.quiescence orelse return error.InvalidState);
        if (capture.fail_before_commit) return error.TestBeforeHostCommit;
        // All checks preceded this single infallible commit and the runtime's
        // remaining infallible linked commit. Worker still waits on ready.
        capture.committed = true;
        host.backend.?.test_callback_facts = .{ .context = capture, .call = Capture.callback };
        host.backend.?.test_pcm = capture.config.pcm;
    }
    fn bind(host: *Host, capture: *Capture) !void {
        capture.owner = host.owner.?;
        capture.owner_alive = true;
        capture.backend = &host.backend.?;
        capture.quiescence = try host.captureCall(Host.captureArgs(.startup_quiescence, {}), audio.RuntimeRenderer.acquireDeviceQuiescence, .{host.renderer.?});
        capture.beginControl(.bind);
        var failed = true;
        defer capture.endControl(failed);
        Binding.bindJoinedHooks(host.owner.?, &capture.finalization, &capture.bootstrap, .{
            .tick_kind = .independent_host,
            .identity = identity(host),
            .register = register,
            .validate_park = validatePark,
            .seal = seal,
            .validate_startup = validateStartup,
            .validate_borrows = validateBorrows,
            .clear_borrows = clearBorrows,
            .validate_empty = validateEmpty,
            .validate_tick = validateTick,
        }, capture.config.roles, host.bytes, host.provider.?.provider(), capture.quiescence.?, capture.config.hooks) catch |err| {
            capture.resultControl(.{ .failure = err });
            return err;
        };
        capture.resultControl(.done);
        failed = false;
    }
    fn releaseFailed(host: *Host, capture: *Capture) !void {
        if (capture.committed or host.owner.?.test_finalization != null or host.owner.?.test_live_bootstrap != null or
            capture.finalization.address != null or capture.bootstrap.address != null or
            host.backend.?.test_callback_facts != null or host.backend.?.test_pcm != null) return error.InvalidState;
        if (capture.quiescence) |token| {
            try host.captureCall(Host.captureArgs(.release_quiescence, {}), audio.RuntimeRenderer.releaseDeviceQuiescence, .{ host.renderer.?, token });
            capture.quiescence = null;
        }
    }
    fn ready(host: *Host, capture: *Capture) void {
        std.debug.assert(!host.worker_ready.load(.monotonic));
        host.worker_ready.store(true, .release);
        capture.config.control.emit(capture.config.control.context, .{ .ready = .{ .committed = capture.committed } });
    }
    fn validatePark(raw: *anyopaque, owner: *music.MusicRuntime, session: *const Binding.Session, park_request: Binding.Park) !void {
        const host = from(raw);
        const capture = try pinned(host, session);
        if (!capture.owner_alive or host.owner != owner or capture.owner != owner or
            !std.meta.eql(park_request.host, identity(host)) or host.park_sequence != park_request.sequence or
            !host.gate.parked(host.launch_identity.epoch, park_request.sequence)) return error.InvalidState;
        // Only this acquire of the exact ACK permits peer-owned inspection.
        if (capture.worker_begin_attempts != capture.worker_end_attempts or capture.ack_end_attempts != capture.worker_end_attempts or
            capture.bootstrap.worker_active or capture.bootstrap.entry_permit or capture.bootstrap.entry_arm_pending) return error.InvalidState;
        if (host.gate.stopped.load(.acquire)) {
            const sealed = capture.sealed orelse return error.InvalidState;
            if (!std.meta.eql(sealed, session.capability orelse return error.InvalidState) or
                !std.meta.eql(sealed.park, park_request) or sealed.owner != owner or sealed.session != session) return error.InvalidState;
        }
    }
    fn validateStartup(raw: *anyopaque, owner: *music.MusicRuntime, session: *const Binding.Session) !void {
        const host = from(raw);
        const capture = try pinned(host, session);
        const sequence = host.park_sequence orelse return error.InvalidState;
        try validatePark(raw, owner, session, .{ .host = identity(host), .sequence = sequence });
        try owner.renderer.validateDeviceQuiescence(capture.quiescence orelse return error.InvalidState);
        if (host.backend.?.callback_registered or host.started or capture.engine_borrows_ended) return error.InvalidState;
        try backendHooks(host, false);
    }
    fn validateBorrows(raw: *anyopaque, session: *const Binding.Session, ended: bool) !void {
        const host = from(raw);
        const capture = try pinned(host, session);
        const owner = host.owner orelse return error.InvalidState;
        try validatePark(raw, owner, session, .{ .host = identity(host), .sequence = host.park_sequence orelse return error.InvalidState });
        if (capture.engine_borrows_ended != ended or host.backend.?.callback_registered or capture.render_active) return error.InvalidState;
        try backendHooks(host, ended);
    }
    fn clearBorrows(raw: *anyopaque, session: *const Binding.Session) void {
        const host = from(raw);
        const capture = get(host);
        std.debug.assert(session == &capture.finalization and host.gate.stopped.load(.acquire));
        host.backend.?.test_callback_facts = null;
        host.backend.?.test_pcm = null;
        capture.engine_borrows_ended = true;
        // Role/Gate callback storage remains immutable and retained through the
        // actual Worker and Control joins, including its post-ACK Gate fact.
    }
    fn validateEmpty(raw: *anyopaque, owner: *music.MusicRuntime, session: *const Binding.Session, park_request: ?Binding.Park) !void {
        try validatePark(raw, owner, session, park_request orelse return error.InvalidState);
        try validateBorrows(raw, session, false);
    }
    fn seal(raw: *anyopaque, capability: Binding.Capability) !void {
        const host = from(raw);
        const capture = get(host);
        try validatePark(raw, capability.owner, capability.session, capability.park);
        if (capability.owner.owned_streaming != capability.service or capability.nonce == 0 or
            capability.owner.test_finalization_nonce != capability.nonce or !std.meta.eql(capture.finalization.capability.?, capability)) return error.InvalidState;
        if (capture.sealed) |actual| {
            if (!std.meta.eql(actual, capability) or !host.gate.stopped.load(.acquire)) return error.InvalidState;
            return;
        }
        mailbox.WorkerGate.FinalizationTests.seal(&host.gate, host.launch_identity.epoch, capability.park.sequence) catch |err| {
            capture.controlGate(.{ .seal = .{ .sequence = capability.park.sequence, .nonce = capability.nonce, .failure = err } });
            return err;
        };
        capture.sealed = capability;
        capture.controlGate(.{ .seal = .{ .sequence = capability.park.sequence, .nonce = capability.nonce, .failure = null } });
    }
    fn validateTick(raw: *anyopaque, request: Binding.TickRequest, stage: Binding.TickStage) !void {
        const host = from(raw);
        const capture = try pinned(host, request.session);
        const active = capture.active_control orelse return error.InvalidState;
        if (!capture.owner_alive or host.owner != request.owner or capture.host_thread != std.Thread.getCurrentId() or
            active.call != .tick or active.operation != request.operation or active.call_id != request.main or
            active.call.tick.mode != @as(@TypeOf(active.call.tick.mode), if (request.mode == .playback) .playback else .chronology_cleanup) or
            active.call.tick.limit != request.limit or !std.meta.eql(request.sink, @as(?audio.runtime.ControlRuntime.LiveAcceptanceSinkV1, capture.config.tick)) or
            !std.meta.eql(capture.tick_request orelse return error.InvalidState, request) or
            capture.tick_in_progress != (stage != .issue)) return error.InvalidState;
        try backendHooks(host, false);
        // No active Worker/Render fields, queue counters or recorder health.
    }
    fn tick(host: *Host, owner: *music.MusicRuntime, live: bool) !music.MusicRuntime.LiveControlTickOutcomeV1 {
        const capture = get(host);
        if (!capture.committed or (!live and owner.live_chronology_frontier == null))
            return Host.tickCall(owner, live);
        const active = capture.active_control orelse return error.InvalidState;
        const request: Binding.TickRequest = .{ .owner = owner, .session = &capture.finalization, .operation = active.operation orelse return error.InvalidState, .main = active.call_id, .mode = if (live) .playback else .cleanup, .limit = audio.runtime.max_control_drain, .sink = capture.config.tick };
        capture.tick_request = request;
        defer capture.tick_request = null;
        try capture.finalization.issueTick(request);
        var failed = true;
        defer capture.finalization.endTick(request, failed) catch @panic("actual Host retained tick authority");
        capture.tick_in_progress = true;
        const result = Binding.hostTick(owner, request) catch |err| {
            capture.tick_in_progress = false;
            return err;
        };
        capture.tick_in_progress = false;
        failed = false;
        return result;
    }
    fn park(host: *Host) !bool {
        const capture = get(host);
        const sequence = host.park_sequence orelse blk: {
            const value = host.gate.requestPark(host.launch_identity.epoch) catch |err| {
                capture.controlGate(.{ .request = err });
                if (err == error.ProgressPending) return false;
                return err;
            };
            host.park_sequence = value;
            capture.controlGate(.{ .request = value });
            break :blk value;
        };
        const parked = host.gate.parked(host.launch_identity.epoch, sequence);
        capture.controlGate(.{ .poll = .{ .sequence = sequence, .parked = parked } });
        return parked;
    }
    fn resumePending(host: *Host) !void {
        const capture = get(host);
        const sequence = host.park_sequence orelse return error.InvalidState;
        if (capture.finalization.blocked()) return error.InvalidState;
        host.gate.resumeAfterPending(host.launch_identity.epoch, sequence) catch |err| {
            capture.controlGate(.{ .resume_return = .{ .sequence = sequence, .failure = err } });
            return err;
        };
        host.park_sequence = null;
        capture.controlGate(.{ .resume_return = .{ .sequence = sequence, .failure = null } });
    }
    fn worker(host: *Host, owner: *music.MusicRuntime) !music.MusicRuntime.LiveWorkerOutcomeV1 {
        const capture = try pinned(host, &get(host).finalization);
        capture.worker_begin_attempts +|= 1;
        capture.bootstrap.beginCombinedClosed(&capture.finalization) catch |err| {
            capture.config.worker.emit(capture.config.worker.context, .{ .rejected_entry = .{ .attempt = capture.worker_begin_attempts, .failure = err } });
            capture.worker_end_attempts +|= 1;
            return err;
        };
        const operation = capture.bootstrap.worker_operation;
        capture.config.worker.emit(capture.config.worker.context, .{ .enter = .{ .operation = operation, .begin = capture.bootstrap.worker_begin_receipt } });
        var failed = true;
        defer {
            // Typed result precedes this real lane end. Independent bookkeeping
            // remains valid if either append is lost, and ACK comes later.
            capture.bootstrap.endCombined(&capture.finalization, failed);
            capture.config.worker.emit(capture.config.worker.context, .{ .end = .{ .operation = operation, .end = capture.bootstrap.worker_end_receipt, .failed = failed } });
            capture.worker_end_attempts +|= 1;
        }
        capture.bootstrap.armCombined(&capture.finalization) catch |err| {
            capture.config.worker.emit(capture.config.worker.context, .{ .result = .{ .operation = operation, .value = err } });
            return @as(anyerror!music.MusicRuntime.LiveWorkerOutcomeV1, err);
        };
        const result = owner.workerOneLiveV1() catch |err| {
            capture.config.worker.emit(capture.config.worker.context, .{ .result = .{ .operation = operation, .value = err } });
            return @as(anyerror!music.MusicRuntime.LiveWorkerOutcomeV1, err);
        };
        capture.config.worker.emit(capture.config.worker.context, .{ .result = .{ .operation = operation, .value = result } });
        failed = false;
        return result;
    }
    fn cleanupRender(host: *Host) !void {
        const capture = get(host);
        const backend = &host.backend.?;
        const token = capture.quiescence orelse return error.InvalidState;
        if (backend.callback_registered or backend.context_initialized or
            (backend.state != .closed and backend.state != .stopped and backend.state != .lost)) return error.InvalidState;
        try host.renderer.?.validateDeviceQuiescence(token);
        capture.beginControl(.{ .cleanup_render = .{ .frames = backend.adapter.quantum_frames, .channels = backend.adapter.channels } });
        var failed = true;
        defer capture.endControl(failed);
        capture.beginRender(.shutdown);
        defer capture.endRender(failed);
        const first = host.renderer.?.renderFrame();
        backend.adapter.drainShutdownQuiescent(token) catch |err| {
            capture.resultControl(.{ .failure = err });
            return err;
        };
        const samples = @as(usize, backend.adapter.quantum_frames) * backend.adapter.channels;
        capture.config.render.emit(capture.config.render.context, .{ .cleanup_pcm = .{ .operation = capture.render_operations, .epoch = backend.adapter.device_epoch, .first_frame = first, .channels = backend.adapter.channels, .samples = backend.adapter.pending[0..samples] } });
        capture.resultControl(.done);
        failed = false;
    }
    fn boundary(host: *Host, capture: *Capture) void {
        capture.config.control.emit(capture.config.control.context, .{ .boundary = .{
            .owner_alive = capture.owner_alive,
            .control_torn_down = if (capture.owner_alive) host.owner.?.control_torn_down else null,
            .phase = capture.finalization.phase.load(.acquire),
            .report = capture.finalization.actual_report,
        } });
    }
    fn destroyTurn(host: *Host) !void {
        const capture = get(host);
        if (!capture.owner_alive) return finishDestroyed(host);
        if (!try park(host)) return;
        const sequence = host.park_sequence.?;
        const token = capture.quiescence orelse return error.InvalidState;
        const parked: Binding.Park = .{ .host = identity(host), .sequence = sequence };
        host.operation = .destroy;
        host.status.destroy_attempts +|= 1;
        if (capture.finalization.capability) |capability| {
            capture.beginControl(.{ .finalize = .{ .sequence = sequence, .nonce = capability.nonce } });
            var failed = true;
            defer capture.endControl(failed);
            const result = Binding.finalize(host.owner.?, capability) catch |err| {
                boundary(host, capture);
                capture.resultControl(.{ .failure = err });
                host.status.cleanup_error = err;
                return; // issued/sealed custody cannot resume
            };
            if (result != .destroyed) return error.UnexpectedRetainedCapability;
            capture.owner_alive = false;
            host.owner = null;
            host.status.sample_leases = result.destroyed.sample_leases;
            host.status.live_instances = result.destroyed.live_instances;
            host.status.phase = .provider_release;
            boundary(host, capture);
            capture.resultControl(.{ .destroyed = result.destroyed });
            failed = false;
            return;
        }
        if (capture.bootstrap.published_generation == null) {
            capture.beginControl(.{ .destroy_empty = sequence });
            var failed = true;
            defer capture.endControl(failed);
            const report = Binding.destroyEmpty(host.owner.?, &capture.finalization, parked, token) catch |err| {
                boundary(host, capture);
                capture.resultControl(.{ .failure = err });
                host.status.cleanup_error = err;
                try resumePending(host);
                return;
            };
            // The real Session has already stored destroyed_empty. Commit the
            // external dead state before any callback, stop or fallible retry.
            capture.owner_alive = false;
            capture.empty_destroyed = true;
            host.owner = null;
            host.status.sample_leases = report.sample_leases;
            host.status.live_instances = report.live_instances;
            host.status.phase = .provider_release;
            boundary(host, capture);
            capture.resultControl(.{ .destroyed = report });
            failed = false;
            return;
        }
        capture.beginControl(.{ .prepare = sequence });
        var failed = true;
        defer capture.endControl(failed);
        const result = Binding.prepare(host.owner.?, &capture.finalization, parked, token) catch |err| {
            boundary(host, capture);
            capture.resultControl(.{ .failure = err });
            host.status.cleanup_error = err;
            if (!capture.finalization.blocked()) try resumePending(host);
            return;
        };
        if (result == .destroyed) {
            capture.owner_alive = false;
            host.owner = null;
            host.status.sample_leases = result.destroyed.sample_leases;
            host.status.live_instances = result.destroyed.live_instances;
            host.status.phase = .provider_release;
        }
        boundary(host, capture);
        capture.resultControl(.{ .prepare = result });
        failed = false;
    }
    fn validateDestroyed(host: *Host) !*Capture {
        const capture = try pinned(host, &get(host).finalization);
        if (capture.owner_alive or host.owner != null or !capture.committed or host.terminal_stop_sent or
            capture.finalization.address != &capture.finalization or capture.bootstrap.address != &capture.bootstrap or
            capture.finalization.bootstrap != &capture.bootstrap or capture.bootstrap.combined != @as(?*anyopaque, @ptrCast(&capture.finalization)) or
            !std.meta.eql(capture.finalization.adapter.?.identity, identity(host))) return error.InvalidState;
        const sequence = host.park_sequence orelse return error.InvalidState;
        if (!host.gate.parked(host.launch_identity.epoch, sequence)) return error.InvalidState;
        if (capture.host_thread != std.Thread.getCurrentId()) return error.InvalidState;
        return capture;
    }
    fn validateDestroyedEmpty(host: *Host) !void {
        const capture = try validateDestroyed(host);
        if (!capture.empty_destroyed) return error.InvalidState;
        const sequence = host.park_sequence.?;
        if (capture.finalization.phase.load(.acquire) != .destroyed_empty or capture.finalization.capability != null) return error.InvalidState;
        const receipt = capture.finalization.empty_receipt orelse return error.InvalidState;
        if (!std.meta.eql(receipt.report, capture.finalization.actual_report orelse return error.InvalidState) or
            !std.meta.eql(receipt.park, @as(?Binding.Park, .{ .host = identity(host), .sequence = sequence })) or
            capture.worker_begin_attempts != capture.worker_end_attempts or capture.ack_end_attempts != capture.worker_end_attempts or
            capture.finalization.control != capture.bootstrap.control or capture.finalization.renderer != capture.bootstrap.renderer)
            return error.InvalidState;
        try capture.bootstrap.validateControlHooksAfterEmpty();
        try backendHooks(host, false);
    }
    fn finishDestroyed(host: *Host) !void {
        const capture = try validateDestroyed(host);
        const sequence = host.park_sequence.?;
        if (capture.empty_destroyed) {
            try validateDestroyedEmpty(host);
            host.gate.stopAfterDestroyed(host.launch_identity.epoch, sequence) catch |err| {
                capture.controlGate(.{ .stop_empty = .{ .sequence = sequence, .failure = err } });
                return err;
            };
            // No fallible work follows stop. Both embedded and surviving native
            // tables were validated before the original free/this stop commit.
            capture.controlGate(.{ .stop_empty = .{ .sequence = sequence, .failure = null } });
            capture.bootstrap.clearControlHooks();
            host.backend.?.test_callback_facts = null;
            host.backend.?.test_pcm = null;
            capture.engine_borrows_ended = true;
        } else {
            if (capture.finalization.phase.load(.acquire) != .destroyed or !capture.engine_borrows_ended or
                !host.gate.stopped.load(.acquire) or !std.meta.eql(capture.sealed, capture.finalization.capability)) return error.InvalidState;
        }
        host.terminal_stop_sent = true;
        host.worker_thread.?.join();
        host.worker_thread = null;
        host.status.worker_joined = true;
        capture.config.control.emit(capture.config.control.context, .worker_joined);
    }
} else struct {};

test "passive wait observer cannot attach to semantic or legacy capture options" {
    const t = std.testing;
    const Noop = struct {
        fn call(_: *anyopaque, _: TestWaitPoint) void {}
    };
    var marker: u8 = 0;
    var session: semantic.Session = .{};
    // The options gate must reject before dereferencing legacy capture, parsing
    // a bank, allocating a Host, or creating a native thread.
    const capture = try t.allocator.create(TestCapture.Session);
    defer t.allocator.destroy(capture);
    const invalid: Launch = .{ .document_id = 1, .revision = 1, .draft_hash = @splat(0), .state = @enumFromInt(1), .compiled = &.{} };
    const observer: TestWaitObserver = .{ .context = &marker, .call = Noop.call };
    inline for (.{ @as(@FieldType(semantic.Session, "mode"), .capture), @as(@FieldType(semantic.Session, "mode"), .replay) }) |mode| {
        session.mode = mode;
        try t.expectError(error.InvalidState, Host.create(invalid, .{ .io = t.io, .device = .{ .backend = .null_backend }, .semantic = &session, .test_wait_observer = observer }));
    }
    try t.expectError(error.InvalidState, Host.create(invalid, .{ .io = t.io, .test_capture = capture, .test_wait_observer = observer }));
}
