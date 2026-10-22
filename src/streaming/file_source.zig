//! Explicit borrowed file-descriptor ReadAt source. No path lookup, hidden cwd,
//! mapped/retained whole file or heap allocation. Host opens/closes the file and
//! keeps it valid until Asset.canDestroy; only the service worker reads it.
const std = @import("std");
const opus = @import("sme-opus");
pub const FileSource = struct {
    file: std.Io.File,
    io: std.Io,
    length: u64,
    read_calls: u64 = 0,
    read_bytes: u64 = 0,
    max_read_bytes: usize = 0,
    pub fn source(self: *FileSource) opus.ByteSource {
        return .{ .context = self, .length = self.length, .read_at = read };
    }
    fn read(context: *anyopaque, offset: u64, destination: []u8) opus.Error!void {
        const self: *FileSource = @ptrCast(@alignCast(context));
        if (offset > self.length or destination.len > self.length - offset) return error.TruncatedContainer;
        self.read_calls +|= 1;
        self.read_bytes +|= destination.len;
        self.max_read_bytes = @max(self.max_read_bytes, destination.len);
        const count = self.file.readPositionalAll(self.io, destination, offset) catch return error.TruncatedContainer;
        if (count != destination.len) return error.TruncatedContainer;
    }
};
