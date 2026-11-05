//! Subscriptions stored as a tree of topic levels: the filter "a/+/c" is
//! the path a, then +, then c from the root, and its subscribers live in the
//! node where the path ends. Filters that share leading levels share nodes.
//!
//! The trie owns copies of everything it keeps (level keys and client IDs),
//! so callers can pass borrowed slices. Free it all with deinit.
const TopicTrie = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const QoS = @import("packet.zig").QoS;

/// The empty level in front of every filter. Not heap-allocated.
root: Node = .{},

pub const Node = struct {
    /// The next level of each filter that continues past this node, keyed
    /// by the level's text. "+" and "#" are ordinary keys.
    children: std.array_hash_map.String(*Node) = .empty,
    /// Clients whose filter ends at this node.
    subscribers: std.ArrayList(Subscriber) = .empty,
};

pub const Subscriber = struct {
    /// Owned copy of the client's ID.
    client_id: []const u8,
    /// The QoS granted for this subscription.
    qos: QoS,
};

/// Frees every node, level key and client ID in the trie.
pub fn deinit(self: *TopicTrie, alloc: Allocator) void {
    deinitNode(&self.root, alloc);
    self.* = undefined;
}

/// Subscribes `client_id` to `filter` with `qos`, creating any missing
/// nodes. If the client is already subscribed to the same filter, only its
/// QoS is updated, as the spec requires. Copies what it keeps, so `filter`
/// and `client_id` can be borrowed. Returns error.InvalidFilter for a filter
/// that breaks the wildcard rules.
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

test "TopicTrie: subscribe" {
    const testing = std.testing;
    // The testing allocator fails the test if deinit misses anything.
    const alloc = testing.allocator;

    var trie: TopicTrie = .{};
    defer trie.deinit(alloc);

    try trie.subscribe(alloc, "a/b", "c1", .at_most_once);
    try trie.subscribe(alloc, "a/c", "c2", .at_least_once);
    // Same client and filter again: replaces the QoS, no second entry.
    try trie.subscribe(alloc, "a/b", "c1", .exactly_once);

    // "a/b" and "a/c" share the "a" node.
    const a = trie.root.children.get("a").?;
    try testing.expectEqual(2, a.children.count());

    const b = a.children.get("b").?;
    try testing.expectEqual(1, b.subscribers.items.len);
    try testing.expectEqualStrings("c1", b.subscribers.items[0].client_id);
    try testing.expectEqual(.exactly_once, b.subscribers.items[0].qos);
}

test "TopicTrie: subscribe rejects invalid filters" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var trie: TopicTrie = .{};
    defer trie.deinit(alloc);

    try testing.expectError(error.InvalidFilter, trie.subscribe(alloc, "a/b#", "c1", .at_most_once));
    try testing.expectError(error.InvalidFilter, trie.subscribe(alloc, "a/#/c", "c1", .at_most_once));
    try testing.expectError(error.InvalidFilter, trie.subscribe(alloc, "a+/c", "c1", .at_most_once));
}
