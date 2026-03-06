const std = @import("std");

pub fn default(comptime T: type) T {
    const info = @typeInfo(T);

    return switch (info) {
        .int, .comptime_int => 0,
        .float, .comptime_float => 0.0,
        .array => .{},
        .bool => false,
        .optional => null,
        else => std.mem.zeroInit(T, .{}),
    };
}

pub fn canMinMax(comptime T: type) bool {
    const info = @typeInfo(T);

    return switch (info) {
        .int, .comptime_int, .float, .comptime_float => true,
        else => false,
    };
}

pub fn maxValue(comptime T: type) T {
    const info = @typeInfo(T);

    return switch (info) {
        .int, .comptime_int => std.math.maxInt(T),
        .float, .comptime_float => std.math.floatMax(T),
        else => @compileError("Type has no min/max"),
    };
}

pub fn minValue(comptime T: type) T {
    const info = @typeInfo(T);

    return switch (info) {
        .int, .comptime_int => std.math.minInt(T),
        .float, .comptime_float => std.math.floatMin(T),
        else => @compileError("Type has no min/max"),
    };
}
