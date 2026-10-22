//! One pinned test-fixture Worker/Gate/session implementation. The runtime has
//! no dependency on this module. Register after real createV1, before load or
//! Worker start. Host owns this storage through actual final free and join.
const std = @import("std");
const audio = @import("bugu_audio");
const mailbox = @import("sme-author-live-mailbox");
const t = std.testing;
const Owner = audio.music.MusicRuntime;
const order = audio.runtime.capture_order;
pub const Binding = Owner.FinalizationTests;
pub const Renderer = audio.RuntimeRenderer;
var epochs: mailbox.EpochAllocator = .{};

pub const Driver = struct {
    const Command = enum(u8) { idle, requested, done };
    pub const ControlCall = enum { ordinary, finalization, playback_tick, cleanup_tick };
    pub const Mapping = struct { driver: *Driver, session: *Binding.Session, role: order.Role, role_operation: u64, main: u64 };
    pub const Boundary = struct {
        owner_alive: bool,
        control_torn_down: ?bool,
        phase: Binding.Session.Phase,
        capability_issued: bool,
        report: ?Binding.Report,
    };
    pub const SealFault = enum { none, before_store, after_store };
    pub const EndObserver = struct {
        context: *anyopaque,
        /// Bounded callback on the actual Worker, after the engine result and
        /// before workerCompleted/ACK. Cannot replace the engine return value.
        emit: *const fn (*anyopaque, anyerror!bool) void,
    };
    address: ?*Driver = null,
    owner: *Owner = undefined,
    session: Binding.Session = .{},
    bootstrap: Owner.BootstrapTests.Session = .{},
    joined_mode: bool = false,
    expected_observer: ?EndObserver = null,
    gate: mailbox.WorkerGate = undefined,
    thread: ?std.Thread = null,
    command: std.atomic.Value(Command) = .init(.idle),
    worker_exited: std.atomic.Value(bool) = .init(false),
    begin_attempts: std.atomic.Value(u64) = .init(0),
    end_attempts: std.atomic.Value(u64) = .init(0),
    ack_end_attempts: std.atomic.Value(u64) = .init(0),
    worked: bool = false,
    failure: ?anyerror = null,
    live_call: bool = false,
    registered: bool = false,
    owner_alive: bool = true,
    joined: bool = false,
    current_park: ?Binding.Park = null,
    end_observer: ?EndObserver = null,
    sealed: ?Binding.Capability = null,
    seal_fault: SealFault = .none,
    seal_attempts: usize = 0,
    fail_late_validate_once: bool = false,
    fail_after_borrow_end_once: bool = false,
    fail_empty_stop_once: bool = false,
    host_thread: ?std.Thread.Id = null,
    control_operations: u64 = 0,
    render_operations: u64 = 0,
    control_begin_attempts: u64 = 0,
    control_end_attempts: u64 = 0,
    render_begin_attempts: u64 = 0,
    render_end_attempts: u64 = 0,
    active_control: ?Mapping = null,
    active_control_call: ControlCall = .ordinary,
    active_render: ?Mapping = null,
    last_control_main: u64 = 0,
    last_render_main: u64 = 0,
    last_worker_main: u64 = 0,
    requested_main: ?u64 = null, // Host release / actual Worker acquire
    last_worker_mapping: ?Mapping = null, // Worker writes / Host acquires return
    mapping_incomplete: bool = false,
    last_boundary: ?Boundary = null,
    tick_request: ?Binding.TickRequest = null,
    tick_in_progress: bool = false,

    pub fn init(self: *Driver, owner: *Owner) !void {
        if (self.address != null) return error.InvalidState;
        self.* = .{ .address = self, .owner = owner, .host_thread = std.Thread.getCurrentId(), .gate = try mailbox.WorkerGate.init(try epochs.allocate()) };
        try Binding.bind(owner, &self.session, .{ .identity = self.identity(), .register = register, .validate_park = validatePark, .seal = seal });
    }
    /// Source-linked Service-only lifetime experiment. The fixture holds real
    /// DeviceQuiescence and admits no Render/consumer caller through final join.
    pub fn initJoined(self: *Driver, owner: *Owner, roles: audio.runtime.capture_order.Roles, bytes: []const u8, provider: audio.music.MusicSourceProviderV1, token: Renderer.DeviceQuiescence, observer: ?EndObserver) !void {
        return self.initJoinedHooks(owner, roles, bytes, provider, token, observer, null);
    }
    /// Same authenticated lifetime, with the exact existing callback table
    /// installed before preparation. This alone enables no Live API admission.
    pub fn initJoinedHooks(self: *Driver, owner: *Owner, roles: audio.runtime.capture_order.Roles, bytes: []const u8, provider: audio.music.MusicSourceProviderV1, token: Renderer.DeviceQuiescence, observer: ?EndObserver, hooks: ?Binding.Hooks) !void {
        if (self.address != null) return error.InvalidState;
        self.* = .{ .address = self, .owner = owner, .host_thread = std.Thread.getCurrentId(), .gate = try mailbox.WorkerGate.init(try epochs.allocate()), .joined_mode = true, .expected_observer = observer, .end_observer = observer };
        try Binding.bindJoinedHooks(owner, &self.session, &self.bootstrap, .{
            .identity = self.identity(),
            .register = register,
            .validate_park = validatePark,
            .seal = seal,
            .validate_startup = validateStartup,
            .validate_borrows = validateBorrows,
            .clear_borrows = clearBorrows,
            .validate_empty = validateEmpty,
            .after_borrow_end = afterBorrowEnd,
            .validate_tick = validateTick,
        }, roles, bytes, provider, token, hooks);
    }
    fn validateStartup(raw: *anyopaque, owner: *Owner, session: *const Binding.Session) !void {
        const self = from(raw);
        if (self.address != self or !self.registered or !self.joined_mode or !self.owner_alive or self.owner != owner or session != &self.session or
            session.bootstrap != &self.bootstrap or self.bootstrap.combined != @as(?*anyopaque, @ptrCast(&self.session)) or self.thread == null or self.joined or
            self.command.load(.acquire) != .idle or self.current_park != null or self.gate.stopped.load(.acquire) or
            self.begin_attempts.load(.acquire) != self.end_attempts.load(.acquire)) return error.InvalidState;
        try validateBorrows(raw, session, false);
    }
    fn validateBorrows(raw: *anyopaque, session: *const Binding.Session, ended: bool) !void {
        const self = from(raw);
        if (self.address != self or !self.registered or !self.joined_mode or !self.owner_alive or session != &self.session or
            session.bootstrap != &self.bootstrap or self.bootstrap.combined != @as(?*anyopaque, @ptrCast(&self.session)) or self.command.load(.acquire) != .idle or
            !std.meta.eql(self.end_observer, if (ended) @as(?EndObserver, null) else self.expected_observer)) return error.InvalidState;
    }
    fn clearBorrows(raw: *anyopaque, session: *const Binding.Session) void {
        const self = from(raw);
        std.debug.assert(session == &self.session and self.joined_mode and self.gate.stopped.load(.acquire));
        std.debug.assert(std.meta.eql(self.end_observer, self.expected_observer));
        self.end_observer = null;
    }
    fn afterBorrowEnd(raw: *anyopaque) !void {
        const self = from(raw);
        if (self.fail_after_borrow_end_once) {
            self.fail_after_borrow_end_once = false;
            return error.TestAfterBorrowEnd;
        }
    }
    fn validateEmpty(raw: *anyopaque, owner: *Owner, session: *const Binding.Session, park_request: ?Binding.Park) !void {
        const self = from(raw);
        try validateBorrows(raw, session, false);
        if (owner != self.owner or session.owner != owner or self.joined or self.gate.stopped.load(.acquire)) return error.InvalidState;
        if (self.thread != null) {
            try validatePark(raw, owner, session, park_request orelse return error.InvalidState);
        } else if (park_request != null or self.current_park != null or self.gate.sequence != 0 or
            self.begin_attempts.load(.acquire) != 0 or self.end_attempts.load(.acquire) != 0 or
            self.gate.request.load(.acquire) != 0 or self.gate.acknowledgment.load(.acquire) != 0) return error.InvalidState;
    }
    pub fn start(self: *Driver) !void {
        if (self.address != self or !self.registered or self.thread != null or self.joined or !self.owner_alive or
            self.session.phase.load(.acquire) != .registered or self.gate.stopped.load(.acquire)) return error.InvalidState;
        // On spawn error, Host must retain this registered storage until the
        // ordinary never-loaded owner is really destroyed. Never undo identity.
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }
    pub fn started(self: *const Driver) bool {
        return self.address == self and self.thread != null;
    }
    fn identity(self: *Driver) Binding.HostIdentity {
        return .{ .context = self, .gate = &self.gate, .epoch = self.gate.epoch };
    }
    fn from(raw: *anyopaque) *Driver {
        return @ptrCast(@alignCast(raw));
    }
    fn register(raw: *anyopaque, owner: *Owner, session: *Binding.Session, identity_value: Binding.HostIdentity) !void {
        const self = from(raw);
        if (self.address != self or self.registered or self.thread != null or self.owner != owner or session != &self.session or
            !std.meta.eql(identity_value, self.identity()) or self.gate.sequence != 0 or
            self.gate.request.load(.acquire) != 0 or self.gate.acknowledgment.load(.acquire) != 0 or self.gate.stopped.load(.acquire)) return error.InvalidState;
        self.registered = true;
    }
    fn validatePark(raw: *anyopaque, owner: *Owner, session: *const Binding.Session, park_request: Binding.Park) !void {
        const self = from(raw);
        if (self.address != self or !self.registered or !self.owner_alive or owner != self.owner or session != &self.session or
            session.owner != owner or session.owner_slot != &owner.test_finalization or owner.test_finalization != session or
            !std.meta.eql(park_request.host, self.identity()) or !self.gate.parked(self.gate.epoch, park_request.sequence) or
            self.command.load(.acquire) != .idle or self.begin_attempts.load(.acquire) != self.end_attempts.load(.acquire) or
            self.ack_end_attempts.load(.acquire) != self.end_attempts.load(.acquire)) return error.InvalidState;
        if (self.fail_late_validate_once and owner.control_torn_down and owner.generation == null) {
            self.fail_late_validate_once = false;
            return error.TestLateValidation;
        }
        if (self.gate.stopped.load(.acquire)) {
            const sealed = self.sealed orelse return error.InvalidState;
            const actual = session.capability orelse return error.InvalidState;
            const phase = session.phase.load(.acquire);
            if ((phase != .sealing and phase != .sealed and phase != .borrow_ended) or !std.meta.eql(sealed, actual) or
                sealed.owner != owner or sealed.session != session or !std.meta.eql(sealed.park, park_request)) return error.InvalidState;
        }
    }
    fn seal(raw: *anyopaque, capability: Binding.Capability) !void {
        const self = from(raw);
        try validatePark(raw, capability.owner, capability.session, capability.park);
        if (capability.owner.owned_streaming != capability.service or capability.owner.test_finalization_nonce != capability.nonce or
            capability.nonce == 0 or !std.meta.eql(self.session.capability.?, capability)) return error.InvalidState;
        self.seal_attempts += 1;
        if (self.sealed) |actual| {
            if (!std.meta.eql(actual, capability) or !self.gate.stopped.load(.acquire)) return error.InvalidState;
            return;
        }
        if (self.seal_fault == .before_store) {
            self.seal_fault = .none;
            return error.TestBeforeSeal;
        }
        try mailbox.WorkerGate.FinalizationTests.seal(&self.gate, self.gate.epoch, capability.park.sequence);
        self.sealed = capability;
        if (self.seal_fault == .after_store) {
            self.seal_fault = .none;
            return error.TestAfterSeal;
        }
    }
    fn guard(began: std.Io.Timestamp) void {
        if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds > 30 * std.time.ns_per_s)
            @panic("finalization fixture Worker timeout; all live custody retained");
        std.atomic.spinLoopHint();
    }
    fn workerMain(self: *Driver) void {
        while (true) {
            if (self.gate.stopped.load(.acquire) or self.gate.request.load(.acquire) != self.gate.resumed.load(.acquire)) {
                const action = self.gate.workerAction(self.gate.epoch) catch @panic("actual Worker Gate invariant");
                switch (action) {
                    .stop => {
                        self.worker_exited.store(true, .release);
                        return;
                    },
                    .park => |sequence| {
                        self.ack_end_attempts.store(self.end_attempts.load(.acquire), .release);
                        self.gate.acknowledgePark(self.gate.epoch, sequence) catch @panic("actual Worker ACK invariant");
                        while (!self.gate.stopped.load(.acquire) and self.gate.resumed.load(.acquire) != sequence) std.atomic.spinLoopHint();
                    },
                    .work => @panic("unexpected work during park request"),
                }
                continue;
            }
            if (self.command.load(.acquire) != .requested) {
                std.atomic.spinLoopHint();
                continue;
            }
            const action = self.gate.workerAction(self.gate.epoch) catch @panic("actual Worker operation admission");
            if (action != .work) @panic("fixture command raced a Control park");
            _ = self.begin_attempts.fetchAdd(1, .release);
            self.last_worker_mapping = null;
            self.failure = null;
            var combined_began = false;
            if (self.joined_mode) {
                self.bootstrap.beginCombined(&self.session) catch |err| {
                    self.failure = err;
                };
                combined_began = self.failure == null;
            }
            if (self.requested_main) |main| {
                if (combined_began) {
                    self.last_worker_mapping = .{ .driver = self, .session = &self.session, .role = .worker, .role_operation = self.bootstrap.worker_operation, .main = main };
                    if (self.bootstrap.attribution_overflow) self.mapping_incomplete = true;
                }
            }
            self.worked = if (self.failure != null) false else if (self.live_call) live: {
                const outcome = self.owner.workerOneLiveV1() catch |err| {
                    self.failure = err;
                    break :live false;
                };
                break :live outcome.worked;
            } else self.owner.workerOneV1() catch |err| failure: {
                self.failure = err;
                break :failure false;
            };
            // Actual result, lane end, independent end, then progress/ACK. All
            // attempts occur even when a bounded recorder has already poisoned.
            if (self.end_observer) |observer| observer.emit(observer.context, if (self.failure) |err| @as(anyerror!bool, err) else self.worked);
            if (combined_began) self.bootstrap.endCombined(&self.session, self.failure != null);
            _ = self.end_attempts.fetchAdd(1, .release);
            self.gate.workerCompleted(self.gate.epoch) catch @panic("actual Worker completion invariant");
            self.command.store(.done, .release);
        }
    }
    pub fn one(self: *Driver, live_call: bool) !bool {
        if (self.address != self or !self.started() or self.command.load(.acquire) != .idle or self.current_park != null or self.session.blocked() or self.gate.stopped.load(.acquire)) return error.InvalidState;
        if (self.joined_mode and live_call) return error.InvalidMode;
        self.live_call = live_call;
        self.command.store(.requested, .release);
        const began = std.Io.Clock.awake.now(t.io);
        while (self.command.load(.acquire) != .done) guard(began);
        self.command.store(.idle, .release);
        if (self.failure) |err| return err;
        return self.worked;
    }
    /// Fixed-fixture identity only. This is not generic public Control caller
    /// authentication. All peer fields are read under actual returned-command
    /// exclusion; post-free end paths never follow owner/backlinks.
    fn mappedHost(self: *Driver, require_owner: bool) !void {
        if (self.address != self or !self.registered or !self.joined_mode or self.host_thread != std.Thread.getCurrentId() or
            self.session.address != &self.session or self.bootstrap.address != &self.bootstrap or self.session.bootstrap != &self.bootstrap or
            self.bootstrap.combined != @as(?*anyopaque, @ptrCast(&self.session)) or self.command.load(.acquire) != .idle or
            (require_owner and !self.owner_alive)) return error.InvalidState;
        const roles = self.bootstrap.roles orelse return error.InvalidState;
        inline for (.{ order.Role.control, order.Role.render, order.Role.worker }) |role| {
            const lane = roles.get(role);
            if (lane.address != lane or lane.role != role) return error.InvalidState;
        }
    }
    fn nextMapped(self: *Driver, role: order.Role, counter: *u64, main: u64) Mapping {
        const lane = self.bootstrap.roles.?.get(role);
        const operation = std.math.add(u64, counter.*, 1) catch exhausted: {
            self.mapping_incomplete = true;
            lane.invalidateSource();
            break :exhausted counter.*;
        };
        // Attempt the real endpoint even after evidence loss. The collector is
        // sticky-failed on overflow; wrapper custody never depends on its health.
        lane.begin(operation);
        counter.* = operation;
        return .{ .driver = self, .session = &self.session, .role = role, .role_operation = operation, .main = main };
    }
    pub fn beginControl(self: *Driver, main: u64, call: ControlCall) !Mapping {
        if (call == .playback_tick or call == .cleanup_tick) return error.InvalidState;
        return self.beginControlKind(main, call);
    }
    fn beginControlKind(self: *Driver, main: u64, call: ControlCall) !Mapping {
        try self.mappedHost(true);
        if (self.active_control != null or self.active_render != null or main == 0 or main < self.last_control_main or
            (call != .finalization and self.session.phase.load(.acquire) != .registered)) return error.InvalidState;
        self.control_begin_attempts +|= 1;
        const mapping = self.nextMapped(.control, &self.control_operations, main);
        self.active_control = mapping;
        self.active_control_call = call;
        self.last_control_main = main;
        return mapping;
    }
    pub fn endControl(self: *Driver, mapping: Mapping, failed: bool) !void {
        try self.mappedHost(false);
        if (self.active_render != null or !std.meta.eql(self.active_control orelse return error.InvalidState, mapping)) return error.InvalidState;
        if (self.tick_in_progress or self.session.tick_executing) return error.InvalidState;
        if (self.tick_request) |request_value| {
            try self.session.endTick(request_value, failed);
            self.tick_request = null;
        }
        self.bootstrap.roles.?.control.end(@intFromBool(failed));
        self.control_end_attempts +|= 1;
        self.active_control = null;
    }
    fn validateTick(raw: *anyopaque, request_value: Binding.TickRequest, stage: Binding.TickStage) !void {
        const self = from(raw);
        try self.mappedHost(true);
        const mapping = self.active_control orelse return error.InvalidState;
        if (self.active_render != null or request_value.owner != self.owner or request_value.session != &self.session or
            request_value.operation != mapping.role_operation or request_value.main != mapping.main or
            !std.meta.eql(self.tick_request orelse return error.InvalidState, request_value) or
            self.active_control_call != (if (request_value.mode == .playback) ControlCall.playback_tick else ControlCall.cleanup_tick) or
            self.tick_in_progress != (stage != .issue)) return error.InvalidState;
    }
    pub fn beginTick(self: *Driver, main: u64, mode: Binding.TickMode, limit: usize, sink: ?audio.runtime.ControlRuntime.LiveAcceptanceSinkV1) !Mapping {
        const mapping = try self.beginControlKind(main, if (mode == .playback) .playback_tick else .cleanup_tick);
        const request_value: Binding.TickRequest = .{ .owner = self.owner, .session = &self.session, .operation = mapping.role_operation, .main = main, .mode = mode, .limit = limit, .sink = sink };
        self.tick_request = request_value;
        self.session.issueTick(request_value) catch |err| {
            self.tick_request = null;
            self.active_control_call = .ordinary;
            self.endControl(mapping, true) catch @panic("failed tick issue retained active span");
            return err;
        };
        return mapping;
    }
    pub fn tick(self: *Driver, mapping: Mapping, mode: Binding.TickMode, limit: usize, sink: ?audio.runtime.ControlRuntime.LiveAcceptanceSinkV1) !Owner.LiveControlTickOutcomeV1 {
        try self.mappedHost(true);
        if (self.tick_in_progress or self.active_render != null or
            !std.meta.eql(self.active_control orelse return error.InvalidState, mapping)) return error.InvalidState;
        const request_value: Binding.TickRequest = .{ .owner = self.owner, .session = &self.session, .operation = mapping.role_operation, .main = mapping.main, .mode = mode, .limit = limit, .sink = sink };
        if (!std.meta.eql(self.tick_request orelse return error.InvalidState, request_value)) return error.InvalidState;
        self.tick_in_progress = true;
        defer self.tick_in_progress = false;
        return Binding.tick(self.owner, request_value);
    }
    pub fn beginRender(self: *Driver, main: u64) !Mapping {
        try self.mappedHost(true);
        if (self.active_render != null or main == 0 or main < self.last_render_main or self.session.phase.load(.acquire) != .registered or
            self.bootstrap.stage != .published or (self.active_control != null and self.active_control_call == .finalization)) return error.InvalidState;
        // Fixed Host exclusion: no registered device producer or retained
        // startup/final token may overlap this real direct Render call.
        const renderer = self.session.renderer orelse return error.InvalidState;
        if (renderer.device_callbacks_active.load(.acquire) or renderer.device_access.load(.acquire) != 0 or
            renderer.device_quiescence_active.load(.acquire) != 0) return error.InvalidState;
        self.render_begin_attempts +|= 1;
        const mapping = self.nextMapped(.render, &self.render_operations, main);
        self.active_render = mapping;
        self.last_render_main = main;
        return mapping;
    }
    pub fn endRender(self: *Driver, mapping: Mapping, failed: bool) !void {
        try self.mappedHost(false);
        if (!std.meta.eql(self.active_render orelse return error.InvalidState, mapping)) return error.InvalidState;
        self.bootstrap.roles.?.render.end(@intFromBool(failed));
        self.render_end_attempts +|= 1;
        self.active_render = null;
    }
    /// Correspondence only: the existing actual Worker generates its own role
    /// operation. Never assign an expected tape value to Bootstrap's counter.
    pub fn oneMapped(self: *Driver, main: u64) !bool {
        try self.mappedHost(true);
        if (main == 0 or main < self.last_worker_main or self.requested_main != null or self.active_control != null or self.active_render != null) return error.InvalidState;
        self.last_worker_mapping = null;
        self.requested_main = main;
        defer self.requested_main = null;
        const before = self.begin_attempts.load(.acquire);
        defer if (self.begin_attempts.load(.acquire) != before) {
            self.last_worker_main = main;
        };
        return self.one(false);
    }
    /// May be read by the existing result callback on the actual Worker, or by
    /// Host after the genuine command return. No cross-role polling is allowed.
    pub fn workerMapping(self: *const Driver) ?Mapping {
        if (self.address != self) return null;
        return self.last_worker_mapping;
    }
    fn requireFinalizationSpan(self: *Driver, allow_never_started: bool) !void {
        try self.mappedHost(true);
        if (self.active_control == null or self.active_control_call != .finalization or self.active_render != null or
            ((!allow_never_started or self.thread != null) and self.current_park == null)) return error.InvalidState;
    }
    fn rememberBoundary(self: *Driver) void {
        self.last_boundary = .{
            .owner_alive = self.owner_alive,
            .control_torn_down = if (self.owner_alive) self.owner.control_torn_down else null,
            .phase = self.session.phase.load(.acquire),
            .capability_issued = self.session.capability != null,
            .report = self.session.actual_report,
        };
    }
    pub fn prepareObserved(self: *Driver, token: Renderer.DeviceQuiescence) !Binding.Outcome {
        try self.mappedHost(true);
        self.last_boundary = null;
        try self.requireFinalizationSpan(false);
        const result = self.prepare(token) catch |err| {
            self.rememberBoundary();
            return err;
        };
        if (result == .destroyed) self.owner_alive = false;
        self.rememberBoundary();
        return result;
    }
    pub fn finalizeObserved(self: *Driver, capability: Binding.Capability) !Binding.Report {
        try self.mappedHost(true);
        self.last_boundary = null;
        try self.requireFinalizationSpan(false);
        const result = self.finalize(capability) catch |err| {
            self.rememberBoundary();
            return err;
        };
        self.rememberBoundary();
        return result;
    }
    pub fn destroyEmptyObserved(self: *Driver, token: Renderer.DeviceQuiescence) !Binding.Report {
        try self.mappedHost(true);
        self.last_boundary = null;
        try self.requireFinalizationSpan(true);
        const result = self.destroyEmpty(token) catch |err| {
            self.rememberBoundary();
            return err;
        };
        self.rememberBoundary();
        return result;
    }

    pub fn attachEndObserver(self: *Driver, observer: EndObserver) !void {
        if (self.address != self or self.joined_mode or !self.started() or self.command.load(.acquire) != .idle or self.end_observer != null or self.session.blocked()) return error.InvalidState;
        self.end_observer = observer;
    }
    pub fn detachEndObserver(self: *Driver, expected: EndObserver) !void {
        if (self.address != self or self.joined_mode or self.command.load(.acquire) != .idle or self.end_observer == null or !std.meta.eql(self.end_observer.?, expected)) return error.InvalidState;
        self.end_observer = null;
    }
    pub fn park(self: *Driver) !Binding.Park {
        if (self.address != self or !self.started() or self.current_park != null or self.command.load(.acquire) != .idle) return error.InvalidState;
        const sequence = try self.gate.requestPark(self.gate.epoch);
        const began = std.Io.Clock.awake.now(t.io);
        while (!self.gate.parked(self.gate.epoch, sequence)) guard(began);
        const value: Binding.Park = .{ .host = self.identity(), .sequence = sequence };
        self.current_park = value;
        return value;
    }
    pub fn resumePending(self: *Driver) !void {
        if (self.address != self) return error.InvalidState;
        const value = self.current_park orelse return error.InvalidState;
        if (self.session.blocked()) return error.InvalidState;
        try self.gate.resumeAfterPending(self.gate.epoch, value.sequence);
        self.current_park = null;
    }
    pub fn prepare(self: *Driver, token: Renderer.DeviceQuiescence) !Binding.Outcome {
        // This playback-scoped fixture records only the pre-teardown interval.
        // Full-lifecycle capture must instead retain its close/end observers
        // through sealing, then detach the exact issued borrowed set.
        if (self.address != self or !self.owner_alive or (!self.joined_mode and self.end_observer != null)) return error.InvalidState;
        const value = if (self.current_park) |current| current else try self.park();
        return Binding.prepare(self.owner, &self.session, value, token);
    }
    pub fn finalize(self: *Driver, capability: Binding.Capability) !Binding.Report {
        if (self.address != self or !self.owner_alive or (!self.joined_mode and self.end_observer != null)) return error.InvalidState;
        const outcome = try Binding.finalize(self.owner, capability);
        if (outcome != .destroyed) return error.UnexpectedRetainedCapability;
        self.owner_alive = false;
        return outcome.destroyed;
    }
    /// Genuine empty/rolled-back owner route; no fabricated Service capability.
    /// Once free returns, dead/receipt state is retained before any fallible stop.
    pub fn destroyEmpty(self: *Driver, token: Renderer.DeviceQuiescence) !Binding.Report {
        if (self.address != self or !self.joined_mode or !self.owner_alive) return error.InvalidState;
        const parked = if (self.thread == null) null else if (self.current_park) |value| value else try self.park();
        const report = try Binding.destroyEmpty(self.owner, &self.session, parked, token);
        self.owner_alive = false;
        return report;
    }
    pub fn stopAndJoinEmpty(self: *Driver) !void {
        if (self.address != self or !self.joined_mode or self.owner_alive or self.joined or self.session.phase.load(.acquire) != .destroyed_empty) return error.InvalidState;
        // Only retained Host/session state is valid after the actual owner
        // free. Pointer identity comparisons do not dereference that owner.
        if (!self.registered or self.host_thread != std.Thread.getCurrentId() or self.session.address != &self.session or
            self.session.owner != self.owner or self.session.bootstrap != &self.bootstrap or self.session.capability != null or
            self.bootstrap.address != &self.bootstrap or self.bootstrap.owner != @as(*anyopaque, @ptrCast(self.owner)) or
            self.bootstrap.combined != @as(?*anyopaque, @ptrCast(&self.session)) or
            self.session.control != self.bootstrap.control or self.session.renderer != self.bootstrap.renderer or
            !std.meta.eql((self.session.adapter orelse return error.InvalidState).identity, self.identity()) or
            self.command.load(.acquire) != .idle or self.begin_attempts.load(.acquire) != self.end_attempts.load(.acquire)) return error.InvalidState;
        const receipt = self.session.empty_receipt orelse return error.InvalidState;
        if (!std.meta.eql(receipt.report, self.session.actual_report orelse return error.InvalidState) or
            !std.meta.eql(receipt.park, self.current_park) or !std.meta.eql(self.end_observer, self.expected_observer)) return error.InvalidState;
        if (self.thread != null) {
            const parked = receipt.park orelse return error.InvalidState;
            if (!std.meta.eql(parked.host, self.identity()) or !self.gate.parked(self.gate.epoch, parked.sequence) or
                self.ack_end_attempts.load(.acquire) != self.end_attempts.load(.acquire)) return error.InvalidState;
        } else if (receipt.park != null or self.current_park != null or self.gate.sequence != 0 or
            self.begin_attempts.load(.acquire) != 0 or self.gate.request.load(.acquire) != 0 or
            self.gate.acknowledgment.load(.acquire) != 0 or self.gate.stopped.load(.acquire)) return error.InvalidState;
        try self.bootstrap.validateControlHooksAfterEmpty();
        if (self.fail_empty_stop_once) {
            self.fail_empty_stop_once = false;
            return error.TestEmptyStop;
        }
        if (self.thread != null) {
            const parked = receipt.park orelse return error.InvalidState;
            if (!std.meta.eql(parked.host, self.identity())) return error.InvalidState;
            try self.gate.stopAfterDestroyed(self.gate.epoch, parked.sequence);
        } else if (receipt.park != null) return error.InvalidState;
        // Owner is already dead. The registered Host-pinned Control pointer
        // survives through joins; never follow its owner backlink here.
        self.bootstrap.clearControlHooks();
        self.end_observer = null;
        if (self.thread) |thread| {
            const began = std.Io.Clock.awake.now(t.io);
            while (!self.worker_exited.load(.acquire)) guard(began);
            thread.join();
            self.thread = null;
        }
        self.joined = true;
    }
    pub fn joinAfterDestroyed(self: *Driver) !void {
        if (self.address != self or self.owner_alive or self.session.phase.load(.acquire) != .destroyed or self.thread == null or self.end_observer != null) return error.InvalidState;
        const began = std.Io.Clock.awake.now(t.io);
        while (!self.worker_exited.load(.acquire)) guard(began);
        self.thread.?.join();
        self.thread = null;
        self.joined = true;
    }
};
