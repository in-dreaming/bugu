//! Private adapter error mapping, shared with the focused non-injection test.
const c = @import("c.zig").api;
const t = @import("types.zig");
pub const Operation = enum { decoder, encoder };
pub fn classify(operation: Operation, code: i32) t.Error {
    if (code == c.OPUS_ALLOC_FAIL) return error.OutOfMemory;
    return switch (operation) {
        .decoder => error.DecodeFailure,
        .encoder => error.EncodeFailure,
    };
}
