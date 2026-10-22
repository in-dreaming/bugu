//! Canonical v2 scalar codec. Field declaration order is wire order; integer
//! widths and enum codes are frozen by the schema. Never dumps native structs.
const std = @import("std");
pub const Error = error{ BufferTooSmall, Truncated, InvalidEnum, InvalidBoolean, TrailingBytes, InvalidLength };
pub const Encoder = struct {
    bytes: []u8,
    offset: usize = 0,
    pub fn put(self: *Encoder, value: anytype) Error!void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .int => |i| {
                if (i.bits % 8 != 0) @compileError("wire integer width must be bytes");
                const n = i.bits / 8;
                if (self.bytes.len - self.offset < n) return error.BufferTooSmall;
                std.mem.writeInt(T, self.bytes[self.offset..][0..n], value, .little);
                self.offset += n;
            },
            .bool => try self.put(@as(u8, if (value) 1 else 0)),
            .@"enum" => try self.put(@intFromEnum(value)),
            .array => for (value) |v| try self.put(v),
            .@"struct" => |s| inline for (s.fields) |f| try self.put(@field(value, f.name)),
            .optional => {
                try self.put(value != null);
                if (value) |v| try self.put(v);
            },
            .@"union" => |u| {
                const tag = std.meta.activeTag(value);
                try self.put(tag);
                inline for (u.fields) |f| if (std.mem.eql(u8, @tagName(tag), f.name)) try self.put(@field(value, f.name));
            },
            .void => {},
            else => @compileError("Noncanonical wire type: " ++ @typeName(T)),
        }
    }
};
pub const Decoder = struct {
    bytes: []const u8,
    offset: usize = 0,
    pub fn get(self: *Decoder, comptime T: type) Error!T {
        return switch (@typeInfo(T)) {
            .int => |i| blk: {
                if (i.bits % 8 != 0) @compileError("wire integer width must be bytes");
                const n = i.bits / 8;
                if (self.bytes.len - self.offset < n) return error.Truncated;
                const v = std.mem.readInt(T, self.bytes[self.offset..][0..n], .little);
                self.offset += n;
                break :blk v;
            },
            .bool => switch (try self.get(u8)) {
                0 => false,
                1 => true,
                else => error.InvalidBoolean,
            },
            .@"enum" => |e| blk: {
                const raw = try self.get(e.tag_type);
                inline for (e.fields) |f| if (raw == f.value) break :blk @enumFromInt(raw);
                return error.InvalidEnum;
            },
            .array => |a| blk: {
                var v: T = undefined;
                for (&v) |*item| item.* = try self.get(a.child);
                break :blk v;
            },
            .@"struct" => |s| blk: {
                var v: T = undefined;
                inline for (s.fields) |f| @field(v, f.name) = try self.get(f.type);
                break :blk v;
            },
            .optional => |o| if (try self.get(bool)) try self.get(o.child) else null,
            .@"union" => |u| blk: {
                const tag = try self.get(u.tag_type.?);
                inline for (u.fields) |f| if (std.mem.eql(u8, @tagName(tag), f.name)) break :blk @unionInit(T, f.name, try self.get(f.type));
                return error.InvalidEnum;
            },
            .void => {},
            else => @compileError("Noncanonical wire type: " ++ @typeName(T)),
        };
    }
    pub fn finish(self: Decoder) Error!void {
        if (self.offset != self.bytes.len) return error.TrailingBytes;
    }
};
pub fn maxSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .int => |i| i.bits / 8,
        .bool => 1,
        .@"enum" => |e| maxSize(e.tag_type),
        .array => |a| a.len * maxSize(a.child),
        .@"struct" => |s| blk: {
            var n: usize = 0;
            inline for (s.fields) |f| n += maxSize(f.type);
            break :blk n;
        },
        .optional => |o| 1 + maxSize(o.child),
        .@"union" => |u| blk: {
            var n: usize = 0;
            inline for (u.fields) |f| n = @max(n, maxSize(f.type));
            break :blk maxSize(u.tag_type.?) + n;
        },
        .void => 0,
        else => @compileError("Noncanonical wire type"),
    };
}
