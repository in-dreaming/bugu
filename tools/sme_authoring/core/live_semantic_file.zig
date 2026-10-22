//! Sole non-RT collector sinks. No testing imports, native-role callbacks,
//! allocator or unbounded queue. Admit @sizeOf(FileSink) as resident staging.
//! Transport seal, successful file sync/close, and publication are distinct.
const std = @import("std");
const format = @import("live_semantic_recording.zig").format;
pub const buffer_bytes: usize = 64 * 1024;

/// Generic synchronous bounded staging; useful for files or caller-provided
/// storage. The raw sink must not retain slices. Init before sharing binding,
/// then keep this buffer and its raw context at stable addresses until retired.
pub const BufferedSink = struct {
    raw: format.StreamSink,
    buffer: [buffer_bytes]u8 = undefined,
    buffered: usize = 0,
    /// Acknowledged raw bytes only, not a guaranteed file extent after failure.
    written: u64 = 0,
    first_error: ?anyerror = null,

    pub fn init(raw: format.StreamSink) BufferedSink {
        return .{ .raw = raw };
    }
    pub fn binding(self: *BufferedSink) format.StreamSink {
        return .{ .context = self, .write = write };
    }
    fn write(context: *anyopaque, bytes: []const u8) !usize {
        const self: *BufferedSink = @ptrCast(@alignCast(context));
        if (self.first_error) |err| return err;
        const count = @min(bytes.len, self.buffer.len - self.buffered);
        @memcpy(self.buffer[self.buffered..][0..count], bytes[0..count]);
        self.buffered += count;
        if (self.buffered == self.buffer.len) try self.flush();
        return count;
    }
    pub fn flush(self: *BufferedSink) !void {
        if (self.first_error) |err| return err;
        errdefer |err| self.first_error = err;
        var offset: usize = 0;
        while (offset < self.buffered) {
            const pending = self.buffer[offset..self.buffered];
            const n = try self.raw.write(self.raw.context, pending);
            if (n == 0 or n > pending.len) return error.InvalidWrite;
            self.written = std.math.add(u64, self.written, n) catch return error.CounterOverflow;
            offset += n;
        }
        self.buffered = 0;
    }
};

/// Owns the supplied file handle after in-place init. Init only once in final
/// storage: BufferedSink's raw callback points back to this FileSink. The caller
/// closes on every path and retains this object while a Recorder borrows it.
pub const FileSink = struct {
    io: std.Io,
    file: std.Io.File,
    closed: bool,
    buffered: BufferedSink,

    pub fn init(self: *FileSink, io: std.Io, file: std.Io.File) void {
        self.io = io;
        self.file = file;
        self.closed = false;
        self.buffered = BufferedSink.init(.{ .context = self, .write = rawWrite });
    }
    fn rawWrite(context: *anyopaque, bytes: []const u8) !usize {
        const self: *FileSink = @ptrCast(@alignCast(context));
        if (self.closed) return error.StreamFileClosed;
        return self.file.writeStreaming(self.io, &.{}, &.{bytes}, 1);
    }
    fn write(context: *anyopaque, bytes: []const u8) !usize {
        const self: *FileSink = @ptrCast(@alignCast(context));
        if (self.closed) return error.StreamFileClosed;
        const sink = self.buffered.binding();
        return sink.write(sink.context, bytes);
    }
    pub fn binding(self: *FileSink) format.StreamSink {
        return .{ .context = self, .write = write };
    }
    pub fn failure(self: *const FileSink) ?anyerror {
        return self.buffered.first_error;
    }
    pub fn flush(self: *FileSink) !void {
        if (self.closed) return error.StreamFileClosed;
        try self.buffered.flush();
    }
    /// Explicit finalization, not publication or directory-fsync durability.
    /// Failure leaves uncertain external bytes; caller must not publish success.
    pub fn syncAndClose(self: *FileSink) !void {
        if (self.closed) return error.StreamFileClosed;
        errdefer |err| if (self.buffered.first_error == null) {
            self.buffered.first_error = err;
        };
        try self.flush();
        try self.file.sync(self.io);
        self.close();
    }
    /// Abort closes without flushing/retrying an uncertain write. Idempotent.
    pub fn close(self: *FileSink) void {
        if (!self.closed) self.file.close(self.io);
        self.closed = true;
    }
};
