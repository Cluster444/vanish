const std = @import("std");
const stx = @import("stx.zig");
const mem = @import("memory.zig");
const fs = std.fs;
const meta = std.meta;
const psx = std.posix;

const AtomSize = std.atomic.Value(usize);

const MemoryBlocks = enum {
    static,
    buffers,
    arena,
};

pub const Blocks = BlockAlloc(MemoryBlocks);

pub const TempMem = RingAllocator(16 * 1024);

const Aliases = AliasMap(16 * 1024);
const BumpAlloc = mem.BumpAlloc;
const BlockAlloc = mem.BlockAlloc;

const g = @import("global.zig").global;

const assert = std.debug.assert;

pub const MEMORY_OFFSET = 1 << 33;

const PromptState = enum {
    Prompting,
    ReadingInput,
    Parsing,
    ExecutingBuiltin,
    ExecutingCommand,
};

pub const Builtins = enum {
    exit,
    pwd,
    cd,
};

pub const Panic = struct {
    pub fn call(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
        g.term.cooked();
        std.debug.defaultPanic(msg, stack_trace, ret_addr);
    }

    pub const sentinelMismatch = std.debug.FormattedPanic.sentinelMismatch;
    pub const unwrapError = std.debug.FormattedPanic.unwrapError;
    pub const outOfBounds = std.debug.FormattedPanic.outOfBounds;
    pub const startGreaterThanEnd = std.debug.FormattedPanic.startGreaterThanEnd;
    pub const inactiveUnionField = std.debug.FormattedPanic.inactiveUnionField;
    pub const messages = std.debug.FormattedPanic.messages;
};

pub fn main() void {
    // Terminal Setup
    //
    g.term.init();
    defer g.term.cooked();

    // Allocate Memory
    //
    var memblk = Blocks{ .offset = MEMORY_OFFSET };
    memblk.reserve(.static, Aliases, 1);
    memblk.reserve(.static, BumpAlloc, 1);
    memblk.reserve(.static, CommandBuffer, 1);
    memblk.reserve(.static, Input, 1);
    memblk.reserve(.static, Output, 1);
    memblk.reserve(.static, TempMem, 1);
    memblk.reserve(.arena, u8, 1 << 20);
    memblk.commit();
    defer memblk.release();

    // Initialize Memory
    //
    var static_blk = memblk.block(.static);
    const aliases = static_blk.create(Aliases);
    const arena = static_blk.create(BumpAlloc);
    const combuf = static_blk.create(CommandBuffer);
    const input = static_blk.create(Input);
    const output = static_blk.create(Output);
    g.temp = static_blk.create(TempMem);
    aliases.init();
    arena.* = memblk.arena(.arena);

    // Current Path
    var cwd = struct {
        dir: fs.Dir = undefined,
        pathbuf: [psx.PATH_MAX]u8 = undefined,
        pathlen: usize = 0,

        const Self = @This();

        pub fn init(self: *Self, dir: fs.Dir) void {
            self.dir = dir.openDir(".", .{ .iterate = true }) catch unreachable;
            self.refresh(self.dir);
        }

        pub fn refresh(self: *@This(), dir: fs.Dir) void {
            self.dir = dir;
            const _path = dir.realpath(".", self.pathbuf[0..]) catch @panic("shitpath");
            self.pathlen = _path.len;
        }

        pub fn chdir(self: *@This(), reldir: []const u8) !void {
            var newdir = try self.dir.openDir(reldir, .{ .iterate = true });
            errdefer newdir.close();

            try psx.fchdir(newdir.fd);
        }

        pub fn path(self: *@This()) []const u8 {
            return self.pathbuf[0..self.pathlen];
        }

        pub fn iterator(self: *@This()) fs.Dir.Iterator {
            return self.dir.iterate();
        }
    }{};
    cwd.init(fs.cwd());

    // Load Config
    //
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

    // Run Loop
    //
    var state: PromptState = .Prompting;
    var running = true;
    var command: Command = .{};

    run: while (running) {
        defer arena.reset();

        switch (state) {
            .Prompting => {
                output.write(fs.path.basename(cwd.path()));
                output.write(" 👻 ");
                state = .ReadingInput;
                combuf.reset();
                g.term.sashimi();
            },
            .ReadingInput => {
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
                            // :Completions
                            //
                            var tmp_cmd: Command = .{};

                            var args_iter = combuf.iterator();
                            while (args_iter.next()) |arg| {
                                if (tmp_cmd.argc < 32) {
                                    tmp_cmd.argv[tmp_cmd.argc] = arg;
                                    tmp_cmd.argc += 1;
                                } else {
                                    @panic("No application needs more than 32 args! Right!?!?");
                                }
                            }

                            {
                                output.write(AnsiCode.code(.save));

                                const prefix = tmp_cmd.argv[tmp_cmd.argc - 1];
                                var completions: usize = 0;
                                var extend_buf: [256]u8 = undefined;
                                var extend: []u8 = extend_buf[0..256];
                                var first = true;
                                var dir_iter = cwd.iterator();
                                output.write(AnsiCode.code(.{ .move_down = 1 }));
                                output.write("\r");
                                output.write(AnsiCode.code(.clear_line));
                                while (dir_iter.next() catch null) |entry| {
                                    if (std.mem.startsWith(u8, entry.name, prefix)) {
                                        const completion = std.fs.path.basename(entry.name);
                                        if (extend.len > 0) {
                                            const ending = completion[prefix.len..];
                                            if (first) {
                                                first = false;
                                                stx.memcpy(extend_buf[0..], ending);
                                                extend = extend_buf[0..ending.len];
                                            } else {
                                                const end = @min(extend.len, ending.len);
                                                // std.debug.print("Extend len: {d} / Ending len: {d}\r\n", .{ extend.len, ending.len });
                                                // std.debug.print("End: {d}\n", .{end});
                                                for (0..end) |idx| {
                                                    if (extend[idx] != ending[idx]) {
                                                        // std.debug.print("idx: {d}\r\n", .{idx});
                                                        extend = extend[0..idx];
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                        completions += 1;
                                        output.write(completion);
                                        output.write_byte(asc.HORIZ_TAB);
                                    }
                                }

                                if (completions == 1) {
                                    output.write("\r");
                                    output.write(AnsiCode.code(.clear_line));
                                }

                                output.write(AnsiCode.code(.restore));
                                if (extend.len > 0) {
                                    combuf.insert(combuf.head, extend);
                                    output.write(extend);

                                    if (completions == 1) {
                                        // TODO: If the completion is a directory, append a slash
                                        // instead of a space, and then seraching in the subdirectory
                                        combuf.insert(combuf.head, " ");
                                        output.write_byte(' ');
                                    }
                                }
                            }
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

                var args_iter = combuf.iterator();
                // Alias Expansion
                //
                while (true) {
                    if (args_iter.peek()) |arg| {
                        if (aliases.find(arg)) |replacement| {
                            const replacing_self = std.mem.startsWith(u8, replacement, arg);
                            combuf.replace(arg, replacement);
                            if (!replacing_self) continue;
                        }
                    }
                    break;
                }

                const try_cmd = args_iter.peek().?;

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

                // args_iter.reset();
                while (args_iter.next()) |arg| {
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
                g.term.cooked();
                defer state = .Prompting;

                switch (command.builtin.?) {
                    .exit => running = false,
                    .pwd => {
                        output.writeln(cwd.path());
                    },
                    .cd => {
                        if (command.argc > 1) {
                            const reldir = command.argv[1];
                            cwd.chdir(reldir) catch |err| {
                                std.debug.print("Failed to open dir: {!}\n", .{err});
                                continue :run;
                            };
                        }
                    },
                }
                state = .Prompting;
            },
            .ExecutingCommand => {
                g.term.cooked();
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

fn AliasMap(comptime size: usize) type {
    stx.assert_log2(size);

    // Stores data in len:str format for the
    // key and value.
    return struct {
        buffer: [size]u8 = undefined,
        // cache: [64][8]u16 = undefined,
        head: usize = 0,
        // Cache

        const Self = @This();
        const SIZE = size;
        const MASK = SIZE - 1;

        pub fn init(self: *Self) void {
            self.head = 0;
        }

        pub fn insert(self: *Self, alias: []const u8, expansion: []const u8) void {
            assert(alias.len <= 256);
            assert(expansion.len <= 256);
            assert(self.buffer.len >= self.head + alias.len + expansion.len + 2);

            self.buffer[self.head] = @intCast(alias.len);
            stx.memcpy(self.buffer[self.head + 1 ..], alias);
            self.buffer[self.head + 1 + alias.len] = @intCast(expansion.len);
            stx.memcpy(self.buffer[self.head + alias.len + 2 ..], expansion);
            self.head += alias.len + expansion.len + 2;
        }

        pub fn find(self: *Self, alias: []const u8) ?[]const u8 {
            var cursor: usize = 0;
            while (cursor < self.head) {
                const key_len = self.buffer[cursor];
                const key = self.buffer[cursor + 1 .. cursor + 1 + key_len];
                const val_len = self.buffer[cursor + 1 + key_len];

                if (std.mem.eql(u8, key, alias)) {
                    return self.buffer[cursor + key_len + 2 .. cursor + key_len + val_len + 2];
                }

                cursor += key_len + val_len + 2;
            }

            return null;
        }
    };
}

const Command = struct {
    argv: [32][]const u8 = undefined,
    argc: u8 = 0,
    builtin: ?Builtins = null,
};

const CommandBuffer = struct {
    buffer: [SIZE]u8 = undefined,
    head: usize = 0,
    version: usize = 0,

    const SIZE = 4096;

    pub fn init(self: *CommandBuffer) void {
        self.head = 0;
        @memset(self.buffer[0..SIZE], 0);
    }

    pub fn reset(self: *CommandBuffer) void {
        @memset(self.buffer[0..self.head], 0);
        stx.assert_zeroes(self.buffer[0..SIZE]);
        self.head = 0;
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
        self.version += 1;
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
        self.version += 1;
    }

    pub fn iterator(self: *CommandBuffer) Iterator {
        return .{
            .combuf = self,
            .cursor = 0,
            .buffer = self.buffer[0..self.head],
            .version = self.version,
        };
    }

    pub fn debug(self: *CommandBuffer) void {
        std.debug.print("Buffer: {s}\n", .{self.buffer[0..self.head]});
    }

    pub const Iterator = struct {
        const State = enum { Unescaped, EscapedDouble, EscapedSingle };

        combuf: *CommandBuffer,
        buffer: []const u8,
        cursor: usize = 0,
        version: usize = 0,

        pub fn next(self: *Iterator) ?[]const u8 {
            if (self.peek()) |arg| {
                while (self.buffer[self.cursor] == ' ') : (self.cursor += 1) {}
                self.cursor += arg.len;
                return arg;
            } else {
                return null;
            }
        }

        fn refresh(self: *Iterator) void {
            self.buffer = self.combuf.buffer[0..self.combuf.head];
            self.version = self.combuf.version;
            self.cursor = 0;
        }

        pub fn peek(self: *Iterator) ?[]const u8 {
            if (self.version != self.combuf.version) {
                self.refresh();
            }

            var state: Iterator.State = .Unescaped;

            var begin = self.cursor;
            if (self.buffer.len == begin) {
                return null;
            }

            while (self.buffer[begin] == ' ') : (begin += 1) {}

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
                break :blk self.buffer.len;
            };

            return self.buffer[begin..end];
        }
    };
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

pub fn RingAllocator(comptime cap: usize) type {
    return struct {
        const Self = @This();

        buffer: RingBuffer(cap, false) = undefined,

        pub fn init(self: *Self) void {
            self.buffer.init("TempMem");
        }

        pub fn alloc(self: *Self, count: usize) []u8 {
            assert(count <= cap);

            var writable = self.buffer.writable_slice().len;

            if (count > writable) {
                self.buffer.commit(writable);
            }

            writable = self.buffer.writable_slice().len;

            if (count > writable) {
                self.buffer.release(count - writable);
            }

            const result = self.buffer.writable_slice()[0..count];
            self.buffer.commit(count);
            return result;
        }

        pub fn store(self: *Self, bytes: []const u8) []u8 {
            assert(bytes.len <= cap);
            const slice = self.alloc(bytes.len);

            @memcpy(slice, bytes);
            self.buffer.commit(bytes.len);
            return slice[0..bytes.len];
        }

        pub fn reset(self: *Self) void {
            self.head = 0;
        }
    };
}

pub fn RingBuffer(comptime size: u32, comptime thread_safe: bool) type {
    std.debug.assert(@popCount(size) == 1);
    std.debug.assert(size > 1);

    const alignment = if (thread_safe) 64 else @alignOf(AtomSize);

    return struct {
        buffer: [size]u8 = undefined,
        head: AtomSize align(alignment) = AtomSize.init(0),
        tail: AtomSize align(alignment) = AtomSize.init(0),
        name: []const u8,

        const Self = @This();
        pub const SIZE = size;
        const MASK = size - 1;

        pub fn init(self: *Self, name: []const u8) void {
            self.name = name;
            self.reset();
        }

        pub fn reset(self: *Self) void {
            self.head.raw = 0;
            self.tail.raw = 0;
        }

        // Producer side
        //
        pub fn writable_len(self: *Self) usize {
            return SIZE - self.readable_len();
        }

        pub fn writable_slice(self: *Self) []u8 {
            const rhead = if (thread_safe) self.head.load(.acquire) else self.head.raw;
            const avail = self.writable_len();
            const head = rhead & MASK;
            const wrap = SIZE - head;

            return self.buffer[head..(head +% @min(avail, wrap))];
        }

        pub fn commit(self: *Self, count: usize) void {
            assert(count <= self.writable_len());
            if (thread_safe) {
                self.head.store(self.head.raw +% count, .release);
            } else {
                self.head.raw +%= count;
            }
        }

        pub fn write(self: *Self, bytes: []const u8) usize {
            var slice = self.writable_slice();
            const bytes_to_write = @min(bytes.len, slice.len);

            if (bytes_to_write > 0) {
                @memcpy(slice[0..bytes_to_write], bytes[0..bytes_to_write]);
                self.commit(bytes_to_write);
            }

            return bytes_to_write;
        }

        pub fn write_all(self: *Self, bytes: []const u8) void {
            var cursor = bytes;

            while (cursor.len > 0) {
                const count = self.write(cursor);
                cursor = cursor[count..];
            }
        }

        pub fn write_byte(self: *Self, byte: u8) void {
            assert(self.writable_len() > 0);

            self.buffer[self.head.raw & MASK] = byte;
            self.commit(1);
        }

        // Consumer Side
        //
        pub fn readable_len(self: *Self) usize {
            return self.head.raw -% self.tail.raw;
        }

        pub fn readable_slice(self: *Self) []const u8 {
            const rtail = if (thread_safe) self.tail.load(.acquire) else self.tail.raw;
            const avail = self.readable_len();
            const tail = rtail & MASK;
            const wrap = SIZE - tail;

            return self.buffer[tail..(tail +% @min(avail, wrap))];
        }

        pub fn release(self: *Self, count: usize) void {
            assert(count <= self.readable_len());
            if (thread_safe) {
                self.tail.store(self.tail.raw +% count, .release);
            } else {
                self.tail.raw +%= count;
            }
        }

        pub fn read(self: *Self, bytes: []u8) usize {
            var slice = self.readable_slice();
            const bytes_to_read = @min(bytes.len, slice.len);

            if (bytes_to_read > 0) {
                @memcpy(bytes[0..bytes_to_read], slice[0..bytes_to_read]);
                self.release(bytes_to_read);
            }

            return bytes_to_read;
        }

        pub fn read_all(self: *Self, bytes: []u8) void {
            var cursor = bytes;

            while (cursor.len > 0) {
                const count = self.read(cursor);
                cursor = cursor[count..];
            }
        }

        pub fn read_byte(self: *Self) ?u8 {
            if (self.readable_len() == 0) {
                return null;
            }

            const byte: u8 = self.buffer[self.tail.raw];
            self.release(1);
            return byte;
        }
    };
}

const t = std.testing;

test "RingBuffer concurrent access" {
    const ITERS = 654321;

    const expected_cksum: usize = blk: {
        var sum: usize = 0;
        for (0..ITERS) |i| {
            const byte: u8 = @truncate(i);
            sum += byte;
        }
        break :blk sum;
    };

    inline for (.{ 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024 }) |size| {
        const Buffer = RingBuffer(size, true);
        var buffer = Buffer{ .name = "Test" };

        var produced: usize = 0;
        var consumed: usize = 0;

        const producer = std.Thread.spawn(.{}, struct {
            fn run(buf: *Buffer, total: *usize) void {
                for (0..ITERS) |i| {
                    while (buf.writable_len() == 0) {}

                    const slice = buf.writable_slice();
                    if (slice.len > 0) {
                        slice[0] = @truncate(i);
                        buf.commit(1);
                        total.* += 1;
                    }
                }
            }
        }.run, .{ &buffer, &produced }) catch @panic("shitthread");

        var checksum: usize = 0;

        const consumer = std.Thread.spawn(.{}, struct {
            fn run(buf: *Buffer, total: *usize, cksum: *usize) void {
                for (0..ITERS) |_| {
                    while (buf.readable_len() == 0) {}

                    const slice = buf.readable_slice();
                    if (slice.len > 0) {
                        const byte = slice[0];
                        buf.release(1);
                        cksum.* += byte;
                        total.* += 1;
                    }
                }
            }
        }.run, .{ &buffer, &consumed, &checksum }) catch @panic("shitthread");

        producer.join();
        consumer.join();

        const result = .{ produced, consumed, checksum };

        try t.expectEqual(expected_cksum, result[2]);
        try t.expectEqual(result[0], result[1]);
    }
}

// zig fmt: off
// ASCII Codes
//
const asc = struct {
    const NULL       = 0x00;
    const START_HEAD = 0x01;
    const START_TEXT = 0x02;
    const END_TEXT   = 0x03;
    const END_TRANSM = 0x04;
    const ENQUIRY    = 0x05;
    const ACK        = 0x06;
    const BELL       = 0x07;
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
    const CTRL_C     = END_TEXT;
};

// zig fmt: on

const AnsiCode = union(enum) {
    move_up: u8,
    move_down: u8,
    move_right: u8,
    move_left: u8,
    move_begin_up: u8,
    move_begin_down: u8,
    move_col: u8,
    scroll_up: u8,
    scroll_down: u8,
    home,
    clear_up,
    clear_down,
    clear_all,
    clear_right,
    clear_left,
    clear_line,
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
            .scroll_up       => |n| return format(CSI ++ "{d}S", .{n}),
            .scroll_down     => |n| return format(CSI ++ "{d}T", .{n}),
            .home            => return CSI ++ "H",
            .clear_up        => return CSI ++ "0J",
            .clear_down      => return CSI ++ "1J",
            .clear_all       => return CSI ++ "2J",
            .clear_right     => return CSI ++ "0K",
            .clear_left      => return CSI ++ "1K",
            .clear_line      => return CSI ++ "2K",
            .save            => return CSI ++ "s",
            .restore         => return CSI ++ "u",
            // zig fmt: on
        }
    }

    fn format(comptime fmt: []const u8, args: anytype) []const u8 {
        var buffer: [16]u8 = undefined;
        const res = std.fmt.bufPrint(&buffer, fmt, args) catch unreachable;
        return g.temp.store(res);
    }
};
