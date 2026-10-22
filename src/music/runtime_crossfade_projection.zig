//! Pure execution specialization of an unchanged, verified Planner plan.
//! This validates the bounded DIRECT shape; it does not prove live source PCM,
//! target visibility, media/loop bounds, compatible tempo, or source retirement.
//! The owner must keep the original plan for Planner.verifyPcm and its digest,
//! prove those runtime obligations, then atomically publish source release(N)
//! and target start(N) with the one retained target-entry token, phase_order=0.
const std = @import("std");
const planner = @import("sme-planner");
const music = @import("music");
const bank = @import("sme-bank");
const crossfade = @import("sme-runtime-crossfade-contract");
const s = bank.schema;

pub const max_fade_frames: u32 = 6144;
pub const Error = error{ InvalidState, UnsupportedCapability, ArithmeticOverflow };
pub const Kind = enum { bound_linear_direct, bound_equal_power_direct };

/// These are independently known owner/admission facts, not a PCM certificate.
/// source_exit_cursor and source_loop_epoch describe the intended onset. The
/// owner must bind them to its already-playing full group/stream incarnations
/// and prove the actual visible interval before publishing the projection.
pub const Input = struct {
    binding: crossfade.BindingV1,
    tables: s.Tables,
    bank_build_id: u64,
    context: u64,
    asset_generation: u64,
    transport_epoch: u64,
    source_group: planner.GroupBinding,
    source_segment: u64,
    target_segment: u64,
    source_exit_cursor: u64,
    source_loop_epoch: u64,
};

/// Original identity is retained even though only one phase is published.
/// This is provenance, not a replacement for the Planner's issued-plan digest.
pub const PlanIdentity = struct {
    version: u16,
    bank_build_id: u64,
    request_id: u64,
    request_epoch: u64,
    selector_epoch: u64,
    rule_id: u64,
    path_id: u64,
    from_state: u64,
    to_state: u64,
    target_segment: u64,
    target_entry_cue: u64,
    target_token: music.PhaseToken,
};

/// Planning/supply proof endpoints only. Neither phase is published and neither
/// receives a synthetic scheduler receipt. The actual source DSP terminal must
/// discharge the owner's outgoing lifetime and release its retained stream.
pub const SourceObligation = struct {
    group: planner.GroupBinding,
    loop_epoch: u64,
    /// Wrapped only for the explicit one-loop proof. Legacy exact-end cursors
    /// retain their previous unnormalized planning coordinate.
    terminal_loop_epoch: u64 = 0,
    tail: planner.Phase,
    stop: planner.Phase,
};

pub const Projection = struct {
    kind: Kind = .bound_linear_direct,
    identity: PlanIdentity,
    source: SourceObligation,
    onset_frame: u64,
    fade_end_frame: u64,
    fade_frames: u32,
    /// Retains the original target-entry phase verbatim, including phase_id=2.
    /// Scheduler phase_order is the index (zero), not token.phase_id minus one.
    phases: planner.BoundedTransitionPhases,
};

fn checkedAdd(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.ArithmeticOverflow;
}

fn validateToken(token: music.PhaseToken, plan: *const planner.TransitionPlan, input: Input, phase_id: u64) Error!void {
    token.validate() catch return error.InvalidState;
    if (token.context.value() != input.context or
        token.plan_id.value() != plan.plan_id or
        token.plan_epoch.value() != plan.plan_epoch or
        token.transport_epoch.value() != input.transport_epoch or
        token.asset_generation.value() != input.asset_generation or
        token.phase_id.value() != phase_id) return error.InvalidState;
}

/// Call only after ordinary Planner verification with the original plan. No
/// bytes in that plan, its phases, chunks, readiness references or digest change.
/// This helper neither publishes commands nor consumes/invents phase receipts.
pub fn project(plan: *const planner.TransitionPlan, input: Input) Error!Projection {
    switch (input.binding.curve) {
        .linear, .equal_power => {},
        else => return error.UnsupportedCapability,
    }
    if (input.binding.transition_id == 0 or input.binding.transition_id != plan.rule_id)
        return error.InvalidState;
    if (plan.version != planner.algorithm_version or
        plan.bank_build_id == 0 or plan.bank_build_id != input.bank_build_id or
        plan.asset_generation == 0 or plan.asset_generation != input.asset_generation or
        plan.transport_epoch == 0 or plan.transport_epoch != input.transport_epoch or
        input.context == 0 or plan.plan_id == 0 or plan.plan_epoch == 0 or
        input.source_group.generation == 0 or input.source_group.stable_id == 0 or
        plan.source_group != input.source_group.stable_id or
        input.source_segment == 0 or input.target_segment == 0 or
        plan.source_segment != input.source_segment or plan.target_segment != input.target_segment)
        return error.InvalidState;
    if (plan.fill_route != null or plan.fill_start_frame != null or plan.fill_end_frame != null or
        plan.fill_pcm_mode != .full_span) return error.UnsupportedCapability;
    // Check count before indexing; malformed counts never reach slice().
    if (plan.phases.count != 3) return error.InvalidState;
    if (plan.required_chunks.count > planner.max_chunks or plan.readiness_count > planner.max_bindings)
        return error.InvalidState;

    const rule_index = for (input.tables.transitions, 0..) |rule, i| {
        if (rule.key.id == plan.rule_id) break i;
    } else return error.InvalidState;
    const rule = input.tables.transitions[rule_index];
    if (rule.fill != s.none or rule.paths.count != 1 or rule.fade_ticks == 0)
        return error.UnsupportedCapability;
    if (rule.paths.first >= input.tables.transition_paths.len) return error.InvalidState;
    const path = input.tables.transition_paths[rule.paths.first];
    if (path.fill != s.none or path.handoff != .continuous) return error.UnsupportedCapability;
    if (path.key.id == 0 or path.key.id != plan.path_id or path.transition != rule_index or
        path.source_exit >= input.tables.cues.len or path.target_entry >= input.tables.cues.len or
        rule.source_exit != path.source_exit or rule.target_entry != path.target_entry or plan.sync != rule.sync)
        return error.InvalidState;
    const exit = input.tables.cues[path.source_exit];
    const entry = input.tables.cues[path.target_entry];
    if (exit.segment >= input.tables.segments.len or entry.segment >= input.tables.segments.len)
        return error.InvalidState;
    const source_segment = input.tables.segments[exit.segment];
    const target_segment = input.tables.segments[entry.segment];
    if (!bank.transition_validation.isExit(exit.kind) or !bank.transition_validation.isEntry(entry.kind) or
        source_segment.key.id != input.source_segment or target_segment.key.id != input.target_segment or
        exit.key.id == 0 or exit.key.id != plan.source_exit_cue or
        entry.key.id == 0 or entry.key.id != plan.target_entry_cue or exit.frame != input.source_exit_cursor)
        return error.InvalidState;
    if (entry.frame != 0) return error.UnsupportedCapability;
    // The bound is deliberately the finite ring profile, not merely u32. Keep
    // the explicit u32 check as part of the DSP ramp API contract.
    if (plan.fade_frames == 0 or plan.fade_frames > std.math.maxInt(u32) or
        plan.fade_frames > max_fade_frames) return error.UnsupportedCapability;
    if (exit.tail_frames != plan.fade_frames or rule.overlap_frames != plan.fade_frames)
        return error.InvalidState;

    const tail = plan.phases.items[0];
    const target = plan.phases.items[1];
    const stop = plan.phases.items[2];
    if (tail.kind != .source_tail or target.kind != .target_entry or stop.kind != .source_stop)
        return error.InvalidState;
    try validateToken(tail.token, plan, input, 1);
    try validateToken(target.token, plan, input, 2);
    try validateToken(stop.token, plan, input, 3);
    const onset = plan.execute_frame;
    const fade_end = try checkedAdd(onset, plan.fade_frames);
    var source_end: u64 = undefined;
    var terminal_loop_epoch = input.source_loop_epoch;
    switch (plan.source_tail_pcm_mode) {
        .contiguous => {
            if (plan.source_tail_obligation != null) return error.InvalidState;
            source_end = try checkedAdd(exit.frame, plan.fade_frames);
        },
        .live_one_loop => {
            const proof = plan.source_tail_obligation orelse return error.InvalidState;
            const layout = bank.transition_validation.boundedDirectTailLayout(input.tables, path, .{}) catch return error.UnsupportedCapability;
            if (!layout.crosses_loop or layout.fade_frames != plan.fade_frames or
                proof.version != planner.source_tail_proof_version or proof.count != planner.live_source_layers or
                !std.meta.eql(proof.group, input.source_group) or proof.source_incarnation != 1 or
                proof.onset.cursor != exit.frame or proof.onset.loop_epoch != input.source_loop_epoch or
                proof.terminal.cursor != layout.terminal_cursor or
                proof.terminal.loop_epoch != try checkedAdd(input.source_loop_epoch, layout.terminal_epoch_increment)) return error.InvalidState;
            source_end = layout.terminal_cursor;
            terminal_loop_epoch = proof.terminal.loop_epoch;
        },
        else => return error.UnsupportedCapability,
    }
    const target_end = try checkedAdd(onset, target_segment.frames);
    if (target_segment.frames == 0 or plan.target_start_frame != onset or
        tail.execute_frame != onset or tail.end_frame != fade_end or
        target.execute_frame != onset or target.end_frame != target_end or target.end_frame < fade_end or
        stop.execute_frame != fade_end or stop.end_frame != fade_end or
        tail.segment != input.source_segment or stop.segment != input.source_segment or
        target.segment != input.target_segment or
        tail.cue != exit.key.id or stop.cue != exit.key.id or target.cue != entry.key.id or
        tail.source_cursor != exit.frame or stop.source_cursor != source_end or target.source_cursor != 0 or
        tail.tempo_span != stop.tempo_span or
        tail.stop_segment != 0 or target.stop_segment != 0 or stop.stop_segment != 0)
        return error.InvalidState;

    var phases: planner.BoundedTransitionPhases = .{ .count = 1 };
    phases.items[0] = target;
    return .{
        .kind = if (input.binding.curve == .equal_power) .bound_equal_power_direct else .bound_linear_direct,
        .identity = .{
            .version = plan.version,
            .bank_build_id = plan.bank_build_id,
            .request_id = plan.request_id,
            .request_epoch = plan.request_epoch,
            .selector_epoch = plan.selector_epoch,
            .rule_id = plan.rule_id,
            .path_id = plan.path_id,
            .from_state = plan.from_state,
            .to_state = plan.to_state,
            .target_segment = plan.target_segment,
            .target_entry_cue = plan.target_entry_cue,
            .target_token = target.token,
        },
        .source = .{ .group = input.source_group, .loop_epoch = input.source_loop_epoch, .terminal_loop_epoch = terminal_loop_epoch, .tail = tail, .stop = stop },
        .onset_frame = onset,
        .fade_end_frame = fade_end,
        .fade_frames = @intCast(plan.fade_frames),
        .phases = phases,
    };
}
