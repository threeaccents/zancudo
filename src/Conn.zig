//! One client connection: its socket, its address, and the bytes it has sent
//! that haven't been handled yet.
const Conn = @This();

const std = @import("std");
const sys = @import("sys.zig");
const Broker = @import("Broker.zig");
const FixedHeader = @import("mqtt.zig").FixedHeader;
const Ip4Address = sys.Ip4Address;

/// MQTT 3.1.1 servers only have to accept client IDs of 1 to 23 bytes, so
/// that's all client_id_buf has room for. Longer IDs get CONNACK
/// .identifier_rejected.
pub const max_client_id_len = 23;

/// The client's socket.
fd: sys.fd_t,

/// How many bytes at the start of in_buf hold data not handled yet.
in_len: usize = 0,

/// Bytes read from the socket that haven't been handled yet, often a packet
/// that hasn't fully arrived. Only the first in_len bytes are valid.
in_buf: [4096]u8 = undefined,

/// Where the client connected from.
addr: Ip4Address,

/// True once a valid CONNECT has been handled. Any other packet before it,
/// or a second CONNECT, is a protocol violation.
connected: bool = false,

/// Set when the connection should be closed as a normal part of the
/// protocol, not because something failed: the client sent DISCONNECT, hung
/// up, or was refused with a CONNACK. Once set, no more packets are handled,
/// and the event loop closes the connection.
closing: bool = false,

/// The client ID from CONNECT, copied out of in_buf so it outlives the
/// packet. Only the first client_id_len bytes are valid.
client_id_buf: [max_client_id_len]u8 = undefined,

/// How many bytes of client_id_buf hold the client ID.
client_id_len: u8 = 0,

/// The clean session flag from CONNECT. True: the session ends when this
/// connection does.
clean_session: bool = true,

/// The keep-alive from the client's CONNECT, in seconds. 0 means no timeout.
keep_alive: u16 = 0,

/// Called when epoll reports this client readable. Reads everything that has
/// arrived, hands each complete packet to the broker, and keeps any partial
/// packet buffered for the next call.
///
/// Returns normally once there's nothing more to read right now, so the event
/// loop can go back to epoll_wait, or once `closing` is set, so the event loop
/// can close the connection. Returns an error only when something went wrong.
pub fn onReadable(self: *Conn, broker: *Broker) !void {
    while (true) {
        // One read is NOT one message: TCP is a byte stream, so a read returns
        // whatever has arrived so far, up to the free space left in in_buf.
        // Read in after the bytes already buffered, so a partial message
        // from an earlier read isn't overwritten.
        const n = sys.read(self.fd, self.in_buf[self.in_len..]) catch |err| switch (err) {
            // Nothing more to read right now. Back to epoll_wait.
            error.WouldBlock => return,
            else => return err,
        };
        // 0 bytes means the client closed its side of the connection.
        if (n == 0) {
            self.closing = true;
            return;
        }

        // The new bytes extend what was already buffered.
        self.in_len += n;

        while (try FixedHeader.parse(self.in_buf[0..self.in_len])) |header| {
            const packet_len = header.packetLen();
            // TODO grow the buffer to fit up to the max mqtt packet size.
            if (packet_len > self.in_buf.len) return error.PacketTooLarge;
            // havent received the full packet yet
            if (self.in_len < packet_len) break;

            try broker.handlePacket(self, header, self.in_buf[header.header_len..packet_len]);

            // The packet ended the connection (DISCONNECT, a refused CONNECT).
            // Anything after it is ignored.
            if (self.closing) return;

            const leftover = self.in_buf[packet_len..self.in_len];
            std.mem.copyForwards(u8, self.in_buf[0..leftover.len], leftover);
            self.in_len = leftover.len;
        }
    }
}

pub fn clientId(self: *Conn) []const u8 {
    if (self.client_id_len == 0) return .{};

    return self.client_id_buf[0..self.client_id_len];
}
