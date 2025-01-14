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
            while (app.input.readable_len() > 0) {
                if (app.combuf.tee(app.input, app.output)) {
                    app.state = if (app.combuf.head == 1) .Prompting else .Processing;
                }
            }
        },
        .Processing => {
            // Execution order
            //
            // `builtin` builtin
            // Alias expansion
            // Exec Path
            // Exec Func
            // Exec Builtin
            // Hash lookup -> Exec Path
            // Search $PATH -> Exec Path
            // Else -> Command Not Found
            //
            // builtin <builtin> -> Exec builtin (noalias)
            // command builtin -> Exec builtin or path (noalias)
            // type -P <file> -> Exec executable on disk
            //
            // unalias - delete an alias
            // unset - delete a function
            // hash -d <name> delete a hash table entry

            assert(app.combuf.head > 0);

            // Alias Expansion
            //
            {
                if (app.combuf.peek_arg()) |arg| {
                    if (app.aliases.match(arg)) |replacement| {
                        app.combuf.replace(arg, replacement);
                    }
                }
            }

            var argc: usize = 0;
            var argv: [32][]const u8 = undefined;

            while (app.combuf.next_arg()) |arg| {
                if (argc < 32) {
                    argv[argc] = arg;
                    argc += 1;
                } else {
                    @panic("No application needs more than 32 args! Right!?!?");
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

                    app.output.write_all("+ ");
                    for (argv[0..argc]) |arg| {
                        app.output.write_byte(' ');
                        app.output.write_all(arg);
                    }
                    app.output.write_byte(asc.LINE_FEED);

                    var child = std.process.Child.init(argv[0..argc], allocator);
                    child.stdin_behavior = .Inherit;
                    child.stdout_behavior = .Inherit;
                    child.stderr_behavior = .Inherit;

                    child.spawn() catch unreachable;
                    const term = child.wait() catch unreachable;

                    switch (term) {
                        .Exited => {},
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

pub const CommandBuffer = struct {
    buffer: [SIZE]u8 = undefined,
    head: usize = 0,
    cursor: usize = 0,

    const SIZE = 4096;

    pub fn init(self: *CommandBuffer) void {
        self.head = 0;
        self.cursor = 0;
        @memset(self.buffer[0..SIZE], 0);
    }

    pub fn reset(self: *CommandBuffer) void {
        @memset(self.buffer[0..self.head], 0);
        stx.assert_zeroes(self.buffer[0..SIZE]);
        self.head = 0;
        self.cursor = 0;
    }

    pub fn command_slice(self: *CommandBuffer) []const u8 {
        return self.buffer[0..self.head];
    }

    pub fn tee(self: *CommandBuffer, in: *IOPipe, out: *IOPipe) bool {
        while (in.read_byte()) |byte| {
            switch (byte) {
                // We can bounce out once we get a newline so we can run the command
                asc.LINE_FEED => {
                    out.write_byte(byte);
                    return true;
                },
                asc.BACKSPACE, asc.DELETE => {
                    if (self.head > 0) {
                        // AnsiCode.write(.{ .move_left = 1 }, out);
                        // AnsiCode.write(.clear_right, out);
                        self.head -= 1;
                        out.write_byte(asc.BACKSPACE);
                    }
                },
                else => {
                    self.buffer[self.head] = byte;
                    self.head += 1;
                    out.write_byte(byte);
                },
            }
        }

        return false;
    }

    pub fn replace(self: *CommandBuffer, from: []const u8, to: []const u8) void {
        const begin = @intFromPtr(from.ptr) - @intFromPtr(&self.buffer);
        const from_end = begin + from.len;
        const to_end = begin + to.len;
        const expand_by = to.len - from.len;

        if (self.head > from_end) {
            stx.memcpy(
                self.buffer[from_end + expand_by .. self.cursor + expand_by],
                self.buffer[from_end..self.head],
            );
        }

        self.head += expand_by;
        @memcpy(self.buffer[begin..to_end], to);
    }

    pub fn next_arg(self: *CommandBuffer) ?[]const u8 {
        if (self.peek_arg()) |arg| {
            while (self.buffer[self.cursor] == ' ') : (self.cursor += 1) {}
            self.cursor += arg.len;
            return arg;
        } else {
            return null;
        }
    }

    const State = enum { Unescaped, EscapedDouble, EscapedSingle };

    pub fn peek_arg(self: *CommandBuffer) ?[]const u8 {
        var state: CommandBuffer.State = .Unescaped;

        var begin = self.cursor;
        while (self.buffer[begin] == ' ') : (begin += 1) {}

        if (self.head == begin) {
            return null;
        }

        // TODO: Handle backslash escapes
        const end: usize = blk: for (
            self.buffer[begin..],
            begin..,
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
                        ' ' => {
                            break :blk i;
                        },
                        asc.LINE_FEED => {
                            unreachable;
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
            break :blk self.head;
        };

        return self.buffer[begin..end];
    }
};
