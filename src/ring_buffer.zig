const std = @import("std");
const assert = std.debug.assert;

const AtomicSize = std.atomic.Value(usize);

pub fn RingBuffer(comptime size: u32) type {
    std.debug.assert(@popCount(size) == 1);
    std.debug.assert(size > 1);

    return struct {
        buffer: [size]u8 = undefined,
        head: AtomicSize align(64) = AtomicSize.init(0),
        tail: AtomicSize align(64) = AtomicSize.init(0),

        const Self = @This();
        pub const SIZE = size;
        const MASK = size - 1;

        pub fn reset(self: *Self) void {
            self.head.store(0, .release);
            self.tail.store(0, .release);
        }

        // Producer side
        //
        pub fn write_len(self: *Self) usize {
            return SIZE - self.read_len();
        }

        pub fn write_slice(self: *Self) []u8 {
            const rhead = self.head.load(.acquire);
            const avail = self.write_len();
            const head = rhead & MASK;
            const wrap = SIZE - head;

            return self.buffer[head..(head +% @min(avail, wrap))];
        }

        pub fn commit(self: *Self, count: usize) void {
            assert(count <= self.write_len());
            self.head.store(self.head.raw +% count, .release);
        }

        pub fn write(self: *Self, bytes: []const u8) usize {
            var slice = self.write_slice();
            const bytes_to_write = @min(bytes.len, slice.len);

            if (bytes_to_write > 0) {
                @memcpy(slice[0..bytes_to_write], bytes[0..bytes_to_write]);
                self.commit(bytes_to_write);
            }

            return bytes_to_write;
        }

        pub fn write_all(self: *Self, bytes: []const u8) void {
            var cursor = bytes;

            while (cursor.len > 0) {
                const count = self.write(cursor);
                cursor = cursor[count..];
            }
        }

        // Consumer Side
        //
        pub fn read_len(self: *Self) usize {
            return self.head.raw -% self.tail.raw;
        }

        pub fn read_slice(self: *Self) []const u8 {
            const rtail = self.tail.load(.acquire);
            const avail = self.read_len();
            const tail = rtail & MASK;
            const wrap = SIZE - tail;

            return self.buffer[tail..(tail +% @min(avail, wrap))];
        }

        pub fn release(self: *Self, count: usize) void {
            assert(count <= self.read_len());
            self.tail.store(self.tail.raw +% count, .release);
        }

        pub fn read(self: *Self, bytes: []u8) usize {
            var slice = self.read_slice();
            const bytes_to_read = @min(bytes.len, slice.len);

            if (bytes_to_read > 0) {
                @memcpy(bytes[0..bytes_to_read], slice[0..bytes_to_read]);
                self.release(bytes_to_read);
            }

            return bytes_to_read;
        }

        pub fn read_all(self: *Self, bytes: []u8) void {
            var cursor = bytes;

            while (bytes.len > 0) {
                const count = self.read(cursor);
                cursor = cursor[count..];
            }
        }
    };
}

const t = std.testing;

test "RingBuffer concurrent access" {
    const ITERS = 654321;

    const expected_cksum: usize = blk: {
        var sum: usize = 0;
        for (0..ITERS) |i| {
            const byte: u8 = @truncate(i);
            sum += byte;
        }
        break :blk sum;
    };

    const Buffer = RingBuffer(16);
    var buffer = Buffer{};

    var produced: usize = 0;
    var consumed: usize = 0;

    const producer = std.Thread.spawn(.{}, struct {
        fn run(buf: *Buffer, total: *usize) void {
            for (0..ITERS) |i| {
                while (buf.write_len() == 0) {}

                const slice = buf.write_slice();
                if (slice.len > 0) {
                    slice[0] = @truncate(i);
                    buf.commit(1);
                    total.* += 1;
                }
            }
        }
    }.run, .{ &buffer, &produced }) catch @panic("shitthread");

    var checksum: usize = 0;

    const consumer = std.Thread.spawn(.{}, struct {
        fn run(buf: *Buffer, total: *usize, cksum: *usize) void {
            for (0..ITERS) |_| {
                while (buf.read_len() == 0) {}

                const slice = buf.read_slice();
                if (slice.len > 0) {
                    const byte = slice[0];
                    buf.release(1);
                    cksum.* += byte;
                    total.* += 1;
                }
            }
        }
    }.run, .{ &buffer, &consumed, &checksum }) catch @panic("shitthread");

    producer.join();
    consumer.join();

    const result = .{ produced, consumed, checksum };

    try t.expectEqual(expected_cksum, result[2]);
    try t.expectEqual(result[0], result[1]);
}
