//! The MQTT side of the server: decides what each packet means and responds
//! to it. State shared by all clients (client IDs, subscriptions) will live
//! here as fields.

const std = @import("std");
const Client = @import("Client.zig");
const FixedHeader = @import("mqtt/packet.zig").FixedHeader;

const Broker = @This();

/// Handles one complete packet from `c`. `body` is everything after the fixed
/// header. It points into the client's input buffer, which gets reused for
/// the next packet, so it's only valid during this call: anything a handler
/// keeps must be copied.
pub fn handlePacket(broker: *Broker, c: *Client, header: FixedHeader, body: []const u8) !void {
    switch (header.packet_type) {
        .connect => try broker.handleConnect(c, header.flags, body),
        else => {
            return error.PacketTypeNotImplementedYet;
        },
    }
}

fn handleConnect(broker: *Broker, c: *Client, flags: u4, body: []const u8) !void {
    if (flags != 0) return error.Malformed;
    // todo look into creating a reader to handle malformed bodies
    _ = broker;

    const protocol_name_len = std.mem.readInt(u16, body[0..2], .big);
    const protocol_name = body[2..(protocol_name_len + 2)];

    if (!std.mem.eql(u8, protocol_name, "MQTT")) return error.InvalidProtocolName;

    // protocol level
    if (body[6] != 0x04) return error.InvalidProtocolLevel;

    const connect_flags = body[7];
    _ = connect_flags;

    const keep_alive = std.mem.readInt(u16, body[8..10], .big);
    // should probably add this to client struct
    _ = keep_alive;
}
