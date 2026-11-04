//! One client connection: its socket, its address, and the bytes it has sent
//! that haven't been handled yet.
const Client = @This();

const std = @import("std");
const sys = @import("sys.zig");
const Broker = @import("Broker.zig");
const FixedHeader = @import("mqtt.zig").FixedHeader;
const Ip4Address = sys.Ip4Address;

/// The client's socket.
fd: sys.fd_t,

/// How many bytes at the start of in_buf hold data not handled yet.
in_len: usize = 0,

/// Bytes read from the socket that haven't been handled yet, often a packet
/// that hasn't fully arrived. Only the first in_len bytes are valid.
in_buf: [4096]u8 = undefined,

/// Where the client connected from.
addr: Ip4Address,

/// The keep-alive from the client's CONNECT, in seconds.
keep_alive: u64,

/// Called when epoll reports this client readable. Reads everything that has
/// arrived, hands each complete packet to the broker, and keeps any partial
/// packet buffered for the next call.
///
/// Returns normally once there's nothing more to read right now, so the event
/// loop can go back to epoll_wait. Returns error.ClientClosed when the client
/// has closed the connection.
pub fn onReadable(self: *Client, broker: *Broker) !void {
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
        if (n == 0) return error.ClientClosed;

        // The new bytes extend what was already buffered.
        self.in_len += n;

        while (try FixedHeader.parse(self.in_buf[0..self.in_len])) |header| {
            const packet_len = header.packetLen();
            // TODO grow the buffer to fit up to the max mqtt packet size.
            if (packet_len > self.in_buf.len) return error.PacketTooLarge;
            // havent received the full packet yet
            if (self.in_len < packet_len) break;

            try broker.handlePacket(self, header, self.in_buf[header.header_len..packet_len]);

            const leftover = self.in_buf[packet_len..self.in_len];
            std.mem.copyForwards(u8, self.in_buf[0..leftover.len], leftover);
            self.in_len = leftover.len;
        }
    }
}
