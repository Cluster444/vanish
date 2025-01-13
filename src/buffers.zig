const std = @import("std");
const assert = std.debug.assert;

const AtomSize = std.atomic.Value(usize);
const IOPipe = RingBuffer(4096);

pub fn RingBuffer(comptime size: u32, comptime thread_safe: bool) type {
    std.debug.assert(@popCount(size) == 1);
    std.debug.assert(size > 1);

    const alignment = if (thread_safe) 64 else @alignOf(AtomSize);

    return struct {
        buffer: [size]u8 = undefined,
        head: AtomSize align(alignment) = AtomSize.init(0),
        tail: AtomSize align(alignment) = AtomSize.init(0),
        name: []const u8,

        const Self = @This();
        pub const SIZE = size;
        const MASK = size - 1;

        pub fn init(self: *Self, name: []const u8) void {
            self.name = name;
            self.reset();
        }

        pub fn reset(self: *Self) void {
            self.head.raw = 0;
            self.tail.raw = 0;
        }

        // Producer side
        //
        pub fn write_len(self: *Self) usize {
            return SIZE - self.readable_len();
        }

        pub fn writable_slice(self: *Self) []u8 {
            const rhead = if (thread_safe) self.head.load(.acquire) else self.head.raw;
            const avail = self.write_len();
            const head = rhead & MASK;
            const wrap = SIZE - head;

            return self.buffer[head..(head +% @min(avail, wrap))];
        }

        pub fn commit(self: *Self, count: usize) void {
            assert(count <= self.write_len());
            if (thread_safe) {
                self.head.store(self.head.raw +% count, .release);
            } else {
                self.head.raw +%= count;
            }
        }

        pub fn write(self: *Self, bytes: []const u8) usize {
            var slice = self.writable_slice();
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
        pub fn readable_len(self: *Self) usize {
            return self.head.raw -% self.tail.raw;
        }

        pub fn readable_slice(self: *Self) []const u8 {
            const rtail = if (thread_safe) self.tail.load(.acquire) else self.tail.raw;
            const avail = self.readable_len();
            const tail = rtail & MASK;
            const wrap = SIZE - tail;

            return self.buffer[tail..(tail +% @min(avail, wrap))];
        }

        pub fn release(self: *Self, count: usize) void {
            assert(count <= self.readable_len());
            if (thread_safe) {
                self.tail.store(self.tail.raw +% count, .release);
            } else {
                self.tail.raw +%= count;
            }
        }

        pub fn read(self: *Self, bytes: []u8) usize {
            var slice = self.readable_slice();
            const bytes_to_read = @min(bytes.len, slice.len);

            if (bytes_to_read > 0) {
                @memcpy(bytes[0..bytes_to_read], slice[0..bytes_to_read]);
                self.release(bytes_to_read);
            }

            return bytes_to_read;
        }

        pub fn read_all(self: *Self, bytes: []u8) void {
            var cursor = bytes;

            while (cursor.len > 0) {
                const count = self.read(cursor);
                cursor = cursor[count..];
            }
        }

        pub fn read_byte(self: *Self) ?u8 {
            if (self.readable_len() == 0) {
                return null;
            }
            // const byte: u8 = self.buffer[self.tail.load(.acquire)];
            const byte: u8 = self.buffer[self.tail.raw];
            self.release(1);
            return byte;
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

    inline for (.{ 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024 }) |size| {
        const Buffer = RingBuffer(size, true);
        var buffer = Buffer{ .name = "Test" };

        var produced: usize = 0;
        var consumed: usize = 0;

        const producer = std.Thread.spawn(.{}, struct {
            fn run(buf: *Buffer, total: *usize) void {
                for (0..ITERS) |i| {
                    while (buf.write_len() == 0) {}

                    const slice = buf.writable_slice();
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
                    while (buf.readable_len() == 0) {}

                    const slice = buf.readable_slice();
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
}
