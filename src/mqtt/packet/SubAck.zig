//! SUBACK: the server's reply to SUBSCRIBE, with one return code per topic
//! filter, in the same order.
const SubAck = @This();

const std = @import("std");
const Writer = @import("../Writer.zig");

pub const name = "SUBACK";

packet_id: u16,
filter_codes: []const ReturnCode,

pub const ReturnCode = enum(u8) {
    granted_qos0 = 0x00,
    granted_qos1 = 0x01,
    granted_qos2 = 0x02,
    failure = 0x80,
};

pub fn encode(self: SubAck, w: *Writer) !void {
    try w.writeByte(0x90);
    // The packet ID, then one byte per code.
    try w.writeRemainingLength(2 + self.filter_codes.len);
    try w.writeU16(self.packet_id);
    for (self.filter_codes) |code| try w.writeByte(@backingInt(code));
}

test "SubAck: encode" {
    const testing = std.testing;

    const ack: SubAck = .{
        .packet_id = 10,
        .filter_codes = &.{ .granted_qos0, .granted_qos1, .failure },
    };

    var buf: [7]u8 = undefined;
    var w = Writer.init(&buf);
    try ack.encode(&w);

    const expected: [7]u8 = .{ 0x90, 0x05, 0x00, 0x0A, 0x00, 0x01, 0x80 };
    try testing.expectEqualSlices(u8, &expected, w.written());
}
