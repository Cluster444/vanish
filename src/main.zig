const std = @import("std");
const asc = @import("ascii.zig");
const typ = @import("types.zig");
const root = @import("root.zig");
const stx = @import("stx.zig");
const mem = @import("memory.zig");
const fs = std.fs;
const meta = std.meta;
const psx = std.posix;

const AliasMap = typ.AliasMap;
const ByteAllocator = mem.ByteAllocator;
const Blocks = typ.Blocks;
const Config = typ.Config;
const IOPipe = typ.IOPipe;
const State = typ.State;

const assert = std.debug.assert;

pub const MEMORY_OFFSET = 1 << 33;

const PromptState = enum {
    Prompting,
    ReadingInput,
    Parsing,
    ExecutingBuiltin,
    ExecutingCommand,
};

pub const Panic = root.Panic;

pub const Builtins = enum {
    exit,
    pwd,
    cd,
};

pub fn main() void {
    // Terminal Setup
    //
    var term = &root.term;
    root.term.init();
    defer term.cooked();

    // Allocate Memory
    //
    var memblk = Blocks{ .offset = MEMORY_OFFSET };
    memblk.reserve(.static, AliasMap, 1);
    memblk.reserve(.static, ByteAllocator, 1);
    memblk.reserve(.static, CommandBuffer, 1);
    memblk.reserve(.static, Input, 1);
    memblk.reserve(.static, Output, 1);
    memblk.reserve(.static, mem.TempMem, 1);
    memblk.reserve(.arena, u8, 1 << 20);
    memblk.commit();
    defer memblk.release();

    // Initialize Memory
    //
    var static_blk = memblk.block(.static);
    const aliases = static_blk.create(AliasMap);
    const arena = static_blk.create(ByteAllocator);
    const combuf = static_blk.create(CommandBuffer);
    const input = static_blk.create(Input);
    const output = static_blk.create(Output);
    mem.temp = static_blk.create(mem.TempMem);
    aliases.init();
    arena.* = memblk.arena(.arena);

    aliases.insert("ls", "ls -FG");
    aliases.insert("ll", "ls -lh");
    aliases.insert("tree", "tree -C");
    aliases.insert("tg", "tree --gitignore");
    aliases.insert("vim", "nvim");
    aliases.insert("grep", "rg");
    aliases.insert("ga", "git add");
    aliases.insert("gaa", "git add .");
    aliases.insert("gcam", "git commit -am");
    aliases.insert("gcm", "git commit -m");
    aliases.insert("gd", "git diff");
    aliases.insert("gds", "git diff --staged");
    aliases.insert("gl", "git log --oneline");
    aliases.insert("gr", "git restore");
    aliases.insert("grs", "git restore --staged");
    aliases.insert("gs", "git status --short --branch");
    aliases.insert("gss", "git diff --name-status --cached");

    // Current Path
    const Cwd = struct {
        dir: fs.Dir = undefined,
        pathbuf: [psx.PATH_MAX]u8 = undefined,
        pathlen: usize = 0,

        pub fn refresh(self: *@This(), dir: fs.Dir) void {
            self.dir = dir;
            const _path = dir.realpath(".", self.pathbuf[0..]) catch @panic("shitpath");
            self.pathlen = _path.len;
        }

        pub fn path(self: *@This()) []const u8 {
            return self.pathbuf[0..self.pathlen];
        }
    };
    var cwd = Cwd{};
    cwd.refresh(fs.cwd());

    // Run Loop
    //
    var state: PromptState = .Prompting;
    var running = true;
    var command: struct {
        argc: u8 = 0,
        argv: [32][]const u8 = undefined,
        builtin: ?Builtins = null,
    } = .{};

    run: while (running) {
        defer arena.reset();

        switch (state) {
            .Prompting => {
                output.write(fs.path.basename(cwd.path()));
                output.write(" 👻 ");
                state = .ReadingInput;
                combuf.reset();
                term.sashimi();
            },
            .ReadingInput => {
                // var outbuf = std.BoundedArray(u8, 64).init(0) catch unreachable;

                if (input.read_byte()) |byte| {
                    switch (byte) {
                        asc.CTRL_C => {
                            output.writeln("CTRL_C");
                            running = false;
                        },
                        asc.LINE_FEED, asc.CAR_RETURN => {
                            state = if (combuf.head == 0) .Prompting else .Parsing;
                            output.writeln(" ");
                        },
                        asc.BACKSPACE, asc.DELETE => {
                            if (combuf.head > 0) {
                                output.write_byte(asc.BACKSPACE);
                                output.write(AnsiCode.code(.clear_right));
                                combuf.drop(1);
                            }
                        },
                        asc.HORIZ_TAB => {
                            // TODO: Completion
                            // output.write_byte(0);
                        },
                        asc.ESCAPE => {
                            const ack_esc = (input.read_byte() orelse 0) == '[';
                            if (ack_esc) {
                                const esc_byte = input.read_byte() orelse 0;

                                switch (esc_byte) {
                                    'A' => {
                                        // Key up
                                    },
                                    'B' => {
                                        // Key down
                                    },
                                    'C' => {
                                        // Key right
                                    },
                                    'D' => {
                                        // Key left
                                    },
                                    else => {
                                        output.writeln("Unknown Escape Key");
                                    },
                                }
                            } else {
                                output.writeln("Bad Escape Sequence");
                                state = .Prompting;
                                continue :run;
                            }
                        },
                        else => {
                            @branchHint(.likely);
                            // TODO: Completion Hint
                            output.write_byte(byte);
                            combuf.push(byte);
                        },
                    }
                }
            },
            .Parsing => {
                // Execution order
                //
                // `builtin` builtin
                // ^ Alias expansion
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

                assert(combuf.head > 0);

                // Alias Expansion
                //
                while (true) {
                    if (combuf.peek_arg()) |arg| {
                        if (aliases.find(arg)) |replacement| {
                            const replacing_self = std.mem.startsWith(u8, replacement, arg);
                            combuf.replace(arg, replacement);
                            if (!replacing_self) continue;
                        }
                    }
                    break;
                }

                const try_cmd = combuf.peek_arg().?;

                if (meta.stringToEnum(Builtins, try_cmd)) |builtin| {
                    command.builtin = builtin;
                    state = .ExecutingBuiltin;
                    continue :run;
                }

                var slash_pos: usize = 0;
                while (slash_pos < try_cmd.len) : (slash_pos += 1) {
                    if (try_cmd[slash_pos] == '/') {
                        std.debug.print("Found path command", .{});
                        break;
                    }
                } else {
                    const path_env = psx.getenv("PATH").?;

                    var path_begin: usize = 0;
                    var path_cursor: usize = 0;

                    path: while (path_cursor < path_env.len) : (path_cursor += 1) {
                        if (path_env[path_cursor] == ':') {
                            const path_str = path_env[path_begin..path_cursor];
                            const path_dir = fs.cwd().openDir(path_str, .{}) catch {
                                path_begin += path_str.len + 1;
                                path_cursor += 1;
                                continue :path;
                            };
                            const path_mode = psx.F_OK;

                            psx.faccessat(path_dir.fd, try_cmd, path_mode, 0) catch |err| switch (err) {
                                psx.AccessError.FileNotFound => {
                                    path_begin += path_str.len + 1;
                                    path_cursor += 1;
                                    continue :path;
                                },
                                else => {
                                    output.writeln("Permission Denied");
                                    state = .Prompting;
                                    continue :run;
                                },
                            };

                            var new_argv: [psx.PATH_MAX]u8 = undefined;
                            stx.memcpy(new_argv[0..], path_str);
                            new_argv[path_str.len] = '/';
                            combuf.insert(0, new_argv[0..(path_str.len + 1)]);
                            break :path;
                        }
                    } else {
                        output.writeln("Command not found");
                        state = .Prompting;
                        continue :run;
                    }
                }

                command = .{ .argc = 0, .argv = undefined };

                while (combuf.next_arg()) |arg| {
                    if (command.argc < 32) {
                        command.argv[command.argc] = arg;
                        command.argc += 1;
                    } else {
                        @panic("No application needs more than 32 args! Right!?!?");
                    }
                }

                state = .ExecutingCommand;
            },
            .ExecutingBuiltin => {
                term.cooked();
                switch (command.builtin.?) {
                    .exit => running = false,
                    .pwd => {
                        output.writeln(cwd.path());
                    },
                    .cd => {
                        if (command.argc > 1) {
                            const reldir = command.argv[1];
                            const newdir = cwd.dir.openDir(reldir, .{}) catch |err| {
                                std.debug.print("Failed to open dir: {!}\n", .{err});
                                state = .Prompting;
                                continue;
                            };
                            newdir.setAsCwd() catch |err| {
                                std.debug.print("Failed to set cwd: {!}\n", .{err});
                                state = .Prompting;
                                continue;
                            };
                            cwd.refresh(newdir);
                        }
                    },
                }
                state = .Prompting;
            },
            .ExecutingCommand => {
                term.cooked();
                defer state = .Prompting;

                // TODO: Rewrite this doing the fork/execve ourselves
                // so we dont have to deal with zig allocsators
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                const allocator = scratch.allocator();

                output.write("+ ");
                for (command.argv[0..command.argc]) |arg| {
                    output.write_byte(' ');
                    output.write(arg);
                }
                output.write_byte(asc.LINE_FEED);

                var child = std.process.Child.init(command.argv[0..command.argc], allocator);
                child.stdin_behavior = .Inherit;
                child.stdout_behavior = .Inherit;
                child.stderr_behavior = .Inherit;

                child.spawn() catch unreachable;
                const child_term = child.wait() catch unreachable;

                switch (child_term) {
                    .Exited => {},
                    .Signal => {
                        output.write("Signaled\n");
                    },
                    .Stopped => {
                        output.write("Stopped\n");
                    },
                    .Unknown => {
                        output.write("Unknown\n");
                    },
                }
            },
        }
    }
}

const Output = struct {
    vecs: [16]psx.iovec_const = undefined,
    head: u8 = 0,
    len: usize = 0,

    pub fn write_byte(self: *Output, byte: u8) void {
        _ = self;
        const count = psx.write(psx.STDOUT_FILENO, &[_]u8{byte}) catch unreachable;
        assert(count == 1);
    }

    pub fn write(self: *Output, buffer: []const u8) void {
        _ = self;
        const count = psx.write(psx.STDOUT_FILENO, buffer) catch unreachable;
        assert(count == buffer.len);
    }

    pub fn writeln(self: *Output, buffer: []const u8) void {
        self.write(buffer);
        self.write("\r\n");
    }
};

const Input = struct {
    fds: [1]psx.pollfd = undefined,

    pub fn init(self: *Input) void {
        self.fds[0] = .{ .fd = psx.STDIN_FILENO, .events = psx.POLL.IN, .revents = 0 };
    }

    pub fn read_byte(self: *Input) ?u8 {
        const stdin = psx.STDIN_FILENO;

        if (psx.poll(self.fds[0..], 0)) |n| {
            if (n > 0) {
                var buf = [_]u8{0};
                _ = psx.read(stdin, buf[0..1]) catch unreachable;
                return buf[0];
            }
        } else |err| {
            std.debug.print("stdin: {any}\n", .{err});
        }

        return null;
    }
};

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

    pub fn push(self: *CommandBuffer, byte: u8) void {
        self.buffer[self.head] = byte;
        self.head += 1;
    }

    pub fn drop(self: *CommandBuffer, n: usize) void {
        if (self.head >= n) {
            self.head -= n;
        } else {
            self.head = 0;
        }
    }

    pub fn insert(self: *CommandBuffer, index: usize, source: []const u8) void {
        assert(self.buffer.len >= self.head + source.len);
        stx.memcpy(self.buffer[index..][source.len..], self.buffer[index..self.head]);
        stx.memcpy(self.buffer[index..], source);
        self.head += source.len;
    }

    pub fn replace(self: *CommandBuffer, target: []const u8, source: []const u8) void {
        const begin = @intFromPtr(target.ptr) - @intFromPtr(&self.buffer);
        const target_end = begin + target.len;
        const source_end = begin + source.len;
        const delta = source.len - target.len;

        if (self.head > target_end) {
            stx.memcpy(
                self.buffer[target_end + delta .. self.head + delta],
                self.buffer[target_end..self.head],
            );
        }

        self.head += delta;
        @memcpy(self.buffer[begin..source_end], source);
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

    pub fn code(self: AnsiCode) []const u8 {
        switch (self) {
            // zig fmt: off
            .move_up         => |n| return format(CSI ++ "{d}A", .{n}),
            .move_down       => |n| return format(CSI ++ "{d}B", .{n}),
            .move_right      => |n| return format(CSI ++ "{d}C", .{n}),
            .move_left       => |n| return format(CSI ++ "{d}D", .{n}),
            .move_begin_up   => |n| return format(CSI ++ "{d}E", .{n}),
            .move_begin_down => |n| return format(CSI ++ "{d}F", .{n}),
            .move_col        => |n| return format(CSI ++ "{d}G", .{n}),
            .home            => return CSI ++ "H",
            .clear_up        => return CSI ++ "0J",
            .clear_down      => return CSI ++ "1J",
            .clear_all       => return CSI ++ "2J",
            .clear_right     => return CSI ++ "0K",
            .clear_left      => return CSI ++ "1K",
            .clear_line      => return CSI ++ "2K",
            .scroll_up       => return ESC ++ " M",
            .save            => return ESC ++ " 7",
            .restore         => return ESC ++ " 8",
            // zig fmt: on
        }
    }

    fn format(comptime fmt: []const u8, args: anytype) []const u8 {
        var buffer: [16]u8 = undefined;
        const res = std.fmt.bufPrint(&buffer, fmt, args) catch unreachable;
        return mem.temp.alloc(res);
    }
};
