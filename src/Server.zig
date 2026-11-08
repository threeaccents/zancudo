const Server = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const sys = @import("sys.zig");
const EpollEvent = sys.EpollEvent;
const Ip4Address = sys.Ip4Address;
const Conn = @import("Conn.zig");
const mqtt = @import("mqtt.zig");
const Broker = @import("Broker.zig");
const FixedHeader = mqtt.FixedHeader;

// socket fd
fd: sys.fd_t,
// epoll fd
epfd: sys.fd_t,
alloc: Allocator,
ip: [4]u8,
port: u16,
broker: *Broker,

const log = std.log.scoped(.server);

pub fn init(
    alloc: Allocator,
    broker: *Broker,
    ip: [4]u8,
    port: u16,
) !Server {
    const socket_fd = try sys.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);

    // Lets us restart while old connections are still in TIME_WAIT.
    try sys.setsockopt(socket_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);

    const addr: Ip4Address = .{ .ip = ip, .port = port };
    try sys.bind(socket_fd, addr);
    try sys.listen(socket_fd, 128);

    const epfd = try sys.epollCreate();
    // data.ptr = 0 marks the listener, since no Conn lives at address 0.
    try sys.epollAdd(epfd, socket_fd, linux.EPOLL.IN, .{ .ptr = 0 });

    log.info("listening on {f}", .{addr});

    return .{
        .fd = socket_fd,
        .ip = ip,
        .port = port,
        .epfd = epfd,
        .broker = broker,
        .alloc = alloc,
    };
}

pub fn deinit(self: *Server) void {
    sys.close(self.fd);
    sys.close(self.epfd);
}

pub fn serve(self: *Server) !void {
    var events: [128]EpollEvent = undefined;

    while (true) {
        const ready_events = try sys.epollWait(self.epfd, &events, -1);

        for (ready_events) |ev| {
            if (isSocketEv(ev)) self.handleSocketEv(ev) else self.handleConnEv(ev);
        }
    }
}

fn handleSocketEv(self: *Server, ev: EpollEvent) void {
    _ = ev;

    while (true) {
        const accepted = sys.accept(self.fd, linux.SOCK.NONBLOCK) catch |err| switch (err) {
            // no pending connections
            error.WouldBlock => return,
            else => {
                log.err("accept failed: {t}", .{err});
                return;
            },
        };
        log.info("client fd = {d}, from {f}", .{ accepted.fd, accepted.addr });

        const conn = self.alloc.create(Conn) catch |err| {
            log.err("failed to allocate conn state: {t}", .{err});
            sys.close(accepted.fd);
            continue;
        };

        conn.* = .{
            .fd = accepted.fd,
            .epfd = self.epfd,
            .addr = accepted.addr,
        };

        sys.epollAdd(self.epfd, accepted.fd, linux.EPOLL.IN, .{ .ptr = @intFromPtr(conn) }) catch |err| {
            log.err("epoll add client failed: {t}", .{err});
            sys.close(accepted.fd);
            self.alloc.destroy(conn);
        };
    }
}

fn handleConnEv(self: *Server, ev: EpollEvent) void {
    const conn: *Conn = @ptrFromInt(ev.data.ptr);

    if (ev.events & linux.EPOLL.OUT != 0) {
        conn.flush() catch |err| {
            log.err("client fd = {d} error: {t}", .{ conn.fd, err });
            self.closeConn(conn);
            return;
        };
    }

    // reads all the data coming in and sets it to its internal buffer
    conn.read() catch |err| {
        log.err("failed to read conn[{d}]. error: {t}", .{ conn.fd, err });
        self.closeConn(conn);
        return;
    };

    while (true) {
        const header = FixedHeader.parse(conn.data()) catch |err| {
            log.err("failed to parse fixed header conn[{s}]. error: {t}", .{ conn.clientId(), err });
            break;
        } orelse break;

        const packet_len = header.packetLen();
        // TODO grow the buffer to fit up to the max mqtt packet size.
        // if (packet_len > self.in_buf.len) return error.PacketTooLarge;
        //
        // havent received the full packet yet
        if (conn.in_len < packet_len) break;

        self.broker.handlePacket(conn, header, conn.in_buf[header.header_len..packet_len]) catch |err| {
            log.err("failed to handle packet {t}", .{err});
            self.closeConn(conn);
            break;
        };

        // Anything after a packet that ends the connection is ignored.
        if (conn.closing) {
            self.closeConn(conn);
            break;
        }

        conn.helpMeComeUpWtFuncName(packet_len);
    }

    if (conn.closing) {
        self.closeConn(conn);
    }
}

fn closeConn(self: *Server, conn: *Conn) void {
    log.info("client fd = {d} disconnected", .{conn.fd});
    self.broker.removeConn(conn);
    sys.close(conn.fd);
    self.alloc.destroy(conn);
}

fn isSocketEv(ev: EpollEvent) bool {
    return ev.data.ptr == 0;
}
