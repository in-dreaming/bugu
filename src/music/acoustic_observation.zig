//! Versioned raw acoustic facts. Numeric-only and independent of the mapper,
//! bank and runtime. This is distinct from the mapped-output Acoustic record.
const std = @import("std");
pub const version: u16 = 1;
pub const Error = error{ UnknownVersion, InvalidObservation, FutureAvailability };
pub const Input = enum(u8) { openness = 1, room = 2, path = 3 };
pub const Status = enum(u8) {
    ready = 1,
    unavailable = 2,
    missing = 3,
    nonfinite = 4,
    out_of_range = 5,
    overflow = 6,
};
/// Availability is when this fact became visible, not an inferred capture time.
/// Capture/version may be invalid source facts (e.g. zero version or a future
/// capture); the real mapper must reject them, preserving the recorded evidence.
/// Missing and failed conversions identify an actual attempted measurement.
pub const Lane = struct {
    status: Status,
    available_frame: u64,
    captured_frame: ?u64 = null,
    source_version: ?u64 = null,
    value_q16: ?i32 = null,
    lost_count: u32 = 0,
    pub fn validateAt(self: Lane, accepted_frame: u64) Error!void {
        if (self.available_frame > accepted_frame) return error.FutureAvailability;
        switch (self.status) {
            .ready => if (self.captured_frame == null or self.source_version == null or self.value_q16 == null or self.lost_count != 0) return error.InvalidObservation,
            .missing, .nonfinite, .out_of_range => if (self.captured_frame == null or self.source_version == null or self.value_q16 != null or self.lost_count != 0) return error.InvalidObservation,
            .unavailable => if (self.captured_frame != null or self.source_version != null or self.value_q16 != null or self.lost_count != 0) return error.InvalidObservation,
            .overflow => if (self.captured_frame != null or self.source_version != null or self.value_q16 != null or self.lost_count == 0) return error.InvalidObservation,
        }
    }
    /// This records a conversion failure explicitly. No NaN, infinity or value
    /// outside signed Q16.16 is clamped into an apparently valid measurement.
    pub fn fromScalar(value: f64, captured_frame: u64, available_frame: u64, source_version: u64) Lane {
        var result: Lane = .{ .status = .ready, .available_frame = available_frame, .captured_frame = captured_frame, .source_version = source_version };
        if (!std.math.isFinite(value)) {
            result.status = .nonfinite;
            return result;
        }
        const scaled = value * 65536.0;
        if (!std.math.isFinite(scaled) or scaled < -2147483648.0 or scaled > 2147483647.0) {
            result.status = .out_of_range;
            return result;
        }
        const floor = @floor(scaled);
        const fraction = scaled - floor;
        var n: i64 = @intFromFloat(floor);
        if (fraction > 0.5 or (fraction == 0.5 and @mod(n, 2) != 0)) n += 1;
        result.value_q16 = @intCast(n);
        return result;
    }
};
pub const Observation = struct {
    schema_version: u16 = version,
    context: u64,
    asset_generation: u64,
    transport_epoch: u64,
    device_epoch: u64,
    profile: u64,
    parameter: u64,
    input: Input,
    gpu: Lane,
    cpu: Lane,
    pub fn validateAt(self: Observation, accepted_frame: u64) Error!void {
        if (self.schema_version != version) return error.UnknownVersion;
        if (self.context == 0 or self.asset_generation == 0 or self.transport_epoch == 0 or self.device_epoch == 0 or self.profile == 0 or self.parameter == 0) return error.InvalidObservation;
        try self.gpu.validateAt(accepted_frame);
        try self.cpu.validateAt(accepted_frame);
    }
    pub fn hasLoss(self: Observation) bool {
        return self.gpu.status == .overflow or self.cpu.status == .overflow;
    }
};
