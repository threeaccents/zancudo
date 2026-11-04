//! Reads values from the front of a byte slice, checking bounds on every read.
//! Packet bodies come from the network, so they can't be trusted to be as long
//! as they claim: a read past the end returns error.EOF instead of crashing.
const Reader = @This();

const std = @import("std");

/// The bytes being read. Not owned: the caller keeps them alive.
buf: []const u8,

/// Index of the next byte to read.
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

pub fn readU16(self: *Reader) !u16 {
    if ((self.pos + 1) >= self.buf.len) return error.EOF;

    const val = std.mem.readInt(u16, self.buf[self.pos..][0..2], .big);

    self.pos += 2;

    return val;
}

pub fn readBytes(self: *Reader, n: usize) ![]const u8 {
    if ((self.pos + n) > self.buf.len) return error.EOF;

    const r = self.buf[self.pos..][0..n];

    self.pos += n;

    return r;
}

test "Reader: readByte" {
    const testing = std.testing;

    const buf = "hello";

    var r = Reader.init(buf);

    try testing.expectEqual('h', try r.readByte());
    try testing.expectEqual('e', try r.readByte());
    try testing.expectEqual('l', try r.readByte());
    try testing.expectEqual('l', try r.readByte());
    try testing.expectEqual('o', try r.readByte());
    try testing.expectEqual(error.EOF, r.readByte());
}

test "Reader: readU16" {
    const testing = std.testing;

    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, 500, .big);

    var r = Reader.init(&buf);

    try testing.expectEqual(500, try r.readU16());
    try testing.expectEqual(error.EOF, r.readU16());
}

test "Reader: readBytes" {
    const testing = std.testing;

    const buf = "hello";

    var r = Reader.init(buf);

    try testing.expectEqualSlices(u8, "hello", try r.readBytes(5));
    try testing.expectEqual(error.EOF, r.readBytes(6));
}

test "Reader: read mixed types in sequence" {
    const testing = std.testing;

    const buf = "hello\x01\xF4h";

    var r = Reader.init(buf);

    try testing.expectEqualSlices(u8, "hello", try r.readBytes(5));
    try testing.expectEqual(500, try r.readU16());
    try testing.expectEqual('h', try r.readByte());
    try testing.expectEqual(error.EOF, r.readByte());
}
