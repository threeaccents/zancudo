const TopicTrie = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const QoS = @import("packet.zig").QoS;

root: Node = .{},

pub const Node = struct {
    children: std.array_hash_map.String(*Node) = .empty,
    subscribers: std.ArrayList(Subscriber) = .empty,
};

pub const Subscriber = struct {
    client_id: []const u8,
    qos: QoS,
};

pub fn deinit(self: *TopicTrie, alloc: Allocator) void {
    deinitNode(&self.root, alloc);
    self.* = undefined;
}

pub fn subscribe(self: *TopicTrie, alloc: Allocator, filter: []const u8, client_id: []const u8, qos: QoS) !void {
    if (!validFilter(filter)) return error.InvalidFilter;

    var levels = std.mem.splitScalar(u8, filter, '/');

    var node = &self.root;

    while (levels.next()) |level| {
        const gop = try node.children.getOrPut(alloc, level);
        if (!gop.found_existing) {
            errdefer _ = node.children.swapRemove(level);

            const key = try alloc.dupe(u8, level);
            errdefer alloc.free(key);

            const child = try alloc.create(Node);

            gop.key_ptr.* = key;
            child.* = .{};
            gop.value_ptr.* = child;
        }
        node = gop.value_ptr.*;
    }

    // just update the exisitng sub instead of adding duplicates
    for (node.subscribers.items) |*sub| {
        if (std.mem.eql(u8, sub.client_id, client_id)) {
            sub.qos = qos;

            return;
        }
    }

    // Free the copy again if it can't be added to the list.
    const id = try alloc.dupe(u8, client_id);
    errdefer alloc.free(id);

    try node.subscribers.append(alloc, .{ .client_id = id, .qos = qos });
}

/// Checks a topic filter against MQTT's wildcard rules: it can't be empty,
/// "#" is only allowed as the whole last level ("a/#"), and "+" only as a
/// whole level ("a/+/c"). Empty levels ("a//b") are allowed.
fn validFilter(filter: []const u8) bool {
    if (filter.len == 0) return false;

    var levels = std.mem.splitScalar(u8, filter, '/');
    while (levels.next()) |level| {
        if (std.mem.indexOfScalar(u8, level, '#') != null) {
            // peek is non-null when another level follows, even an empty one,
            // so "a/#/" is rejected too.
            if (level.len != 1 or levels.peek() != null) return false;
        }
        if (std.mem.indexOfScalar(u8, level, '+') != null and level.len != 1) return false;
    }

    return true;
}

/// Frees everything below `node` and everything `node` owns, but not `node`
/// itself: the root isn't heap-allocated, and each child is destroyed by its
/// parent.
fn deinitNode(node: *Node, alloc: Allocator) void {
    for (node.children.keys(), node.children.values()) |key, child| {
        // Free the child's own children and subscribers before the child.
        deinitNode(child, alloc);
        // The node came from alloc.create, the key from alloc.dupe.
        alloc.destroy(child);
        alloc.free(key);
    }
    node.children.deinit(alloc);

    // Each client ID is a copy made in subscribe.
    for (node.subscribers.items) |sub| alloc.free(sub.client_id);
    node.subscribers.deinit(alloc);
}
