//! Test-only actual late destruction boundary. This registered adapter is a
//! fixed qualification fixture, not a public pluggable proof or Host admission.
//! Runtime owns the token/nonce; the fixture verifies real Gate custody. No
//! runtime dependency on tools, and no caller-supplied parked/sealed boolean.
const std = @import("std");
const rt = @import("bugu_audio").runtime;
const resident = @import("resident_runtime.zig");
const Owner = resident.MusicRuntime;
const Service = rt.streaming.Service;
const Bootstrap = @import("live_bootstrap_test_binding.zig");

/// Joined-only inventory. These pre-existing Control test hooks are foreign
/// to the Service-only lifetime seam, including ordinary shutdown collection.
/// Standalone bootstrap/finalization retain their established behavior.
pub fn validateJoinedControlHooks(control: *rt.ControlRuntime) !void {
    if (control.test_readiness_observation != null or control.test_live_readiness_checkpoint_hook != null or
        control.test_control_frontier_hook != null or control.test_before_collection_hook != null) return error.InvalidState;
}

pub const HostIdentity = struct { context: *anyopaque, gate: *anyopaque, epoch: u64 };
pub const Park = struct { host: HostIdentity, sequence: u64 };
pub const Capability = struct {
    owner: *Owner,
    session: *Session,
    service: *Service,
    park: Park,
    nonce: u64,
    quiescence: rt.RuntimeRenderer.DeviceQuiescence,
};
pub const TickMode = enum { playback, cleanup };
pub const TickStage = enum { issue, owner, control };
pub const TickRequest = struct {
    owner: *Owner,
    session: *Session,
    operation: u64,
    main: u64,
    mode: TickMode,
    limit: usize,
    sink: ?rt.ControlRuntime.LiveAcceptanceSinkV1,
};
pub const Adapter = struct {
    /// Fixed by the registered internal adapter. The kind alone grants no
    /// authority: every stage still validates the actual pinned caller tuple.
    tick_kind: enum { serialized, independent_host } = .serialized,
    identity: HostIdentity,
    /// Called before any registration mutation, under actual fixture startup
    /// exclusion. The fixed adapter checks both pinned directions and real Gate.
    register: *const fn (*anyopaque, *Owner, *Session, HostIdentity) anyerror!void,
    /// Reads the actual current Gate request/ACK, not an abstract idle flag.
    validate_park: *const fn (*anyopaque, *Owner, *const Session, Park) anyerror!void,
    /// Revalidates exact capability/Gate before the real irreversible seal.
    /// Retry must be idempotent for this same capability after a partial error.
    seal: *const fn (*anyopaque, Capability) anyerror!void,
    // Joined fixture callbacks are fixed at registration. They validate actual
    // command/startup custody and exact observer identity, never recorder health.
    validate_startup: ?*const fn (*anyopaque, *Owner, *const Session) anyerror!void = null,
    validate_borrows: ?*const fn (*anyopaque, *const Session, bool) anyerror!void = null,
    clear_borrows: ?*const fn (*anyopaque, *const Session) void = null,
    validate_empty: ?*const fn (*anyopaque, *Owner, *const Session, ?Park) anyerror!void = null,
    after_borrow_end: ?*const fn (*anyopaque) anyerror!void = null,
    validate_tick: ?*const fn (*anyopaque, TickRequest, TickStage) anyerror!void = null,
};
pub const Request = struct { session: *Session, park: Park, quiescence: rt.RuntimeRenderer.DeviceQuiescence };
pub const EmptyRequest = struct { session: *Session, park: ?Park, quiescence: rt.RuntimeRenderer.DeviceQuiescence };
pub const EmptyReceipt = struct { park: ?Park, report: resident.ShutdownReport };
pub const Outcome = union(enum) { ready_for_final_free: Capability, destroyed: resident.ShutdownReport };
pub const Session = struct {
    pub const Phase = enum(u8) { empty, registered, issued, sealing, sealed, borrow_ended, destroyed, destroyed_empty };
    address: ?*Session = null,
    owner: ?*Owner = null,
    owner_slot: ?*?*Session = null,
    renderer: ?*rt.RuntimeRenderer = null,
    control: ?*rt.ControlRuntime = null,
    adapter: ?Adapter = null,
    // Control writes; accidental Worker entry only reads this atomic admission
    // state. Recorder health and lane active_operation are irrelevant here.
    phase: std.atomic.Value(Phase) = .init(.empty),
    capability: ?Capability = null,
    actual_report: ?resident.ShutdownReport = null,
    bootstrap: ?*Bootstrap.Session = null,
    startup_quiescence: ?rt.RuntimeRenderer.DeviceQuiescence = null,
    empty_receipt: ?EmptyReceipt = null,
    // Actual fixed Control caller owns these independently of collector health.
    tick_request: ?TickRequest = null,
    tick_stage: enum { idle, owner_ready, control_ready, consumed } = .idle,
    tick_executing: bool = false,

    fn tickIdentity(self: *const Session, request_value: TickRequest) !void {
        if (request_value.session != self or request_value.operation == 0 or request_value.main == 0 or
            self.phase.load(.acquire) != .registered) return error.InvalidState;
        _ = try self.validateJoined(request_value.owner);
    }
    fn tickAdapter(self: *const Session, request_value: TickRequest, stage: TickStage) !void {
        const adapter = self.adapter orelse return error.InvalidState;
        try (adapter.validate_tick orelse return error.InvalidState)(adapter.identity.context, request_value, stage);
    }
    pub fn issueTick(self: *Session, request_value: TickRequest) !void {
        try self.tickIdentity(request_value);
        if (self.tick_request != null or self.tick_stage != .idle or self.tick_executing) return error.InvalidState;
        try self.tickAdapter(request_value, .issue);
        self.tick_request = request_value;
        self.tick_stage = .owner_ready;
    }
    pub fn enterTickOwner(self: *Session, request_value: TickRequest) !void {
        try self.tickIdentity(request_value);
        if (self.tick_executing or self.tick_stage != .owner_ready or
            !std.meta.eql(self.tick_request orelse return error.InvalidState, request_value)) return error.InvalidState;
        try self.tickAdapter(request_value, .owner);
        self.tick_stage = .control_ready;
        self.tick_executing = true;
    }
    pub fn enterTickControl(self: *Session, request_value: TickRequest, control: *rt.ControlRuntime) !void {
        try self.tickIdentity(request_value);
        if (!self.tick_executing or self.tick_stage != .control_ready or self.control != control or
            !std.meta.eql(self.tick_request orelse return error.InvalidState, request_value)) return error.InvalidState;
        try self.tickAdapter(request_value, .control);
        self.tick_stage = .consumed;
    }
    pub fn returnedTick(self: *Session, request_value: TickRequest) void {
        std.debug.assert(self.tick_executing and std.meta.eql(self.tick_request.?, request_value));
        self.tick_executing = false;
    }
    pub fn endTick(self: *Session, request_value: TickRequest, failed: bool) !void {
        if (self.address != self or self.tick_executing or
            !std.meta.eql(self.tick_request orelse return error.InvalidState, request_value) or
            (!failed and self.tick_stage != .consumed)) return error.InvalidState;
        self.tick_request = null;
        self.tick_stage = .idle;
    }

    pub fn blocked(self: *const Session) bool {
        return @intFromEnum(self.phase.load(.acquire)) >= @intFromEnum(Phase.issued);
    }
    pub fn register(self: *Session, owner: *Owner, slot: *?*Session, adapter: Adapter) !void {
        try self.validateRegister(slot, adapter);
        try adapter.register(adapter.identity.context, owner, self, adapter.identity);
        self.commitRegister(owner, slot, adapter);
    }
    pub fn validateRegister(self: *const Session, slot: *?*Session, adapter: Adapter) !void {
        if (self.address != null or self.phase.load(.acquire) != .empty or slot.* != null or adapter.identity.epoch == 0) return error.InvalidState;
    }
    pub fn commitRegister(self: *Session, owner: *Owner, slot: *?*Session, adapter: Adapter) void {
        self.address = self;
        self.owner = owner;
        self.owner_slot = slot;
        self.control = owner.control;
        self.renderer = owner.renderer;
        self.adapter = adapter;
        slot.* = self;
        self.phase.store(.registered, .release);
    }
    pub fn identity(self: *const Session, owner: *Owner, slot: *?*Session) !void {
        if (self.phase.load(.acquire) == .empty or (self.phase.load(.acquire) == .destroyed or self.phase.load(.acquire) == .destroyed_empty) or
            self.address != self or self.owner != owner or self.owner_slot != slot or slot.* != self or
            self.control != owner.control or self.renderer != owner.renderer) return error.InvalidState;
    }
    pub fn request(self: *const Session, owner: *Owner, slot: *?*Session, park: Park, token: rt.RuntimeRenderer.DeviceQuiescence) !void {
        try self.identity(owner, slot);
        const adapter = self.adapter orelse return error.InvalidState;
        if (park.sequence == 0 or !std.meta.eql(adapter.identity, park.host)) return error.InvalidState;
        try owner.renderer.validateDeviceQuiescence(token);
        try adapter.validate_park(adapter.identity.context, owner, self, park);
    }
    pub fn validateCapability(self: *const Session, owner: *Owner, slot: *?*Session, capability: Capability) !void {
        try self.identity(owner, slot);
        const actual = self.capability orelse return error.InvalidState;
        if (capability.owner != owner or capability.session != self or capability.nonce == 0 or
            capability.nonce != owner.test_finalization_nonce or !std.meta.eql(actual, capability)) return error.InvalidState;
        try self.request(owner, slot, capability.park, capability.quiescence);
    }
    pub fn issued(self: *Session, capability: Capability) void {
        std.debug.assert(self.phase.load(.acquire) == .registered and self.capability == null);
        self.capability = capability;
        self.phase.store(.issued, .release);
    }
    /// Called only after the owner revalidates all real destroy predicates.
    /// The phase becomes irrevocable before invoking the adapter: even an
    /// error after it stopped Gate cannot allow ordinary entry or resume.
    pub fn seal(self: *Session, capability: Capability) !void {
        const phase = self.phase.load(.acquire);
        if (phase != .issued and phase != .sealing and phase != .sealed) return error.InvalidState;
        self.phase.store(.sealing, .release);
        const adapter = self.adapter.?;
        try adapter.seal(adapter.identity.context, capability);
        self.phase.store(.sealed, .release);
    }
    pub fn validateJoined(self: *const Session, owner: *Owner) !*Bootstrap.Session {
        try self.identity(owner, &owner.test_finalization);
        const bootstrap = self.bootstrap orelse return error.InvalidState;
        if (owner.test_live_bootstrap != bootstrap or bootstrap.combined != @as(?*anyopaque, @ptrCast(@constCast(self)))) return error.InvalidState;
        try bootstrap.validateOwner(owner, &owner.test_live_bootstrap, owner.control, owner.renderer);
        return bootstrap;
    }
    pub fn publication(self: *const Session, owner: *Owner) !*Bootstrap.Session {
        const bootstrap = try self.validateJoined(owner);
        try bootstrap.validateControlHooks(self.phase.load(.acquire) == .borrow_ended);
        if (self.phase.load(.acquire) != .registered) return error.InvalidState;
        try owner.renderer.validateDeviceQuiescence(self.startup_quiescence orelse return error.InvalidState);
        const adapter = self.adapter.?;
        try (adapter.validate_startup orelse return error.InvalidState)(adapter.identity.context, owner, self);
        return bootstrap;
    }
    pub fn hasNativeBorrow(self: *const Session) bool {
        const bootstrap = self.bootstrap orelse return false;
        const hooks = bootstrap.hooks orelse return false;
        // This selects a validator branch, never authenticates a pointer. Every
        // exempted path then checks the complete canonical owner-bound set.
        return hooks.native != null;
    }
    pub fn validateNativeFinal(self: *const Session) !void {
        const bootstrap = self.bootstrap orelse return error.InvalidState;
        const owner = self.owner orelse return error.InvalidState;
        if (bootstrap.native_events != &owner.group_events or !self.hasNativeBorrow()) return error.InvalidState;
        try Bootstrap.Native.validateFinal(self.control.?, bootstrap.native_events orelse return error.InvalidState, bootstrap.native_epoch);
    }
    pub fn validateBorrowSet(self: *const Session, owner: *Owner, service: *Service) !void {
        const bootstrap = try self.validateJoined(owner);
        try bootstrap.validateControlHooks(self.phase.load(.acquire) == .borrow_ended);
        const ended = self.phase.load(.acquire) == .borrow_ended;
        try bootstrap.validateServiceBorrow(service, ended);
        const adapter = self.adapter.?;
        try (adapter.validate_borrows orelse return error.InvalidState)(adapter.identity.context, self, ended);
    }
    /// Active independent Host ticks inspect immutable published identity only.
    /// Mutable Worker/candidate/slot inventory remains behind actual Park ACK.
    pub fn validatePublishedBorrowSet(self: *const Session, owner: *Owner, service: *Service) !void {
        const bootstrap = try self.validateJoined(owner);
        if (self.phase.load(.acquire) != .registered or self.adapter.?.tick_kind != .independent_host or
            bootstrap.hooks == null or bootstrap.hooks.?.native == null) return error.InvalidState;
        try bootstrap.validateControlHooks(false);
        try bootstrap.validatePublishedServiceIdentity(service);
    }
    /// Complete validation has already happened under exact ACK and both owner
    /// guards. No fallible callback or pointer clear can split this commit.
    pub fn endBorrowSet(self: *Session) void {
        std.debug.assert(self.phase.load(.acquire) == .sealed and self.bootstrap != null);
        self.bootstrap.?.endPublished();
        self.bootstrap.?.clearControlHooks();
        const adapter = self.adapter.?;
        adapter.clear_borrows.?(adapter.identity.context, self);
        self.phase.store(.borrow_ended, .release);
    }
    pub fn validateEmptyRequest(self: *const Session, owner: *Owner, park: ?Park, token: rt.RuntimeRenderer.DeviceQuiescence) !void {
        const bootstrap = try self.validateJoined(owner);
        try bootstrap.validateControlHooks(self.phase.load(.acquire) == .borrow_ended);
        if (self.phase.load(.acquire) != .registered or self.capability != null) return error.InvalidState;
        try bootstrap.validateEmpty(@constCast(self));
        try owner.renderer.validateDeviceQuiescence(token);
        if (!std.meta.eql(token, self.startup_quiescence orelse return error.InvalidState)) return error.InvalidState;
        const adapter = self.adapter.?;
        try (adapter.validate_empty orelse return error.InvalidState)(adapter.identity.context, owner, self, park);
    }
    pub fn destroyedEmpty(self: *Session, park: ?Park, report: resident.ShutdownReport) void {
        std.debug.assert(self.phase.load(.acquire) == .registered and self.bootstrap != null and self.capability == null);
        self.empty_receipt = .{ .park = park, .report = report };
        self.actual_report = report;
        self.phase.store(.destroyed_empty, .release);
        // Owner is already freed. This receipt and immutable adapter are the
        // only authority for later stop/join retries; never follow backlinks.
    }
    pub fn destroyed(self: *Session, report: resident.ShutdownReport) void {
        std.debug.assert(self.phase.load(.acquire) == .sealed or self.phase.load(.acquire) == .borrow_ended);
        self.actual_report = report;
        self.phase.store(.destroyed, .release);
        // Keep the immutable copied capability and pinned adapter alive through
        // actual joins. Neither its pointers nor the freed owner are read again.
    }
};
