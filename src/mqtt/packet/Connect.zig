//! CONNECT: the first packet a client sends, client to server only.
const Connect = @This();

const std = @import("std");
const QoS = @import("../packet.zig").QoS;
const Reader = @import("../Reader.zig");

pub const name = "CONNECT";

protocol_name: []const u8,

/// 4 for MQTT 3.1.1. Checked by the broker, since a wrong level still gets a
/// CONNACK.
protocol_level: u8,

clean_session: bool,

/// In seconds. 0 means no timeout.
keep_alive: u16,

client_id: []const u8,

/// Published for the client if it disconnects without a DISCONNECT.
will: ?Will,

username: ?[]const u8,

password: ?[]const u8,

pub const Will = struct {
    topic: []const u8,
    message: []const u8,
    qos: QoS,
    retain: bool,
};

pub fn decode(flags: u4, body: []const u8) !Connect {
    if (flags != 0) return error.Malformed;

    var r = Reader.init(body);

    const proto_name = try r.readString();
    if (!std.mem.eql(u8, proto_name, "MQTT")) return error.InvalidProtocolName;

    const proto_level = try r.readByte();

    if (proto_level != 4) return error.UnacceptableProtocolVersion;

    const connect_flags = try r.readByte();

    const has_username = connect_flags & 0x80 != 0;
    const has_password = connect_flags & 0x40 != 0;
    const will_retain = connect_flags & 0x20 != 0;
    const will_qos = (connect_flags >> 3) & 0x03;
    const will_flag = connect_flags & 0x04 != 0;
    const clean_session = connect_flags & 0x02 != 0;
    const reserved = connect_flags & 0x01 != 0;
    if (reserved) return error.Malformed;

    // Without a will, the will's QoS and retain bits must be 0.
    if (!will_flag and (will_qos != 0 or will_retain)) return error.Malformed;

    // Only QoS 0, 1 and 2 exist.
    if (will_qos == 3) return error.Malformed;

    // MQTT 3.1.1 doesn't allow a password without a username.
    if (has_password and !has_username) return error.Malformed;

    const keep_alive = try r.readU16();

    const client_id = try r.readString();

    if ((!clean_session and client_id.len == 0) or client_id.len > 23) return error.IdentifierRejected;

    var will: ?Will = null;
    if (will_flag) {
        const will_topic = try r.readString();
        if (will_topic.len == 0 or std.mem.indexOfAny(u8, will_topic, "+#") != null) return error.Malformed;

        const will_msg = try r.readString();

        will = .{
            .topic = will_topic,
            .message = will_msg,
            .qos = @fromBackingInt(@intCast(will_qos)),
            .retain = will_retain,
        };
    }

    var username: ?[]const u8 = null;
    if (has_username) {
        username = try r.readString();
    }

    var password: ?[]const u8 = null;
    if (has_password) {
        password = try r.readString();
    }

    // make sure no garbage bytes were sent
    if (r.pos != body.len) return error.Malformed;

    return .{
        .client_id = client_id,
        .protocol_name = proto_name,
        .protocol_level = proto_level,
        .keep_alive = keep_alive,
        .will = will,
        .clean_session = clean_session,
        .username = username,
        .password = password,
    };
}

test "Connect: decode" {
    const testing = std.testing;

    // Flags 0xEE set every field.
    const full = try decode(0, "\x00\x04MQTT\x04\xEE\x00\x3C\x00\x03abc" ++
        "\x00\x01t\x00\x03bye\x00\x01u\x00\x01p");
    try testing.expectEqualStrings("MQTT", full.protocol_name);
    try testing.expectEqual(4, full.protocol_level);
    try testing.expectEqual(60, full.keep_alive);
    try testing.expect(full.clean_session);
    try testing.expectEqualStrings("abc", full.client_id);
    try testing.expectEqualStrings("t", full.will.?.topic);
    try testing.expectEqualStrings("bye", full.will.?.message);
    try testing.expectEqual(.at_least_once, full.will.?.qos);
    try testing.expect(full.will.?.retain);
    try testing.expectEqualStrings("u", full.username.?);
    try testing.expectEqualStrings("p", full.password.?);

    const minimal = try decode(0, "\x00\x04MQTT\x04\x02\x00\x3C\x00\x03abc");
    try testing.expectEqual(null, minimal.will);
    try testing.expectEqual(null, minimal.username);
    try testing.expectEqual(null, minimal.password);
}

test "Connect: decode malformed" {
    const testing = std.testing;

    // Reserved flag bit set.
    try testing.expectError(error.Malformed, decode(0, "\x00\x04MQTT\x04\x03\x00\x3C\x00\x03abc"));
    // Bytes left over after the payload.
    try testing.expectError(error.Malformed, decode(0, "\x00\x04MQTT\x04\x02\x00\x3C\x00\x03abcJUNK"));
    try testing.expectError(error.Malformed, decode(0, "\x00\x04MQTT\x04\x06\x00\x3C\x00\x03abc\x00\x00\x00\x03bye"));
    try testing.expectError(error.Malformed, decode(0, "\x00\x04MQTT\x04\x06\x00\x3C\x00\x03abc\x00\x03a/#\x00\x03bye"));
    try testing.expectError(error.Malformed, decode(0, "\x00\x04MQTT\x04\x06\x00\x3C\x00\x03abc\x00\x03+/b\x00\x03bye"));
}
