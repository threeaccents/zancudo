const Session = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Conn = @import("Conn.zig");
const sys = @import("sys.zig");
const linux = std.os.linux;
const mqtt = @import("mqtt.zig");
const Publish = mqtt.Publish;
const Deque = std.Deque;

const log = std.log.scoped(.session);

const max_inflight_msgs = 50;

// null means the client is offline.
conn: ?*Conn,

alloc: Allocator,

// QoS 1&2 msgs waiting for responses
inflight_msgs: std.array_hash_map.Auto(u16, Publish) = .empty,

// msgs queued up while the client was offline
queued_msgs: Deque(Publish) = .empty,

next_packet_id: u16 = 1,

clean_session: bool = true,

// was this session new or restablished
existing_session: bool = false,

//   clean_session = 0 (persistent session)
// - If a session exists for that ID, the server MUST resume it. If none exists, it MUST create
//   one.
// - After a disconnect, the server MUST keep the session.
// - While the client is offline, the server MUST store QoS 1 and QoS 2 messages that match the
//   subscriptions the client had when it disconnected. It MAY store QoS 0 messages too.
// - A resumed session keeps its subscriptions, so the client doesn't have to subscribe again.
//
// clean_session = 1
// - The server MUST discard any previous session for that ID, including its subscriptions and
//   queued messages.
// - The new session lasts only as long ;as the network connection.
// - Its state MUST NOT be reused by any later session.
// clean_session: u4,
//
//

pub fn init(alloc: Allocator, conn: *Conn, clean_session: bool) Session {
    return .{
        .alloc = alloc,
        .conn = conn,
        .clean_session = clean_session,
    };
}

pub fn deinit(self: *Session) void {
    for (self.inflight_msgs.values()) |msg| {
        self.alloc.free(msg.topic);
        self.alloc.free(msg.payload);
    }

    self.inflight_msgs.deinit(self.alloc);

    while (self.queued_msgs.popFront()) |msg| {
        self.alloc.free(msg.topic);
        self.alloc.free(msg.payload);
    }

    self.queued_msgs.deinit(self.alloc);
}

pub fn sendMsg(self: *Session, msg: anytype) !void {
    switch (@TypeOf(msg)) {
        Publish => try self.sendPublish(msg),
        else => {
            if (self.conn) |conn| try conn.send(msg);
        },
    }
}

fn sendPublish(self: *Session, msg: Publish) !void {
    // check if client is online. If they are not queue the msg
    // if qos 1/2 check if inflight buffer is full if it is add msg to queue
    // send that bitch
    if (self.conn == null) return self.appendQueuedMsg(msg);

    var conn = self.conn.?;

    if (msg.qos == .at_least_once or msg.qos == .exactly_once) {
        if (self.inflight_msgs.count() >= max_inflight_msgs) {
            // inflight buffer full so just queue the msg
            return self.appendQueuedMsg(msg);
        }

        try self.appendInflightMsg(msg);
    }

    // follow the spec better. For now just log
    conn.send(msg) catch |err| {
        log.err("Failed to send msg {s} {t}", .{ msg.topic, err });
    };
}

pub fn packetId(self: *Session) u16 {
    const id = self.next_packet_id;

    self.next_packet_id += 1;

    if (self.next_packet_id > 65534) self.next_packet_id = 1;

    return id;
}

pub fn appendQueuedMsg(self: *Session, msg: Publish) !void {
    if (self.queued_msgs.len >= 500) return error.OutOfSpace;

    var owned = msg;

    owned.payload = try self.alloc.dupe(u8, owned.payload);
    errdefer self.alloc.free(owned.payload);

    owned.topic = try self.alloc.dupe(u8, owned.topic);
    errdefer self.alloc.free(owned.topic);

    try self.queued_msgs.pushBack(self.alloc, owned);
}

pub fn drainQueuedMsgs(self: *Session) !void {
    if (self.conn == null) return error.ClientOffline;

    while (self.queued_msgs.popFront()) |msg| {
        // check the err and maybe re-add msg to queue to try again
        self.conn.?.send(msg) catch continue;

        if (msg.qos != .at_most_once) try self.appendInflightMsg(msg);

        self.alloc.free(msg.topic);
        self.alloc.free(msg.payload);
    }
}

pub fn resendInflightMsgs(self: *Session) !void {
    for (self.inflight_msgs.values()) |msg| {
        var resend = msg;

        resend.dup = true;

        self.conn.?.send(resend) catch |err| {
            log.err("failed to resend inflight msg {d}. error {t}", .{ resend.packet_id.?, err });
            return;
        };
    }
}

pub fn appendInflightMsg(self: *Session, msg: Publish) !void {
    // if inflight is full we queue the msg
    if (self.inflight_msgs.count() >= max_inflight_msgs) unreachable;

    var owned = msg;

    owned.payload = try self.alloc.dupe(u8, owned.payload);
    errdefer self.alloc.free(owned.payload);

    owned.topic = try self.alloc.dupe(u8, owned.topic);
    errdefer self.alloc.free(owned.topic);

    try self.inflight_msgs.put(self.alloc, owned.packet_id.?, owned);
}

pub fn removeInflightMsg(self: *Session, packet_id: u16) void {
    if (self.inflight_msgs.fetchOrderedRemove(packet_id)) |msg| {
        self.alloc.free(msg.value.payload);
        self.alloc.free(msg.value.topic);
    }
}

test "sendPublish offline client gets put in the queue" {
    const allocator = std.testing.allocator;

    var sess: Session = .{
        .conn = null,
        .alloc = allocator,
    };
    defer sess.deinit();

    const msg: Publish = .{
        .packet_id = 1,
        .qos = .at_most_once,
        .dup = true,
        .retain = true,
        .payload = &.{},
        .topic = &.{},
    };

    try sess.sendPublish(msg);

    const p = sess.queued_msgs.popFront().?;

    try std.testing.expectEqual(msg.packet_id, p.packet_id);
}

test "sendPublish qos 1/2 get put in queue if inflight buffer is full" {
    const allocator = std.testing.allocator;
    const fds = try sys.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    var conn: Conn = .{ .fd = fds[0], .epfd = 6, .addr = .{
        .ip = .{ 127, 0, 0, 1 },
        .port = 4269,
    } };
    var sess: Session = .{
        .conn = &conn,
        .alloc = allocator,
    };
    defer sess.deinit();

    // fill buffer
    for (0..50) |n| {
        try sess.appendInflightMsg(.{
            .dup = true,
            .payload = "test payload",
            .topic = "test_topoc",
            .packet_id = @intCast(n),
            .qos = .at_least_once,
            .retain = true,
        });
    }

    const msg: Publish = .{
        .packet_id = 1,
        .qos = .at_least_once,
        .dup = true,
        .retain = true,
        .payload = &.{},
        .topic = &.{},
    };

    try sess.sendPublish(msg);

    const p = sess.queued_msgs.popFront().?;

    try std.testing.expectEqual(msg.packet_id, p.packet_id);
}

test "sendPublish qos 1/2 gets added to the inflight queue" {
    const allocator = std.testing.allocator;
    const fds = try sys.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    var conn: Conn = .{ .fd = fds[0], .epfd = 6, .addr = .{
        .ip = .{ 127, 0, 0, 1 },
        .port = 4269,
    } };

    var sess: Session = .{
        .conn = &conn,
        .alloc = allocator,
    };
    defer sess.deinit();

    const msg: Publish = .{
        .packet_id = 1,
        .qos = .at_least_once,
        .dup = true,
        .retain = true,
        .payload = &.{},
        .topic = &.{},
    };

    try sess.sendPublish(msg);

    try std.testing.expectEqual(1, sess.inflight_msgs.count());
    try std.testing.expectEqual(msg.packet_id, sess.inflight_msgs.values()[0].packet_id);
}
