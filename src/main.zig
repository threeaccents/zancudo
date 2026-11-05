//! Sets up the listening socket and runs the event loop.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const Conn = @import("Conn.zig");
const Broker = @import("Broker.zig");
const EpollEvent = sys.EpollEvent;
const Ip4Address = sys.Ip4Address;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    const listen_fd = try sys.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);
    // The loop never exits. The kernel closes our fds when the process dies.
    defer sys.close(listen_fd);

    // Lets us restart while old connections are still in TIME_WAIT.
    try sys.setsockopt(listen_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);

    const addr: Ip4Address = .{ .ip = .{ 127, 0, 0, 1 }, .port = 1883 };
    try sys.bind(listen_fd, addr);
    try sys.listen(listen_fd, 128);

    const epfd = try sys.epollCreate();
    defer sys.close(epfd);
    // data.ptr = 0 marks the listener, since no Conn lives at address 0.
    try sys.epollAdd(epfd, listen_fd, linux.EPOLL.IN, .{ .ptr = 0 });
    log.info("listening on {f}", .{addr});

    var events: [64]EpollEvent = undefined;

    var broker: Broker = .{
        .alloc = alloc,
    };

    while (true) {
        const ready = try sys.epollWait(epfd, &events, -1);
        for (ready) |ev| {
            log.debug("ready: data.ptr = 0x{x}", .{ev.data.ptr});
            // check if we have a new connection or handling a client.
            // We register those 2 events with the same epoll instance.
            if (ev.data.ptr == 0) {
                // More than one connection may be waiting.
                while (true) {
                    const accepted = sys.accept(listen_fd, linux.SOCK.NONBLOCK) catch |err| switch (err) {
                        error.WouldBlock => break,
                        else => {
                            log.err("accept failed: {t}", .{err});
                            break;
                        },
                    };
                    log.info("client fd = {d}, from {f}", .{ accepted.fd, accepted.addr });
                    const conn = alloc.create(Conn) catch |err| {
                        log.err("failed to allocate client state: {t}", .{err});
                        sys.close(accepted.fd);
                        continue;
                    };

                    conn.* = .{
                        .fd = accepted.fd,
                        .addr = accepted.addr,
                    };

                    // data.ptr leads each event back to its Conn.
                    sys.epollAdd(epfd, accepted.fd, linux.EPOLL.IN, .{ .ptr = @intFromPtr(conn) }) catch |err| {
                        log.err("epoll add client failed: {t}", .{err});
                        sys.close(accepted.fd);
                        alloc.destroy(conn);
                    };
                }
            } else {
                const conn: *Conn = @ptrFromInt(ev.data.ptr);

                conn.onReadable(&broker) catch |err| {
                    log.err("client fd = {d} error: {t}", .{ conn.fd, err });

                    closeConn(alloc, conn, &broker);
                    continue;
                };

                if (conn.closing) {
                    closeConn(alloc, conn, &broker);
                }
            }
        }
    }
}

fn closeConn(alloc: Allocator, conn: *Conn, broker: *Broker) void {
    log.info("client fd = {d} disconnected", .{conn.fd});
    sys.close(conn.fd);
    broker.removeConn(conn);
    alloc.destroy(conn);
}

// Tests only run for files reachable from here.
test {
    _ = @import("mqtt.zig");
}
