//! One client connection: its socket, its address, and the bytes it has sent
//! that haven't been handled yet.

const std = @import("std");
const sys = @import("sys.zig");
const Broker = @import("Broker.zig");
const FixedHeader = @import("mqtt/packet.zig").FixedHeader;

const Client = @This();

fd: sys.fd_t,
in_len: usize = 0,
in_buf: [4096]u8 = undefined,
addr: sys.Ip4Address,

/// Called when epoll reports this client readable. Reads everything that has
/// arrived, hands each complete packet to the broker, and keeps any partial
/// packet buffered for the next call.
///
/// Returns normally once there's nothing more to read right now, so the event
/// loop can go back to epoll_wait. Returns error.ClientClosed when the client
/// has closed the connection.
pub fn onReadable(c: *Client, broker: *Broker) !void {
    while (true) {
        // One read is NOT one message: TCP is a byte stream, so a read returns
        // whatever has arrived so far, up to the free space left in in_buf.
        // Read in after the bytes already buffered, so a partial message
        // from an earlier read isn't overwritten.
        const n = sys.read(c.fd, c.in_buf[c.in_len..]) catch |err| switch (err) {
            // Nothing more to read right now. Back to epoll_wait.
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) return error.ClientClosed;

        // The new bytes extend what was already buffered.
        c.in_len += n;

        while (try FixedHeader.parse(c.in_buf[0..c.in_len])) |header| {
            const packet_len = header.packetLen();
            // TODO grow the buffer to fit up to the max mqtt packet size.
            if (packet_len > c.in_buf.len) return error.PacketTooLarge;
            // havent received the full packet yet
            if (c.in_len < packet_len) break;

            try broker.handlePacket(c, header, c.in_buf[header.header_len..packet_len]);

            const leftover = c.in_buf[packet_len..c.in_len];
            std.mem.copyForwards(u8, c.in_buf[0..leftover.len], leftover);
            c.in_len = leftover.len;
        }
    }
}
