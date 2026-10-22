//! Bounded Control ownership / Render terminal bridge. Slots do not themselves
//! prove scheduler capacity. ControlRuntime reserves actual common credits first.
const std = @import("std");
pub const life = @import("sme-duck-lifetime");
pub const Error = life.Error;
pub const Kind = enum { begin, end };
pub const Tracked = struct { handle: life.Handle, kind: Kind };
pub const Slot = struct {
    cell: life.Cell = .{},
    begin_batch: ?life.Graph = null,
    end_batch: ?life.Graph = null,
    references: u16 = 0, // Control: all schedule blocks, including terminal ones.
    end_pending: bool = false,
    end_executed: bool = false,
    terminal_consumed: bool = false,
};
pub const Manager = struct {
    slots: [life.capacity]Slot = @splat(.{}),
    next_generation: u64 = 1,
    pub fn get(self: *Manager, handle: life.Handle) Error!*Slot {
        if (handle.index >= self.slots.len or handle.generation == 0) return error.StaleDuck;
        const slot = &self.slots[handle.index];
        if (slot.cell.state.load(.acquire) == .free or !slot.cell.handle.eql(handle)) return error.StaleDuck;
        return slot;
    }
    pub fn collision(self: *const Manager, graph: life.Graph, bus: u32, id: u32) ?life.Handle {
        for (&self.slots) |*slot| {
            if (slot.cell.state.load(.acquire) == .free) continue;
            const identity = slot.cell.identity;
            if (std.meta.eql(identity.graph, graph) and identity.bus == bus and identity.dsp_id == id) return slot.cell.handle;
        }
        return null;
    }
    pub fn prepare(self: *Manager, identity: life.Identity) Error!life.Handle {
        try identity.validate();
        if (self.collision(identity.graph, identity.bus, identity.dsp_id) != null) return error.DuckBusy;
        // An external name has no incarnation in the public end request. Keep
        // overlapping names unavailable even when DSP keys differ.
        for (&self.slots) |*slot| if (slot.cell.state.load(.acquire) != .free and slot.cell.identity.context == identity.context and slot.cell.identity.external_id == identity.external_id) return error.DuckBusy;
        if (self.next_generation == std.math.maxInt(u64)) return error.DuckGenerationExhausted;
        for (&self.slots, 0..) |*slot, i| if (slot.cell.state.load(.acquire) == .free) {
            const handle: life.Handle = .{ .context = identity.context, .index = @intCast(i), .generation = self.next_generation };
            self.next_generation += 1;
            slot.* = .{};
            slot.cell.handle = handle;
            slot.cell.identity = identity;
            slot.cell.state.store(.prepared, .release);
            return handle;
        };
        return error.DuckCapacity;
    }
    /// Reservations remain until terminal consumption. A bound cleanup block
    /// already represents its block/plan/fence credit and is counted only once.
    pub fn stopCredits(self: *const Manager) usize {
        var n: usize = 0;
        for (&self.slots) |*slot| if (slot.cell.state.load(.acquire) != .free and !slot.terminal_consumed and !slot.end_pending) {
            n += 1;
        };
        return n;
    }
    pub fn validateBind(self: *Manager, tracked: Tracked) Error!void {
        const slot = try self.get(tracked.handle);
        const state = slot.cell.state.load(.acquire);
        if (slot.references == std.math.maxInt(u16)) return error.DuckCapacity;
        switch (tracked.kind) {
            .begin => if (state != .prepared) return error.DuckBusy,
            .end => if (state == .prepared or slot.end_pending or slot.end_executed or slot.terminal_consumed) return error.DuckBusy,
        }
    }
    pub fn bind(self: *Manager, tracked: Tracked, anchor: life.Anchor) void {
        self.validateBind(tracked) catch unreachable;
        const slot = self.get(tracked.handle) catch unreachable;
        slot.references += 1;
        switch (tracked.kind) {
            .begin => {
                slot.cell.begin = anchor;
                slot.cell.state.store(.bound, .release);
            },
            .end => slot.end_pending = true,
        }
    }
    /// Only after the real phase receipt was acquired. An unsuccessful end
    /// returns its reserved credit; it does not invent DSP retirement.
    pub fn releaseCommand(self: *Manager, tracked: Tracked, success: bool, frame: u64) void {
        const slot = self.get(tracked.handle) catch unreachable;
        std.debug.assert(slot.references != 0);
        if (tracked.kind == .begin and !success and slot.cell.state.load(.acquire) == .bound) slot.cell.publish(.begin_rejected, frame, frame);
        slot.references -= 1;
        if (tracked.kind == .end) {
            std.debug.assert(slot.end_pending);
            slot.end_pending = false;
            slot.end_executed = success;
        }
    }
    pub fn consume(self: *Manager, handle: life.Handle, frontier: u64) Error!?life.Terminal {
        const slot = try self.get(handle);
        const terminal = slot.cell.observe(frontier) orelse return null;
        slot.terminal_consumed = true;
        return terminal;
    }
    pub fn releasable(self: *Manager, handle: life.Handle, frontier: u64) Error!void {
        const slot = try self.get(handle);
        if (slot.references != 0 or slot.end_pending) return error.DuckDrainPending;
        if (slot.cell.state.load(.acquire) == .prepared) return;
        if (!slot.terminal_consumed or slot.cell.observe(frontier) == null) return error.DuckDrainPending;
    }
    pub fn release(self: *Manager, handle: life.Handle, frontier: u64) Error!life.Identity {
        try self.releasable(handle, frontier);
        const slot = try self.get(handle);
        const identity = slot.cell.identity;
        slot.cell.state.store(.free, .release);
        return identity;
    }
    pub fn empty(self: *const Manager) bool {
        for (&self.slots) |*slot| if (slot.cell.state.load(.acquire) != .free) return false;
        return true;
    }
};
