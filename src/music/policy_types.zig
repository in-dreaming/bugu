//! Shared TASK-015 policy values and validation only. No bank, trace or runtime imports.
const std = @import("std");
pub const stinger = struct {
    pub const version: u16 = 1;
    pub const hard_max_stingers: u16 = 64;
    pub const Error = error{ InvalidPolicy, InvalidIdentity, InvalidSnapshot, InvalidBoundary, InvalidOrder, Overflow };
    pub const Sync = enum { immediate, next_beat, next_bar };
    pub const ConflictPolicy = enum { drop, replace, @"defer" };
    pub const Policy = struct {
        version: u16 = 1,
        max_polyphony: u16,
        repeat_frames: u64,
        deadline_frames: u64,
        sync: Sync,
        conflict: ConflictPolicy,
        priority: u8,
        protected: bool,
        duck_preset: ?u64,

        pub fn validate(self: Policy, max_stingers: u16) Error!void {
            if (self.version != version or max_stingers == 0 or max_stingers > hard_max_stingers or self.max_polyphony == 0 or self.max_polyphony > max_stingers) return error.InvalidPolicy;
            if (self.duck_preset) |id| if (id == 0) return error.InvalidPolicy;
        }
    };
};
pub const acoustic = struct {
    pub const version: u16 = 1;
    pub const one: u32 = 65536;
    pub const Input = enum { openness, room, path };
    pub const Missing = enum { hold_last, neutral };
    pub const Error = error{ InvalidPolicy, InvalidIdentity, InvalidScalar, InvalidOrder, ConflictingSourceVersion, InvalidState };
    pub const Policy = struct {
        version: u16 = 1,
        minimum_q16: i32,
        maximum_q16: i32,
        neutral_q16: i32,
        attack_frames: u64,
        release_frames: u64,
        rate_per_second_q16: u32,
        quantize_intervals: u32,
        stale_frames: u64,
        missing: Missing,
        pub fn validate(self: Policy) Error!void {
            if (self.version != version or self.minimum_q16 >= self.maximum_q16 or self.neutral_q16 < self.minimum_q16 or self.neutral_q16 > self.maximum_q16 or self.rate_per_second_q16 == 0 or self.quantize_intervals == 0 or self.quantize_intervals > one) return error.InvalidPolicy;
        }
    };
};
