const std = @import("std");
const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;
const assert = std.debug.assert;
const indexOf = std.mem.indexOf;

const stx = @import("stdx.zig");
const typ = @import("types.zig");
const Config = typ.Config;
const State = typ.State;
const IOPipe = typ.IOPipe;

// zig fmt: off
// ASCII Codes
//
const BACKSPACE  = 0x08;
const HORIZ_TAB  = 0x09;
const LINE_FEED  = 0x0A;
const VERT_TAB   = 0x0B;
const FORM_FEED  = 0x0C;
const CAR_RETURN = 0x0D;
const SHIFT_OUT  = 0x0E;
const SHIFT_IN   = 0x0F;
const ESCAPE     = 0x1B;
const SPACE      = 0x20;
const DQUOTE     = 0x22;
const SQUOTE     = 0x27;
const DELETE     = 0x7F;
// zig fmt: on

const AnsiCode = union(enum) {
    move_up: u8,
    move_down: u8,
    move_right: u8,
    move_left: u8,
    move_begin_up: u8,
    move_begin_down: u8,
    move_col: u8,
    home,
    clear_up,
    clear_down,
    clear_all,
    clear_right,
    clear_left,
    clear_line,
    scroll_up,
    save,
    restore,

    const ESC = "\x1b";
    const CSI = "\x1b[";

    pub fn write(self: AnsiCode, out: *IOPipe) void {
        switch (self) {
            // zig fmt: off
            .move_up         => |n| out.write_all(format(CSI ++ "{d}A", .{n})),
            .move_down       => |n| out.write_all(format(CSI ++ "{d}B", .{n})),
            .move_right      => |n| out.write_all(format(CSI ++ "{d}C", .{n})),
            .move_left       => |n| out.write_all(format(CSI ++ "{d}D", .{n})),
            .move_begin_up   => |n| out.write_all(format(CSI ++ "{d}E", .{n})),
            .move_begin_down => |n| out.write_all(format(CSI ++ "{d}F", .{n})),
            .move_col        => |n| out.write_all(format(CSI ++ "{d}G", .{n})),
            .home            => out.write_all(CSI ++ "H"),
            .clear_up        => out.write_all(CSI ++ "0J"),
            .clear_down      => out.write_all(CSI ++ "1J"),
            .clear_all       => out.write_all(CSI ++ "2J"),
            .clear_right     => out.write_all(CSI ++ "0K"),
            .clear_left      => out.write_all(CSI ++ "1K"),
            .clear_line      => out.write_all(CSI ++ "2K"),
            .scroll_up       => out.write_all(ESC ++ " M"),
            .save            => out.write_all(ESC ++ " 7"),
            .restore         => out.write_all(ESC ++ " 8"),
            // zig fmt: on
        }
    }

    fn format(comptime fmt: []const u8, args: anytype) []const u8 {
        const Buf = struct {
            var fer: [16]u8 = undefined;
        };
        return std.fmt.bufPrint(&Buf.fer, fmt, args) catch unreachable;
    }
};

const Self = @This();

// Setup
//
const BlockAllocator = struct {
    memory: []u8 = undefined,
    block_count: usize = 0,
    cursor: usize = 0,

    const BLOCK_SIZE = 16 * 1024;

    pub fn add_blocks(self: *BlockAllocator, count: usize) void {
        self.block_count += count;
    }

    pub fn alloc_size(self: *BlockAllocator) usize {
        return self.block_count * BLOCK_SIZE;
    }

    pub fn alloc(self: *BlockAllocator, count: usize) []u8 {
        const size = count * BLOCK_SIZE;
        const new_cursor = self.cursor + size;
        defer self.cursor = new_cursor;
        assert(new_cursor <= self.memory.len);
        return self.memory[self.cursor..new_cursor];
    }
};

var blocks = BlockAllocator{};

const BUILTIN_ARENA_BLOCKS = 1;
const RUN_BLOCKS = 1;

pub export fn setup(cfg: *Config) void {
    blocks.add_blocks(RUN_BLOCKS);
    blocks.add_blocks(BUILTIN_ARENA_BLOCKS);
    cfg.mem_size = blocks.alloc_size();
}

const PROMPT = " 👻 ";
const PromptState = enum { Prompting, Waiting, Processing };

pub const Builtins = enum {
    exit,
    pwd,
    cd,
};

// Run
//
pub export fn run(state: *State) void {
    var prompt_state: PromptState = .Prompting;
    var combuf = CommandBuffer{};

    blocks.memory = state.mem();
    const run_memory = blocks.alloc(RUN_BLOCKS);
    const run_buffer = heap.FixedBufferAllocator.init(run_memory);
    _ = run_buffer;

    const builtin_memory = blocks.alloc(BUILTIN_ARENA_BLOCKS);
    var builtin_buffer = heap.FixedBufferAllocator.init(builtin_memory);

    var throttle: u64 = 1;
    var workdir = std.fs.cwd();

    while (state.running) {
        defer builtin_buffer.reset();
        const alloc = builtin_buffer.allocator();

        switch (prompt_state) {
            .Prompting => {
                const path = workdir.realpathAlloc(alloc, ".") catch unreachable;
                state.output.write_all(fs.path.basename(path));
                state.output.write_all(PROMPT);
                prompt_state = .Waiting;
            },
            .Waiting => {
                if (state.input.readable_len() > 0) {
                    throttle = 1;
                    const slice = combuf.read_from(state.input, state.output);
                    state.output.write_all(slice);

                    if (combuf.advance()) {
                        prompt_state = .Processing;
                    }
                } else {
                    stx.sleep(&throttle);
                }
            },
            .Processing => {
                // Execution order
                // * Builtins
                // * Aliases
                // * Exec Command

                var args = ArgsIterator.init(combuf.command_slice());
                const command = args.next_arg().?;

                blt_blk: {
                    if (meta.stringToEnum(Builtins, command)) |builtin| {
                        switch (builtin) {
                            .exit => state.running = false,
                            .pwd => {
                                const path = workdir.realpathAlloc(alloc, ".") catch unreachable;
                                state.output.write_all(path);
                                state.output.write_all("\n");
                            },
                            .cd => {
                                if (args.next_arg()) |reldir| {
                                    const newdir = workdir.openDir(reldir, .{ .iterate = true }) catch |err| {
                                        std.debug.print("Failed to open dir: {!}\n", .{err});
                                        break :blt_blk;
                                    };
                                    newdir.setAsCwd() catch |err| {
                                        std.debug.print("Failed to set cwd: {!}\n", .{err});
                                        break :blt_blk;
                                    };
                                }
                            },
                        }
                    } else {}
                }

                prompt_state = .Prompting;
                combuf.release();
            },
        }
    }
}

const ArgsIterator = struct {
    command_line: []const u8,
    cursor: usize = 0,

    const State = enum { Unescaped, EscapedSingle, EscapedDouble };

    pub fn init(command_line: []const u8) ArgsIterator {
        return .{
            .command_line = command_line,
        };
    }

    pub fn next_arg(self: *ArgsIterator) ?[]const u8 {
        var state: ArgsIterator.State = .Unescaped;
        const start = self.cursor;

        if (self.command_line.len == start) {
            return null;
        }

        const end: usize = blk: for (
            self.command_line[self.cursor..],
            self.cursor..,
        ) |b, i| {
            switch (state) {
                .Unescaped => {
                    switch (b) {
                        DQUOTE => {
                            state = .EscapedDouble;
                        },
                        SQUOTE => {
                            state = .EscapedSingle;
                        },
                        ' ', '\t', '\n' => {
                            break :blk i;
                        },
                        else => {},
                    }
                },
                .EscapedDouble => {
                    if (b == DQUOTE) {
                        state = .Unescaped;
                    }
                },
                .EscapedSingle => {
                    if (b == SQUOTE) {
                        state = .Unescaped;
                    }
                },
            }
        } else {
            self.cursor = self.command_line.len;
            return self.command_line[start..];
        };

        self.cursor = end + 1;
        return self.command_line[start..end];
    }
};

const CommandBuffer = struct {
    buffer: [SIZE]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    cursor: usize = 0,

    const State = enum { Waiting, Ready };

    const SIZE = 4096;

    pub fn reset(self: *CommandBuffer) void {
        self.head = 0;
        self.tail = 0;
        self.cursor = 0;
    }

    pub fn readable_slice(self: *CommandBuffer) []const u8 {
        return self.buffer[self.tail..self.head];
    }

    pub fn command_slice(self: *CommandBuffer) []const u8 {
        return self.buffer[self.tail..self.cursor];
    }

    pub fn writable_slice(self: *CommandBuffer) []u8 {
        return self.buffer[self.head..];
    }

    pub fn read_from(self: *CommandBuffer, in: *IOPipe, out: *IOPipe) []const u8 {
        while (in.read_byte()) |byte| {
            switch (byte) {
                BACKSPACE, DELETE => {
                    if (self.head > self.tail) {
                        AnsiCode.write(.{ .move_left = 1 }, out);
                        AnsiCode.write(.clear_right, out);
                        self.head -= 1;
                        if (self.cursor > self.head) {
                            self.cursor = self.head;
                        }
                    }
                },
                else => {
                    self.buffer[self.head] = byte;
                    self.commit(1);
                },
            }
        }

        return self.buffer[self.cursor..self.head];
    }

    pub fn commit(self: *CommandBuffer, count: usize) void {
        assert(self.head + count <= SIZE);
        self.head += count;
    }

    /// Use after a command has been executed and is
    /// ready to be removed from the command buffer.
    ///
    /// If there was only one command, this will reset
    /// the buffer, otherwise if there's more input then
    /// this will move the tail forward until all commands
    /// are processed.
    pub fn release(self: *CommandBuffer) void {
        if (self.cursor == self.head) {
            self.reset();
        } else {
            assert(!std.mem.eql(u8, self.command_slice(), "\n"));
            self.tail = self.cursor;
        }
    }

    /// Move the cursor forward until we run into a newline that
    /// marks the end of the command.
    ///
    /// This will return true if the advance hit a newline and
    /// is ready to be executed, or false if we want more input.
    pub fn advance(self: *CommandBuffer) bool {
        assert(self.head >= self.cursor);
        const slice = self.buffer[self.cursor..self.head];

        for (slice) |byte| {
            switch (byte) {
                LINE_FEED => {
                    self.cursor += 1;
                    return true;
                },
                else => {},
            }
        }

        self.cursor = self.head;
        return false;
    }
};
