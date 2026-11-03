const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const sys = @import("sys.zig");
const Client = @import("Client.zig");
const packet = @import("mqtt/packet.zig");

// Make `zig build test` run the tests in these files too. Zig only runs tests
// in files it reaches through imports from here.
test {
    _ = @import("mqtt/packet.zig");
}

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

        while (try packet.packetLength(client_state.in_buf[0..client_state.in_len])) |total| {
            if (total > client_state.in_buf.len) return error.PacketTooLarge;
            if (client_state.in_len < total) break;

            const b = client_state.in_buf[0..total];
            try sys.sendAll(client_state.fd, b);

            const leftover = client_state.in_buf[total..client_state.in_len];
            std.mem.copyForwards(u8, client_state.in_buf[0..leftover.len], leftover);
            client_state.in_len = leftover.len;
        }
    }
}
