const std = @import("std");
const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;
const psx = std.posix;
const assert = std.debug.assert;
const indexOf = std.mem.indexOf;

const asc = @import("ascii.zig");
const stx = @import("stx.zig");
const typ = @import("types.zig");
const Config = typ.Config;
const State = typ.State;
const IOPipe = typ.IOPipe;

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

pub export fn setup(cfg: *Config) void {
    _ = cfg;
}

pub const PROMPT = " 👻 ";

pub const Builtins = enum {
    exit,
    pwd,
    cd,
};

// Run
//
pub export fn run(app: *State) void {
    var cwd = std.fs.cwd();

    switch (app.state) {
        .Prompting => {
            const pathbuf = app.arena.alloc(1024);
            const path = cwd.realpath(".", pathbuf) catch unreachable;
            app.output.write_all(fs.path.basename(path));
            app.output.write_all(PROMPT);
            app.state = .Waiting;
            app.combuf.reset();
        },
        .Waiting => {
            if (app.input.readable_len() > 0) {
                const slice = app.combuf.read_from(app.input, app.output);
                app.output.write_all(slice);

                if (slice.len > 0 and slice[slice.len - 1] == asc.LINE_FEED) {
                    app.state = if (app.combuf.head == 1) .Prompting else .Processing;
                }
            }
        },
        .Processing => {
            // Execution order
            // * Builtins
            // * Aliases
            // * Exec Command

            const com_slice = std.mem.trim(u8, app.combuf.command_slice(), " \n\r\t");
            assert(com_slice.len > 0);

            var args = ArgsIterator.init(app.combuf.command_slice());
            var argc: usize = 0;
            var argv: [32][]const u8 = undefined;

            while (args.next_arg()) |arg| {
                if (argc < 32) {
                    argv[argc] = arg;
                    argc += 1;
                } else {
                    @panic("No application needs more than 32 args");
                }
            }

            blt_blk: {
                if (meta.stringToEnum(Builtins, argv[0])) |builtin| {
                    switch (builtin) {
                        .exit => app.running = false,
                        .pwd => {
                            const pathbuf = app.arena.alloc(1024);
                            const path = cwd.realpath(".", pathbuf) catch unreachable;
                            app.output.write_all(path);
                            app.output.write_all("\n");
                        },
                        .cd => {
                            if (argc > 1) {
                                const reldir = argv[1];
                                const newdir = cwd.openDir(reldir, .{ .iterate = true }) catch |err| {
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
                } else {
                    // TODO: All of this needs to go to platform and be handled by
                    // the platform thread
                    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer arena.deinit();
                    const allocator = arena.allocator();

                    var child = std.process.Child.init(argv[0..argc], allocator);
                    child.stdin_behavior = .Inherit;
                    child.stdout_behavior = .Inherit;
                    child.stderr_behavior = .Inherit;

                    child.spawn() catch unreachable;

                    const term = child.wait() catch unreachable;

                    switch (term) {
                        .Exited => {
                            // app.output.write_all(output);
                            // app.output.write_all(errout);
                        },
                        .Signal => {
                            app.output.write_all("Signaled\n");
                        },
                        .Stopped => {
                            app.output.write_all("Stopped\n");
                        },
                        .Unknown => {
                            app.output.write_all("Unknown\n");
                        },
                    }
                }
            }

            app.state = .Prompting;
        },
    }
    // }
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
                        asc.DQUOTE => {
                            state = .EscapedDouble;
                        },
                        asc.SQUOTE => {
                            state = .EscapedSingle;
                        },
                        ' ', '\t', '\n' => {
                            break :blk i;
                        },
                        else => {},
                    }
                },
                .EscapedDouble => {
                    if (b == asc.DQUOTE) {
                        state = .Unescaped;
                    }
                },
                .EscapedSingle => {
                    if (b == asc.SQUOTE) {
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

pub const CommandBuffer = struct {
    buffer: [SIZE]u8 = undefined,
    head: usize = 0,

    const State = enum { Waiting, Ready };

    const SIZE = 4096;

    pub fn init(self: *CommandBuffer) void {
        self.reset();
    }

    pub fn reset(self: *CommandBuffer) void {
        self.head = 0;
    }

    pub fn command_slice(self: *CommandBuffer) []const u8 {
        return self.buffer[0..self.head];
    }

    pub fn read_from(self: *CommandBuffer, in: *IOPipe, out: *IOPipe) []const u8 {
        var begin = self.head;

        while (in.read_byte()) |byte| blk: {
            switch (byte) {
                // We can bounce out once we get a newline so we can run the command
                asc.LINE_FEED => {
                    self.buffer[self.head] = byte;
                    self.head += 1;
                    break :blk;
                },
                asc.BACKSPACE, asc.DELETE => {
                    if (self.head > 0) {
                        AnsiCode.write(.{ .move_left = 1 }, out);
                        AnsiCode.write(.clear_right, out);
                        begin -= 1;
                        self.head -= 1;
                    }
                },
                else => {
                    self.buffer[self.head] = byte;
                    self.head += 1;
                },
            }
        }

        return self.buffer[begin..self.head];
    }
};
