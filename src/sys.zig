//! Wrappers over the raw Linux syscalls we use. Each one turns the errno
//! into a Zig error. Errnos we don't handle are logged and returned as
//! error.Unexpected.

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.sys);

pub const fd_t = linux.fd_t;

/// An IPv4 address and port in native byte order.
pub const Ip4Address = struct {
    ip: [4]u8,
    port: u16,

    fn toSockaddr(self: Ip4Address) linux.sockaddr.in {
        return .{
            .port = std.mem.nativeToBig(u16, self.port),
            // `ip` is already in network order, so no byte swap.
            .addr = @bitCast(self.ip),
        };
    }

    fn fromSockaddr(sa: linux.sockaddr.in) Ip4Address {
        return .{
            .ip = @bitCast(sa.addr),
            .port = std.mem.bigToNative(u16, sa.port),
        };
    }

    pub fn format(self: Ip4Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}.{d}:{d}", .{ self.ip[0], self.ip[1], self.ip[2], self.ip[3], self.port });
    }
};

pub const SocketError = error{ TooManyOpenFiles, Unexpected };

pub fn socket(domain: u32, sock_type: u32, protocol: u32) SocketError!fd_t {
    const rc = linux.socket(domain, sock_type, protocol);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE, .NFILE => error.TooManyOpenFiles,
        else => |err| unexpected(err),
    };
}

/// Two sockets already connected to each other. Bytes sent on one come out
/// of the other.
pub fn socketpair(domain: u32, sock_type: u32, protocol: u32) SocketError![2]fd_t {
    var fds: [2]fd_t = undefined;
    const rc = linux.socketpair(domain, sock_type, protocol, &fds);
    return switch (linux.errno(rc)) {
        .SUCCESS => fds,
        .MFILE, .NFILE => error.TooManyOpenFiles,
        else => |err| unexpected(err),
    };
}

/// Set an int-valued socket option.
pub fn setsockopt(fd: fd_t, level: i32, optname: u32, value: c_int) error{Unexpected}!void {
    const bytes = std.mem.asBytes(&value);
    const rc = linux.setsockopt(fd, level, optname, bytes, bytes.len);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |err| unexpected(err),
    };
}

pub const BindError = error{ AddressInUse, AccessDenied, Unexpected };

pub fn bind(fd: fd_t, addr: Ip4Address) BindError!void {
    const sa = addr.toSockaddr();
    const rc = linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .ADDRINUSE => error.AddressInUse,
        // Ports below 1024 need root.
        .ACCES => error.AccessDenied,
        else => |err| unexpected(err),
    };
}

pub const ListenError = error{ AddressInUse, Unexpected };

pub fn listen(fd: fd_t, backlog: u32) ListenError!void {
    const rc = linux.listen(fd, backlog);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .ADDRINUSE => error.AddressInUse,
        else => |err| unexpected(err),
    };
}

pub const Accepted = struct {
    fd: fd_t,
    addr: Ip4Address,
};

pub const AcceptError = error{ WouldBlock, ConnectionAborted, TooManyOpenFiles, Unexpected };

/// `flags` apply to the new socket. Linux doesn't carry non-blocking mode
/// over from the listener, so pass linux.SOCK.NONBLOCK here if needed.
pub fn accept(fd: fd_t, flags: u32) AcceptError!Accepted {
    var sa: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const rc = linux.accept4(fd, @ptrCast(&sa), &len, flags);
    return switch (linux.errno(rc)) {
        .SUCCESS => .{ .fd = @intCast(rc), .addr = Ip4Address.fromSockaddr(sa) },
        .AGAIN => error.WouldBlock,
        .CONNABORTED => error.ConnectionAborted,
        .MFILE, .NFILE => error.TooManyOpenFiles,
        else => |err| unexpected(err),
    };
}

pub const ReadError = error{ WouldBlock, ConnectionReset, Unexpected };

/// Returns 0 when the peer has closed the connection.
pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.WouldBlock,
        .CONNRESET => error.ConnectionReset,
        else => |err| unexpected(err),
    };
}

pub const SendError = error{ WouldBlock, ConnectionReset, BrokenPipe, Unexpected };

/// May send fewer bytes than given. See sendAll.
pub fn send(fd: fd_t, bytes: []const u8) SendError!usize {
    std.debug.print("in send sending {d} bytes", .{bytes.len});
    // NOSIGNAL: a peer that's gone gives us EPIPE instead of a SIGPIPE that
    // would kill the process.
    const rc = linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN => error.WouldBlock,
        .CONNRESET => error.ConnectionReset,
        .PIPE => error.BrokenPipe,
        else => |err| unexpected(err),
    };
}

pub fn sendAll(fd: fd_t, bytes: []const u8) SendError!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        sent += try send(fd, bytes[sent..]);
    }
}

// ---- epoll ----

pub const EpollEvent = linux.epoll_event;
pub const EpollData = linux.epoll_data;

pub const EpollCreateError = error{ TooManyOpenFiles, Unexpected };

pub fn epollCreate() EpollCreateError!fd_t {
    const rc = linux.epoll_create1(0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE, .NFILE => error.TooManyOpenFiles,
        else => |err| unexpected(err),
    };
}

pub const EpollAddError = error{ AlreadyRegistered, Unexpected };

/// `data` comes back with every event for this fd.
pub fn epollAdd(epfd: fd_t, fd: fd_t, events: u32, data: EpollData) EpollAddError!void {
    var ev: EpollEvent = .{ .events = events, .data = data };
    const rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .EXIST => error.AlreadyRegistered,
        else => |err| unexpected(err),
    };
}

pub const EpollModError = error{ NotRegistered, Unexpected };

/// Replaces both the events and `data`, so pass `data` again.
pub fn epollMod(epfd: fd_t, fd: fd_t, events: u32, data: EpollData) EpollModError!void {
    var ev: EpollEvent = .{ .events = events, .data = data };
    const rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &ev);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT => error.NotRegistered,
        else => |err| unexpected(err),
    };
}

/// Waits until a watched fd is ready or `timeout_ms` passes (-1 waits
/// forever), and returns the filled part of `events`.
pub fn epollWait(epfd: fd_t, events: []EpollEvent, timeout_ms: i32) error{Unexpected}![]EpollEvent {
    const rc = linux.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout_ms);
    return switch (linux.errno(rc)) {
        .SUCCESS => events[0..rc],
        // Woken by a signal before anything was ready.
        .INTR => events[0..0],
        else => |err| unexpected(err),
    };
}

/// Closing an fd also removes it from epoll.
pub fn close(fd: fd_t) void {
    // The fd is released even when close fails, so there's nothing to retry.
    _ = linux.close(fd);
}

/// End the connection but keep the fd open. epoll then reports it readable
/// with EOF, so it gets closed through the normal path.
pub fn shutdown(fd: fd_t) void {
    // The only realistic failure is ENOTCONN, when the peer is already gone.
    _ = linux.shutdown(fd, linux.SHUT.RDWR);
}

fn unexpected(err: linux.E) error{Unexpected} {
    log.err("unexpected errno: {t}", .{err});
    return error.Unexpected;
}
