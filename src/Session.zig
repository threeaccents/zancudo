const Session = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Conn = @import("Conn.zig");
const mqtt = @import("mqtt.zig");
const Publish = mqtt.Publish;
const Deque = std.Deque;

// null means the client is offline.
conn: ?*Conn,

alloc: Allocator,

// QoS 1&2 msgs waiting for responses
inflight_msgs: [50]Publish = undefined,
inflight_msgs_len: u8 = 0,

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

        if (msg.qos == .at_most_once) {
            self.alloc.free(msg.topic);
            self.alloc.free(msg.payload);
        } else {
            self.appendInflightMsg(msg);
        }
    }
}

pub fn appendInflightMsg(self: *Session, msg: Publish) void {
    // override the oldest msgs.
    if (self.inflight_msgs_len >= self.inflight_msgs.len) self.inflight_msgs_len = 0;

    self.inflight_msgs[self.inflight_msgs_len] = msg;

    self.inflight_msgs_len += 1;
}
