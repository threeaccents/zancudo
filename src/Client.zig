const sys = @import("sys.zig");

fd: sys.fd_t,
in_len: usize = 0,
in_buf: [4096]u8 = undefined,
addr: sys.Ip4Address,
