const Reader = @This();

const std = @import("std");

buf: []const u8,
pos: usize = 0,

pub fn init(buf: []const u8) Reader {
    return .{ .buf = buf };
}

pub fn readByte(self: *Reader) !u8 {
    if (self.pos >= self.buf.len) return error.EOF;
    const val = self.buf[self.pos];

    self.pos += 1;

    return val;
}

test readByte {
    const buf = "hello";

    var r = Reader.init(buf);

    try std.testing.expectEqual('h', try r.readByte());
    try std.testing.expectEqual('e', try r.readByte());
    try std.testing.expectEqual('l', try r.readByte());
    try std.testing.expectEqual('l', try r.readByte());
    try std.testing.expectEqual('o', try r.readByte());
    try std.testing.expectEqual(error.EOF, r.readByte());
}

pub fn readU16(self: *Reader) !u16 {
    if ((self.pos + 1) >= self.buf.len) return error.EOF;

    const val = std.mem.readInt(u16, self.buf[self.pos..][0..2], .big);

    self.pos += 2;

    return val;
}

test readU16 {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, 500, .big);

    var r = Reader.init(&buf);

    try std.testing.expectEqual(500, try r.readU16());
    try std.testing.expectEqual(error.EOF, r.readU16());
}

pub fn readBytes(self: *Reader, n: usize) ![]const u8 {
    if ((self.pos + n) > self.buf.len) return error.EOF;

    const r = self.buf[self.pos..][0..n];

    self.pos += n;

    return r;
}

test readBytes {
    const buf = "hello";

    var r = Reader.init(buf);

    try std.testing.expectEqualSlices(u8, "hello", try r.readBytes(5));
    try std.testing.expectEqual(error.EOF, r.readBytes(6));
}

test "read mixed types in sequence" {
    const buf = "hello\x01\xF4h";

    var r = Reader.init(buf);

    try std.testing.expectEqualSlices(u8, "hello", try r.readBytes(5));
    try std.testing.expectEqual(500, try r.readU16());
    try std.testing.expectEqual('h', try r.readByte());
    try std.testing.expectEqual(error.EOF, r.readByte());
}
