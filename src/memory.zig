const std = @import("std");
const stx = @import("stx.zig");

const assert = std.debug.assert;

const dbg = std.debug.print;

pub const BLOCK_ALIGNMENT = 16 * 1024;

pub const ByteAllocator = struct {
    memory: []u8,
    head: usize = 0,

    pub fn alloc(self: *ByteAllocator, size: usize) []u8 {
        assert(self.memory.len >= self.head + size);

        const begin = self.head;
        const end = self.head + size;
        self.head = end;
        return self.memory[begin..end];
    }

    pub fn reset(self: *ByteAllocator) void {
        self.head = 0;
    }
};

pub fn BlockAllocator(comptime E: type) type {
    stx.assertEnum(E);

    return struct {
        memory: []u8 = undefined,
        offset: usize,
        blocks: Blocks(E) = std.mem.zeroes(Blocks(E)),
        commited: bool = false,

        const Self = @This();

        pub fn reserve(self: *Self, comptime blk: E, comptime T: type, count: usize) void {
            assert(!self.commited);
            var blk_data = self.block(blk);
            blk_data.size += @sizeOf(T) * count;
        }

        pub fn commit(self: *Self) void {
            assert(!self.commited);

            const fields = @typeInfo(E).@"enum".fields;
            var total_size: usize = 0;

            inline for (fields) |field| {
                const blk_data = self.block(std.meta.stringToEnum(E, field.name).?);
                total_size += std.mem.alignForward(usize, blk_data.size, BLOCK_ALIGNMENT);
            }

            // Pulled from stdlib so we can set the VM offsets
            const hint = @atomicLoad(@TypeOf(std.heap.next_mmap_addr_hint), &std.heap.next_mmap_addr_hint, .unordered);
            const new_hint: [*]align(std.mem.page_size) u8 = @ptrFromInt(self.offset);
            _ = @cmpxchgStrong(@TypeOf(std.heap.next_mmap_addr_hint), &std.heap.next_mmap_addr_hint, hint, new_hint, .monotonic, .monotonic);

            self.memory = std.heap.page_allocator.alloc(u8, total_size) catch @panic("shitbits");

            var end: usize = 0;
            inline for (fields) |field| {
                var blk_data = self.block(std.meta.stringToEnum(E, field.name).?);
                const begin = end;
                end += std.mem.alignForward(usize, blk_data.size, BLOCK_ALIGNMENT);
                blk_data.memory = self.memory[begin..end];
            }

            self.commited = true;
        }

        pub fn release(self: *Self) void {
            assert(self.commited);
            std.heap.page_allocator.free(self.memory);
            self.commited = false;
        }

        pub fn block(self: *Self, comptime blk_grp: E) *BlockData {
            return &@field(self.blocks, @tagName(blk_grp));
        }

        pub fn arena(self: *Self, comptime blk_grp: E) ByteAllocator {
            var blk = self.block(blk_grp);
            const memory = blk.alloc_remains();
            return ByteAllocator{ .memory = memory };
        }
    };
}

const BlockData = struct {
    memory: []u8,
    size: usize,
    head: usize,

    pub fn create(self: *BlockData, comptime T: type) *T {
        return @ptrCast(@alignCast(self.alloc(@sizeOf(T)).ptr));
    }

    pub fn alloc(self: *BlockData, count: usize) []u8 {
        const begin = self.head;
        const end = self.head + count;
        self.head = end;
        return self.memory[begin..end];
    }

    pub fn alloc_remains(self: *BlockData) []u8 {
        const begin = self.head;
        const end = self.memory.len;
        self.head = end;
        return self.memory[begin..end];
    }
};

fn Blocks(comptime E: type) type {
    stx.assertEnum(E);

    const enum_fields = std.meta.fields(E);
    comptime var struct_fields: [enum_fields.len]std.builtin.Type.StructField = undefined;

    inline for (enum_fields, 0..) |field, i| {
        struct_fields[i] = .{
            .name = field.name,
            .type = BlockData,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(usize),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}
