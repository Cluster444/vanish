const std = @import("std");
const stx = @import("stx.zig");

const assert = std.debug.assert;

pub fn AliasMap(comptime size: usize) type {
    stx.assert_log2(size);

    // Stores data in len:str format for the
    // key and value.
    return struct {
        buffer: [size]u8 = undefined,
        // cache: [64][8]u16 = undefined,
        head: usize = 0,
        // Cache

        const Self = @This();
        const SIZE = size;
        const MASK = SIZE - 1;

        pub fn init(self: *Self) void {
            self.head = 0;
        }

        pub fn insert(self: *Self, alias: []const u8, expansion: []const u8) void {
            assert(alias.len <= 256);
            assert(expansion.len <= 256);
            assert(self.buffer.len >= self.head + alias.len + expansion.len + 2);

            self.buffer[self.head] = @intCast(alias.len);
            stx.memcpy(self.buffer[self.head + 1 ..], alias);
            self.buffer[self.head + 1 + alias.len] = @intCast(expansion.len);
            stx.memcpy(self.buffer[self.head + alias.len + 2 ..], expansion);
            self.head += alias.len + expansion.len + 2;
        }

        pub fn find(self: *Self, alias: []const u8) ?[]const u8 {
            var cursor: usize = 0;
            while (cursor < SIZE) {
                const key_len = self.buffer[cursor];
                const key = self.buffer[cursor + 1 .. cursor + 1 + key_len];
                const val_len = self.buffer[cursor + 1 + key_len];

                if (std.mem.eql(u8, key, alias)) {
                    return self.buffer[cursor + key_len + 2 .. cursor + key_len + val_len + 2];
                }

                cursor += key_len + val_len + 2;
            }

            return null;
        }
    };
}

const t = std.testing;

test "AliasMap" {
    var map = AliasMap(16){};
    map.insert("hello", "world");
    const val = map.find("hello");
    try t.expectEqualSlices(u8, "world", val);
}
