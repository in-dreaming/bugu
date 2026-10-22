//! Explicit, copied host selection of the bounded DIRECT explicitly selected fade profile.
//! This is not a bank wire field, an inferred curve, or a readiness certificate.
const std = @import("std");

pub const max_bindings: usize = 64;

/// Zero/default and unknown values deliberately do not select an algorithm.
pub const CurveV1 = enum(u8) { unspecified = 0, linear = 1, equal_power = 2, _ };

pub const BindingV1 = struct {
    /// The nonzero stable Transition.key.id, never its mutable table index.
    transition_id: u64 = 0,
    curve: CurveV1 = .unspecified,
};

pub const ConfigV1 = struct {
    version: u16 = 1,
    bindings: []const BindingV1 = &.{},

    pub fn validate(self: ConfigV1) !void {
        if (self.version != 1) return error.UnsupportedVersion;
        if (self.bindings.len > max_bindings) return error.ResourceLimitExceeded;
        for (self.bindings, 0..) |binding, i| {
            if (binding.transition_id == 0) return error.InvalidBinding;
            switch (binding.curve) {
                .linear, .equal_power => {},
                else => return error.UnsupportedCapability,
            }
            for (self.bindings[0..i]) |prior| {
                if (prior.transition_id == binding.transition_id) return error.InvalidBinding;
            }
        }
    }

    /// Only use after validate/OwnedConfig.init has admitted the complete list.
    pub fn curveFor(self: ConfigV1, transition_id: u64) ?CurveV1 {
        for (self.bindings) |binding| {
            if (binding.transition_id == transition_id) return binding.curve;
        }
        return null;
    }

    /// Call against the already structurally validated bank.schema.Tables,
    /// before any provider opens. Generic solely to keep this public value
    /// contract independent of the bank -> music import dependency.
    ///
    /// This checks explicit selection and the narrow DIRECT topology only.
    /// The owner must still prove the beat-derived fade duration, matching
    /// tempo/meter, media/loop bounds, resource budget, and actual live PCM
    /// visibility; global fill/graph/policy/gain composition is also its gate.
    pub fn validateTables(self: ConfigV1, tables: anytype) !void {
        try self.validate();
        const none = std.math.maxInt(u32);
        for (self.bindings) |binding| {
            const index = for (tables.transitions, 0..) |rule, i| {
                if (rule.key.id == binding.transition_id) break i;
            } else return error.InvalidBinding;
            const rule = tables.transitions[index];
            if (rule.fade_ticks == 0) return error.InvalidBinding;
            if (rule.fill != none or rule.paths.count != 1 or rule.overlap_frames == 0)
                return error.UnsupportedCapability;
            if (rule.paths.first >= tables.transition_paths.len) return error.InvalidBinding;
            const path = tables.transition_paths[rule.paths.first];
            if (path.transition != index or path.source_exit >= tables.cues.len or path.target_entry >= tables.cues.len or
                rule.source_exit != path.source_exit or rule.target_entry != path.target_entry)
                return error.InvalidBinding;
            // Continuous already participates in the ordinary Planner's
            // tempo/meter compatibility checks. Other handoffs are not opted in.
            if (path.fill != none or path.handoff != .continuous) return error.UnsupportedCapability;
            const source = tables.cues[path.source_exit];
            const target = tables.cues[path.target_entry];
            if (source.tail_frames != rule.overlap_frames or target.frame != 0)
                return error.UnsupportedCapability;
        }
        // Empty config preserves rejection of nonzero fades/overlap. A partial
        // list cannot silently choose an algorithm for another authored rule.
        for (tables.transitions) |rule| {
            if ((rule.fade_ticks != 0 or rule.overlap_frames != 0) and self.curveFor(rule.key.id) == null)
                return error.UnsupportedCapability;
        }
    }
};

/// Construct before publication to Worker. The caller can immediately mutate
/// or free its array; neither the array nor any nested caller memory is retained.
pub const OwnedConfig = struct {
    allocator: std.mem.Allocator,
    value: ConfigV1,

    pub fn init(allocator: std.mem.Allocator, value: ConfigV1) !OwnedConfig {
        try value.validate();
        // Do not allocate, free, or retain a caller's zero-length slice pointer.
        const bindings: []const BindingV1 = if (value.bindings.len == 0)
            &.{}
        else
            try allocator.dupe(BindingV1, value.bindings);
        return .{ .allocator = allocator, .value = .{ .version = value.version, .bindings = bindings } };
    }

    pub fn deinit(self: *OwnedConfig) void {
        if (self.value.bindings.len != 0) self.allocator.free(self.value.bindings);
        self.* = undefined;
    }

    /// Heap bytes only. Empty/default configuration adds no owned heap cost.
    pub fn ownedBytes(self: *const OwnedConfig) usize {
        return self.value.bindings.len * @sizeOf(BindingV1);
    }
};
