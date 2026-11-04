//! CONNECT: the first packet a client sends, client to server only.
const Connect = @This();

const QoS = @import("packet.zig").QoS;

/// 4 for MQTT 3.1.1. Kept rather than rejected while decoding, because a
/// wrong level is answered with CONNACK .unacceptable_protocol_version.
protocol_level: u8,

/// Connect flags bit 1. True: drop any old session and start fresh.
clean_session: bool,

/// Seconds the client may stay silent before the server drops it.
/// 0 turns the timeout off.
keep_alive: u16,

/// Can be empty, but only when clean_session is true.
client_id: []const u8,

/// Published for the client if it disconnects without a DISCONNECT.
/// Present when connect flags bit 2 (will flag) is set.
will: ?Will,

/// Present when connect flags bit 7 is set.
username: ?[]const u8,

/// Present when connect flags bit 6 is set. Binary data, not UTF-8.
password: ?[]const u8,

pub const Will = struct {
    topic: []const u8,
    /// Binary data, not UTF-8.
    message: []const u8,
    /// Connect flags bits 4-3.
    qos: QoS,
    /// Connect flags bit 5.
    retain: bool,
};
