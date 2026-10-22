//! Dedicated production process: exactly one capture OR one fresh replay.
const std = @import("std");
const cli = @import("sme-live-history-cli");
pub fn main(init: std.process.Init) void {
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &.{});
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &.{});
    var storage: [64 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    var iterator = std.process.Args.Iterator.initAllocator(init.minimal.args, fixed.allocator()) catch {
        stderr.interface.writeAll("live.ArgumentLimit\n") catch {};
        std.process.exit(2);
    };
    defer iterator.deinit();
    _ = iterator.skip();
    var arguments: [33][]const u8 = undefined;
    var count: usize = 0;
    while (iterator.next()) |arg| {
        if (count == arguments.len) {
            stderr.interface.writeAll("live.ArgumentLimit\n") catch {};
            std.process.exit(2);
        }
        arguments[count] = arg;
        count += 1;
    }
    cli.run(init.gpa, init.io, arguments[0..count], &stdout.interface) catch |err| {
        stderr.interface.print("live.{s}: command failed; no replay success inferred; inspect any output files\n", .{@errorName(err)}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
    stdout.interface.flush() catch std.process.exit(1);
}
