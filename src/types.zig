const std = @import("std");

const RingBuffer = @import("ring_buffer.zig").RingBuffer;

pub const IOPipe = RingBuffer(4096);

pub const Config = extern struct {
    mem_size: usize = 0,
};

pub const State = extern struct {
    mem_ptr: [*]u8 = undefined,
    mem_len: usize = 0,
    input: *IOPipe,
    output: *IOPipe,
    running: bool,

    pub fn mem(self: *State) []u8 {
        return self.mem_ptr[0..self.mem_len];
    }
};

pub const SetupFn = fn (*Config) void;
pub const RunFn = fn (*State) void;
