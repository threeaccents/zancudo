const Fqueue = @This();
const std = @import("std");
const File = std.Io.File;
const Io = std.Io;

file: File,
end: u64 = 0,
io: Io,
offset: u64 = 0,
dead_bytes: u64 = 0,

pub fn init(io: Io, path: []const u8) !Fqueue {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
    });
    errdefer file.close(io);

    const end = try file.length(io);

    return .{
        .file = file,
        .end = end,
        .io = io,
    };
}

pub fn enqueue(self: *Fqueue, record: []const u8) !void {
    var buf: [65538]u8 = undefined;

    const start_offset = self.end;

    var file_writer = self.file.writer(self.io, &.{});
    try file_writer.seekTo(start_offset);

    std.mem.writeInt(u16, buf[0..2], record.len, .big);

    @memcpy(buf[2..], record);

    const len = record.len + 2;

    try file_writer.interface.writeAll(&buf[0..len]);

    self.end += len;
}

pub fn dequeue(self: Fqueue) []u8 {
    _ = self;

    // const record_len = std.mem.readInt(u16, , endian: Endian)
}
