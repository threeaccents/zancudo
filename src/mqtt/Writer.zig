//! Bounds-checked writes into a byte buffer, the counterpart to Reader. A
//! write that doesn't fit returns error.NoSpaceLeft and writes nothing.
const Writer = @This();

const std = @import("std");

buf: []u8,
pos: usize = 0,

pub fn init(buf: []u8) Writer {
    return .{ .buf = buf };
}

pub fn writeByte(self: *Writer, b: u8) !void {
    if (self.pos >= self.buf.len) return error.NoSpaceLeft;

    self.buf[self.pos] = b;

    self.pos += 1;
}

pub fn writeU16(self: *Writer, num: u16) !void {
    if (self.pos + 2 > self.buf.len) return error.NoSpaceLeft;

    std.mem.writeInt(u16, self.buf[self.pos..][0..2], num, .big);

    self.pos += 2;
}

pub fn writeBytes(self: *Writer, b: []const u8) !void {
    if (self.pos + b.len > self.buf.len) return error.NoSpaceLeft;

    @memcpy(self.buf[self.pos..][0..b.len], b);

    self.pos += b.len;
}

pub fn writeString(self: *Writer, str: []const u8) !void {
    if (str.len > std.math.maxInt(u16)) return error.StringTooLong;
    // The 2 length bytes count too, so nothing is written if it won't all fit.
    if (self.pos + 2 + str.len > self.buf.len) return error.NoSpaceLeft;

    try self.writeU16(@intCast(str.len));
    try self.writeBytes(str);
}

/// 7 bits per byte, lowest first. The top bit says another byte follows.
pub fn writeRemainingLength(self: *Writer, len: usize) !void {
    // The most that 4 length bytes can hold.
    if (len > 268_435_455) return error.RemainingLengthTooLong;

    // Encoded first so nothing is written if it won't all fit.
    var encoded: [4]u8 = undefined;
    var count: usize = 0;
    var rest = len;

    // Runs at least once, since a length of 0 is still one byte.
    while (true) {
        var byte: u8 = @intCast(rest % 128);
        rest /= 128;
        if (rest > 0) byte |= 0x80;

        encoded[count] = byte;
        count += 1;

        if (rest == 0) break;
    }

    try self.writeBytes(encoded[0..count]);
}

pub fn written(self: *Writer) []const u8 {
    return self.buf[0..self.pos];
}

test writeByte {
    var buf: [4]u8 = undefined;

    const expected: [4]u8 = .{ 0x01, 0x02, 0x03, 0x04 };

    var w = Writer.init(&buf);

    try w.writeByte(0x01);
    try w.writeByte(0x02);
    try w.writeByte(0x03);
    try w.writeByte(0x04);

    try std.testing.expectEqualSlices(u8, &expected, w.written());
    try std.testing.expectError(error.NoSpaceLeft, w.writeByte(0x05));
}

test writeU16 {
    var buf: [4]u8 = undefined;

    const expected: [4]u8 = .{ 0x00, 0x01, 0x00, 0x02 };

    var w = Writer.init(&buf);

    try w.writeU16(1);
    try w.writeU16(2);

    try std.testing.expectEqualSlices(u8, &expected, w.written());
    try std.testing.expectError(error.NoSpaceLeft, w.writeU16(5));
}

test writeBytes {
    var buf: [4]u8 = undefined;

    const expected: [4]u8 = .{ 0x00, 0x01, 0x00, 0x02 };

    var w = Writer.init(&buf);

    const b: []const u8 = &.{ 0x00, 0x01, 0x00, 0x02 };

    try w.writeBytes(b);
    try w.writeBytes("");

    try std.testing.expectEqualSlices(u8, &expected, w.written());
    try std.testing.expectError(error.NoSpaceLeft, w.writeBytes(b));
}

test writeString {
    var buf: [6]u8 = undefined;

    // An empty string is still its 2 length bytes.
    const expected: [6]u8 = .{ 0x00, 0x02, 'h', 'i', 0x00, 0x00 };

    var w = Writer.init(&buf);

    try w.writeString("hi");
    try w.writeString("");

    try std.testing.expectEqualSlices(u8, &expected, w.written());
    try std.testing.expectError(error.NoSpaceLeft, w.writeString("1"));
}

test writeRemainingLength {
    var buf: [7]u8 = undefined;

    const expected: [7]u8 = .{ 0x00, 0xC1, 0x02, 0xFF, 0xFF, 0xFF, 0x7F };

    var w = Writer.init(&buf);

    try w.writeRemainingLength(0);
    try w.writeRemainingLength(321);
    try w.writeRemainingLength(268_435_455);

    try std.testing.expectEqualSlices(u8, &expected, w.written());
    try std.testing.expectError(error.RemainingLengthTooLong, w.writeRemainingLength(268_435_456));
}

test "all writing methods" {
    var buf: [14]u8 = undefined;

    const expected: [14]u8 = .{ 'h', 'i', 0x00, 0x01, 0x00, 0x02, 'f', 'o', 'o', 0x00, 0x03, 'b', 'a', 'r' };

    var w = Writer.init(&buf);

    try w.writeByte('h');
    try w.writeByte('i');

    try w.writeU16(1);
    try w.writeU16(2);

    try w.writeBytes("foo");

    try w.writeString("bar");

    try std.testing.expectEqualSlices(u8, &expected, w.written());
    try std.testing.expectError(error.NoSpaceLeft, w.writeByte(0x05));
}
