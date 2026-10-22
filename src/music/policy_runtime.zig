//! TASK015 Control preparation helpers for the single production owner.
//! These call real TickV1 group/bus preparation. They neither accept requests nor
//! allocate plan/request identities, publish work, consume receipts or free leases
//! before the owner observes actual scheduler/group/batch retirement.
const std = @import("std");
const audio = @import("bugu_audio");
const rt = audio.runtime;
const music = audio.music;
const bank = @import("sme-bank");
const adapter = bank.music_policy_adapter;
const clock = @import("sme-clock");
const policy = @import("sme-stinger-policy");
pub const stinger_admission = policy;
const trace = @import("sme-trace").schema;
const br = rt.bus_runtime;
pub const Context = struct {
    tick: rt.ControlRuntime.TickV1,
    ticket: music.MusicRequestTicketV1,
    accepted: trace.Position,
    command: rt.scheduler.CommandIdentity,
    /// Borrowed from the same generation owner, not a helper-owned clock.
    transport: *const clock.Clock,
    loaded: *const bank.MusicBank,
    policies: *const adapter.Owned,
    /// Explicit runtime binding; metadata and copied adapter remain authored.
    /// The live owner must authenticate this identity and these exact pointers.
    runtime_generation: u64,
    pub fn validate(self: Context) !void {
        try self.tick.requirePhase(.prepare);
        try self.command.token.validate();
        const token = self.command.token;
        if (self.ticket.request_id == 0 or self.ticket.context == 0 or self.ticket.context != self.ticket.bank.context or !self.ticket.bank.handle.isValid()) return error.InvalidIdentity;
        if (self.command.command_id == 0 or self.command.group_id == 0 or self.command.execute_frame < self.accepted.accepted_control_frame) return error.InvalidIdentity;
        if (token.context.value() != self.ticket.context or token.asset_generation.value() != self.ticket.bank.asset_generation or self.runtime_generation == 0 or self.ticket.bank.asset_generation != self.runtime_generation or self.policies.generation != self.loaded.metadata.generation) return error.StaleIdentity;
        const owner = self.tick.runtime.music_runtime orelse return error.InvalidState;
        const retained = try owner.retainedPolicyGeneration(self.tick.runtime, self.ticket);
        const generation = retained orelse owner.generation orelse return error.StaleIdentity;
        if (self.loaded != &generation.loaded or self.transport != &generation.transport or generation.policies == null or
            self.policies != &generation.policies.? or self.runtime_generation != generation.runtime_generation or
            self.ticket.bank.context != owner.config.context or self.ticket.bank.handle.index != 0 or
            (retained == null and self.ticket.bank.handle.generation != owner.handle_incarnation)) return error.StaleIdentity;
        if (token.transport_epoch.value() != self.transport.transport_epoch or self.transport.device_epoch == 0) return error.StaleIdentity;
        if (self.policies.sample_rate != bank.schema.sample_rate) return error.InvalidSampleRate;
        if (!bank.schema.policyEnabled(self.loaded.metadata)) return error.UnsupportedCapability;
    }
    pub fn identity(self: Context) policy.Identity {
        return .{ .context = self.ticket.context, .asset_generation = self.ticket.bank.asset_generation, .transport_epoch = self.transport.transport_epoch, .device_epoch = self.transport.device_epoch };
    }
};
/// Association established by the generation owner's actual graph preparation.
/// The helper checks bank identity; the real manager checks the handle and lanes.
pub const GraphBinding = struct {
    handle: br.Handle,
    /// Runtime custody epoch, distinct from immutable authored resource identity.
    generation: u64,
    authored_generation: u64,
    build_id: u64,
    bank_content_hash: [32]u8,
};
fn validateGraph(context: Context, graph: GraphBinding) !void {
    if (graph.generation != context.runtime_generation or graph.authored_generation != context.loaded.metadata.generation or graph.build_id != (std.mem.readInt(u64, context.loaded.content_hash[0..8], .little) | 1) or !std.mem.eql(u8, &graph.bank_content_hash, &context.loaded.content_hash)) return error.StaleIdentity;
}
pub const Prepared = struct { command: rt.ScheduledCommand, resource: union(enum) { group: rt.GroupHandle, batch: br.BatchHandle, duck: br.duck_lifetime.Handle } };
pub const DuckLease = struct {
    tracked: ?br.Manager.DuckLease = null,
    bank_ref: ?music.MusicBankRefV1 = null,
    identity: policy.Identity,
    external_id: u64,
    render_id: u32,
    bus: u32,
    attack_frames: u32,
    hold_frames: u32,
    release_frames: u32,
    graph: GraphBinding,
};
pub const PreparedDuck = struct { prepared: Prepared, lease: DuckLease };
/// The single owner allocates render_id from its bounded generation-safe ledger.
/// It must not reuse an ID until any begin, end, cancellation and release drain.
pub fn prepareDuckBegin(context: Context, graph: GraphBinding, preset_id: u64, external_id: u64, render_id: u32) !PreparedDuck {
    try context.validate();
    try validateGraph(context, graph);
    if (preset_id == 0 or external_id == 0 or render_id == 0) return error.InvalidIdentity;
    for (context.policies.ducks) |preset| {
        if (preset.key.id != preset_id) continue;
        const target = try adapter.duckTarget(preset, render_id);
        const identity: br.duck_lifetime.Identity = .{ .request_id = context.ticket.request_id, .accepted = .{ .accepted_control_frame = context.accepted.accepted_control_frame, .control_tick = context.accepted.control_tick, .input_order = context.accepted.input_order }, .context = context.ticket.context, .bank_context = context.ticket.bank.context, .bank_index = context.ticket.bank.handle.index, .bank_handle_generation = context.ticket.bank.handle.generation, .asset_generation = context.ticket.bank.asset_generation, .transport_epoch = context.transport.transport_epoch, .device_epoch = context.transport.device_epoch, .external_id = external_id, .graph = .{ .context = graph.handle.context, .index = graph.handle.index, .generation = graph.handle.generation }, .bus = preset.bus, .dsp_id = render_id };
        const tracked = try context.tick.prepareTrackedDuck(graph.handle, identity, target);
        return .{ .prepared = .{ .command = .{ .identity = context.command, .payload = .{ .graph_targets = .{ .batch = tracked.begin_batch } } }, .resource = .{ .duck = tracked.handle } }, .lease = .{ .tracked = tracked, .bank_ref = context.ticket.bank, .identity = context.identity(), .external_id = external_id, .render_id = render_id, .bus = preset.bus, .attack_frames = target.attack_frames, .hold_frames = target.hold_frames, .release_frames = target.release_frames, .graph = graph } };
    }
    return error.UnknownDuckPreset;
}
/// Duplicate-end rejection and the begin-executed decision belong to the real
/// request slot. This helper cannot turn a cancelled begin into a live duck.
pub fn prepareDuckEnd(context: Context, lease: DuckLease) !Prepared {
    try context.validate();
    try validateGraph(context, lease.graph);
    const current = context.identity();
    if (current.context != lease.identity.context or current.asset_generation != lease.identity.asset_generation or
        current.device_epoch != lease.identity.device_epoch or lease.external_id == 0 or lease.render_id == 0) return error.StaleIdentity;
    const tracked = lease.tracked orelse return error.InvalidIdentity;
    if (lease.bank_ref == null or !std.meta.eql(lease.bank_ref.?, context.ticket.bank)) return error.StaleIdentity;
    const manager = context.tick.runtime.bus_manager orelse return error.StaleDuck;
    const slot = try manager.ducks.get(tracked.handle);
    const original = slot.cell.identity;
    const begin = slot.begin_batch orelse return error.InvalidIdentity;
    if (original.context != lease.identity.context or original.asset_generation != lease.identity.asset_generation or
        original.transport_epoch != lease.identity.transport_epoch or original.device_epoch != lease.identity.device_epoch or
        original.bank_context != context.ticket.bank.context or original.bank_index != context.ticket.bank.handle.index or
        original.bank_handle_generation != context.ticket.bank.handle.generation or original.external_id != lease.external_id or
        original.dsp_id != lease.render_id or original.bus != lease.bus or original.graph.context != lease.graph.handle.context or
        original.graph.index != lease.graph.handle.index or original.graph.generation != lease.graph.handle.generation or
        begin.context != tracked.begin_batch.context or begin.index != tracked.begin_batch.index or begin.generation != tracked.begin_batch.generation) return error.StaleIdentity;
    const owner = context.tick.runtime.music_runtime orelse return error.InvalidState;
    const generation = owner.generation orelse return error.StaleIdentity;
    if (context.loaded != &generation.loaded or context.transport != &generation.transport) return error.StaleIdentity;
    const authorization: rt.DuckCleanupAuthorization = .{ .handle = tracked.handle, .transport_epoch = current.transport_epoch, .device_epoch = current.device_epoch, .accepted = context.accepted };
    try authorization.validate(context.tick, tracked.end_batch, context.command);
    // Only the retained incarnation's immutable cleanup batch is used. No raw
    // external ID can address a later DSP lifetime through this helper. Ordinary
    // same-epoch command bytes remain unchanged.
    return .{ .command = .{ .identity = context.command, .payload = .{ .graph_targets = .{ .batch = tracked.end_batch, .duck_cleanup = if (current.transport_epoch != lease.identity.transport_epoch) authorization else null } } }, .resource = .{ .duck = tracked.handle } };
}
pub fn findStinger(context: Context, id: u64) !adapter.Stinger {
    try context.validate();
    for (context.policies.stingers) |entry| if (entry.id == id) return entry;
    return error.UnknownStinger;
}
/// Real immutable transport and scheduler frontier queries. No quantum clock,
/// invented beat or main-transport mutation is used for the candidate boundary.
pub fn stingerBoundary(context: Context, entry: adapter.Stinger) !policy.BoundaryCandidate {
    try context.validate();
    const owned_entry = try findStinger(context, entry.id);
    if (!std.meta.eql(owned_entry, entry)) return error.InvalidIdentity;
    const frontier = try context.tick.runtime.earliestPlanFrame();
    const frame = switch (entry.policy.sync) {
        .immediate => @max(context.accepted.accepted_control_frame, frontier),
        .next_beat => (try context.transport.strictNext(.beat, context.accepted.accepted_control_frame, .{ .earliest_submit_frame = frontier })).frame,
        .next_bar => (try context.transport.strictNext(.bar, context.accepted.accepted_control_frame, .{ .earliest_submit_frame = frontier })).frame,
    };
    return .{ .sync = entry.policy.sync, .frame = frame };
}
/// The assets owner supplies genuine resident/stream layer sources at this cue.
/// All stinger layers are required real voices with actual stinger protection;
/// the existing group admission enforces its voice/group/stinger/storage limits.
/// This is preparation only. Policy decision and publish belong to the owner.
pub fn prepareStinger(context: Context, stinger_id: u64, desc: rt.MusicGroupDesc, output: rt.channel_layout.ChannelLayout) !Prepared {
    const entry = try findStinger(context, stinger_id);
    if (entry.segment >= context.loaded.tables.segments.len or entry.cue >= context.loaded.tables.cues.len) return error.InvalidReference;
    const segment = context.loaded.tables.segments[entry.segment];
    const cue = context.loaded.tables.cues[entry.cue];
    if (desc.segment != segment.key.id or desc.generation != context.runtime_generation or desc.start_cursor != cue.frame or desc.start_loop_epoch != 0 or desc.loop != null or desc.emergency != null or cue.kind != .stinger or cue.segment != entry.segment) return error.InvalidState;
    if (desc.layers.len == 0 or desc.layers.len > rt.music_group.max_layers) return error.InvalidArgument;
    var layers: [rt.music_group.max_layers]rt.MusicGroupLayer = undefined;
    for (desc.layers, 0..) |layer, index| {
        if (layer.generation != context.runtime_generation or layer.initial_state != .real) return error.InvalidState;
        layers[index] = layer;
        layers[index].required = true;
        layers[index].authored.protection = .stinger;
        layers[index].authored.priority = entry.policy.priority;
    }
    var prepared_desc = desc;
    prepared_desc.layers = layers[0..desc.layers.len];
    const group = try context.tick.prepareMusicGroup(prepared_desc, output, context.policies.sample_rate);
    return .{ .command = .{ .identity = context.command, .payload = .{ .group_start = .{ .group = group } } }, .resource = .{ .group = group } };
}
/// The real APIs reject retained resources. No local receipt bit can override
/// schedule publication pins or pending renderer/snapshot references.
pub fn release(tick: rt.ControlRuntime.TickV1, prepared: Prepared) !void {
    switch (prepared.resource) {
        .group => |group| try tick.releaseMusicGroup(group),
        .batch => |batch| try tick.releaseBusTargetBatch(batch),
        .duck => |handle| try tick.releaseTrackedDuck(handle),
    }
}
