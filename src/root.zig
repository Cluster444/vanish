const std = @import("std");
const types = @import("types.zig");
const stdx = @import("stdx.zig");

const Config = types.Config;
const State = types.State;

const assert = std.debug.assert;
const indexOf = std.mem.indexOf;

const APP_ALLOC = std.mem.page_size * 1;
const Self = @This();

const PROMPT = " 👻 ";
const PromptState = enum { Prompting, Waiting, Processing };

const Builtins = enum {
    echo,
    exit,
};

pub export fn setup(cfg: *Config) void {
    cfg.mem_size = APP_ALLOC;
}

pub export fn run(state: *State) void {
    var prompt_state: PromptState = .Prompting;
    var combuf = CommandBuffer{};
    var running = true;

    while (running) {
        switch (prompt_state) {
            .Prompting => {
                state.output.write_all(PROMPT);
                prompt_state = .Waiting;
            },
            .Waiting => {
                if (state.input.read_len() > 0) {
                    const slice = combuf.writable_slice();
                    const count = state.input.read(slice);
                    state.output.write_all(slice[0..count]);

                    combuf.commit(count);
                    if (combuf.advance()) {
                        prompt_state = .Processing;
                    }
                }
            },
            .Processing => {
                // Execution order
                // * Builtins
                // * Aliases
                // * Exec Command

                const comslice = combuf.command_slice();
                const endcom = std.mem.indexOf(u8, comslice, " ") orelse comslice.len;
                const command = comslice[0 .. endcom - 1];

                if (std.meta.stringToEnum(Builtins, command)) |builtin| {
                    switch (builtin) {
                        .exit => running = false,
                        else => @panic("shitfuck"),
                    }
                } else {}

                prompt_state = .Prompting;
                combuf.release();
            },
        }
    }
}

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
        assert(self.head > self.cursor);

        if (indexOf(u8, self.buffer[self.cursor..self.head], "\n")) |idx| {
            self.cursor += idx + 1;
            return true;
        }

        self.cursor = self.head;
        return false;
    }
};
