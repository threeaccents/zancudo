//! the MQTT server handles each packet and holds the state
//! shared by all clients.
const Broker = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const mqtt = @import("mqtt.zig");
const Conn = @import("Conn.zig");
const Session = @import("Session.zig");
const ConnAck = mqtt.ConnAck;
const Connect = mqtt.Connect;
const FixedHeader = mqtt.FixedHeader;
const PingResp = mqtt.PingResp;
const PubAck = mqtt.PubAck;
const Publish = mqtt.Publish;
const SubAck = mqtt.SubAck;
const Subscribe = mqtt.Subscribe;
const TopicTrie = mqtt.TopicTrie;

const log = std.log.scoped(.broker);

/// Used to name clients that connect with an empty client ID.
next_client_id: u64 = 0,
alloc: Allocator,
subscriptions: TopicTrie = .{},
// Conn that fiinished CONNECT, keyed by client_id.
conns: std.StringHashMapUnmanaged(*Conn) = .empty,

sessions: std.StringHashMapUnmanaged(*Session) = .empty,

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
        .publish => try self.handlePublish(conn, header.flags, body),
        else => {
            return error.PacketTypeNotImplementedYet;
        },
    }
}

fn handlePublish(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    _ = conn;

    const p = Publish.decode(flags, body) catch return error.Malformed;

    var buf: [16 * 1024]TopicTrie.Subscriber = undefined;
    const subscribers = try self.subscriptions.match(p.topic, &buf);

    for (subscribers) |s| {
        const sesh = self.sessions.get(s.client_id) orelse continue;
        const pub_packet: Publish = .{ .dup = p.dup, .payload = p.payload, .qos = p.qos, .retain = p.retain, .topic = p.topic };

        if (sesh.conn) |sesh_conn| {
            sesh_conn.send(pub_packet) catch |err| {
                log.err("Failed to send publish to subscriber. client id: {s}. error {t}", .{ sesh_conn.clientId(), err });

                continue;
            };
        } else {
            const owned_pub = try self.alloc.create(Publish);
            owned_pub.* = pub_packet;
            sesh.appendQueuedMsg(owned_pub) catch continue;
        }
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

    const ack: SubAck = .{ .packet_id = sub.packet_id, .filter_codes = filter_codes.items };
    try conn.send(ack);
}

fn handlePingReq(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    _ = self;

    if (flags != 0 or body.len != 0) return error.Malformed;

    const resp: PingResp = .{};
    try conn.send(resp);
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
        const ack: ConnAck = .{ .session_present = false, .return_code = .unacceptable_protocol_version };
        try conn.send(ack);
        conn.closing = true;
        return;
    }

    // An empty ID is only allowed with a clean session.
    const id = connect.client_id;
    if ((id.len == 0 and !connect.clean_session) or id.len > Conn.max_client_id_len) {
        const ack: ConnAck = .{ .session_present = false, .return_code = .identifier_rejected };
        try conn.send(ack);
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

    const client_id = conn.clientId();

    if (try self.conns.fetchPut(self.alloc, client_id, conn)) |old| {
        old.value.closing = true;
        sys.shutdown(old.value.fd);
    }

    if (conn.clean_session) {
        _ = self.sessions.remove(client_id);
        self.subscriptions.removeSubscriber(self.alloc, client_id);
    }

    var session_present = false;

    const gop = try self.sessions.getOrPut(self.alloc, client_id);
    if (!gop.found_existing) {
        errdefer _ = self.sessions.remove(client_id);

        const key = try self.alloc.dupe(u8, client_id);
        errdefer self.alloc.free(key);

        const sesh = try self.alloc.create(Session);
        sesh.* = Session.init(self.alloc, conn, connect.clean_session);

        gop.key_ptr.* = key;
        gop.value_ptr.* = sesh;
    } else {
        log.debug("Found existing session. Client id: {s}", .{client_id});
        session_present = true;
        gop.value_ptr.*.conn = conn;

        try gop.value_ptr.*.drainQueuedMsgs();
    }

    log.info("client fd = {d} connected as {s}", .{ conn.fd, client_id });

    const ack: ConnAck = .{ .session_present = session_present, .return_code = .accepted };

    try conn.send(ack);
}

pub fn removeConn(self: *Broker, conn: *Conn) void {
    if (!conn.connected) return;

    const id = conn.clientId();

    // make sure conn still represents the conn being passed in
    if (self.conns.get(id) == conn) {
        _ = self.conns.remove(id);

        if (self.sessions.get(id)) |sesh| {
            if (sesh.clean_session) {
                self.subscriptions.removeSubscriber(self.alloc, id);
                if (self.sessions.fetchRemove(id)) |s| {
                    self.alloc.free(s.key);
                    self.alloc.destroy(s.value);
                }
            } else {
                sesh.conn = null;
            }
        }
    }
}
