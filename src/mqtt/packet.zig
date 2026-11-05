//! Types shared by every packet, and one struct per packet type in packet/.

pub const ConnAck = @import("packet/ConnAck.zig");
pub const Connect = @import("packet/Connect.zig");
pub const PingResp = @import("packet/PingResp.zig");
pub const SubAck = @import("packet/SubAck.zig");
pub const Subscribe = @import("packet/Subscribe.zig");

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
    publish: void, // TODO
    puback: void, // TODO
    pubrec: void, // TODO
    pubrel: void, // TODO
    pubcomp: void, // TODO
    subscribe: void, // TODO
    suback: SubAck,
    unsubscribe: void, // TODO
    unsuback: void, // TODO
    pingreq: void,
    pingresp: void,
    disconnect: void,
};

test {
    @import("std").testing.refAllDecls(@This());
}
