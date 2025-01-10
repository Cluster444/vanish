const std = @import("std");
const time = std.time;

const RingBuffer = @import("ring_buffer.zig").RingBuffer;

pub fn main() void {
    const iterations = 10_000_000;
    const Buffer = RingBuffer(64);
    var buffer = Buffer{};

    const results = benchmark(&buffer, iterations);

    std.debug.print(
        \\BufferPool Iterations {d}
        \\  total - Read: {d}ms Write: {d}ms
        \\  each - Read: {d}ns Write: {d}ns
        \\
    , .{
        // fill_percentage,
        iterations,
        results.read_time,
        results.write_time,
        results.read_time / iterations,
        results.write_time / iterations,
    });
    // }
}

fn benchmark(
    ring_buffer: anytype,
    iterations: u32,
) struct { read_time: u64, write_time: u64 } {
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    // Prepare test data
    var data: [64]u8 = undefined;
    for (&data) |*byte| {
        byte.* = random.intRangeAtMost(u8, 0, 255);
    }

    // We use this to vary the writes, but pre-fill to limit
    // the effects on the timer
    const op_size = comptime blk: {
        var amounts: [256]usize = undefined;
        var seed: u64 = 0;
        @setEvalBranchQuota(100_000);
        for (&amounts) |*amount| {
            seed = std.hash.Wyhash.hash(seed, &[_]u8{@intCast(seed & 0xFF)});
            amount.* = @mod(seed, 32) + 1;
        }
        break :blk amounts;
    };

    var op_size_idx: u8 = 0;
    var volatile_sum: u64 = 0;

    var timer = time.Timer.start() catch @panic("shittimer");
    var write_time: u64 = 0;
    var read_time: u64 = 0;

    // Benchmark write operations
    {
        timer.reset();
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            var write_size = op_size[op_size_idx];
            op_size_idx +%= 1;
            const slice = ring_buffer.write_slice();
            if (slice.len > 0) {
                write_size = @min(slice.len, data.len);
                @memcpy(slice[0..write_size], data[0..write_size]);
                ring_buffer.commit(write_size);
                ring_buffer.release(write_size);
            }
            volatile_sum +%= write_size;
        }
        write_time = timer.lap();
    }

    // Reset buffer for write_slice2
    ring_buffer.reset();
    ring_buffer.commit(64);

    // Benchmark read operations
    {
        timer.reset();
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            var read_size = op_size[op_size_idx];
            op_size_idx +%= 1;
            const slice = ring_buffer.read_slice();
            if (slice.len > 0) {
                read_size = @min(slice.len, data.len);
                @memcpy(data[0..read_size], slice[0..read_size]);
                ring_buffer.release(read_size);
                ring_buffer.commit(read_size);
            }
            volatile_sum +%= data[read_size - 1];
        }
        read_time = timer.lap();
    }

    return .{ .read_time = read_time, .write_time = write_time };
}
