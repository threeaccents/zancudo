//! CONNACK: the server's reply to CONNECT, server to client only.
const ConnAck = @This();

session_present: bool,

return_code: ReturnCode,

/// Anything but .accepted is followed by closing the connection.
pub const ReturnCode = enum(u8) {
    accepted = 0x00,
    unacceptable_protocol_version = 0x01,
    identifier_rejected = 0x02,
    server_unavailable = 0x03,
    bad_username_or_password = 0x04,
    not_authorized = 0x05,
};

pub fn encode(self: ConnAck) [4]u8 {
    return .{
        0x20,
        0x02,
        @intFromBool(self.session_present),
        @backingInt(self.return_code),
    };
}
