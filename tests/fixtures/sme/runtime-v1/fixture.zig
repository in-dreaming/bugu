//! Public-API-only resident lifecycle fixture; real compiled source banks and
//! the same RuntimeOfflineBackend used by the compatibility fixture.
const std = @import("std");
pub const audio = @import("bugu_audio");
pub const music = audio.music;
pub const source = @import("sme-early-bank-fixture");
pub const a = std.testing.allocator;
pub const Run = struct {
    control: *audio.ControlRuntime,
    renderer: *audio.RuntimeRenderer,
    owner: *music.MusicRuntime,
    backend: audio.RuntimeOfflineBackend,
    bank: ?music.MusicBankRefV1 = null,
    pub fn create(config: music.MusicRuntimeConfigV1) !*Run {
        return createWithOwnerAllocator(config, a);
    }
    /// The allocator is fixed when the owner is constructed; tests may control
    /// its backing failure policy without replacing any live allocator.
    pub fn createWithOwnerAllocator(config: music.MusicRuntimeConfigV1, owner_allocator: std.mem.Allocator) !*Run {
        const control = try audio.ControlRuntime.create(a);
        errdefer a.destroy(control);
        const renderer = try a.create(audio.RuntimeRenderer);
        errdefer a.destroy(renderer);
        renderer.* = audio.RuntimeRenderer.init(control, 48000);
        const owner = try music.MusicRuntime.createV1(owner_allocator, control, renderer, config);
        const self = try a.create(Run);
        self.* = .{ .control = control, .renderer = renderer, .owner = owner, .backend = try audio.RuntimeOfflineBackend.init(renderer, config.quantum_frames, 2) };
        return self;
    }
    pub fn load(self: *Run) !void {
        const bytes = try source.build(a);
        defer a.free(bytes);
        const ticket = try self.owner.loadBank(bytes);
        try std.testing.expectEqual(.pending, try self.owner.pollLoad(ticket));
        try std.testing.expect(try self.owner.workerOneV1());
        const loaded = try self.owner.pollLoad(ticket);
        try std.testing.expect(loaded == .ready);
        self.bank = loaded.ready.bank;
        try self.owner.acknowledgeLoad(ticket);
    }
    pub fn pump(self: *Run) !void {
        if (self.owner.usesIntegratedTickV1()) {
            _ = try self.control.controlTickV1(audio.runtime.max_control_drain);
        } else _ = try self.owner.pumpResidentV1(audio.runtime.max_control_drain);
    }
    pub fn render(self: *Run, frames: u32) ![]f32 {
        return self.backend.renderFrames(a, frames);
    }
    pub fn start(self: *Run) !music.MusicRequestTicketV1 {
        const ticket = try self.owner.start(self.bank.?, source.state_calm);
        try self.pump();
        const pcm = try self.render(256);
        a.free(pcm);
        try self.pump();
        return ticket;
    }
    pub fn finish(self: *Run) !void {
        try self.owner.shutdown();
        // At most4096 already accepted inputs, bounded512 drain per pump.
        for (0..10) |_| try self.pump();
        const output = try self.render(512);
        a.free(output);
        // Collect actual shutdown cancellation/completion facts before final
        // host-quiescent destruction of their retained music-owner ledger.
        for (0..2) |_| try self.pump();
        const report = try self.owner.destroyQuiescent();
        try std.testing.expectEqual(@as(u64, 0), report.sample_leases);
        try std.testing.expectEqual(@as(u64, 0), report.live_instances);
        a.destroy(self.renderer);
        a.destroy(self.control);
        a.destroy(self);
    }
};
pub fn peak(samples: []const f32) f32 {
    var value: f32 = 0;
    for (samples) |sample| value = @max(value, @abs(sample));
    return value;
}
