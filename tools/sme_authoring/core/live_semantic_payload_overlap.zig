//! Finite input-only exclusion for two unscheduled scalar payload classes.
//! Never reads reference values or mutates live playback. The caller supplies
//! globally occurrence-ordered cuts before creating a replay owner/publishing a tape.
const std = @import("std");
pub const Error = error{ UnsupportedOverlap, InvalidOrder, Incomplete };
const Kind = enum { frame, consumed };
const Access = struct { kind: Kind, site: u64, index: u64, generation: u64 };
pub const Validator = struct {
    /// Only the mandatory wire5 joint planner may discharge frame overlap.
    defer_frame_to_joint: bool = false,
    defer_consumed_to_joint: bool = false,
    read: ?Access = null,
    publication: ?Access = null,
    /// Accept codec.Cut or an equivalent owned source-coordinate value. There
    /// is deliberately no value/prefix/reference argument in this interface.
    pub fn observe(self: *Validator, cut: anytype) Error!void {
        const name = @tagName(cut.site);
        const is_read = std.mem.eql(u8, name, "service_availability_readiness_frame") or
            std.mem.eql(u8, name, "service_availability_acceptance_frame") or
            std.mem.eql(u8, name, "service_readiness_frame") or
            std.mem.eql(u8, name, "service_availability_readiness_control_consumed") or
            std.mem.eql(u8, name, "service_availability_acceptance_control_consumed") or
            std.mem.eql(u8, name, "service_readiness_consumed");
        const is_publication = std.mem.eql(u8, name, "service_stream_observation_frame") or
            std.mem.eql(u8, name, "service_render_consumed");
        if (!is_read and !is_publication) return;
        if (!std.mem.eql(u8, @tagName(cut.role), if (is_read) "control" else "render")) return error.InvalidOrder;
        const frame = std.mem.eql(u8, name, "service_availability_readiness_frame") or
            std.mem.eql(u8, name, "service_availability_acceptance_frame") or
            std.mem.eql(u8, name, "service_readiness_frame") or
            std.mem.eql(u8, name, "service_stream_observation_frame");
        const access: Access = .{ .kind = if (frame) .frame else .consumed, .site = @intFromEnum(cut.site), .index = cut.index, .generation = cut.generation };
        const own = if (is_read) &self.read else &self.publication;
        const other = if (is_read) self.publication else self.read;
        if (std.mem.eql(u8, @tagName(cut.edge), "before")) {
            if (own.* != null) return error.InvalidOrder;
            if (other) |active| {
                // observation_frame belongs to the Service, independent of the
                // source's diagnostic stream label. control_consumed belongs
                // to exactly one slot incarnation.
                if (active.kind == access.kind and (frame or (active.index == access.index and active.generation == access.generation)) and !(if (frame) self.defer_frame_to_joint else self.defer_consumed_to_joint)) return error.UnsupportedOverlap;
            }
            own.* = access;
        } else if (std.mem.eql(u8, @tagName(cut.edge), "after")) {
            if (own.* == null or !std.meta.eql(own.*.?, access)) return error.InvalidOrder;
            own.* = null;
        } else return error.InvalidOrder;
    }
    pub fn finish(self: *const Validator) Error!void {
        if (self.read != null or self.publication != null) return error.Incomplete;
    }
};
