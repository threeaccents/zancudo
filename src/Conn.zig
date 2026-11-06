//! One client connection: its socket and the bytes read from it that haven't
//! been handled yet.
const Conn = @This();

const std = @import("std");
const sys = @import("sys.zig");
const mqtt = @import("mqtt.zig");
const linux = std.os.linux;
const Broker = @import("Broker.zig");
const FixedHeader = mqtt.FixedHeader;
const Ip4Address = sys.Ip4Address;
const Writer = mqtt.Writer;

/// MQTT 3.1.1 only requires servers to accept client IDs up to 23 bytes.
pub const max_client_id_len = 23;

fd: sys.fd_t,

// epoll fd
epfd: sys.fd_t,

/// Only the first in_len bytes are valid.
in_buf: [4096]u8 = undefined,
in_len: usize = 0,

out_buf: [16_000]u8 = undefined,
out_len: usize = 0,

addr: Ip4Address,

/// Set once CONNECT has been handled.
connected: bool = false,

/// The connection ended normally (DISCONNECT, hang-up, refused CONNECT) and
/// should be closed.
closing: bool = false,

client_id_buf: [max_client_id_len]u8 = undefined,
client_id_len: u8 = 0,
clean_session: bool = true,

/// In seconds. 0 means no timeout.
keep_alive: u16 = 0,

/// Flag if conn is listening to linux.EPOLL.OUT events
epoll_out_on: bool = false,

/// Reads what has arrived and hands each complete packet to the broker. A
/// partial packet stays buffered until the rest arrives.
pub fn onReadable(self: *Conn, broker: *Broker) !void {
    while (true) {
        // TCP is a byte stream, so a read can end mid-packet. Append after
        // whatever is already buffered.
        const n = sys.read(self.fd, self.in_buf[self.in_len..]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        // The client closed its side.
        if (n == 0) {
            self.closing = true;
            return;
        }

        self.in_len += n;

        while (try FixedHeader.parse(self.in_buf[0..self.in_len])) |header| {
            const packet_len = header.packetLen();
            // TODO grow the buffer to fit up to the max mqtt packet size.
            if (packet_len > self.in_buf.len) return error.PacketTooLarge;
            // havent received the full packet yet
            if (self.in_len < packet_len) break;

            try broker.handlePacket(self, header, self.in_buf[header.header_len..packet_len]);

            // Anything after a packet that ends the connection is ignored.
            if (self.closing) return;

            const leftover = self.in_buf[packet_len..self.in_len];
            std.mem.copyForwards(u8, self.in_buf[0..leftover.len], leftover);
            self.in_len = leftover.len;
        }
    }
}

pub fn clientId(self: *Conn) []const u8 {
    return self.client_id_buf[0..self.client_id_len];
}

pub fn send(self: *Conn, packet: anytype) !void {
    var w = Writer.init(self.out_buf[self.out_len..]);
    try packet.encode(&w);

    self.out_len += w.written().len;

    try self.flush();
}

pub fn flush(self: *Conn) !void {
    while (self.out_len > 0) {
        const n = sys.send(self.fd, self.out_buf[0..self.out_len]) catch |err| switch (err) {
            error.WouldBlock => {
                if (!self.epoll_out_on) {
                    try sys.epollMod(self.epfd, self.fd, linux.EPOLL.IN | linux.EPOLL.OUT, .{ .ptr = @intFromPtr(self) });
                    self.epoll_out_on = true;
                }
                break;
            },
            else => return err,
        };

        @memmove(self.out_buf[0..(self.out_len - n)], self.out_buf[n..self.out_len]);

        self.out_len -= n;
    }

    if (self.out_len == 0 and self.epoll_out_on) {
        self.epoll_out_on = false;
        try sys.epollMod(self.epfd, self.fd, linux.EPOLL.IN, .{ .ptr = @intFromPtr(self) });
    }
}
