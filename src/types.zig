const std = @import("std");

const buf = @import("buffers.zig");
const mem = @import("memory.zig");
const root = @import("root.zig");

pub const AliasMap = @import("alias_map.zig").AliasMap(64);
const BlockAllocator = mem.BlockAllocator;

pub const ByteAllocator = mem.ByteAllocator;
pub const IOPipe = buf.RingBuffer(4096, false);

const MemoryBlocks = enum {
    static,
    buffers,
    arena,
};

pub const Blocks = BlockAllocator(MemoryBlocks);
