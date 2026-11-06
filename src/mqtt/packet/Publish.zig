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

