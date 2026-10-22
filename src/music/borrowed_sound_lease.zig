//! Bounded Control-owned return cells for real borrowed resident PCM.
//! The heap-stable anchor has no MusicRuntime pointer. Any thread may return a
//! single-use token; only Control collects credits and frees the anchor, last.
const std = @import("std");
const rt = @import("bugu_audio").runtime;
const registry = @import("sme-generation-admission").registry;
const v1 = @import("runtime_contract.zig");
pub const capacity = (v1.CapacityV1{}).borrowed_sound_lease_slots;
pub const max_incarnation = std.math.maxInt(u64) >> 3;
const Phase = enum(u3) { free, reserved, held, returning, returned };
fn encodeState(incarnation: u64, phase: Phase) u64 {
    return (incarnation << 3) | @intFromEnum(phase);
}
fn phaseOf(value: u64) Phase { return @enumFromInt(value & 7); }
pub fn nextIncarnation(previous: u64) !u64 {
    if (previous >= max_incarnation) return error.IdentityExhausted;
    return previous + 1;
}
pub const Payload = struct { generation: registry.Handle, owner: *rt.SampleOwner };
const Cell = struct {
    state: std.atomic.Value(u64) = .init(0),
    payload: Payload = undefined,
};
pub const Token = struct {
    anchor: *Anchor,
    index: u16,
    incarnation: u64,

    /// Single use. Copies do not create new ownership. A stale/duplicate token
    /// is detectable while its anchor remains alive, without reading recycled
    /// payload. No operation on a token is valid after anchor destruction.
    /// The caller must keep the owner alias unused after this release.
    pub fn release(self: Token) bool {
        if (self.index >= capacity or self.incarnation == 0 or self.incarnation > max_incarnation) return false;
        const cell = &self.anchor.cells[self.index];
        if (cell.state.cmpxchgStrong(encodeState(self.incarnation, .held), encodeState(self.incarnation, .returning), .acq_rel, .acquire) != null) return false;
        const owner = cell.payload.owner;
        owner.release();
        // FINAL anchor/owner access by this releasing thread. Control can
        // acquire this publication, destroy the owner and finally this anchor.
        cell.state.store(encodeState(self.incarnation, .returned), .release);
        return true;
    }
};
pub const Snapshot = struct { outstanding: u32, returned_uncollected: u32, accepting: bool };
pub const Anchor = struct {
    cells: [capacity]Cell = @splat(.{}),
    outstanding: u32 = 0,
    accepting: bool = true,

    /// Serialized Control only. Reservation precedes registry/physical retain;
    /// caller cancels on either failure and publishes only after both succeed.
    pub fn reserve(self: *Anchor, payload: Payload) !Token {
        if (!self.accepting) return error.RuntimeStopped;
        for (&self.cells, 0..) |*cell, index| {
            const previous = cell.state.load(.monotonic);
            if (phaseOf(previous) != .free) continue;
            const incarnation = nextIncarnation(previous >> 3) catch continue;
            cell.payload = payload;
            cell.state.store(encodeState(incarnation, .reserved), .monotonic);
            std.debug.assert(self.outstanding < capacity);
            self.outstanding += 1; // At most one reservation per bounded cell.
            return .{ .anchor = self, .index = @intCast(index), .incarnation = incarnation };
        }
        return error.BorrowedLeaseCapacityExceeded; // Exhausted cells never wrap.
    }
    pub fn cancel(self: *Anchor, token: Token) void {
        std.debug.assert(token.anchor == self);
        const cell = &self.cells[token.index];
        std.debug.assert(cell.state.load(.monotonic) == encodeState(token.incarnation, .reserved));
        cell.payload = undefined;
        cell.state.store(encodeState(token.incarnation, .free), .monotonic);
        self.outstanding -= 1;
    }
    pub fn publish(self: *Anchor, token: Token) void {
        std.debug.assert(token.anchor == self);
        const cell = &self.cells[token.index];
        std.debug.assert(cell.state.load(.monotonic) == encodeState(token.incarnation, .reserved));
        cell.state.store(encodeState(token.incarnation, .held), .release);
    }
    /// Acquire the releasing thread's FINAL access before removing custody.
    /// Caller owns the returned exact handle and must return its credit once.
    pub fn collect(self: *Anchor, index: usize) ?registry.Handle {
        const cell = &self.cells[index];
        const state = cell.state.load(.acquire);
        if (phaseOf(state) != .returned) return null;
        const generation = cell.payload.generation;
        cell.payload = undefined;
        cell.state.store(encodeState(state >> 3, .free), .monotonic);
        self.outstanding -= 1;
        return generation;
    }
    pub fn close(self: *Anchor) void { self.accepting = false; }
    pub fn snapshot(self: *const Anchor) Snapshot {
        var returned: u32 = 0;
        for (&self.cells) |*cell| returned += @intFromBool(phaseOf(cell.state.load(.acquire)) == .returned);
        return .{ .outstanding = self.outstanding, .returned_uncollected = returned, .accepting = self.accepting };
    }
    /// Control-only conservation check. Releasers change phase, never payload or
    /// membership; reserved cells are transient and checked only by their owner.
    pub fn countFor(self: *const Anchor, generation: registry.Handle) u64 {
        var count: u64 = 0;
        for (&self.cells) |*cell| {
            if (phaseOf(cell.state.load(.acquire)) == .free) continue;
            if (std.meta.eql(cell.payload.generation, generation)) count += 1;
        }
        return count;
    }
};
