//! Owned, bounded metadata from actual serialized Control read points. These
//! are sequential reads, not a coherent Worker/Render snapshot or replay input.
//! A null optional means that the corresponding real read/operation did not run.
const trace = @import("sme-trace");
const ring = @import("ring.zig");
const visibility = @import("visibility.zig");

/// StreamCapacityProfile.validate permits at most 256 jobs. If that contract
/// grows, producers keep working and mark observation completeness lost.
pub const job_capacity: usize = 256;
pub const Handle = struct { index: u16, generation: u64 };
pub const Accepted = struct { input: trace.Input, handle: Handle, stale: bool };
pub const JobState = enum(u8) { free, queued, running, completed };
pub const CompletedIdentity = struct {
    job: u64 = 0,
    handle: Handle = .{ .index = 0, .generation = 0 },
    generation: u64 = 0,
    transport_epoch: u64 = 0,
};
pub const Selected = struct {
    slot: u16,
    handle: Handle,
    descriptor: trace.schema.readiness.JobDescriptor,
    ordinal: u64,
    count: u32,
    outcome: trace.schema.Readiness,
    failure_code: u16,
    content_hash: [32]u8,
};
pub const Availability = struct {
    attached: bool = false,
    requested_frame: ?u64 = null,
    sequence_before: ?u64 = null,
    frame: ?u64 = null,
    consumed: ?u64 = null,
    produced: ?u64 = null,
    sequence_after: ?u64 = null,
    available: ?u64 = null,
    error_code: u32 = 0,
};
pub const PublicationCut = struct { head: u64, tail: u64, capacity: usize };
pub const Effects = struct {
    stale_completion_counted: bool = false,
    pcm_published: bool = false,
    publication_published: bool = false,
    stream_failed: bool = false,
    stream_cancelled: bool = false,
    job_released: bool = false,
    throughput_observation_attempted: bool = false,
};
pub const Outcome = enum { not_started, no_completion, availability_unavailable, ring_capacity, publication_capacity, accepted, failed };
pub const Acceptance = struct {
    position: trace.schema.Position = .{ .accepted_control_frame = 0, .control_tick = 0, .input_order = 0 },
    batch_id: u64 = 0,
    runtime_attached: bool = false,
    replay_mode: bool = false,
    job_slots: usize = 0,
    scanned: usize = 0,
    representation_complete: bool = true,
    states: [job_capacity]JobState = @splat(.free),
    /// Indexed by acquired job-slot position. Valid only for .completed state.
    completed: [job_capacity]CompletedIdentity = @splat(.{}),
    selected: ?Selected = null,
    availability: Availability = .{},
    ring_capacity: ?u32 = null,
    publication_preflight: ?PublicationCut = null,
    /// acceptJob's separate capacity cut; absent when batch check short-circuits.
    publication_commit: ?PublicationCut = null,
    last_batch_id: ?u64 = null,
    next_snapshot: ?u64 = null,
    cancel: ?bool = null,
    stopped: ?bool = null,
    generation: ?u64 = null,
    transport_epoch: ?u64 = null,
    stale: ?bool = null,
    actual_worker: ?trace.schema.Worker = null,
    coordinate: ?ring.Coordinate = null,
    ring_produced: ?u64 = null,
    ring_writable: ?ring.ReadCut = null,
    ring_publish: ring.PublishObservation = .{},
    publication: ?visibility.Descriptor = null,
    outcome: Outcome = .not_started,
    /// Exact returned error, or suppressed availability error on the null path.
    error_code: u32 = 0,
    effects: Effects = .{},
    accepted: ?Accepted = null,
};
pub const Visibility = struct {
    tail: u64 = 0,
    read: u64 = 0,
    admission: ?trace.schema.Admission = null,
    descriptor: ?visibility.Descriptor = null,
    acknowledged: bool = false,
};
pub const acceptance_bytes: usize = @sizeOf(Acceptance);
pub const visibility_bytes: usize = @sizeOf(Visibility);
