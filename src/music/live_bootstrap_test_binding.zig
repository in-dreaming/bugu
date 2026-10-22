//! Test-only first slice of the Live owner/session borrow contract. The real
//! initial-load path creates, prepares, retires and destroys the candidate.
//! The joined test seam also transfers this exact Service borrow to its owner.
//! No production attachment or Live replay admission is enabled here.
//! Callback equality authenticates this retained fixture provider only; it is
//! not immutable external source/plan provenance or complete capture coverage.
const std = @import("std");
const rt = @import("bugu_audio").runtime;
const assets = @import("runtime_assets.zig");
const v1 = @import("runtime_contract.zig");
const save = @import("save_state.zig");
const order = rt.capture_order;
const Service = rt.streaming.Service;
pub const Native = @import("live_native_test_binding.zig");

/// Exact existing callbacks, registered before the actual Service allocation.
/// This internal variant still grants no Live tick or replay admission.
pub const Hooks = struct {
    checkpoint: rt.streaming.stream.TestCheckpointHook,
    acceptance: rt.streaming.stream.AcceptanceHook,
    worker_clock: rt.streaming.stream.TestWorkerClockHook,
    control_readiness: rt.CausalReplayHooks,
    native: ?Native.Hooks = null,
    pub fn validateInitial(self: Hooks) !void {
        if (self.worker_clock.replay != null) return error.InvalidState;
        try (self.worker_clock.joined orelse return error.InvalidState).validateInitial();
    }
};

pub const Session = struct {
    pub const Stage = enum { empty, owner_bound, load_queued, candidate_borrowed, borrow_ended, published, published_ended };
    address: ?*Session = null,
    owner: ?*anyopaque = null,
    // The owner issues this address. A caller-supplied session number cannot
    // replace the live backlink, and copying Session invalidates address.
    owner_slot: ?*?*Session = null,
    control: ?*rt.ControlRuntime = null,
    renderer: ?*rt.RuntimeRenderer = null,
    context: u64 = 0,
    source_hash: [32]u8 = @splat(0),
    source_bytes: usize = 0,
    provider: ?assets.SourceProvider = null,
    roles: ?order.Roles = null,
    stage: Stage = .empty,
    ticket: ?v1.LoadTicketV1 = null,
    candidate: ?*assets.Generation = null,
    service: ?*Service = null,
    // Immutable link to the single finalization authority. Only the registered
    // outer Worker wrapper may issue one engine-entry permit in joined mode.
    combined: ?*anyopaque = null,
    hooks: ?Hooks = null,
    native_events: ?*rt.MusicGroupTrace = null,
    native_epoch: u64 = 0,
    native_ended: bool = false,
    hook_clock_context: ?*anyopaque = null,
    hook_clock_next: ?rt.streaming.stream.TestJoinedClock.Next = null,
    entry_permit: bool = false,
    entry_arm_pending: bool = false,
    published_generation: ?u64 = null,
    worker_operation: u64 = 0,
    worker_begin_receipt: ?order.EndpointReceipt = null,
    worker_end_receipt: ?order.EndpointReceipt = null,
    worker_active: bool = false,
    worker_begin_attempts: u64 = 0,
    worker_end_attempts: u64 = 0,
    worker_error_ends: u64 = 0,
    attribution_overflow: bool = false,
    installs: usize = 0,
    borrow_ends: usize = 0,
    end_operation: ?u64 = null,

    /// Called only by the test-only owner constructor seam after actual startup
    /// validation. Producers and the consumer have not been started yet.
    pub fn issue(self: *Session, owner: *anyopaque, owner_slot: *?*Session, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, context: u64, roles: order.Roles, bytes: []const u8, provider: assets.SourceProvider) !void {
        try self.validateIssue(owner_slot, roles);
        self.commitIssue(owner, owner_slot, control, renderer, context, roles, bytes, provider);
    }
    pub fn validateIssue(self: *const Session, owner_slot: *?*Session, roles: order.Roles) !void {
        if (self.address != null or self.stage != .empty or owner_slot.* != null or !roles.pristine()) return error.InvalidState;
    }
    pub fn commitIssue(self: *Session, owner: *anyopaque, owner_slot: *?*Session, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, context: u64, roles: order.Roles, bytes: []const u8, provider: assets.SourceProvider) void {
        self.* = .{ .address = self, .owner = owner, .owner_slot = owner_slot, .control = control, .renderer = renderer, .context = context, .source_hash = save.hash(bytes), .source_bytes = bytes.len, .provider = provider, .roles = roles, .stage = .owner_bound };
        owner_slot.* = self;
    }
    /// Infallible part of combined startup, after every identity check. The
    /// decision table is immutable; failure/provenance remains Worker-owned.
    pub fn commitHooks(self: *Session, hooks: ?Hooks, events: *rt.MusicGroupTrace) void {
        self.hooks = hooks;
        if (hooks) |value| {
            const clock = value.worker_clock.joined.?;
            clock.claimSession(self.combined.?);
            self.hook_clock_context = clock.context;
            self.hook_clock_next = clock.next;
            self.control.?.test_live_readiness_checkpoint_hook = value.control_readiness;
            if (value.native) |native| {
                self.native_events = events;
                self.native_epoch = events.reset_epoch.load(.acquire);
                Native.installControl(native, self.control.?, self.renderer.?, events, self.roles.?, self.native_epoch);
            }
        }
    }
    fn validateNativeIdentity(self: *const Session) !void {
        const native = if (self.hooks) |hooks| hooks.native else null;
        if (native != null) {
            const owner = self.control.?.music_runtime orelse return error.InvalidState;
            if (self.native_events != &owner.group_events or self.native_epoch == 0) return error.InvalidState;
        } else if (self.native_events != null or self.native_epoch != 0 or self.native_ended) return error.InvalidState;
    }
    pub fn validateControlHooks(self: *const Session, ended: bool) !void {
        try self.validateNativeIdentity();
        const control = self.control.?;
        if (control.test_readiness_observation != null or control.test_control_frontier_hook != null or control.test_before_collection_hook != null) return error.InvalidState;
        const expected: ?rt.CausalReplayHooks = if (!ended) if (self.hooks) |hooks| hooks.control_readiness else null else null;
        if (!std.meta.eql(control.test_live_readiness_checkpoint_hook, expected)) return error.InvalidState;
        if (self.hooks) |hooks| if (hooks.native) |native| {
            if (self.native_ended != ended) return error.InvalidState;
            try Native.validateControl(native, control, self.renderer.?, self.native_events.?, self.roles.?, self.native_epoch, ended);
        };
    }
    /// Only after the fixed Host authenticates its retained destroyed-empty
    /// receipt. The native set was already validated and cleared before free.
    /// Inspect surviving Host storage only: native_events/owner_slot are stale
    /// pointer values here and must never be followed, including on retries.
    pub fn validateControlHooksAfterEmpty(self: *const Session) !void {
        if (self.address != self or self.control == null or self.renderer == null) return error.InvalidState;
        const hooks = self.hooks;
        const native = if (hooks) |value| value.native else null;
        if (native) |value| {
            if (!self.native_ended or self.native_events == null or self.native_epoch == 0) return error.InvalidState;
            const control = self.control.?;
            if (control.test_readiness_observation != null or control.test_control_frontier_hook != null or
                control.test_before_collection_hook != null or control.test_live_readiness_checkpoint_hook != null) return error.InvalidState;
            try self.validateRoles();
            try Native.validateControlStorage(value, control, self.renderer.?, self.roles.?, true);
        } else {
            // The older non-native set stays attached until the genuine stop
            // or proven never-started exclusion. This branch has no owner read.
            try self.validateControlHooks(false);
        }
    }
    /// Control storage belongs to the Host fixture and survives owner free.
    /// The complete set was validated under sealed or empty parked custody.
    pub fn clearControlHooks(self: *Session) void {
        if (self.hooks != null) self.control.?.test_live_readiness_checkpoint_hook = null;
        if (self.native_events) |events| if (!self.native_ended) {
            Native.clearControl(self.control.?, self.renderer.?, events);
            self.native_ended = true;
        };
    }
    fn validateServiceHooks(self: *const Session, service: *Service, ended: bool) !void {
        const hooks = if (!ended) self.hooks else null;
        if (!std.meta.eql(service.test_checkpoint_hook, if (hooks) |value| @as(?rt.streaming.stream.TestCheckpointHook, value.checkpoint) else null) or
            !std.meta.eql(service.test_acceptance_hook, if (hooks) |value| @as(?rt.streaming.stream.AcceptanceHook, value.acceptance) else null) or
            !std.meta.eql(service.test_worker_clock_hook, if (hooks) |value| @as(?rt.streaming.stream.TestWorkerClockHook, value.worker_clock) else null)) return error.InvalidState;
        try Native.validateService(if (hooks) |value| value.native else null, service);
        if (!ended) try self.validateHookIdentity();
    }
    fn validateHookIdentity(self: *const Session) !void {
        if (self.hooks) |value| {
            const clock = value.worker_clock.joined orelse return error.InvalidState;
            // No mutable failure, provenance or collector-health reads.
            if (clock.address != clock or clock.session != self.combined or clock.context != self.hook_clock_context or clock.next != self.hook_clock_next) return error.InvalidState;
        }
    }
    pub fn validateOwner(self: *const Session, owner: *anyopaque, owner_slot: *?*Session, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer) !void {
        if (self.address != self or self.owner != owner or self.owner_slot != owner_slot or owner_slot.* != self or self.control != control or self.renderer != renderer) return error.InvalidState;
        try self.validateRoles();
        try self.validateNativeIdentity();
    }
    fn validateBacklink(self: *const Session) !void {
        const slot = self.owner_slot orelse return error.InvalidState;
        if (self.address != self or self.owner == null or slot.* != self or self.control == null or self.renderer == null) return error.InvalidState;
        const actual_owner = self.control.?.music_runtime orelse return error.InvalidState;
        if (@as(*anyopaque, @ptrCast(actual_owner)) != self.owner.? or self.renderer.?.runtime != self.control.?) return error.InvalidState;
        try self.validateNativeIdentity();
    }
    fn validateRoles(self: *const Session) !void {
        const roles = self.roles orelse return error.InvalidState;
        if (roles.control == roles.render or roles.control == roles.worker or roles.render == roles.worker) return error.InvalidState;
        // These are immutable identity fields. Never inspect a peer lane's
        // mutable head/tail, active_operation, counters or recording health.
        inline for (.{ order.Role.control, order.Role.render, order.Role.worker }) |role| {
            const lane = roles.get(role);
            if (lane.address != lane or lane.role != role) return error.InvalidState;
        }
    }
    fn sameProvider(a: assets.SourceProvider, b: assets.SourceProvider) bool {
        return a.context == b.context and a.open == b.open and a.read_at == b.read_at and a.close == b.close;
    }
    pub fn validateSource(self: *const Session, bytes: []const u8, provider: ?assets.AnySourceProvider) !void {
        if (self.stage != .owner_bound or self.ticket != null or bytes.len != self.source_bytes or !std.mem.eql(u8, &self.source_hash, &save.hash(bytes))) return error.InvalidState;
        const actual = provider orelse return error.InvalidState;
        if (actual != .v1 or !sameProvider(self.provider.?, actual.v1)) return error.InvalidState;
    }
    pub fn validateTicket(self: *const Session, ticket: v1.LoadTicketV1) !void {
        if (self.ticket == null or !std.meta.eql(self.ticket.?, ticket)) return error.InvalidState;
    }
    /// Revalidate the real constructor's exact immutable input before it can
    /// allocate/prepare a candidate. This is not callable authority to substitute
    /// another bank just because it uses the same provider callback table.
    pub fn validatePreparation(self: *const Session, bytes: []const u8, provider: ?assets.SourceProvider) !void {
        try self.validateBacklink();
        try self.validateRoles();
        try self.validateHookIdentity();
        if (!self.worker_active or self.stage != .load_queued or self.ticket == null or self.ticket.?.context != self.context or
            bytes.len != self.source_bytes or !std.mem.eql(u8, &self.source_hash, &save.hash(bytes))) return error.InvalidState;
        if (!sameProvider(self.provider.?, provider orelse return error.InvalidState)) return error.InvalidState;
    }
    /// Infallible commit immediately before the original load's release-queue.
    /// Source validation happened before the original allocation/mutation.
    pub fn queued(self: *Session, ticket: v1.LoadTicketV1) void {
        std.debug.assert(self.stage == .owner_bound and ticket.context == self.context and ticket.sequence == 1);
        self.ticket = ticket;
        self.stage = .load_queued;
    }
    /// Actual fixed Worker entry only. Identity failures are separate from
    /// append loss: a poisoned collector cannot prevent work or later cleanup.
    pub fn beginWorker(self: *Session) !void {
        if (self.worker_active) return error.InvalidState;
        self.worker_begin_receipt = null;
        self.worker_end_receipt = null;
        self.worker_active = true;
        self.worker_begin_attempts +|= 1;
        const lane = self.roles.?.worker;
        self.worker_operation = std.math.add(u64, self.worker_operation, 1) catch {
            self.attribution_overflow = true;
            lane.invalidateSource();
            return;
        };
        self.worker_begin_receipt = lane.beginReceipt(self.worker_operation);
    }
    pub fn endWorker(self: *Session, failed: bool) void {
        std.debug.assert(self.worker_active);
        self.worker_end_receipt = self.roles.?.worker.endReceipt(@intFromBool(failed));
        self.worker_end_attempts +|= 1;
        if (failed) self.worker_error_ends +|= 1;
        self.worker_active = false;
    }
    pub fn beginCombined(self: *Session, authority: *anyopaque) !void {
        try self.beginCombinedClosed(authority);
        try self.armCombined(authority);
    }
    /// The independent Host emits its passive begin callback with engine entry
    /// still closed. The old serialized wrapper keeps beginCombined semantics.
    pub fn beginCombinedClosed(self: *Session, authority: *anyopaque) !void {
        try self.validateBacklink();
        try self.validateRoles();
        if (self.combined != authority or self.entry_permit or self.entry_arm_pending) return error.InvalidState;
        try self.beginWorker();
        self.entry_arm_pending = true;
    }
    /// Called by the fixed wrapper immediately before its actual owner call.
    /// The pending bit distinguishes a never-armed entry from a consumed one.
    pub fn armCombined(self: *Session, authority: *anyopaque) !void {
        try self.validateBacklink();
        if (self.combined != authority or !self.worker_active or self.entry_permit or !self.entry_arm_pending) return error.InvalidState;
        self.entry_arm_pending = false;
        self.entry_permit = true;
    }
    /// Consumed before owner effects, including failure publication and first
    /// Worker-thread registration. An observer cannot reenter the live wrapper.
    pub fn enterCombined(self: *Session, authority: *anyopaque) !void {
        try self.validateBacklink();
        if (self.combined != authority or !self.worker_active or self.entry_arm_pending or !self.entry_permit) return error.InvalidState;
        self.entry_permit = false;
    }
    pub fn endCombined(self: *Session, authority: *anyopaque, failed: bool) void {
        std.debug.assert(self.combined == authority and self.worker_active);
        self.entry_permit = false;
        self.entry_arm_pending = false;
        self.endWorker(failed);
    }
    /// Published identity only, for a later checked independent Host route.
    /// Startup transfer must have acquired the genuine Worker ACK and release-
    /// published these immutable fields before matching resume. This does not
    /// inspect Worker-owned active/permit/clock state or any live slot inventory,
    /// and grants no quiescence, detach or new Live admission by itself.
    pub fn validatePublishedServiceIdentity(self: *const Session, service: *Service) !void {
        try self.validateBacklink();
        try self.validateRoles();
        if (self.combined == null or self.service != service or self.candidate != null or
            self.published_generation == null or self.stage != .published) return error.InvalidState;
        try self.validateInstalled(service);
    }
    pub fn validateServiceBorrow(self: *const Session, service: *Service, ended: bool) !void {
        try self.validateBacklink();
        try self.validateRoles();
        if (self.combined == null or self.service != service or self.candidate != null or self.published_generation == null or
            self.worker_active or self.entry_permit or self.entry_arm_pending or self.stage != (if (ended) Stage.published_ended else Stage.published)) return error.InvalidState;
        if (ended) {
            if (service.prerequisite_order != null or service.prerequisite_order_mode != .prerequisite or
                service.live_slot_guard_points or service.live_availability_points) return error.InvalidState;
            try self.validateServiceHooks(service, true);
        } else try self.validatePublishedServiceIdentity(service);
    }
    fn validateInstalled(self: *const Session, service: *Service) !void {
        const actual = service.prerequisite_order orelse return error.InvalidState;
        const expected = self.roles.?;
        if (actual.control != expected.control or actual.render != expected.render or actual.worker != expected.worker or
            service.prerequisite_order_mode != .semantic_span or !service.live_slot_guard_points or !service.live_availability_points) return error.InvalidState;
        try self.validateServiceHooks(service, false);
    }
    pub fn validateTransfer(self: *const Session, ticket: v1.LoadTicketV1, candidate: *assets.Generation) !void {
        try self.validateBacklink();
        try self.validateRoles();
        try self.validateTicket(ticket);
        if (self.combined == null or self.stage != .candidate_borrowed or self.worker_active or self.entry_permit or self.entry_arm_pending or
            self.candidate != candidate or candidate.test_live_bootstrap != self or candidate.service != self.service or
            candidate.sources.len == 0 or !candidate.owns_service or candidate.service_custody != null or
            candidate.registry != null or candidate.registry_handle != null or candidate.preparation_failure != null) return error.InvalidState;
        const service = self.service orelse return error.InvalidState;
        try self.unusedService(service, false);
        try self.validateInstalled(service);
    }
    /// Prevalidated startup transaction, immediately after real attachment and
    /// before any Worker/registry publication. Candidate lifetime is not retained.
    pub fn transfer(self: *Session, candidate: *assets.Generation) void {
        std.debug.assert(self.stage == .candidate_borrowed and self.candidate == candidate and candidate.test_live_bootstrap == self);
        self.published_generation = candidate.runtime_generation;
        candidate.test_live_bootstrap = null;
        self.candidate = null;
        self.stage = .published;
    }
    /// Private sealed-owner commit; the caller validated the complete expected
    /// set before sealing. Public post-join detach retains its original contract.
    pub fn endPublished(self: *Session) void {
        std.debug.assert(self.stage == .published and !self.worker_active);
        self.clearInstalled(self.service.?);
        self.stage = .published_ended;
        self.borrow_ends += 1;
        self.end_operation = self.worker_operation;
    }
    pub fn validateEmpty(self: *const Session, authority: *anyopaque) !void {
        try self.validateBacklink();
        try self.validateRoles();
        if (self.combined != authority or self.worker_active or self.entry_permit or self.entry_arm_pending or self.candidate != null or self.service != null or
            self.published_generation != null or (self.stage != .owner_bound and self.stage != .load_queued and self.stage != .borrow_ended)) return error.InvalidState;
    }
    fn clearInstalled(self: *Session, service: *Service) void {
        if (self.hooks != null) {
            service.test_checkpoint_hook = null;
            service.test_acceptance_hook = null;
            service.test_worker_clock_hook = null;
        }
        if (self.native_events != null) Native.clearService(service);
        service.prerequisite_order = null;
        service.prerequisite_order_mode = .prerequisite;
        service.live_slot_guard_points = false;
        service.live_availability_points = false;
    }
    fn unusedService(self: *const Session, service: *Service, before_install: bool) !void {
        try self.validateServiceHooks(service, before_install);
        if (service.runtime_attached or service.readiness_attached or service.replay_mode or
            service.public_causal_exclusion != null or
            service.public_causal_consumed_sink != null or service.offline_causal_replay != null or
            service.test_consumed_hook != null or service.test_readiness_hook != null or
            service.test_availability_hook != null or service.test_supply_hook != null or service.test_supply_return_hook != null or service.test_worker_clock_observer != null or
            service.test_frontier_hook != null or service.test_worker_hook != null or
            service.test_worker_stage_hook != null or service.test_publication_hook != null or
            service.next_generation != 1 or service.next_job != 1 or service.next_snapshot != 1 or
            service.worker_busy.load(.acquire) or service.free_stream_count != service.slots.len or service.free_job_count != service.jobs.len or
            service.publication_head.load(.acquire) != 0 or service.publication_read.load(.acquire) != 0 or service.publication_tail.load(.acquire) != 0 or
            service.observation_sequence.load(.acquire) != 0 or service.observation_frame.load(.acquire) != 0 or
            service.last_render_gate.load(.acquire) != 0 or service.last_render_frame.load(.acquire) != 0) return error.InvalidState;
        for (service.slots, service.slot_guards) |*slot, *guard| {
            if (slot.occupied or slot.generation != 0 or slot.pending_job != null or slot.visibility_refs != 0 or guard.load(.acquire) != 2) return error.InvalidState;
            // The untouched PCM Ring is undefined. Do not read it to prove
            // zero leases: next_generation=1 and all virgin slots prove no open.
        }
        for (service.jobs) |*job| if (job.state.load(.acquire) != .free) return error.InvalidState;
    }
    /// Checked internal adoption of an actual newly allocated Service. The
    /// enclosing Worker operation has already begun; pristine() is invalid now.
    /// Every fallible check precedes installing any borrow or candidate marker.
    pub fn install(self: *Session, candidate: *assets.Generation, compiled: []const u8, provider: assets.SourceProvider) !void {
        try self.validatePreparation(compiled, provider);
        if (!self.worker_active or self.stage != .load_queued or self.ticket == null or self.candidate != null or self.service != null or
            !sameProvider(self.provider.?, provider) or candidate.test_live_bootstrap != null or candidate.sources.len == 0 or
            !candidate.owns_service or candidate.service_custody != null or candidate.registry != null or candidate.registry_handle != null or
            candidate.source_binding != null or candidate.windowCount() != 0 or candidate.hasControlLeases()) return error.InvalidState;
        const service = candidate.service orelse return error.InvalidState;
        try self.unusedService(service, true);
        if (service.prerequisite_order != null or service.prerequisite_order_mode != .prerequisite or service.live_slot_guard_points or service.live_availability_points) return error.InvalidState;
        service.prerequisite_order = self.roles.?;
        service.prerequisite_order_mode = .semantic_span;
        service.live_slot_guard_points = true;
        service.live_availability_points = true;
        if (self.hooks) |hooks| {
            service.test_checkpoint_hook = hooks.checkpoint;
            service.test_acceptance_hook = hooks.acceptance;
            service.test_worker_clock_hook = hooks.worker_clock;
            if (hooks.native) |native| Native.installService(native, service);
        }
        candidate.test_live_bootstrap = self;
        self.candidate = candidate;
        self.service = service;
        self.stage = .candidate_borrowed;
        self.installs += 1;
        if (self.hooks) |hooks| if (hooks.native) |native| if (native.birth) |sink|
            sink.emit(sink.context, .{ .context = self.context, .load_ticket = self.ticket.?, .worker_operation = self.worker_operation, .installation = self.installs, .runtime_generation = candidate.runtime_generation, .bank_hash = candidate.loaded.content_hash, .profile = service.profile, .profile_hash = service.profile.hash(), .next_job = service.next_job, .next_generation = service.next_generation, .job_slots = service.jobs.len, .stream_slots = service.slots.len });
    }
    /// Same Worker, after actual provider retirement acknowledgement. The owner
    /// separately proves this candidate was never published. All validation is
    /// complete before clearing the exact Service-local borrowed set.
    pub fn endUnpublished(self: *Session, ticket: v1.LoadTicketV1, candidate: *assets.Generation) !void {
        try self.validateBacklink();
        try self.validateRoles();
        if (!self.worker_active or self.stage != .candidate_borrowed or self.ticket == null or !std.meta.eql(self.ticket.?, ticket) or
            self.candidate != candidate or candidate.test_live_bootstrap != self or candidate.service != self.service or
            !candidate.owns_service or candidate.service_custody != null or candidate.registry != null or candidate.registry_handle != null or
            !candidate.retirementAcknowledged() or candidate.source_binding != null or candidate.hasControlLeases() or candidate.windowCount() != 0) return error.InvalidState;
        for (candidate.sources) |*record| {
            if (record.opened != null) return error.InvalidState;
            if (record.asset) |*asset| if (asset.references.load(.acquire) != 0) return error.InvalidState;
        }
        const service = self.service orelse return error.InvalidState;
        try self.unusedService(service, false);
        try self.validateInstalled(service);
        self.clearInstalled(service);
        candidate.test_live_bootstrap = null;
        self.service = null;
        self.candidate = null;
        self.stage = .borrow_ended;
        self.borrow_ends += 1;
        self.end_operation = self.worker_operation;
        // Session and lane storage remain pinned. The enclosing Worker still
        // attempts its end after Generation.destroy and the real return.
    }
};
