//! Production embedding runtime: bounded MPSC control, immutable snapshots,
//! generation-safe instances, and callback-local render state.

const std = @import("std");
const core = @import("../core/engine.zig");
const mixer = @import("../mixer/mixer.zig");

pub const command_capacity = 4096;
pub const reserved_command_capacity = 128;
pub const normal_command_capacity = command_capacity - reserved_command_capacity;
pub const max_control_drain = 512;
pub const max_instances = 1024;
pub const max_render_voices = mixer.max_real_voices;
pub const snapshot_count = 3;
pub const steal_fade_frames = 32;

pub const RuntimeError = core.BuguError || error{
    CommandQueueFull,
    InstanceCapacity,
    StaleInstance,
    DuplicateInstance,
    ConcurrentControl,
    SnapshotBusy,
    RuntimeStopped,
    DrainPending,
};

pub const InstanceHandle = struct {
    index: u16,
    generation: u16,

    pub fn eql(a: InstanceHandle, b: InstanceHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

pub const SampleOwner = struct {
    samples: []const f32,
    references: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    retired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(samples: []const f32) RuntimeError!SampleOwner {
        if (samples.len == 0) return error.InvalidArgument;
        return .{ .samples = samples };
    }

    pub fn retain(self: *SampleOwner) RuntimeError!void {
        if (self.retired.load(.acquire)) return error.InvalidState;
        return self.pin();
    }

    fn pin(self: *SampleOwner) RuntimeError!void {
        var current = self.references.load(.acquire);
        while (current != 0 and current != std.math.maxInt(u32)) current = self.references.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) orelse return;
        return error.InvalidState;
    }

    pub fn release(self: *SampleOwner) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
    }

    pub fn retire(self: *SampleOwner) void {
        if (!self.retired.swap(true, .acq_rel)) self.release();
    }

    pub fn referenceCount(self: *const SampleOwner) u32 {
        return self.references.load(.acquire);
    }

    pub fn canDestroy(self: *const SampleOwner) bool {
        return self.retired.load(.acquire) and self.referenceCount() == 0;
    }
};

pub const VoiceParams = struct {
    gain: f32 = 1,
    pitch: f32 = 1,
    priority: f32 = 1,
    bus: mixer.BusId = .sfx,
    loop: bool = false,
    pan: f32 = 0,
    lowpass_hz: f32 = 20_000,
    reverb_send: f32 = 0,
};

pub const PlayCommand = struct {
    instance: InstanceHandle,
    owner: *SampleOwner,
    params: VoiceParams,
};

pub const UpdateCommand = struct {
    instance: InstanceHandle,
    params: mixer.VoiceControlParams,
    ramp_frames: u32,
};

pub const StopCommand = struct {
    instance: InstanceHandle,
    fade_frames: u32,
};

pub const BusCommand = struct {
    bus: mixer.BusId,
    gain: f32,
    ramp_frames: u32,
};

pub const CommandKind = enum { play, update, bus, stop, shutdown };
pub const Command = union(CommandKind) {
    play: PlayCommand,
    update: UpdateCommand,
    bus: BusCommand,
    stop: StopCommand,
    shutdown: void,
};

const SequencedCommand = struct { sequence: u64, value: Command };

fn MpscRing(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Cell = struct {
            sequence: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
            value: SequencedCommand = undefined,
        };

        cells: [capacity]Cell = undefined,
        enqueue_position: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        dequeue_position: usize = 0,

        fn init() Self {
            @setEvalBranchQuota(100_000);
            var self: Self = .{};
            for (&self.cells, 0..) |*cell, index| cell.* = .{ .sequence = std.atomic.Value(usize).init(index) };
            return self;
        }

        fn push(self: *Self, value: Command, sequence_counter: *std.atomic.Value(u64)) bool {
            var position = self.enqueue_position.load(.monotonic);
            while (true) {
                const cell = &self.cells[position % capacity];
                const sequence = cell.sequence.load(.acquire);
                const difference: isize = @as(isize, @bitCast(sequence -% position));
                if (difference == 0) {
                    if (self.enqueue_position.cmpxchgWeak(position, position +% 1, .monotonic, .monotonic)) |actual| {
                        position = actual;
                        continue;
                    }
                    cell.value = .{ .sequence = sequence_counter.fetchAdd(1, .monotonic), .value = value };
                    cell.sequence.store(position +% 1, .release);
                    return true;
                }
                if (difference < 0) return false;
                position = self.enqueue_position.load(.monotonic);
            }
        }

        fn peek(self: *Self) ?SequencedCommand {
            const position = self.dequeue_position;
            const cell = &self.cells[position % capacity];
            if (cell.sequence.load(.acquire) != position +% 1) return null;
            return cell.value;
        }

        fn pop(self: *Self) ?SequencedCommand {
            const value = self.peek() orelse return null;
            const position = self.dequeue_position;
            self.cells[position % capacity].sequence.store(position +% capacity, .release);
            self.dequeue_position = position +% 1;
            return value;
        }

        fn count(self: *const Self) usize {
            return self.enqueue_position.load(.acquire) -% self.dequeue_position;
        }
    };
}

const InstancePool = struct {
    const occupied: u32 = 1 << 31;
    slots: [max_instances]std.atomic.Value(u32) = init: {
        @setEvalBranchQuota(100_000);
        var values: [max_instances]std.atomic.Value(u32) = undefined;
        for (&values) |*value| value.* = std.atomic.Value(u32).init(0);
        break :init values;
    },

    fn reserve(self: *InstancePool) RuntimeError!InstanceHandle {
        for (&self.slots, 0..) |*slot, index| {
            var slot_value = slot.load(.acquire);
            while (slot_value & occupied == 0) {
                const old_generation: u16 = @truncate(slot_value);
                const generation = nextGeneration(old_generation);
                const desired = occupied | generation;
                if (slot.cmpxchgWeak(slot_value, desired, .acq_rel, .acquire)) |actual| {
                    slot_value = actual;
                    continue;
                }
                return .{ .index = @intCast(index), .generation = generation };
            }
        }
        return error.InstanceCapacity;
    }

    fn current(self: *const InstancePool, handle: InstanceHandle) bool {
        if (handle.index >= max_instances or handle.generation == 0) return false;
        return self.slots[handle.index].load(.acquire) == occupied | handle.generation;
    }

    fn release(self: *InstancePool, handle: InstanceHandle) void {
        if (handle.index >= max_instances) return;
        _ = self.slots[handle.index].cmpxchgStrong(occupied | handle.generation, handle.generation, .acq_rel, .acquire);
    }

    fn liveCount(self: *const InstancePool) usize {
        var count: usize = 0;
        for (&self.slots) |*slot| count += @intFromBool(slot.load(.acquire) & occupied != 0);
        return count;
    }
};

const DesiredVoice = struct {
    active: bool = false,
    stopping: bool = false,
    instance: InstanceHandle = .{ .index = 0, .generation = 0 },
    owner: *SampleOwner = undefined,
    params: VoiceParams = .{},
    revision: u64 = 0,
    fade_frames: u32 = 0,
    start_order: u64 = 0,
};

pub const SnapshotVoice = struct {
    instance: InstanceHandle,
    owner: *SampleOwner,
    params: VoiceParams,
    revision: u64,
    stopping: bool,
    fade_frames: u32,
};

pub const RenderSnapshot = struct {
    generation: u64 = 0,
    voices: [max_render_voices]SnapshotVoice = undefined,
    voice_count: usize = 0,
    sfx_gain: f32 = 1,
    music_gain: f32 = 1,
    master_gain: f32 = 1,
    master_ramp_frames: u32 = 1,
    bus_revision: u64 = 0,
};

const SnapshotSlot = struct {
    readers: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    snapshot: RenderSnapshot = .{},

    fn releaseOwners(self: *SnapshotSlot, counters: *RuntimeCounters) void {
        for (self.snapshot.voices[0..self.snapshot.voice_count]) |voice| {
            voice.owner.release();
            _ = counters.snapshot_pins.fetchSub(1, .monotonic);
        }
        self.snapshot.voice_count = 0;
    }
};

pub const SnapshotLease = struct {
    runtime: *ControlRuntime,
    slot_index: u8,
    snapshot: *const RenderSnapshot,

    pub fn release(self: SnapshotLease) void {
        const previous = self.runtime.snapshots[self.slot_index].readers.fetchSub(1, .release);
        std.debug.assert(previous > 0);
    }
};

pub const CompletionReason = enum { finished, stopped, stolen, rejected };
pub const Completion = struct { instance: InstanceHandle, reason: CompletionReason };

fn SpscRing(comptime capacity: usize, comptime T: type) type {
    return struct {
        values: [capacity]T = undefined,
        write_position: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        read_position: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn push(self: *@This(), value: T) bool {
            const write = self.write_position.load(.monotonic);
            if (write -% self.read_position.load(.acquire) == capacity) return false;
            self.values[write % capacity] = value;
            self.write_position.store(write +% 1, .release);
            return true;
        }

        fn pop(self: *@This()) ?T {
            const read = self.read_position.load(.monotonic);
            if (read == self.write_position.load(.acquire)) return null;
            const value = self.values[read % capacity];
            self.read_position.store(read +% 1, .release);
            return value;
        }

        fn count(self: *const @This()) usize {
            return self.write_position.load(.acquire) -% self.read_position.load(.acquire);
        }
    };
}

pub const RuntimeTelemetry = struct {
    accepted_commands: u64,
    rejected_commands: u64,
    queue_high_water: u32,
    live_instances: u32,
    snapshot_generation: u64,
    snapshot_pins: u32,
    render_pins: u32,
    completion_overflow: u64,
    stolen_instances: u64,
};

const RuntimeCounters = struct {
    accepted_commands: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_commands: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queue_high_water: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    snapshot_pins: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    render_pins: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    completion_overflow: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stolen_instances: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub const ControlRuntime = struct {
    normal: MpscRing(normal_command_capacity) = MpscRing(normal_command_capacity).init(),
    reserved: MpscRing(reserved_command_capacity) = MpscRing(reserved_command_capacity).init(),
    next_sequence: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    next_control_sequence: u64 = 1,
    instances: InstancePool = .{},
    desired: [max_instances]DesiredVoice = [_]DesiredVoice{.{}} ** max_instances,
    active_count: usize = 0,
    accepting: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    shutdown_submitted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    control_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    snapshots: [snapshot_count]SnapshotSlot = [_]SnapshotSlot{.{}} ** snapshot_count,
    published_slot: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    published_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    next_revision: u64 = 1,
    sfx_gain: f32 = 1,
    music_gain: f32 = 1,
    master_gain: f32 = 1,
    master_ramp_frames: u32 = 1,
    bus_revision: u64 = 1,
    render_completions: SpscRing(max_instances, Completion) = .{},
    reported_completions: SpscRing(max_instances, Completion) = .{},
    counters: RuntimeCounters = .{},

    pub fn init() ControlRuntime {
        return .{};
    }

    pub fn reserveInstance(self: *ControlRuntime) RuntimeError!InstanceHandle {
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        return self.instances.reserve();
    }

    pub fn submitPlay(self: *ControlRuntime, play: PlayCommand) RuntimeError!void {
        if (!self.accepting.load(.acquire)) return error.RuntimeStopped;
        if (!self.instances.current(play.instance)) return error.StaleInstance;
        try validateVoiceParams(play.params);
        try play.owner.retain();
        errdefer play.owner.release();
        try self.submit(.{ .play = play }, false);
    }

    pub fn submitUpdate(self: *ControlRuntime, update: UpdateCommand) RuntimeError!void {
        if (!self.instances.current(update.instance)) return error.StaleInstance;
        inline for (.{ update.params.gain, update.params.pan, update.params.lowpass_hz, update.params.pitch_ratio, update.params.reverb_send }) |optional| if (optional) |value| if (!finite(value)) return error.InvalidArgument;
        try self.submit(.{ .update = update }, false);
    }

    pub fn submitBus(self: *ControlRuntime, bus: BusCommand) RuntimeError!void {
        if (!finite(bus.gain) or bus.gain < 0 or bus.gain > 4) return error.InvalidArgument;
        try self.submit(.{ .bus = bus }, false);
    }

    pub fn submitStop(self: *ControlRuntime, stop: StopCommand) RuntimeError!void {
        if (!self.instances.current(stop.instance)) return error.StaleInstance;
        try self.submit(.{ .stop = stop }, true);
    }

    pub fn submitShutdown(self: *ControlRuntime) RuntimeError!void {
        self.accepting.store(false, .release);
        if (self.shutdown_submitted.swap(true, .acq_rel)) return;
        self.submit(.{ .shutdown = {} }, true) catch |err| {
            self.shutdown_submitted.store(false, .release);
            return err;
        };
    }

    pub fn stopAccepting(self: *ControlRuntime) void {
        self.accepting.store(false, .release);
    }

    fn submit(self: *ControlRuntime, command: Command, use_reserved: bool) RuntimeError!void {
        const pushed = if (use_reserved) self.reserved.push(command, &self.next_sequence) else self.normal.push(command, &self.next_sequence);
        if (!pushed) {
            _ = self.counters.rejected_commands.fetchAdd(1, .monotonic);
            return error.CommandQueueFull;
        }
        _ = self.counters.accepted_commands.fetchAdd(1, .monotonic);
        self.recordHighWater();
    }

    fn recordHighWater(self: *ControlRuntime) void {
        const count: u32 = @intCast(@min(command_capacity, self.normal.count() + self.reserved.count()));
        var current = self.counters.queue_high_water.load(.monotonic);
        while (count > current) current = self.counters.queue_high_water.cmpxchgWeak(current, count, .monotonic, .monotonic) orelse return;
    }

    pub fn controlTick(self: *ControlRuntime, limit: usize) RuntimeError!usize {
        if (self.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_active.store(false, .release);
        self.consumeCompletions();
        var drained: usize = 0;
        while (drained < @min(limit, max_control_drain)) : (drained += 1) {
            const normal = self.normal.peek();
            const reserved = self.reserved.peek();
            const candidate = if (normal == null) reserved else if (reserved == null) normal else if (normal.?.sequence < reserved.?.sequence) normal else reserved;
            if (candidate == null or candidate.?.sequence != self.next_control_sequence) break;
            const command = if (normal != null and normal.?.sequence == self.next_control_sequence) self.normal.pop() else self.reserved.pop();
            const item = command orelse break;
            self.next_control_sequence +%= 1;
            if (self.next_control_sequence == 0) self.next_control_sequence = 1;
            self.apply(item.value, item.sequence) catch |err| switch (err) {
                error.StaleInstance, error.DuplicateInstance => {
                    _ = self.counters.rejected_commands.fetchAdd(1, .monotonic);
                    continue;
                },
                else => return err,
            };
        }
        try self.publishSnapshot();
        return drained;
    }

    fn apply(self: *ControlRuntime, command: Command, sequence: u64) RuntimeError!void {
        switch (command) {
            .play => |play| {
                if (!self.instances.current(play.instance)) {
                    play.owner.release();
                    return error.StaleInstance;
                }
                const state = &self.desired[play.instance.index];
                if (state.active) {
                    play.owner.release();
                    return error.DuplicateInstance;
                }
                if (self.active_count == max_render_voices) {
                    const victim = self.findVictim(play.params.priority) orelse {
                        play.owner.release();
                        self.finish(play.instance, .rejected);
                        return;
                    };
                    const old = self.desired[victim];
                    old.owner.release();
                    self.desired[victim] = .{};
                    self.instances.release(old.instance);
                    self.reportCompletion(.{ .instance = old.instance, .reason = .stolen });
                    _ = self.counters.stolen_instances.fetchAdd(1, .monotonic);
                    self.active_count -= 1;
                }
                state.* = .{ .active = true, .instance = play.instance, .owner = play.owner, .params = play.params, .revision = self.takeRevision(), .start_order = sequence };
                self.active_count += 1;
            },
            .update => |update| {
                const state = try self.stateFor(update.instance);
                if (state.stopping) return;
                applyUpdate(&state.params, update.params);
                state.revision = self.takeRevision();
                state.fade_frames = update.ramp_frames;
            },
            .bus => |bus| {
                switch (bus.bus) {
                    .sfx => self.sfx_gain = bus.gain,
                    .music => self.music_gain = bus.gain,
                    .master => {
                        self.master_gain = bus.gain;
                        self.master_ramp_frames = @max(bus.ramp_frames, 1);
                    },
                }
                self.bus_revision = self.takeRevision();
            },
            .stop => |stop| {
                const state = try self.stateFor(stop.instance);
                state.stopping = true;
                state.fade_frames = @max(stop.fade_frames, 1);
                state.revision = self.takeRevision();
            },
            .shutdown => {
                self.accepting.store(false, .release);
                for (&self.desired) |*state| if (state.active) {
                    state.stopping = true;
                    state.fade_frames = 1;
                    state.revision = self.takeRevision();
                };
            },
        }
    }

    fn stateFor(self: *ControlRuntime, handle: InstanceHandle) RuntimeError!*DesiredVoice {
        if (!self.instances.current(handle)) return error.StaleInstance;
        const state = &self.desired[handle.index];
        if (!state.active or !state.instance.eql(handle)) return error.StaleInstance;
        return state;
    }

    fn findVictim(self: *const ControlRuntime, incoming_priority: f32) ?usize {
        var victim: ?usize = null;
        for (self.desired, 0..) |state, index| if (state.active and !state.stopping) {
            if (victim == null or weaker(state, self.desired[victim.?])) victim = index;
        };
        if (victim) |index| if (incoming_priority <= self.desired[index].params.priority) return null;
        return victim;
    }

    fn takeRevision(self: *ControlRuntime) u64 {
        defer self.next_revision +%= 1;
        if (self.next_revision == 0) self.next_revision = 1;
        return self.next_revision;
    }

    fn consumeCompletions(self: *ControlRuntime) void {
        while (self.render_completions.pop()) |completion| {
            if (!self.instances.current(completion.instance)) continue;
            const state = &self.desired[completion.instance.index];
            if (!state.active or !state.instance.eql(completion.instance)) continue;
            state.owner.release();
            state.* = .{};
            self.active_count -= 1;
            self.instances.release(completion.instance);
            self.reportCompletion(completion);
        }
    }

    fn finish(self: *ControlRuntime, instance: InstanceHandle, reason: CompletionReason) void {
        self.instances.release(instance);
        self.reportCompletion(.{ .instance = instance, .reason = reason });
    }

    fn pushRenderCompletion(self: *ControlRuntime, completion: Completion) void {
        if (!self.render_completions.push(completion)) _ = self.counters.completion_overflow.fetchAdd(1, .monotonic);
    }

    fn reportCompletion(self: *ControlRuntime, completion: Completion) void {
        if (!self.reported_completions.push(completion)) _ = self.counters.completion_overflow.fetchAdd(1, .monotonic);
    }

    fn publishSnapshot(self: *ControlRuntime) RuntimeError!void {
        const current = self.published_slot.load(.acquire);
        var selected: ?u8 = null;
        for (0..snapshot_count) |offset| {
            const index: u8 = @intCast((@as(usize, current) + 1 + offset) % snapshot_count);
            if (index != current and self.snapshots[index].readers.load(.acquire) == 0) {
                selected = index;
                break;
            }
        }
        const index = selected orelse return error.SnapshotBusy;
        const slot = &self.snapshots[index];
        slot.releaseOwners(&self.counters);
        const generation = self.published_generation.load(.monotonic) +% 1;
        slot.snapshot = .{ .generation = if (generation == 0) 1 else generation, .sfx_gain = self.sfx_gain, .music_gain = self.music_gain, .master_gain = self.master_gain, .master_ramp_frames = self.master_ramp_frames, .bus_revision = self.bus_revision };
        for (self.desired) |state| if (state.active) {
            state.owner.pin() catch return error.InvalidState;
            _ = self.counters.snapshot_pins.fetchAdd(1, .monotonic);
            slot.snapshot.voices[slot.snapshot.voice_count] = .{ .instance = state.instance, .owner = state.owner, .params = state.params, .revision = state.revision, .stopping = state.stopping, .fade_frames = state.fade_frames };
            slot.snapshot.voice_count += 1;
        };
        self.published_generation.store(slot.snapshot.generation, .release);
        self.published_slot.store(index, .release);
    }

    pub fn acquireSnapshot(self: *ControlRuntime) SnapshotLease {
        while (true) {
            const index = self.published_slot.load(.acquire);
            _ = self.snapshots[index].readers.fetchAdd(1, .acquire);
            if (index == self.published_slot.load(.acquire)) return .{ .runtime = self, .slot_index = index, .snapshot = &self.snapshots[index].snapshot };
            _ = self.snapshots[index].readers.fetchSub(1, .release);
        }
    }

    pub fn pollCompletion(self: *ControlRuntime) ?Completion {
        return self.reported_completions.pop();
    }

    pub fn telemetry(self: *const ControlRuntime) RuntimeTelemetry {
        return .{ .accepted_commands = self.counters.accepted_commands.load(.monotonic), .rejected_commands = self.counters.rejected_commands.load(.monotonic), .queue_high_water = self.counters.queue_high_water.load(.monotonic), .live_instances = @intCast(self.instances.liveCount()), .snapshot_generation = self.published_generation.load(.acquire), .snapshot_pins = self.counters.snapshot_pins.load(.monotonic), .render_pins = self.counters.render_pins.load(.monotonic), .completion_overflow = self.counters.completion_overflow.load(.monotonic), .stolen_instances = self.counters.stolen_instances.load(.monotonic) };
    }

    pub fn drainStatus(self: *const ControlRuntime) RuntimeError!void {
        if (self.normal.count() != 0 or self.reserved.count() != 0 or self.instances.liveCount() != 0 or self.counters.render_pins.load(.acquire) != 0) return error.DrainPending;
    }

    pub fn destroy(self: *ControlRuntime) RuntimeError!void {
        self.stopAccepting();
        try self.drainStatus();
        for (&self.snapshots) |*slot| {
            if (slot.readers.load(.acquire) != 0) return error.DrainPending;
            slot.releaseOwners(&self.counters);
        }
        while (self.reported_completions.pop() != null) {}
        if (self.counters.snapshot_pins.load(.acquire) != 0) return error.DrainPending;
    }
};

const RenderVoice = struct {
    active: bool = false,
    instance: InstanceHandle = .{ .index = 0, .generation = 0 },
    handle: mixer.VoiceHandle = .{ .index = 0, .generation = 0 },
    owner: *SampleOwner = undefined,
    revision: u64 = 0,
    stopping: bool = false,
};

pub const RuntimeRenderer = struct {
    runtime: *ControlRuntime,
    mixer: mixer.Mixer,
    telemetry: core.TelemetryCounters = .{},
    voices: [max_render_voices]RenderVoice = [_]RenderVoice{.{}} ** max_render_voices,
    last_bus_revision: u64 = 0,

    pub fn init(runtime: *ControlRuntime, sample_rate: u32) RuntimeRenderer {
        return .{ .runtime = runtime, .mixer = mixer.Mixer.init(sample_rate) };
    }

    pub fn render(self: *RuntimeRenderer, output: []f32, frame_count: u32, channels: u16) void {
        const lease = self.runtime.acquireSnapshot();
        self.sync(lease.snapshot);
        lease.release();
        self.mixer.render(output, frame_count, channels, &self.telemetry);
        self.collectFinished();
    }

    fn sync(self: *RuntimeRenderer, snapshot: *const RenderSnapshot) void {
        if (snapshot.bus_revision != self.last_bus_revision) {
            self.mixer.setBusGain(.sfx, snapshot.sfx_gain);
            self.mixer.setBusGain(.music, snapshot.music_gain);
            self.mixer.setMasterGain(snapshot.master_gain, snapshot.master_ramp_frames);
            self.last_bus_revision = snapshot.bus_revision;
        }
        for (&self.voices) |*voice| if (voice.active and !voice.stopping and !snapshotContains(snapshot, voice.instance)) {
            self.mixer.stopVoice(voice.handle, steal_fade_frames) catch {};
            voice.stopping = true;
        };
        for (snapshot.voices[0..snapshot.voice_count]) |wanted| {
            var current = self.find(wanted.instance);
            if (current == null and !wanted.stopping) current = self.start(wanted);
            if (current) |voice| {
                if (wanted.revision != voice.revision) {
                    if (wanted.stopping) {
                        self.mixer.stopVoice(voice.handle, wanted.fade_frames) catch {};
                        voice.stopping = true;
                    } else {
                        self.mixer.updateVoice(voice.handle, .{ .gain = wanted.params.gain, .pan = wanted.params.pan, .lowpass_hz = wanted.params.lowpass_hz, .pitch_ratio = wanted.params.pitch, .reverb_send = wanted.params.reverb_send }, wanted.fade_frames) catch {};
                    }
                    voice.revision = wanted.revision;
                }
            }
        }
    }

    fn start(self: *RuntimeRenderer, wanted: SnapshotVoice) ?*RenderVoice {
        const slot = for (&self.voices) |*voice| if (!voice.active) break voice else continue else return null;
        wanted.owner.pin() catch return null;
        const handle = self.mixer.startSampleVoiceWithHandle(.{ .samples = wanted.owner.samples, .gain = wanted.params.gain, .pitch = wanted.params.pitch, .priority = wanted.params.priority, .bus = wanted.params.bus, .loop = wanted.params.loop, .pan = wanted.params.pan, .lowpass_hz = wanted.params.lowpass_hz, .reverb_send = wanted.params.reverb_send }, &self.telemetry) catch {
            wanted.owner.release();
            return null;
        };
        _ = self.runtime.counters.render_pins.fetchAdd(1, .monotonic);
        slot.* = .{ .active = true, .instance = wanted.instance, .handle = handle, .owner = wanted.owner, .revision = wanted.revision };
        return slot;
    }

    fn find(self: *RuntimeRenderer, instance: InstanceHandle) ?*RenderVoice {
        for (&self.voices) |*voice| if (voice.active and voice.instance.eql(instance)) return voice;
        return null;
    }

    fn collectFinished(self: *RuntimeRenderer) void {
        for (&self.voices) |*voice| if (voice.active and !self.mixer.isVoiceActive(voice.handle)) {
            const reason: CompletionReason = if (voice.stopping) .stopped else .finished;
            self.runtime.pushRenderCompletion(.{ .instance = voice.instance, .reason = reason });
            voice.owner.release();
            _ = self.runtime.counters.render_pins.fetchSub(1, .monotonic);
            voice.* = .{};
        };
    }

    pub fn activeVoiceCount(self: *const RuntimeRenderer) usize {
        var count: usize = 0;
        for (self.voices) |voice| count += @intFromBool(voice.active);
        return count;
    }
};

fn applyUpdate(params: *VoiceParams, update: mixer.VoiceControlParams) void {
    if (update.gain) |value| params.gain = std.math.clamp(value, 0, 4);
    if (update.pan) |value| params.pan = std.math.clamp(value, -1, 1);
    if (update.lowpass_hz) |value| params.lowpass_hz = value;
    if (update.pitch_ratio) |value| params.pitch = std.math.clamp(value, 0.01, 8);
    if (update.reverb_send) |value| params.reverb_send = std.math.clamp(value, 0, 1);
}

fn validateVoiceParams(params: VoiceParams) RuntimeError!void {
    inline for (.{ params.gain, params.pitch, params.priority, params.pan, params.lowpass_hz, params.reverb_send }) |value| if (!finite(value)) return error.InvalidArgument;
    if (params.gain < 0 or params.gain > 4 or params.pitch < 0.01 or params.pitch > 8 or params.priority < 0 or params.priority > 1 or params.pan < -1 or params.pan > 1 or params.lowpass_hz < 20 or params.reverb_send < 0 or params.reverb_send > 1) return error.InvalidArgument;
}

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

fn snapshotContains(snapshot: *const RenderSnapshot, instance: InstanceHandle) bool {
    for (snapshot.voices[0..snapshot.voice_count]) |voice| if (voice.instance.eql(instance)) return true;
    return false;
}

fn weaker(a: DesiredVoice, b: DesiredVoice) bool {
    if (a.params.priority != b.params.priority) return a.params.priority < b.params.priority;
    if (a.start_order != b.start_order) return a.start_order > b.start_order;
    if (a.instance.index != b.instance.index) return a.instance.index > b.instance.index;
    return a.instance.generation > b.instance.generation;
}

fn nextGeneration(current: u16) u16 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

const StressContext = struct {
    runtime: *ControlRuntime,
    producers_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    render_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn stressProducer(context: *StressContext, producer: u32) void {
    for (0..1000) |index| {
        const gain = @as(f32, @floatFromInt((index + producer) % 4)) * 0.25;
        while (true) {
            context.runtime.submitBus(.{ .bus = if (producer & 1 == 0) .sfx else .music, .gain = gain, .ramp_frames = 8 }) catch |err| switch (err) {
                error.CommandQueueFull => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => {
                    context.failed.store(true, .release);
                    return;
                },
            };
            break;
        }
    }
    _ = context.producers_done.fetchAdd(1, .release);
}

fn stressControl(context: *StressContext) void {
    while (context.producers_done.load(.acquire) != 4 or context.runtime.normal.count() != 0 or context.runtime.reserved.count() != 0) {
        _ = context.runtime.controlTick(max_control_drain) catch |err| switch (err) {
            error.SnapshotBusy => continue,
            else => {
                context.failed.store(true, .release);
                return;
            },
        };
        std.Thread.yield() catch {};
    }
    context.render_stop.store(true, .release);
}

fn stressRender(context: *StressContext) void {
    var renderer = RuntimeRenderer.init(context.runtime, 48_000);
    var output: [2]f32 = undefined;
    while (!context.render_stop.load(.acquire)) renderer.render(&output, 1, 2);
}

test "reserved commands survive normal queue saturation and preserve sequence" {
    var runtime = ControlRuntime.init();
    const stopped = try runtime.reserveInstance();
    try runtime.submitBus(.{ .bus = .sfx, .gain = 0.5, .ramp_frames = 1 });
    for (1..normal_command_capacity) |_| try runtime.submitBus(.{ .bus = .music, .gain = 0.75, .ramp_frames = 1 });
    try std.testing.expectError(error.CommandQueueFull, runtime.submitBus(.{ .bus = .master, .gain = 1, .ramp_frames = 1 }));
    try runtime.submitStop(.{ .instance = stopped, .fade_frames = 1 });
    try runtime.submitShutdown();
    while (runtime.normal.count() + runtime.reserved.count() > 0) _ = try runtime.controlTick(max_control_drain);
    try std.testing.expect(runtime.telemetry().queue_high_water == normal_command_capacity + 2);
    runtime.instances.release(stopped);
    try runtime.destroy();
}

test "sample owner remains pinned through snapshot and render retirement" {
    const samples = [_]f32{ 0.25, -0.25, 0.5, -0.5 };
    var owner = try SampleOwner.init(&samples);
    var runtime = ControlRuntime.init();
    const instance = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{} });
    _ = try runtime.controlTick(max_control_drain);
    owner.retire();
    try std.testing.expect(!owner.canDestroy());
    var renderer = RuntimeRenderer.init(&runtime, 48_000);
    var output: [32]f32 = undefined;
    renderer.render(&output, 16, 2);
    _ = try runtime.controlTick(max_control_drain);
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "generation-safe single stop rejects stale reuse" {
    const samples = [_]f32{1} ** 64;
    var owner = try SampleOwner.init(&samples);
    defer if (!owner.retired.load(.acquire)) owner.retire();
    var runtime = ControlRuntime.init();
    const first = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = first, .owner = &owner, .params = .{ .loop = true } });
    _ = try runtime.controlTick(max_control_drain);
    var renderer = RuntimeRenderer.init(&runtime, 48_000);
    var output: [32]f32 = undefined;
    renderer.render(&output, 16, 2);
    try runtime.submitStop(.{ .instance = first, .fade_frames = 1 });
    _ = try runtime.controlTick(max_control_drain);
    renderer.render(&output, 16, 2);
    _ = try runtime.controlTick(max_control_drain);
    const completion = runtime.pollCompletion();
    try std.testing.expect(completion != null);
    try std.testing.expect(completion.?.instance.eql(first));
    try std.testing.expectEqual(CompletionReason.stopped, completion.?.reason);
    const second = try runtime.reserveInstance();
    try std.testing.expect(first.index == second.index and first.generation != second.generation);
    try std.testing.expectError(error.StaleInstance, runtime.submitStop(.{ .instance = first, .fade_frames = 1 }));
    runtime.instances.release(second);
    owner.retire();
}

test "concurrent producers control and render preserve bounded snapshots" {
    var runtime = ControlRuntime.init();
    var context: StressContext = .{ .runtime = &runtime };
    var producers: [4]std.Thread = undefined;
    for (&producers, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, stressProducer, .{ &context, @as(u32, @intCast(index)) });
    const control_thread = try std.Thread.spawn(.{}, stressControl, .{&context});
    const render_thread = try std.Thread.spawn(.{}, stressRender, .{&context});
    for (producers) |thread| thread.join();
    control_thread.join();
    render_thread.join();
    try std.testing.expect(!context.failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 4000), runtime.telemetry().accepted_commands);
    try std.testing.expect(runtime.telemetry().snapshot_generation > 0);
    try runtime.destroy();
}

test "control voice policy deterministically rejects and steals beyond 64" {
    const samples = [_]f32{ 0.25, -0.25 } ** 128;
    var owner = try SampleOwner.init(&samples);
    var runtime = ControlRuntime.init();
    for (0..max_render_voices) |_| {
        const instance = try runtime.reserveInstance();
        try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{ .loop = true, .priority = 0.5 } });
    }
    const rejected = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = rejected, .owner = &owner, .params = .{ .loop = true, .priority = 0.25 } });
    const strongest = try runtime.reserveInstance();
    try runtime.submitPlay(.{ .instance = strongest, .owner = &owner, .params = .{ .loop = true, .priority = 1 } });
    _ = try runtime.controlTick(max_control_drain);
    const first = runtime.pollCompletion();
    const second = runtime.pollCompletion();
    try std.testing.expect(first != null and first.?.instance.eql(rejected) and first.?.reason == .rejected);
    try std.testing.expect(second != null and second.?.reason == .stolen);
    try std.testing.expectEqual(@as(u32, max_render_voices), runtime.telemetry().live_instances);
    try std.testing.expectEqual(@as(u64, 1), runtime.telemetry().stolen_instances);

    var renderer = RuntimeRenderer.init(&runtime, 48_000);
    var output: [512]f32 = undefined;
    renderer.render(&output, 256, 2);
    try runtime.submitShutdown();
    _ = try runtime.controlTick(max_control_drain);
    renderer.render(&output, 256, 2);
    _ = try runtime.controlTick(max_control_drain);
    owner.retire();
    try runtime.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "repeated shutdown and destroy are idempotent with all counters retired" {
    const samples = [_]f32{ 0.1, -0.1 } ** 32;
    for (0..32) |_| {
        var owner = try SampleOwner.init(&samples);
        var runtime = ControlRuntime.init();
        const instance = try runtime.reserveInstance();
        try runtime.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{ .loop = true } });
        _ = try runtime.controlTick(max_control_drain);
        var renderer = RuntimeRenderer.init(&runtime, 48_000);
        var output: [64]f32 = undefined;
        renderer.render(&output, 32, 2);
        try runtime.submitShutdown();
        try runtime.submitShutdown();
        _ = try runtime.controlTick(max_control_drain);
        renderer.render(&output, 32, 2);
        _ = try runtime.controlTick(max_control_drain);
        owner.retire();
        owner.retire();
        try runtime.destroy();
        try runtime.destroy();
        const telemetry = runtime.telemetry();
        try std.testing.expectEqual(@as(u32, 0), telemetry.live_instances);
        try std.testing.expectEqual(@as(u32, 0), telemetry.snapshot_pins);
        try std.testing.expectEqual(@as(u32, 0), telemetry.render_pins);
        try std.testing.expect(owner.canDestroy());
    }
}
