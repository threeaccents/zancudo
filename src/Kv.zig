//! A BitCaskish key vaulue store
const Kv = @This();

const std = @import("std");
const Io = std.Io;
const File = std.Io.File;

index: std.StringHashMapUnmanaged(Record) = .empty,
file: File,

const Operation = enum(u8) { set, del };

pub const Record = struct { offset: usize, len: usize };

pub fn init(io: Io, path: []const u8) Kv {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
    });
    errdefer file.close(io);

    return .{
        .file = file,
    };
}

pub fn set(io: Io, key: []const u8, )
