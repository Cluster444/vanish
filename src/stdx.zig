const std = @import("std");
const assert = std.debug.assert;
const copyForwards = std.mem.copyForwards;
const copyBackwards = std.mem.copyBackwards;

fn memcpy(target: []u8, source: []const u8) void {
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
