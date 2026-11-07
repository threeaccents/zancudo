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
inflight_msgs: Deque(Publish) = .empty,

// msgs queued up while the client was offline
queued_msgs: Deque(Publish) = .empty,

next_packet_id: usize = 0,

clean_session: bool = true,

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

pub fn appendQueuedMsg(self: *Session, msg: Publish) !void {
    if (self.queued_msgs.len >= 500) return error.OutOfSpace;

    try self.queued_msgs.pushBack(self.alloc, msg);
}

pub fn drainQueuedMsgs(self: *Session) !void {
    if (self.conn == null) return error.ClientOffline;

    while (self.queued_msgs.popFront()) |msg| {
        // check the err and maybe re-add msg to queue to try again
        self.conn.?.send(msg) catch continue;
        self.alloc.destroy(msg);
    }
}
