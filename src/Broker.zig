//! The MQTT side of the server: handles each packet and holds the state
//! shared by all clients.
const Broker = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const mqtt = @import("mqtt.zig");
const Conn = @import("Conn.zig");
const ConnAck = mqtt.ConnAck;
const Connect = mqtt.Connect;
const FixedHeader = mqtt.FixedHeader;
const PingResp = mqtt.PingResp;
const SubAck = mqtt.SubAck;
const Subscribe = mqtt.Subscribe;
const TopicTrie = mqtt.TopicTrie;
const Writer = mqtt.Writer;

const log = std.log.scoped(.broker);

/// Used to name clients that connect with an empty client ID.
next_client_id: u64 = 0,
alloc: Allocator,
subscriptions: TopicTrie = .{},
// Conn that fiinished CONNECT, keyed by client_id.
conns: std.StringHashMapUnmanaged(*Conn) = .empty,

/// `body` points into the connection's input buffer and is only valid
/// during this call.
pub fn handlePacket(self: *Broker, conn: *Conn, header: FixedHeader, body: []const u8) !void {
    // connect has to be the first msg sent
    if (!conn.connected and header.packet_type != .connect) return error.ProtocolViolation;

    switch (header.packet_type) {
        .connect => try self.handleConnect(conn, header.flags, body),
        .disconnect => try self.handleDisconnect(conn, header.flags, body),
        .pingreq => try self.handlePingReq(conn, header.flags, body),
        .subscribe => try self.handleSubscribe(conn, header.flags, body),
        else => {
            return error.PacketTypeNotImplementedYet;
        },
    }
}

fn handleSubscribe(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    if (flags != 0x02) return error.Malformed;

    var topics: [32]Subscribe.Topic = undefined;

    const sub = try Subscribe.decode(body, &topics);

    for (sub.topics) |topic| {
        try self.subscriptions.subscribe(self.alloc, topic.filter, conn.clientId(), topic.qos);
    }

    var buf: [32]SubAck.ReturnCode = undefined;
    var filter_codes: std.ArrayList(SubAck.ReturnCode) = .initBuffer(&buf);
    for (sub.topics) |topic| {
        const code: SubAck.ReturnCode = switch (topic.qos) {
            .at_least_once => .granted_qos1,
            .at_most_once => .granted_qos0,
            .exactly_once => .granted_qos2,
        };

        try filter_codes.appendBounded(code);
    }

    try sendSubAck(conn, sub.packet_id, filter_codes.items);
}

fn handlePingReq(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    _ = self;

    if (flags != 0 or body.len != 0) return error.Malformed;

    try sendPingResp(conn);
}

fn handleDisconnect(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    _ = self;

    if (flags != 0 or body.len != 0) return error.Malformed;

    conn.closing = true;
}

/// A refused client gets a CONNACK before it's closed. A malformed CONNECT
/// gets none.
fn handleConnect(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    if (conn.connected) return error.ProtocolViolation;

    const connect = Connect.decode(flags, body) catch return error.Malformed;

    // Not MQTT, so don't answer in MQTT.
    if (!std.mem.eql(u8, connect.protocol_name, "MQTT")) return error.InvalidProtocolName;

    if (connect.protocol_level != 4) {
        try sendConnAck(conn, .unacceptable_protocol_version);
        conn.closing = true;
        return;
    }

    // An empty ID is only allowed with a clean session.
    const id = connect.client_id;
    if ((id.len == 0 and !connect.clean_session) or id.len > Conn.max_client_id_len) {
        try sendConnAck(conn, .identifier_rejected);
        conn.closing = true;
        return;
    }

    // TODO: keep connect.will once PUBLISH exists.
    // TODO: check connect.username and connect.password once there's auth.

    if (id.len == 0) {
        // create an id for them
        const assigned = std.fmt.bufPrint(&conn.client_id_buf, "z-{d}", .{self.next_client_id}) catch unreachable;
        self.next_client_id += 1;
        conn.client_id_len = @intCast(assigned.len);
    } else {
        // id points into in_buf, so copy it.
        @memcpy(conn.client_id_buf[0..id.len], id);
        conn.client_id_len = @intCast(id.len);
    }
    conn.clean_session = connect.clean_session;
    conn.keep_alive = connect.keep_alive;
    conn.connected = true;

    if (conn.clean_session) {
        self.subscriptions.removeSubscriber(self.alloc, conn.clientId());
    }

    if (try self.conns.fetchPut(self.alloc, conn.clientId(), conn)) |old| {
        old.value.closing = true;
        sys.shutdown(old.value.fd);
    }

    log.info("client fd = {d} connected as {s}", .{ conn.fd, conn.client_id_buf[0..conn.client_id_len] });
    try sendConnAck(conn, .accepted);
}

pub fn removeConn(self: *Broker, conn: *Conn) void {
    if (!conn.connected) return;

    const id = conn.clientId();

    // make sure conn still represents the conn being passed in
    if (self.conns.get(id) == conn) {
        _ = self.conns.remove(id);
        self.subscriptions.removeSubscriber(self.alloc, id);
    }
}

/// session_present stays false until sessions are stored.
fn sendConnAck(conn: *Conn, return_code: ConnAck.ReturnCode) !void {
    const ack: ConnAck = .{ .session_present = false, .return_code = return_code };
    var buf: [4]u8 = undefined;
    var w = Writer.init(&buf);
    try ack.encode(&w);
    try sys.sendAll(conn.fd, w.written());
}

fn sendPingResp(conn: *Conn) !void {
    const resp: PingResp = .{};
    var buf: [2]u8 = undefined;
    var w = Writer.init(&buf);
    try resp.encode(&w);
    try sys.sendAll(conn.fd, w.written());
}

fn sendSubAck(conn: *Conn, packet_id: u16, filter_codes: []SubAck.ReturnCode) !void {
    const ack: SubAck = .{ .packet_id = packet_id, .filter_codes = filter_codes };
    var buf: [4096]u8 = undefined;
    var w = Writer.init(&buf);
    try ack.encode(&w);
    try sys.sendAll(conn.fd, w.written());
}
