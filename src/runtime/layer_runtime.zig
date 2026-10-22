//! Control-owned immutable program pool and Render-owned cursor/result bridge.
//! This module never imports Runtime. Cross-owner completion is a release/acquire
//! publication; no plain cursor/result field is read by Control before terminal.
const std = @import("std");
pub const spans = @import("sme-layer-spans");
pub const Error = spans.Error || std.mem.Allocator.Error || error{DrainPending};
pub const State = enum(u8) { free, prepared, bound, active, terminal };
pub const Binding = struct {
    plan_id: u64,
    plan_epoch: u64,
    command_id: u64,
    phase_id: u64,
    phase_order: u32,
    /// Pinned by the installation scheduler block until automation terminal.
    admitted_epoch: *const std.atomic.Value(u64),
};
pub const Result = struct {
    program: spans.ProgramHandle,
    content_hash: [32]u8,
    tracks: [spans.max_tracks]spans.Terminal = undefined,
    track_count: u16,
    release_frontier: u64,
};
pub const Slot = struct {
    state: std.atomic.Value(State) = .init(.free),
    generation: u64 = 0,
    desc: spans.ProgramDesc = undefined,
    binding: ?Binding = null,
    references: u16 = 0, // Control only; installation and stop schedules.
    stop_credit: bool = false, // Control only; backed by runtime admission.
    stop_pending: bool = false,
    predecessor_retained: bool = false, // Control-only successor reservation.
    effective_transport_epoch: u64 = 0, // Render only after install.
    effective_mutation_epoch: u64 = 0,
    cursors: [spans.max_tracks]spans.RenderCursor = undefined, // Render owner.
    result: Result = undefined, // Written once by Render or rejected Control.
    bytes: usize = 0,
    profile_hash: [32]u8 = @splat(0),
};
pub const Manager = struct {
    allocator: std.mem.Allocator,
    slots: [spans.max_programs]Slot = @splat(.{}),
    next_generation: u64 = 1,
    retained_tracks: usize = 0,
    retained_spans: usize = 0,
    retained_bytes: usize = @sizeOf(Manager),
    pub fn create(allocator: std.mem.Allocator, external_bridge_bytes: usize) Error!*Manager {
        if (external_bridge_bytes > spans.max_metadata_bytes - @sizeOf(Manager)) return error.LayerProgramBudgetExceeded;
        const self = try allocator.create(Manager);
        self.* = .{ .allocator = allocator, .retained_bytes = @sizeOf(Manager) + external_bridge_bytes };
        return self;
    }
    pub fn get(self: *Manager, handle: spans.ProgramHandle) Error!*Slot {
        if (handle.index >= self.slots.len or handle.generation == 0) return error.StaleLayerProgram;
        const slot = &self.slots[handle.index];
        if (slot.state.load(.acquire) == .free or slot.generation != handle.generation or slot.desc.anchor.context != handle.context) return error.StaleLayerProgram;
        return slot;
    }
    pub fn stopCredits(self: *const Manager) usize {
        var count: usize = 0;
        for (&self.slots) |*slot| if (slot.stop_credit and slot.state.load(.acquire) != .terminal and slot.state.load(.acquire) != .free) {
            count += 1;
        };
        return count;
    }
    pub fn prepare(self: *Manager, desc: spans.ProgramDesc) Error!spans.ProgramHandle {
        try spans.validate(desc);
        var count: usize = 0;
        var available: ?usize = null;
        for (&self.slots, 0..) |*slot, i| {
            const state = slot.state.load(.acquire);
            if (state == .free) {
                if (available == null) available = i;
                continue;
            }
            count += 1;
            if (state == .terminal or !std.meta.eql(slot.desc.anchor.group, desc.anchor.group) or slot.desc.target_mask & desc.target_mask == 0) continue;
            const prior: spans.ProgramHandle = .{ .context = slot.desc.anchor.context, .index = @intCast(i), .generation = slot.generation };
            if (desc.anchor.expected_previous == null or !prior.eql(desc.anchor.expected_previous.?) or slot.desc.target_mask != desc.target_mask or state == .prepared) return error.LayerProgramBusy;
            // At most one pending successor reserves any physical target key.
            if (slot.desc.anchor.expected_previous != null and state != .active) return error.LayerProgramBusy;
        }
        if (desc.anchor.expected_previous) |previous| {
            const prior = try self.get(previous);
            if (!std.meta.eql(prior.desc.anchor.group, desc.anchor.group) or prior.desc.target_mask != desc.target_mask) return error.InvalidLayerProgram;
            if (prior.references == std.math.maxInt(u16)) return error.LayerProgramBudgetExceeded;
        }
        const bytes = desc.tracks.len * @sizeOf(spans.TrackDesc) + desc.spans.len * @sizeOf(spans.Span);
        if (count >= desc.profile.programs or available == null or self.retained_tracks + desc.tracks.len > desc.profile.tracks or self.retained_spans + desc.spans.len > desc.profile.spans or self.retained_bytes + bytes > desc.profile.metadata_bytes or self.next_generation == std.math.maxInt(u64)) return error.LayerProgramBudgetExceeded;
        const tracks = try self.allocator.dupe(spans.TrackDesc, desc.tracks);
        errdefer self.allocator.free(tracks);
        const values = try self.allocator.dupe(spans.Span, desc.spans);
        const index = available.?;
        const slot = &self.slots[index];
        slot.generation = self.next_generation;
        slot.desc = desc;
        slot.bytes = bytes;
        slot.stop_credit = true;
        slot.stop_pending = false;
        slot.predecessor_retained = false;
        slot.references = 0;
        slot.binding = null;
        slot.profile_hash = spans.profileHash(desc.profile);
        slot.desc.tracks = tracks;
        slot.desc.spans = values;
        self.next_generation += 1;
        self.retained_tracks += tracks.len;
        self.retained_spans += values.len;
        self.retained_bytes += bytes;
        if (desc.anchor.expected_previous) |previous| {
            const prior = self.get(previous) catch unreachable;
            prior.references += 1;
            slot.predecessor_retained = true;
        }
        slot.state.store(.prepared, .release);
        return .{ .context = desc.anchor.context, .index = @intCast(index), .generation = slot.generation };
    }
    pub fn bindInstall(self: *Manager, handle: spans.ProgramHandle, binding: Binding) void {
        const slot = self.get(handle) catch unreachable;
        std.debug.assert(slot.state.load(.acquire) == .prepared);
        slot.binding = binding;
        slot.references += 1;
        slot.state.store(.bound, .release);
    }
    pub fn bindStop(self: *Manager, handle: spans.ProgramHandle) void {
        const slot = self.get(handle) catch unreachable;
        std.debug.assert(!slot.stop_pending);
        slot.stop_pending = true;
        slot.stop_credit = false;
        slot.references += 1;
    }
    /// Control only, after acquiring the installation execution/cancellation
    /// receipt. A future successor cannot outlive its exact predecessor lease.
    pub fn reconcileInstall(self: *Manager, handle: spans.ProgramHandle) void {
        const slot = self.get(handle) catch unreachable;
        if (!slot.predecessor_retained) return;
        const prior = self.get(slot.desc.anchor.expected_previous.?) catch unreachable;
        std.debug.assert(prior.references > 0);
        prior.references -= 1;
        slot.predecessor_retained = false;
    }
    pub fn releaseCommand(self: *Manager, handle: spans.ProgramHandle, stop: bool) void {
        const slot = self.get(handle) catch unreachable;
        std.debug.assert(slot.references > 0);
        slot.references -= 1;
        if (stop) {
            slot.stop_pending = false;
            slot.stop_credit = slot.state.load(.acquire) != .terminal;
        }
    }
    pub fn rejectInstall(self: *Manager, handle: spans.ProgramHandle, frame: u64) void {
        const slot = self.get(handle) catch unreachable;
        if (slot.state.load(.acquire) != .bound) return;
        var result: Result = .{ .program = handle, .content_hash = slot.desc.content_hash, .track_count = @intCast(slot.desc.tracks.len), .release_frontier = frame };
        for (slot.desc.tracks, 0..) |track, i| result.tracks[i] = .{ .reason = .install_rejected, .frame = frame, .release_frontier = frame, .elapsed_source_frames = 0, .gain_bits = @bitCast(track.initial_prediction), .audible = false };
        slot.result = result;
        slot.state.store(.terminal, .release);
    }
    /// Render only. Called after whole-phase preflight and before group attach.
    pub fn install(self: *Manager, handle: spans.ProgramHandle) *Slot {
        const slot = self.get(handle) catch unreachable;
        for (slot.desc.tracks, 0..) |*track, i| slot.cursors[i] = .{ .program = handle, .binding_revision = slot.desc.anchor.binding_revision, .track = track, .spans = slot.desc.spans[track.spans.first..][0..track.spans.count] };
        slot.effective_transport_epoch = slot.desc.anchor.transport_epoch;
        slot.effective_mutation_epoch = slot.desc.anchor.mutation_epoch;
        slot.state.store(.active, .release);
        return slot;
    }
    /// Render only. Group has already detached every completed cursor. The
    /// terminal store is the final access to slot in this call.
    pub fn publishTerminal(self: *Manager, index: usize) void {
        const slot = &self.slots[index];
        if (slot.state.load(.acquire) != .active) return;
        for (slot.cursors[0..slot.desc.tracks.len]) |cursor| if (cursor.terminal == null) return;
        var result: Result = .{ .program = .{ .context = slot.desc.anchor.context, .index = @intCast(index), .generation = slot.generation }, .content_hash = slot.desc.content_hash, .track_count = @intCast(slot.desc.tracks.len), .release_frontier = 0 };
        for (slot.cursors[0..slot.desc.tracks.len], 0..) |cursor, i| {
            result.tracks[i] = cursor.terminal.?;
            result.release_frontier = @max(result.release_frontier, cursor.terminal.?.release_frontier);
        }
        slot.result = result;
        slot.state.store(.terminal, .release);
    }
    pub fn observe(self: *Manager, handle: spans.ProgramHandle, completed_frontier: u64) Error!?Result {
        const slot = try self.get(handle);
        if (slot.state.load(.acquire) != .terminal or slot.result.release_frontier > completed_frontier) return null;
        return slot.result;
    }
    pub fn canReleaseInstall(self: *Manager, handle: spans.ProgramHandle, frontier: u64) Error!void {
        if (try self.observe(handle, frontier) == null) return error.DrainPending;
    }
    pub fn release(self: *Manager, handle: spans.ProgramHandle, frontier: u64) Error!spans.GroupIdentity {
        const slot = try self.get(handle);
        const state = slot.state.load(.acquire);
        if (slot.references != 0 or (state != .prepared and (state != .terminal or slot.result.release_frontier > frontier))) return error.DrainPending;
        const group = slot.desc.anchor.group;
        self.reconcileInstall(handle);
        self.retained_tracks -= slot.desc.tracks.len;
        self.retained_spans -= slot.desc.spans.len;
        self.retained_bytes -= slot.bytes;
        self.allocator.free(slot.desc.tracks);
        self.allocator.free(slot.desc.spans);
        slot.state.store(.free, .release);
        return group;
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
