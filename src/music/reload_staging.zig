//! Internal asset-preparation ownership only. An assets_prepared outcome is not
//! migration admission, retained-history reservation, or a Render activation.
//! No declaration here is exported by the public music facade.
const std = @import("std");
const v1 = @import("runtime_contract.zig");

pub const Ticket = struct { source: v1.BankRefV1, sequence: u64 };
pub const Candidate = struct {
    source_build_id: u64,
    target_build_id: u64,
    content_hash: [32]u8,
    // Authored identity is distinct from the separately reserved runtime identity.
    // Reservation precedes provider work but does not imply activation admission.
    authored_generation: u64,
};
pub const AbortReason = enum { requested, unloading, shutdown };
pub const Status = union(enum) {
    pending,
    assets_prepared: Candidate,
    unchanged,
    aborted: AbortReason,
    failed: v1.FailureV1,
    pub fn terminal(self: Status) bool {
        return switch (self) {
            .pending, .assets_prepared => false,
            .unchanged, .aborted, .failed => true,
        };
    }
};
pub const Diagnostics = struct {
    source_preparation_leases: u32,
    pending_plan_leases: u32,
    candidate_owned: bool,
    input_bytes: u64,
    worker_preparing: bool,
};

pub fn Slot(comptime Generation: type) type {
    return struct {
        const Self = @This();
        pub const State = enum(u8) { idle, queued, preparing, completed, sources_queued, sources_preparing, sources_completed, held, retiring, retired, terminal };
        // Worker owns content/source preparation and provider-close phases.
        // Control reads Worker-mutated fields only after acquire-completion.
        state: std.atomic.Value(State) = .init(.idle),
        bytes: []u8 = &.{},
        candidate: ?*Generation = null,
        failure: ?v1.FailureV1 = null,
        input_bytes: std.atomic.Value(u64) = .init(0),
        cancelled: std.atomic.Value(bool) = .init(false),
        // The remaining fields have one serialized Control owner.
        source: ?*Generation = null,
        ticket: ?Ticket = null,
        status: Status = .pending,
        terminal_status: ?Status = null,
        abort_reason: AbortReason = .requested,
        next_sequence: u64 = 1,
        pub fn ownsResources(self: *const Self) bool {
            return switch (self.state.load(.acquire)) {
                .idle, .terminal => false,
                else => true,
            };
        }
    };
}
