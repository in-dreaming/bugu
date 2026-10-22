//! Fail-closed author live admission over the real compiled MusicBank schema.
//! This is a narrower host contract, not a second bank validator. The ordinary
//! loader validates all hashes, references, source indices and media reports.
//! Admission retains no table slices; the host must own the exact checked bytes.
const std = @import("std");
const bank = @import("sme-bank");
const s = bank.schema;
pub const music = @import("bugu_audio").music;
// A new configuration field needs an explicit live-admission decision.
comptime {
    if (std.meta.fields(music.MusicRuntimeConfigV1).len != 16)
        @compileError("Extend live configuration admission for the new runtime shape");
}
pub const stem_count = 4;
/// Bound matches the retained source provider and runtime planner envelope.
pub const max_sources = 48;
pub const default_config: music.MusicRuntimeConfigV1 = .{
    .kind = .authoring,
    .control_driver = .integrated,
    .quantum_frames = 256,
};
pub const Selection = struct {
    state: music.MusicStateId,
    segment: music.SegmentId,
    sounds: [stem_count]u64,
    bank_hash: [32]u8,
    generation: u64,
    loop_start: u64,
    loop_end: u64,
};

/// No live configuration is silently downgraded. The default resident snapshot
/// profile is only an allocation setting: this host never admits snapshot APIs.
pub fn validateConfig(config: music.MusicRuntimeConfigV1) !void {
    try config.validate();
    if (config.kind != .authoring or config.control_driver != .integrated or
        config.quantum_frames != 256 or config.policy_support != .disabled or
        config.snapshot_profile != .resident_v1 or config.layer_gain.bindings.len != 0 or
        config.layer_gain.parameter_sampling != .accepted_only or
        config.crossfade.bindings.len != 0 or config.sfx_generation_custody != .untracked or
        config.streaming_reservation != .initial_bank_only or config.streamed_fill_mode != .full_span or
        config.boundary_stop != null or config.preview_seek != null)
        return error.UnsupportedLiveConfig;
}

/// Run synchronously before creating the live owner or opening a device.
/// The selected ID need not be the bank's default; it must identify exactly one
/// deterministic state. DIRECT authored routes are inert because the host only
/// submits initial start and emergency stop, never a transition/state request.
pub fn validate(allocator: std.mem.Allocator, compiled: []const u8, selected_state: music.MusicStateId, config: music.MusicRuntimeConfigV1) !Selection {
    try validateConfig(config);
    if (compiled.len > config.capacity.max_bank_bytes) return error.ResourceLimitExceeded;
    var loaded = try bank.MusicBank.load(allocator, compiled);
    defer loaded.deinit();
    return validateLoaded(&loaded, selected_state);
}

/// Requires an ordinary successfully loaded, unmodified MusicBank. Exposed for
/// consumers already owning that bank and for schema-level negative witnesses;
/// untrusted bytes must always enter through validate / MusicBank.load first.
pub fn validateLoaded(loaded: *const bank.MusicBank, selected_state: music.MusicStateId) !Selection {
    const tables = loaded.tables;
    const allowed = s.bit(.core) | s.bit(.tempo) | s.bit(.selection) | s.bit(.transitions) | s.bit(.bus) | s.bit(.streaming);
    if ((loaded.metadata.required_capabilities | loaded.metadata.optional_capabilities) & ~allowed != 0 or loaded.bus_graph != null)
        return error.UnsupportedLiveBank;
    // Enumerate every accepted table. A schema extension fails closed even if
    // its capability flag happens to share an already accepted capability.
    inline for (std.meta.fields(s.Tables)) |field| {
        const admitted = comptime blk: {
            @setEvalBranchQuota(20_000);
            for (.{ "strings", "sounds", "states", "themes", "segments", "selectors", "layers", "transitions", "tempos", "cues", "fills", "buses", "platforms", "codecs", "chunks", "seeks", "candidates", "tempo_spans", "beats", "bars", "anchors", "beat_groups", "import_policies", "import_reports", "quality_reports", "remaps", "string_data", "blob", "tempo_meters", "tempo_queries", "tempo_tick_frames", "transition_paths" }) |name| {
                if (std.mem.eql(u8, field.name, name)) break :blk true;
            }
            break :blk false;
        };
        if (!admitted and @field(tables, field.name).len != 0) return error.UnsupportedLiveBank;
    }
    if (tables.sounds.len < stem_count or tables.sounds.len > max_sources or tables.segments.len == 0 or
        tables.states.len == 0 or tables.buses.len != 1) return error.UnsupportedLiveBank;
    const bus = tables.buses[0];
    if (bus.parent != s.none or bus.gain_db != 0 or bus.sends.count != 0 or
        !((bus.layout == .mono and bus.channel_mask == 4) or (bus.layout == .stereo and bus.channel_mask == 3)))
        return error.UnsupportedLiveBank;
    for (tables.sounds) |sound| {
        if (sound.storage != .streaming or sound.sample_rate_hz != 48_000 or sound.frames == 0 or
            !((sound.layout == .mono and sound.channels == 1 and sound.channel_mask == 4) or
                (sound.layout == .stereo and sound.channels == 2 and sound.channel_mask == 3)) or
            tables.codecs[sound.codec].kind != .ogg_opus or sound.chunks.count == 0 or sound.seeks.count == 0)
            return error.UnsupportedLiveBank;
    }
    for (tables.tempos) |tempo| {
        if (tempo.spans.count != 1 or tempo.pickup_ticks != 0 or tempo.loop_present != 1 or tempo.loop_start_tick != 0)
            return error.UnsupportedLiveBank;
        const span = tables.tempo_spans[tempo.spans.first];
        if (span.curve != .constant or span.start_milli_bpm != span.end_milli_bpm)
            return error.UnsupportedLiveBank;
    }
    for (tables.segments, 0..) |segment, index| {
        if (segment.storage != .streaming or segment.emergency != 0 or segment.fallback_segment != s.none or
            segment.pickup_ticks != 0 or segment.layers.count != stem_count or segment.loop_start != 0 or
            segment.loop_end != segment.frames or segment.frames == 0)
            return error.UnsupportedLiveBank;
        const tempo = tables.tempos[segment.tempo];
        if (tempo.total_frames != segment.frames) return error.UnsupportedLiveBank;
        const layers = tables.layers[segment.layers.first..][0..segment.layers.count];
        for (layers, 0..) |layer, i| {
            if (layer.segment != index or layer.required != 1 or layer.drop_rank != 0 or layer.source_start != 0 or
                layer.gain_curve != s.none or layer.gain_db != 0 or layer.bus != 0 or
                tables.sounds[layer.sound].frames != segment.frames)
                return error.UnsupportedLiveBank;
            for (layers[0..i]) |prior| if (prior.sound == layer.sound) return error.UnsupportedLiveBank;
        }
    }
    // No dangling extra layer can introduce an unexamined authored gain/source.
    for (tables.layers, 0..) |layer, i| {
        const range = tables.segments[layer.segment].layers;
        if (i < range.first or i - range.first >= range.count) return error.UnsupportedLiveBank;
    }
    for (tables.selectors) |selector| {
        if (selector.kind != .fixed or selector.candidates.count != 1 or selector.fallback_segment != s.none or
            selector.no_repeat_window != 0 or selector.history_capacity != 0 or selector.exhaustion != .reject)
            return error.UnsupportedLiveBank;
    }
    for (tables.candidates) |candidate| if (candidate.condition != s.none) return error.UnsupportedLiveBank;
    for (tables.states) |state| {
        if (state.minimum_hold_bars != 0 or state.cooldown_bars != 0 or state.hysteresis_bars != 0 or state.required != 1)
            return error.UnsupportedLiveBank;
    }
    for (tables.cues) |cue| {
        if ((cue.kind != .entry and cue.kind != .exit and cue.kind != .both) or cue.tail_frames != 0 or cue.min_lead_frames != 0)
            return error.UnsupportedLiveBank;
    }
    // Legacy compiler sources may carry unreferenced zero-step fill labels.
    // Those labels have no playback effect; actual fill routes are forbidden.
    for (tables.fills) |fill| if (fill.steps.count != 0) return error.UnsupportedLiveBank;
    for (tables.transitions) |transition| {
        if (transition.fill != s.none or transition.condition != s.none or transition.fade_ticks != 0 or
            transition.overlap_frames != 0 or transition.fallback != .reject or transition.fallback_segment != s.none)
            return error.UnsupportedLiveBank;
    }
    for (tables.transition_paths) |path| {
        if (path.fill != s.none or path.handoff != .hard_cut) return error.UnsupportedLiveBank;
    }
    for (tables.states) |state| if (state.key.id == selected_state.value()) {
        const selector = tables.selectors[state.selector];
        const segment = tables.segments[tables.candidates[selector.candidates.first].segment];
        var result: Selection = .{
            .state = selected_state,
            .segment = @enumFromInt(segment.key.id),
            .sounds = undefined,
            .bank_hash = loaded.content_hash,
            .generation = loaded.metadata.generation,
            .loop_start = segment.loop_start,
            .loop_end = segment.loop_end,
        };
        for (tables.layers[segment.layers.first..][0..stem_count], 0..) |layer, i|
            result.sounds[i] = tables.sounds[layer.sound].key.id;
        return result;
    };
    return error.LiveStateNotFound;
}
