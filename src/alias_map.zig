const std = @import("std");
const stx = @import("stx.zig");

pub fn AliasMap(comptime key_size: usize) type {
    stx.assert_log2(key_size);

    return struct {
        buffer: [key_size * stx.CACHE_LINE_SIZE]u8 = undefined,
        head: usize = 0,
        // hashes: [key_size]u32 = undefined,
        key_idx: [key_size]u16 = undefined,
        key_len: [key_size]u8 = undefined,
        val_idx: [key_size]u16 = undefined,
        val_len: [key_size]u8 = undefined,

        const Self = @This();
        const MASK = key_size - 1;

        pub fn init(self: *Self) void {
            @memset(self.key_idx[0..key_size], 0);
            self.head = 0;
        }

        pub fn insert(self: *Self, key: []const u8, val: []const u8) void {
            const hash = stx.hash(stx.HASH_SEED, key);
            const idx = hash & MASK;
            std.debug.assert(self.key_idx[idx] == 0);

            @memcpy(self.buffer[self.head..(self.head + key.len)], key);
            self.key_idx[idx] = @intCast(self.head);
            self.key_len[idx] = @intCast(key.len);
            self.head += key.len;

            @memcpy(self.buffer[self.head..(self.head + val.len)], val);
            self.val_idx[idx] = @intCast(self.head);
            self.val_len[idx] = @intCast(val.len);
            self.head += val.len;

            self.head = stx.align_cache_line(self.head);
        }

        pub fn match(self: *Self, key: []const u8) ?[]u8 {
            const hash = stx.hash(stx.HASH_SEED, key);
            const idx = hash & MASK;

            if (self.key_len[idx] != 0) {
                return self.buffer[self.val_idx[idx] .. self.val_idx[idx] + self.val_len[idx]];
            } else {
                return null;
            }
        }
    };
}

const t = std.testing;

test "AliasMap" {
    var map = AliasMap(16){};
    map.insert("hello", "world");
    const val = map.command("hello");
    try t.expectEqualSlices(u8, "world", val);
}
