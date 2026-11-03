const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const sys = @import("sys.zig");
const Client = @import("Client.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Create a non-blocking IPv4 TCP socket. This becomes the listener.
    const listen_fd = try sys.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);
    // Never runs, because the event loop never exits. That's fine: when the
    // process dies (Ctrl-C), the kernel closes all its fds.
    defer sys.close(listen_fd);

    // Allow restarting the server while old connections on the port are
    // still in TIME_WAIT. Must come before bind().
    try sys.setsockopt(listen_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);

    const addr: sys.Ip4Address = .{ .ip = .{ 127, 0, 0, 1 }, .port = 1883 };
    try sys.bind(listen_fd, addr);
    try sys.listen(listen_fd, 128);

    // The epoll instance: watches the listener and every client for us.
    const epfd = try sys.epollCreate();
    defer sys.close(epfd);
    // Readable listener = a connection is waiting in the accept queue.
    // data.ptr = 0 marks the listener: no Client ever lives at address 0.
    try sys.epollAdd(epfd, listen_fd, linux.EPOLL.IN, .{ .ptr = 0 });
    std.debug.print("listening on {f}\n", .{addr});

    var events: [64]sys.EpollEvent = undefined;

    // Event loop: sleep until something is ready, handle it, repeat.
    while (true) {
        const ready = try sys.epollWait(epfd, &events, -1);
        for (ready) |ev| {
            std.debug.print("ready: data.ptr = 0x{x}\n", .{ev.data.ptr});
            if (ev.data.ptr == 0) {
                // A connection is waiting in the accept queue. More than one
                // may be waiting, so keep accepting until the queue is empty.
                while (true) {
                    const client = sys.accept(listen_fd, linux.SOCK.NONBLOCK) catch |err| switch (err) {
                        // Queue is empty: we've taken every waiting connection.
                        error.WouldBlock => break,
                        else => {
                            std.debug.print("accept failed: {t}\n", .{err});
                            break;
                        },
                    };
                    std.debug.print("client fd = {d}, from {f}\n", .{ client.fd, client.addr });
                    const client_state = gpa.create(Client) catch |err| {
                        std.debug.print("failed to allocate client state: {t}\n", .{err});
                        sys.close(client.fd);
                        continue;
                    };

                    client_state.* = .{
                        .fd = client.fd,
                        .addr = client.addr,
                    };

                    // Watch this client for incoming data. A pointer to its
                    // state goes in `data`, so each of its events leads
                    // straight back to its Client.
                    sys.epollAdd(epfd, client.fd, linux.EPOLL.IN, .{ .ptr = @intFromPtr(client_state) }) catch |err| {
                        // If epoll can't watch it, we could never serve it.
                        std.debug.print("epoll add client failed: {t}\n", .{err});
                        sys.close(client.fd);
                        gpa.destroy(client_state);
                    };
                }
            } else {
                // A client is readable: it sent data, closed, or broke.
                const client_state = @as(*Client, @ptrFromInt(ev.data.ptr));
                handleClient(client_state) catch |err| {
                    // ClientClosed is the normal way a client leaves. Anything
                    // else is a real error. Either way, we're done with it.
                    if (err != error.ClientClosed) {
                        std.debug.print("client fd = {d} error: {t}\n", .{ client_state.fd, err });
                    }
                    std.debug.print("client fd = {d} disconnected\n", .{client_state.fd});
                    // Closing the fd also removes it from epoll.
                    sys.close(client_state.fd);
                    gpa.destroy(client_state);
                };
            }
        }
    }
}

fn handleClient(client_state: *Client) !void {
    while (true) {
        // One read is NOT one message: TCP is a byte stream, so a read returns
        // whatever has arrived so far, up to the free space left in in_buf.
        // Read in after the bytes already buffered, so a partial message
        // from an earlier read isn't overwritten.
        const n = sys.read(client_state.fd, client_state.in_buf[client_state.in_len..]) catch |err| switch (err) {
            // Nothing more to read right now. Back to epoll_wait.
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) return error.ClientClosed;

        // The new bytes extend what was already buffered.
        client_state.in_len += n;

        // Everything buffered so far: earlier leftovers plus this read.
        const bytes = client_state.in_buf[0..client_state.in_len];
        std.debug.print("got {d} bytes, {d} buffered\n  text: {s}\n  hex:  {x}\n", .{ n, client_state.in_len, bytes, bytes });

        try sys.sendAll(client_state.fd, bytes);
    }
}

/// Works out the total size of the first MQTT packet in `buf`: the fixed
/// header (1 type byte + 1 to 4 length bytes) plus the remaining length that
/// those length bytes encode.
///
/// Returns null if the header hasn't fully arrived yet, so the caller should
/// wait for more bytes. A total can be returned while the packet's body is
/// still arriving; the caller compares it with how many bytes are buffered.
/// Returns error.InvalidLength if the length would need more than 4 bytes.
///
/// Encoding: each length byte holds 7 bits of the value (byte & 0x7F), and
/// its top bit (0x80) says whether another length byte follows. Each length
/// byte counts 128 times more than the one before it.
fn packetLength(buf: []const u8) !?usize {
    if (buf.len == 0) return null;

    var multiplier_index: u8 = 0;
    // Place value of each length byte: 1, 128, 128 x 128, 128 x 128 x 128.
    const multiplier_vals: [4]usize = .{ 1, 128, 16_384, 2_097_152 };

    // Header size so far: 1 type byte + 1 length byte. Each extra length byte
    // adds 1 below, and each length byte's value is added on top.
    var total: usize = 2;

    // The length bytes start right after the type byte.
    for (buf[1..]) |byte| {
        // MQTT allows at most 4 length bytes, so the 4th can't say "more".
        if ((byte & 0x80) != 0 and multiplier_index == 3) return error.InvalidLength;

        // Value 0 with no "more" bit: the length ends here.
        if (byte == 0x00) return total;

        // The lower 7 bits are this byte's piece of the value, scaled by its
        // place value.
        const value = (byte & 0x7F) * multiplier_vals[multiplier_index];
        total += value;

        // Top bit set: another length byte follows.
        if ((byte & 0x80) != 0) {
            multiplier_index += 1;
            total += 1;
            continue;
        }

        // Top bit clear: that was the last length byte.
        return total;
    }

    // Ran out of bytes before the last length byte arrived.
    return null;
}

test "packetLength: remaining length fits in one byte" {
    // PINGREQ: type 12, remaining length 0. The whole packet is 2 bytes.
    try std.testing.expectEqual(2, try packetLength(&.{ 0xC0, 0x00 }));

    // CONNECT with client id "abc": remaining length 15, so 1 + 1 + 15 = 17.
    const connect = [_]u8{ 0x10, 0x0F, 0x00, 0x04, 'M', 'Q', 'T', 'T', 0x04, 0x02, 0x00, 0x3C, 0x00, 0x03, 'a', 'b', 'c' };
    try std.testing.expectEqual(17, try packetLength(&connect));

    // 0x7F (0111 1111) is the largest value one length byte can hold: 127.
    // Only the header is here, but the total is already known: 1 + 1 + 127.
    try std.testing.expectEqual(129, try packetLength(&.{ 0x30, 0x7F }));
}

test "packetLength: remaining length uses two bytes" {
    // 0x80 0x01: value 0 with "more" set, then 1 x 128. The smallest value that
    // needs two length bytes: 128. Total: 1 + 2 + 128.
    try std.testing.expectEqual(131, try packetLength(&.{ 0x30, 0x80, 0x01 }));

    // 0xC1 0x02: 65 + 2 x 128 = 321. Total: 1 + 2 + 321.
    try std.testing.expectEqual(324, try packetLength(&.{ 0x30, 0xC1, 0x02 }));

    // 0xFF 0x7F: 127 + 127 x 128 = 16,383, the largest two-byte value.
    // Total: 1 + 2 + 16,383.
    try std.testing.expectEqual(16_386, try packetLength(&.{ 0x30, 0xFF, 0x7F }));

    // 0xC1 has "more" set, but the second length byte hasn't arrived yet, so
    // the header isn't complete: wait for more bytes.
    try std.testing.expectEqual(null, try packetLength(&.{ 0x30, 0xC1 }));
}

test "packetLength: remaining length uses three bytes" {
    // 0x80 0x80 0x01: 0 + 0 x 128 + 1 x 16,384. The smallest value that needs
    // three length bytes: 16,384. Total: 1 + 3 + 16,384.
    try std.testing.expectEqual(16_388, try packetLength(&.{ 0x30, 0x80, 0x80, 0x01 }));

    // 0xFF 0xFF 0x7F: 127 + 127 x 128 + 127 x 16,384 = 2,097,151, the largest
    // three-byte value. Total: 1 + 3 + 2,097,151.
    try std.testing.expectEqual(2_097_155, try packetLength(&.{ 0x30, 0xFF, 0xFF, 0x7F }));

    // The second byte still has "more" set and the third hasn't arrived yet.
    try std.testing.expectEqual(null, try packetLength(&.{ 0x30, 0xFF, 0xFF }));
}

test "packetLength: remaining length uses four bytes" {
    // 0x80 0x80 0x80 0x01: 1 x 2,097,152. The smallest value that needs four
    // length bytes: 2,097,152. Total: 1 + 4 + 2,097,152.
    try std.testing.expectEqual(2_097_157, try packetLength(&.{ 0x30, 0x80, 0x80, 0x80, 0x01 }));

    // 0xFF 0xFF 0xFF 0x7F: 268,435,455, the largest remaining length MQTT
    // allows. Total: 1 + 4 + 268,435,455.
    try std.testing.expectEqual(268_435_460, try packetLength(&.{ 0x30, 0xFF, 0xFF, 0xFF, 0x7F }));

    // The third byte still has "more" set and the fourth hasn't arrived yet.
    try std.testing.expectEqual(null, try packetLength(&.{ 0x30, 0xFF, 0xFF, 0xFF }));
}

test "packetLength: header not here yet" {
    // Nothing buffered at all.
    try std.testing.expectEqual(null, try packetLength(&[_]u8{}));

    // Only the type byte has arrived, no length byte yet.
    try std.testing.expectEqual(null, try packetLength(&.{0x10}));
}

test "packetLength: more than four length bytes" {
    // The 4th length byte still has "more" set, so a 5th follows. MQTT allows
    // at most 4 length bytes, so the packet is broken.
    try std.testing.expectError(error.InvalidLength, packetLength(&.{ 0x30, 0x80, 0x80, 0x80, 0x80, 0x01 }));

    // Same, but the 5th byte hasn't arrived yet. The 4th byte's "more" bit is
    // already enough to know the packet is broken, so don't wait for more.
    try std.testing.expectError(error.InvalidLength, packetLength(&.{ 0x30, 0x80, 0x80, 0x80, 0x80 }));
}
