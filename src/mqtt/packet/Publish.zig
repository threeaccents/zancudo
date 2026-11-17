//! PUBLISH: an application message, sent by clients to the broker and by
//! the broker to subscribers.
const Publish = @This();

const std = @import("std");
const Reader = @import("../Reader.zig");
const QoS = @import("../packet.zig").QoS;
const Writer = @import("../Writer.zig");

packet_id: ?u16 = null,
qos: QoS,
dup: bool,
retain: bool,
topic: []const u8,
payload: []const u8,

pub fn decode(flags: u4, body: []const u8) !Publish {
    var r = Reader.init(body);

    const retain = flags & 0b0001 != 0;
    const dup = flags & 0b1000 != 0;
    const qos_flag = (flags >> 1) & 0b11;

    const qos = std.enums.fromInt(QoS, qos_flag) orelse return error.Malformed;
    if (dup and qos == .at_most_once) return error.Malformed;

    const topic = try r.readString();
    if (topic.len == 0 or std.mem.indexOfAny(u8, topic, "+#") != null) return error.Malformed;

    var packet_id: ?u16 = null;
    if (qos != .at_most_once) {
        const id = try r.readU16();
        if (id == 0) return error.Malformed;
        packet_id = id;
    }

    // the remaing bytes is the payload
    const payload = body[r.pos..];

    return .{
        .qos = qos,
        .retain = retain,
        .dup = dup,
        .packet_id = packet_id,
        .topic = topic,
        .payload = payload,
    };
}

pub fn encode(self: Publish, w: *Writer) !void {
    const first_byte: u8 = @as(u8, 3) << 4 | @as(u8, @intFromBool(self.dup)) << 3 | @as(u8, @backingInt(self.qos)) << 1 | @as(u8, @intFromBool(self.retain));

    const packet_id_len: usize = if (self.packet_id != null) 2 else 0;

    const len = (self.topic.len + 2) + packet_id_len + self.payload.len;

    try w.writeByte(first_byte);
    try w.writeRemainingLength(len);
    try w.writeString(self.topic);
    if (self.packet_id) |id| try w.writeU16(id);
    try w.writeBytes(self.payload);
}

test "Publish: decode" {
    const testing = std.testing;

    // QoS 0 has no packet ID, so the payload starts right after the topic.
    const p0 = try decode(0b0000, "\x00\x03a/b21C");
    try testing.expectEqual(.at_most_once, p0.qos);
    try testing.expectEqual(null, p0.packet_id);
    try testing.expectEqualStrings("a/b", p0.topic);
    try testing.expectEqualStrings("21C", p0.payload);

    // QoS 1 with RETAIN: packet ID 10 sits between the topic and the payload.
    const p1 = try decode(0b0011, "\x00\x03a/b\x00\x0a21C");
    try testing.expectEqual(.at_least_once, p1.qos);
    try testing.expect(p1.retain);
    try testing.expectEqual(10, p1.packet_id);
    try testing.expectEqualStrings("21C", p1.payload);
}

test "Publish: decode malformed" {
    const testing = std.testing;

    // QoS 3 doesn't exist.
    try testing.expectError(error.Malformed, decode(0b0110, "\x00\x03a/b\x00\x0a"));
    // DUP is only for QoS 1 and 2.
    try testing.expectError(error.Malformed, decode(0b1000, "\x00\x03a/b"));
    // Empty topic.
    try testing.expectError(error.Malformed, decode(0b0000, "\x00\x0021C"));
    // QoS 1 with packet ID 0.
    try testing.expectError(error.Malformed, decode(0b0010, "\x00\x03a/b\x00\x0021C"));
}

test "Publish: decode rejects wildcards in the topic" {
    const testing = std.testing;

    try testing.expectError(error.Malformed, decode(0b0000, "\x00\x03a/#21C"));
    try testing.expectError(error.Malformed, decode(0b0000, "\x00\x03+/b21C"));
    try testing.expectError(error.Malformed, decode(0b0000, "\x00\x03a+b21C"));
}
