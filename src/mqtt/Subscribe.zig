//! SUBSCRIBE: a client asking for messages on one or more topic filters,
//! client to server only. Each filter comes with the highest QoS the client
//! wants to receive on it.
const Subscribe = @This();

const std = @import("std");
const Reader = @import("Reader.zig");
const QoS = @import("packet.zig").QoS;

packet_id: u16,
topics: []Topic,

pub const Topic = struct {
    filter: []const u8,
    qos: QoS,
};

pub fn decode(body: []const u8, topic_buf: []Topic) !Subscribe {
    var r = Reader.init(body);

    const packet_id = try r.readU16();

    if (packet_id == 0) return error.Malformed;

    var topics: std.ArrayList(Topic) = .initBuffer(topic_buf);

    while (r.pos < body.len) {
        const filter = try r.readString();
        if (filter.len == 0) return error.Malformed;

        const qos = std.enums.fromInt(QoS, try r.readByte()) orelse return error.Malformed;

        topics.appendBounded(.{
            .filter = filter,
            .qos = qos,
        }) catch return error.TooManyTopics;
    }

    if (topics.items.len == 0) return error.Malformed;

    return .{
        .packet_id = packet_id,
        .topics = topics.items,
    };
}

test "Subscribe: decode" {
    const testing = std.testing;

    var buf: [8]Topic = undefined;

    // Packet ID 1: "test" at QoS 0, then "a/b" at QoS 1.
    const sub = try decode("\x00\x01\x00\x04test\x00\x00\x03a/b\x01", &buf);
    try testing.expectEqual(1, sub.packet_id);
    try testing.expectEqual(2, sub.topics.len);
    try testing.expectEqualStrings("test", sub.topics[0].filter);
    try testing.expectEqual(.at_most_once, sub.topics[0].qos);
    try testing.expectEqualStrings("a/b", sub.topics[1].filter);
    try testing.expectEqual(.at_least_once, sub.topics[1].qos);
}

test "Subscribe: decode malformed" {
    const testing = std.testing;

    var buf: [8]Topic = undefined;

    // No topics after the packet ID.
    try testing.expectError(error.Malformed, decode("\x00\x01", &buf));
    // QoS 3 doesn't exist.
    try testing.expectError(error.Malformed, decode("\x00\x01\x00\x01a\x03", &buf));
    // More topics than the buffer holds.
    try testing.expectError(error.TooManyTopics, decode("\x00\x01\x00\x01a\x00\x00\x01b\x00", buf[0..1]));
}
