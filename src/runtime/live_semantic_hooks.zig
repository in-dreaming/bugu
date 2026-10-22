//! Collector-free finite semantic cuts for the explicit Live-boundary profile.
//! These are native call coordinates, not expected decisions or a wire format.
//! Every callback receives an owned copy and has no result channel. Capture
//! callbacks must only copy into bounded, single-producer role-local storage:
//! no allocation, IO, blocking, reentry, engine mutation or capacity retries.
//! An offline owner may coordinate its separate replay threads at these cuts.
//! Bindings/context/storage stay pinned and immutable from excluded startup
//! through real producer joins and excluded detach. Health is never custody.
const std = @import("std");
const native = @import("sme-capture-order");
pub const Role = native.Role;
pub const Edge = native.Edge;
pub const Site = native.Site;
pub const Point = struct {
    role: Role,
    site: Site,
    edge: Edge,
    index: u64 = 0,
    generation: u64 = 0,
    value: ?u64 = null,
};
/// Separate occurrence identities for enclosing operations and publications.
/// acceptance_attempt: index=tick, generation=input_order, value=entry frame.
/// acceptance_scan: index=job capacity. selected: index=slot, generation=job.
/// worker_attempt: no identity until the actual selector computes a job.
/// consumed_prefix: index=completed frame, generation=odd sequence episode.
/// cancel/stopped release: index=slot, generation=stream incarnation, value=1.
pub const Boundary = enum(u8) {
    service_acceptance_attempt,
    service_acceptance_scan,
    service_acceptance_selected,
    service_worker_attempt,
    service_worker_selected,
    service_render_consumed_prefix,
    service_cancel_release,
    service_stopped_release,
    /// Whole original Worker scan; index=job capacity, generation=0.
    service_worker_scan,
    /// Scheduler whole scans. prepare/reconcile: index=block capacity.
    /// acquire: index=gate, generation=frame, value=block capacity.
    scheduler_prepare_scan,
    scheduler_reconcile_scan,
    scheduler_acquire_scan,
    /// Actual plan cancellation store; role is its genuine Control/Render
    /// owner. index=plan slot, generation=incarnation, value=1.
    /// Never a cancellation override.
    scheduler_plan_cancel_release,
};
pub const BoundaryPoint = struct {
    role: Role,
    site: Boundary,
    edge: Edge,
    index: u64 = 0,
    generation: u64 = 0,
    value: ?u64 = null,
};
pub const Binding = struct {
    context: *anyopaque,
    point: *const fn (*anyopaque, Point) void,
    boundary: *const fn (*anyopaque, BoundaryPoint) void,
    pub fn same(a: Binding, b: Binding) bool {
        return a.context == b.context and a.point == b.point and a.boundary == b.boundary;
    }
};
/// Frozen finite vocabulary. In particular Render per-sample Ring operations,
/// diagnostic claim-ticket progress and generic resource bookkeeping are not
/// semantic cuts. Worker/acceptance scans and Render consumed-prefix loops
/// retain their actual per-slot cuts inside bounded whole-operation envelopes.
/// A recorder may packetize those cuts, preserving each original occurrence
/// and coordinate; observed values remain separate comparison-only outputs.
/// Scheduler scalar scans remain omitted, so the first profile must reject
/// their overlapping publication intervals before replay. Consumers must reject
/// all other sites, not silently drop an unknown tape record. Role-local
/// occurrence order distinguishes equal values; no scan observation or selected
/// job is supplied as an engine input.
/// Readiness backlog needs no scalar state labels: sole Control owns free /
/// nonfree transitions and descriptors; Worker transitions stay nonfree.
pub fn allowedSite(site: Site) bool {
    return switch (site) {
        .ring_consumed,
        .service_initial_entry_consumed,
        .service_initial_entry_cancel,
        .ring_produced,
        .produced_release,
        .runtime_collection_frame,
        .runtime_plan_phase,
        .runtime_execution_receipt,
        .runtime_schedule_admission,
        .runtime_schedule_result,
        .runtime_schedule_release,
        .runtime_control_horizon,
        .runtime_control_accept_frame,
        .runtime_render_frame,
        .runtime_control_collect_frame,
        .runtime_render_commit_horizon,
        .runtime_stream_stop_publish,
        .runtime_readiness_outer_before,
        .runtime_readiness_outer_after,
        .runtime_load_state_read,
        .runtime_load_state_publish,
        .runtime_load_state_claim,
        .runtime_worker_service_read,
        .runtime_worker_service_publish,
        .service_availability_readiness_sequence_before,
        .service_availability_readiness_frame,
        .service_availability_readiness_control_consumed,
        .service_availability_readiness_produced,
        .service_availability_readiness_sequence_after,
        .service_availability_acceptance_sequence_before,
        .service_availability_acceptance_frame,
        .service_availability_acceptance_control_consumed,
        .service_availability_acceptance_produced,
        .service_availability_acceptance_sequence_after,
        .service_stream_observation_frame,
        .service_worker_claim,
        .service_worker_scan,
        .service_worker_running,
        .service_worker_completed,
        .service_worker_idle,
        .service_job_queued,
        .service_job_free,
        .service_acceptance_scan,
        .service_worker_cancel,
        .service_worker_stopped,
        .service_publication_release,
        .service_publication_frontier,
        .service_visibility_head,
        .service_visibility_produced,
        .service_visibility_stopped,
        .service_visibility_release,
        .service_visibility_poll,
        .service_visibility_ack,
        .service_readiness_stopped_first,
        .service_readiness_stopped_second,
        .service_readiness_sequence,
        .service_readiness_frame,
        .service_readiness_consumed,
        .service_readiness_produced,
        .service_readiness_final_sequence,
        .service_render_sequence_odd,
        .service_render_consumed,
        .service_render_frame,
        .service_render_sequence_even,
        .service_stream_close_claim,
        .service_stream_close_pending,
        .service_stream_close_idle,
        .service_service_prepare_claim,
        .service_service_prepare_idle,
        .service_stream_close_visibility,
        .service_stream_close_stopped,
        .service_slot_guard_open,
        .service_slot_guard_close,
        .service_slot_guard_render_claim,
        .service_slot_guard_render_release,
        .group_event_space,
        .group_event_publish,
        .group_event_pop,
        .group_event_return,
        .scheduler_validate,
        .scheduler_ack_terminal,
        .scheduler_publication,
        .scheduler_acquired,
        .scheduler_phase,
        .scheduler_terminal,
        .scheduler_receipt,
        .scheduler_horizon,
        .scheduler_prepare_horizon,
        .scheduler_invalidation_before_scan,
        .scheduler_invalidation_after_scan,
        .scheduler_invalidation_pre_claim,
        .scheduler_invalidation_poll,
        .scheduler_invalidation_publication,
        => true,
        else => false,
    };
}
pub fn allowedPoint(point: Point) bool {
    if (!allowedSite(point.site)) return false;
    // Ring hooks are attached only to finite Control publication/read calls.
    return switch (point.site) {
        .ring_consumed,
        .service_initial_entry_consumed,
        .service_initial_entry_cancel,
        .ring_produced,
        .produced_release,
        .runtime_worker_service_publish,
        => point.role == .control,
        .runtime_load_state_claim, .runtime_worker_service_read => point.role == .worker,
        .runtime_load_state_read, .runtime_load_state_publish => point.role != .render,
        else => true,
    };
}
pub const ClockStage = enum(u8) { begin, end };
pub const ClockSample = struct { value: u64, available: bool, error_code: u32 = 0 };
/// Only the sole replay Worker calls next and owns its forward input cursor.
/// Other replay roles may poison this pinned object through abort(), never by
/// mutating next/context/cursor. An in-flight callback's sample is discarded if
/// abort wins before its final acquire. Null poisons before native fallback;
/// no expected clocks are used by failed replay or its genuine native cleanup.
/// This object is not live-capture state and cannot be attached in capture mode.
pub const OfflineClock = struct {
    pub const Next = *const fn (*anyopaque, ClockStage, u64) ?ClockSample;
    address: ?*OfflineClock = null,
    context: *anyopaque = undefined,
    next: Next = undefined,
    failed: std.atomic.Value(bool) = .init(false),
    pub fn init(self: *OfflineClock, context: *anyopaque, next: Next) !void {
        if (self.address != null) return error.InvalidState;
        self.* = .{ .address = self, .context = context, .next = next };
    }
    pub fn validateInitial(self: *const OfflineClock) !void {
        if (self.address != self or self.failed.load(.acquire)) return error.InvalidState;
    }
    pub fn abort(self: *OfflineClock) void {
        std.debug.assert(self.address == self);
        self.failed.store(true, .release);
    }
    pub fn sample(self: *OfflineClock, stage: ClockStage, job: u64) ?ClockSample {
        std.debug.assert(self.address == self);
        if (self.failed.load(.acquire)) return null;
        const result = self.next(self.context, stage, job) orelse {
            self.abort();
            return null;
        };
        if (self.failed.load(.acquire)) return null;
        return result;
    }
};
