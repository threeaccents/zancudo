//! The MQTT side of the server: decides what each packet means and responds
//! to it. State shared by all clients (client IDs, subscriptions) will live
//! here as fields.
const Broker = @This();

const std = @import("std");
const sys = @import("sys.zig");
const mqtt = @import("mqtt.zig");
const Client = @import("Client.zig");
const ConnAck = mqtt.ConnAck;
const Connect = mqtt.Connect;
const FixedHeader = mqtt.FixedHeader;

const log = std.log.scoped(.broker);

/// The number in the next ID handed to a client that connects with an empty
/// client ID.
next_client_id: u64 = 0,

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

/// Decodes a CONNECT, decides whether to accept it, and answers with a
/// CONNACK. Returns an error, which closes the connection, when the packet is
/// malformed (no CONNACK) or when the CONNACK refuses the client.
fn handleConnect(self: *Broker, c: *Client, flags: u4, body: []const u8) !void {
    // CONNECT is sent once, as the first packet. A second one is a protocol
    // violation.
    if (c.connected) return error.ProtocolViolation;

    const connect = try Connect.decode(flags, body);

    // Not MQTT at all, so there's no point sending an MQTT reply.
    if (!std.mem.eql(u8, connect.protocol_name, "MQTT")) return error.InvalidProtocolName;

    if (connect.protocol_level != 4) {
        try sendConnAck(c, .unacceptable_protocol_version);
        return error.ConnectRefused;
    }

    // An empty ID asks the server to pick one, which is only allowed with a
    // clean session. IDs longer than we have room for are refused too.
    const id = connect.client_id;
    if ((id.len == 0 and !connect.clean_session) or id.len > Client.max_client_id_len) {
        try sendConnAck(c, .identifier_rejected);
        return error.ConnectRefused;
    }

    // TODO: keep connect.will once PUBLISH exists.
    // TODO: check connect.username and connect.password once there's auth.

    if (id.len == 0) {
        // The client left the ID to us. MQTT 3.1.1 never tells the client
        // which one it got, so it only has to be unique among connected
        // clients, and a counter is enough. "z-" plus at most 20 digits is
        // 22 bytes, so it always fits the 23-byte buffer.
        const assigned = std.fmt.bufPrint(&c.client_id_buf, "z-{d}", .{self.next_client_id}) catch unreachable;
        self.next_client_id += 1;
        c.client_id_len = @intCast(assigned.len);
    } else {
        // id points into in_buf, which the next packet overwrites, so copy it.
        @memcpy(c.client_id_buf[0..id.len], id);
        c.client_id_len = @intCast(id.len);
    }
    c.clean_session = connect.clean_session;
    c.keep_alive = connect.keep_alive;
    c.connected = true;

    log.info("client fd = {d} connected as {s}", .{ c.fd, c.client_id_buf[0..c.client_id_len] });
    try sendConnAck(c, .accepted);
}

/// Sends a CONNACK. Sessions aren't stored yet, so there's never one to
/// resume and session_present is always false.
fn sendConnAck(c: *Client, return_code: ConnAck.ReturnCode) !void {
    const ack: ConnAck = .{ .session_present = false, .return_code = return_code };
    try sys.sendAll(c.fd, &ack.encode());
}
