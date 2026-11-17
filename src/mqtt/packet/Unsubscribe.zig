const Unsubscribe = @This();

const std = @import("std");
const Reader = @import("../Reader.zig");

packet_id: u16,
filters: [][]const u8,

pub fn decode(body: []const u8, filters_buf: [][]const u8) !Unsubscribe {
    var r = Reader.init(body);

    const packet_id = try r.readU16();

    if (packet_id == 0) return error.Malformed;

    var filters: std.ArrayList([]const u8) = .initBuffer(filters_buf);

    while (r.pos < body.len) {
        const filter = try r.readString();
        if (filter.len == 0) return error.Malformed;

        filters.appendBounded(filter) catch return error.TooManyFilters;
    }

    if (filters.items.len == 0) return error.Malformed;

    return .{
        .packet_id = packet_id,
        .filters = filters.items,
    };
}

test "Unsubscribe: decode" {
    const testing = std.testing;

    var buf: [8][]const u8 = undefined;

    const unsub = try decode("\x00\x01\x00\x04test\x00\x02hi", &buf);
    try testing.expectEqual(1, unsub.packet_id);
    try testing.expectEqual(2, unsub.filters.len);
    try testing.expectEqualStrings("test", unsub.filters[0]);
    try testing.expectEqualStrings("hi", unsub.filters[1]);
}

test "Unsubscribe: decode malformed" {
    const testing = std.testing;

    var buf: [8][]const u8 = undefined;

    // No topics after the packet ID.
    try testing.expectError(error.Malformed, decode("\x00\x01", &buf));
    // Exceed filter buf
    try testing.expectError(error.TooManyFilters, decode("\x00\x01\x00\x01a\x00\x02hi\x00\x02si", buf[0..1]));
}
