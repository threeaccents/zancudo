//! The MQTT side of the server: decides what each packet means and responds
//! to it. State shared by all clients (client IDs, subscriptions) will live
//! here as fields.
const Broker = @This();

const std = @import("std");
const mqtt = @import("mqtt.zig");
const Client = @import("Client.zig");
const FixedHeader = mqtt.FixedHeader;
const Reader = mqtt.Reader;

/// Handles one complete packet from `c`. `body` is everything after the fixed
/// header. It points into the client's input buffer, which gets reused for
/// the next packet, so it's only valid during this call: anything a handler
/// keeps must be copied.
pub fn handlePacket(self: *Broker, c: *Client, header: FixedHeader, body: []const u8) !void {
    switch (header.packet_type) {
        .connect => try self.handleConnect(c, header.flags, body),
        else => {
            return error.PacketTypeNotImplementedYet;
        },
    }
}

fn handleConnect(self: *Broker, c: *Client, flags: u4, body: []const u8) !void {
    _ = self;

    if (flags != 0) return error.Malformed;

    var r = Reader.init(body);

    const proto_name_len = r.readU16() catch return error.Malformed;
    const proto_name = r.readBytes(proto_name_len) catch return error.Malformed;

    if (!std.mem.eql(u8, proto_name, "MQTT")) return error.InvalidProtocolName;

    // protocol level
    if (try r.readByte() != 0x04) return error.InvalidProtocolLevel;

    const connect_flags = r.readByte() catch return error.Malformed;

    _ = connect_flags;

    const keep_alive = r.readU16() catch return error.Malformed;
    c.keep_alive = keep_alive;
}
