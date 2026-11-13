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
const Timestamp = std.Io.Timestamp;
const Io = std.Io;

// socket fd
fd: sys.fd_t,
// epoll fd
epfd: sys.fd_t,
timerfd: sys.fd_t,
alloc: Allocator,
ip: [4]u8,
port: u16,
broker: *Broker,
conns: std.AutoHashMapUnmanaged(sys.fd_t, *Conn) = .empty,
io: Io,

const log = std.log.scoped(.server);

pub fn init(
    io: Io,
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

    const timerfd = try sys.timerfdCreate();
    try sys.epollAdd(epfd, timerfd, linux.EPOLL.IN, .{ .ptr = 1 });
    try sys.timerfdSet(timerfd, std.time.ns_per_s, std.time.ns_per_s);

    log.info("listening on {f}", .{addr});

    return .{
        .io = io,
        .fd = socket_fd,
        .ip = ip,
        .port = port,
        .epfd = epfd,
        .broker = broker,
        .alloc = alloc,
        .timerfd = timerfd,
    };
}

pub fn deinit(self: *Server) void {
    sys.close(self.fd);
    sys.close(self.epfd);
    sys.close(self.timerfd);

    var it = self.conns.valueIterator();

    // destroyConn, not closeConn: removing from conns would invalidate `it`.
    while (it.next()) |conn| self.destroyConn(conn.*);

    self.conns.deinit(self.alloc);
}

pub fn serve(self: *Server) !void {
    var events: [128]EpollEvent = undefined;

    while (true) {
        const ready_events = try sys.epollWait(self.epfd, &events, -1);

        for (ready_events) |ev| {
            if (isSocketEv(ev)) self.handleSocketEv() else if (isKeepAliveTimerEv(ev)) try self.handleKeepAliveTimerEv() else try self.handleConnEv(ev);
        }
    }
}

fn handleSocketEv(self: *Server) void {
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

        self.conns.put(self.alloc, conn.fd, conn) catch |err| {
            log.err("failed to append conn to conn list: {t}", .{err});
            sys.close(accepted.fd);
            continue;
        };

        sys.epollAdd(self.epfd, accepted.fd, linux.EPOLL.IN, .{ .ptr = @intFromPtr(conn) }) catch |err| {
            log.err("epoll add client failed: {t}", .{err});
            sys.close(accepted.fd);
            self.alloc.destroy(conn);
        };
    }
}

fn handleKeepAliveTimerEv(self: *Server) !void {
    _ = try sys.timerfdRead(self.timerfd);

    var iter = self.conns.valueIterator();

    const now = Timestamp.now(self.io, .awake).nanoseconds;

    while (iter.next()) |conn| {
        if (conn.*.keep_alive == 0 or conn.*.last_packet_at == 0) continue;
        // spec says 1.5 the keep alive time
        // look up int/float conversion.
        const keep_alive = conn.*.keep_alive;

        const since_ns = now - conn.*.last_packet_at;
        const seconds_since = @divFloor(since_ns, std.time.ns_per_s);

        // since * 2 > ka * 3 is since > 1.5 * ka without floats.
        if (since_ns * 2 > @as(u64, keep_alive) * std.time.ns_per_s * 3) {
            log.debug("Droppig connection keep alive timeput client id: {s} fd: {d}, keep-alive: {d}. duration: {d}", .{ conn.*.clientId(), conn.*.fd, keep_alive, seconds_since });
            // closeConn would remove from conns mid-iteration. The EOF from
            // shutdown closes it through handleConnEv instead.
            sys.shutdown(conn.*.fd);
        }
    }
}

fn handleConnEv(self: *Server, ev: EpollEvent) !void {
    const conn: *Conn = @ptrFromInt(ev.data.ptr);

    if (ev.events & linux.EPOLL.OUT != 0) {
        conn.flush() catch |err| {
            log.err("client fd = {d} error: {t}", .{ conn.fd, err });
            self.closeConn(conn);
            return;
        };
    }

    // reads all the data coming in and sets it to its internal buffer
    conn.read() catch |err| switch (err) {
        error.InBufferFull =>
        // look into allocating to a bigger buffer
        log.debug("buffer full", .{}),

        else => {
            log.err("failed to read conn[{d}]. error: {t}", .{ conn.fd, err });
            self.closeConn(conn);
            return;
        },
    };

    while (true) {
        const header = FixedHeader.parse(conn.data()) catch |err| {
            log.err("failed to parse fixed header conn[{d}]. error: {t}", .{ conn.fd, err });
            self.closeConn(conn);
            return;
        } orelse break;

        const packet_len = header.packetLen();
        // TODO grow the buffer to fit up to the max mqtt packet size.
        if (packet_len > conn.in_buf.len) return error.PacketTooLarge;

        // havent received the full packet yet
        if (conn.in_len < packet_len) break;

        self.broker.handlePacket(conn, header, conn.in_buf[header.header_len..packet_len]) catch |err| {
            log.err("failed to handle packet {t}", .{err});
            self.closeConn(conn);
            return;
        };

        // Anything after a packet that ends the connection is ignored.
        if (conn.closing) {
            self.closeConn(conn);
            return;
        }

        conn.consume(packet_len);
    }

    if (conn.closing or conn.peer_closed) {
        self.closeConn(conn);
    }
}

fn closeConn(self: *Server, conn: *Conn) void {
    _ = self.conns.remove(conn.fd);
    self.destroyConn(conn);
}

/// closeConn without removing from conns.
fn destroyConn(self: *Server, conn: *Conn) void {
    log.info("client fd = {d} disconnected", .{conn.fd});
    self.broker.removeConn(conn);
    sys.close(conn.fd);
    self.alloc.destroy(conn);
}

fn isSocketEv(ev: EpollEvent) bool {
    return ev.data.ptr == 0;
}

fn isKeepAliveTimerEv(ev: EpollEvent) bool {
    return ev.data.ptr == 1;
}
