const MusicError = @import("errors.zig").MusicError;

/// The name slice is borrowed for this call only; no bytes are retained.
/// FNV-1a over the exact UTF-8 bytes; no case folding or Unicode normalization.
/// Compiler collision checking remains TASK-003's responsibility.
pub fn hashName(name: []const u8) MusicError!u64 {
    if (name.len == 0) return error.InvalidState;
    var hash: u64 = 14695981039346656037;
    for (name) |byte| hash = (hash ^ byte) *% 1099511628211;
    if (hash == 0) return error.InvalidState;
    return hash;
}

pub const Domain = enum {
    state,
    theme,
    segment,
    layer,
    parameter,
    context,
    context_value,
    stinger,
    duck_request,
    duck_preset,
    cue,
    fill_route,
    selector,
    logic_program,
    voice_group,
    tempo_span,
    harmony_tag,
    phrase_tag,
    energy_tag,
    bus,
    profile,
    tempo_map,
};

fn StableId(comptime identity: Domain) type {
    return enum(u64) {
        invalid = 0,
        _,
        pub const domain = identity;
        pub fn fromName(name: []const u8) MusicError!@This() {
            return @enumFromInt(try hashName(name));
        }
        pub fn isValid(self: @This()) bool {
            return @intFromEnum(self) != 0;
        }
        pub fn value(self: @This()) u64 {
            return @intFromEnum(self);
        }
    };
}

pub const MusicStateId = StableId(.state);
pub const ThemeId = StableId(.theme);
pub const SegmentId = StableId(.segment);
pub const LayerId = StableId(.layer);
pub const MusicParameterId = StableId(.parameter);
pub const MusicContextId = StableId(.context);
pub const MusicContextValueId = StableId(.context_value);
pub const StingerId = StableId(.stinger);
pub const DuckRequestId = StableId(.duck_request);
pub const DuckPresetId = StableId(.duck_preset);
pub const CueId = StableId(.cue);
pub const FillRouteId = StableId(.fill_route);
pub const SegmentSelectorId = StableId(.selector);
pub const LogicProgramId = StableId(.logic_program);
pub const MusicVoiceGroupId = StableId(.voice_group);
pub const TempoSpanId = StableId(.tempo_span);
pub const TempoMapId = StableId(.tempo_map);
pub const HarmonyTagId = StableId(.harmony_tag);
pub const PhraseTagId = StableId(.phrase_tag);
pub const EnergyTagId = StableId(.energy_tag);
pub const MusicBusId = StableId(.bus);
pub const PlatformProfileId = StableId(.profile);

pub const CounterDomain = enum { runtime_context, plan, command, phase, plan_epoch, transport_epoch, device_epoch, asset_generation };
fn Counter(comptime identity: CounterDomain) type {
    return enum(u64) {
        invalid = 0,
        _,
        pub const domain = identity;
        pub fn isValid(self: @This()) bool {
            return @intFromEnum(self) != 0;
        }
        pub fn value(self: @This()) u64 {
            return @intFromEnum(self);
        }
    };
}
pub const RuntimeContextId = Counter(.runtime_context);
pub const PlanId = Counter(.plan);
pub const CommandId = Counter(.command);
pub const PhaseId = Counter(.phase);
pub const PlanEpoch = Counter(.plan_epoch);
pub const TransportEpoch = Counter(.transport_epoch);
pub const DeviceEpoch = Counter(.device_epoch);
pub const AssetGeneration = Counter(.asset_generation);

const HandleDomain = enum { runtime, instance, bank };
fn GenerationHandle(comptime identity: HandleDomain) type {
    return packed struct(u64) {
        index: u32 = 0,
        generation: u32 = 0,
        pub const domain = identity;
        /// Slot zero is valid; generation zero always invalidates the handle.
        pub fn isValid(self: @This()) bool {
            return self.generation != 0;
        }
        pub fn validate(self: @This()) MusicError!void {
            if (!self.isValid()) return error.InvalidHandle;
        }
        pub fn matches(self: @This(), current: @This()) bool {
            return self.isValid() and current.isValid() and self.index == current.index and self.generation == current.generation;
        }
    };
}
pub const MusicRuntimeHandle = GenerationHandle(.runtime);
pub const MusicInstanceHandle = GenerationHandle(.instance);
pub const MusicBankHandle = GenerationHandle(.bank);
