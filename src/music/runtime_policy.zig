//! Heap-pinned bounded storage owned exclusively by the existing MusicRuntime.
//! The helpers here do not own a clock, scheduler, admission queue or renderer.
const std = @import("std");
const rt = @import("bugu_audio").runtime;
const helper = @import("sme-policy-runtime");
const v1 = @import("runtime_contract.zig");
const api = @import("contract.zig");
const assets = @import("runtime_assets.zig");
const trace = @import("sme-trace").schema;
pub const capacity = @min(rt.scheduler.default_profile.block_capacity, rt.scheduler.default_profile.plan_capacity, rt.scheduler.default_profile.epoch_fence_capacity, rt.bus_runtime.duck_lifetime.capacity);
pub const Plan = struct {
    block: rt.scheduler.Handle,
    plan: rt.scheduler.Handle,
    token: api.PhaseToken,
    submitted: bool = false,
    phase_cursor: u16 = 0,
    receipt_cursor: u16 = 0,
    admission_seen: bool = false,
    phase: ?api.PhaseReceipt = null,
    failure: ?v1.FailureV1 = null,
    rejection_reason: ?trace.Reason = null,
    /// Actual scheduler rejection frontier, never an executed PhaseReceipt.
    rejection_frame: ?u64 = null,
    cancellation: ?rt.scheduler.Handle = null,
};
pub const DuckState = struct {
    preset: u64 = 0,
    external_id: u64 = 0,
    render_id: u32 = 0,
    lease: ?helper.DuckLease = null,
    begin: ?Plan = null,
    end: ?Plan = null,
    end_accepted: ?trace.Position = null,
    stop_requested: bool = false,
    end_executed: bool = false,
    terminal_consumed: bool = false,
    result: v1.DuckLifetimeV1 = undefined,
};
/// Stable dependency on one retained policy lifetime, never a reusable slot index.
pub const StingerVictim = struct { ticket: v1.RequestTicketV1, incarnation: u64 };
pub const PreparedStingerVictim = struct { identity: StingerVictim, group: rt.GroupHandle };
pub const StingerState = struct {
    entry_index: u32,
    identity: helper.stinger_admission.Identity,
    group: ?rt.GroupHandle = null,
    begin: ?Plan = null,
    end: ?Plan = null,
    stop_requested: bool = false,
    reprepare: bool = false,
    replacement_requested: bool = false,
    /// Replacement uses an immediate atomic stop; public emergency cleanup
    /// records its distinct frozen physical release span before preparation.
    stop_release_frames: u32 = 0,
    prepared_victim: ?PreparedStingerVictim = null,
    waiting_victim: ?StingerVictim = null,
    result: v1.StingerLifetimeV1,
};
pub const Slot = struct {
    occupied: bool = false,
    generation_lease: ?assets.PolicyGenerationLease = null,
    ticket: v1.RequestTicketV1 = undefined,
    accepted: trace.Position = undefined,
    incarnation: u64 = 0,
    action_ticket: ?v1.RequestTicketV1 = null,
    data: union(enum) { duck: DuckState, stinger: StingerState } = .{ .duck = .{} },
    pub fn drained(self: *const Slot) bool {
        return switch (self.data) {
            .duck => |value| value.result.physical_drained,
            .stinger => |value| value.result.physical_drained,
        };
    }
    pub fn requestStop(self: *Slot, accepted: ?trace.Position) void {
        switch (self.data) {
            .duck => |*value| {
                value.stop_requested = true;
                if (value.end_accepted == null) value.end_accepted = accepted;
            },
            .stinger => |*value| {
                value.stop_requested = true;
                value.stop_release_frames = rt.scheduler.default_profile.emergency_ramp_frames;
            },
        }
    }
};
pub const Storage = struct {
    slots: [capacity]Slot,
    graph: ?helper.GraphBinding,
    bootstrap: ?Plan,
    graph_installed: bool,
    /// Exact primary/interruption owner retained through physical policy drain.
    music_stop_ticket: ?v1.RequestTicketV1,
    music_stop_phase: ?api.PhaseReceipt,
    lifecycle_stop: bool,
    cleanup_accepted: ?trace.Position,
    cleanup_phase: ?api.PhaseReceipt,
    next_incarnation: u64,
    next_render_id: u32,
    pub fn create(allocator: std.mem.Allocator) !*Storage {
        const self = try allocator.create(Storage);
        // Never create a whole-pool temporary on the construction stack.
        for (&self.slots) |*slot| slot.* = .{};
        self.graph = null;
        self.bootstrap = null;
        self.graph_installed = false;
        self.music_stop_ticket = null;
        self.music_stop_phase = null;
        self.lifecycle_stop = false;
        self.cleanup_accepted = null;
        self.cleanup_phase = null;
        self.next_incarnation = 1;
        self.next_render_id = 1;
        return self;
    }
    pub fn slotForTicket(self: *Storage, ticket: v1.RequestTicketV1) ?*Slot {
        for (&self.slots) |*slot| if (slot.occupied and std.meta.eql(slot.ticket, ticket)) return slot;
        return null;
    }
    pub fn action(self: *Storage, ticket: v1.RequestTicketV1) ?*Slot {
        for (&self.slots) |*slot| if (slot.occupied) if (slot.action_ticket) |owned| if (std.meta.eql(owned, ticket)) return slot;
        return null;
    }
    pub fn physicalCount(self: *const Storage) u32 {
        var count: u32 = 0;
        for (self.slots) |slot| if (slot.occupied and !slot.drained()) {
            count += 1;
        };
        return count;
    }
    pub fn requestCount(self: *const Storage) u32 {
        var count: u32 = 0;
        for (self.slots) |slot| if (slot.occupied and slot.action_ticket != null) {
            count += 1;
        };
        return count;
    }
    pub fn planCount(self: *const Storage) u32 {
        var count: u32 = @intFromBool(self.bootstrap != null);
        for (self.slots) |slot| if (slot.occupied) {
            count += switch (slot.data) {
                .duck => |value| @as(u32, @intFromBool(value.begin != null)) + @intFromBool(value.end != null),
                .stinger => |value| @as(u32, @intFromBool(value.begin != null)) + @intFromBool(value.end != null),
            };
        };
        return count;
    }
    pub fn resultCount(self: *const Storage) u32 {
        var count: u32 = 0;
        for (self.slots) |slot| if (slot.occupied) {
            const ready = switch (slot.data) {
                .duck => |value| value.result.terminal != null or value.result.preparation_failure != null,
                .stinger => |value| value.result.terminal != null or value.result.preparation_failure != null,
            };
            count += @intFromBool(ready);
        };
        return count;
    }
    pub fn retainedCount(self: *const Storage) u32 {
        var count: u32 = 0;
        for (self.slots) |slot| count += @intFromBool(slot.occupied);
        return count;
    }
};
