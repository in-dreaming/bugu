//! One bounded profile-tagged fence/install transaction. Descriptors are immutable
//! after schedule binding; only Render publishes execution facts. No PCM copy.
const std = @import("std");
const group = @import("../mixer/music_group.zig");
const scheduler = @import("sme-scheduler");
pub const Error = error{ ResidentTransactionBusy, StaleResidentTransaction, InvalidState, UnsupportedOperation };
pub const Handle = struct { generation: u64 };
/// The resident profile remains the default, including its historical digest.
pub const Profile = enum(u8) { resident_v1 = 1, stream_direct_v1 = 2, stream_fill_v1 = 3, stream_reload_v1 = 4 };
pub const GroupSet = struct {
    items: [4]group.Handle = undefined,
    count: u8 = 0,
    pub fn contains(self: *const GroupSet, handle: group.Handle) bool {
        for (self.items[0..self.count]) |item| if (item.eql(handle)) return true;
        return false;
    }
};
/// First resident profile: source cursor/pause plus unchanged authored steady
/// group/layer gains and loop bounds. Dynamic DSP state is rejected at the
/// actual ordered fence, including completed raw gain or loop mutations.
pub const CaptureDesc = struct {
    profile: Profile = .resident_v1,
    bank_generation: u64,
    transport_epoch: u64,
    groups: GroupSet = .{},
    plan: ?scheduler.Handle = null,
};
/// Seek-only promise about the admitted outgoing source. Playback may advance
/// while fresh windows prepare, but this exact source identity may not change.
pub const PreviewSeekGuard = struct {
    outgoing: group.Handle,
    segment: u64,
    source_incarnation: u64,
    mutation_epoch: u64,
};
/// Replacement Prepared must use the saved steady gains and zero entry ramp.
pub const RestoreDesc = struct {
    profile: Profile = .resident_v1,
    /// Target generation. Omitted expected generation preserves same-bank restore.
    bank_generation: u64,
    expected_bank_generation: ?u64 = null,
    expected_transport_epoch: u64,
    new_transport_epoch: u64,
    install_frame: u64,
    old_groups: GroupSet = .{},
    old_plan: ?scheduler.Handle = null,
    replacement: ?group.Handle = null,
    paused: bool = false,
    /// Stream-reload-only promise at install_frame, sealed before publication.
    /// Segment names the outgoing group; the replacement may use a mapped ID.
    /// Legacy profiles neither interpret nor hash these optional fields.
    expected_outgoing_segment: ?u64 = null,
    expected_outgoing_cursor: ?u64 = null,
    expected_outgoing_loop_epoch: ?u64 = null,
    /// Optional tool-audition authority, only for same-generation stream_direct.
    /// Null preserves ordinary restore admission and its historical digest.
    seek_guard: ?PreviewSeekGuard = null,

    pub fn expectedBankGeneration(self: RestoreDesc) u64 {
        return self.expected_bank_generation orelse self.bank_generation;
    }
};
pub const Kind = enum { capture, restore };
pub const Descriptor = union(Kind) { capture: CaptureDesc, restore: RestoreDesc };
pub const Command = struct { transaction: Handle, content_hash: [32]u8 = @splat(0) };
pub const Physical = struct {
    group: group.Handle,
    source_incarnation: u64,
    segment: u64,
    cursor: u64,
    loop_epoch: u64,
    paused: bool,
    mutation_epoch: u64,
};
pub const Result = struct {
    kind: Kind,
    outcome: scheduler.Outcome,
    reason: scheduler.trace.Reason = .none,
    frame: u64 = 0,
    gate: u64 = 0,
    execution_ordinal: u64 = 0,
    /// Exact Render facts. Previous identities are sampled before replacement;
    /// current identities are published only after the no-fail install.
    previous_bank_generation: u64 = 0,
    previous_transport_epoch: u64 = 0,
    bank_generation: u64 = 0,
    transport_epoch: u64 = 0,
    physical: ?Physical = null,
    executed_prefix_count: u16 = 0,
    executed_frames: [scheduler.default_profile.phases_per_plan]u64 = @splat(0),
    executed_ordinals: [scheduler.default_profile.phases_per_plan]u64 = @splat(0),
};
pub const State = enum(u8) { free, prepared, bound, terminal };
pub const Slot = struct {
    state: std.atomic.Value(State) = .init(.free),
    generation: u64 = 0,
    desc: Descriptor = undefined,
    content_hash: [32]u8 = @splat(0),
    /// Profile-3 immutable, normalized pending-command descriptor digest.
    /// Kept after completed scheduler blocks are acknowledged and recycled.
    plan_content_hash: [32]u8 = @splat(0),
    block: ?scheduler.Handle = null,
    command_index: u16 = 0,
    result: Result = undefined,
    pub fn get(self: *Slot, handle: Handle) Error!*Slot {
        if (handle.generation == 0 or handle.generation != self.generation or self.state.load(.acquire) == .free) return error.StaleResidentTransaction;
        return self;
    }
    pub fn profile(self: *const Slot) Profile {
        return switch (self.desc) {
            .capture => |v| v.profile,
            .restore => |v| v.profile,
        };
    }
    pub fn groups(self: *const Slot) *const GroupSet {
        return switch (self.desc) {
            .capture => |*v| &v.groups,
            .restore => |*v| &v.old_groups,
        };
    }
    pub fn plan(self: *const Slot) ?scheduler.Handle {
        return switch (self.desc) {
            .capture => |v| v.plan,
            .restore => |v| v.old_plan,
        };
    }
};

test "snapshot transaction profile is explicit and resident by default" {
    const capture: CaptureDesc = .{ .bank_generation = 7, .transport_epoch = 3 };
    const restore: RestoreDesc = .{ .bank_generation = 7, .expected_transport_epoch = 3, .new_transport_epoch = 4, .install_frame = 128 };
    var slot: Slot = .{ .desc = .{ .capture = capture } };
    try std.testing.expectEqual(Profile.resident_v1, slot.profile());
    slot.desc = .{ .restore = restore };
    try std.testing.expectEqual(Profile.resident_v1, slot.profile());
    slot.desc.restore.profile = .stream_direct_v1;
    try std.testing.expectEqual(Profile.stream_direct_v1, slot.profile());
    slot.desc.restore.profile = .stream_fill_v1;
    try std.testing.expectEqual(Profile.stream_fill_v1, slot.profile());
    slot.desc = .{ .capture = capture };
    slot.desc.capture.profile = .stream_direct_v1;
    try std.testing.expectEqual(Profile.stream_direct_v1, slot.profile());
    slot.desc.capture.profile = .stream_fill_v1;
    try std.testing.expectEqual(Profile.stream_fill_v1, slot.profile());
}
