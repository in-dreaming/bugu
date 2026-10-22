//! Accepted external measurements, not planner outcomes. A replay consumer sees
//! only Facts; its recomputed Projection is checked against the recording.
const s = @import("trace_schema.zig");
pub const Facts = struct {
    context: u64,
    asset: u64,
    generation: u64,
    transport_epoch: u64,
    control_epoch: u64,
    snapshot_version: u64,
    profile: u64,
    profile_hash: s.Hash,
    resident_chunk_first: u32,
    resident_chunk_count: u32,
    pcm_start: u64,
    pcm_end: u64,
    available_frames: u64,
    queued_bytes: u64,
    queued_frames: u64,
    backlog_frames: u64,
    backlog_jobs: u32,
    throughput_pcm_frames_per_second: ?u64,
    measurement_version: u32,
    pub fn validate(self: Facts) s.Error!void {
        if (self.context == 0 or self.asset == 0 or self.generation == 0 or self.transport_epoch == 0 or self.control_epoch == 0 or self.snapshot_version == 0 or self.profile == 0 or s.isZero(self.profile_hash) or self.measurement_version == 0) return error.InvalidEvent;
        if (self.pcm_end < self.pcm_start or self.available_frames > self.pcm_end - self.pcm_start or @addWithOverflow(self.resident_chunk_first, self.resident_chunk_count)[1] != 0) return error.InvalidEvent;
        if (self.throughput_pcm_frames_per_second) |rate| if (rate == 0) return error.InvalidEvent;
    }
};
pub const Projection = struct { estimated_ready_frame: ?u64, watermark_frames: u64, deadline_frame: u64, ready: bool };
pub const Observation = struct {
    facts: Facts,
    expected: Projection,
    pub fn validate(self: Observation) s.Error!void {
        try self.facts.validate();
        if (self.facts.throughput_pcm_frames_per_second == null and self.facts.available_frames == 0 and (self.expected.estimated_ready_frame != null or self.expected.ready)) return error.InvalidEvent;
    }
};
pub const JobDescriptor = struct {
    job: u64,
    asset: u64,
    generation: u64,
    transport_epoch: u64,
    operation: s.WorkerOperation,
    group: u64,
    layer: u64,
    loop_epoch: u64,
    target_cursor: u64,
    realize_frame: u64,
};
