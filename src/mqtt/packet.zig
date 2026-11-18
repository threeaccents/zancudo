//! Types shared by every packet, and one struct per packet type in packet/.
const std = @import("std");

pub const ConnAck = @import("packet/ConnAck.zig");
pub const Connect = @import("packet/Connect.zig");
pub const PingResp = @import("packet/PingResp.zig");
pub const PubAck = @import("packet/PubAck.zig");
pub const Publish = @import("packet/Publish.zig");
pub const SubAck = @import("packet/SubAck.zig");
pub const Subscribe = @import("packet/Subscribe.zig");
pub const Unsubscribe = @import("packet/Unsubscribe.zig");
pub const UnsubAck = @import("packet/UnsubAck.zig");
pub const PubRec = @import("packet/PubRec.zig");
pub const PubRel = @import("packet/PubRel.zig");
pub const PubComp = @import("packet/PubComp.zig");

pub const PacketType = enum(u4) {
    connect = 1,
    connack = 2,
    publish = 3,
    puback = 4,
    pubrec = 5,
    pubrel = 6,
    pubcomp = 7,
    subscribe = 8,
    suback = 9,
    unsubscribe = 10,
    unsuback = 11,
    pingreq = 12,
    pingresp = 13,
    disconnect = 14,
};

pub const QoS = enum(u2) {
    at_most_once = 0,
    at_least_once = 1,
    exactly_once = 2,
};

/// Slices inside point into the buffer the packet was decoded from.
pub const Packet = union(PacketType) {
    connect: Connect,
    connack: ConnAck,
    publish: Publish,
    puback: PubAck,
    pubrec: PubRec,
    pubrel: PubRel,
    pubcomp: PubComp,
    subscribe: Subscribe,
    suback: SubAck,
    unsubscribe: Unsubscribe,
    unsuback: UnsubAck,
    pingreq: void,
    pingresp: PingResp,
    disconnect: void,
};

/// "#" is only valid as the whole last level and "+" only as a whole level.
pub fn validFilter(filter: []const u8) bool {
    if (filter.len == 0) return false;

    var levels = std.mem.splitScalar(u8, filter, '/');
    while (levels.next()) |level| {
        if (std.mem.indexOfScalar(u8, level, '#') != null) {
            // Nothing can follow "#", not even an empty level.
            if (level.len != 1 or levels.peek() != null) return false;
        }
        if (std.mem.indexOfScalar(u8, level, '+') != null and level.len != 1) return false;
    }

    return true;
}

test "validFilter" {
    const testing = std.testing;

    try testing.expect(validFilter("a/b"));
    try testing.expect(validFilter("a/+/c"));
    try testing.expect(validFilter("a/#"));
    try testing.expect(validFilter("#"));

    try testing.expect(!validFilter(""));
    try testing.expect(!validFilter("a/b#"));
    try testing.expect(!validFilter("a+/c"));
    try testing.expect(!validFilter("a/#/c"));
    try testing.expect(!validFilter("a/#/"));
}

test {
    @import("std").testing.refAllDecls(@This());
}
