const TopicTrie = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Conn = @import("../Conn.zig");
const QoS = @import("packet.zig").QoS;

root: Node = .{},

pub const Node = struct {
    children: std.StringArrayHashMapUnmanaged(*Node) = .empty,
    subscribers: std.ArrayList(Subscriber) = .empty,
};

pub const Subscriber = struct {
    topic: []const u8,
    client_id: []const u8,
    qos: QoS,
};

pub fn subscribe(self: *TopicTrie, alloc: Allocator, path: []const u8, client_id: []const u8, qos: QoS) !void {
    const levels = std.mem.splitScalar(u8, path, '/');

    var node = &self.root;

    while (levels.next()) |level| {
        const gop = try node.children.getOrPut(alloc, level);
        if (!gop.found_existing) {
            gop.key_ptr.* = try alloc.dupe(u8, level);

            const child = try alloc.create(Node);
            child.* = .{};
            gop.value_ptr.* = child;
        }
        node = gop.value_ptr.*;
    }
}
