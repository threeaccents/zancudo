//! Thin wrappers over the raw Linux syscalls the broker uses.
//!
//! A raw syscall returns a usize that holds either the result or a negative
//! errno (see linux.errno). Each wrapper here turns that into a normal Zig
//! error union, so callers can use `try` and `catch` and never look at errno
//! directly. Errnos we expect to act on get their own named error. Anything
//! else is logged and returned as error.Unexpected.

const std = @import("std");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;

/// An IPv4 address and port, in normal byte order. The wrappers convert to
/// and from the kernel's big-endian sockaddr.in, so callers never deal with
/// byte order.
pub const Ip4Address = struct {
    ip: [4]u8,
    port: u16,

    fn toSockaddr(self: Ip4Address) linux.sockaddr.in {
        return .{
            .port = std.mem.nativeToBig(u16, self.port),
            // The kernel wants the address big-endian, which means the bytes
            // a.b.c.d in that order in memory. That's exactly how `ip` is laid
            // out, so reinterpret the 4 bytes as a u32 without converting.
            .addr = @bitCast(self.ip),
        };
    }

    fn fromSockaddr(sa: linux.sockaddr.in) Ip4Address {
        return .{
            .ip = @bitCast(sa.addr),
            .port = std.mem.bigToNative(u16, sa.port),
        };
    }

    /// Lets print show an address with "{f}", e.g. 127.0.0.1:1883.
    pub fn format(self: Ip4Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}.{d}:{d}", .{ self.ip[0], self.ip[1], self.ip[2], self.ip[3], self.port });
    }
};

pub const SocketError = error{ TooManyOpenFiles, Unexpected };

/// Create a socket and return its fd.
pub fn socket(domain: u32, sock_type: u32, protocol: u32) SocketError!fd_t {
    const rc = linux.socket(domain, sock_type, protocol);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        // MFILE: this process hit its fd limit. NFILE: the whole system did.
        .MFILE, .NFILE => error.TooManyOpenFiles,
        else => |err| unexpected(err),
    };
}

/// Set an int-valued socket option, like SO_REUSEADDR (1 = on).
pub fn setsockopt(fd: fd_t, level: i32, optname: u32, value: c_int) error{Unexpected}!void {
    // The kernel takes the value as raw bytes plus a length, because every
    // option has its own type. asBytes views the c_int as its 4 bytes.
    const bytes = std.mem.asBytes(&value);
    const rc = linux.setsockopt(fd, level, optname, bytes, bytes.len);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |err| unexpected(err),
    };
}

pub const BindError = error{ AddressInUse, AccessDenied, Unexpected };

/// Attach the socket to an address and port.
pub fn bind(fd: fd_t, addr: Ip4Address) BindError!void {
    const sa = addr.toSockaddr();
    // bind takes the generic *sockaddr; the length says which struct it is.
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

/// Start accepting connections. Up to `backlog` finished handshakes wait in
/// the accept queue.
pub fn listen(fd: fd_t, backlog: u32) ListenError!void {
    const rc = linux.listen(fd, backlog);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        // Another socket is already listening on this port.
        .ADDRINUSE => error.AddressInUse,
        else => |err| unexpected(err),
    };
}

/// A newly accepted connection: its own fd, and who it came from.
pub const Accepted = struct {
    fd: fd_t,
    addr: Ip4Address,
};

pub const AcceptError = error{ WouldBlock, ConnectionAborted, TooManyOpenFiles, Unexpected };

/// Take the next connection off the accept queue. Blocks until there is one,
/// unless the listening socket is non-blocking.
///
/// `flags` apply to the NEW client socket, e.g. linux.SOCK.NONBLOCK. On Linux
/// a client socket does not inherit non-blocking mode from the listener, so it
/// has to be asked for here. 0 = no flags.
pub fn accept(fd: fd_t, flags: u32) AcceptError!Accepted {
    var sa: linux.sockaddr.in = undefined;
    // In/out: in = how big sa is, out = how many bytes the kernel wrote.
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    // accept4 = accept plus a 4th argument: flags for the new socket.
    const rc = linux.accept4(fd, @ptrCast(&sa), &len, flags);
    return switch (linux.errno(rc)) {
        .SUCCESS => .{ .fd = @intCast(rc), .addr = Ip4Address.fromSockaddr(sa) },
        // Only on a non-blocking socket: the accept queue is empty.
        .AGAIN => error.WouldBlock,
        // The client gave up between the handshake and our accept().
        .CONNABORTED => error.ConnectionAborted,
        .MFILE, .NFILE => error.TooManyOpenFiles,
        else => |err| unexpected(err),
    };
}

pub const ReadError = error{ WouldBlock, ConnectionReset, Unexpected };

/// Read into buf. Returns how many bytes arrived; 0 means the peer closed
/// the connection.
pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        // Only on a non-blocking socket: no bytes have arrived yet.
        .AGAIN => error.WouldBlock,
        // The peer aborted the connection (sent a RST) instead of closing it
        // normally.
        .CONNRESET => error.ConnectionReset,
        else => |err| unexpected(err),
    };
}

pub const SendError = error{ WouldBlock, ConnectionReset, BrokenPipe, Unexpected };

/// Send once. Returns how many bytes the kernel took, which may be fewer than
/// bytes.len.
pub fn send(fd: fd_t, bytes: []const u8) SendError!usize {
    // MSG.NOSIGNAL: sending to a peer that already disconnected fails with
    // EPIPE instead of the kernel killing our whole process with SIGPIPE.
    // null/0 = no destination address; a TCP socket is already connected.
    const rc = linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        // Only on a non-blocking socket: the send buffer is full.
        .AGAIN => error.WouldBlock,
        .CONNRESET => error.ConnectionReset,
        // The peer is gone.
        .PIPE => error.BrokenPipe,
        else => |err| unexpected(err),
    };
}

/// Send every byte, calling send() again after each partial send.
pub fn sendAll(fd: fd_t, bytes: []const u8) SendError!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        sent += try send(fd, bytes[sent..]);
    }
}

// ---- epoll ----

pub const EpollEvent = linux.epoll_event;
/// The 8-byte slot in each event that's ours: an fd, a pointer, or a number.
pub const EpollData = linux.epoll_data;

pub const EpollCreateError = error{ TooManyOpenFiles, Unexpected };

/// Create an epoll instance. It's an fd too: a kernel object that holds our
/// interest list (which fds we watch, and for which events).
pub fn epollCreate() EpollCreateError!fd_t {
    const rc = linux.epoll_create1(0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE, .NFILE => error.TooManyOpenFiles,
        else => |err| unexpected(err),
    };
}

pub const EpollAddError = error{ AlreadyRegistered, Unexpected };

/// Start watching `fd` for `events`, e.g. linux.EPOLL.IN for readable.
/// `data` is ours: the kernel stores it and hands it back untouched with every
/// event for this fd, so we can tell which fd the event is about.
pub fn epollAdd(epfd: fd_t, fd: fd_t, events: u32, data: EpollData) EpollAddError!void {
    // The kernel copies the event, so it only needs to live for this call.
    var ev: EpollEvent = .{ .events = events, .data = data };
    const rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        // This fd is already being watched.
        .EXIST => error.AlreadyRegistered,
        else => |err| unexpected(err),
    };
}

/// Sleep until at least one watched fd is ready, or `timeout_ms` passes
/// (-1 = wait forever, 0 = don't wait at all). Fills `events` with what's
/// ready and returns just the filled part.
pub fn epollWait(epfd: fd_t, events: []EpollEvent, timeout_ms: i32) error{Unexpected}![]EpollEvent {
    const rc = linux.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout_ms);
    return switch (linux.errno(rc)) {
        .SUCCESS => events[0..rc],
        // A signal woke us before anything was ready, e.g. the process was
        // paused with Ctrl-Z and resumed. Report "nothing ready"; the caller's
        // loop just waits again.
        .INTR => events[0..0],
        else => |err| unexpected(err),
    };
}

/// Close an fd. If epoll was watching it, that stops too.
pub fn close(fd: fd_t) void {
    // close() can technically fail, but there's nothing useful to do about it:
    // Linux releases the fd either way, so it must not be retried.
    _ = linux.close(fd);
}

/// Log an errno we didn't plan for and turn it into error.Unexpected.
fn unexpected(err: linux.E) error{Unexpected} {
    std.debug.print("unexpected errno: {t}\n", .{err});
    return error.Unexpected;
}
