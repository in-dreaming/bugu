//! Frame-unit capacity and deterministic prefetch projection. No wall clock is
//! sampled here: measured facts are accepted by Control and recorded for replay.
const std = @import("std");
const trace = @import("sme-trace").schema;
pub const Error = error{ InvalidStreamProfile, CapacityOverflow, InvalidMeasurement };
pub const Priority = enum(u8) { imminent_target_fill, active_required, virtual_soon_realize, optional };
pub const StreamCapacityProfile = struct {
    id: u64 = 1,
    sample_rate: u32 = 48_000,
    max_streams: u16 = 48,
    max_channels: u8 = 8,
    ring_frames: u32 = 8192,
    decode_chunk_frames: u32 = 1024,
    job_capacity: u16 = 48,
    completion_capacity: u16 = 48,
    /// Unacknowledged accepted PCM publications, including receipt retention.
    visibility_capacity: u16 = 512,
    critical_frames: u32 = 512,
    low_frames: u32 = 2048,
    high_frames: u32 = 6144,
    prefetch_lead_frames: u32 = 96_000,
    deadline_margin_frames: u32 = 1024,
    max_encoded_chunk_bytes: u32 = 4 * 1024 * 1024,
    resident_limit_bytes: u64 = 16 * 1024 * 1024,
    /// One serialized codec/I/O owner. Control and render remain concurrent.
    worker_count: u8 = 1,
    allocation_budget_bytes: u64 = 192 * 1024 * 1024,
    pub fn validate(self: StreamCapacityProfile) Error!void {
        if (self.visibility_capacity == 0 or self.visibility_capacity > 4096 or self.allocation_budget_bytes == 0 or self.allocation_budget_bytes > 256 * 1024 * 1024 or self.ring_frames > 65536 or self.decode_chunk_frames > 5760 or self.id == 0 or self.sample_rate != 48_000 or self.max_streams == 0 or self.max_streams > 64 or self.max_channels == 0 or self.max_channels > 8 or self.worker_count != 1 or self.job_capacity == 0 or self.job_capacity > 256 or self.completion_capacity != self.job_capacity or self.completion_capacity > 256 or self.decode_chunk_frames == 0 or self.critical_frames == 0 or self.critical_frames > self.low_frames or self.low_frames >= self.high_frames or self.high_frames >= self.ring_frames or self.high_frames - self.low_frames < self.decode_chunk_frames or self.ring_frames - self.high_frames < self.decode_chunk_frames or self.prefetch_lead_frames < self.high_frames or self.deadline_margin_frames == 0 or self.deadline_margin_frames > self.prefetch_lead_frames or self.max_encoded_chunk_bytes == 0 or self.max_encoded_chunk_bytes > 4 * 1024 * 1024 or self.resident_limit_bytes == 0) return error.InvalidStreamProfile;
        if (try self.pcmBytes() > self.allocation_budget_bytes) return error.InvalidStreamProfile;
    }
    /// Owned rings and staging PCM only. Service.memory reports all other owned
    /// storage and measured native decoder state separately, never hides it.
    pub fn pcmBytes(self: StreamCapacityProfile) Error!usize {
        const frames = std.math.add(usize, try mul(self.max_streams, self.ring_frames), try mul(self.job_capacity, self.decode_chunk_frames)) catch return error.CapacityOverflow;
        return try mul(try mul(frames, self.max_channels), @sizeOf(f32));
    }
    pub fn hash(self: StreamCapacityProfile) [32]u8 {
        var bytes: [128]u8 = @splat(0);
        var position: usize = 0;
        inline for (@typeInfo(StreamCapacityProfile).@"struct".fields) |field| {
            const value = @field(self, field.name);
            std.mem.writeInt(@TypeOf(value), bytes[position..][0..@sizeOf(@TypeOf(value))], value, .little);
            position += @sizeOf(@TypeOf(value));
        }
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[0..position], &result, .{});
        return result;
    }
};
fn mul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.CapacityOverflow;
}
pub const release_profile: StreamCapacityProfile = .{};
pub const Watermark = enum { critical, low, filling, high };
pub fn watermark(profile: StreamCapacityProfile, available: u64) Watermark {
    if (available < profile.critical_frames) return .critical;
    if (available < profile.low_frames) return .low;
    if (available < profile.high_frames) return .filling;
    return .high;
}
/// Conservative rate is half the slowest observed end-to-end worker job rate,
/// so I/O, verification, preroll and decode all count in the measured cost.
pub const Throughput = struct {
    frames_per_second: ?u64 = null,
    version: u32 = 1,
    pub fn observe(self: *Throughput, frames: u64, elapsed_ns: u64) Error!void {
        if (frames == 0 or elapsed_ns == 0 or self.version == std.math.maxInt(u32)) return error.InvalidMeasurement;
        const rate: u64 = @intCast(@min(std.math.maxInt(u64), @as(u128, frames) * 1_000_000_000 / elapsed_ns / 2));
        self.frames_per_second = if (rate == 0) null else if (self.frames_per_second) |old| @min(old, rate) else rate;
        self.version += 1;
    }
};
pub fn project(profile: StreamCapacityProfile, accepted_frame: u64, available: u64, queued_frames: u64, backlog_frames: u64, rate: ?u64, deadline_frame: u64, needed: u64) trace.readiness.Projection {
    const ready = available >= needed;
    const estimate: ?u64 = if (ready) accepted_frame else estimate: {
        const throughput = rate orelse break :estimate null;
        if (throughput == 0) break :estimate null;
        const work: u128 = @as(u128, @max(queued_frames, needed - available)) + backlog_frames;
        const frames = (work * profile.sample_rate + throughput - 1) / throughput + profile.deadline_margin_frames;
        if (frames > std.math.maxInt(u64) - accepted_frame) break :estimate null;
        break :estimate accepted_frame + @as(u64, @intCast(frames));
    };
    return .{ .estimated_ready_frame = estimate, .watermark_frames = available, .deadline_frame = deadline_frame, .ready = ready };
}
