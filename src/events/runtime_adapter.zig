//! Explicit, Control-thread event adapter for the production runtime. Catalog
//! descriptors are copied; playback uses real InstanceHandle/SampleOwner leases.
const std = @import("std");
const rt = @import("../runtime/runtime.zig");
const music = @import("music");
pub const Choice = struct { sound_id: u64, switch_value: u64 = 0, gain: f32 = 1, pitch: f32 = 1 };
pub const Curve = struct {
    parameter: u64,
    input_min: f32 = 0,
    input_max: f32 = 1,
    output_min: f32 = 0,
    output_max: f32 = 1,
    fn evaluate(self: Curve, value: f32) f32 {
        const t = if (self.input_max == self.input_min) 0 else std.math.clamp((value - self.input_min) / (self.input_max - self.input_min), 0, 1);
        return self.output_min + (self.output_max - self.output_min) * t;
    }
};
pub const Event = struct {
    id: u64,
    choices: []const Choice,
    switch_group: ?u64 = null,
    random: bool = false,
    loop: bool = false,
    volume: f32 = 1,
    volume_rtpc: ?Curve = null,
};
pub const Completion = struct { event: u64, instance: rt.InstanceHandle, reason: rt.CompletionReason };
const Entry = struct { event: Event, first: usize };
const Instance = struct { event: u64, handle: rt.InstanceHandle, terminal: ?rt.CompletionReason = null };
pub const Config = struct {
    /// Counts active instances plus unconsumed terminal credits. The existing
    /// Control pool bounds this adapter; no separate voice/mixer budget exists.
    instance_capacity: u16 = 64,
    seed: u64 = 1,
};

pub const RuntimeAdapterV1 = struct {
    allocator: std.mem.Allocator,
    owner: *music.MusicRuntime,
    bank: music.MusicBankRefV1,
    entries: []Entry,
    choices: []Choice,
    instances: []?Instance,
    completions: []u16,
    completion_read: usize = 0,
    completion_write: usize = 0,
    completion_count: usize = 0,
    active: usize = 0,
    seed: u64,
    switch_group: u64 = 0,
    switch_value: u64 = 0,
    rtpc_id: u64 = 0,
    rtpc_value: f32 = 0,

    pub fn create(allocator: std.mem.Allocator, owner: *music.MusicRuntime, reference: music.MusicBankRefV1, events: []const Event, config: Config) !*RuntimeAdapterV1 {
        if (config.instance_capacity == 0 or config.instance_capacity > rt.max_instances or config.seed == 0 or events.len == 0 or events.len > rt.max_instances) return error.InvalidArgument;
        var choice_count: usize = 0;
        for (events, 0..) |event, i| {
            if (event.id == 0 or event.choices.len == 0 or event.choices.len > rt.max_instances or !std.math.isFinite(event.volume) or event.volume < 0 or event.volume > 4 or (event.random and event.switch_group != null)) return error.InvalidArgument;
            for (events[0..i]) |previous| if (previous.id == event.id) return error.InvalidArgument;
            choice_count = try std.math.add(usize, choice_count, event.choices.len);
            if (choice_count > rt.command_capacity) return error.ResourceLimitExceeded;
            if (event.switch_group) |group| if (group == 0) return error.InvalidArgument;
            if (event.volume_rtpc) |curve| {
                if (curve.parameter == 0 or curve.input_min > curve.input_max) return error.InvalidArgument;
                inline for (.{ curve.input_min, curve.input_max, curve.output_min, curve.output_max }) |value| if (!std.math.isFinite(value)) return error.InvalidArgument;
            }
            for (event.choices) |choice| {
                if (choice.sound_id == 0 or !std.math.isFinite(choice.gain) or !std.math.isFinite(choice.pitch) or choice.gain < 0 or choice.gain > 4 or choice.pitch <= 0) return error.InvalidArgument;
            }
        }
        const entries = try allocator.alloc(Entry, events.len);
        errdefer allocator.free(entries);
        const choices = try allocator.alloc(Choice, choice_count);
        errdefer allocator.free(choices);
        const instances = try allocator.alloc(?Instance, config.instance_capacity);
        errdefer allocator.free(instances);
        @memset(instances, null);
        const completions = try allocator.alloc(u16, config.instance_capacity);
        errdefer allocator.free(completions);
        var first: usize = 0;
        for (events, entries) |event, *entry| {
            @memcpy(choices[first..][0..event.choices.len], event.choices);
            entry.* = .{ .event = event, .first = first };
            entry.event.choices = choices[first..][0..event.choices.len];
            first += event.choices.len;
        }
        const self = try allocator.create(RuntimeAdapterV1);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .owner = owner, .bank = reference, .entries = entries, .choices = choices, .instances = instances, .completions = completions, .seed = config.seed };
        try owner.bindEventAdapterV1(self, reference);
        return self;
    }
    fn check(self: *const RuntimeAdapterV1) !void {
        if (std.Thread.getCurrentId() != self.owner.control_thread) return error.WrongThread;
        if (self.owner.event_adapter != self or self.owner.control_guard.load(.acquire) or self.owner.control.control_active.load(.acquire)) return error.InvalidState;
    }
    pub fn setSwitch(self: *RuntimeAdapterV1, group: u64, value: u64) !void {
        try self.check();
        if (group == 0) return error.InvalidArgument;
        self.switch_group = group;
        self.switch_value = value;
    }
    pub fn setRtpc(self: *RuntimeAdapterV1, id: u64, value: f32) !void {
        try self.check();
        if (id == 0 or !std.math.isFinite(value)) return error.InvalidArgument;
        self.rtpc_id = id;
        self.rtpc_value = value;
    }
    pub fn postEvent(self: *RuntimeAdapterV1, id: u64) !rt.InstanceHandle {
        try self.check();
        if (self.owner.shutdown_requested.load(.acquire)) return error.RuntimeStopped;
        const event = for (self.entries) |entry| {
            if (entry.event.id == id) break entry.event;
        } else return error.EventNotFound;
        const free = for (self.instances, 0..) |entry, i| {
            if (entry == null) break i;
        } else return error.CommandQueueFull;
        var next_seed = self.seed;
        var index: usize = 0;
        if (event.random) {
            next_seed ^= next_seed << 13;
            next_seed ^= next_seed >> 7;
            next_seed ^= next_seed << 17;
            index = @intCast(next_seed % event.choices.len);
        } else if (event.switch_group == self.switch_group) {
            for (event.choices, 0..) |choice, i| if (choice.switch_value == self.switch_value) {
                index = i;
                break;
            };
        }
        const choice = event.choices[index];
        var gain = event.volume * choice.gain;
        if (event.volume_rtpc) |curve| if (curve.parameter == self.rtpc_id) {
            gain *= curve.evaluate(self.rtpc_value);
        };
        if (!std.math.isFinite(gain) or gain < 0 or gain > 4) return error.InvalidArgument;
        const lease = try self.owner.acquireSoundV1(self.bank, choice.sound_id);
        defer lease.release();
        const instance = try self.owner.control.submitNewPlay(lease.owner, .{ .gain = gain, .pitch = choice.pitch, .loop = event.loop, .bus = .sfx });
        self.instances[free] = .{ .event = event.id, .handle = instance };
        self.active += 1;
        self.seed = next_seed;
        return instance;
    }
    fn owns(self: *const RuntimeAdapterV1, handle: rt.InstanceHandle) bool {
        for (self.instances) |entry| if (entry) |instance| if (instance.terminal == null and instance.handle.eql(handle)) return true;
        return false;
    }
    pub fn update(self: *RuntimeAdapterV1, handle: rt.InstanceHandle, params: rt.UpdateCommand) !void {
        try self.check();
        if (!handle.eql(params.instance) or !self.owns(handle)) return error.StaleInstance;
        try self.owner.control.submitUpdate(params);
    }
    pub fn stop(self: *RuntimeAdapterV1, handle: rt.InstanceHandle, fade_frames: u32) !void {
        try self.check();
        if (!self.owns(handle)) return error.StaleInstance;
        try self.owner.control.submitStop(.{ .instance = handle, .fade_frames = fade_frames });
    }
    /// Called synchronously by the actual Control completion owner, before its
    /// optional host queue. Reserved instance/terminal slots make this lossless.
    pub fn recordCompletion(self: *RuntimeAdapterV1, completion: rt.Completion) void {
        for (self.instances, 0..) |*entry, i| if (entry.*) |*instance| {
            if (instance.terminal != null or !instance.handle.eql(completion.instance)) continue;
            std.debug.assert(self.completion_count < self.completions.len and self.active > 0);
            instance.terminal = completion.reason;
            self.active -= 1;
            self.completions[self.completion_write] = @intCast(i);
            self.completion_write = (self.completion_write + 1) % self.completions.len;
            self.completion_count += 1;
            return;
        };
    }
    pub fn pollCompletion(self: *RuntimeAdapterV1) !?Completion {
        try self.check();
        if (self.completion_count == 0) return null;
        const index = self.completions[self.completion_read];
        const instance = self.instances[index].?;
        self.instances[index] = null;
        self.completion_read = (self.completion_read + 1) % self.completions.len;
        self.completion_count -= 1;
        return .{ .event = instance.event, .instance = instance.handle, .reason = instance.terminal.? };
    }
    pub fn retainedBytes(self: *const RuntimeAdapterV1) usize {
        return @sizeOf(RuntimeAdapterV1) + self.entries.len * @sizeOf(Entry) + self.choices.len * @sizeOf(Choice) + self.instances.len * @sizeOf(?Instance) + self.completions.len * @sizeOf(u16);
    }
    /// Active instances must retire through Control first. Unpolled terminal
    /// values own no SampleOwner; explicit adapter destruction may discard them.
    pub fn destroy(self: *RuntimeAdapterV1) !void {
        try self.check();
        if (self.active != 0) return error.DrainPending;
        try self.owner.unbindEventAdapterV1(self);
        const allocator = self.allocator;
        allocator.free(self.entries);
        allocator.free(self.choices);
        allocator.free(self.instances);
        allocator.free(self.completions);
        allocator.destroy(self);
    }
};
