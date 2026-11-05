//! PINGRESP: the server's reply to PINGREQ. It has no body.
const PingResp = @This();

pub fn encode(self: PingResp) [2]u8 {
    _ = self;
    return .{ 0xD0, 0x00 };
}
