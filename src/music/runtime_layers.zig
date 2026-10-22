//! Generation-owned prepared gain bindings for the public parameter owner.
//! This module never creates a scheduler, plan ID or mixer.
const std = @import("std");
const bank = @import("sme-bank");
const rt = @import("bugu_audio").runtime;
const layers = @import("sme-layers");
const v1 = @import("runtime_contract.zig");
const curves = @import("sme-layer-curves");
const s = bank.schema;
pub const binding_contract = @import("runtime_layer_contract.zig");
pub const BindingV1 = binding_contract.BindingV1;
pub const ConfigV1 = binding_contract.ConfigV1;
/// Own before publishing config to Worker. A host may immediately reuse its input.
pub const OwnedConfig = struct {
    allocator: std.mem.Allocator,
    value: ConfigV1,
    pub fn init(allocator: std.mem.Allocator, value: ConfigV1) !OwnedConfig {
        try value.validate();
        return .{ .allocator = allocator, .value = .{ .version = value.version, .bindings = try allocator.dupe(BindingV1, value.bindings), .parameter_sampling = value.parameter_sampling } };
    }
    pub fn deinit(self: *OwnedConfig) void {
        self.allocator.free(self.value.bindings);
        self.* = undefined;
    }
    pub fn ownedBytes(self: *const OwnedConfig) usize {
        return self.value.bindings.len * @sizeOf(BindingV1);
    }
};
const Resolved = struct { layer: u32, parameter: u32, binding: layers.Binding };
pub const Instance = struct {
    bank: v1.BankRefV1,
    segment: u32,
    group: rt.GroupHandle,
    source_incarnation: u64 = 1,
    controller_closed: bool = false,
    controller: layers.LayerController,
    parameters: [rt.music_group.max_layers]u32 = undefined,
    /// The source owner, not installation receipts, determines this boundary.
    retiring: bool = false,
    last_terminal: ?layers.PreparedTerminal = null,
    pending_request: ?struct { ticket: v1.RequestTicketV1, accepted: @import("sme-trace").schema.Position, program: layers.prepared_spans.ProgramHandle } = null,
    /// One bounded driver. Internal observations never mint another host input.
    driver: struct {
        enabled: bool = false,
        ticket: ?v1.RequestTicketV1 = null,
        accepted: ?@import("sme-trace").schema.Position = null,
        observed_frame: u64 = 0,
        observed_tick: u64 = 0,
        values: [rt.music_group.max_layers]i32 = @splat(0),
        pending: ?layers.prepared_spans.ProgramHandle = null,
        failure: ?v1.FailureV1 = null,
    } = .{},

    pub fn driverValuesChanged(self: *const Instance, values: []const i32) bool {
        for (self.parameters[0..self.controller.bindings.len], 0..) |parameter, i| if (self.driver.values[i] != values[parameter]) return true;
        return false;
    }
    pub fn observeDriverValues(self: *Instance, values: []const i32, frame: u64, tick: u64) void {
        for (self.parameters[0..self.controller.bindings.len], 0..) |parameter, i| self.driver.values[i] = values[parameter];
        self.driver.observed_frame = frame;
        self.driver.observed_tick = tick;
    }

    pub fn evaluate(self: *const Instance, values: []const i32, output: []layers.Update) ![]layers.Update {
        if (self.controller_closed or self.retiring) return error.InvalidState;
        const bindings = self.controller.bindings;
        if (output.len < bindings.len) return error.InvalidArgument;
        for (bindings, 0..) |binding, i| {
            const parameter = self.parameters[i];
            if (parameter >= values.len) return error.InvalidBinding;
            // Director values are the actual accepted/smoothed Q16.16 state.
            const input = @as(f64, @floatFromInt(values[parameter])) / 65536.0;
            const normalized = try curves.normalize(input, binding.input_minimum, binding.input_maximum);
            const gain = try self.controller.owned_curves.evaluate(binding.layer.gain_curve, normalized);
            output[i] = .{ .layer_id = binding.layer.key.id, .target = .{ .gain = try layers.contract.validateGain(gain, binding.output_policy) } };
        }
        return output[0..bindings.len];
    }
    pub fn collect(self: *Instance, scope: rt.ControlRuntime.TickV1) !layers.PreparedPoll {
        // pollPrepared can prepare a genuine cancellation-loser cleanup stop.
        // Consequently the owner invokes it only in its live prepare scope.
        try scope.requirePhase(.prepare);
        return self.collectPrepared(scope);
    }
    /// The enclosing MusicRuntime remains sole Control owner; the adapter also
    /// supports host-quiescent final collection through ordinary guarded APIs.
    pub fn collectPrepared(self: *Instance, control: anytype) !layers.PreparedPoll {
        if (self.controller_closed) return .{};
        try self.controller.retryPreparedRollback(control);
        const result = try self.controller.pollPrepared(control);
        if (result.terminal) |terminal| self.last_terminal = terminal;
        return result;
    }
    pub fn ownedBytes(self: *const Instance) usize {
        if (self.controller_closed) return @sizeOf(Instance);
        const controller = &self.controller;
        return @sizeOf(Instance) + controller.bindings.len * @sizeOf(layers.Binding) +
            controller.owned_curves.descriptors.len * @sizeOf(curves.Descriptor) +
            controller.owned_curves.points.len * @sizeOf(s.CurvePoint) + controller.preparedUsage().owned_heap_bytes;
    }
};
/// Generation owns a bounded original/fallback pair and refuses retirement until every
/// exact group instance is relinquished.
/// No Render pointer refers to this owner/controller; runtime deep copies hold
/// their own group/source leases until actual terminal/frontier release.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    content_hash: [32]u8,
    authored_generation: u64,
    runtime_generation: u64 = 0,
    reference: ?v1.BankRefV1 = null,
    observed_sampling: bool = false,
    bindings: []const Resolved,
    // These are pointers only. Controllers are allocated in place as real
    // groups are prepared, never a64-controller stack or heap temporary.
    instances: [rt.music_group.max_groups]?*Instance = @splat(null),
    fallback_instances: [rt.music_group.max_groups]?*Instance = @splat(null),
    instance_count: usize = 0,

    /// Runs before provider opens, against the genuine loaded compiled bank.
    pub fn create(allocator: std.mem.Allocator, loaded: *const bank.MusicBank, config: ConfigV1) !*Owner {
        try config.validate();
        const tables = loaded.tables;
        const profile = tables.platforms[loaded.metadata.profile];
        if (config.bindings.len > tables.layers.len or config.bindings.len > profile.max_table_records) return error.ResourceLimitExceeded;
        const resolved = try allocator.alloc(Resolved, config.bindings.len);
        errdefer allocator.free(resolved);
        for (config.bindings, resolved) |binding, *out| {
            const layer_index: u32 = for (tables.layers, 0..) |layer, i| {
                if (layer.key.id == binding.layer.value()) break @intCast(i);
            } else return error.InvalidBinding;
            const parameter_index: u32 = for (tables.parameters, 0..) |parameter, i| {
                if (parameter.key.id == binding.parameter.value()) break @intCast(i);
            } else return error.InvalidBinding;
            const layer = tables.layers[layer_index];
            if (layer.gain_curve == s.none or layer.gain_curve >= tables.curves.len or layer.segment >= tables.segments.len) return error.InvalidBinding;
            const segment = tables.segments[layer.segment];
            for (tables.stinger_policies) |stinger| if (stinger.segment == layer.segment) return error.UnsupportedCapability;
            if (layer_index < segment.layers.first or layer_index >= segment.layers.first + segment.layers.count or segment.layers.count > rt.music_group.max_layers) return error.InvalidBinding;
            const parameter = tables.parameters[parameter_index];
            // Default keeps accepted-only admission. The explicit profile uses
            // the actual Director at owned completed-frame observations.
            if (config.parameter_sampling == .accepted_only and (parameter.attack_frames != 0 or parameter.release_frames != 0)) return error.UnsupportedCapability;
            _ = try curves.normalize(0, parameter.minimum, parameter.maximum);
            const curve = tables.curves[layer.gain_curve];
            for (tables.curve_points[curve.points.first..][0..curve.points.count]) |point| _ = try layers.contract.validateGain(point.value, binding.output_policy);
            out.* = .{ .layer = layer_index, .parameter = parameter_index, .binding = .{
                .layer = layer,
                .ordinal = @intCast(layer_index - segment.layers.first),
                .input_minimum = parameter.minimum,
                .input_maximum = parameter.maximum,
                .input_stage = .accepted_smoothed,
                .output_policy = binding.output_policy,
                .ramps = binding.ramps,
            } };
        }
        for (tables.layers, 0..) |layer, index| if (layer.gain_curve != s.none) {
            var found = false;
            for (resolved) |binding| if (binding.layer == index) {
                found = true;
                break;
            };
            if (!found) return error.InvalidBinding;
        };
        const result = try allocator.create(Owner);
        result.* = .{ .allocator = allocator, .content_hash = loaded.content_hash, .authored_generation = loaded.metadata.generation, .bindings = resolved, .observed_sampling = config.parameter_sampling == .observed_control_v1 };
        return result;
    }
    pub fn adopt(self: *Owner, reference: v1.BankRefV1, runtime_generation: u64) !void {
        if (self.reference != null or reference.context == 0 or reference.handle.generation == 0 or runtime_generation == 0 or reference.asset_generation != runtime_generation) return error.InvalidState;
        self.runtime_generation = runtime_generation;
        self.reference = reference;
    }
    pub fn bindsSegment(self: *const Owner, segment: u32) bool {
        for (self.bindings) |binding| if (binding.binding.layer.segment == segment) return true;
        return false;
    }
    pub fn prepareGroup(self: *Owner, loaded: *const bank.MusicBank, group: rt.GroupHandle, segment: u32) !void {
        if (try self.controllerCount(group) != 0) return error.InvalidState;
        try self.prepareSource(loaded, group, segment, 1);
    }
    pub fn prepareFallbackGroup(self: *Owner, loaded: *const bank.MusicBank, group: rt.GroupHandle, segment: u32) !void {
        _ = try self.get(group);
        try self.prepareSource(loaded, group, segment, 2);
    }
    fn prepareSource(self: *Owner, loaded: *const bank.MusicBank, group: rt.GroupHandle, segment: u32, incarnation: u64) !void {
        const reference = self.reference orelse return error.InvalidState;
        if (group.index >= self.instances.len or group.generation == 0 or segment >= loaded.tables.segments.len or loaded.metadata.generation != self.authored_generation or !std.mem.eql(u8, &loaded.content_hash, &self.content_hash)) return error.InvalidState;
        const slot = switch (incarnation) {
            1 => &self.instances[group.index],
            2 => &self.fallback_instances[group.index],
            else => return error.InvalidArgument,
        };
        if (slot.* != null) return error.InvalidState;
        var bindings: [rt.music_group.max_layers]layers.Binding = undefined;
        var parameters: [rt.music_group.max_layers]u32 = undefined;
        var count: usize = 0;
        for (self.bindings) |binding| if (binding.binding.layer.segment == segment) {
            if (count == bindings.len) return error.ResourceLimitExceeded;
            bindings[count] = binding.binding;
            parameters[count] = binding.parameter;
            count += 1;
        };
        if (count == 0) return;
        const instance = try self.allocator.create(Instance);
        errdefer self.allocator.destroy(instance);
        instance.* = .{ .bank = reference, .segment = segment, .group = group, .source_incarnation = incarnation, .parameters = parameters, .controller = try layers.LayerController.initPrepared(self.allocator, .{ .group = group, .context = reference.context, .bank_generation = reference.asset_generation, .source_incarnation = incarnation }, bindings[0..count], loaded.tables.curves, loaded.tables.curve_points, loaded.tables.platforms[loaded.metadata.profile], .{}, .{}) };
        slot.* = instance;
        self.instance_count += 1;
    }
    /// Compatibility lookup always means the original source, including its
    /// retained retiring shell. Active submissions must use getSource.
    pub fn get(self: *Owner, group: rt.GroupHandle) !?*Instance {
        return self.getSource(group, 1);
    }
    pub fn getSource(self: *Owner, group: rt.GroupHandle, incarnation: u64) !?*Instance {
        if (group.index >= self.instances.len or group.generation == 0) return error.InvalidHandle;
        const instance = (switch (incarnation) {
            1 => self.instances[group.index],
            2 => self.fallback_instances[group.index],
            else => return error.InvalidHandle,
        }) orelse return null;
        if (!instance.group.eql(group) or instance.source_incarnation != incarnation or self.reference == null or !std.meta.eql(instance.bank, self.reference.?)) return error.InvalidHandle;
        return instance;
    }
    pub fn controllerCount(self: *Owner, group: rt.GroupHandle) !u8 {
        const original = try self.getSource(group, 1);
        const fallback = try self.getSource(group, 2);
        return @as(u8, @intFromBool(original != null)) + @as(u8, @intFromBool(fallback != null));
    }
    /// Called only after the source handoff is observed. Original pending
    /// requests and rollback/program terminals remain collectable in place.
    pub fn switchToFallback(self: *Owner, group: rt.GroupHandle) !?*Instance {
        const original = try self.getSource(group, 1);
        const fallback = try self.getSource(group, 2);
        if (fallback) |value| if (value.retiring or value.controller_closed) return error.InvalidState;
        if (original) |value| {
            value.retiring = true;
            value.driver.enabled = false;
        }
        return fallback;
    }
    /// The fallible half precedes physical group/source release. Keep both
    /// shells until all program cleanup and the physical group release finish.
    pub fn closeController(self: *Owner, group: rt.GroupHandle) !void {
        const original = try self.getSource(group, 1);
        const fallback = try self.getSource(group, 2);
        const pair = [_]?*Instance{ original, fallback };
        for (pair) |entry| if (entry) |instance| {
            instance.retiring = true;
            instance.driver.enabled = false;
        };
        var pending = false;
        for (pair) |entry| if (entry) |instance| {
            if (instance.controller_closed) continue;
            instance.controller.deinit() catch |err| switch (err) {
                error.PendingAutomation => {
                    pending = true;
                    continue;
                },
                else => return err,
            };
            instance.controller_closed = true;
        };
        if (pending) return error.DrainPending;
    }
    pub fn releaseClosedGroup(self: *Owner, group: rt.GroupHandle) !void {
        const original = try self.getSource(group, 1);
        const fallback = try self.getSource(group, 2);
        const pair = [_]?*Instance{ original, fallback };
        // Validate the complete pair before releasing either exact shell.
        for (pair) |entry| if (entry) |instance| {
            if (!instance.retiring or !instance.controller_closed) return error.InvalidState;
        };
        for (pair) |entry| if (entry) |instance| {
            self.instance_count -= 1;
            self.allocator.destroy(instance);
        };
        self.instances[group.index] = null;
        self.fallback_instances[group.index] = null;
    }
    pub fn releaseGroup(self: *Owner, group: rt.GroupHandle) !void {
        try self.closeController(group);
        try self.releaseClosedGroup(group);
    }
    pub fn ownedBytes(self: *const Owner) usize {
        var bytes = @sizeOf(Owner) + self.bindings.len * @sizeOf(Resolved);
        for (self.instances) |instance| if (instance) |value| {
            bytes += value.ownedBytes();
        };
        for (self.fallback_instances) |instance| if (instance) |value| {
            bytes += value.ownedBytes();
        };
        return bytes;
    }
    pub fn destroy(self: *Owner) !void {
        if (self.instance_count != 0) return error.DrainPending;
        for (self.instances) |instance| if (instance != null) return error.InvalidState;
        for (self.fallback_instances) |instance| if (instance != null) return error.InvalidState;
        const allocator = self.allocator;
        allocator.free(self.bindings);
        allocator.destroy(self);
    }
};
