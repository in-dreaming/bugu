//! Generation storage extracted from the same public MusicRuntime owner.
//! Worker preparation and Control activation remain separate transactions.
const std = @import("std");
const rt = @import("bugu_audio").runtime;
const bank = @import("sme-bank");
const planner = @import("sme-planner");
const director = @import("sme-director");
const clock = @import("sme-clock");
const s = bank.schema;
const streaming = @import("sme-streaming");
const opus = @import("sme-opus");
const generation_registry = @import("sme-generation-admission").registry;
pub const GenerationRegistry = generation_registry.Registry(Generation);
const v1 = @import("runtime_contract.zig");
const save = @import("save_state.zig");
pub const runtime_layers = @import("runtime_layers.zig");
pub const crossfade_contract = @import("sme-runtime-crossfade-contract");

pub const source_provider = @import("source_provider.zig");
pub const SourceProvider = source_provider.V1;
pub const SourceProviderV2 = source_provider.V2;
pub const AnySourceProvider = source_provider.Any;
/// Internal qualification primitive only; no shipping attachment API or state.
pub const TestLiveBootstrap = if (@import("builtin").is_test) @import("live_bootstrap_test_binding.zig") else struct {};
const SourceSession = union(enum) { v1: SourceProvider, v2: *const source_provider.BoundV2 };
const SourceRecord = struct {
    provider: ?SourceSession = null,
    sound_index: u32,
    opened: ?SourceProvider.Opened = null,
    asset: ?streaming.Asset = null,
    fn bytes(self: *SourceRecord) opus.ByteSource {
        return .{ .context = self, .length = self.opened.?.encoded_bytes, .read_at = read };
    }
    fn read(raw: *anyopaque, offset: u64, destination: []u8) opus.Error!void {
        const self: *SourceRecord = @ptrCast(@alignCast(raw));
        const opened = self.opened orelse return error.TruncatedContainer;
        if (offset > opened.encoded_bytes or destination.len > opened.encoded_bytes - offset) return error.TruncatedContainer;
        switch (self.provider.?) {
            .v1 => |provider| provider.read_at(provider.context, opened.token, offset, destination) catch return error.TruncatedContainer,
            .v2 => |binding| binding.provider.read_at(binding.provider.context, binding.token, opened.token, offset, destination) catch return error.TruncatedContainer,
        }
    }
};
/// Recovery ownership is disjoint from every public ingress request ticket.
pub const WindowScope = enum(u8) { request, device_recovery };
/// A numeric ID is unique only within its scope and owning Generation.
pub const WindowKey = struct { scope: WindowScope, request_id: u64 };
/// Control-owned stream slots use the existing Service/Planner release profile.
/// Windows retain physical custody until Service.close proves all owners gone;
/// supply admission can end earlier when the exact source is physically stopped.
const Window = struct {
    request_id: u64,
    scope: WindowScope = .request,
    binding: planner.StreamBinding,
    group: ?rt.GroupHandle = null,
    retiring: bool = false,

    fn ownedBy(self: Window, scope: WindowScope, request_id: u64) bool {
        return self.scope == scope and self.request_id == request_id;
    }
};
pub const StingerHistory = struct { last: ?struct { request_id: u64, accepted_frame: u64 } = null };
/// One candidate entry coordinate. Repetition is local to equal segment/cue
/// entries in a plan, never the absolute route position saved in fill_occurrence.
/// Distinct keys own independent consuming Service rings even for the same asset.
pub const EntryWindow = struct {
    segment: u64,
    cue: u64,
    occurrence: u16 = 0,

    fn matches(self: EntryWindow, binding: planner.StreamBinding) bool {
        return self.segment == binding.segment and self.cue == binding.cue and self.occurrence == binding.occurrence;
    }
};
/// Physical restore preparation is separate from the remaining authored entry
/// list. A finite remaining fill span uses the same PCM policy as a fresh fill;
/// null preserves the direct stream's existing minimum-playable window.
pub const RestorePhysical = struct {
    segment_index: u32,
    cursor: u64,
    loop_epoch: u64,
    remaining: ?u64 = null,
};
/// Saved Entry.occurrence is an absolute route position. Only equal entries in
/// this fresh suffix contribute to the independent consuming window key.
pub fn restoreEntryWindow(entries: []const save.Entry, index: usize) EntryWindow {
    std.debug.assert(entries.len <= 3 and index < entries.len);
    const entry = entries[index];
    var occurrence: u16 = 0;
    for (entries[0..index]) |prior| if (prior.segment == entry.segment and prior.cue == entry.cue) {
        occurrence += 1;
    };
    return .{ .segment = entry.segment, .cue = entry.cue, .occurrence = occurrence };
}
/// Bounded hard-cut profile; rolling supply is an explicit admission mode.
pub const max_resident_fill_steps: usize = v1.resident_fill_hard_cut_v1.max_fill_steps;
pub const Config = struct { context: u64 = 1, seed: u64 = 1, quantum_frames: u32 = 256 };

/// Serialized-Control owner of the one context Service. Its storage is charged
/// once by MusicRuntime. Each bound Generation acquires before its Service
/// pointer becomes visible and releases only after windows/provider retirement.
/// These credits protect storage; actual Service slot/job/ring leases still
/// govern close/destroy and are never replaced by this count.
pub const ServiceCustody = struct {
    service: *streaming.Service,
    generation_leases: u32 = 0,
    accepting: bool = true,
    pub fn acquire(self: *ServiceCustody) !void {
        if (!self.accepting) return error.AcquisitionClosed;
        self.generation_leases = try std.math.add(u32, self.generation_leases, 1);
    }
    pub fn release(self: *ServiceCustody) void {
        std.debug.assert(self.generation_leases != 0);
        self.generation_leases -= 1;
    }
    /// Non-mutating late-boundary check; does not grant Host quiescence.
    pub fn validateDestroyQuiescent(self: *ServiceCustody) !void {
        if (self.generation_leases != 0) return error.DrainPending;
        try self.service.validateDestroyQuiescent();
    }
    pub fn destroy(self: *ServiceCustody) !void {
        self.accepting = false;
        if (self.generation_leases != 0) return error.DrainPending;
        try self.service.destroy();
    }
};

// One generation owns both immutable assets and the one Control-side musical
// state. Worker preparation never attaches it or publishes Ready.
pub const PolicyGenerationLease = struct { payload: *Generation, registry: generation_registry.Handle, runtime_generation: u64, authored_generation: u64, bank_content_hash: [32]u8 };

pub const Generation = struct {
    const Retirement = enum(u8) { active, requested, closing, acknowledged };
    allocator: std.mem.Allocator,
    loaded: bank.MusicBank,
    /// Opt-in exact input image for streamed reload history. Empty on ordinary
    /// load; ownership is transferred only after full-image authentication.
    retained_compiled: []u8 = &.{},
    // Runtime custody identity is assigned separately from immutable authored
    // metadata/content hash, before provider open or any window/job publication.
    runtime_generation: u64 = 0,
    /// Immutable preparation choice, retained across shared-Service adoption.
    fill_pcm_mode: planner.FillPcmMode = .full_span,
    // Identity published by Control before source work; binding custody acquired
    // and returned on Worker. Both remain owned through acknowledged retirement.
    source_identity: ?source_provider.IdentityV2 = null,
    source_binding: ?source_provider.BoundV2 = null,
    owners: []rt.SampleOwner,
    policies: ?bank.music_policy_adapter.Owned = null,
    layer_owner: ?*runtime_layers.Owner = null,
    stinger_history: []StingerHistory = &.{},
    // One owned preparation service, transferred to the context at adoption.
    // Once attached it survives music-only unload while unrelated SFX renders.
    service: ?*streaming.Service = null,
    owns_service: bool = true,
    test_live_bootstrap: if (@import("builtin").is_test) ?*TestLiveBootstrap.Session else void = if (@import("builtin").is_test) null else {},
    service_custody: ?*ServiceCustody = null,
    sources: []SourceRecord = &.{},
    windows: [planner.max_bindings]?Window = @splat(null),
    readiness: ?*planner.ReadinessSnapshot = null,
    binding_scratch: [planner.max_bindings]planner.StreamBinding = undefined,
    preparation_failure: ?anyerror = null,
    retirement: std.atomic.Value(Retirement) = .init(.active),
    close_failed: std.atomic.Value(bool) = .init(false),
    close_cursor: usize = 0,
    closed_sources: std.atomic.Value(usize) = .init(0),
    director: ?*director.Director = null,
    // Heap-only transactional proposal. One Director remains authoritative;
    // this scratch copy is committed only after real gain schedule admission.
    layer_director_scratch: ?*director.Director = null,
    solver: ?*planner.Planner = null,
    scratch_plan: ?*planner.TransitionPlan = null,
    transport: clock.Clock = undefined,

    // Serialized Control-owned leases. These do not pretend to cover voices,
    // streams, snapshots or rollback history; those owners remain separate.
    preparation_leases: u32 = 0,
    pending_plan_leases: u32 = 0,
    // Original policy ownership, including deferred requests without a group.
    policy_leases: u32 = 0,
    // One canonical Control credit per actual prepared controller instance.
    layer_controller_leases: u32 = 0,

    registry: ?*GenerationRegistry = null,
    registry_handle: ?generation_registry.Handle = null,
    play_custody: ?*rt.PlayCustodyAnchor = null,
    play_custody_bound: bool = false,
    play_custody_funded: bool = false,
    play_custody_control_thread: std.Thread.Id = undefined,

    pub fn allocatePlayCustody(self: *Generation) !void {
        if (self.play_custody != null) return;
        self.play_custody = try self.allocator.create(rt.PlayCustodyAnchor);
    }
    /// Fresh registry adoption and runtime identity precede immutable owner
    /// binding. Allocation already succeeded before the adoption boundary.
    pub fn bindPlayCustody(self: *Generation, context: u64) void {
        const anchor = self.play_custody orelse return;
        std.debug.assert(!self.play_custody_bound and self.registry != null);
        const handle = self.registry_handle.?;
        anchor.* = rt.PlayCustodyAnchor.init(.{ .context = context, .authored_generation = self.loaded.metadata.generation, .runtime_generation = self.runtime_generation, .registry_index = handle.index, .registry_incarnation = handle.incarnation }) catch unreachable;
        self.registry.?.reservePlayEnvelopes(handle, rt.play_custody.capacity) catch unreachable;
        self.play_custody_control_thread = std.Thread.getCurrentId();
        self.play_custody_bound = true;
        self.play_custody_funded = true;
        for (self.owners) |*owner| if (!owner.stream_token) {
            std.debug.assert(owner.play_custody == null);
            owner.play_custody = anchor;
        };
    }
    pub fn collectPlayCustody(self: *Generation) void {
        if (!self.play_custody_bound) return;
        std.debug.assert(std.Thread.getCurrentId() == self.play_custody_control_thread);
        const anchor = self.play_custody.?;
        _ = anchor.collect();
        if (self.play_custody_funded and anchor.drained()) {
            self.registry.?.releasePlayEnvelopes(self.registry_handle.?, rt.play_custody.capacity) catch unreachable;
            self.play_custody_funded = false;
        }
        if (self.registry) |registry| std.debug.assert((registry.get(self.registry_handle.?) catch unreachable).play_envelopes == @as(u64, if (self.play_custody_funded) rt.play_custody.capacity else 0));
    }
    pub fn closePlayCustody(self: *Generation) void {
        if (!self.play_custody_bound) return;
        std.debug.assert(std.Thread.getCurrentId() == self.play_custody_control_thread);
        self.play_custody.?.close();
        self.collectPlayCustody();
    }

    // Registry credits are acquired before a slot/Pending becomes visible. The
    // local counters classify those SAME credits; they are never added again to
    // retention totals. Every transfer asserts this conservation invariant.
    pub fn assertControlCredits(self: *Generation) void {
        if (self.registry) |registry| {
            const entry = registry.get(self.registry_handle.?) catch unreachable;
            std.debug.assert(entry.payload == self);
            if (entry.generation.isValid()) std.debug.assert(entry.generation.value() == self.runtime_generation);
            std.debug.assert(entry.control_plan_leases == @as(u64, self.preparation_leases) + self.pending_plan_leases + self.policy_leases + self.layer_controller_leases);
        } else std.debug.assert(self.registry_handle == null and !self.hasControlLeases());
    }
    pub fn retainPreparation(self: *Generation) !void {
        self.assertControlCredits();
        const next = try std.math.add(u32, self.preparation_leases, 1);
        try self.registry.?.acquireControl(self.registry_handle.?);
        self.preparation_leases = next;
        self.assertControlCredits();
    }
    pub fn releasePreparation(self: *Generation) void {
        self.assertControlCredits();
        std.debug.assert(self.preparation_leases != 0);
        self.registry.?.releaseControl(self.registry_handle.?) catch unreachable;
        self.preparation_leases -= 1;
        self.assertControlCredits();
    }
    pub fn retainPending(self: *Generation) !void {
        self.assertControlCredits();
        const next = try std.math.add(u32, self.pending_plan_leases, 1);
        try self.registry.?.acquireControl(self.registry_handle.?);
        self.pending_plan_leases = next;
        self.assertControlCredits();
    }
    pub fn releasePending(self: *Generation) void {
        self.assertControlCredits();
        std.debug.assert(self.pending_plan_leases != 0);
        self.registry.?.releaseControl(self.registry_handle.?) catch unreachable;
        self.pending_plan_leases -= 1;
        self.assertControlCredits();
    }
    pub fn retainPolicy(self: *Generation) !PolicyGenerationLease {
        self.assertControlCredits();
        if (self.retirement.load(.acquire) != .active or self.runtime_generation == 0) return error.InvalidState;
        const handle = self.registry_handle orelse return error.InvalidState;
        const next = try std.math.add(u32, self.policy_leases, 1);
        try self.registry.?.acquireControl(handle);
        self.policy_leases = next;
        self.assertControlCredits();
        return .{ .payload = self, .registry = handle, .runtime_generation = self.runtime_generation, .authored_generation = self.loaded.metadata.generation, .bank_content_hash = self.loaded.content_hash };
    }
    pub fn releasePolicy(self: *Generation, lease: PolicyGenerationLease) !void {
        self.assertControlCredits();
        if (lease.payload != self or lease.runtime_generation != self.runtime_generation or self.registry_handle == null or
            !std.meta.eql(lease.registry, self.registry_handle.?) or self.policy_leases == 0 or lease.authored_generation != self.loaded.metadata.generation or
            !std.mem.eql(u8, &lease.bank_content_hash, &self.loaded.content_hash)) return error.InvalidState;
        try self.registry.?.releaseControl(lease.registry);
        self.policy_leases -= 1;
        self.assertControlCredits();
    }
    /// Called before prepared-group visibility, under the actual Control owner.
    /// Runtime identity belongs to the registry; curve tables keep their exact
    /// original authored identity. Neither is inferred from the other.
    pub fn prepareLayerController(self: *Generation, group: rt.GroupHandle, segment_id: u64) !bool {
        return (try self.prepareLayerControllers(group, segment_id, null)) != 0;
    }
    /// Reserve and construct the bounded source pair as one preparation
    /// transaction. Each actual controller owns one registry Control credit.
    pub fn prepareLayerControllers(self: *Generation, group: rt.GroupHandle, original_segment_id: u64, fallback_segment_id: ?u64) !u8 {
        const owner = self.layer_owner orelse return 0;
        self.assertControlCredits();
        if (self.retirement.load(.acquire) != .active or self.runtime_generation == 0 or owner.runtime_generation != self.runtime_generation) return error.InvalidState;
        if (try owner.controllerCount(group) != 0) return error.InvalidState;
        const original = try self.layerSegmentIndex(original_segment_id);
        const fallback: ?u32 = if (fallback_segment_id) |id| try self.layerSegmentIndex(id) else null;
        if (fallback) |index| if (index == original) return error.InvalidBinding;
        const count: u8 = @as(u8, @intFromBool(owner.bindsSegment(original))) + @as(u8, @intFromBool(if (fallback) |index| owner.bindsSegment(index) else false));
        if (count == 0) return 0;
        const next = try std.math.add(u32, self.layer_controller_leases, count);
        var acquired: u8 = 0;
        errdefer while (acquired != 0) {
            self.registry.?.releaseControl(self.registry_handle.?) catch unreachable;
            acquired -= 1;
        };
        while (acquired < count) : (acquired += 1) try self.registry.?.acquireControl(self.registry_handle.?);
        // Newly allocated controllers have no published programs, so this
        // rollback cannot need deferred Control/Render cleanup.
        errdefer owner.releaseGroup(group) catch unreachable;
        try owner.prepareGroup(&self.loaded, group, original);
        if (fallback) |index| try owner.prepareFallbackGroup(&self.loaded, group, index);
        self.layer_controller_leases = next;
        self.assertControlCredits();
        return count;
    }
    fn layerSegmentIndex(self: *Generation, segment_id: u64) !u32 {
        for (self.loaded.tables.segments, 0..) |entry, index| {
            if (entry.key.id == segment_id) return @intCast(index);
        }
        return error.InvalidBinding;
    }
    /// Validate only the authored emergency edge for this loaded generation.
    /// A fallback is a distinct resident leaf, never a recursive source graph.
    pub fn emergencyFallbackSegment(self: *const Generation, original: u32) !?u32 {
        const tables = self.loaded.tables;
        if (original >= tables.segments.len) return error.InvalidBinding;
        const index = tables.segments[original].fallback_segment;
        if (index == s.none) return null;
        if (index >= tables.segments.len or index == original) return error.InvalidBinding;
        const fallback = tables.segments[index];
        if (fallback.emergency != 1 or fallback.storage != .resident or fallback.fallback_segment != s.none or fallback.layers.count == 0 or fallback.layers.count > rt.music_group.max_layers) return error.UnsupportedCapability;
        if (fallback.layers.first > tables.layers.len or fallback.layers.count > tables.layers.len - fallback.layers.first) return error.InvalidBinding;
        for (tables.layers[fallback.layers.first..][0..fallback.layers.count]) |layer| {
            if (layer.segment != index or layer.sound >= tables.sounds.len) return error.InvalidBinding;
            if (tables.sounds[layer.sound].storage != .resident) return error.UnsupportedCapability;
        }
        return index;
    }
    pub fn closeLayerController(self: *Generation, group: rt.GroupHandle) !void {
        const owner = self.layer_owner orelse return;
        self.assertControlCredits();
        try owner.closeController(group);
    }
    pub fn releaseLayerController(self: *Generation, group: rt.GroupHandle) !void {
        const owner = self.layer_owner orelse return error.InvalidState;
        self.assertControlCredits();
        const count = try owner.controllerCount(group);
        if (count == 0 or self.layer_controller_leases < count) return error.InvalidState;
        try owner.releaseClosedGroup(group);
        for (0..count) |_| self.registry.?.releaseControl(self.registry_handle.?) catch unreachable;
        self.layer_controller_leases -= count;
        self.assertControlCredits();
    }
    pub fn ownsSampleOwner(self: *const Generation, owner: *const rt.SampleOwner) bool {
        for (self.owners) |*owned| if (owned == owner) return true;
        return false;
    }
    /// Exact descriptor custody, not an aggregate reference-count inference.
    pub fn ownsGroupLayer(self: *Generation, layer: rt.MusicGroupLayer) bool {
        if (layer.generation != self.runtime_generation or !self.ownsSampleOwner(layer.owner)) return false;
        if (layer.stream) |source| {
            const service = self.service orelse return false;
            const handle = service.handleForSource(source) catch return false;
            if (source.identity.asset_generation != self.runtime_generation) return false;
            for (self.windows) |entry| if (entry) |window| {
                if (!window.retiring and std.meta.eql(window.binding.handle, handle) and window.binding.sound == source.identity.asset) return true;
            };
            return false;
        }
        return !layer.owner.stream_token;
    }
    pub fn hasPreparedGroupLeases(self: *Generation) bool {
        if (self.registry) |registry| return (registry.get(self.registry_handle.?) catch unreachable).prepared_music_groups != 0;
        return false;
    }
    pub fn hasSnapshotLeases(self: *Generation) bool {
        if (self.registry) |registry| return (registry.get(self.registry_handle.?) catch unreachable).snapshot_slots != 0;
        return false;
    }
    pub fn hasControlLeases(self: *const Generation) bool {
        return self.preparation_leases != 0 or self.pending_plan_leases != 0 or self.policy_leases != 0 or self.layer_controller_leases != 0;
    }
    pub fn registered(self: *Generation, registry: *GenerationRegistry, handle: generation_registry.Handle) void {
        std.debug.assert(self.registry == null and !self.hasControlLeases());
        self.registry = registry;
        self.registry_handle = handle;
        self.assertControlCredits();
    }
    // Call only after the real owner has removed slot/Pending references and
    // performed its physical teardown checks; an observation cannot authorize
    // destruction. Registry custody transfers back exactly once here.
    pub fn withdraw(self: *Generation) void {
        self.assertControlCredits();
        std.debug.assert(!self.hasControlLeases());
        const owned = self.registry.?.withdraw(self.registry_handle.?) catch unreachable;
        std.debug.assert(owned == self);
        self.registry = null;
        self.registry_handle = null;
    }
    /// The caller transfers an allocation from this Generation's allocator.
    /// Content was already validated and its full original image authenticated;
    /// this operation allocates nothing and has exactly one lifetime owner.
    pub fn adoptCompiledImage(self: *Generation, compiled: []u8) void {
        std.debug.assert(self.retained_compiled.len == 0 and compiled.len != 0);
        self.retained_compiled = compiled;
    }
    pub fn retainedBytes(self: *const Generation) !u64 {
        var bytes: u64 = @sizeOf(Generation);
        bytes = try std.math.add(u64, bytes, self.retained_compiled.len);
        if (self.play_custody != null) bytes = try std.math.add(u64, bytes, @sizeOf(rt.PlayCustodyAnchor));
        bytes = try std.math.add(u64, bytes, try std.math.mul(u64, self.owners.len, @sizeOf(rt.SampleOwner)));
        inline for (std.meta.fields(s.Tables)) |field| {
            const rows = @field(self.loaded.tables, field.name);
            bytes = try std.math.add(u64, bytes, try std.math.mul(u64, rows.len, @sizeOf(std.meta.Elem(@TypeOf(rows)))));
        }
        if (self.loaded.bus_graph) |graph| bytes = try std.math.add(u64, bytes, try graph.backingAllocationBytes());
        if (self.policies) |owned| {
            bytes = try std.math.add(u64, bytes, try std.math.mul(u64, owned.stingers.len, @sizeOf(bank.music_policy_adapter.Stinger)));
            bytes = try std.math.add(u64, bytes, try std.math.mul(u64, owned.acoustics.len, @sizeOf(bank.music_policy_adapter.Acoustic)));
            bytes = try std.math.add(u64, bytes, try std.math.mul(u64, owned.ducks.len, @sizeOf(s.AutomationDuckPreset)));
        }
        if (self.layer_owner) |owner| bytes = try std.math.add(u64, bytes, owner.ownedBytes());
        bytes = try std.math.add(u64, bytes, self.sourceStorageBytes());
        if (self.readiness != null) bytes = try std.math.add(u64, bytes, @sizeOf(planner.ReadinessSnapshot));
        for (self.owners) |owner| if (!owner.stream_token) {
            bytes = try std.math.add(u64, bytes, try std.math.mul(u64, owner.samples.len, @sizeOf(f32)));
        };
        bytes = try std.math.add(u64, bytes, try std.math.mul(u64, self.stinger_history.len, @sizeOf(StingerHistory)));
        if (self.director != null) bytes = try std.math.add(u64, bytes, @sizeOf(director.Director));
        if (self.layer_director_scratch != null) bytes = try std.math.add(u64, bytes, @sizeOf(director.Director));
        if (self.scratch_plan != null) bytes = try std.math.add(u64, bytes, @sizeOf(planner.TransitionPlan));
        if (self.solver) |solver| bytes = try std.math.add(u64, bytes, solver.retainedBytes());
        return bytes;
    }

    pub fn prepare(allocator: std.mem.Allocator, compiled: []const u8) !*Generation {
        return prepareWithSources(allocator, compiled, null);
    }
    /// Initial-load compatibility path. Provider work remains on Worker. The
    /// preparation Service transfers into context custody at actual adoption.
    pub fn prepareWithSources(allocator: std.mem.Allocator, compiled: []const u8, provider: ?SourceProvider) !*Generation {
        return prepareProfile(allocator, compiled, provider, .disabled);
    }
    pub fn prepareProfile(allocator: std.mem.Allocator, compiled: []const u8, provider: ?SourceProvider, profile: v1.PolicySupportV1) !*Generation {
        return prepareProfileBindings(allocator, compiled, provider, profile, .{});
    }
    pub fn prepareProfileBindings(allocator: std.mem.Allocator, compiled: []const u8, provider: ?SourceProvider, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1) !*Generation {
        return prepareProfileBindingsMode(allocator, compiled, provider, profile, bindings, .full_span);
    }
    pub fn prepareProfileBindingsMode(allocator: std.mem.Allocator, compiled: []const u8, provider: ?SourceProvider, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1, fill_pcm_mode: planner.FillPcmMode) !*Generation {
        return prepareProfileBindingsReservation(allocator, compiled, provider, profile, bindings, fill_pcm_mode, false);
    }
    pub fn prepareProfileBindingsReservation(allocator: std.mem.Allocator, compiled: []const u8, provider: ?SourceProvider, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1, fill_pcm_mode: planner.FillPcmMode, release_reservation: bool) !*Generation {
        return prepareProfileCrossfade(allocator, compiled, provider, profile, bindings, fill_pcm_mode, release_reservation, .{});
    }
    /// Explicit host-bound curve admission. Legacy entry points keep an empty
    /// binding set and therefore retain their original hard-cut-only contract.
    pub fn prepareProfileCrossfade(allocator: std.mem.Allocator, compiled: []const u8, provider: ?SourceProvider, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1, fill_pcm_mode: planner.FillPcmMode, release_reservation: bool, crossfades: crossfade_contract.ConfigV1) !*Generation {
        return prepareProfileCrossfadeImpl(allocator, compiled, provider, profile, bindings, fill_pcm_mode, release_reservation, crossfades, if (@import("builtin").is_test) null else {}, null);
    }
    /// Explicit Live semantic constructor. Installs the immutable Service
    /// observer immediately after real allocation, before any source preparation.
    pub fn prepareSemanticCrossfade(allocator: std.mem.Allocator, compiled: []const u8, provider: ?SourceProvider, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1, fill_pcm_mode: planner.FillPcmMode, release_reservation: bool, crossfades: crossfade_contract.ConfigV1, hooks: streaming.stream.LiveSemanticHooks) !*Generation {
        return prepareProfileCrossfadeImpl(allocator, compiled, provider, profile, bindings, fill_pcm_mode, release_reservation, crossfades, if (@import("builtin").is_test) null else {}, hooks);
    }
    /// Only the real owner's test-only bootstrap route can select this helper.
    /// Its candidate can retire but cannot enter published Service custody yet.
    pub const BootstrapTests = if (@import("builtin").is_test) struct {
        pub fn prepare(allocator: std.mem.Allocator, compiled: []const u8, provider: ?SourceProvider, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1, fill_pcm_mode: planner.FillPcmMode, release_reservation: bool, crossfades: crossfade_contract.ConfigV1, session: *TestLiveBootstrap.Session, ticket: v1.LoadTicketV1) !*Generation {
            try session.validateTicket(ticket);
            return prepareProfileCrossfadeImpl(allocator, compiled, provider, profile, bindings, fill_pcm_mode, release_reservation, crossfades, session, null);
        }
    } else struct {};
    fn prepareProfileCrossfadeImpl(allocator: std.mem.Allocator, compiled: []const u8, provider: ?SourceProvider, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1, fill_pcm_mode: planner.FillPcmMode, release_reservation: bool, crossfades: crossfade_contract.ConfigV1, bootstrap: if (@import("builtin").is_test) ?*TestLiveBootstrap.Session else void, semantic_hooks: ?streaming.stream.LiveSemanticHooks) !*Generation {
        if (@import("builtin").is_test) if (bootstrap) |session| try session.validatePreparation(compiled, provider);
        const result = try prepareContentCrossfade(allocator, compiled, provider != null, profile, bindings, fill_pcm_mode, release_reservation, crossfades);
        errdefer result.destroy();
        try result.assignRuntimeIdentity(result.loaded.metadata.generation);
        if (result.sources.len != 0) {
            const service = try streaming.Service.create(allocator, streaming.release_profile);
            result.service = service;
            if (semantic_hooks) |hooks| {
                if (hooks.clock != null) try service.attachLiveSemanticReplayQuiescent(hooks) else try service.attachLiveSemanticQuiescent(hooks);
            }
            // All fallible install checks precede mutation; prepareSources
            // retains its ordinary failure for real Worker retirement below.
            if (@import("builtin").is_test) if (bootstrap) |session| try session.install(result, compiled, provider.?);
            result.prepareSources(.{ .v1 = provider.? });
        }
        return result;
    }
    /// Worker owns validated original content and policy descriptors, but opens
    /// no provider and allocates no Service before Control identity admission.
    pub fn prepareContent(allocator: std.mem.Allocator, compiled: []const u8, allow_streaming: bool) !*Generation {
        return prepareContentProfile(allocator, compiled, allow_streaming, .disabled);
    }
    pub fn prepareContentProfile(allocator: std.mem.Allocator, compiled: []const u8, allow_streaming: bool, profile: v1.PolicySupportV1) !*Generation {
        return prepareContentBindings(allocator, compiled, allow_streaming, profile, .{});
    }
    pub fn prepareContentBindings(allocator: std.mem.Allocator, compiled: []const u8, allow_streaming: bool, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1) !*Generation {
        return prepareContentBindingsMode(allocator, compiled, allow_streaming, profile, bindings, .full_span);
    }
    pub fn prepareContentBindingsMode(allocator: std.mem.Allocator, compiled: []const u8, allow_streaming: bool, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1, fill_pcm_mode: planner.FillPcmMode) !*Generation {
        return prepareContentBindingsReservation(allocator, compiled, allow_streaming, profile, bindings, fill_pcm_mode, false);
    }
    pub fn prepareContentBindingsReservation(allocator: std.mem.Allocator, compiled: []const u8, allow_streaming: bool, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1, fill_pcm_mode: planner.FillPcmMode, release_reservation: bool) !*Generation {
        return prepareContentCrossfade(allocator, compiled, allow_streaming, profile, bindings, fill_pcm_mode, release_reservation, .{});
    }
    /// The caller owns the already-copied host configuration through Worker
    /// preparation. No curve binding changes the compiled bank wire or identity.
    pub fn prepareContentCrossfade(allocator: std.mem.Allocator, compiled: []const u8, allow_streaming: bool, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1, fill_pcm_mode: planner.FillPcmMode, release_reservation: bool, crossfades: crossfade_contract.ConfigV1) !*Generation {
        try bindings.validate();
        try crossfades.validate();
        var loaded = try bank.MusicBank.load(allocator, compiled);
        errdefer loaded.deinit();
        try crossfades.validateTables(loaded.tables);
        // Resolve every explicit binding against genuine compiled metadata
        // before opening any provider. Empty/default support is unchanged.
        const layer_owner = if (bindings.bindings.len != 0) try runtime_layers.Owner.create(allocator, &loaded, bindings) else null;
        errdefer if (layer_owner) |owner| owner.destroy() catch unreachable;
        try validateCapability(&loaded, allow_streaming, profile, bindings, fill_pcm_mode, release_reservation, crossfades);
        var policies: ?bank.music_policy_adapter.Owned = if (s.policyEnabled(loaded.metadata)) try bank.music_policy_adapter.Owned.init(allocator, loaded.metadata, loaded.tables, s.sample_rate) else null;
        errdefer if (policies) |*value| value.deinit();
        const history = try allocator.alloc(StingerHistory, if (policies) |value| value.stingers.len else 0);
        errdefer allocator.free(history);
        for (history) |*entry| entry.* = .{};
        var stream_count: usize = 0;
        for (loaded.tables.sounds) |sound| stream_count += @intFromBool(sound.storage == .streaming);
        // An unused opt-in must not alter resident/short-fill plan identity or
        // the supported resident recording/replay contract. Carry the new mode
        // only when this generation actually contains a long streamed fill.
        const effective_fill_mode: planner.FillPcmMode = mode: {
            if (fill_pcm_mode == .rolling_high_watermark) for (loaded.tables.fill_steps) |step| {
                if (loaded.tables.cues[step.exit].frame - loaded.tables.cues[step.entry].frame <= streaming.release_profile.high_frames) continue;
                const segment = loaded.tables.segments[step.segment];
                for (loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
                    if (loaded.tables.sounds[layer.sound].storage == .streaming) break :mode .rolling_high_watermark;
                }
            };
            break :mode .full_span;
        };
        // This first public profile keeps asset descriptors within the existing
        // 48-source service/binding budget. It is explicit admission, not a new
        // larger hidden allocation limit or full-runtime capability claim.
        if (stream_count > streaming.release_profile.max_streams) return error.ResourceLimitExceeded;
        const owners = try allocator.alloc(rt.SampleOwner, loaded.tables.sounds.len);
        errdefer allocator.free(owners);
        var initialized: usize = 0;
        errdefer for (owners[0..initialized]) |owner| if (!owner.stream_token) allocator.free(owner.samples);
        for (loaded.tables.sounds, owners) |sound, *owner| {
            if (sound.storage == .streaming) {
                owner.* = rt.SampleOwner.initStreamToken();
            } else {
                const samples = try allocator.alloc(f32, @intCast(sound.frames * sound.channels));
                errdefer allocator.free(samples);
                const bytes = loaded.tables.blob[@intCast(sound.blob_offset)..][0..@intCast(sound.blob_length)];
                for (samples, 0..) |*sample, i| sample.* = @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
                owner.* = try rt.SampleOwner.init(samples);
            }
            initialized += 1;
        }
        const source_bytes = try std.math.mul(usize, stream_count, @sizeOf(SourceRecord));
        if (stream_count != 0 and try std.math.add(usize, try streaming.Service.capacityBytes(streaming.release_profile), source_bytes) > rt.virtual_voice.releaseProfile().stream_budget_bytes) return error.ResourceLimitExceeded;
        const records = try allocator.alloc(SourceRecord, stream_count);
        errdefer allocator.free(records);
        const result = try allocator.create(Generation);
        result.* = .{ .allocator = allocator, .loaded = loaded, .fill_pcm_mode = effective_fill_mode, .owners = owners, .sources = records, .policies = policies, .layer_owner = layer_owner, .stinger_history = history };
        var next: usize = 0;
        for (loaded.tables.sounds, 0..) |sound, i| if (sound.storage == .streaming) {
            records[next] = .{ .sound_index = @intCast(i) };
            next += 1;
        };
        return result;
    }
    pub fn assignRuntimeIdentity(self: *Generation, identity: u64) !void {
        if (identity == 0 or self.runtime_generation != 0 or self.director != null or self.windowCount() != 0) return error.InvalidState;
        self.runtime_generation = identity;
    }
    /// Control acquires authoritative context custody before publishing this
    /// Generation to Worker. An initially owned Service may transfer only into
    /// custody for the very same pointer; it is never silently replaced.
    pub fn bindSharedService(self: *Generation, custody: *ServiceCustody) !void {
        if (self.runtime_generation == 0 or self.sources.len == 0 or self.service_custody != null or self.retirement.load(.acquire) != .active) return error.InvalidState;
        if (self.service) |service| if (service != custody.service or !self.owns_service) return error.InvalidState;
        try custody.acquire();
        self.service = custody.service;
        self.service_custody = custody;
        self.owns_service = false;
    }
    /// Only initial startup attachment rollback uses this inverse transfer.
    /// No shared Worker pointer or window may have been published yet.
    pub fn undoSharedServiceTransfer(self: *Generation) void {
        std.debug.assert(self.windowCount() == 0 and self.service_custody != null and !self.owns_service);
        self.service_custody.?.release();
        self.service_custody = null;
        self.owns_service = true;
    }
    pub fn authorizeSourceIdentity(self: *Generation, context: u64) !void {
        if (self.source_identity != null or self.runtime_generation == 0 or self.sources.len == 0) return error.InvalidState;
        const identity: source_provider.IdentityV2 = .{ .context = context, .runtime_generation = self.runtime_generation, .bank_hash = self.loaded.content_hash, .authored_generation = self.loaded.metadata.generation };
        try identity.validate();
        self.source_identity = identity;
    }
    /// Worker only, after Control identity/custody/source-budget authorization.
    /// Bind/open failures retain every acquired token for real retirement.
    pub fn prepareSources(self: *Generation, provider: AnySourceProvider) void {
        std.debug.assert(self.runtime_generation != 0 and self.service != null);
        const session: SourceSession = switch (provider) {
            .v1 => |value| .{ .v1 = value },
            .v2 => |value| blk: {
                const identity = self.source_identity orelse {
                    self.preparation_failure = error.InvalidBinding;
                    return;
                };
                const token = value.bind(value.context, identity) catch |err| {
                    self.preparation_failure = err;
                    return;
                };
                // A successful bind already owns custody, including malformed
                // provider output. Preserve its exact token for unbind cleanup.
                self.source_binding = .{ .provider = value, .identity = identity, .token = token };
                if (!token.matches(identity)) {
                    self.preparation_failure = error.InvalidBinding;
                    return;
                }
                break :blk .{ .v2 = &self.source_binding.? };
            },
        };
        for (self.sources) |*record| {
            std.debug.assert(record.provider == null and record.opened == null and record.asset == null);
            record.provider = session;
        }
        for (self.sources) |*record| {
            self.openSource(record) catch |err| {
                self.preparation_failure = err;
                break;
            };
        }
    }
    fn openSource(self: *Generation, record: *SourceRecord) !void {
        const sound = self.loaded.tables.sounds[record.sound_index];
        record.opened = switch (record.provider.?) {
            // Preserve the original V1 resource-authentication meaning.
            .v1 => |provider| try provider.open(provider.context, .{ .bank_hash = self.loaded.content_hash, .asset_generation = self.loaded.metadata.generation, .sound_id = sound.key.id, .encoded_hash = sound.audio_hash, .encoded_bytes = sound.blob_length }),
            .v2 => |binding| try binding.provider.open(binding.provider.context, binding.token, .{ .sound_id = sound.key.id, .encoded_hash = sound.audio_hash, .encoded_bytes = sound.blob_length }),
        };
        if (record.opened.?.token == 0 or record.opened.?.encoded_bytes != sound.blob_length) return error.InvalidSource;
        record.asset = try self.service.?.prepareAsset(.{ .sound_index = record.sound_index, .sound = sound, .codec = self.loaded.tables.codecs[sound.codec], .chunks = self.loaded.tables.chunks[sound.chunks.first..][0..sound.chunks.count], .seeks = self.loaded.tables.seeks[sound.seeks.first..][0..sound.seeks.count], .source = record.bytes() });
    }
    pub fn streamAsset(self: *Generation, sound_index: u32) !*streaming.Asset {
        if (self.retirement.load(.acquire) != .active or self.preparation_failure != null) return error.InvalidState;
        for (self.sources) |*record| if (record.sound_index == sound_index) return if (record.asset) |*asset| asset else error.InvalidState;
        return error.InvalidState;
    }
    /// Prepare all potentially selected entry occurrences for the existing
    /// Planner. This does not select a path, advance Director history, create a
    /// group, or claim readiness. Alternative paths may reuse one unconsumed
    /// candidate key; repeated entries within a path always use distinct keys.
    pub fn prepareEntryWindows(self: *Generation, intent: director.TransitionIntent, source_segment: ?u64, transport_epoch: u64, deadline: u64) !void {
        if (self.service == null) return;
        errdefer self.retireEntryRequestWindows(intent.request_id);
        const t = self.loaded.tables;
        if (source_segment) |source| {
            const rule = for (t.transitions) |value| {
                if (value.key.id == intent.rule_id) break value;
            } else return error.InvalidMusicGraph;
            for (t.transition_paths[rule.paths.first..][0..rule.paths.count]) |path| {
                const target = t.cues[path.target_entry];
                if (t.segments[t.cues[path.source_exit].segment].key.id != source or t.segments[target.segment].key.id != intent.resolved_segment) continue;
                const steps: []const s.FillStep = if (path.fill == s.none) &.{} else t.fill_steps[t.fills[path.fill].steps.first..][0..t.fills[path.fill].steps.count];
                if (steps.len > max_resident_fill_steps) return error.UnsupportedCapability;
                for (steps, 0..) |step, index| {
                    var occurrence: u16 = 0;
                    for (steps[0..index]) |prior| if (prior.segment == step.segment and prior.entry == step.entry) {
                        occurrence += 1;
                    };
                    _ = try self.prepareCueWindows(intent.request_id, step.segment, step.entry, occurrence, transport_epoch, deadline);
                }
                var occurrence: u16 = 0;
                for (steps) |step| if (step.segment == target.segment and step.entry == path.target_entry) {
                    occurrence += 1;
                };
                _ = try self.prepareCueWindows(intent.request_id, target.segment, path.target_entry, occurrence, transport_epoch, deadline);
            }
            // Only Planner decides which matching paths are actually eligible
            // at this clock/frontier. Failure adjudication follows that result.
        } else {
            const segment_index: u32 = for (t.segments, 0..) |segment, i| {
                if (segment.key.id == intent.resolved_segment) break @intCast(i);
            } else return error.InvalidMusicGraph;
            var cue_index: ?u32 = null;
            for (t.cues, 0..) |cue, i| {
                if (cue.segment != segment_index or (cue.kind != .entry and cue.kind != .both) or cue.frame != 0) continue;
                if (cue_index != null) return error.UnsupportedCapability;
                cue_index = @intCast(i);
            }
            if (try self.prepareCueWindows(intent.request_id, segment_index, cue_index orelse return error.TransitionNotFound, 0, transport_epoch, deadline)) return error.SourceReadFailed;
        }
    }
    /// A failed existing window stays owned under its original handle. Report
    /// its real Service failure to route viability; never reopen it on retry.
    fn prepareCueWindows(self: *Generation, request_id: u64, segment_index: u32, cue_index: u32, occurrence: u16, transport_epoch: u64, deadline: u64) !bool {
        const service = self.service orelse return error.InvalidState;
        const segment = self.loaded.tables.segments[segment_index];
        const cue = self.loaded.tables.cues[cue_index];
        if (cue.segment != segment_index or request_id == 0) return error.InvalidMusicGraph;
        const entry: EntryWindow = .{ .segment = segment.key.id, .cue = cue.key.id, .occurrence = occurrence };
        var failed = false;
        for (self.loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            const sound = self.loaded.tables.sounds[layer.sound];
            if (sound.storage != .streaming) continue;
            const start = try std.math.add(u64, layer.source_start, cue.frame);
            var existing = false;
            for (self.windows) |value| if (value) |window| {
                if (!window.ownedBy(.request, request_id) or window.retiring or window.binding.layer != layer.key.id or !entry.matches(window.binding)) continue;
                if (window.binding.sound != sound.key.id or window.binding.source_cursor != start or window.group != null) return error.InvalidState;
                failed = (try service.failure(window.binding.handle) != .none) or failed;
                existing = true;
                break;
            };
            if (existing) continue;
            const slot = for (&self.windows) |*value| {
                if (value.* == null) break value;
            } else return error.ResourceLimitExceeded;
            const loop: ?streaming.Loop = if (segment.loop_end > segment.loop_start) .{ .start = try std.math.add(u64, layer.source_start, segment.loop_start), .end = try std.math.add(u64, layer.source_start, segment.loop_end) } else null;
            const handle = try service.open(try self.streamAsset(layer.sound), .{ .generation = self.runtime_generation, .transport_epoch = transport_epoch, .group = request_id, .layer = layer.key.id, .start_cursor = start, .loop = loop, .deadline_frame = deadline, .priority = .imminent_target_fill });
            slot.* = .{ .request_id = request_id, .binding = .{ .sound = sound.key.id, .layer = layer.key.id, .segment = segment.key.id, .cue = cue.key.id, .occurrence = occurrence, .source_cursor = start, .handle = handle } };
        }
        return failed;
    }
    /// Prepare exactly the validated saved suffix, without a new path search or
    /// provider session. Repeated entries receive distinct existing-capacity
    /// Service slots; retries retain failed handles for acknowledged cleanup.
    pub fn prepareRestoreEntryWindows(self: *Generation, request_id: u64, entries: []const save.Entry, transport_epoch: u64, deadline: u64) !void {
        const service = self.service orelse return error.InvalidState;
        if (request_id == 0 or transport_epoch == 0 or entries.len > 3) return error.InvalidState;
        errdefer self.retireEntryRequestWindows(request_id);
        for (self.windows) |value| if (value) |window| {
            if (!window.ownedBy(.request, request_id) or window.binding.cue == 0) continue;
            if (window.retiring or window.group != null) return error.InvalidState;
            const source = try service.renderSource(window.binding.handle);
            if (source.identity.transport_epoch != transport_epoch or source.identity.start_loop_epoch != 0) return error.InvalidState;
            if (try service.failure(window.binding.handle) != .none) return error.SourceReadFailed;
        };
        const t = self.loaded.tables;
        for (entries, 0..) |entry, index| {
            const segment_index = try restoreIndex(t.segments, entry.segment);
            const cue_index = try restoreIndex(t.cues, entry.cue);
            const cue = t.cues[cue_index];
            if (cue.segment != segment_index or !bank.transition_validation.isEntry(cue.kind) or cue.frame != entry.cursor or entry.duration == 0) return error.InvalidSnapshot;
            const window = restoreEntryWindow(entries, index);
            if (try self.prepareCueWindows(request_id, segment_index, cue_index, window.occurrence, transport_epoch, deadline)) return error.SourceReadFailed;
        }
    }
    /// Prepare real Worker windows at the acquired pause coordinate; no entry
    /// cue or Planner phase is invented for this transport operation.
    pub fn prepareResumeWindows(self: *Generation, request_id: u64, group: rt.GroupHandle, segment_index: u32, paused: rt.music_group.ContinuityCoordinate, transport_epoch: u64, deadline: u64) !void {
        const service = self.service orelse return error.InvalidState;
        if (!paused.paused or request_id == 0 or paused.transport_epoch == std.math.maxInt(u64) or transport_epoch != paused.transport_epoch + 1) return error.InvalidState;
        const segment = self.loaded.tables.segments[segment_index];
        if (paused.cursor >= segment.frames) return error.InvalidState;
        for (self.loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            const sound = self.loaded.tables.sounds[layer.sound];
            if (sound.storage != .streaming) continue;
            var existing = false;
            for (self.windows) |entry| if (entry) |window| {
                if (window.ownedBy(.request, request_id) and window.binding.layer == layer.key.id and !window.retiring) {
                    existing = true;
                    break;
                }
            };
            if (existing) continue;
            const destination = for (&self.windows) |*entry| {
                if (entry.* == null) break entry;
            } else return error.ResourceLimitExceeded;
            const start = try std.math.add(u64, layer.source_start, paused.cursor);
            const loop: ?streaming.Loop = if (segment.loop_end > segment.loop_start) .{ .start = try std.math.add(u64, layer.source_start, segment.loop_start), .end = try std.math.add(u64, layer.source_start, segment.loop_end) } else null;
            const handle = try service.open(try self.streamAsset(layer.sound), .{ .generation = self.runtime_generation, .transport_epoch = transport_epoch, .group = group.generation, .layer = layer.key.id, .start_cursor = start, .loop_epoch = paused.loop_epoch, .loop = loop, .deadline_frame = deadline, .priority = .imminent_target_fill, .operation = .seek });
            destination.* = .{ .request_id = request_id, .binding = .{ .sound = sound.key.id, .layer = layer.key.id, .segment = segment.key.id, .cue = 0, .source_cursor = start, .handle = handle } };
        }
    }
    /// Fresh restore windows own new Service slots/decoders/rings. The saved
    /// physical cursor is translated through each authored source origin; no
    /// live ring or decoder is reset, borrowed, or treated as restored state.
    pub fn prepareRestoreWindows(self: *Generation, request_id: u64, segment_index: u32, cursor: u64, loop_epoch: u64, transport_epoch: u64, deadline: u64) !void {
        return self.prepareRestoreWindowsScoped(.request, request_id, segment_index, cursor, loop_epoch, transport_epoch, deadline);
    }
    pub fn prepareRestoreWindowsScoped(self: *Generation, scope: WindowScope, request_id: u64, segment_index: u32, cursor: u64, loop_epoch: u64, transport_epoch: u64, deadline: u64) !void {
        const service = self.service orelse return error.InvalidState;
        if (segment_index >= self.loaded.tables.segments.len) return error.InvalidState;
        const segment = self.loaded.tables.segments[segment_index];
        if (request_id == 0 or transport_epoch == 0 or segment.storage != .streaming or cursor >= segment.frames) return error.InvalidState;
        errdefer self.retireRequestWindowsScoped(scope, request_id);
        for (self.loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            const sound = self.loaded.tables.sounds[layer.sound];
            if (sound.storage != .streaming) return error.UnsupportedCapability;
            const start = try std.math.add(u64, layer.source_start, cursor);
            var existing = false;
            for (self.windows) |entry| if (entry) |window| {
                if (!window.ownedBy(scope, request_id) or window.binding.cue != 0 or window.binding.layer != layer.key.id) continue;
                if (window.retiring or window.group != null or existing or window.binding.segment != segment.key.id or window.binding.sound != sound.key.id or window.binding.source_cursor != start) return error.InvalidState;
                const source = try service.renderSource(window.binding.handle);
                if (source.identity.transport_epoch != transport_epoch or source.identity.start_loop_epoch != loop_epoch) return error.InvalidState;
                if (try service.failure(window.binding.handle) != .none) return error.SourceReadFailed;
                existing = true;
            };
            if (existing) continue;
            const destination = for (&self.windows) |*entry| {
                if (entry.* == null) break entry;
            } else return error.ResourceLimitExceeded;
            const loop: ?streaming.Loop = if (segment.loop_end > segment.loop_start) .{ .start = try std.math.add(u64, layer.source_start, segment.loop_start), .end = try std.math.add(u64, layer.source_start, segment.loop_end) } else null;
            const handle = try service.open(try self.streamAsset(layer.sound), .{ .generation = self.runtime_generation, .transport_epoch = transport_epoch, .group = request_id, .layer = layer.key.id, .start_cursor = start, .loop_epoch = loop_epoch, .loop = loop, .deadline_frame = deadline, .priority = .imminent_target_fill, .operation = .seek });
            destination.* = .{ .request_id = request_id, .scope = scope, .binding = .{ .sound = sound.key.id, .layer = layer.key.id, .segment = segment.key.id, .cue = 0, .source_cursor = start, .handle = handle } };
        }
    }
    /// The caller collects genuine accepted Control observations for this exact
    /// request first. Worker completion, forecasts, and accepted-but-not-visible
    /// publications alone cannot authorize a restored group or suffix.
    pub fn restoreWindowsReady(self: *Generation, request_id: u64, physical: ?RestorePhysical, entries: []const save.Entry, transport_epoch: u64, readiness: *const planner.ReadinessSnapshot) !bool {
        return self.restoreWindowsReadyScoped(.request, request_id, physical, entries, transport_epoch, readiness);
    }
    pub fn restoreWindowsReadyScoped(self: *Generation, scope: WindowScope, request_id: u64, physical: ?RestorePhysical, entries: []const save.Entry, transport_epoch: u64, readiness: *const planner.ReadinessSnapshot) !bool {
        const service = self.service orelse return error.InvalidState;
        if (request_id == 0 or transport_epoch == 0 or entries.len > 3 or readiness.count > planner.max_bindings) return error.InvalidState;
        if (!readiness.complete) return false;
        if (!std.meta.eql(readiness.stream_profile, service.profile)) return error.InvalidState;
        var expected: usize = 0;
        var ready = true;
        if (physical) |position| {
            if (position.segment_index >= self.loaded.tables.segments.len) return error.InvalidSnapshot;
            const segment = self.loaded.tables.segments[position.segment_index];
            // A capture fence can precede an authored same-frame next entry.
            // Its physical group still needs an ordinary playable source for
            // install, although it has no remaining transition span to cover.
            const needed: ?u64 = if (position.remaining) |remaining| (if (remaining == 0) null else try self.restoreFillFrames(remaining)) else null;
            ready = try self.restoreSegmentReady(scope, request_id, .{ .segment = segment.key.id, .cue = 0 }, position.segment_index, position.cursor, position.loop_epoch, needed, transport_epoch, readiness, &expected) and ready;
        }
        const minimum = self.loaded.tables.platforms[self.loaded.metadata.profile].planner_minimum_window_frames;
        for (entries, 0..) |entry, index| {
            const segment_index = try restoreIndex(self.loaded.tables.segments, entry.segment);
            const needed = if (entry.target) @min(entry.duration, minimum) else try self.restoreFillFrames(entry.duration);
            ready = try self.restoreSegmentReady(scope, request_id, restoreEntryWindow(entries, index), segment_index, entry.cursor, 0, needed, transport_epoch, readiness, &expected) and ready;
        }
        if (readiness.count != expected) return error.InvalidState;
        return ready;
    }
    fn restoreFillFrames(self: *const Generation, remaining: u64) !u64 {
        if (remaining == 0) return error.InvalidSnapshot;
        const high = self.service.?.profile.high_frames;
        if (self.fill_pcm_mode == .rolling_high_watermark) return @min(remaining, high);
        if (remaining > high) return error.UnsupportedCapability;
        return remaining;
    }
    fn restoreSegmentReady(self: *Generation, scope: WindowScope, request_id: u64, entry: EntryWindow, segment_index: u32, cursor: u64, loop_epoch: u64, required_frames: ?u64, transport_epoch: u64, readiness: *const planner.ReadinessSnapshot, expected: *usize) !bool {
        const service = self.service.?;
        const segment = self.loaded.tables.segments[segment_index];
        if (cursor >= segment.frames or (required_frames != null and required_frames.? == 0)) return error.InvalidSnapshot;
        var ready = true;
        for (self.loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            const sound = self.loaded.tables.sounds[layer.sound];
            if (sound.storage != .streaming) continue;
            expected.* += 1;
            const start = try std.math.add(u64, layer.source_start, cursor);
            var matched: ?usize = null;
            for (readiness.bindings[0..readiness.count], 0..) |binding, i| {
                if (binding.layer != layer.key.id or !entry.matches(binding)) continue;
                if (matched != null or binding.sound != sound.key.id or binding.source_cursor != start) return error.InvalidState;
                matched = i;
            }
            const index = matched orelse return error.InvalidState;
            const binding = readiness.bindings[index];
            if (readiness.failures[index] != .none or try service.failure(binding.handle) != .none) return error.SourceReadFailed;
            const source = if (entry.cue == 0) try self.sourceForScoped(scope, request_id, layer.key.id) else try self.sourceForEntryScoped(scope, request_id, entry, layer.key.id, start);
            if (!source.validate() or !std.meta.eql(source.identity, readiness.identities[index]) or source.identity.stream_generation != binding.handle.generation or source.identity.asset_generation != self.runtime_generation or source.identity.transport_epoch != transport_epoch or source.identity.start_cursor != start or source.identity.start_loop_epoch != loop_epoch) return error.InvalidState;
            const observation = readiness.observations[index];
            try observation.validate();
            if (observation.payload != .readiness_snapshot) return error.InvalidState;
            const accepted = observation.payload.readiness_snapshot;
            const facts = accepted.facts;
            if (facts.asset != sound.key.id or facts.generation != self.runtime_generation or facts.transport_epoch != transport_epoch or facts.profile != service.profile.id or !std.mem.eql(u8, &facts.profile_hash, &source.identity.profile_hash)) return error.InvalidState;
            const end = if (source.identity.loop) |loop| loop.end else source.identity.frame_count;
            if (start >= end) return error.InvalidSnapshot;
            const needed = required_frames orelse @min(source.identity.minimum_playable_frames, end - start);
            const required_end = try std.math.add(u64, start, needed);
            if (required_end > end) return error.InvalidSnapshot;
            const actual = facts.pcm_start == start and facts.pcm_end >= required_end and facts.available_frames >= needed;
            const consumed = source.ring.consumed.load(.acquire);
            const visible = source.ring.renderProduced();
            ready = actual and accepted.expected.ready and source.ready(start, loop_epoch) and visible >= consumed and visible - consumed >= needed and ready;
        }
        return ready;
    }
    /// Includes retiring windows until real Worker/visibility/Render custody is
    /// acknowledged. A cancellation intent alone never completes this count.
    pub fn requestWindowCount(self: *const Generation, request_id: u64) u32 {
        return self.requestWindowCountScoped(.request, request_id);
    }
    pub fn requestWindowCountScoped(self: *const Generation, scope: WindowScope, request_id: u64) u32 {
        var count: u32 = 0;
        for (self.windows) |entry| if (entry) |window| {
            count += @intFromBool(window.ownedBy(scope, request_id));
        };
        return count;
    }
    pub fn groupWindowCount(self: *const Generation, group: rt.GroupHandle) u32 {
        var count: u32 = 0;
        for (self.windows) |entry| if (entry) |window| if (window.group) |owned| {
            count += @intFromBool(owned.eql(group));
        };
        return count;
    }
    pub fn requestBindings(self: *Generation, request_id: u64) []const planner.StreamBinding {
        return self.requestBindingsScoped(.request, request_id);
    }
    pub fn requestBindingsScoped(self: *Generation, scope: WindowScope, request_id: u64) []const planner.StreamBinding {
        var count: usize = 0;
        for (self.windows) |entry| if (entry) |window| {
            if (window.retiring or !window.ownedBy(scope, request_id)) continue;
            self.binding_scratch[count] = window.binding;
            count += 1;
        };
        return self.binding_scratch[0..count];
    }
    /// A resumed fill and its automatic suffix deliberately share Director's
    /// request ID. The former's cue=0 continuity windows are already group-owned;
    /// only the latter's nonzero-cue candidates belong to entry preparation.
    pub fn entryBindings(self: *Generation, request_id: u64) ![]const planner.StreamBinding {
        const service = self.service orelse return error.InvalidState;
        var count: usize = 0;
        for (self.windows) |entry| if (entry) |window| {
            if (window.retiring or !window.ownedBy(.request, request_id) or window.binding.cue == 0 or window.group != null) continue;
            // Omit failed inputs rather than publishing invented readiness or
            // allowing a partially prefetched failed source to win. Planner
            // rejects any path requiring this missing exact occurrence. The
            // actual accepted Worker failure and window custody remain intact.
            if (try service.failure(window.binding.handle) != .none) continue;
            self.binding_scratch[count] = window.binding;
            count += 1;
        };
        return self.binding_scratch[0..count];
    }
    /// Exact retained initial cold candidate only. Ordinary entry helpers keep
    /// excluding bound windows. No replacement handles or global relaxation.
    pub fn validateRetainedColdStartBindings(self: *Generation, request_id: u64, entry: EntryWindow, group: rt.GroupHandle, bindings: *const [4]planner.StreamBinding) !void {
        const service = self.service orelse return error.InvalidState;
        var seen: [4]bool = @splat(false);
        var count: usize = 0;
        for (self.windows) |slot| if (slot) |window| {
            if (!window.ownedBy(.request, request_id)) continue;
            if (window.retiring or !entry.matches(window.binding) or
                window.group == null or !window.group.?.eql(group)) return error.InvalidState;
            const index = for (bindings, 0..) |binding, i| {
                if (std.meta.eql(binding, window.binding)) break i;
            } else return error.InvalidState;
            if (seen[index]) return error.InvalidState;
            if (try service.failure(window.binding.handle) != .none) return error.SourceReadFailed;
            seen[index] = true;
            count += 1;
        };
        if (count != 4) return error.InvalidState;
    }
    /// Explicit bound-linear path only. Borrow the already-playing group's
    /// exact handles for Planner's source-tail key; no Window, consumer, decoder
    /// or seek is created. The immutable original start_cursor must survive:
    /// ReadinessSnapshot verifies it against the real Service identity, while
    /// Planner compares the genuine current PCM interval with the exit cue.
    pub fn linearCrossfadeEntryBindings(self: *Generation, request_id: u64, rule_id: u64, source_group: rt.GroupHandle, source_segment: u64) ![]const planner.StreamBinding {
        const service = self.service orelse return error.InvalidState;
        if (request_id == 0 or source_group.generation == 0) return error.InvalidState;
        const t = self.loaded.tables;
        const rule = for (t.transitions) |candidate| {
            if (candidate.key.id == rule_id) break candidate;
        } else return error.InvalidMusicGraph;
        if (rule.fade_ticks == 0 or rule.overlap_frames == 0 or rule.paths.count != 1 or rule.fill != s.none or rule.paths.first >= t.transition_paths.len) return error.UnsupportedCapability;
        const path = t.transition_paths[rule.paths.first];
        if (path.fill != s.none or path.handoff != .continuous or path.source_exit >= t.cues.len) return error.UnsupportedCapability;
        const exit = t.cues[path.source_exit];
        if (exit.segment >= t.segments.len or t.segments[exit.segment].key.id != source_segment) return error.InvalidMusicGraph;
        const segment = t.segments[exit.segment];
        if (segment.storage != .streaming or self.groupWindowCount(source_group) != segment.layers.count) return error.InvalidState;
        var count = (try self.entryBindings(request_id)).len;
        for (t.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            const window = try self.liveGroupWindow(source_group, source_segment, layer.key.id);
            if (window.binding.sound != t.sounds[layer.sound].key.id) return error.InvalidState;
            if (try service.failure(window.binding.handle) != .none) return error.SourceReadFailed;
            const source = try service.renderSource(window.binding.handle);
            if (!source.validate() or source.identity.asset_generation != self.runtime_generation or source.identity.start_cursor != window.binding.source_cursor) return error.InvalidState;
            var alias = window.binding;
            alias.cue = exit.key.id;
            alias.occurrence = 0;
            for (self.binding_scratch[0..count]) |prior| {
                if (std.meta.eql(prior.handle, alias.handle) or
                    (prior.layer == alias.layer and prior.segment == alias.segment and prior.cue == alias.cue and prior.occurrence == alias.occurrence)) return error.InvalidState;
            }
            if (count == self.binding_scratch.len) return error.ResourceLimitExceeded;
            self.binding_scratch[count] = alias;
            count += 1;
        }
        return self.binding_scratch[0..count];
    }
    fn liveGroupWindow(self: *const Generation, group: rt.GroupHandle, segment: u64, layer: u64) !Window {
        var found: ?Window = null;
        for (self.windows) |entry| if (entry) |window| {
            const owned = window.group orelse continue;
            if (!owned.eql(group) or window.binding.layer != layer) continue;
            if (found != null or window.retiring or window.binding.segment != segment) return error.InvalidState;
            found = window;
        };
        return found orelse error.InvalidState;
    }
    /// Structural classification only. An actual one-loop source certificate
    /// is collected separately; this never treats metadata as visible PCM.
    pub fn crossfadeLoopTailLayout(self: *const Generation, rule_id: u64) !?bank.transition_validation.BoundedDirectTailLayout {
        const t = self.loaded.tables;
        const rule = for (t.transitions) |candidate| {
            if (candidate.key.id == rule_id) break candidate;
        } else return error.InvalidMusicGraph;
        if (rule.fade_ticks == 0) return null;
        if (rule.paths.count != 1 or rule.paths.first >= t.transition_paths.len) return error.UnsupportedCapability;
        const layout = try bank.transition_validation.boundedDirectTailLayout(t, t.transition_paths[rule.paths.first], t.platforms[self.loaded.metadata.profile]);
        return if (layout.crosses_loop) layout else null;
    }

    /// Copy genuine candidate-independent values from the original four rings.
    /// B is deliberately absent. Initial capture requires a coherent completed
    /// Render observation; Planner alone derives the candidate's fixed bounds.
    pub fn collectLoopCrossfadeSource(self: *Generation, out: *planner.LiveSourceTailSnapshot, source_group: rt.GroupHandle, source_segment: u64, context: u64, transport_epoch: u64, source_incarnation: u64, position: @FieldType(planner.LiveSourceTailSnapshot, "position"), observed: rt.MusicGroupObservation) !bool {
        out.* = .{};
        const service = self.service orelse return error.InvalidState;
        if (!service.runtime_attached or source_group.generation == 0 or context == 0 or transport_epoch == 0 or source_incarnation != 1 or
            !observed.group.eql(source_group) or observed.generation != self.runtime_generation or observed.transport_epoch != transport_epoch or
            observed.source_incarnation != source_incarnation or observed.layer_count != planner.live_source_layers) return error.InvalidState;
        if (observed.paused or observed.state != .playing) return false;
        const segment = for (self.loaded.tables.segments) |candidate| {
            if (candidate.key.id == source_segment) break candidate;
        } else return error.InvalidMusicGraph;
        if (segment.storage != .streaming or segment.layers.count != planner.live_source_layers or self.groupWindowCount(source_group) != planner.live_source_layers or segment.loop_end <= segment.loop_start) return error.InvalidState;
        const loop: rt.music_group.Loop = .{ .start = segment.loop_start, .end = segment.loop_end };
        if (observed.loop == null or !std.meta.eql(observed.loop.?, loop)) return error.InvalidState;
        const sequence = service.observation_sequence.load(.acquire);
        if (sequence & 1 != 0 or service.observation_frame.load(.acquire) != observed.frame) return false;
        var sources: [planner.live_source_layers]streaming.Source = undefined;
        out.* = .{
            .context = context,
            .asset_generation = self.runtime_generation,
            .transport_epoch = transport_epoch,
            .source_segment = source_segment,
            .group = .{ .index = source_group.index, .generation = source_group.generation, .stable_id = source_group.generation },
            .source_incarnation = source_incarnation,
            .position = position,
            .observed_frame = observed.frame,
            .cursor = observed.cursor,
            .loop_epoch = observed.loop_epoch,
            .loop = .{ .start = loop.start, .end = loop.end },
            .observation_sequence = sequence,
            .playing = true,
            .paused = false,
            .stream_profile = service.profile,
        };
        for (self.loaded.tables.layers[segment.layers.first..][0..segment.layers.count], 0..) |layer, index| {
            const window = try self.liveGroupWindow(source_group, source_segment, layer.key.id);
            const sound = self.loaded.tables.sounds[layer.sound];
            if (layer.required != 1 or sound.storage != .streaming or window.binding.sound != sound.key.id or observed.layers[index].state != .real or observed.layers[index].stream_generation != window.binding.handle.generation) return error.InvalidState;
            const failure = try service.failure(window.binding.handle);
            if (failure != .none) return error.SourceReadFailed;
            const source = try service.renderSource(window.binding.handle);
            const references = source.ring.references.load(.acquire);
            if (!source.validate() or !source.ring.gated or references != 1 or
                source.identity.asset != sound.key.id or source.identity.asset_generation != self.runtime_generation or
                source.identity.transport_epoch != transport_epoch or source.identity.stream_generation != window.binding.handle.generation or
                source.identity.start_cursor != window.binding.source_cursor or source.identity.frame_count != sound.frames or
                source.identity.profile_id != service.profile.id or !std.mem.eql(u8, &source.identity.profile_hash, &service.profile.hash()) or
                !std.mem.eql(u8, &source.identity.encoded_hash, &sound.audio_hash)) return error.InvalidState;
            const expected_loop: streaming.Loop = .{ .start = try std.math.add(u64, layer.source_start, loop.start), .end = try std.math.add(u64, layer.source_start, loop.end) };
            if (source.identity.loop == null or !std.meta.eql(source.identity.loop.?, expected_loop)) return error.InvalidState;
            const consumed = source.ring.consumed.load(.acquire);
            const control_consumed = source.ring.control_consumed.load(.acquire);
            if (consumed != control_consumed) return false;
            const coordinate = source.ring.coordinate(consumed) orelse return error.ArithmeticOverflow;
            if (coordinate.cursor != try std.math.add(u64, layer.source_start, observed.cursor) or coordinate.loop_epoch != observed.loop_epoch) return false;
            const visible = source.ring.renderProduced();
            if (visible < consumed or visible - consumed > source.ring.capacity_frames) return false;
            out.layers[index] = .{ .layer = layer.key.id, .sound = sound.key.id, .handle = window.binding.handle, .identity = source.identity, .consumed = consumed, .control_consumed = control_consumed, .visible_produced = visible, .capacity_frames = source.ring.capacity_frames, .real = true, .gated = true, .stopped = false, .references = references, .failure = failure };
            sources[index] = source;
        }
        for (sources, out.layers) |source, captured| {
            if (source.ring.stopped.load(.acquire) or source.ring.consumed.load(.acquire) != captured.consumed or source.ring.control_consumed.load(.acquire) != captured.control_consumed) return false;
        }
        if (sequence != service.observation_sequence.load(.acquire) or service.observation_frame.load(.acquire) != observed.frame) return false;
        out.count = planner.live_source_layers;
        out.complete = true;
        return true;
    }

    /// Independent last check of the original immutable obligation. Prefix
    /// consumption may advance to onset; it cannot overwrite an unread suffix.
    /// The fresh values never replace the issued snapshot or its digest.
    pub fn loopCrossfadeSourceStillReady(self: *Generation, snapshot: *const planner.LiveSourceTailSnapshot, obligation: *const planner.LiveSourceTailObligation, observed: rt.MusicGroupObservation, onset_frame: u64) !bool {
        if (obligation.version != planner.source_tail_proof_version or obligation.count != planner.live_source_layers or
            !std.mem.eql(u8, &obligation.snapshot_digest, &(try snapshot.digest())) or !std.meta.eql(obligation.group, snapshot.group) or
            obligation.source_incarnation != snapshot.source_incarnation or obligation.observed_frame != snapshot.observed_frame or
            obligation.observed.cursor != snapshot.cursor or obligation.observed.loop_epoch != snapshot.loop_epoch) return error.InvalidState;
        if (observed.frame < snapshot.observed_frame or observed.frame > onset_frame) return false;
        var current: planner.LiveSourceTailSnapshot = undefined;
        const group: rt.GroupHandle = .{ .index = snapshot.group.index, .generation = snapshot.group.generation };
        if (!try self.collectLoopCrossfadeSource(&current, group, snapshot.source_segment, snapshot.context, snapshot.transport_epoch, snapshot.source_incarnation, snapshot.position, observed)) return false;
        for (snapshot.layers, current.layers, obligation.layers) |old, actual, required| {
            if (required.layer != old.layer or required.sound != old.sound or !std.meta.eql(required.handle, old.handle) or required.consumed != old.consumed or
                actual.layer != old.layer or actual.sound != old.sound or !std.meta.eql(actual.handle, old.handle) or !std.meta.eql(actual.identity, old.identity) or actual.capacity_frames != old.capacity_frames or
                required.onset_ordinal != try std.math.add(u64, old.consumed, onset_frame - snapshot.observed_frame) or required.end_ordinal <= required.onset_ordinal) return error.InvalidState;
            if (actual.consumed < old.consumed or actual.consumed > required.onset_ordinal or actual.visible_produced < required.end_ordinal or
                actual.consumed - old.consumed != observed.frame - snapshot.observed_frame) return false;
        }
        return true;
    }

    /// Additional live-source proof, never a replacement for Planner/verifyPcm.
    /// Caller supplies the actual coherent lower observation for the exact
    /// active group, then publishes only the admitted bound-linear projection.
    /// Accepted Worker PCM is insufficient: every original consuming ring must
    /// already expose [observed.frame, onset_frame + fade_frames) to Render.
    /// Concurrent progress yields false; no wait, allocation or source reset.
    pub fn linearCrossfadeSourceTailReady(self: *Generation, source_group: rt.GroupHandle, source_segment: u64, transport_epoch: u64, source_incarnation: u64, observed: rt.MusicGroupObservation, onset_frame: u64, fade_frames: u32) !bool {
        const service = self.service orelse return error.InvalidState;
        if (!service.runtime_attached or source_group.generation == 0 or transport_epoch == 0 or source_incarnation != 1 or fade_frames == 0 or
            !observed.group.eql(source_group) or observed.generation != self.runtime_generation or observed.transport_epoch != transport_epoch or
            observed.source_incarnation != source_incarnation or observed.layer_count == 0 or observed.layer_count > rt.music_group.max_layers) return error.InvalidState;
        if (observed.paused or observed.state != .playing or onset_frame < observed.frame) return false;
        const segment = for (self.loaded.tables.segments) |candidate| {
            if (candidate.key.id == source_segment) break candidate;
        } else return error.InvalidMusicGraph;
        if (segment.storage != .streaming or observed.layer_count != segment.layers.count or self.groupWindowCount(source_group) != segment.layers.count) return error.InvalidState;
        const expected_loop: ?rt.music_group.Loop = if (segment.loop_end > segment.loop_start) .{ .start = segment.loop_start, .end = segment.loop_end } else null;
        if (!std.meta.eql(observed.loop, expected_loop)) return error.InvalidState;
        const fade_end = try std.math.add(u64, onset_frame, fade_frames);
        const needed = fade_end - observed.frame;
        const source_end = if (expected_loop) |loop| loop.end else segment.frames;
        if (observed.cursor >= source_end or needed > source_end - observed.cursor) return false;
        const sequence = service.observation_sequence.load(.acquire);
        if (sequence & 1 != 0 or service.observation_frame.load(.acquire) != observed.frame) return false;
        var sources: [rt.music_group.max_layers]streaming.Source = undefined;
        var ordinals: [rt.music_group.max_layers]u64 = undefined;
        for (self.loaded.tables.layers[segment.layers.first..][0..segment.layers.count], 0..) |layer, index| {
            const window = try self.liveGroupWindow(source_group, source_segment, layer.key.id);
            const sound = self.loaded.tables.sounds[layer.sound];
            if (sound.storage != .streaming or window.binding.sound != sound.key.id or observed.layers[index].state != .real or
                observed.layers[index].stream_generation != window.binding.handle.generation) return error.InvalidState;
            if (try service.failure(window.binding.handle) != .none) return error.SourceReadFailed;
            const source = try service.renderSource(window.binding.handle);
            if (!source.validate() or !source.ring.gated or source.ring.references.load(.acquire) != 1 or
                source.identity.asset != sound.key.id or source.identity.asset_generation != self.runtime_generation or
                source.identity.transport_epoch != transport_epoch or source.identity.stream_generation != window.binding.handle.generation or
                source.identity.start_cursor != window.binding.source_cursor or source.identity.frame_count != sound.frames or
                source.identity.profile_id != service.profile.id or !std.mem.eql(u8, &source.identity.profile_hash, &service.profile.hash()) or
                !std.mem.eql(u8, &source.identity.encoded_hash, &sound.audio_hash)) return error.InvalidState;
            const expected_source_loop: ?streaming.Loop = if (expected_loop) |loop| .{
                .start = try std.math.add(u64, layer.source_start, loop.start),
                .end = try std.math.add(u64, layer.source_start, loop.end),
            } else null;
            if (!std.meta.eql(source.identity.loop, expected_source_loop)) return error.InvalidState;
            const consumed = source.ring.consumed.load(.acquire);
            if (consumed != source.ring.control_consumed.load(.acquire)) return false;
            const coordinate = source.ring.coordinate(consumed) orelse return false;
            const cursor = try std.math.add(u64, layer.source_start, observed.cursor);
            if (coordinate.cursor != cursor or coordinate.loop_epoch != observed.loop_epoch or needed > source.ring.capacity_frames) return false;
            const required_end = try std.math.add(u64, consumed, needed);
            const visible = source.ring.renderProduced();
            if (visible < required_end) return false;
            // The last rendered sample, not the exclusive terminal coordinate,
            // must remain in this media/loop epoch. Equality at the boundary is
            // a separate scheduler/terminal-order qualification obligation.
            const last = source.ring.coordinate(required_end - 1) orelse return false;
            if (last.loop_epoch != observed.loop_epoch or last.cursor != try std.math.add(u64, cursor, needed - 1)) return false;
            sources[index] = source;
            ordinals[index] = consumed;
        }
        for (sources[0..observed.layer_count], ordinals[0..observed.layer_count]) |source, consumed| {
            if (source.ring.stopped.load(.acquire) or source.ring.consumed.load(.acquire) != consumed) return false;
        }
        return sequence == service.observation_sequence.load(.acquire) and service.observation_frame.load(.acquire) == observed.frame;
    }
    /// Called only for an exact path the Planner just evaluated. This reads
    /// real failure facts for its required occurrence keys, not timing or rank.
    pub fn pathEntryFailed(self: *Generation, request_id: u64, path_index: u32) !bool {
        const t = self.loaded.tables;
        if (path_index >= t.transition_paths.len) return error.InvalidMusicGraph;
        const path = t.transition_paths[path_index];
        const steps: []const s.FillStep = if (path.fill == s.none) &.{} else t.fill_steps[t.fills[path.fill].steps.first..][0..t.fills[path.fill].steps.count];
        for (steps, 0..) |step, index| {
            var occurrence: u16 = 0;
            for (steps[0..index]) |prior| if (prior.segment == step.segment and prior.entry == step.entry) {
                occurrence += 1;
            };
            if (try self.entryWindowFailed(request_id, .{ .segment = t.segments[step.segment].key.id, .cue = t.cues[step.entry].key.id, .occurrence = occurrence })) return true;
        }
        const target = t.cues[path.target_entry];
        var occurrence: u16 = 0;
        for (steps) |step| if (step.segment == target.segment and step.entry == path.target_entry) {
            occurrence += 1;
        };
        return self.entryWindowFailed(request_id, .{ .segment = t.segments[target.segment].key.id, .cue = target.key.id, .occurrence = occurrence });
    }
    fn entryWindowFailed(self: *Generation, request_id: u64, entry: EntryWindow) !bool {
        const service = self.service orelse return false;
        for (self.windows) |value| if (value) |window| {
            if (window.retiring or !window.ownedBy(.request, request_id) or !entry.matches(window.binding)) continue;
            if (window.group != null) return error.InvalidState;
            if (try service.failure(window.binding.handle) != .none) return true;
        };
        return false;
    }
    /// Direct restore/resume selects only the cue-zero physical window. Saved
    /// suffix entries can share the request and layer but never its consumer.
    pub fn sourceFor(self: *Generation, request_id: u64, layer: u64) !streaming.Source {
        return self.sourceForScoped(.request, request_id, layer);
    }
    pub fn sourceForScoped(self: *Generation, scope: WindowScope, request_id: u64, layer: u64) !streaming.Source {
        var handle: ?streaming.Handle = null;
        for (self.windows) |entry| if (entry) |window| {
            if (window.retiring or !window.ownedBy(scope, request_id) or window.binding.cue != 0 or window.binding.layer != layer) continue;
            if (handle != null) return error.InvalidState;
            handle = window.binding.handle;
        };
        return self.service.?.renderSource(handle orelse return error.InvalidState);
    }
    pub fn sourceForEntry(self: *Generation, request_id: u64, entry: EntryWindow, layer: u64, source_cursor: u64) !streaming.Source {
        return self.sourceForEntryScoped(.request, request_id, entry, layer, source_cursor);
    }
    pub fn sourceForEntryScoped(self: *Generation, scope: WindowScope, request_id: u64, entry: EntryWindow, layer: u64, source_cursor: u64) !streaming.Source {
        var handle: ?streaming.Handle = null;
        for (self.windows) |value| if (value) |window| {
            if (window.retiring or !window.ownedBy(scope, request_id) or window.binding.layer != layer or !entry.matches(window.binding)) continue;
            if (handle != null or window.binding.source_cursor != source_cursor) return error.InvalidState;
            handle = window.binding.handle;
        };
        return self.service.?.renderSource(handle orelse return error.InvalidState);
    }
    /// Establish the exact occurrence's physical owner before schedule
    /// publication. The complete preflight prevents partial reassignment.
    pub fn bindEntryWindows(self: *Generation, request_id: u64, entry: EntryWindow, group: rt.GroupHandle) !void {
        for (self.windows) |value| if (value) |window| {
            if (window.retiring or !window.ownedBy(.request, request_id) or !entry.matches(window.binding)) continue;
            if (window.group) |owned| if (!owned.eql(group)) return error.InvalidState;
        };
        for (&self.windows) |*value| if (value.*) |*window| {
            if (!window.retiring and window.ownedBy(.request, request_id) and entry.matches(window.binding)) window.group = group;
        };
    }
    /// The restored physical source and each saved occurrence have independent
    /// consumers even when they share a request, segment, cue or stem asset.
    pub fn bindPhysicalWindows(self: *Generation, request_id: u64, group: rt.GroupHandle) !void {
        return self.bindPhysicalWindowsScoped(.request, request_id, group);
    }
    pub fn bindPhysicalWindowsScoped(self: *Generation, scope: WindowScope, request_id: u64, group: rt.GroupHandle) !void {
        try self.bindRestoreWindows(scope, request_id, null, group, false);
    }
    pub fn bindExecutedPhysicalWindows(self: *Generation, request_id: u64, group: rt.GroupHandle) !void {
        return self.bindExecutedPhysicalWindowsScoped(.request, request_id, group);
    }
    pub fn bindExecutedPhysicalWindowsScoped(self: *Generation, scope: WindowScope, request_id: u64, group: rt.GroupHandle) !void {
        try self.bindRestoreWindows(scope, request_id, null, group, true);
    }
    pub fn bindExecutedEntryWindows(self: *Generation, request_id: u64, entry: EntryWindow, group: rt.GroupHandle) !void {
        if (entry.cue == 0) return error.InvalidState;
        try self.bindRestoreWindows(.request, request_id, entry, group, true);
    }
    /// Executed receipts still attribute retiring windows to their exact group;
    /// they never reopen admission. Validate all owners before changing any.
    fn bindRestoreWindows(self: *Generation, scope: WindowScope, request_id: u64, entry: ?EntryWindow, group: rt.GroupHandle, executed: bool) !void {
        for (self.windows) |value| if (value) |window| {
            if (!window.ownedBy(scope, request_id) or (!executed and window.retiring)) continue;
            if (entry) |key| {
                if (!key.matches(window.binding)) continue;
            } else if (window.binding.cue != 0) continue;
            if (window.group) |owned| if (!owned.eql(group)) return error.InvalidState;
        };
        for (&self.windows) |*value| if (value.*) |*window| {
            if (!window.ownedBy(scope, request_id) or (!executed and window.retiring)) continue;
            if (entry) |key| {
                if (!key.matches(window.binding)) continue;
            } else if (window.binding.cue != 0) continue;
            window.group = group;
        };
    }
    /// Only selected occurrences were assigned a prepared group. Other
    /// candidates still own their real Worker/visibility obligations until close.
    pub fn retireUnboundRequestWindows(self: *Generation, request_id: u64) void {
        for (&self.windows) |*entry| if (entry.*) |*window| {
            if (window.ownedBy(.request, request_id) and window.binding.cue != 0 and window.group == null) window.retiring = true;
        };
    }
    pub fn bindRequestWindows(self: *Generation, request_id: u64, group: rt.GroupHandle) void {
        return self.bindRequestWindowsScoped(.request, request_id, group);
    }
    pub fn bindRequestWindowsScoped(self: *Generation, scope: WindowScope, request_id: u64, group: rt.GroupHandle) void {
        for (&self.windows) |*entry| if (entry.*) |*window| {
            if (!window.retiring and window.ownedBy(scope, request_id)) window.group = group;
        };
    }
    /// An actual executed phase attributes its windows even when an earlier
    /// cancellation/retirement request already closed their admission. This
    /// records lifetime ownership only; it never reopens a retiring window.
    pub fn bindExecutedRequestWindows(self: *Generation, request_id: u64, group: rt.GroupHandle) void {
        return self.bindExecutedRequestWindowsScoped(.request, request_id, group);
    }
    pub fn bindExecutedRequestWindowsScoped(self: *Generation, scope: WindowScope, request_id: u64, group: rt.GroupHandle) void {
        for (&self.windows) |*entry| if (entry.*) |*window| {
            if (window.ownedBy(scope, request_id)) {
                std.debug.assert(window.group == null or window.group.?.eql(group));
                window.group = group;
            }
        };
    }
    pub fn retireRequestWindows(self: *Generation, request_id: u64) void {
        return self.retireRequestWindowsScoped(.request, request_id);
    }
    pub fn retireRequestWindowsScoped(self: *Generation, scope: WindowScope, request_id: u64) void {
        for (&self.windows) |*entry| if (entry.*) |*window| {
            if (window.ownedBy(scope, request_id)) window.retiring = true;
        };
    }
    /// Abandoning an entry proposal never cancels the resumed source that has
    /// the same request ID. Already selected occurrence groups still retire via
    /// their retained real group/scheduler/Service leases.
    pub fn retireEntryRequestWindows(self: *Generation, request_id: u64) void {
        for (&self.windows) |*entry| if (entry.*) |*window| {
            if (window.ownedBy(.request, request_id) and window.binding.cue != 0) window.retiring = true;
        };
    }
    pub fn retireGroupWindows(self: *Generation, group: rt.GroupHandle) void {
        for (&self.windows) |*entry| if (entry.*) |*window| {
            if (window.group) |owned| if (std.meta.eql(owned, group)) {
                window.retiring = true;
            };
        };
    }
    /// No provider I/O occurs here. Service.close itself retains a stream when
    /// workers, accepted visibility, Render, or prepared-source leases remain.
    pub fn collectWindows(self: *Generation) !void {
        const service = self.service orelse return;
        for (&self.windows, 0..) |*entry, window_index| if (entry.*) |*window| {
            var read: streaming.stream.readiness_observation.WindowRead = .{
                .handle = window.binding.handle,
                .runtime_generation = self.runtime_generation,
                .request_id = window.request_id,
                .window_index = @intCast(window_index),
                .group = if (window.group) |group| .{ .index = group.index, .generation = group.generation } else null,
                .retiring = window.retiring,
            };
            // Lower source retirement can stop/release this exact stream after
            // an acquired terminal/frontier proof, yet whole-group release can
            // still wait for desired completions or controller custody. Do not
            // keep admitting supply until that unrelated final credit returns.
            // ringFor validates the complete live Service handle; no stale-slot
            // inference or swallowed request error substitutes for this proof.
            if (!read.retiring) {
                read.ring_lookup_reached = true;
                const ring = service.ringFor(window.binding.handle) catch |err| {
                    read.error_code = @intFromError(err);
                    _ = service.observeReadinessLifecycle(.{ .window = read });
                    return err;
                };
                const stopped = ring.stopped.load(.acquire);
                read.stopped = stopped;
                if (!stopped) {
                    _ = service.observeReadinessLifecycle(.{ .window = read });
                    continue;
                }
                window.retiring = true;
                read.marked_retiring = true;
            }
            read.invokes_cancel = true;
            // Publish the containing actual read before entering nested
            // observed Service operations. Only owned scalar copies survive.
            const parent_attempt = service.observeReadinessLifecycle(.{ .window = read });
            try service.cancelObserved(read.handle, parent_attempt);
            service.closeObserved(read.handle, parent_attempt) catch |err| switch (err) {
                error.DrainPending => continue,
                else => return err,
            };
            entry.* = null;
            _ = service.observeReadinessLifecycle(.{ .window_return = .{
                .parent_attempt = parent_attempt,
                .handle = read.handle,
                .runtime_generation = read.runtime_generation,
                .request_id = read.request_id,
                .window_index = read.window_index,
            } });
        };
    }
    /// Serialized Control retains the detached completion obligation for its
    /// exact windows. Registry and Service custody still own this Generation.
    /// Normal close/cancel and actual Worker completion remain prerequisites.
    pub fn acceptDetachedRetiringCompletion(self: *Generation, position: @import("sme-trace").schema.Position) !?streaming.stream.Accepted {
        const custody = self.service_custody orelse return error.InvalidState;
        if (self.service != custody.service or self.owns_service or custody.accepting or custody.service.runtime_attached) return error.InvalidState;
        self.assertControlCredits();
        const registry = self.registry orelse return error.InvalidState;
        const entry = try registry.get(self.registry_handle.?);
        if (entry.payload != self or entry.generation.value() != self.runtime_generation) return error.StaleAssetGeneration;
        for (self.windows) |window| if (window) |value| if (!value.retiring) return error.DrainPending;
        for (self.windows) |window| if (window) |value| {
            if (try custody.service.acceptCancelledCompletion(value.binding.handle, self.runtime_generation, position)) |accepted| return accepted;
        };
        return null;
    }
    pub fn prefetchWindows(self: *Generation, frame: u64) !void {
        return self.prefetchWindowsExcluding(null, frame);
    }
    /// Global supply covers both scopes. Until a recovery phase really executes,
    /// its candidate ledger alone owns prefetch and the first-failure boundary.
    /// Exclude only that exact scoped key, never every recovery or matching ID.
    pub fn prefetchWindowsExcluding(self: *Generation, excluded: ?WindowKey, frame: u64) !void {
        _ = try self.prefetchSelectedWindows(null, excluded, false, frame, false, null);
    }
    /// A preparation failure belongs to this request, not an unrelated active
    /// or retiring source that happens to be stored in the same generation.
    pub fn prefetchRequestWindows(self: *Generation, request_id: u64, frame: u64) !void {
        return self.prefetchRequestWindowsScoped(.request, request_id, frame);
    }
    pub fn prefetchRequestWindowsScoped(self: *Generation, scope: WindowScope, request_id: u64, frame: u64) !void {
        _ = try self.prefetchSelectedWindows(.{ .scope = scope, .request_id = request_id }, null, false, frame, false, null);
    }
    /// Exact recovery/request scope, using the existing typed live observation.
    pub fn prefetchRequestWindowsScopedLiveV1(self: *Generation, scope: WindowScope, request_id: u64, frame: u64) !?streaming.stream.LiveObservationDeferV1 {
        return self.prefetchSelectedWindows(.{ .scope = scope, .request_id = request_id }, null, false, frame, true, null);
    }
    pub fn prefetchEntryWindows(self: *Generation, request_id: u64, frame: u64) !void {
        _ = try self.prefetchSelectedWindows(.{ .scope = .request, .request_id = request_id }, null, true, frame, false, null);
    }
    /// Only the owner-validated first request may include its retained, bound
    /// but never submitted candidate. Each call revalidates current Tick custody.
    pub fn prefetchInitialEntryV1(self: *Generation, scope: anytype, request_id: u64, frame: u64) !void {
        for (self.windows) |entry| if (entry) |window| {
            if (window.retiring or !window.ownedBy(.request, request_id) or window.binding.cue == 0) continue;
            _ = try scope.prefetchInitialEntryV1(request_id, window.binding.handle, frame);
        };
    }
    pub fn prefetchEntryWindowsLiveV1(self: *Generation, request_id: u64, frame: u64) !?streaming.stream.LiveObservationDeferV1 {
        return self.prefetchSelectedWindows(.{ .scope = .request, .request_id = request_id }, null, true, frame, true, null);
    }
    pub fn prefetchWindowsLiveV1(self: *Generation, frame: u64) !?streaming.stream.LiveObservationDeferV1 {
        return self.prefetchWindowsExcludingLiveV1(null, frame);
    }
    pub fn prefetchWindowsExcludingLiveV1(self: *Generation, excluded: ?WindowKey, frame: u64) !?streaming.stream.LiveObservationDeferV1 {
        return self.prefetchSelectedWindows(null, excluded, false, frame, true, null);
    }
    pub fn prefetchStableActiveWindowsLiveV1(self: *Generation, excluded: ?WindowKey, frame: u64, active: ?rt.GroupHandle) !?streaming.stream.LiveObservationDeferV1 {
        return self.prefetchSelectedWindows(null, excluded, false, frame, true, active);
    }
    /// Chronology background fairness: every eligible window gets one actual
    /// supply opportunity. A typed defer is not a failure of the other stems.
    /// Request-scoped and legacy callers retain their first-defer contract.
    pub fn prefetchChronologyActiveWindowsLiveV1(self: *Generation, excluded: ?WindowKey, frame: u64, active: ?rt.GroupHandle) !?streaming.stream.LiveObservationDeferV1 {
        return self.prefetchSelectedWindowsPolicy(null, excluded, false, frame, true, active, true);
    }
    fn prefetchSelectedWindows(self: *Generation, selected: ?WindowKey, excluded: ?WindowKey, entry_only: bool, frame: u64, live: bool, active: ?rt.GroupHandle) !?streaming.stream.LiveObservationDeferV1 {
        return self.prefetchSelectedWindowsPolicy(selected, excluded, entry_only, frame, live, active, false);
    }
    fn prefetchSelectedWindowsPolicy(self: *Generation, selected: ?WindowKey, excluded: ?WindowKey, entry_only: bool, frame: u64, live: bool, active: ?rt.GroupHandle, complete_background_sweep: bool) !?streaming.stream.LiveObservationDeferV1 {
        const service = self.service orelse return null;
        var first_defer: ?streaming.stream.LiveObservationDeferV1 = null;
        for (self.windows) |entry| if (entry) |window| {
            if (window.retiring) continue;
            if (selected) |owned| if (!window.ownedBy(owned.scope, owned.request_id)) continue;
            if (excluded) |owned| if (window.ownedBy(owned.scope, owned.request_id)) continue;
            if (entry_only and (window.binding.cue == 0 or window.group != null)) continue;
            if (try service.failure(window.binding.handle) != .none) {
                // Cold entry failures are adjudicated after Planner's complete
                // search. Background supply must not preempt its route choice.
                // Bound/published/active and cue-zero continuity sources retain
                // their existing fatal supply behavior.
                if (window.group == null and window.binding.cue != 0) continue;
                return error.SourceReadFailed;
            }
            if (live) {
                const stable = if (active) |group| if (window.group) |bound| group.eql(bound) else false else false;
                switch (try (if (stable) service.prefetchActiveLiveV1(window.binding.handle, frame) else service.prefetchLiveV1(window.binding.handle, frame))) {
                    .submitted => {},
                    .deferred => |value| {
                        if (!complete_background_sweep) return value;
                        if (first_defer == null) first_defer = value;
                    },
                }
            } else _ = try service.prefetch(window.binding.handle, frame);
        };
        return first_defer;
    }
    pub fn windowCount(self: *const Generation) u32 {
        var count: u32 = 0;
        for (self.windows) |entry| count += @intFromBool(entry != null);
        return count;
    }
    /// Control calls only after actual group/stream retirement. No callback,
    /// file close or PCM free happens here. Failure leaves all intrinsic pins.
    pub fn requestRetirement(self: *Generation) !void {
        self.closePlayCustody();
        if (self.play_custody_funded) return error.DrainPending;
        // Control cannot retire provider/PCM storage while preparation/Pending
        // or an actual borrowed return still owns this exact generation.
        if (self.hasControlLeases() or self.hasPreparedGroupLeases() or self.hasSnapshotLeases()) return error.DrainPending;
        if (self.registry) |registry| if ((registry.get(self.registry_handle.?) catch unreachable).borrowed_resident_pcm != 0) return error.DrainPending;
        if (self.retirement.load(.acquire) != .active) return;
        if (self.windowCount() != 0) return error.DrainPending;
        for (self.owners) |*owner| {
            // Unload preserves the intrinsic pin; host-quiescent shutdown may
            // already have retired it. In either case all external refs are gone.
            const intrinsic: u32 = @intFromBool(!owner.retired.load(.acquire));
            if (owner.referenceCount() != intrinsic) return error.DrainPending;
        }
        for (self.sources) |*record| if (record.asset) |*asset| if (asset.references.load(.acquire) != 1) return error.DrainPending;
        for (self.owners) |*owner| owner.retire();
        for (self.sources) |*record| if (record.asset) |*asset| asset.retire();
        self.retirement.store(if (self.sources.len == 0) .acknowledged else .requested, .release);
    }
    /// One worker close attempt; successful tokens are removed exactly once.
    /// Failed tokens and all metadata stay owned for a later worker retry.
    pub fn workerRetireOne(self: *Generation) !bool {
        if (self.retirement.cmpxchgStrong(.requested, .closing, .acq_rel, .acquire) != null) return false;
        errdefer self.retirement.store(.requested, .release);
        while (self.close_cursor < self.sources.len) {
            const record = &self.sources[self.close_cursor];
            if (record.opened) |opened| {
                const closed = switch (record.provider.?) {
                    .v1 => |provider| provider.close(provider.context, opened.token),
                    .v2 => |binding| binding.provider.close(binding.provider.context, binding.token, opened.token),
                };
                closed catch |err| {
                    self.close_failed.store(true, .release);
                    return err;
                };
                record.opened = null;
                _ = self.closed_sources.fetchAdd(1, .release);
                self.close_cursor += 1;
                self.retirement.store(if (self.close_cursor == self.sources.len and self.source_binding == null) .acknowledged else .requested, .release);
                return true;
            }
            self.close_cursor += 1;
        }
        if (self.source_binding) |binding| {
            binding.provider.unbind(binding.provider.context, binding.token) catch |err| {
                self.close_failed.store(true, .release);
                return err;
            };
            self.source_binding = null;
        }
        self.retirement.store(.acknowledged, .release);
        return true;
    }
    pub fn retirementAcknowledged(self: *const Generation) bool {
        return self.retirement.load(.acquire) == .acknowledged;
    }
    pub fn sourceStorageBytes(self: *const Generation) usize {
        return self.sources.len * @sizeOf(SourceRecord);
    }

    pub fn activate(self: *Generation, config: Config) !void {
        if (self.runtime_generation == 0) return error.InvalidState;
        const d = try self.allocator.create(director.Director);
        errdefer self.allocator.destroy(d);
        const solver = try self.allocator.create(planner.Planner);
        errdefer self.allocator.destroy(solver);
        const plan = try self.allocator.create(planner.TransitionPlan);
        errdefer self.allocator.destroy(plan);
        const profile = self.loaded.tables.platforms[self.loaded.metadata.profile];
        const initial = self.loaded.tables.states[self.loaded.metadata.initial_state];
        const initial_segment = self.loaded.tables.themes[initial.theme].initial_segment;
        const build_id = buildId(self.loaded.content_hash);
        try d.init(self.allocator, .{ .tables = self.loaded.tables, .profile = profile, .bank_build_id = build_id, .seed = config.seed, .initial_state = initial.key.id, .initial_segment = self.loaded.tables.segments[initial_segment].key.id, .context = config.context, .asset_generation = self.runtime_generation });
        try solver.init(self.allocator, self.loaded.tables, profile, self.runtime_generation, build_id);
        errdefer solver.deinit();
        const layer_scratch = if (self.layer_owner != null) try self.allocator.create(director.Director) else null;
        errdefer if (layer_scratch) |value| self.allocator.destroy(value);
        const readiness = if (self.service != null) try self.allocator.create(planner.ReadinessSnapshot) else null;
        if (readiness) |value| {
            value.complete = false;
            value.count = 0;
        }
        self.readiness = readiness;
        self.director = d;
        self.layer_director_scratch = layer_scratch;
        self.solver = solver;
        self.scratch_plan = plan;
        self.transport = clock.Clock.init(solver.maps[self.loaded.tables.segments[initial_segment].tempo], 0);
    }

    pub fn destroy(self: *Generation) void {
        if (@import("builtin").is_test) std.debug.assert(self.test_live_bootstrap == null);
        std.debug.assert(self.source_binding == null);
        std.debug.assert(!self.hasControlLeases() and self.registry == null and self.registry_handle == null);
        if (self.sources.len != 0) {
            // Validated-only content has no external source custody to close.
            var opened = false;
            for (self.sources) |record| opened = opened or record.opened != null or record.asset != null;
            std.debug.assert(!opened or self.retirementAcknowledged());
        }
        std.debug.assert(self.windowCount() == 0);
        for (self.owners) |owner| if (!owner.stream_token) self.allocator.free(owner.samples);
        self.allocator.free(self.owners);
        self.allocator.free(self.sources);
        if (self.service_custody) |custody| {
            std.debug.assert(!self.owns_service and self.service == custody.service);
            custody.release();
        } else if (self.owns_service) if (self.service) |service| service.destroy() catch unreachable;
        if (self.solver) |solver| {
            solver.deinit();
            self.allocator.destroy(solver);
        }
        if (self.director) |d| self.allocator.destroy(d);
        if (self.layer_director_scratch) |value| self.allocator.destroy(value);
        if (self.scratch_plan) |plan| self.allocator.destroy(plan);
        if (self.readiness) |value| self.allocator.destroy(value);
        if (self.layer_owner) |owner| owner.destroy() catch unreachable;
        if (self.policies) |*value| value.deinit();
        self.allocator.free(self.stinger_history);
        self.loaded.deinit();
        self.allocator.free(self.retained_compiled);
        if (self.play_custody) |anchor| {
            std.debug.assert(!self.play_custody_funded);
            if (self.play_custody_bound) std.debug.assert(anchor.drained());
            self.allocator.destroy(anchor); // All source/foreign destination returns acquired.
        }
        self.allocator.destroy(self);
    }
};
fn restoreIndex(values: anytype, id: u64) !u32 {
    for (values, 0..) |value, index| if (value.key.id == id) return @intCast(index);
    return error.InvalidSnapshot;
}
fn buildId(hash: [32]u8) u64 {
    return std.mem.readInt(u64, hash[0..8], .little) | 1;
}
fn validateCapability(value: *const bank.MusicBank, allow_streaming: bool, profile: v1.PolicySupportV1, bindings: runtime_layers.ConfigV1, fill_pcm_mode: planner.FillPcmMode, release_reservation: bool, crossfades: crossfade_contract.ConfigV1) !void {
    // The explicit support profile validates every used feature before opening
    // sources. An admitted graph must later pass real Control/Render bootstrap;
    // unsupported records never fall back to the legacy aggregate bus path.
    const t = value.tables;
    const allow_bound_gain = bindings.bindings.len != 0;
    const allow_linear_crossfade = crossfades.bindings.len != 0;
    if (allow_linear_crossfade and (!allow_streaming or !release_reservation or
        profile != .disabled or value.bus_graph != null or s.policyEnabled(value.metadata) or
        t.fill_steps.len != 0)) return error.UnsupportedCapability;
    if (allow_linear_crossfade and allow_bound_gain and bindings.parameter_sampling != .accepted_only)
        return error.UnsupportedCapability;
    const stinger_profile = profile == .resident_stinger_v1;
    const duck_profile = profile == .duck_v1 or stinger_profile;
    if (profile != .disabled and !duck_profile) return error.UnsupportedCapability;
    if (!duck_profile and (s.policyEnabled(value.metadata) or value.bus_graph != null)) return error.UnsupportedCapability;
    if (t.stingers.len != 0 or t.sidechains.len != 0 or t.acoustic_profiles.len != 0 or t.bus_sends.len != 0) return error.UnsupportedCapability;
    if (s.policyEnabled(value.metadata)) {
        if ((!stinger_profile and t.stinger_policies.len != 0) or t.acoustic_policy_profiles.len != 0 or t.acoustic_policy_inputs.len != 0 or value.bus_graph == null) return error.UnsupportedCapability;
        // This explicit first stinger profile uses real resident one-shots.
        // Streaming stingers and associated start+duck transactions remain a
        // separate public extension; unsupported records reject before opens.
        for (t.stinger_policies) |entry| {
            const segment = t.segments[entry.segment];
            if (segment.storage != .resident or entry.duck_preset != s.none) return error.UnsupportedCapability;
            for (t.layers[segment.layers.first..][0..segment.layers.count]) |layer| if (t.sounds[layer.sound].storage != .resident) return error.UnsupportedCapability;
        }
        const graph = &value.bus_graph.?;
        if (graph.profile.duck_requests == 0 or graph.profile.duck_requests_per_bus == 0) return error.UnsupportedCapability;
        for (t.automation_duck_presets) |preset| {
            _ = try bank.music_policy_adapter.duckTarget(preset, 1);
            _ = try graph.graph.targetInfo(.{ .bus_gain = preset.bus });
        }
    } else if (value.bus_graph != null) return error.UnsupportedCapability;
    if (value.bus_graph) |graph| {
        // This initial owner uses the actual aggregate music adapter; per-layer
        // authored graph routes still require a separately owned binding.
        const output = for (graph.desc.buses) |bus| {
            if (bus.id == graph.desc.output_bus) break bus.layout;
        } else return error.UnsupportedCapability;
        if (!output.eql(rt.channel_layout.stereo)) return error.UnsupportedCapability;
    } else if (t.buses.len != 1 or t.buses[0].gain_db != 0 or t.buses[0].parent != s.none) return error.UnsupportedCapability;
    var bound_gain_fill = false;
    for (t.fills) |fill| {
        if (fill.steps.count > max_resident_fill_steps) return error.UnsupportedCapability;
        if (fill.steps.count != 0 and (value.bus_graph != null or s.policyEnabled(value.metadata))) return error.UnsupportedCapability;
        if (fill.steps.count != 0 and allow_bound_gain) {
            // This composition is deliberately narrower than unbound fills:
            // up to the existing two rolling steps with accepted input and
            // source-frame ramps. Every occurrence retains distinct custody.
            if (!release_reservation or !allow_streaming or fill_pcm_mode != .rolling_high_watermark or bindings.parameter_sampling != .accepted_only) return error.UnsupportedCapability;
            bound_gain_fill = true;
        }
        for (t.fill_steps[fill.steps.first..][0..fill.steps.count]) |step| {
            const segment = t.segments[step.segment];
            if (allow_bound_gain) {
                // The first composition is genuinely rolling, not a supplied
                // but unused provider or a full-span short-fill optimization.
                if (segment.storage != .streaming or t.cues[step.exit].frame - t.cues[step.entry].frame <= streaming.release_profile.high_frames) return error.UnsupportedCapability;
                for (t.layers[segment.layers.first..][0..segment.layers.count]) |layer|
                    if (t.sounds[layer.sound].storage != .streaming) return error.UnsupportedCapability;
            }
            if ((!allow_streaming and segment.storage != .resident) or step.overlap_frames != 0 or t.cues[step.entry].frame != 0 or t.cues[step.exit].tail_frames != 0) return error.UnsupportedCapability;
            // Preserve strict pre-provider admission. Only the explicit rolling
            // mode can admit a span longer than the bounded Service watermark;
            // it requires a separate genuine entry-window proof in Planner.
            for (t.layers[segment.layers.first..][0..segment.layers.count]) |layer| if (t.sounds[layer.sound].storage == .streaming) {
                if (!allow_streaming or (fill_pcm_mode == .full_span and t.cues[step.exit].frame - t.cues[step.entry].frame > streaming.release_profile.high_frames)) return error.UnsupportedCapability;
            };
        }
    }
    if (bound_gain_fill or allow_linear_crossfade) for (bindings.bindings) |binding| {
        inline for (.{ binding.ramps.attack, binding.ramps.release }) |duration| switch (duration) {
            .frames => {},
            .quarter_beats => return error.UnsupportedCapability,
        };
    };
    for (t.sounds) |sound| switch (sound.storage) {
        .resident => if (t.codecs[sound.codec].kind != .pcm_f32le or sound.blob_length != sound.frames * sound.channels * 4) return error.UnsupportedCapability,
        .streaming => if (!allow_streaming or t.codecs[sound.codec].kind != .ogg_opus) return error.UnsupportedCapability,
    };
    for (t.segments) |segment| {
        // Fallback/source-incarnation composition remains outside the bounded
        // rolling-fill gain contract, including fallbacks on future groups.
        if ((bound_gain_fill or allow_linear_crossfade) and segment.fallback_segment != s.none) return error.UnsupportedCapability;
        if ((!allow_streaming and segment.storage != .resident) or segment.layers.count == 0 or segment.layers.count > rt.music_group.max_layers) return error.UnsupportedCapability;
        for (t.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            if (layer.source_start != 0 or (!allow_bound_gain and layer.gain_curve != s.none) or layer.required != 1 or layer.bus != (if (value.bus_graph) |graph| graph.adapter.music_bus else @as(u32, 0)) or t.sounds[layer.sound].frames != segment.frames or layer.gain_db > 12) return error.UnsupportedCapability;
        }
    }
    for (t.transitions) |rule| {
        // The wire bank may retain unused empty fill records. Composition is
        // determined by actual rule/path references, never table presence.
        if (allow_linear_crossfade and rule.fill != s.none) return error.UnsupportedCapability;
        if (rule.sync != .next_bar and rule.sync != .authored_exit_cue) return error.UnsupportedCapability;
        if (crossfades.curveFor(rule.key.id)) |curve| {
            if ((curve != .linear and curve != .equal_power) or rule.fade_ticks == 0 or rule.overlap_frames == 0 or rule.paths.count == 0 or
                rule.fill != s.none or rule.fallback != .reject or rule.fallback_segment != s.none) return error.UnsupportedCapability;
        } else if (rule.fade_ticks != 0 or rule.overlap_frames != 0) return error.UnsupportedCapability;
    }
    for (t.transition_paths, 0..) |path, path_index| {
        if (path.transition >= t.transitions.len or path.source_exit >= t.cues.len or
            path.target_entry >= t.cues.len) return error.InvalidMusicGraph;
        if (allow_linear_crossfade and path.fill != s.none) return error.UnsupportedCapability;
        const rule = t.transitions[path.transition];
        if (crossfades.curveFor(rule.key.id) != null) {
            // Only a path genuinely referenced by its bound transition may use
            // this narrow lowering; unused path records gain no permission.
            const path_end = @as(u64, rule.paths.first) + rule.paths.count;
            if (path_index < rule.paths.first or path_index >= path_end or path.fill != s.none or path.handoff != .continuous) return error.UnsupportedCapability;
            const source_exit = t.cues[path.source_exit];
            const target_entry = t.cues[path.target_entry];
            if (source_exit.segment >= t.segments.len or target_entry.segment >= t.segments.len) return error.InvalidMusicGraph;
            const source = t.segments[source_exit.segment];
            const target = t.segments[target_entry.segment];
            if (target_entry.frame != 0 or source.storage != .streaming or target.storage != .streaming)
                return error.UnsupportedCapability;
            // SINGLE refers to one source/target group, not to one stem.
            for ([_]s.Segment{ source, target }) |segment| {
                for (t.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
                    if (t.sounds[layer.sound].storage != .streaming) return error.UnsupportedCapability;
                }
            }
            try bank.transition_validation.path(t, path, t.platforms[value.metadata.profile]);
            const map = try clock.Map.init(t, source.tempo, &.{}, t.platforms[value.metadata.profile]);
            if (try map.frameAtTick(source_exit.tick) != source_exit.frame) return error.InvalidMusicGraph;
            const layout = try bank.transition_validation.boundedDirectTailLayout(t, path, t.platforms[value.metadata.profile]);
            // One-loop tails are a separate, fixed-four-stream proof. Their
            // gain/continuity/fill composition is not inferred from the older
            // noncrossing profile's support.
            if (layout.crosses_loop and allow_bound_gain) return error.UnsupportedCapability;
            const frames = layout.fade_frames;
            if (frames > std.math.maxInt(u32) or frames > streaming.release_profile.high_frames or
                frames != source_exit.tail_frames or frames != rule.overlap_frames) return error.UnsupportedCapability;
            // Half-open PCM spans may end exactly at the current media/loop
            // boundary. Crossing it needs a different live-source proof.
            const source_end = if (source.loop_end > source.loop_start) source.loop_end else source.frames;
            const target_end = if (target.loop_end > target.loop_start) target.loop_end else target.frames;
            if ((!layout.crosses_loop and layout.terminal_cursor > source_end) or frames > target_end) return error.UnsupportedCapability;
        } else if (t.cues[path.source_exit].tail_frames != 0 or t.cues[path.target_entry].frame != 0) return error.UnsupportedCapability;
        if (path.fill != s.none and t.fills[path.fill].steps.count != 0) {
            if (path.handoff != .hard_cut) return error.UnsupportedCapability;
        }
    }
}

test "restored suffix window occurrences are local to equal segment and cue" {
    var entries: [3]save.Entry = undefined;
    for (&entries, 0..) |*entry, index| entry.* = .{ .segment = 11, .cue = 22, .distance = 100, .duration = 100, .cursor = 0, .tempo_span = 0, .occurrence = @intCast(index), .target = index == 2 };
    try std.testing.expectEqual(@as(u16, 2), restoreEntryWindow(&entries, 2).occurrence);
    try std.testing.expectEqual(@as(u16, 0), restoreEntryWindow(entries[1..], 0).occurrence);
    try std.testing.expectEqual(@as(u16, 1), restoreEntryWindow(entries[1..], 1).occurrence);
    entries[2].cue = 33;
    try std.testing.expectEqual(@as(u16, 0), restoreEntryWindow(&entries, 2).occurrence);
    entries[2].cue = 22;
    entries[2].segment = 44;
    try std.testing.expectEqual(@as(u16, 0), restoreEntryWindow(&entries, 2).occurrence);
}

test "restored physical and repeated entry windows retain separate executed owners" {
    var generation: Generation = undefined;
    generation.windows = @splat(null);
    const physical: rt.GroupHandle = .{ .index = 1, .generation = 1 };
    const first: rt.GroupHandle = .{ .index = 2, .generation = 2 };
    const second: rt.GroupHandle = .{ .index = 3, .generation = 3 };
    generation.windows[0] = .{ .request_id = 7, .binding = .{ .sound = 10, .layer = 11, .segment = 12, .cue = 0, .source_cursor = 1200, .handle = .{ .index = 0, .generation = 1 } } };
    generation.windows[1] = .{ .request_id = 7, .binding = .{ .sound = 10, .layer = 11, .segment = 12, .cue = 13, .source_cursor = 0, .handle = .{ .index = 1, .generation = 2 } } };
    generation.windows[2] = .{ .request_id = 7, .binding = .{ .sound = 10, .layer = 11, .segment = 12, .cue = 13, .occurrence = 1, .source_cursor = 0, .handle = .{ .index = 2, .generation = 3 } } };
    try generation.bindPhysicalWindows(7, physical);
    try generation.bindEntryWindows(7, .{ .segment = 12, .cue = 13 }, first);
    generation.retireRequestWindows(7);
    try generation.bindExecutedPhysicalWindows(7, physical);
    try generation.bindExecutedEntryWindows(7, .{ .segment = 12, .cue = 13 }, first);
    try generation.bindExecutedEntryWindows(7, .{ .segment = 12, .cue = 13, .occurrence = 1 }, second);
    try std.testing.expectEqual(@as(u32, 1), generation.groupWindowCount(physical));
    try std.testing.expectEqual(@as(u32, 1), generation.groupWindowCount(first));
    try std.testing.expectEqual(@as(u32, 1), generation.groupWindowCount(second));
    for (generation.windows[0..3]) |window| try std.testing.expect(window.?.retiring);
    try std.testing.expectError(error.InvalidState, generation.bindExecutedPhysicalWindows(7, first));
    try std.testing.expectError(error.InvalidState, generation.bindExecutedEntryWindows(7, .{ .segment = 12, .cue = 13 }, second));
}

test "restored executed ownership preflights every stem before assignment" {
    var generation: Generation = undefined;
    generation.windows = @splat(null);
    const intended: rt.GroupHandle = .{ .index = 1, .generation = 1 };
    const other: rt.GroupHandle = .{ .index = 2, .generation = 2 };
    generation.windows[0] = .{ .request_id = 7, .retiring = true, .binding = .{ .sound = 10, .layer = 11, .segment = 12, .cue = 13, .source_cursor = 0, .handle = .{ .index = 0, .generation = 1 } } };
    generation.windows[1] = .{ .request_id = 7, .group = other, .retiring = true, .binding = .{ .sound = 20, .layer = 21, .segment = 12, .cue = 13, .source_cursor = 0, .handle = .{ .index = 1, .generation = 2 } } };
    try std.testing.expectError(error.InvalidState, generation.bindExecutedEntryWindows(7, .{ .segment = 12, .cue = 13 }, intended));
    try std.testing.expect(generation.windows[0].?.group == null);
    try std.testing.expect(generation.windows[1].?.group.?.eql(other));
}
