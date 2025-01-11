const RingBuffer = @import("ring_buffer.zig").RingBuffer;

pub const IOPipe = RingBuffer(4096);

pub const Config = extern struct {
    mem_size: usize,
};

pub const State = extern struct {
    mem_ptr: [*]u8 = undefined,
    mem_len: usize = 0,
    input: *IOPipe,
    output: *IOPipe,

    pub fn stdin_writeable(self: *State) []u8 {
        return self.stdin_buffer[self.stdin_len..self.stdin_cap];
    }
};

pub const SetupFn = fn (*Config) void;
pub const RunFn = fn (*State) void;
