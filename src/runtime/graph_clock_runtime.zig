//! Ownership bridge for source-clock graph programs. Control owns allocations,
//! immutable descriptors and references. Render alone owns progress. A release /
//! acquire terminal state gates result reads and eventual Control reclamation.
const std = @import("std");
pub const gc = @import("sme-layer-graph-clock");
pub const Error = gc.Error || std.mem.Allocator.Error;
pub const State = enum(u8) { free, prepared, bound, active, terminal };
pub const Binding = struct { plan_epoch: u64, admitted_epoch: *const std.atomic.Value(u64) };
pub const SourceBinding = struct { hash: [32]u8 = @splat(0), handle: ?struct { index: u16, generation: u64 } = null };
pub const Slot = struct {
    source_binding: SourceBinding = .{},
    state: std.atomic.Value(State) = .init(.free),
    generation: u64 = 0,
    desc: gc.Desc = undefined,
    binding: ?Binding = null,
    references: u16 = 0,
    predecessor_retained: bool = false,
    stop_credit: bool = false,
    stop_pending: bool = false,
    bytes: usize = 0,
    progress: gc.Progress = undefined, // Render only until terminal publication.
};
pub const Usage = struct { programs: usize, targets: usize, spans: usize, retained_metadata_bytes: usize, last_prepare_peak_bytes: usize, reserved_stop_credits: usize };
pub fn copiedBytes(desc: gc.Desc) usize {
    return @sizeOf(gc.spans.TrackDesc) + desc.progress.spans.len * @sizeOf(gc.spans.Span) + desc.targets.len * @sizeOf(gc.Write);
}
pub const Manager = struct {
    allocator: std.mem.Allocator,
    slots: [gc.max_programs]Slot = @splat(.{}),
    next_generation: u64 = 1,
    retained_spans: usize = 0,
    retained_targets: usize = 0,
    retained_bytes: usize = @sizeOf(Manager),
    last_prepare_peak_bytes: usize = 0,
    pub fn create(allocator: std.mem.Allocator, bridge_bytes: usize, profile: gc.Profile) Error!*Manager {
        try profile.validate();
        if (@sizeOf(Manager) > profile.metadata_bytes or bridge_bytes > profile.metadata_bytes - @sizeOf(Manager)) return error.GraphProgramBudgetExceeded;
        const self = try allocator.create(Manager);
        self.* = .{ .allocator = allocator, .retained_bytes = @sizeOf(Manager) + bridge_bytes };
        return self;
    }
    pub fn get(self: *Manager, handle: gc.Handle) Error!*Slot {
        if (handle.index >= self.slots.len or handle.generation == 0) return error.StaleGraphProgram;
        const slot = &self.slots[handle.index];
        if (slot.state.load(.acquire) == .free or slot.generation != handle.generation or slot.desc.progress.anchor.context != handle.context) return error.StaleGraphProgram;
        return slot;
    }
    pub fn stopCredits(self: *const Manager) usize {
        var count: usize = 0;
        for (&self.slots) |*slot| {
            const state = slot.state.load(.acquire);
            if (state != .free and state != .terminal and slot.stop_credit) count += 1;
        }
        return count;
    }
    pub fn usage(self: *const Manager) Usage {
        var count: usize = 0;
        for (&self.slots) |*slot| if (slot.state.load(.acquire) != .free) {
            count += 1;
        };
        return .{ .programs = count, .targets = self.retained_targets, .spans = self.retained_spans, .retained_metadata_bytes = self.retained_bytes, .last_prepare_peak_bytes = self.last_prepare_peak_bytes, .reserved_stop_credits = self.stopCredits() };
    }
    fn sameKeys(a: gc.Desc, b: gc.Desc) bool {
        if (!std.meta.eql(a.graph, b.graph) or !std.meta.eql(a.progress.anchor.group, b.progress.anchor.group) or a.progress.tracks[0].ordinal != b.progress.tracks[0].ordinal or a.targets.len != b.targets.len) return false;
        for (a.targets, b.targets) |x, y| if (!gc.sameTarget(x.target, y.target)) return false;
        return true;
    }
    pub fn conflicts(self: *const Manager, graph: gc.GraphIdentity, target: gc.bg.Target) bool {
        for (&self.slots) |*slot| {
            const state = slot.state.load(.acquire);
            if (state == .free or state == .terminal or !std.meta.eql(slot.desc.graph, graph)) continue;
            for (slot.desc.targets) |write| if (gc.sameTarget(write.target, target)) return true;
        }
        return false;
    }
    /// Alias/retarget validation is pure and must run before producer allocation.
    pub fn validateReservation(self: *Manager, graph: gc.GraphIdentity, group: gc.spans.GroupIdentity, ordinal: u16, targets: []const gc.Write, previous: ?gc.Handle) Error!void {
        if (previous) |handle| {
            const prior = try self.get(handle);
            const state = prior.state.load(.acquire);
            if (state == .prepared or !std.meta.eql(prior.desc.graph, graph) or !std.meta.eql(prior.desc.progress.anchor.group, group) or prior.desc.progress.tracks[0].ordinal != ordinal or prior.desc.targets.len != targets.len) return error.InvalidGraphProgram;
            for (prior.desc.targets, targets) |a, b| if (!gc.sameTarget(a.target, b.target)) return error.InvalidGraphProgram;
            if (prior.references == std.math.maxInt(u16)) return error.GraphProgramBudgetExceeded;
        }
        for (&self.slots, 0..) |*slot, i| {
            const state = slot.state.load(.acquire);
            if (state == .free or state == .terminal or !std.meta.eql(slot.desc.graph, graph)) continue;
            var overlaps = false;
            for (slot.desc.targets) |a| for (targets) |b| {
                if (gc.sameTarget(a.target, b.target)) {
                    overlaps = true;
                }
            };
            if (!overlaps) continue;
            const handle: gc.Handle = .{ .context = slot.desc.progress.anchor.context, .index = @intCast(i), .generation = slot.generation };
            if (previous == null or !previous.?.eql(handle) or state == .prepared or (slot.desc.previous != null and state != .active)) return error.GraphProgramBusy;
        }
    }
    /// The producer and this deep copy coexist during preparation. Charge both
    /// copies, fixed slots and bridge storage before allocating either copy.
    pub fn remainingProducerBytes(self: *const Manager, profile: gc.Profile) Error!usize {
        try profile.validate();
        if (self.retained_bytes >= profile.metadata_bytes) return error.GraphProgramBudgetExceeded;
        return (profile.metadata_bytes - self.retained_bytes) / 2;
    }
    pub fn prepare(self: *Manager, desc: gc.Desc) Error!gc.Handle {
        return self.prepareSourceBound(desc, .{});
    }
    pub fn prepareSourceBound(self: *Manager, desc: gc.Desc, source_binding: SourceBinding) Error!gc.Handle {
        try gc.validate(desc);
        try self.validateReservation(desc.graph, desc.progress.anchor.group, desc.progress.tracks[0].ordinal, desc.targets, desc.previous);
        var count: usize = 0;
        var available: ?usize = null;
        for (&self.slots, 0..) |*slot, i| if (slot.state.load(.acquire) == .free) {
            if (available == null) available = i;
        } else {
            count += 1;
        };
        const bytes = copiedBytes(desc);
        if (available == null or count >= desc.profile.programs or self.retained_spans + desc.progress.spans.len > desc.profile.spans or bytes > try self.remainingProducerBytes(desc.profile) or self.next_generation == std.math.maxInt(u64)) return error.GraphProgramBudgetExceeded;
        const tracks = try self.allocator.dupe(gc.spans.TrackDesc, desc.progress.tracks);
        errdefer self.allocator.free(tracks);
        const values = try self.allocator.dupe(gc.spans.Span, desc.progress.spans);
        errdefer self.allocator.free(values);
        const targets = try self.allocator.dupe(gc.Write, desc.targets);
        const slot = &self.slots[available.?];
        slot.generation = self.next_generation;
        self.next_generation += 1;
        slot.desc = desc;
        slot.desc.progress.tracks = tracks;
        slot.desc.progress.spans = values;
        slot.desc.targets = targets;
        slot.references = 0;
        slot.binding = null;
        slot.stop_credit = true;
        slot.stop_pending = false;
        slot.predecessor_retained = false;
        slot.bytes = bytes;
        self.last_prepare_peak_bytes = self.retained_bytes + 2 * bytes;
        self.retained_bytes += bytes;
        self.retained_spans += values.len;
        self.retained_targets += targets.len;
        if (desc.previous) |handle| {
            const prior = self.get(handle) catch unreachable;
            prior.references += 1;
            slot.predecessor_retained = true;
        }
        slot.source_binding = source_binding;
        slot.state.store(.prepared, .release);
        return .{ .context = desc.progress.anchor.context, .index = @intCast(available.?), .generation = slot.generation };
    }
    pub fn bindInstall(self: *Manager, handle: gc.Handle, binding: Binding) void {
        const slot = self.get(handle) catch unreachable;
        std.debug.assert(slot.state.load(.acquire) == .prepared);
        slot.binding = binding;
        slot.references += 1;
        slot.state.store(.bound, .release);
    }
    pub fn bindStop(self: *Manager, handle: gc.Handle) void {
        const slot = self.get(handle) catch unreachable;
        std.debug.assert(!slot.stop_pending);
        slot.stop_pending = true;
        slot.stop_credit = false;
        slot.references += 1;
    }
    /// Control after acquiring an execution/cancellation receipt.
    pub fn reconcileInstall(self: *Manager, handle: gc.Handle) void {
        const slot = self.get(handle) catch unreachable;
        if (!slot.predecessor_retained) return;
        const prior = self.get(slot.desc.previous.?) catch unreachable;
        std.debug.assert(prior.references > 0);
        prior.references -= 1;
        slot.predecessor_retained = false;
    }
    pub fn releaseCommand(self: *Manager, handle: gc.Handle, stop: bool) void {
        const slot = self.get(handle) catch unreachable;
        std.debug.assert(slot.references > 0);
        slot.references -= 1;
        if (stop) {
            slot.stop_pending = false;
            slot.stop_credit = slot.state.load(.acquire) != .terminal;
        }
    }
    pub fn rejectInstall(self: *Manager, handle: gc.Handle, frame: u64) void {
        const slot = self.get(handle) catch unreachable;
        if (slot.state.load(.acquire) != .bound) return;
        // No live value was sampled. A rejected result intentionally has zero
        // values; it does not label the Control target/prediction as emitted PCM.
        slot.progress = .{};
        slot.progress.terminal = .{ .reason = .install_rejected, .frame = frame, .release_frontier = frame, .elapsed_source_frames = 0, .count = 0 };
        slot.state.store(.terminal, .release);
    }
    pub fn canReleaseInstall(self: *Manager, handle: gc.Handle, frontier: u64) Error!void {
        const slot = try self.get(handle);
        if (slot.state.load(.acquire) != .terminal or slot.progress.terminal.?.release_frontier > frontier) return error.DrainPending;
    }
    /// Caller must detach every Render bridge pointer before publishing terminal.
    pub fn publishTerminal(self: *Manager, handle: gc.Handle) void {
        const slot = self.get(handle) catch unreachable;
        std.debug.assert(slot.progress.terminal != null);
        slot.state.store(.terminal, .release);
    }
    pub fn observe(self: *Manager, handle: gc.Handle, frontier: u64) Error!?gc.Result {
        const slot = try self.get(handle);
        if (slot.state.load(.acquire) != .terminal or slot.progress.terminal.?.release_frontier > frontier) return null;
        return slot.progress.terminal;
    }
    pub const Released = struct { graph: gc.GraphIdentity, group: gc.spans.GroupIdentity };
    pub fn release(self: *Manager, handle: gc.Handle, frontier: u64) Error!Released {
        const slot = try self.get(handle);
        const state = slot.state.load(.acquire);
        if (slot.references != 0 or (state != .prepared and state != .terminal) or (state == .terminal and slot.progress.terminal.?.release_frontier > frontier)) return error.DrainPending;
        self.reconcileInstall(handle);
        const desc = slot.desc;
        self.retained_bytes -= slot.bytes;
        self.retained_spans -= desc.progress.spans.len;
        self.retained_targets -= desc.targets.len;
        self.allocator.free(desc.progress.tracks);
        self.allocator.free(desc.progress.spans);
        self.allocator.free(desc.targets);
        slot.state.store(.free, .release);
        return .{ .graph = desc.graph, .group = desc.progress.anchor.group };
    }
    pub fn hasRenderObligations(self: *const Manager) bool {
        for (&self.slots) |*slot| {
            const state = slot.state.load(.acquire);
            if (state == .bound or state == .active) return true;
        }
        return false;
    }
    pub fn deinit(self: *Manager) Error!void {
        for (&self.slots) |*slot| if (slot.state.load(.acquire) != .free) return error.DrainPending;
        self.allocator.destroy(self);
    }
};
