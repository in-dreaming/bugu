//! Public bounded reload values. The V2 source-aware entry points add stable
//! four-stem streamed hard cuts; pending fills and replay remain out of scope. Renamed IDs
//! require explicit mapped-equivalent topology and selector migration policies.
const v1 = @import("runtime_contract.zig");
const contracts = @import("sme-generation-admission");
pub const migration = contracts.contracts.migration;
pub const epoch_policy = contracts.policy;
pub const retention = contracts.contracts.retention;
pub const Options = struct {
    version: u16 = 1,
    publish: enum { next_bar_hard_cut } = .next_bar_hard_cut,
    retention: retention.GenerationRetentionProfile = .{
        .history_capacity = 2,
        .rollback_retention = 2,
        .max_retained_bytes = 256 * 1024 * 1024,
        .max_retained_leases = 4096,
    },
    pub fn validate(self: Options) !void {
        if (self.version != 1) return error.UnsupportedVersion;
        try self.retention.validate();
        if (self.retention.history_capacity < 2 or self.retention.rollback_retention < 2) return error.UnsupportedCapacity;
    }
};
/// For streamed V2 calls, activated reports the acquired executed gate even
/// while old-provider close/unbind is pending. acknowledgeReloadV1 is the
/// provider-release boundary and returns DrainPending until all old custody
/// has drained. After activation, acknowledgement releases the outgoing provider
/// only; the activated provider stays borrowed until its successor is
/// acknowledged or unload/shutdown completes. For failed, cancelled or unchanged
/// candidates, successful acknowledgement releases candidate custody (if any);
/// the still-playing provider remains borrowed.
/// Retention byte limits account engine-owned storage; provider-private memory
/// is external and cannot be measured by the runtime.
pub const Poll = union(enum) {
    pending,
    unchanged,
    activated: struct {
        bank: v1.BankRefV1,
        previous_generation: u64,
        content_hash: [32]u8,
        phase: @import("contract.zig").PhaseReceipt,
    },
    failed: v1.FailureV1,
};
pub const Retained = struct {
    generation: u64,
    build_id: u64,
    content_hash: [32]u8,
    active: bool,
    retained_bytes: u64,
    leases: u64,
};
