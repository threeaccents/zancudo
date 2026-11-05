//! MQTT packets: the types shared by every packet (the packet type, QoS, and
//! the Packet union that holds any one decoded packet), plus one struct per
//! packet type in packet/. Code outside this folder imports this file, not
//! the files inside packet/.

pub const ConnAck = @import("packet/ConnAck.zig");
pub const Connect = @import("packet/Connect.zig");
pub const PingResp = @import("packet/PingResp.zig");
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

/// Delivery guarantee for a message. Used by the will in CONNECT, and later
/// by PUBLISH and SUBSCRIBE. 3 is not a valid QoS.
pub const QoS = enum(u2) {
    at_most_once = 0,
    at_least_once = 1,
    exactly_once = 2,
};

/// One decoded packet. The tag is the packet type, so a switch on it covers
/// every type. Packets with no body (PINGREQ, PINGRESP, DISCONNECT) are void.
/// Types still marked TODO are void until they get a struct.
///
/// Slices inside point into the buffer the packet was decoded from: they are
/// only valid as long as that buffer is.
pub const Packet = union(PacketType) {
    connect: Connect,
    connack: ConnAck,
    publish: void, // TODO
    puback: void, // TODO
    pubrec: void, // TODO
    pubrel: void, // TODO
    pubcomp: void, // TODO
    subscribe: void, // TODO
    suback: void, // TODO
    unsubscribe: void, // TODO
    unsuback: void, // TODO
    pingreq: void,
    pingresp: void,
    disconnect: void,
};

test {
    @import("std").testing.refAllDecls(@This());
}
