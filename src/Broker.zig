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
const PingResp = mqtt.PingResp;
const Subscribe = mqtt.Subscribe;

const log = std.log.scoped(.broker);

/// The number in the next ID handed to a client that connects with an empty
/// client ID.
next_client_id: u64 = 0,

/// Handles one complete packet from `c`. `body` is everything after the fixed
/// header. It points into the client's input buffer, which gets reused for
/// the next packet, so it's only valid during this call: anything a handler
/// keeps must be copied.
pub fn handlePacket(self: *Broker, c: *Client, header: FixedHeader, body: []const u8) !void {
    // connect has to be the first msg sent
    if (!c.connected and header.packet_type != .connect) return error.ProtocolViolation;

    switch (header.packet_type) {
        .connect => try self.handleConnect(c, header.flags, body),
        .disconnect => try self.handleDisconnect(c, header.flags, body),
        .pingreq => try self.handlePingReq(c, header.flags, body),
        .subscribe => try self.handleSubscribe(c, header.flags, body),
        else => {
            return error.PacketTypeNotImplementedYet;
        },
    }
}

fn handleSubscribe(self: *Broker, c: *Client, flags: u4, body: []const u8) !void {
    _ = self;
    _ = c;

    if (flags != 0x02) return error.Malformed;

    var topics: [32]Subscribe.Topic = undefined;

    const sub = try Subscribe.decode(body, &topics);

    _ = sub;
}

fn handlePingReq(self: *Broker, c: *Client, flags: u4, body: []const u8) !void {
    _ = self;

    if (flags != 0 or body.len != 0) return error.Malformed;

    try sendPingResp(c);
}

fn handleDisconnect(self: *Broker, c: *Client, flags: u4, body: []const u8) !void {
    _ = self;

    if (flags != 0 or body.len != 0) return error.Malformed;

    c.closing = true;
}

/// Decodes a CONNECT, decides whether to accept it, and answers with a
/// CONNACK. A refused client gets its CONNACK and is then marked closing. A
/// malformed packet returns an error and gets no CONNACK.
fn handleConnect(self: *Broker, c: *Client, flags: u4, body: []const u8) !void {
    // CONNECT is sent once, as the first packet. A second one is a protocol
    // violation.
    if (c.connected) return error.ProtocolViolation;

    const connect = Connect.decode(flags, body) catch return error.Malformed;

    // Not MQTT at all, so there's no point sending an MQTT reply.
    if (!std.mem.eql(u8, connect.protocol_name, "MQTT")) return error.InvalidProtocolName;

    if (connect.protocol_level != 4) {
        try sendConnAck(c, .unacceptable_protocol_version);
        c.closing = true;
        return;
    }

    // An empty ID asks the server to pick one, which is only allowed with a
    // clean session. IDs longer than we have room for are refused too.
    const id = connect.client_id;
    if ((id.len == 0 and !connect.clean_session) or id.len > Client.max_client_id_len) {
        try sendConnAck(c, .identifier_rejected);
        c.closing = true;
        return;
    }

    // TODO: keep connect.will once PUBLISH exists.
    // TODO: check connect.username and connect.password once there's auth.

    if (id.len == 0) {
        // create an id for them
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

fn sendPingResp(c: *Client) !void {
    const resp: PingResp = .{};
    try sys.sendAll(c.fd, &resp.encode());
}
