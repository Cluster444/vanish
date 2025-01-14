const std = @import("std");

const readInt = std.mem.readInt;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

pub const RAPID_SEED: u64 = 0xbdd89aa982704029;
const RAPID_SECRET: [3]u64 = .{ 0x2d358dccaa6c78a5, 0x8bb84b93962eacc9, 0x4b33a62ed433d4a3 };

pub fn rapid_hash(seed: u64, input: []const u8) u64 {
    const secret = RAPID_SECRET;
    const len = input.len;
    var a: u64 = 0;
    var b: u64 = 0;
    var cursor = input;
    var state: [3]u64 = .{ seed, 0, 0 };

    state[0] ^= mix(seed ^ secret[0], secret[1]) ^ len;

    if (len <= 16) {
        if (len >= 4) {
            // If there's 4-16 bytes, then we concat the 1st and last u32 to a u64
            // Then we grab the "2nd & 3rd" unaligned u32s shifted by the delta.
            // delta will move from 0 to 4 as len goes from 4 to 16, so at 16 bytes
            // all four u32s are non-overlapping
            const delta: u64 = ((len & 24) >> @intCast(len >> 3));
            const end = len - 4;
            const a_1 = read32(cursor) << 32;
            const a_2 = read32(cursor[end..]);
            const b_1 = read32(cursor[delta..]) << 32;
            const b_2 = read32(cursor[(end - delta)..]);

            a = a_1 | a_2;
            b = b_1 | b_2;
        } else if (len > 0) {
            const a_1 = @as(u64, cursor[0]) << 56;
            const a_2 = @as(u64, cursor[len >> 1]) << 32;
            const a_3 = @as(u64, cursor[len - 1]);

            a = a_1 | a_2 | a_3;
        }
    } else {
        // If we have a long key (>16 bytes), we switch to the more complex
        // state triple that the following loops build up, and the simpler
        // state simple grabs the last two u64s
        a = read64(input[len - 16 ..]);
        b = read64(input[len - 8 ..]);

        var remain = len;
        // If we have more than 48 bytes, then we mix 48 byte chucnks
        // into an internal state working sequentially on u64 pairs.
        // These will mix into the state triples
        if (len > 48) {
            state[1] = state[0];
            state[2] = state[0];

            while (remain >= 96) {
                inline for (0..6) |i| {
                    const m1 = read64(cursor[8 * i * 2 ..]);
                    const m2 = read64(cursor[8 * (i * 2 + 1) ..]);
                    state[i % 3] = mix(m1 ^ secret[i % 3], m2 ^ state[i % 3]);
                }
                cursor = cursor[96..];
                remain -= 96;
            }
            if (remain >= 48) {
                inline for (0..3) |i| {
                    const m1 = read64(cursor[8 * i * 2 ..]);
                    const m2 = read64(cursor[8 * (i * 2 + 1) ..]);
                    state[i] = mix(m1 ^ secret[i], m2 ^ state[i]);
                }
                cursor = cursor[48..];
                remain -= 48;
            }

            // Flatten the triple down to a single u64
            state[0] ^= state[1] ^ state[2];
        }

        // If there's leftovers past LEN % 48 then we mix how over many u64 pairs are left. They only
        // mix into the first state slot since 1 & 2 are skipped if if the len is 16-48 bytes.
        if (remain > 16) {
            state[0] = mix(read64(cursor) ^ secret[2], read64(cursor[8..]) ^ state[0] ^ secret[1]);
            if (remain > 32) {
                state[0] = mix(read64(cursor[16..]) ^ secret[2], read64(cursor[24..]) ^ state[0]);
            }
        }
    }

    a ^= secret[1];
    b ^= state[0];
    mum(&a, &b);
    return mix(a ^ secret[0] ^ len, b ^ secret[1]);
}

inline fn mum(a: *u64, b: *u64) void {
    const r = @as(u128, a.*) * b.*;
    a.* = @truncate(r);
    b.* = @truncate(r >> 64);
}

inline fn mix(a: u64, b: u64) u64 {
    var copy_a = a;
    var copy_b = b;
    mum(&copy_a, &copy_b);
    return copy_a ^ copy_b;
}

inline fn read64(p: []const u8) u64 {
    return readInt(u64, p[0..8], .little);
}

inline fn read32(p: []const u8) u64 {
    return readInt(u32, p[0..4], .little);
}

test "RapidHash.hash" {
    const bytes: []const u8 = "abcdefgh" ** 128;

    const sizes: [13]u64 = .{ 0, 1, 2, 3, 4, 8, 16, 32, 64, 128, 256, 512, 1024 };

    const outcomes: [13]u64 = .{
        0x5a6ef77074ebc84b,
        0xc11328477bc0f5d1,
        0x5644ac035e40d569,
        0x347080fbf5fcd81,
        0x56b66b8dc802bcc,
        0xb6bf9055973aac7c,
        0xed56d62eead1e402,
        0xc19072d767da8ffb,
        0x89bb40a9928a4f0d,
        0xe0af7c5e7b6e29fd,
        0x9a3ed35fbedfa11a,
        0x4c684b2119ca19fb,
        0x4b575f5bf25600d6,
    };

    var hashes: [13]u64 = undefined;

    for (sizes, 0..) |size, idx| {
        hashes[idx] = rapid_hash(RAPID_SEED, bytes[0..size]);
    }

    try expectEqualSlices(u64, outcomes[0..13], hashes[0..13]);
}
