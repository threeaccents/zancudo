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
    // Not used yet. Zig rejects unused parameters, so discard them until the
    // handler needs them.
    _ = broker;
    _ = c;
    _ = flags;
    _ = body;
    std.debug.print("Handling conenct", .{});
}
