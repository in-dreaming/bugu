//! TASK-012 logical vocabulary. Types describe full scope; capabilities describe
//! the much narrower implementation. This is internal, not the public facade.
const std = @import("std");
pub const Field = enum(u5) { gain, active, audibility, virtual_policy, variant, articulation, channel_trim, filter_cutoff, filter_bypass, effect_sends, bus_route, protection_class, retention_priority, drop_rank, attack, release };
pub const FieldMask = u32;
pub fn bit(field: Field) FieldMask {
    return @as(FieldMask, 1) << @intFromEnum(field);
}
pub const supported_fields = bit(.gain) | bit(.attack) | bit(.release);
pub const full_controller_implemented = false;
/// Separate internal M3 typed graph adapter, NOT the gain controller's mask.
/// Requires an exclusive prepared ingress lane; graph-frame ramps only.
pub const graph_adapter_fields = bit(.channel_trim) | bit(.filter_cutoff) | bit(.filter_bypass) | bit(.effect_sends) | bit(.bus_route);
/// Executable source-clock subset; wet/bypass and route envelopes remain gated.
pub const graph_source_clock_fields = bit(.channel_trim) | bit(.filter_cutoff) | bit(.effect_sends);
pub const Duration = union(enum) {
    frames: u64,
    /// Quarter notes, independent of meter pulse grouping. Sub-tick endpoints
    /// are rejected by M1, not rounded to a different musical duration.
    quarter_beats: struct { numerator: u64, denominator: u64 },
};
pub const Ramps = struct { attack: Duration = .{ .frames = 0 }, release: Duration = .{ .frames = 0 } };
pub const VirtualPolicy = enum { keep_real, budget_managed, virtual_when_inactive };
pub const Protection = enum { optional, stinger, dialogue, base };
pub const ChannelTrim = struct { channel: u8, gain: f32 };
pub const EffectSend = struct { send_id: u64, gain: f32 };
pub const LayerTarget = struct {
    gain: ?f32 = null, // Linear amplitude [0,4]; null inherits compiled initial value.
    active: ?bool = null, // Initial true; discrete hysteresis decision.
    audibility: ?f32 = null, // Independent [0,1] track, initial 1.
    virtual_policy: ?VirtualPolicy = null,
    variant: ?u64 = null, // Source ID; legal cue occurrence required.
    articulation: ?u64 = null,
    channel_trim: ?[]const ChannelTrim = null, // Present empty still unsupported.
    filter_cutoff: ?f32 = null, // Hz [20,20000], one-pole lowpass only.
    filter_bypass: ?bool = null,
    effect_sends: ?[]const EffectSend = null,
    bus_route: ?u64 = null,
    protection_class: ?Protection = null,
    retention_priority: ?u16 = null,
    drop_rank: ?u16 = null,
    attack: ?Duration = null,
    release: ?Duration = null,
    pub fn present(self: LayerTarget) FieldMask {
        var mask: FieldMask = 0;
        inline for (@typeInfo(Field).@"enum".fields) |f| {
            if (@field(self, f.name) != null) mask |= bit(@enumFromInt(f.value));
        }
        return mask;
    }
    pub fn unsupported(self: LayerTarget) FieldMask {
        return self.present() & ~supported_fields;
    }
};
pub const Unit = enum { linear_amplitude, normalized, hertz, boolean, stable_id, unsigned_rank, enumeration };
pub const Classification = enum { continuous, discrete };
pub const Boundary = enum { admitted_frame, compatible_cue, policy_transaction };
pub const Combine = enum { override, multiply };
pub const Conflict = enum { exclusive, declared_override, declared_multiply };
pub const Driver = union(enum) { parameter: u64, context: u64, state: u64, accepted_logic: u64 };
pub const PhysicalKey = struct { context: u64, group_generation: u64, layer_id: u64, field: Field, graph_generation: u64 = 0, target_id: u64 = 0, channel: u8 = 0 };
/// Full producer vocabulary, not an assertion that M1 resolves these writers.
/// M1 admits exactly one owned gain binding per physical group layer.
pub const Writer = struct {
    driver: Driver,
    field: Field,
    physical: PhysicalKey,
    unit: Unit,
    classification: Classification,
    boundary: Boundary,
    priority: i32 = 0,
    authored_order: u32,
    combine: Combine = .override,
    conflict: Conflict = .exclusive,
    allow_equal_priority_ordering: bool = false,
};
pub const OutputPolicy = enum { reject, clamp };
pub const InputStage = enum { accepted_smoothed, explicitly_raw };
pub const Hysteresis = struct { off: f64, on: f64, initially_active: bool = true };
/// Descriptive future transaction, deliberately not accepted by this controller.
pub const VariantSwitchPlan = struct {
    variant_id: u64,
    cue_id: u64,
    cue_tick: u64,
    cue_frame: u64,
    loop_epoch: u64,
    bank_generation: u64,
    group_generation: u64,
    transport_epoch: u64,
    mutation_epoch: u64,
    readiness_revision: u64,
    crossfade: Duration,
};
pub const Profile = struct {
    version: u16 = 1,
    max_layers: u16 = 16,
    max_commands: u16 = 32,
    max_phases: u16 = 32,
    max_writes_per_phase: u16 = 8,
    pub fn validate(self: Profile) error{InvalidProfile}!void {
        if (self.version != 1 or self.max_layers == 0 or self.max_layers > 16 or self.max_commands == 0 or self.max_commands > 32 or self.max_phases == 0 or self.max_phases > 32 or self.max_writes_per_phase == 0 or self.max_writes_per_phase > 8) return error.InvalidProfile;
    }
};
pub fn validateGain(value: f32, policy: OutputPolicy) error{InvalidGain}!f32 {
    if (!std.math.isFinite(value)) return error.InvalidGain;
    if (policy == .clamp) return std.math.clamp(value, 0, 4);
    if (value < 0 or value > 4) return error.InvalidGain;
    return value;
}
