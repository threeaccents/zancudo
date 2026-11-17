const UnsubAck = @This();

const std = @import("std");
const Writer = @import("../Writer.zig");

packet_id: u16,

pub fn encode(self: UnsubAck, w: *Writer) !void {
    try w.writeByte(0xB0);
    try w.writeRemainingLength(2);
    try w.writeU16(self.packet_id);
}

test "UnsubAck: encode" {
    const testing = std.testing;

    const ack: UnsubAck = .{ .packet_id = 10 };

    var buf: [5]u8 = undefined;
    var w = Writer.init(&buf);
    try ack.encode(&w);

    const expected: [4]u8 = .{ 0xB0, 0x02, 0x00, 0x0A };
    try testing.expectEqualSlices(u8, &expected, w.written());
}
