const SubAck = @This();

const std = @import("std");

packet_id: u16,
filter_codes: []const u8,

pub const ReturnCode = enum(u8) {
    granted_qos0 = 0x00,
    granted_qos1 = 0x01,
    granted_qos2 = 0x02,
    failure = 0x80,
};

pub fn encode(self: *SubAck) []u8 {
    const len = 4 + self.filter_codes.len;
    return &.{
        0x90,
        self.packet_id,
    };
}
