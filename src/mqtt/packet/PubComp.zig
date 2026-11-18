const PubComp = @This();

const std = @import("std");
const Writer = @import("../Writer.zig");
const Reader = @import("../Reader.zig");

pub const name = "PUBCOMP";

packet_id: u16,

pub fn decode(body: []const u8) !PubComp {
    if (body.len != 2) return error.Malformed;

    var r = Reader.init(body);

    const packet_id = try r.readU16();

    return .{ .packet_id = packet_id };
}

pub fn encode(self: PubComp, w: *Writer) !void {
    try w.writeByte(0x70);
    try w.writeRemainingLength(2);
    try w.writeU16(self.packet_id);
}

test "PubComp: decode" {
    const testing = std.testing;

    const ack = try decode("\x00\x0a");
    try testing.expectEqual(10, ack.packet_id);

    try testing.expectError(error.Malformed, decode("\x00"));
    try testing.expectError(error.Malformed, decode("\x00\x0a\x00"));
}

test "PubComp: encode" {
    const testing = std.testing;

    const ack: PubComp = .{ .packet_id = 10 };

    var buf: [4]u8 = undefined;
    var w = Writer.init(&buf);
    try ack.encode(&w);

    const expected: [4]u8 = .{ 0x70, 0x02, 0x00, 0x0A };
    try testing.expectEqualSlices(u8, &expected, w.written());
}
