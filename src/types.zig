const std = @import("std");

const buf = @import("buffers.zig");
const mem = @import("memory.zig");
const root = @import("root.zig");

const BlockAllocator = mem.BlockAllocator;

pub const ByteAllocator = mem.ByteAllocator;
pub const CommandBuffer = root.CommandBuffer;
pub const IOPipe = buf.RingBuffer(4096, false);

const MemoryBlocks = enum {
    static,
    buffers,
    arena,
};

pub const Blocks = BlockAllocator(MemoryBlocks);

pub const Config = extern struct {
    mem_size: usize = 0,
};

const PromptState = enum(c_int) { Prompting = 1, Waiting, Processing };

pub const State = extern struct {
    arena: *ByteAllocator,
    combuf: *CommandBuffer,
    input: *IOPipe,
    output: *IOPipe,
    state: PromptState = .Prompting,
    running: bool,
};

pub const SetupFn = fn (*Config) void;
pub const RunFn = fn (*State) void;
