//! the MQTT server handles each packet and holds the state
//! shared by all clients.
const Broker = @This();

const std = @import("std");
const Io = std.Io;
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
const Unsubscribe = mqtt.Unsubscribe;
const UnsubAck = mqtt.UnsubAck;
const TopicTrie = mqtt.TopicTrie;
const Will = Connect.Will;
const packet = mqtt.packet;
const QoS = mqtt.QoS;

const log = std.log.scoped(.broker);

/// Used to name clients that connect with an empty client ID.
next_client_id: u64 = 0,
alloc: Allocator,
subscriptions: TopicTrie = .{},
// Conn that fiinished CONNECT, keyed by client_id.
conns: std.StringHashMapUnmanaged(*Conn) = .empty,

sessions: std.StringHashMapUnmanaged(*Session) = .empty,

io: Io,

pub fn init(io: Io, alloc: Allocator) Broker {
    return .{ .io = io, .alloc = alloc };
}

/// `body` points into the connection's input buffer and is only valid
/// during this call.
pub fn handlePacket(self: *Broker, conn: *Conn, header: FixedHeader, body: []const u8) !void {
    // connect has to be the first msg sent
    if (!conn.connected and header.packet_type != .connect) return error.ProtocolViolation;

    conn.setLastPacketAt(self.io);

    switch (header.packet_type) {
        .connect => try self.handleConnect(conn, header.flags, body),
        .disconnect => try self.handleDisconnect(conn, header.flags, body),
        .pingreq => try self.handlePingReq(conn, header.flags, body),
        .subscribe => try self.handleSubscribe(conn, header.flags, body),
        .unsubscribe => try self.handleUnsubscribe(conn, header.flags, body),
        .publish => try self.handlePublish(conn, header.flags, body),
        else => {
            return error.PacketTypeNotImplementedYet;
        },
    }
}

/// A refused client gets a CONNACK before it's closed. A malformed CONNECT
/// gets none.
// TODO: check connect.username and connect.password once there's auth.
fn handleConnect(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    if (conn.connected) return error.ProtocolViolation;

    const connect = Connect.decode(flags, body) catch |err| switch (err) {
        error.UnacceptableProtocolVersion => {
            const ack: ConnAck = .{ .session_present = false, .return_code = .unacceptable_protocol_version };
            try conn.send(ack);
            conn.closing = true;
            return;
        },
        error.IdentifierRejected => {
            const ack: ConnAck = .{ .session_present = false, .return_code = .identifier_rejected };
            try conn.send(ack);
            conn.closing = true;
            return;
        },
        else => return error.Malformed,
    };

    conn.setClientId(self.io, connect.client_id);
    const client_id = conn.clientId();

    conn.keep_alive = connect.keep_alive;
    conn.connected = true;

    if (connect.will) |will| try self.storeWill(conn, will);
    errdefer self.dropWill(conn);

    try self.appendConn(conn);

    const sess = try self.getOrSetSession(conn, connect.clean_session);

    log.info("client fd = {d} connected as {s}", .{ conn.fd, client_id });

    const ack: ConnAck = .{ .session_present = sess.existing_session, .return_code = .accepted };

    try sess.sendMsg(ack);

    try sess.drainQueuedMsgs();
}

fn handlePublish(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    _ = conn;

    const p = Publish.decode(flags, body) catch return error.Malformed;

    try self.publish(p);
}

fn publish(self: *Broker, p: Publish) !void {
    var buf: [16 * 1024]TopicTrie.Subscriber = undefined;
    const subscribers = try self.subscriptions.match(p.topic, &buf);

    for (subscribers) |s| {
        const sess = self.sessions.get(s.client_id) orelse continue;

        const qos = getMsgQos(p.qos, s.qos);

        const pub_packet: Publish = .{
            .dup = p.dup,
            .payload = p.payload,
            .qos = qos,
            .retain = p.retain,
            .topic = p.topic,
            .packet_id = if (qos != .at_most_once) sess.packetId() else null,
        };

        sess.sendMsg(pub_packet) catch |err| {
            log.err("Failed to send client publish msg. topic {s} client id {s}. Error: {t}", .{ pub_packet.topic, s.client_id, err });
        };
    }
}

fn getMsgQos(p: QoS, s: QoS) QoS {
    const min = @min(@backingInt(p), @backingInt(s));

    return std.enums.fromInt(QoS, min).?;
}

fn handleSubscribe(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    if (flags != 0x02) return error.Malformed;

    const sess = self.sessions.get(conn.clientId()) orelse return error.SessionNotFound;

    var topics: [32]Subscribe.Topic = undefined;

    const sub = try Subscribe.decode(body, &topics);

    var buf: [32]SubAck.ReturnCode = undefined;
    var filter_codes: std.ArrayList(SubAck.ReturnCode) = .initBuffer(&buf);

    for (sub.topics) |topic| {
        if (!packet.validFilter(topic.filter)) {
            try filter_codes.appendBounded(.failure);
            continue;
        }

        const code: SubAck.ReturnCode = switch (topic.qos) {
            .at_least_once => .granted_qos1,
            .at_most_once => .granted_qos0,
            .exactly_once => .granted_qos2,
        };

        try filter_codes.appendBounded(code);

        try self.subscriptions.subscribe(self.alloc, topic.filter, conn.clientId(), topic.qos);
    }

    const ack: SubAck = .{ .packet_id = sub.packet_id, .filter_codes = filter_codes.items };

    try sess.sendMsg(ack);
}

fn handleUnsubscribe(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    if (flags != 0x02) return error.Malformed;

    const sess = self.sessions.get(conn.clientId()) orelse return error.SessionNotFound;

    var filters: [32][]const u8 = undefined;

    const unsub = try Unsubscribe.decode(body, &filters);

    for (unsub.filters) |filter| {
        self.subscriptions.unsubscribe(self.alloc, filter, conn.clientId());
    }

    const ack: UnsubAck = .{ .packet_id = unsub.packet_id };

    try sess.sendMsg(ack);
}

fn handlePingReq(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    if (flags != 0 or body.len != 0) return error.Malformed;

    const sess = self.sessions.get(conn.clientId()) orelse return error.SessionNotFound;

    const resp: PingResp = .{};
    try sess.sendMsg(resp);
}

fn handleDisconnect(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    if (flags != 0 or body.len != 0) return error.Malformed;

    self.dropWill(conn);
    conn.closing = true;
}

pub fn removeConn(self: *Broker, conn: *Conn) void {
    if (!conn.connected) return;

    const id = conn.clientId();

    // make sure conn still represents the conn being passed in
    if (self.conns.get(id) == conn) {
        _ = self.conns.remove(id);

        if (self.sessions.get(id)) |sess| {
            if (sess.clean_session) {
                self.cleanSession(id);
            } else {
                sess.conn = null;
            }
        }
    }

    self.publishWill(conn);
}

fn storeWill(self: *Broker, conn: *Conn, will: Will) !void {
    var owned = will;

    owned.message = try self.alloc.dupe(u8, owned.message);
    errdefer self.alloc.free(owned.message);

    owned.topic = try self.alloc.dupe(u8, owned.topic);

    conn.will = owned;
}

fn publishWill(self: *Broker, conn: *Conn) void {
    const will = conn.will orelse return;
    defer self.dropWill(conn);

    log.info("publishing will of {s} to {s}", .{ conn.clientId(), will.topic });

    const p: Publish = .{
        .qos = will.qos,
        .dup = false,
        .retain = will.retain,
        .topic = will.topic,
        .payload = will.message,
    };

    self.publish(p) catch |err| {
        log.err("Failed to publish will. topic {s} client id {s}. Error: {t}", .{ will.topic, conn.clientId(), err });
    };
}

fn dropWill(self: *Broker, conn: *Conn) void {
    const will = conn.will orelse return;

    self.alloc.free(will.topic);
    self.alloc.free(will.message);
    conn.will = null;
}

fn removeSession(self: *Broker, client_id: []const u8) void {
    if (self.sessions.fetchRemove(client_id)) |s| {
        s.value.deinit();

        self.alloc.free(s.key);
        self.alloc.destroy(s.value);
    }
}

fn cleanSession(self: *Broker, client_id: []const u8) void {
    self.removeSession(client_id);
    self.subscriptions.removeSubscriber(self.alloc, client_id);
}

fn getOrSetSession(self: *Broker, conn: *Conn, clean_session: bool) !*Session {
    const client_id = conn.clientId();

    const session = self.sessions.get(client_id);

    if (session == null) {
        const key = try self.alloc.dupe(u8, client_id);
        errdefer self.alloc.free(key);

        const sess = try self.alloc.create(Session);
        errdefer self.alloc.destroy(sess);
        sess.* = Session.init(self.alloc, conn, clean_session);

        try self.sessions.put(self.alloc, key, sess);

        return sess;
    }

    if (session.?.clean_session or clean_session) {
        self.cleanSession(client_id);

        const key = try self.alloc.dupe(u8, client_id);
        errdefer self.alloc.free(key);

        const sess = try self.alloc.create(Session);
        errdefer self.alloc.destroy(sess);
        sess.* = Session.init(self.alloc, conn, clean_session);

        try self.sessions.put(self.alloc, key, sess);

        return sess;
    }

    session.?.existing_session = true;
    session.?.conn = conn;

    return session.?;
}

fn appendConn(self: *Broker, conn: *Conn) !void {
    // we might have an old conn still around for this client.
    // So we set the new conn and the old conn we close.
    if (try self.conns.fetchPut(self.alloc, conn.clientId(), conn)) |old| {
        old.value.closing = true;
        sys.shutdown(old.value.fd);
    }
}
