//! PINGRESP: the server's reply to PINGREQ, server to client only. It has no
//! variable header or payload, so there are no fields.
const PingResp = @This();

/// The whole PINGRESP packet, always 2 bytes: type 13 with no flags, and
/// remaining length 0.
pub fn encode(self: PingResp) [2]u8 {
    _ = self;
    return .{ 0xD0, 0x00 };
}
