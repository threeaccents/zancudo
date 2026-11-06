//! PUBLISH: an application message, sent by clients to the broker and by
//! the broker to subscribers.
const Publish = @This();

const std = @import("std");
const Reader = @import("../Reader.zig");
const QoS = @import("../packet.zig").QoS;

packet_id: ?u16,
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

    var packet_id: ?u16 = null;
    if (qos != .at_most_once) {
        packet_id = try r.readU16();
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
}
