//! Topic filters stored by level, so the subscribers of a topic can be found
//! without checking every subscription. The trie owns its own copies of
//! levels and client IDs.
const TopicTrie = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const QoS = @import("packet.zig").QoS;

root: Node = .{},

pub const Node = struct {
    /// Keyed by level. Wildcards are stored like any other level.
    children: std.array_hash_map.String(*Node) = .empty,
    /// Subscribers whose filter ends at this node.
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

/// Subscribe a client to a filter. Subscribing again to the same filter
/// only updates the QoS.
pub fn subscribe(self: *TopicTrie, alloc: Allocator, filter: []const u8, client_id: []const u8, qos: QoS) !void {
    var levels = std.mem.splitScalar(u8, filter, '/');

    var node = &self.root;

    while (levels.next()) |level| {
        const child = node.children.get(level) orelse blk: {
            const key = try alloc.dupe(u8, level);
            errdefer alloc.free(key);

            const val = try alloc.create(Node);
            errdefer alloc.destroy(val);
            val.* = .{};

            try node.children.put(alloc, key, val);
            break :blk val;
        };

        node = child;
    }

    // just update the exisitng sub instead of adding duplicates
    for (node.subscribers.items) |*sub| {
        if (std.mem.eql(u8, sub.client_id, client_id)) {
            sub.qos = qos;

            return;
        }
    }

    const id = try alloc.dupe(u8, client_id);
    errdefer alloc.free(id);

    try node.subscribers.append(alloc, .{ .client_id = id, .qos = qos });
}

/// Collects the subscribers of every filter matching `topic` into `buf`. A
/// client with several matching filters is in the result once per filter.
/// `topic` must not contain wildcards.
pub fn match(self: *const TopicTrie, topic: []const u8, buf: []Subscriber) ![]Subscriber {
    var found: std.ArrayList(Subscriber) = .initBuffer(buf);
    var levels = std.mem.splitScalar(u8, topic, '/');

    // "+" and "#" as the first level don't match topics starting with "$".
    if (std.mem.startsWith(u8, topic, "$")) {
        const first = levels.next().?;
        if (self.root.children.get(first)) |child| try matchNode(child, levels, &found);
    } else {
        try matchNode(&self.root, levels, &found);
    }

    // dedup later
    return found.items;
}

fn matchNode(node: *const Node, levels: std.mem.SplitIterator(u8, .scalar), found: *std.ArrayList(Subscriber)) !void {
    var rest = levels;
    const level = rest.next() orelse {
        try found.appendSliceBounded(node.subscribers.items);
        // "a/#" also matches "a".
        if (node.children.get("#")) |hash| try found.appendSliceBounded(hash.subscribers.items);
        return;
    };

    if (node.children.get("#")) |hash| try found.appendSliceBounded(hash.subscribers.items);
    if (node.children.get("+")) |plus| try matchNode(plus, rest, found);
    if (node.children.get(level)) |child| try matchNode(child, rest, found);
}

pub fn removeSubscriber(self: *TopicTrie, alloc: Allocator, client_id: []const u8) void {
    rmSub(alloc, &self.root, client_id);
}

fn rmSub(alloc: Allocator, node: *Node, client_id: []const u8) void {
    // Backwards, because swapRemoveAt moves the last child into the freed
    // slot, and going backwards that child has already been visited.
    var index = node.children.count();
    while (index > 0) {
        index -= 1;
        const child = node.children.values()[index];
        rmSub(alloc, child, client_id);

        if (child.children.count() == 0 and child.subscribers.items.len == 0) {
            const key = node.children.keys()[index];
            node.children.swapRemoveAt(index);
            alloc.free(key);
            // Empty, but its list and map can still hold allocated capacity.
            deinitNode(child, alloc);
            alloc.destroy(child);
        }
    }

    for (node.subscribers.items, 0..) |sub, i| {
        if (std.mem.eql(u8, sub.client_id, client_id)) {
            _ = node.subscribers.swapRemove(i);
            alloc.free(sub.client_id);

            break;
        }
    }
}

/// Frees everything a node owns, but not the node itself.
fn deinitNode(node: *Node, alloc: Allocator) void {
    for (node.children.keys(), node.children.values()) |key, child| {
        deinitNode(child, alloc);
        alloc.destroy(child);
        alloc.free(key);
    }
    node.children.deinit(alloc);

    for (node.subscribers.items) |sub| alloc.free(sub.client_id);
    node.subscribers.deinit(alloc);
}

test "TopicTrie: subscribe" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var trie: TopicTrie = .{};
    defer trie.deinit(alloc);

    try trie.subscribe(alloc, "a/b", "c1", .at_most_once);
    try trie.subscribe(alloc, "a/c", "c2", .at_least_once);
    // Replaces the QoS instead of adding a second subscriber.
    try trie.subscribe(alloc, "a/b", "c1", .exactly_once);

    const a = trie.root.children.get("a").?;
    try testing.expectEqual(2, a.children.count());

    const b = a.children.get("b").?;
    try testing.expectEqual(1, b.subscribers.items.len);
    try testing.expectEqualStrings("c1", b.subscribers.items[0].client_id);
    try testing.expectEqual(.exactly_once, b.subscribers.items[0].qos);
}

test "TopicTrie: match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var trie: TopicTrie = .{};
    defer trie.deinit(alloc);

    try trie.subscribe(alloc, "a/b", "exact", .at_most_once);
    try trie.subscribe(alloc, "a/+", "plus", .at_most_once);
    try trie.subscribe(alloc, "a/#", "hash", .at_most_once);
    try trie.subscribe(alloc, "#", "all", .at_most_once);
    try trie.subscribe(alloc, "$SYS/#", "sys", .at_most_once);

    var buf: [8]Subscriber = undefined;

    try testing.expectEqual(4, (try trie.match("a/b", &buf)).len);
    // "+" is one level, "#" any number.
    try testing.expectEqual(2, (try trie.match("a/b/c", &buf)).len);
    try testing.expectEqual(1, (try trie.match("$SYS/uptime", &buf)).len);

    const parent = try trie.match("a", &buf);
    try testing.expectEqual(2, parent.len);
    try testing.expectEqualStrings("all", parent[0].client_id);
    try testing.expectEqualStrings("hash", parent[1].client_id);

    var small: [1]Subscriber = undefined;
    try testing.expectError(error.OutOfMemory, trie.match("a/b", &small));
}

test "TopicTrie: removeSubscriber" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var trie: TopicTrie = .{};
    defer trie.deinit(alloc);

    try trie.subscribe(alloc, "a/b", "c1", .at_most_once);
    try trie.subscribe(alloc, "a/b", "c2", .at_most_once);
    try trie.subscribe(alloc, "a/c", "c1", .at_most_once);
    try trie.subscribe(alloc, "x/y", "c1", .at_most_once);

    trie.removeSubscriber(alloc, "c1");

    // Only a/b is left, for c2. The emptied nodes are pruned.
    try testing.expectEqual(1, trie.root.children.count());
    const a = trie.root.children.get("a").?;
    try testing.expectEqual(1, a.children.count());

    const b = a.children.get("b").?;
    try testing.expectEqual(1, b.subscribers.items.len);
    try testing.expectEqualStrings("c2", b.subscribers.items[0].client_id);
}
