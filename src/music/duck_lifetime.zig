//! Internal TASK015 duck incarnation and lossless terminal cell. No public ID
//! reuse contract, scheduler, host observation queue, or elapsed-time inference.
const std = @import("std");
pub const capacity = 64;
pub const Error = error{ InvalidDuckIdentity, StaleDuck, DuckBusy, DuckCapacity, DuckGenerationExhausted, DuckDrainPending };
pub const Handle = struct {
    context: u64,
    index: u16,
    generation: u64,
    pub fn eql(a: Handle, b: Handle) bool {
        return std.meta.eql(a, b);
    }
};
pub const Graph = struct { context: u64, index: u16, generation: u64 };
pub const Position = struct { accepted_control_frame: u64, control_tick: u64, input_order: u64 };
pub const Identity = struct {
    request_id: u64,
    accepted: Position,
    context: u64,
    bank_context: u64,
    bank_index: u32,
    bank_handle_generation: u32,
    asset_generation: u64,
    transport_epoch: u64,
    device_epoch: u64,
    external_id: u64,
    graph: Graph,
    bus: u32,
    dsp_id: u32,
    pub fn validate(self: Identity) Error!void {
        if (self.request_id == 0 or self.context == 0 or self.bank_context != self.context or self.bank_handle_generation == 0 or self.asset_generation == 0 or self.transport_epoch == 0 or self.device_epoch == 0 or self.external_id == 0 or self.graph.context == 0 or self.graph.generation == 0 or self.dsp_id == 0) return error.InvalidDuckIdentity;
    }
};
pub const State = enum(u8) { free, prepared, bound, active, terminal };
pub const Reason = enum { expired, ended, graph_retired, begin_rejected };
pub const Anchor = struct { command_id: u64, plan_id: u64, plan_epoch: u64, phase_id: u64, phase_order: u32, execute_frame: u64 };
pub const Terminal = struct {
    begin: Anchor,
    handle: Handle,
    identity: Identity,
    reason: Reason,
    /// Actual DSP removal sample/gate. No preset-duration prediction.
    frame: u64,
    /// First completed Render frontier after the last possible DSP access.
    release_frontier: u64,
};
pub const Cell = struct {
    state: std.atomic.Value(State) = .init(.free),
    handle: Handle = undefined,
    identity: Identity = undefined,
    begin: Anchor = undefined,
    terminal: Terminal = undefined,
    /// Single owner: Render after detach, or Control after a rejected begin
    /// receipt proves Render did not install. Terminal is immutable until drain.
    pub fn publish(self: *Cell, reason: Reason, frame: u64, frontier: u64) void {
        const state = self.state.load(.acquire);
        std.debug.assert((state == .active and reason != .begin_rejected) or (state == .bound and reason == .begin_rejected));
        std.debug.assert(frontier >= frame);
        self.terminal = .{ .handle = self.handle, .identity = self.identity, .begin = self.begin, .reason = reason, .frame = frame, .release_frontier = frontier };
        self.state.store(.terminal, .release); // final cell access
    }
    pub fn observe(self: *const Cell, frontier: u64) ?Terminal {
        if (self.state.load(.acquire) != .terminal or self.terminal.release_frontier > frontier) return null;
        return self.terminal;
    }
};
