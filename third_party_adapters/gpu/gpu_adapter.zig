const std = @import("std");

pub const c = @cImport({
    @cInclude("gpu_viz_api.h");
});

pub const GpuError = error{
    GpuFailed,
};

pub fn check(result: c.GpuResult) GpuError!void {
    if (result != c.GPU_SUCCESS) return error.GpuFailed;
}

pub fn checkMsg(result: c.GpuResult, comptime msg: []const u8) GpuError!void {
    if (result != c.GPU_SUCCESS) {
        std.log.err("{s}: gpu result={d}", .{ msg, result });
        return error.GpuFailed;
    }
}
