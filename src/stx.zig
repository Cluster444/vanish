const std = @import("std");
const assert = std.debug.assert;
const copyForwards = std.mem.copyForwards;
const copyBackwards = std.mem.copyBackwards;

pub fn assert_enum(comptime E: type) void {
    if (@typeInfo(E) != .@"enum") {
        @compileError("Expected enum type, got " ++ @typeName(E));
    }
}

pub fn assert_log2(comptime size: usize) void {
    if (@popCount(size) != 1) {
        @compileError("Expected power of 2, got " ++ size);
    }
}

pub fn memcpy(target: []u8, source: []const u8) void {
    assert(target.len >= source.len);
    assert(target.ptr != source.ptr);

    const target_ptr = @intFromPtr(target.ptr);
    const source_ptr = @intFromPtr(source.ptr);
    const target_end = target_ptr + source.len;
    const source_end = source_ptr + source.len;

    // Check for no overlap and do a fast memcpy
    // Otherwise fall back to a for loop directional copy
    if (target_end <= source_ptr or source_end <= target_ptr) {
        @memcpy(target, source);
    } else {
        if (target_ptr < source_ptr) {
            copyForwards(u8, target, source);
        } else {
            copyBackwards(u8, target, source);
        }
    }
}

pub fn sleep(throttle: *u64) void {
    std.Thread.sleep(std.time.ms_per_s * throttle.*);

    throttle.* = switch (throttle.*) {
        1 => 2,
        2 => 3,
        3 => 5,
        5 => 7,
        7 => 10,
        else => 20,
    };
}
