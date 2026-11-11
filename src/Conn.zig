//! A client connection
const Conn = @This();

const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");
const mqtt = @import("mqtt.zig");
const linux = std.os.linux;
const Ip4Address = sys.Ip4Address;
const Writer = mqtt.Writer;

/// MQTT 3.1.1 only requires servers to accept client IDs up to 23 bytes.
pub const max_client_id_len = 23;

fd: sys.fd_t,

// epoll fd
epfd: sys.fd_t,

/// Only the first in_len bytes are valid.
in_buf: [16 * 1024]u8 = undefined,
in_len: usize = 0,

out_buf: [16_000]u8 = undefined,
out_len: usize = 0,

next_packet_id: u16 = 0,

addr: Ip4Address,

/// Set once CONNECT has been handled.
connected: bool = false,

/// The connection ended normally (DISCONNECT, refused CONNECT, takeover) and
/// should be closed. Anything still buffered is ignored.
closing: bool = false,

/// The client closed its side. Packets already buffered still get handled.
peer_closed: bool = false,

client_id_buf: [max_client_id_len]u8 = undefined,
client_id_len: u8 = 0,

/// In seconds. 0 means no timeout.
keep_alive: u16 = 0,

/// Flag if conn is listening to linux.EPOLL.OUT events
epoll_out_on: bool = false,

// reads data coming in and sets it to its internal buffer
pub fn read(self: *Conn) !void {
    while (true) {
        // TCP is a byte stream, so a read can end mid-packet. Append after
        // whatever is already buffered.
        const n = sys.read(self.fd, self.in_buf[self.in_len..]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };

        if (n == 0 and (self.in_len == self.in_buf.len)) return error.InBufferFull;
        if (n == 0) {
            self.peer_closed = true;
            return;
        }

        self.in_len += n;
    }
}

pub fn data(self: *Conn) []u8 {
    return self.in_buf[0..self.in_len];
}

pub fn clientId(self: *Conn) []const u8 {
    return self.client_id_buf[0..self.client_id_len];
}

pub fn consume(self: *Conn, packet_len: usize) void {
    const leftover = self.in_buf[packet_len..self.in_len];
    std.mem.copyForwards(u8, self.in_buf[0..leftover.len], leftover);
    self.in_len = leftover.len;
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

pub fn setClientId(self: *Conn, io: Io, client_id: []const u8) void {
    if (client_id.len == 0) {
        randomId(io, self.client_id_buf[0..10]);
        self.client_id_len = 10;
        return;
    }

    @memcpy(self.client_id_buf[0..client_id.len], client_id);
    self.client_id_len = @intCast(client_id.len);
}

fn randomId(io: Io, buf: []u8) void {
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

    io.random(buf);
    for (buf) |*c| c.* = alphabet[c.* % alphabet.len];
}
