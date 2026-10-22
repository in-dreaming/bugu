//! Copies of actual live readiness/supply reads. Never a replay/output input.
const std = @import("std");
const trace = @import("sme-trace");
const acceptance = @import("acceptance_observation.zig");
pub const Handle = acceptance.Handle;
pub const ReadinessMeasurement = struct { frames_per_second: ?u64, version: u32 };
pub const QueryKey = struct {
    interval_id: u64 = 0,
    tick_serial: u64 = 0,
    attempt_ordinal: u64 = 0,
    handle: Handle = .{ .index = 0, .generation = 0 },
    phase: u8 = 0,
    context: u64 = 0,
    control_epoch: u64 = 0,
    transport_epoch: u64 = 0,
    position: trace.schema.Position = .{ .accepted_control_frame = 0, .control_tick = 0, .input_order = 0 },
};
pub const Read = enum(u6) {
    order,
    outer_before,
    stopped_first,
    mode,
    stopped_second,
    sequence_before,
    observation_frame,
    consumed,
    produced,
    pending,
    measurement,
    failure,
    cancel,
    sequence_after,
    outer_after,
    request_cancel,
    request_stopped,
    request_failed,
    request_pending,
    request_ordinal,
    availability_sequence,
    availability_frame,
    availability_consumed,
    availability_produced,
    availability_after,
};
pub fn bit(value: Read) u64 {
    return @as(u64, 1) << @intFromEnum(value);
}
pub const QueryRead = struct {
    reached: u64 = 0,
    order: u64 = 0,
    outer_before: u64 = 0,
    outer_after: u64 = 0,
    stopped_first: bool = false,
    stopped_second: bool = false,
    replay_mode: bool = false,
    attached: bool = false,
    sequence_before: u64 = 0,
    frame: u64 = 0,
    consumed: u64 = 0,
    produced: u64 = 0,
    sequence_after: u64 = 0,
    configured: u16 = 0,
    scanned: u16 = 0,
    /// Four acquired states per byte, in exact scan order. Metadata for free
    /// slots is never loaded. Request records bind slot -> descriptor lifetime.
    states: [64]u8 = @splat(0),
    pending_job: ?u16 = null,
    pending_count: u32 = 0,
    local_measurement: ReadinessMeasurement = .{ .frames_per_second = null, .version = 0 },
    selected_measurement: ReadinessMeasurement = .{ .frames_per_second = null, .version = 0 },
    failure_code: u16 = 0,
    cancel: bool = false,
    representation_complete: bool = true,
    service_error: u32 = 0,
    error_code: u32 = 0,
    pub fn saw(self: *QueryRead, which: Read) void {
        self.reached |= bit(which);
    }
    pub fn has(self: QueryRead, which: Read) bool {
        return self.reached & bit(which) != 0;
    }
    pub fn state(self: QueryRead, index: usize) acceptance.JobState {
        std.debug.assert(index < self.scanned and index < 256);
        return @enumFromInt((self.states[index / 4] >> @as(u3, @intCast((index % 4) * 2))) & 3);
    }
    pub fn putState(self: *QueryRead, index: usize, value: acceptance.JobState) void {
        if (index >= 256) {
            self.representation_complete = false;
            return;
        }
        self.states[index / 4] |= @as(u8, @intFromEnum(value)) << @as(u3, @intCast((index % 4) * 2));
        self.scanned = @intCast(index + 1);
    }
};
pub const SupplyKind = enum { prefetch, request };
pub const SupplyRead = struct {
    kind: SupplyKind,
    parent_attempt: u64 = 0,
    reached: u64 = 0,
    availability: acceptance.Availability = .{},
    cancel: bool = false,
    stopped: bool = false,
    failure_code: u16 = 0,
    pending_job: ?u16 = null,
    ordinal: u64 = 0,
    /// Populated only on the actual new request. The finite oracle retires
    /// the prior accepted lifetime before binding a reused slot to this job.
    job_slot: ?u16 = null,
    descriptor: ?trace.schema.readiness.JobDescriptor = null,
    count: u32 = 0,
    result_job: ?u64 = null,
    invokes_request: bool = false,
    error_code: u32 = 0,
};
/// Runtime-owned, installed only for the duration of an admitted Control tick.
/// A prefetch closes its own record before invoking the nested request, so the
/// producer has only one in-progress scratch event.
pub const SupplySink = struct {
    context: *anyopaque,
    begin: *const fn (*anyopaque, SupplyKind, Handle, ?u64, u64) ?*SupplyRead,
    finish: *const fn (*anyopaque) u64,
    throughput: *const fn (*anyopaque, ThroughputFold) void,
};
pub const ThroughputFold = struct { job: u64, count: u32, elapsed_ns: u64, before: ReadinessMeasurement, after: ReadinessMeasurement, attempted: bool };
/// Optional fields are actual reached reads, not later diagnostic snapshots.
/// In particular, a successful CAS copies its expected prior value, while a
/// failed CAS copies the value returned by that very operation.
pub const StreamValidation = struct {
    index_in_bounds: ?bool = null,
    occupied: ?bool = null,
    generation: ?u64 = null,
};
pub const StreamOpenRead = struct {
    parent_attempt: u64 = 0,
    asset_generation: u64,
    transport_epoch: u64,
    group: u64,
    layer: u64,
    start_cursor: u64,
    loop_epoch: u64,
    free_before: ?u32 = null,
    selected_index: ?u16 = null,
    result: ?Handle = null,
    free_after: ?u32 = null,
    next_generation_after: ?u64 = null,
    guard_published: ?u8 = null,
    error_code: u32 = 0,
};
pub const StreamCancelRead = struct {
    parent_attempt: u64 = 0,
    handle: Handle,
    validation: StreamValidation = .{},
    cancel_published: bool = false,
    replay_readiness_cleared: bool = false,
    error_code: u32 = 0,
};
pub const StreamCloseRead = struct {
    parent_attempt: u64 = 0,
    handle: Handle,
    worker_busy: ?bool = null,
    validation: StreamValidation = .{},
    /// The separate reached bit distinguishes an absent read from a read of
    /// the actual empty pending-job optional.
    pending_job_reached: bool = false,
    pending_job: ?u16 = null,
    visibility_refs: ?u32 = null,
    ring_references: ?u32 = null,
    guard: ?u8 = null,
    worker_idle_published: bool = false,
    stopped_published: bool = false,
    returned: bool = false,
    free_before: ?u32 = null,
    free_after: ?u32 = null,
    error_code: u32 = 0,
};
pub const WindowRead = struct {
    parent_attempt: u64 = 0,
    handle: Handle,
    runtime_generation: u64,
    request_id: u64,
    window_index: u32,
    group: ?Handle = null,
    retiring: bool,
    ring_lookup_reached: bool = false,
    stopped: ?bool = null,
    marked_retiring: bool = false,
    invokes_cancel: bool = false,
    error_code: u32 = 0,
};
pub const WindowReturn = struct {
    parent_attempt: u64,
    handle: Handle,
    runtime_generation: u64,
    request_id: u64,
    window_index: u32,
};
/// The caller copies the exact identity before returning the source lease.
/// Effects are distinguished from atomic read evidence; no count is inferred.
pub const StreamLeaseRead = struct {
    parent_attempt: u64 = 0,
    handle: Handle,
    group: ?Handle = null,
    layer: u16 = 0,
    action: enum { retain, release, stop_release, rollback_release },
    completed: bool = false,
    error_code: u32 = 0,
};
pub const LifecycleRead = union(enum) {
    open: StreamOpenRead,
    cancel: StreamCancelRead,
    close: StreamCloseRead,
    window: WindowRead,
    window_return: WindowReturn,
    stream_lease: StreamLeaseRead,
};
/// Runtime-owned and scoped to an admitted tick. The entire record is copied
/// synchronously; emit leaves no scratch operation open and returns its attempt
/// ordinal (zero when inactive/lost) for explicit nested-operation linkage.
pub const LifecycleSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, LifecycleRead) u64,
};
/// Tests only: the only accepted external numerical data is a rate/version.
/// No expected Facts, Projection, schedule, atomics, or PCM enter this type.
pub const MeasurementSource = struct {
    context: *anyopaque,
    select: *const fn (*anyopaque, QueryKey) error{IncompleteTrace}!ReadinessMeasurement,
    finish: *const fn (*anyopaque) error{IncompleteTrace}!void,
};
pub const ReadStage = enum { before_outer_before, before_stopped_first, after_stopped_first, after_sequence, after_frame, after_consumed, after_produced, before_job_state, after_job_state, before_final_sequence, after_final_sequence, after_outer_before, after_outer_after };
pub const ReadHook = struct { context: *anyopaque, call: *const fn (*anyopaque, ReadStage, u64) void };
pub const FrontierStage = enum { after_odd, after_consumed_prefix, after_frame, after_even, after_runtime_frame };
pub const FrontierHook = struct { context: *anyopaque, call: *const fn (*anyopaque, FrontierStage, u64) void };
comptime {
    if (@sizeOf(QueryRead) > 384 or @sizeOf(SupplyRead) > 384) @compileError("Readiness primitive record exceeds bounded payload");
    if (@sizeOf(LifecycleRead) > 320) @compileError("Readiness lifecycle record exceeds bounded payload");
}
