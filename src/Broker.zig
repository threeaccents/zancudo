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
const TopicTrie = mqtt.TopicTrie;

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

/// A refused client gets a CONNACK before it's closed. A malformed CONNECT
/// gets none.
// TODO: keep connect.will once PUBLISH exists.
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

    conn.clean_session = connect.clean_session;
    conn.keep_alive = connect.keep_alive;
    conn.connected = true;

    if (conn.clean_session) self.cleanSession(client_id);

    try self.setConn(conn);

    const sess = try self.getOrSetSession(conn, connect.clean_session);

    log.info("client fd = {d} connected as {s}", .{ conn.fd, client_id });

    const ack: ConnAck = .{ .session_present = sess.existing_session, .return_code = .accepted };

    try conn.send(ack);

    try sess.drainQueuedMsgs();
}

fn handlePublish(self: *Broker, conn: *Conn, flags: u4, body: []const u8) !void {
    _ = conn;

    const p = Publish.decode(flags, body) catch return error.Malformed;

    var buf: [16 * 1024]TopicTrie.Subscriber = undefined;
    const subscribers = try self.subscriptions.match(p.topic, &buf);

    for (subscribers) |s| {
        const sesh = self.sessions.get(s.client_id) orelse continue;

        const pub_packet: Publish = .{
            .dup = p.dup,
            .payload = p.payload,
            .qos = p.qos,
            .retain = p.retain,
            .topic = p.topic,
            .packet_id = if (p.qos != .at_most_once) sesh.packetId() else null,
        };

        if (sesh.conn) |sesh_conn| {
            sesh_conn.send(pub_packet) catch |err| {
                log.err("Failed to send publish to subscriber. client id: {s}. error {t}", .{ sesh_conn.clientId(), err });

                continue;
            };
        } else {
            sesh.appendQueuedMsg(pub_packet) catch continue;
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

pub fn closeConn(self: *Broker, conn: *Conn) void {
    if (!conn.connected) return;

    const id = conn.clientId();

    // make sure conn still represents the conn being passed in
    if (self.conns.get(id) == conn) {
        _ = self.conns.remove(id);

        if (self.sessions.get(id)) |sesh| {
            if (sesh.clean_session) {
                self.cleanSession(id);
            } else {
                sesh.conn = null;
            }
        }
    }
}

fn removeSession(self: *Broker, client_id: []const u8) void {
    if (self.sessions.fetchRemove(client_id)) |s| {
        self.alloc.free(s.key);
        self.alloc.destroy(s.value);
    }
}

fn cleanSession(self: *Broker, client_id: []const u8) void {
    self.removeSession(client_id);
    self.removeSubscribers(client_id);
}

fn getOrSetSession(self: *Broker, conn: *Conn, clean_session: bool) !*Session {
    const client_id = conn.clientId();

    const gop = try self.sessions.getOrPut(self.alloc, client_id);
    if (!gop.found_existing or gop.value_ptr.*.clean_session) {
        self.cleanSession(client_id);
        errdefer _ = self.sessions.remove(client_id);

        const key = try self.alloc.dupe(u8, client_id);
        errdefer self.alloc.free(key);

        const sesh = try self.alloc.create(Session);
        sesh.* = Session.init(self.alloc, conn, clean_session);

        gop.key_ptr.* = key;
        gop.value_ptr.* = sesh;

        return sesh;
    }

    log.debug("Found existing session. Client id: {s}", .{client_id});
    gop.value_ptr.*.conn = conn;
    gop.value_ptr.*.existing_session = true;

    return gop.value_ptr.*;
}

fn removeSubscribers(self: *Broker, client_id: []const u8) void {
    self.subscriptions.removeSubscriber(self.alloc, client_id);
}

fn setConn(self: *Broker, conn: *Conn) !void {
    // we might have an old conn still around for this client.
    // So we set the new conn and the old conn we close.
    if (try self.conns.fetchPut(self.alloc, conn.clientId(), conn)) |old| {
        old.value.closing = true;
        sys.shutdown(old.value.fd);
    }
}
