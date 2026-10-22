//! Public, pointer-free device facts. Notification is one preallocated atomic
//! cell. Repeated loss for the same open device coalesces without losing loss;
//! the host cannot reopen until Control acknowledges the resulting epoch.
const std = @import("std");
const contract = @import("contract.zig");

pub const Signal = struct {
    pending: std.atomic.Value(bool) = .init(false),
    duplicates: std.atomic.Value(u64) = .init(0),

    /// Callback-safe: no waits, allocation, device calls or Control/mixer access.
    /// false is a full/coalesced cell, never permission to discard the first loss.
    pub fn notify(self: *Signal) bool {
        if (self.pending.swap(true, .acq_rel)) {
            _ = self.duplicates.fetchAdd(1, .monotonic);
            return false;
        }
        return true;
    }
};

pub const Loss = struct {
    flush: contract.DeviceFlushRecord,
    render_frame: u64,
    submitted_frames: u64,
    sample_rate: u32,
    channels: u16,
    channel_mask: u32,
    policy: contract.DeviceRecoveryPolicy = .restart_at_bar,
};
pub const Stage = enum { unaffected, queued, draining, policy_required, scheduled, recovered, stopped };
pub const PreparationFailure = enum { capacity, source_read, clock_range, identity_exhausted, invalid_state };
pub const Status = struct {
    device_epoch: u64 = 1,
    stage: Stage = .unaffected,
    policy: contract.DeviceRecoveryPolicy = .restart_at_bar,
    accepted_tick: u64 = 0,
    accepted_frame: u64 = 0,
    discarded_frames: u64 = 0,
    restart_frame: ?u64 = null,
    phase: ?contract.PhaseReceipt = null,
    /// The loss is accepted even when recovery is unsupported. Music remains
    /// stopped; callers may explicitly choose restart or shut down.
    failure: ?enum { unsupported_profile, unavailable_phase, cancelled, invalid_state } = null,
    /// Failed streamed attempts keep their first cause while exact owners drain.
    preparation_failure: ?PreparationFailure = null,
};
