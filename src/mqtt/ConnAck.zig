//! CONNACK: the server's reply to CONNECT, server to client only.
const ConnAck = @This();

/// True when the server resumed a stored session for this client ID.
/// Must be false when return_code isn't .accepted.
session_present: bool,

return_code: ReturnCode,

/// Anything other than .accepted means the server closes the connection
/// after sending the CONNACK.
pub const ReturnCode = enum(u8) {
    accepted = 0x00,
    unacceptable_protocol_version = 0x01,
    identifier_rejected = 0x02,
    server_unavailable = 0x03,
    bad_username_or_password = 0x04,
    not_authorized = 0x05,
};

/// The whole CONNACK packet, always 4 bytes: type 2 with no flags, remaining
/// length 2, the acknowledge flags (bit 0 is session present), and the
/// return code.
pub fn encode(self: ConnAck) [4]u8 {
    return .{ 0x20, 0x02, @intFromBool(self.session_present), @backingInt(self.return_code) };
}
