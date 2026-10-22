//! Control-owned immutable physical-binding transactions. Render publishes an
//! actual transfer result; Control reclaims only after its completed frontier.
const std = @import("std");
const group = @import("../mixer/music_group.zig");
pub const capacity = 2; // One current binding plus one candidate/retiring binding.
pub const Error = error{ InvalidState, StaleContinuity, ContinuityCapacity, DrainPending };
pub const Handle = struct { index: u16, generation: u64 };
pub const State = enum(u8) { free, prepared, bound, executed, cancelled };
pub const Slot = struct {
    state: std.atomic.Value(State) = .init(.free),
    generation: u64 = 0,
    desc: group.SourceContinuity = undefined,
    content_hash: [32]u8 = @splat(0),
    coordinate: group.ContinuityCoordinate = undefined,
    schedule_ref: bool = false,
    installed: bool = false,
    retired_frame: ?u64 = null,
    retired_completed_frontier: ?u64 = null,
    leased_mask: u16 = 0,
};
pub const Manager = struct {
    allocator: std.mem.Allocator,
    slots: [capacity]Slot = @splat(.{}),
    next_generation: u64 = 1,
    pub fn get(self: *Manager, handle: Handle) Error!*Slot {
        if (handle.index >= self.slots.len or handle.generation == 0) return error.StaleContinuity;
        const slot = &self.slots[handle.index];
        if (slot.state.load(.acquire) == .free or slot.generation != handle.generation) return error.StaleContinuity;
        return slot;
    }
    pub fn prepare(self: *Manager, desc: group.SourceContinuity) Error!Handle {
        return self.prepareHashed(desc, @splat(0));
    }
    /// Caller proves Service identity and authored windows. Fresh consumers are
    /// acquired atomically as a set; failure releases every earlier acquisition.
    pub fn prepareHashed(self: *Manager, desc: group.SourceContinuity, content_hash: [32]u8) Error!Handle {
        if (desc.source_incarnation == 0 or desc.layer_count == 0 or desc.layer_count > group.max_layers or desc.old_transport_epoch == 0 or
            desc.old_transport_epoch == std.math.maxInt(u64) or desc.new_transport_epoch != desc.old_transport_epoch + 1) return error.InvalidState;
        if (self.next_generation == std.math.maxInt(u64)) return error.ContinuityCapacity;
        const index = for (&self.slots, 0..) |*slot, i| {
            if (slot.state.load(.acquire) == .free) break i;
        } else return error.ContinuityCapacity;
        var leased_mask: u16 = 0;
        errdefer for (desc.sources[0..desc.layer_count], 0..) |source, i| {
            if (leased_mask & (@as(u16, 1) << @intCast(i)) != 0) source.?.release();
        };
        for (desc.sources[0..desc.layer_count], 0..) |source, i| {
            if (desc.old_sources[i]) |old| {
                if (desc.old_handles[i] == null or desc.old_handles[i].?.generation != old.stream_generation) return error.InvalidState;
            } else if (desc.old_handles[i] != null) return error.InvalidState;
            if (source) |fresh| {
                if (desc.paused or desc.old_sources[i] == null or desc.handles[i] == null or
                    desc.handles[i].?.generation != fresh.identity.stream_generation or fresh.identity.transport_epoch != desc.new_transport_epoch or
                    !group.sameAuthoredSource(desc.old_sources[i].?, fresh.identity)) return error.InvalidState;
                try fresh.retain();
                leased_mask |= @as(u16, 1) << @intCast(i);
            } else if (desc.handles[i] != null or (!desc.paused and desc.old_sources[i] != null)) return error.InvalidState;
        }
        const slot = &self.slots[index];
        slot.* = .{ .generation = self.next_generation, .desc = desc, .content_hash = content_hash, .leased_mask = leased_mask };
        self.next_generation += 1;
        slot.state.store(.prepared, .release);
        return .{ .index = @intCast(index), .generation = slot.generation };
    }
    pub fn bind(self: *Manager, handle: Handle) void {
        const slot = self.get(handle) catch unreachable;
        std.debug.assert(slot.state.load(.acquire) == .prepared and !slot.schedule_ref);
        slot.schedule_ref = true;
        slot.state.store(.bound, .release);
    }
    pub fn executed(self: *Manager, handle: Handle, coordinate: group.ContinuityCoordinate) void {
        const slot = self.get(handle) catch unreachable;
        std.debug.assert(slot.state.load(.acquire) == .bound);
        slot.coordinate = coordinate;
        slot.state.store(.executed, .release);
    }
    pub fn acknowledge(self: *Manager, handle: Handle, succeeded: bool) void {
        const slot = self.get(handle) catch unreachable;
        const state = slot.state.load(.acquire);
        std.debug.assert(slot.schedule_ref);
        if (succeeded) {
            std.debug.assert(state == .executed);
            slot.installed = !slot.desc.paused;
        } else {
            std.debug.assert(state == .bound);
            slot.state.store(.cancelled, .release);
        }
        slot.schedule_ref = false;
    }
    pub fn retire(self: *Manager, handle: Handle, frame: u64) Error!void {
        const slot = try self.get(handle);
        if (slot.state.load(.acquire) != .executed or !slot.installed or frame < slot.coordinate.frame) return error.InvalidState;
        slot.retired_frame = frame;
    }
    pub fn result(self: *Manager, handle: Handle) Error!?group.ContinuityCoordinate {
        const slot = try self.get(handle);
        return if (slot.state.load(.acquire) == .executed) slot.coordinate else null;
    }
    pub fn release(self: *Manager, handle: Handle, completed_frame: u64) Error!void {
        const slot = try self.get(handle);
        const state = slot.state.load(.acquire);
        if (slot.schedule_ref or state == .bound) return error.DrainPending;
        if (state == .executed) {
            if (slot.retired_completed_frontier) |frontier| {
                if (completed_frame < frontier) return error.DrainPending;
            } else {
                const frontier = if (slot.installed) slot.retired_frame orelse return error.DrainPending else slot.coordinate.frame;
                if (completed_frame <= frontier) return error.DrainPending;
            }
        }
        for (slot.desc.sources[0..slot.desc.layer_count], 0..) |source, i| {
            if (slot.leased_mask & (@as(u16, 1) << @intCast(i)) == 0) continue;
            source.?.ring.stopped.store(true, .release);
            source.?.release();
        }
        slot.state.store(.free, .release);
    }
    pub fn retained(self: *const Manager) usize {
        var count: usize = 0;
        for (&self.slots) |*slot| count += @intFromBool(slot.state.load(.acquire) != .free);
        return count;
    }
};
