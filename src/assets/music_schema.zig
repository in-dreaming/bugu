//! TASK-003 binary/IR contract. Every field is explicitly encoded little-endian;
//! Zig ABI padding, pointers, native enums and timestamps never enter the bank.
const std = @import("std");
pub const music = @import("music");
pub const sample_rate: u32 = 48_000;
pub const major: u16 = 1;
pub const minor: u16 = 1;
pub const policy_minor: u16 = 2;
pub const legacy_table_count: u32 = 50;
pub const magic = "BUGUSME1";
pub const endian_marker: u32 = 0x01020304;
pub const header_bytes: u32 = 128;
pub const directory_entry_bytes: u32 = 32;
pub const alignment: u32 = 8;
pub const hash_offset: usize = 64;
pub const none: u32 = std.math.maxInt(u32);
pub const Hash = [32]u8;
pub const zero_hash: Hash = @splat(0);
pub const Capability = enum(u6) { core, tempo, selection, transitions, stingers, logic, curves, bus, sidechain, acoustic, streaming, multichannel, bus_graph, music_policy_v1 };
pub fn bit(cap: Capability) u64 {
    return @as(u64, 1) << @intFromEnum(cap);
}
pub const full_capabilities: u64 = (1 << 14) - 1;
/// Legacy source defaults stay unchanged; the graph extension is opt-in.
pub const default_capabilities: u64 = (1 << 12) - 1;
pub const BankError = music.MusicError || error{
    InvalidBankMagic,
    InvalidEndian,
    TruncatedBank,
    InvalidBankLayout,
    BankHashMismatch,
    IdCollision,
    InvalidUtf8,
    InvalidReference,
    ResourceLimitExceeded,
    ArithmeticOverflow,
    MissingRequiredTable,
    DuplicateTable,
    InvalidRecord,
    InvalidSource,
    UnknownField,
    DuplicateField,
    MissingField,
    MissingRequiredPass,
    DuplicatePass,
    AudioReportMismatch,
    AudioQualityGateFailed,
    InvalidSeekIndex,
    EmergencyMustBeResident,
    InvalidGeneration,
    InvalidSampleRate,
    InvalidStorageDecision,
    InvalidCapabilityDeclaration,
    InvalidMeter,
    AmbiguousBeatGrouping,
    AnchorMismatch,
    NonClosingLoop,
};
pub const Privacy = enum { public, sensitive, local_only };
/// Runtime tables contain only numeric IDs, public musical labels and hashes.
/// Authoring source paths are local_only and never serialized/exported by this ABI.
pub const runtime_field_privacy = Privacy.public;
pub const source_path_privacy = Privacy.local_only;
pub const Limits = struct {
    pub const validation_scratch_bytes: u64 = 16 * 1024 * 1024;
    pub const loader_peak_bytes: u64 = 512 * 1024 * 1024;
    pub const bank_bytes: u64 = 256 * 1024 * 1024;
    pub const blob_bytes: u64 = 192 * 1024 * 1024;
    pub const chunk_bytes: u64 = 4 * 1024 * 1024;
    pub const id_bytes: u32 = 255;
    pub const string_bytes: u32 = 4 * 1024 * 1024;
    pub const records: u32 = 65_536;
    pub const grid_entries: u32 = 16_777_216;
    pub const logic_instructions: u32 = 4096;
    pub const logic_stack: u16 = 64;
    pub const logic_programs: u32 = 256;
    pub const logic_total_instructions: u32 = 65_536;
    pub const selection_states: u32 = 256;
    pub const selection_parameters: u32 = 256;
    pub const selection_contexts: u32 = 256;
    pub const selection_selectors: u32 = 128;
    pub const selector_candidates: u32 = 256;
    pub const selector_history: u32 = 64;
    pub const director_requests: u32 = 256;
    pub const director_pending: u32 = 64;
    pub const selection_transitions: u32 = 4096;
    pub const planner_phases: u16 = 64;
    pub const planner_candidates: u32 = 4096;
    pub const planner_paths: u32 = 4096;
    pub const fill_route_steps: u16 = 16;
    pub const required_chunks: u16 = 256;
    pub const planner_sound_bindings: u16 = 48;
    pub const resident_bytes: u64 = 16 * 1024 * 1024;
};
pub const Range = struct { first: u32 = 0, count: u32 = 0 };
pub const Named = struct { id: u64 = 0, name: u32 = none };
pub const String = struct { bytes: Range = .{} };
pub const Storage = enum(u8) { resident, streaming };
pub const Layout = @import("sme-channels").Layout;
pub const CodecKind = enum(u8) { pcm_f32le, ogg_opus };
pub const Sound = struct {
    key: Named = .{},
    codec: u32 = 0,
    import_report: u32 = 0,
    quality_report: u32 = 0,
    encoded_quality_report: u32 = none,
    storage: Storage = .resident,
    layout: Layout = .mono,
    channels: u16 = 1,
    channel_mask: u32 = 4,
    sample_rate_hz: u32 = sample_rate,
    frames: u64 = 0,
    blob_offset: u64 = 0,
    blob_length: u64 = 0,
    audio_hash: Hash = zero_hash,
    normalized_hash: Hash = zero_hash,
    chunks: Range = .{},
    seeks: Range = .{},
};
pub const State = struct { key: Named = .{}, theme: u32 = 0, selector: u32 = 0, required: u8 = 1, minimum_hold_bars: u16 = 0, cooldown_bars: u16 = 0, hysteresis_bars: u16 = 0 };
pub const Parameter = struct { key: Named = .{}, minimum: f32 = 0, maximum: f32 = 1, initial: f32 = 0, attack_frames: u32 = 0, release_frames: u32 = 0 };
pub const ContextKind = enum(u8) { boolean, integer, scalar, id };
pub const Context = struct { key: Named = .{}, kind: ContextKind = .boolean, initial_integer: i64 = 0, initial_scalar: f64 = 0, initial_id: u64 = 0 };
pub const Theme = struct { key: Named = .{}, initial_segment: u32 = 0 };
pub const Segment = struct {
    key: Named = .{},
    theme: u32 = 0,
    tempo: u32 = 0,
    layers: Range = .{},
    cues: Range = .{},
    frames: u64 = 0,
    loop_start: u64 = 0,
    loop_end: u64 = 0,
    pickup_ticks: u64 = 0,
    emergency: u8 = 0,
    storage: Storage = .resident,
    decoded_bytes: u64 = 0,
    fallback_segment: u32 = none,
    harmony: u64 = 0,
    phrase: u64 = 0,
    energy: u64 = 0,
};
pub const SelectorKind = enum(u8) { fixed, sequence, weighted_random, shuffle, no_repeat, condition, history };
pub const Exhaustion = enum(u8) { reject, reset, fallback };
pub const Selector = struct { key: Named = .{}, kind: SelectorKind = .fixed, candidates: Range = .{}, no_repeat_window: u16 = 0, history_capacity: u16 = 0, exhaustion: Exhaustion = .reject, fallback_segment: u32 = none };
pub const Candidate = struct { segment: u32 = 0, weight: u32 = 1, condition: u32 = none, authored_order: u32 = 0 };
pub const Layer = struct { key: Named = .{}, segment: u32 = 0, sound: u32 = 0, bus: u32 = 0, gain_curve: u32 = none, gain_db: f32 = 0, required: u8 = 1, drop_rank: u16 = 0, source_start: u64 = 0 };
pub const Sync = enum(u8) { next_beat, next_bar, next_cue, immediate, segment_end, authored_exit_cue };
pub const BeatRole = enum(u8) { any, downbeat, beat, offbeat };
pub const Handoff = enum(u8) { continuous, tail_overlap, tempo_handoff, hard_cut };
pub const Fallback = enum(u8) { reject, next_boundary, segment };
pub const Transition = struct {
    key: Named = .{},
    from: u32 = 0,
    to: u32 = 0,
    condition: u32 = none,
    selector: u32 = 0,
    source_exit: u32 = 0,
    target_entry: u32 = 0,
    fill: u32 = none,
    sync: Sync = .next_bar,
    fade_ticks: u64 = 0,
    minimum_hold_bars: u16 = 0,
    priority: u8 = 0,
    specificity: u16 = 0,
    authored_order: u32 = 0,
    fallback: Fallback = .reject,
    fallback_segment: u32 = none,
    compatibility: u32 = 0,
    harmony: u64 = 0,
    phrase: u64 = 0,
    energy: u64 = 0,
    beat_role: BeatRole = .any,
    overlap_frames: u32 = 0,
    paths: Range = .{},
};
pub const TransitionPath = struct { key: Named = .{}, transition: u32 = 0, source_exit: u32 = 0, target_entry: u32 = 0, fill: u32 = none, authored_rank: u32 = 0, sync_penalty: u16 = 0, handoff: Handoff = .continuous };
pub const TempoCurve = enum(u8) { constant, linear_seconds };
pub const TempoBeatUnit = enum(u8) { quarter_note };
pub const TempoRampDomain = enum(u8) { seconds };
pub const TempoRounding = enum(u8) { nearest_ties_even };
pub const Tempo = struct {
    key: Named = .{},
    ppq: u16 = 960,
    spans: Range = .{},
    beats: Range = .{},
    bars: Range = .{},
    anchors: Range = .{},
    total_ticks: u64 = 0,
    total_frames: u64 = 0,
    beat_unit: TempoBeatUnit = .quarter_note,
    ramp_domain: TempoRampDomain = .seconds,
    rounding: TempoRounding = .nearest_ties_even,
    pickup_ticks: u64 = 0,
    loop_present: u8 = 0,
    loop_start_tick: u64 = 0,
    loop_end_tick: u64 = 0,
    meters: Range = .{},
    queries: Range = .{},
};
pub const TempoMeter = struct { tick: u64 = 0, numerator: u8 = 4, denominator: u8 = 4, groups: Range = .{} };
pub const TempoQueryKind = enum(u8) { rational, materialized };
pub const TempoQuery = struct { start_tick: u64 = 0, end_tick: u64 = 0, kind: TempoQueryKind = .rational, origin_numerator: u256 = 0, step_numerator: u256 = 0, denominator: u256 = 1, frames: Range = .{} };
pub const TempoSpan = struct { start_tick: u64 = 0, end_tick: u64 = 0, start_frame: u64 = 0, end_frame: u64 = 0, start_milli_bpm: u32 = 120_000, end_milli_bpm: u32 = 120_000, curve: TempoCurve = .constant, numerator: u8 = 4, denominator: u8 = 4, groups: Range = .{} };
pub const Grid = struct { tick: u64 = 0, frame: u64 = 0, ordinal: u64 = 0, span: u32 = 0 };
pub const Anchor = struct { tick: u64 = 0, frame: u64 = 0 };
pub const CueKind = enum(u8) { entry, exit, both, stinger, fill_entry, fill_exit };
pub const Cue = struct { key: Named = .{}, segment: u32 = 0, kind: CueKind = .both, tick: u64 = 0, frame: u64 = 0, harmony: u64 = 0, phrase: u64 = 0, energy: u64 = 0, beat_role: BeatRole = .any, tail_frames: u32 = 0, min_lead_frames: u32 = 0 };
pub const Fill = struct { key: Named = .{}, source_exit: u32 = 0, target_entry: u32 = 0, steps: Range = .{} };
pub const FillStep = struct { segment: u32 = 0, entry: u32 = 0, exit: u32 = 0, overlap_frames: u32 = 0 };
pub const Stinger = struct { key: Named = .{}, segment: u32 = 0, cue: u32 = 0, sync: Sync = .next_beat, protected: u8 = 1, duck_preset: u32 = none };
pub const Logic = struct { key: Named = .{}, instructions: Range = .{}, stack_limit: u16 = Limits.logic_stack };
pub const LogicOp = enum(u8) { push_bool, push_number, load_state, load_parameter, load_context, eq, ne, lt, le, gt, ge, and_op, or_op, not_op, in_range, push_integer, push_id, return_bool };
pub const Instruction = struct { op: LogicOp = .push_bool, reference: u32 = none, integer: i64 = 1, number: f64 = 0, unsigned: u64 = 0 };
pub const Curve = struct { key: Named = .{}, points: Range = .{} };
pub const CurvePoint = struct { position: f64 = 0, value: f32 = 0 };
pub const Bus = struct { key: Named = .{}, parent: u32 = none, gain_db: f32 = 0, sends: Range = .{}, layout: Layout = .stereo, channel_mask: u32 = 3 };
pub const BusSend = struct { target: u32 = 0, gain_db: f32 = 0 };
pub const Sidechain = struct { key: Named = .{}, source_bus: u32 = 0, target_bus: u32 = 0, threshold_db: f32 = -18, ratio: f32 = 4, attack_frames: u32 = 480, release_frames: u32 = 4800, window_frames: u32 = 480, lookahead_frames: u32 = 0, max_attenuation_db: f32 = 12 };
/// TASK013 wire extension v1. All references are table indices, never host IDs.
/// Existing Bus remains the identity/layout/gain record. Full graph records do
/// not reinterpret its parent/sends: those must be empty in graph mode.
pub const GraphConfig = struct {
    key: Named = .{},
    platform: u32 = 0,
    version: u32 = 1,
    output_bus: u32 = 0,
    max_buses: u16 = 32,
    max_edges: u16 = 128,
    max_effects: u16 = 64,
    max_effects_per_bus: u16 = 8,
    max_sidechains: u16 = 16,
    max_duck_requests: u16 = 64,
    max_duck_requests_per_bus: u16 = 8,
    max_latency_frames: u32 = 2048,
    max_state_bytes: u64 = 33554432,
    music_bus: u32 = 0,
    sfx_bus: u32 = none,
    legacy_music_bus: u32 = none,
    legacy_master_bus: u32 = none,
    reverb_bus: u32 = none,
};
pub const GraphDuckMode = enum(u8) { strongest, additive, priority };
pub const GraphNode = struct {
    bus: u32 = 0,
    mute: u8 = 0,
    channel_gains: [8]f32 = @splat(1),
    effects: Range = .{},
    input_latency_frames: u32 = 0,
    meter_window_frames: u32 = 4800,
    duck_mode: GraphDuckMode = .strongest,
    automation_cap_db: f32 = 12,
};
pub const GraphEdge = struct {
    key: Named = .{},
    source: u32 = 0,
    destination: u32 = 0,
    gain: f32 = 1,
    matrix: u32 = none,
    route_group: u32 = 0,
    route_selected: u8 = 1,
};
pub const GraphMatrix = struct {
    key: Named = .{},
    input_layout: Layout = .mono,
    output_layout: Layout = .mono,
    coefficients: [8][8]f32 = @splat(@splat(0)),
};
pub const GraphEffectKind = enum(u8) { gain, lowpass, delay, compressor };
pub const GraphEffect = struct {
    key: Named = .{},
    kind: GraphEffectKind = .gain,
    bypass: u8 = 0,
    gain: f32 = 1,
    cutoff_hz: f32 = 20000,
    delay_frames: u32 = 0,
    detector_bus: u32 = none,
    preset: u32 = none,
};
pub const GraphDetectorMode = enum(u8) { rms, peak };
pub const GraphPreset = struct {
    key: Named = .{},
    preset_id: u32 = 1,
    sample_rate: u32 = 48000,
    detector_mode: GraphDetectorMode = .rms,
    rms_window_frames: u32 = 480,
    peak_window_frames: u32 = 48,
    meter_window_frames: u32 = 4800,
    threshold_dbfs: f32 = -18,
    ratio: f32 = 4,
    knee_db: f32 = 6,
    attack_frames: u32 = 480,
    hold_frames: u32 = 2400,
    release_frames: u32 = 4800,
    lookahead_frames: u32 = 240,
    makeup_db: f32 = 0,
    signal_cap_db: f32 = 12,
    automation_cap_db: f32 = 12,
    combined_cap_db: f32 = 24,
    /// Required explicitly by the author; inactive detector channels must be zero.
    weights: [8]f32 = @splat(0),
};
pub const GraphTargetKind = enum(u8) {
    bus_gain,
    bus_mute,
    channel_gain,
    send_gain,
    effect_gain,
    lowpass_hz,
    effect_bypass,
    compressor_threshold_dbfs,
    compressor_ratio,
    compressor_knee_db,
    compressor_attack_frames,
    compressor_hold_frames,
    compressor_release_frames,
    compressor_makeup_db,
    prepared_route,
};
pub const GraphTarget = struct {
    key: Named = .{},
    kind: GraphTargetKind = .bus_gain,
    bus: u32 = none,
    edge: u32 = none,
    effect: u32 = none,
    channel: u8 = 0,
};
pub const AcousticProfile = struct { key: Named = .{}, parameter: u32 = 0, mapping_curve: u32 = 0, minimum: f32 = 0, maximum: f32 = 1, smoothing_frames: u32 = 480 };
pub const Platform = struct {
    key: Named = .{},
    resident_limit_bytes: u64 = Limits.resident_bytes,
    max_bank_bytes: u64 = Limits.bank_bytes,
    max_blob_bytes: u64 = Limits.blob_bytes,
    max_chunk_bytes: u64 = Limits.chunk_bytes,
    max_table_records: u32 = Limits.records,
    max_grid_entries: u32 = 1_048_576,
    max_tempo_spans: u32 = Limits.records,
    max_logic_instructions: u32 = Limits.logic_instructions,
    max_logic_stack: u16 = Limits.logic_stack,
    max_planner_phases: u16 = Limits.planner_phases,
    max_planner_candidates: u32 = Limits.planner_candidates,
    profile_hash: Hash = zero_hash,
    max_fill_steps: u16 = Limits.fill_route_steps,
    max_required_chunks: u16 = Limits.required_chunks,
    planner_minimum_window_frames: u32 = 512,
};
pub const Codec = struct { kind: CodecKind = .pcm_f32le, version: u32 = 1, pre_skip: u32 = 0, end_trim: u32 = 0, channel_mapping_family: u8 = 0, stream_count: u8 = 1, coupled_count: u8 = 0, channel_mapping: [8]u8 = @splat(0), encoder_hash: Hash = zero_hash };
pub const Chunk = struct { sound: u32 = 0, byte_offset: u64 = 0, byte_length: u64 = 0, first_frame: u64 = 0, frame_count: u64 = 0, hash: Hash = zero_hash };
/// Coordinates are after Opus pre-skip: logical_frame zero is first audible PCM.
pub const SeekEntryV1 = struct { sound: u32 = 0, logical_frame: u64 = 0, page_byte_offset: u64 = 0, granule_position: u64 = 0, packet_byte_offset: u64 = 0, recovery_byte_offset: u64 = 0, preroll_frames: u32 = 0, discard_frames: u32 = 0, stream_serial: u32 = 0, link_id: u32 = 0 };
pub const Verdict = enum(u8) { pass, warn, fail };
pub const LoudnessState = enum(u8) { measured, silence, insufficient_duration };
pub const QualitySeverity = enum(u8) { report_only, warn, fail };
pub const QualityStage = enum(u8) { normalized, decoded_encoded };
pub const AudioImportPolicyV1 = struct { version: u32 = 1, target_sample_rate: u32 = sample_rate, src_algorithm: u32 = 0, src_version: u32 = 1, coefficients_hash: Hash = zero_hash, policy_hash: Hash = zero_hash, quality_policy_hash: Hash = zero_hash };
pub const AudioSourceFormat = enum(u8) { pcm_f32le, wav_integer, wav_float, ogg_opus };
pub const RemapKind = enum(u8) { cue, anchor, loop_start, loop_end };
pub const Remap = struct { source_frame: u64 = 0, target_frame: u64 = 0, marker_id: u64 = 0, kind: RemapKind = .cue };
pub const AudioImportReportV1 = struct {
    version: u32 = 1,
    policy: u32 = 0,
    source_hash: Hash = zero_hash,
    normalized_hash: Hash = zero_hash,
    source_format: AudioSourceFormat = .pcm_f32le,
    source_sample_rate: u32 = sample_rate,
    target_sample_rate: u32 = sample_rate,
    channels: u16 = 1,
    layout: Layout = .mono,
    channel_mask: u32 = 4,
    source_frames: u64 = 0,
    target_frames: u64 = 0,
    src_algorithm: u32 = 0,
    src_version: u32 = 1,
    coefficients_hash: Hash = zero_hash,
    bypass: u8 = 1,
    opus_input_rate_hint_present: u8 = 0,
    opus_input_rate_hint: u32 = 0,
    loop_present: u8 = 0,
    source_loop_start: u64 = 0,
    source_loop_end: u64 = 0,
    target_loop_start: u64 = 0,
    target_loop_end: u64 = 0,
    loop_play_count: u32 = 0,
    remaps: Range = .{},
    verdict: Verdict = .pass,
};
/// Wire-only quality records: explicit u8 presence/boolean flags, no native
/// bool, optional, pointer, or ABI padding. Mirrors scanner algorithm revision 2.
pub const QualityLoopState = enum(u8) { not_requested, measured, insufficient_duration };
pub const QualityRangeV1 = struct { minimum: f64 = 0, maximum: f64 = 0 };
pub const QualityPolicyRecordV1 = struct {
    version: u32 = 1,
    dc_absolute_maximum: f64 = 0.001,
    dc_severity: QualitySeverity = .warn,
    normalized_true_peak_maximum_dbtp: f64 = 0,
    normalized_true_peak_severity: QualitySeverity = .warn,
    loop_window_frames: u32 = 256,
    loop_seam_excess_maximum: f64 = 0.01,
    loop_slope_excess_maximum: f64 = 0.02,
    loop_dc_difference_maximum: f64 = 0.01,
    loop_severity: QualitySeverity = .warn,
    require_loop: u8 = 0,
    lufs_range_present: u8 = 0,
    lufs_range: QualityRangeV1 = .{},
    lufs_severity: QualitySeverity = .report_only,
    require_lufs_range: u8 = 0,
    required_measurements: u32 = 0x1f,
};
pub const QualityLoopRangeV1 = struct { start: u64 = 0, end: u64 = 0 };
pub const QualitySpeakerV1 = struct {
    mask_bit: u32 = 0,
    azimuth_degrees: i16 = 0,
    elevation_degrees: i16 = 0,
    lfe: u8 = 0,
    loudness_weight: f64 = 0,
};
pub const QualityLoopMetricsV1 = struct {
    state: QualityLoopState = .not_requested,
    window_frames: u32 = 0,
    seam_delta: f64 = 0,
    difference_before: f64 = 0,
    difference_after: f64 = 0,
    slope_change_before: f64 = 0,
    slope_change_after: f64 = 0,
    dc_before: f64 = 0,
    dc_after: f64 = 0,
    dc_difference: f64 = 0,
    local_max_difference: f64 = 0,
    local_max_slope_change: f64 = 0,
    seam_excess: f64 = 0,
    slope_excess: f64 = 0,
    dc_anomaly: u8 = 0,
};
pub const QualityChannelV1 = struct {
    speaker: QualitySpeakerV1 = .{},
    sample_peak: f64 = 0,
    true_peak: f64 = 0,
    rms: f64 = 0,
    dc: f64 = 0,
    loop: QualityLoopMetricsV1 = .{},
};
/// Finite dB/LUFS placeholders are meaningful only with their availability state.
/// Completion is never assumed: the sole producer copies actual scanner bits.
pub const AudioQualityReportV1 = struct {
    version: u32 = 1,
    algorithm_version: u32 = 2,
    source_hash: Hash = zero_hash,
    encoded_hash_present: u8 = 0,
    encoded_hash: Hash = zero_hash,
    audio_hash: Hash = zero_hash,
    policy_hash: Hash = zero_hash,
    effective_policy_hash: Hash = zero_hash,
    profile_hash: Hash = zero_hash,
    stage: QualityStage = .normalized,
    sample_rate_hz: u32 = sample_rate,
    layout: Layout = .mono,
    channel_mask: u32 = 4,
    channels: u16 = 1,
    measurement_frames: u64 = 0,
    completed_measurements: u32 = 0,
    policy: QualityPolicyRecordV1 = .{},
    channel: [8]QualityChannelV1 = @splat(.{}),
    sample_peak: f64 = 0,
    sample_peak_dbfs: f64 = 0,
    true_peak: f64 = 0,
    true_peak_dbtp: f64 = 0,
    peak_silence: u8 = 1,
    rms: f64 = 0,
    integrated_lufs: f64 = 0,
    loudness_state: LoudnessState = .insufficient_duration,
    loudness_window_frames: u32 = 19_200,
    loudness_hop_frames: u32 = 4_800,
    absolute_gate_lufs: f64 = -70,
    relative_gate_lu: f64 = -10,
    measured_relative_gate_lufs: f64 = 0,
    loudness_blocks: u64 = 0,
    absolute_gated_blocks: u64 = 0,
    relative_gated_blocks: u64 = 0,
    true_peak_oversample: u8 = 4,
    loop_minimum_support_frames: u32 = 64,
    loop_present: u8 = 0,
    loop: QualityLoopRangeV1 = .{},
    warnings: u32 = 0,
    failures: u32 = 0,
    verdict: Verdict = .pass,
};
pub const StreamStorageDecisionV1 = struct { storage: Storage, decoded_bytes: u64, forced_streaming: bool };
pub const StemSize = struct { frames: u64, channels: u16 };
pub fn storageDecision(stems: []const StemSize, limit: u64, requested: Storage, emergency: bool) BankError!StreamStorageDecisionV1 {
    if (stems.len == 0 or limit == 0) return error.InvalidStorageDecision;
    var bytes: u64 = 0;
    for (stems) |stem| {
        if (stem.channels == 0 or stem.channels > 8 or stem.frames == 0) return error.InvalidRecord;
        const samples = std.math.mul(u64, stem.frames, stem.channels) catch return error.ArithmeticOverflow;
        const size = std.math.mul(u64, samples, 4) catch return error.ArithmeticOverflow;
        bytes = std.math.add(u64, bytes, size) catch return error.ArithmeticOverflow;
    }
    if (emergency and (bytes > limit or requested == .streaming)) return error.EmergencyMustBeResident;
    return .{ .storage = if (bytes > limit) .streaming else requested, .decoded_bytes = bytes, .forced_streaming = bytes > limit and requested == .resident };
}
/// TASK015 opt-in 1.2 records. Fixed scalar encoding; no runtime request IDs.
pub const PolicyOrigin = enum(u8) { release, platform, asset };
pub const PolicySync = enum(u8) { immediate, next_beat, next_bar };
pub const PolicyConflict = enum(u8) { drop, replace, @"defer" };
pub const AcousticInputKind = enum(u8) { openness, room, path };
pub const AcousticMissing = enum(u8) { hold_last, neutral };
pub const PolicyConfig = struct { version: u16 = 1, platform: u32 = 0, sample_rate_hz: u32 = sample_rate, max_stingers: u16 = 8, origin: PolicyOrigin = .release };
pub const StingerPolicy = struct {
    key: Named = .{},
    version: u16 = 1,
    segment: u32 = 0,
    cue: u32 = 0,
    max_polyphony: u16 = 1,
    repeat_frames: u64 = 4800,
    deadline_frames: u64 = 24000,
    sync: PolicySync = .immediate,
    conflict: PolicyConflict = .drop,
    priority: u8 = 0,
    protected: u8 = 0,
    duck_preset: u32 = none,
    provenance: [9]PolicyOrigin = @splat(.release),
};
pub const AcousticPolicyProfile = struct { key: Named = .{}, version: u16 = 1, inputs: Range = .{} };
pub const AcousticPolicyInput = struct {
    version: u16 = 1,
    profile: u32 = 0,
    parameter: u32 = 0,
    input: AcousticInputKind = .openness,
    minimum_q16: i32 = 0,
    maximum_q16: i32 = 65536,
    neutral_q16: i32 = 32768,
    attack_frames: u64 = 2400,
    release_frames: u64 = 12000,
    rate_per_second_q16: u32 = 131072,
    quantize_intervals: u32 = 256,
    stale_frames: u64 = 12000,
    missing: AcousticMissing = .hold_last,
    provenance: [10]PolicyOrigin = @splat(.release),
};
/// Every value is explicit in the typed authoring handoff; no implicit duck defaults.
pub const AutomationDuckPreset = struct {
    key: Named = .{},
    version: u16 = 1,
    bus: u32 = 0,
    reduction_db: f32 = 0,
    priority: i16 = 0,
    authored_order: u32 = 0,
    attack_frames: u32 = 0,
    hold_frames: u32 = 0,
    release_frames: u32 = 0,
};
pub const Tables = struct {
    strings: []const String = &.{},
    sounds: []const Sound = &.{},
    states: []const State = &.{},
    parameters: []const Parameter = &.{},
    contexts: []const Context = &.{},
    themes: []const Theme = &.{},
    segments: []const Segment = &.{},
    selectors: []const Selector = &.{},
    layers: []const Layer = &.{},
    transitions: []const Transition = &.{},
    tempos: []const Tempo = &.{},
    cues: []const Cue = &.{},
    fills: []const Fill = &.{},
    stingers: []const Stinger = &.{},
    logic: []const Logic = &.{},
    curves: []const Curve = &.{},
    buses: []const Bus = &.{},
    sidechains: []const Sidechain = &.{},
    acoustic_profiles: []const AcousticProfile = &.{},
    platforms: []const Platform = &.{},
    codecs: []const Codec = &.{},
    chunks: []const Chunk = &.{},
    seeks: []const SeekEntryV1 = &.{},
    candidates: []const Candidate = &.{},
    fill_steps: []const FillStep = &.{},
    tempo_spans: []const TempoSpan = &.{},
    beats: []const Grid = &.{},
    bars: []const Grid = &.{},
    anchors: []const Anchor = &.{},
    beat_groups: []const u8 = &.{},
    instructions: []const Instruction = &.{},
    curve_points: []const CurvePoint = &.{},
    bus_sends: []const BusSend = &.{},
    import_policies: []const AudioImportPolicyV1 = &.{},
    import_reports: []const AudioImportReportV1 = &.{},
    quality_reports: []const AudioQualityReportV1 = &.{},
    remaps: []const Remap = &.{},
    string_data: []const u8 = &.{},
    blob: []const u8 = &.{},
    // Append-only directory identities; existing record IDs stay unchanged.
    tempo_meters: []const TempoMeter = &.{},
    tempo_queries: []const TempoQuery = &.{},
    tempo_tick_frames: []const u64 = &.{},
    transition_paths: []const TransitionPath = &.{},
    // IDs 44..50: explicit TASK013 graph extension; capability bus_graph.
    graph_configs: []const GraphConfig = &.{},
    graph_nodes: []const GraphNode = &.{},
    graph_edges: []const GraphEdge = &.{},
    graph_matrices: []const GraphMatrix = &.{},
    graph_effects: []const GraphEffect = &.{},
    graph_presets: []const GraphPreset = &.{},
    graph_targets: []const GraphTarget = &.{},
    // IDs 51..55 require music_policy_v1 and bank minor 2.
    policy_configs: []const PolicyConfig = &.{},
    stinger_policies: []const StingerPolicy = &.{},
    acoustic_policy_profiles: []const AcousticPolicyProfile = &.{},
    acoustic_policy_inputs: []const AcousticPolicyInput = &.{},
    automation_duck_presets: []const AutomationDuckPreset = &.{},
};
pub const Table = std.meta.FieldEnum(Tables);
pub const table_count = std.meta.fields(Tables).len;
pub fn Record(comptime table: Table) type {
    return std.meta.Child(@FieldType(Tables, @tagName(table)));
}
pub fn countLimit(table: Table) u32 {
    return switch (table) {
        .blob => @intCast(Limits.blob_bytes),
        .string_data => Limits.string_bytes,
        .beats, .bars, .anchors, .tempo_tick_frames => Limits.grid_entries,
        .instructions => Limits.records * Limits.logic_instructions,
        .transition_paths => Limits.planner_paths,
        .graph_configs, .policy_configs => 1,
        .stinger_policies => 512,
        .acoustic_policy_profiles => 128,
        .acoustic_policy_inputs => 384,
        .automation_duck_presets => 64,
        .graph_nodes => 32,
        .graph_edges, .graph_matrices => 128,
        .graph_effects => 64,
        .graph_presets => 16,
        .graph_targets => 1088,
        else => Limits.records,
    };
}
pub fn requiredCapability(table: Table) u64 {
    return bit(switch (table) {
        .parameters, .contexts, .logic, .instructions => .logic,
        .selectors, .candidates => .selection,
        .transitions, .fills, .fill_steps, .transition_paths => .transitions,
        .tempos, .tempo_spans, .beats, .bars, .anchors, .beat_groups, .cues, .tempo_meters, .tempo_queries, .tempo_tick_frames => .tempo,
        .stingers => .stingers,
        .curves, .curve_points => .curves,
        .buses, .bus_sends => .bus,
        .graph_configs, .graph_nodes, .graph_edges, .graph_matrices, .graph_effects, .graph_presets, .graph_targets => .bus_graph,
        .policy_configs, .stinger_policies, .acoustic_policy_profiles, .acoustic_policy_inputs, .automation_duck_presets => .music_policy_v1,
        .sidechains => .sidechain,
        .acoustic_profiles => .acoustic,
        .chunks, .seeks => .streaming,
        else => .core,
    });
}
pub fn mustBeNonempty(table: Table) bool {
    return @intFromEnum(table) < 23 or switch (table) {
        .import_policies, .import_reports, .quality_reports, .string_data, .blob, .policy_configs => true,
        else => false,
    };
}
pub const Metadata = struct { generation: u64 = 1, required_capabilities: u64 = default_capabilities, optional_capabilities: u64 = 0, initial_state: u32 = 0, profile: u32 = 0 };
pub const ValidatedIR = struct { metadata: Metadata, tables: Tables };

pub fn policyEnabled(metadata: Metadata) bool {
    return metadata.required_capabilities & bit(.music_policy_v1) != 0;
}
pub fn directoryCount(metadata: Metadata) u32 {
    return if (policyEnabled(metadata)) @intCast(table_count) else legacy_table_count;
}
pub fn bankMinor(metadata: Metadata) u16 {
    return if (policyEnabled(metadata)) policy_minor else minor;
}
