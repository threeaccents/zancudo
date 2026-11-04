//! Entry point: sets up the listening socket and runs the event loop. Each
//! ready event is either a new connection on the listener or data from a
//! client.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const Client = @import("Client.zig");
const Broker = @import("Broker.zig");
const EpollEvent = sys.EpollEvent;
const Ip4Address = sys.Ip4Address;

const log = std.log.scoped(.main);

// Make `zig build test` run the tests in these files too. Zig only runs tests
// in files it reaches through imports from here.
test {
    _ = @import("mqtt.zig");
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    // Create a non-blocking IPv4 TCP socket. This becomes the listener.
    const listen_fd = try sys.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);
    // Never runs, because the event loop never exits. That's fine: when the
    // process dies (Ctrl-C), the kernel closes all its fds.
    defer sys.close(listen_fd);

    // Allow restarting the server while old connections on the port are
    // still in TIME_WAIT. Must come before bind().
    try sys.setsockopt(listen_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);

    const addr: Ip4Address = .{ .ip = .{ 127, 0, 0, 1 }, .port = 1883 };
    try sys.bind(listen_fd, addr);
    try sys.listen(listen_fd, 128);

    // The epoll instance: watches the listener and every client for us.
    const epfd = try sys.epollCreate();
    defer sys.close(epfd);
    // Readable listener = a connection is waiting in the accept queue.
    // data.ptr = 0 marks the listener: no Client ever lives at address 0.
    try sys.epollAdd(epfd, listen_fd, linux.EPOLL.IN, .{ .ptr = 0 });
    log.info("listening on {f}", .{addr});

    var events: [64]EpollEvent = undefined;

    // MQTT state shared by every client. Empty for now.
    var broker: Broker = .{};

    // Event loop: sleep until something is ready, handle it, repeat.
    while (true) {
        const ready = try sys.epollWait(epfd, &events, -1);
        for (ready) |ev| {
            log.debug("ready: data.ptr = 0x{x}", .{ev.data.ptr});
            // check if we have a new connection or handling a client.
            // We register those 2 events with the same epoll instance.
            if (ev.data.ptr == 0) {
                // A connection is waiting in the accept queue. More than one
                // may be waiting, so keep accepting until the queue is empty.
                while (true) {
                    const client = sys.accept(listen_fd, linux.SOCK.NONBLOCK) catch |err| switch (err) {
                        // Queue is empty: we've taken every waiting connection.
                        error.WouldBlock => break,
                        else => {
                            log.err("accept failed: {t}", .{err});
                            break;
                        },
                    };
                    log.info("client fd = {d}, from {f}", .{ client.fd, client.addr });
                    const client_state = alloc.create(Client) catch |err| {
                        log.err("failed to allocate client state: {t}", .{err});
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
                        log.err("epoll add client failed: {t}", .{err});
                        sys.close(client.fd);
                        alloc.destroy(client_state);
                    };
                }
            } else {
                // A client is readable: it sent data, closed, or broke.
                const client_state = @as(*Client, @ptrFromInt(ev.data.ptr));
                client_state.onReadable(&broker) catch |err| {
                    // ClientClosed is the normal way a client leaves. Anything
                    // else is a real error. Either way, we're done with it.
                    if (err != error.ClientClosed) {
                        log.err("client fd = {d} error: {t}", .{ client_state.fd, err });
                    }
                    log.info("client fd = {d} disconnected", .{client_state.fd});
                    // Closing the fd also removes it from epoll.
                    sys.close(client_state.fd);
                    alloc.destroy(client_state);
                };
            }
        }
    }
}
