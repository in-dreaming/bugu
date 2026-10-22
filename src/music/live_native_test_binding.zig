//! Exact optional borrowed set for the private independent-Host prerequisite.
//! Ownership only: no new Live admission, no complete semantic-capture claim.
//! Every callback is the genuine role's fixed bounded collector. The caller
//! retains callback storage through real producer/consumer joins.
const std = @import("std");
const rt = @import("bugu_audio").runtime;
const order = rt.capture_order;
const Service = rt.streaming.Service;
const readiness = rt.streaming.stream.readiness_observation;

/// Birth is copied on the creating Worker after the actual binding commit,
/// before source preparation. Service has no global transport epoch.
pub const ServiceBirth = struct {
    context: u64,
    load_ticket: @import("runtime_contract.zig").LoadTicketV1,
    worker_operation: u64,
    installation: usize,
    runtime_generation: u64,
    bank_hash: [32]u8,
    profile: @FieldType(Service, "profile"),
    profile_hash: [32]u8,
    next_job: u64,
    next_generation: u64,
    job_slots: usize,
    stream_slots: usize,
};
pub const BirthSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, ServiceBirth) void };
pub const Hooks = struct {
    birth: ?BirthSink = null,
    render_facts: ?rt.owned_render_facts.Hook = null,
    worker: rt.streaming.stream.WorkerFactSink,
    supply: readiness.SupplySink,
    lifecycle: readiness.LifecycleSink,
    scheduler_control: rt.scheduler.ControlSink,
    publication: rt.scheduler.CausalPublicationSink,
    progress: rt.scheduler.CausalProgressSink,
    terminal: rt.music_group.TerminalPublicationSink,
    source_final: rt.GroupSourceFinalSink,
    admission: rt.RuntimeRenderer.TestRenderAdmissionHook,
    control_facts: rt.TestOwnedControlFacts,
};

pub fn validateStartup(control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, events: *rt.MusicGroupTrace) !void {
    if (control.test_owned_control_facts != null or control.prerequisite_order != null or control.prerequisite_terminal_order != null or
        control.public_causal_group_terminal_sink != null or control.public_causal_group_source_final_sink != null or
        control.scheduled.prerequisite_order != null or control.scheduled.control_sink != null or
        control.scheduled.public_causal_publication_sink != null or control.scheduled.public_causal_progress_sink != null or
        control.scheduled.offline_causal_replay != null or control.scheduled.test_hook != null or control.scheduled.test_publication_hook != null or
        renderer.prerequisite_order != null or renderer.test_render_admission_hook != null or renderer.test_owned_render_facts != null or
        events.order_control != null or events.order_render != null or events.public_causal_sink != null or events.offline_causal_hooks != null or
        events.head.load(.acquire) != 0 or events.tail.load(.acquire) != 0 or events.reset_epoch.load(.acquire) == 0) return error.InvalidState;
    // Prepared payload/Rings are undefined when unused. Inspect only their
    // initialized ownership/terminal fields under real startup exclusion.
    for (&control.prepared_groups) |*slot| if (slot.occupied or slot.terminal.prerequisite_order != null or
        slot.terminal.causal_publication_sink != null or slot.terminal.offline_causal_replay != null) return error.InvalidState;
}

pub fn installControl(hooks: Hooks, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, events: *rt.MusicGroupTrace, roles: order.Roles, epoch: u64) void {
    control.test_owned_control_facts = hooks.control_facts;
    control.prerequisite_order = roles.control;
    control.prerequisite_terminal_order = roles.render;
    control.public_causal_group_terminal_sink = hooks.terminal;
    control.public_causal_group_source_final_sink = hooks.source_final;
    control.scheduled.prerequisite_order = roles;
    control.scheduled.control_sink = hooks.scheduler_control;
    control.scheduled.public_causal_publication_sink = hooks.publication;
    control.scheduled.public_causal_progress_sink = hooks.progress;
    renderer.prerequisite_order = roles.render;
    renderer.test_render_admission_hook = hooks.admission;
    renderer.test_owned_render_facts = hooks.render_facts;
    events.order_control = .{ .collector = roles.control, .index = 0, .generation = epoch };
    events.order_render = .{ .collector = roles.render, .index = 0, .generation = epoch };
}

/// Host-owned storage only; never resolves an owner backlink or embedded queue.
/// The post-empty caller must first authenticate the actual destroyed receipt.
pub fn validateControlStorage(hooks: Hooks, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, roles: order.Roles, ended: bool) !void {
    if (!std.meta.eql(control.test_owned_control_facts, if (ended) @as(?rt.TestOwnedControlFacts, null) else hooks.control_facts) or
        !std.meta.eql(control.prerequisite_order, if (ended) @as(?*order.RoleCollector, null) else roles.control) or
        !std.meta.eql(control.prerequisite_terminal_order, if (ended) @as(?*order.RoleCollector, null) else roles.render) or
        !std.meta.eql(control.public_causal_group_terminal_sink, if (ended) @as(?rt.music_group.TerminalPublicationSink, null) else hooks.terminal) or
        !std.meta.eql(control.public_causal_group_source_final_sink, if (ended) @as(?rt.GroupSourceFinalSink, null) else hooks.source_final) or
        !std.meta.eql(control.scheduled.prerequisite_order, if (ended) @as(?order.Roles, null) else roles) or
        !std.meta.eql(control.scheduled.control_sink, if (ended) @as(?rt.scheduler.ControlSink, null) else hooks.scheduler_control) or
        !std.meta.eql(control.scheduled.public_causal_publication_sink, if (ended) @as(?rt.scheduler.CausalPublicationSink, null) else hooks.publication) or
        !std.meta.eql(control.scheduled.public_causal_progress_sink, if (ended) @as(?rt.scheduler.CausalProgressSink, null) else hooks.progress) or
        !std.meta.eql(renderer.prerequisite_order, if (ended) @as(?*order.RoleCollector, null) else roles.render) or
        !std.meta.eql(renderer.test_render_admission_hook, if (ended) @as(?rt.RuntimeRenderer.TestRenderAdmissionHook, null) else hooks.admission) or
        !std.meta.eql(renderer.test_owned_render_facts, if (ended) @as(?rt.owned_render_facts.Hook, null) else hooks.render_facts) or
        control.offline_causal_group_terminal != null or
        control.scheduled.offline_causal_replay != null or control.scheduled.test_hook != null or control.scheduled.test_publication_hook != null)
        return error.InvalidState;
}

pub fn validateControl(hooks: Hooks, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, events: *rt.MusicGroupTrace, roles: order.Roles, epoch: u64, ended: bool) !void {
    try validateControlStorage(hooks, control, renderer, roles, ended);
    if (!std.meta.eql(events.order_control, if (ended) @as(?order.Binding, null) else .{ .collector = roles.control, .index = 0, .generation = epoch }) or
        !std.meta.eql(events.order_render, if (ended) @as(?order.Binding, null) else .{ .collector = roles.render, .index = 0, .generation = epoch }) or
        events.public_causal_sink != null or events.offline_causal_hooks != null) return error.InvalidState;
    // No mutable Worker/Render slot state or recorder health here. Queue epoch
    // cannot change while these exact bindings are attached: reset rejects it.
}

/// Only after exact final ACK and real caller/Render exclusion. Actual Control
/// destruction released every group, whose original slot reset clears terminal
/// bindings. This check never repairs or erases an occupied group's ownership.
pub fn validateFinal(control: *rt.ControlRuntime, events: *rt.MusicGroupTrace, epoch: u64) !void {
    if (events.reset_epoch.load(.acquire) != epoch) return error.InvalidState;
    for (&control.prepared_groups) |*slot| if (slot.occupied or slot.terminal.prerequisite_order != null or
        slot.terminal.causal_publication_sink != null or slot.terminal.offline_causal_replay != null) return error.InvalidState;
}

pub fn clearControl(control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, events: *rt.MusicGroupTrace) void {
    control.test_owned_control_facts = null;
    control.prerequisite_order = null;
    control.prerequisite_terminal_order = null;
    control.public_causal_group_terminal_sink = null;
    control.public_causal_group_source_final_sink = null;
    control.scheduled.prerequisite_order = null;
    control.scheduled.control_sink = null;
    control.scheduled.public_causal_publication_sink = null;
    control.scheduled.public_causal_progress_sink = null;
    renderer.prerequisite_order = null;
    renderer.test_render_admission_hook = null;
    renderer.test_owned_render_facts = null;
    events.order_control = null;
    events.order_render = null;
}

pub fn installService(hooks: Hooks, service: *Service) void {
    service.public_causal_worker_sink = hooks.worker;
    service.readiness_supply_sink = hooks.supply;
    service.readiness_lifecycle_sink = hooks.lifecycle;
}
pub fn validateService(hooks: ?Hooks, service: *Service) !void {
    if (!std.meta.eql(service.public_causal_worker_sink, if (hooks) |value| @as(?rt.streaming.stream.WorkerFactSink, value.worker) else null) or
        !std.meta.eql(service.readiness_supply_sink, if (hooks) |value| @as(?readiness.SupplySink, value.supply) else null) or
        !std.meta.eql(service.readiness_lifecycle_sink, if (hooks) |value| @as(?readiness.LifecycleSink, value.lifecycle) else null)) return error.InvalidState;
}
pub fn clearService(service: *Service) void {
    service.public_causal_worker_sink = null;
    service.readiness_supply_sink = null;
    service.readiness_lifecycle_sink = null;
}
