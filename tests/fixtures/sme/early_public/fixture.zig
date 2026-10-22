//! TASK026-A original, deterministic source-media fixture (CC0-1.0).
//!
//! Five short mono PCM16 WAV files are generated in memory, imported by the
//! genuine TASK010 media pipeline, and composed with the real TASK007/008/009
//! producers before the normal TASK003 builder and loader are called. This
//! module contains no runtime, plan, scheduler, or scenario-dependent output.
//!
//! The normal compiler Registry invokes every required real producer, including
//! source-bound static bus validation/emission, before serialization.
//! The third, unselected segment gives the SFX sound the media ownership that
//! TASK010 requires; only calm and active participate in music selection.
//! The current v1 schema requires a nonempty fills table with transitions. One
//! unused zero-step source route satisfies that rule; all actual paths explicitly
//! remain direct (fill=none), and this fixture exercises no runtime fill support.
const std = @import("std");
const bank = @import("sme-bank");
const s = bank.schema;
const compiler = @import("sme-compiler");
const media = @import("sme-media-pipeline");
const tempo = @import("sme-tempo");
const selection = @import("sme-selection-compiler");
const transitions = @import("sme-transition-compiler");
const buses = @import("sme-bus-compiler");

pub const sample_rate: u32 = 48_000;
pub const milli_bpm: u32 = 600_000;
pub const ppq: u16 = 960;
pub const bar_ticks: u64 = ppq;
pub const bar_frames: u64 = 4_800;
pub const segment_frames: u64 = bar_frames;
pub const sfx_frames: u64 = bar_frames;
pub const generation: u64 = 26;
pub const music_stems: usize = 2;
pub const sound_count: usize = 5;
pub const resident_limit_bytes: u64 = 1_048_576;

pub const state_calm = s.music.MusicStateId.fromName("early-calm") catch unreachable;
pub const state_active = s.music.MusicStateId.fromName("early-active") catch unreachable;
pub const segment_calm = s.music.SegmentId.fromName("early-calm-segment") catch unreachable;
pub const segment_active = s.music.SegmentId.fromName("early-active-segment") catch unreachable;
pub const segment_sfx = s.music.SegmentId.fromName("early-sfx-asset") catch unreachable;
pub const state_calm_index: u32 = 0;
pub const state_active_index: u32 = 1;
pub const segment_calm_index: u32 = 0;
pub const segment_active_index: u32 = 1;
pub const segment_sfx_index: u32 = 2;
pub const sound_calm_a_index: u32 = 0;
pub const sound_calm_b_index: u32 = 1;
pub const sound_active_a_index: u32 = 2;
pub const sound_active_b_index: u32 = 3;
pub const sound_sfx_index: u32 = 4;
pub const sound_calm_a = s.music.hashName("early-calm-a") catch unreachable;
pub const sound_calm_b = s.music.hashName("early-calm-b") catch unreachable;
pub const sound_active_a = s.music.hashName("early-active-a") catch unreachable;
pub const sound_active_b = s.music.hashName("early-active-b") catch unreachable;
pub const sound_sfx = s.music.hashName("early-sfx") catch unreachable;
pub const sound_ids = [_]u64{ sound_calm_a, sound_calm_b, sound_active_a, sound_active_b, sound_sfx };
pub const calm_entry_index: u32 = 0;
pub const calm_exit_index: u32 = 1;
pub const active_entry_index: u32 = 2;
pub const active_exit_index: u32 = 3;

/// Source-wave definitions, independent of callback partition or music request.
/// A pulse has four positive then four negative samples, so every source has
/// exact zero DC. Distinct periods/onsets/amplitudes expose individual stems
/// even after mono summation. All periods exactly divide the one-bar loop.
pub const Pulse = struct { period: u32, onset: u32, amplitude: i16 };
pub const pulse_half_width: u32 = 4;
pub const pulses = [_]Pulse{
    .{ .period = 480, .onset = 0, .amplitude = 2_048 },
    .{ .period = 600, .onset = 24, .amplitude = 4_096 },
    .{ .period = 300, .onset = 0, .amplitude = 4_096 },
    .{ .period = 400, .onset = 40, .amplitude = 6_144 },
    .{ .period = 96, .onset = 0, .amplitude = 8_192 },
};
const source_paths = [_][]const u8{ "calm-a.wav", "calm-b.wav", "active-a.wav", "active-b.wav", "sfx.wav" };
const wav_bytes: usize = 44 + @as(usize, segment_frames) * 2;

fn writeInt(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}
fn makeWav(allocator: std.mem.Allocator, pulse: Pulse) ![]u8 {
    const out = try allocator.alloc(u8, wav_bytes);
    @memset(out, 0);
    @memcpy(out[0..4], "RIFF");
    writeInt(u32, out, 4, wav_bytes - 8);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    writeInt(u32, out, 16, 16);
    writeInt(u16, out, 20, 1); // Integer PCM, not precompiled resident float data.
    writeInt(u16, out, 22, 1);
    writeInt(u32, out, 24, sample_rate);
    writeInt(u32, out, 28, sample_rate * 2);
    writeInt(u16, out, 32, 2);
    writeInt(u16, out, 34, 16);
    @memcpy(out[36..40], "data");
    writeInt(u32, out, 40, wav_bytes - 44);
    for (0..@as(usize, segment_frames)) |frame| {
        const phase = frame % pulse.period;
        const value: i16 = if (phase < pulse.onset or phase >= pulse.onset + 2 * pulse_half_width)
            0
        else if (phase < pulse.onset + pulse_half_width)
            pulse.amplitude
        else
            -pulse.amplitude;
        writeInt(i16, out, 44 + frame * 2, value);
    }
    return out;
}
const Sources = struct {
    reads: usize = 0,
    fn read(context: *anyopaque, allocator: std.mem.Allocator, input: compiler.SoundSource, limit: usize) media.Error![]u8 {
        const self: *Sources = @ptrCast(@alignCast(context));
        if (wav_bytes > limit) return error.ResourceLimitExceeded;
        for (source_paths, pulses) |path, pulse| if (std.mem.eql(u8, input.path, path)) {
            self.reads += 1;
            return makeWav(allocator, pulse);
        };
        return error.SourceReadFailed;
    }
};

/// Caller owns the returned normal compiled bank bytes. Every call executes
/// actual import, quality measurement, domain production, serialization and
/// normal loader admission; there is no cached/prebuilt-bank fallback.
pub fn build(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try buildSource(allocator, source);
    errdefer allocator.free(bytes);
    var loaded = try bank.MusicBank.load(allocator, bytes);
    defer loaded.deinit();
    try verify(&loaded);
    return bytes;
}

/// Compile authored variants against these same real WAV sources through the
/// complete normal Registry path. Useful for public capability rejection tests;
/// unlike build(), this does not enforce the fixed direct-transition fixture.
pub fn buildSource(allocator: std.mem.Allocator, source_text: []const u8) ![]u8 {
    var sources: Sources = .{};
    var pipeline: media.Pipeline = .{ .resolver = .{ .context = &sources, .read = Sources.read } };
    var registry: compiler.Registry = .{};
    try registry.registerMediaProviderContext(pipeline.provider());
    try tempo.install(&registry);
    try selection.install(&registry);
    try transitions.install(&registry);
    try buses.install(&registry);
    var compiled = try registry.buildSource(allocator, source_text);
    errdefer compiled.deinit();
    const bytes = compiled.bytes;
    var loaded = try bank.MusicBank.load(allocator, bytes);
    defer loaded.deinit();
    allocator.free(compiled.report.storage_decisions);
    return bytes;
}

/// Fixture-contract assertions over the actual normal loader output. These
/// do not construct or validate runtime plans and do not qualify the loader.
pub fn verify(loaded: *const bank.MusicBank) !void {
    const t = loaded.tables;
    if (loaded.metadata.generation != generation or loaded.metadata.initial_state != state_calm_index or t.states.len != 2 or t.segments.len != 3 or t.sounds.len != sound_count or t.layers.len != 5 or t.transitions.len != 2 or t.transition_paths.len != 2 or t.fills.len != 1 or t.fill_steps.len != 0) return error.InvalidFixtureMedia;
    if (t.states[0].key.id != state_calm.value() or t.states[1].key.id != state_active.value()) return error.InvalidFixtureMedia;
    for (t.sounds, sound_ids) |sound, id| {
        if (sound.key.id != id or sound.storage != .resident or sound.frames != segment_frames or sound.channels != 1 or sound.layout != .mono or sound.channel_mask != 4 or t.codecs[sound.codec].kind != .pcm_f32le or sound.blob_length != segment_frames * 4) return error.InvalidFixtureMedia;
        const report = t.import_reports[sound.import_report];
        if (report.source_format != .wav_integer or report.source_sample_rate != sample_rate or report.source_frames != segment_frames or report.bypass != 1) return error.InvalidFixtureMedia;
    }
    for (t.segments[0..2]) |segment| if (segment.layers.count != music_stems or segment.frames != segment_frames or segment.loop_start != 0 or segment.loop_end != bar_frames or segment.decoded_bytes != segment_frames * 4 * music_stems) return error.InvalidFixtureMedia;
    if (t.fills[0].steps.count != 0) return error.InvalidFixtureMedia;
    for (t.transition_paths) |path| if (path.fill != s.none) return error.InvalidFixtureMedia;
    for (t.transitions) |rule| if (rule.sync != .next_bar or rule.fill != s.none or rule.paths.count != 1 or rule.overlap_frames != 0) return error.InvalidFixtureMedia;
    if (t.tempos.len != 1 or t.tempos[0].total_frames != bar_frames or t.tempos[0].total_ticks != bar_ticks or t.tempos[0].loop_present != 1 or t.tempos[0].loop_start_tick != 0 or t.tempos[0].loop_end_tick != bar_ticks or t.tempo_spans[0].start_milli_bpm != milli_bpm or t.tempo_spans[0].numerator != 1 or t.tempo_spans[0].denominator != 4 or t.cues[calm_entry_index].frame != 0 or t.cues[active_entry_index].frame != 0 or t.cues[calm_exit_index].frame != bar_frames or t.cues[active_exit_index].frame != bar_frames) return error.InvalidFixtureMedia;
}

pub const source =
    \\schema="bugu.music.source/v1"
    \\generation=26
    \\initial_state="early-calm"
    \\profile="early-resident"
    \\required_capabilities=["core","tempo","selection","transitions","bus"]
    \\[[platforms]]
    \\id="early-resident"
    \\resident_limit_bytes=1048576
    \\profile_hash="2626262626262626262626262626262626262626262626262626262626262626"
    \\[[sounds]]
    \\id="early-calm-a"
    \\source="calm-a.wav"
    \\[[sounds]]
    \\id="early-calm-b"
    \\source="calm-b.wav"
    \\[[sounds]]
    \\id="early-active-a"
    \\source="active-a.wav"
    \\[[sounds]]
    \\id="early-active-b"
    \\source="active-b.wav"
    \\[[sounds]]
    \\id="early-sfx"
    \\source="sfx.wav"
    \\[[themes]]
    \\id="early-theme"
    \\initial_segment="early-calm-segment"
    \\[[states]]
    \\id="early-calm"
    \\theme="early-theme"
    \\selector="early-calm-selector"
    \\[[states]]
    \\id="early-active"
    \\theme="early-theme"
    \\selector="early-active-selector"
    \\[[selectors]]
    \\id="early-calm-selector"
    \\candidates={first=0,count=1}
    \\[[selectors]]
    \\id="early-active-selector"
    \\candidates={first=1,count=1}
    \\[[candidates]]
    \\id="early-calm-candidate"
    \\segment="early-calm-segment"
    \\[[candidates]]
    \\id="early-active-candidate"
    \\segment="early-active-segment"
    \\[[buses]]
    \\id="early-mono"
    \\layout="mono"
    \\channel_mask=4
    \\[[tempos]]
    \\id="early-clock"
    \\ppq=960
    \\spans={first=0,count=1}
    \\loop_present=true
    \\loop_start_tick=0
    \\loop_end_tick=960
    \\[[tempo_spans]]
    \\id="early-constant"
    \\end_tick=960
    \\start_milli_bpm=600000
    \\end_milli_bpm=600000
    \\numerator=1
    \\denominator=4
    \\[[segments]]
    \\id="early-calm-segment"
    \\theme="early-theme"
    \\tempo="early-clock"
    \\storage="resident"
    \\layers={first=0,count=2}
    \\cues={first=0,count=2}
    \\[[segments]]
    \\id="early-active-segment"
    \\theme="early-theme"
    \\tempo="early-clock"
    \\storage="resident"
    \\layers={first=2,count=2}
    \\cues={first=2,count=2}
    \\[[segments]]
    \\id="early-sfx-asset"
    \\theme="early-theme"
    \\tempo="early-clock"
    \\storage="resident"
    \\layers={first=4,count=1}
    \\cues={first=4,count=1}
    \\[[layers]]
    \\id="early-calm-a-layer"
    \\segment="early-calm-segment"
    \\sound="early-calm-a"
    \\bus="early-mono"
    \\[[layers]]
    \\id="early-calm-b-layer"
    \\segment="early-calm-segment"
    \\sound="early-calm-b"
    \\bus="early-mono"
    \\[[layers]]
    \\id="early-active-a-layer"
    \\segment="early-active-segment"
    \\sound="early-active-a"
    \\bus="early-mono"
    \\[[layers]]
    \\id="early-active-b-layer"
    \\segment="early-active-segment"
    \\sound="early-active-b"
    \\bus="early-mono"
    \\[[layers]]
    \\id="early-sfx-layer"
    \\segment="early-sfx-asset"
    \\sound="early-sfx"
    \\bus="early-mono"
    \\[[cues]]
    \\id="early-calm-entry"
    \\segment="early-calm-segment"
    \\kind="entry"
    \\tick=0
    \\[[cues]]
    \\id="early-calm-exit"
    \\segment="early-calm-segment"
    \\kind="exit"
    \\tick=960
    \\[[cues]]
    \\id="early-active-entry"
    \\segment="early-active-segment"
    \\kind="entry"
    \\tick=0
    \\[[cues]]
    \\id="early-active-exit"
    \\segment="early-active-segment"
    \\kind="exit"
    \\tick=960
    \\[[cues]]
    \\id="early-sfx-entry"
    \\segment="early-sfx-asset"
    \\kind="entry"
    \\tick=0
    \\[[fills]]
    \\id="early-unused-zero-step"
    \\source_exit="early-calm-exit"
    \\target_entry="early-active-entry"
    \\steps={first=0,count=0}
    \\[[transitions]]
    \\id="early-to-active"
    \\from="early-calm"
    \\to="early-active"
    \\selector="early-active-selector"
    \\source_exit="early-calm-exit"
    \\target_entry="early-active-entry"
    \\sync="next_bar"
    \\fallback="next_boundary"
    \\compatibility=24
    \\paths={first=0,count=1}
    \\[[transitions]]
    \\id="early-to-calm"
    \\from="early-active"
    \\to="early-calm"
    \\selector="early-calm-selector"
    \\source_exit="early-active-exit"
    \\target_entry="early-calm-entry"
    \\sync="next_bar"
    \\fallback="next_boundary"
    \\compatibility=24
    \\paths={first=1,count=1}
    \\[[transition_paths]]
    \\id="early-path-active"
    \\transition="early-to-active"
    \\source_exit="early-calm-exit"
    \\target_entry="early-active-entry"
    \\[[transition_paths]]
    \\id="early-path-calm"
    \\transition="early-to-calm"
    \\source_exit="early-active-exit"
    \\target_entry="early-calm-entry"
    \\
;
