const Message = @This();

const std = @import("std");
const QoS = @import("mqtt.zig").QoS;

topic: []const u8,
payload: []const u8,
qos: QoS,
retain: bool,
