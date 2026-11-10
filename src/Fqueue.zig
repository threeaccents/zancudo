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
    if (record.len > std.math.maxInt(u16)) return error.RecordTooLarge;

    var buf: [2 + std.math.maxInt(u16)]u8 = undefined;

    std.mem.writeInt(u16, buf[0..2], @intCast(record.len), .little);
    @memcpy(buf[2..][0..record.len], record);

    const len = 2 + record.len;

    var fw = self.file.writer(self.io, &.{});

    try fw.seekTo(self.end);
    try fw.interface.writeAll(buf[0..len]);

    self.end += len;
}

pub fn dequeue(self: *Fqueue, out: []u8) !?[]u8 {
    if (self.offset >= self.end) return null;

    var buf: [2 + std.math.maxInt(u16)]u8 = undefined;
    var fr = self.file.reader(self.io, &buf);
    try fr.seekTo(self.offset);

    const record_len = try fr.interface.takeInt(u16, .little);
    if (record_len > out.len) return error.BufferTooSmall;
    try fr.interface.readSliceAll(out[0..record_len]);

    const consumed: u64 = 2 + record_len;
    self.offset += consumed;
    self.dead_bytes += consumed;

    // if (self.offset == self.end) truncate file to 0 and zero the three fields

    return out[0..record_len];
}
