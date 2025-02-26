const std = @import("std");
const stx = @import("stx.zig");
const mem = @import("memory.zig");
const fs = std.fs;
const psx = std.posix;

const BumpAlloc = mem.BumpAlloc;
const BlockAlloc = mem.BlockAlloc;

const AtomSize = std.atomic.Value(usize);
const Blocks = BlockAlloc(MemoryBlocks);
const TempMem = RingAllocator(1 * MB);
const Aliases = AliasMap(1 * MB);
const History = HistoryList(1 * MB);

const assert = std.debug.assert;

const log = std.log;

fn dbg_prompt(prompt: *CommandBuffer) void {
    var buf = RingBuffer(1024, false){ .name = "" };
    var tmp: [64]u8 = undefined;

    buf.write_all("\x1b[s");
    buf.write_all("\x1b[2;1H\x1b[0K Prompt: ");
    buf.write_all(prompt.command_slice());
    buf.write_all("\x1b[3;1H\x1b[0K Head: ");
    const head_len = std.fmt.formatIntBuf(&tmp, prompt.head, 10, .lower, .{});
    buf.write_all(tmp[0..head_len]);
    buf.write_all("\x1b[4;1H\x1b[0K ---------------------------------------------");
    buf.write_all("\x1b[u");

    output.write(buf.readable_slice());
    buf.reset();
}

const KB = 1024;
const MB = 1024 * KB;
const GB = 1024 * MB;

const MEMORY_OFFSET = 1 << 33;

const MemoryBlocks = enum {
    static,
};

const PromptState = enum {
    Prompting,
    ReadingInput,
    Parsing,
    ExecutingBuiltin,
    ExecutingCommand,
};

const Builtins = enum {
    clear,
    exit,
    pwd,
    cd,

    const CLEAR = "clear";
    const EXIT = "exit";
    const PWD = "pwd";
    const CD = "cd";

    pub fn from_str(cmd: []const u8) ?Builtins {
        if (stx.str_eql(cmd, CD)) return .cd;
        if (stx.str_eql(cmd, PWD)) return .pwd;
        if (stx.str_eql(cmd, EXIT)) return .exit;
        if (stx.str_eql(cmd, CLEAR)) return .clear;

        return null;
    }
};

pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, ret_addr: ?usize) noreturn {
        term.cooked();
        std.debug.simple_panic.call(msg, ret_addr);
    }
}.panic);

var input: *Input = undefined;
var output: *Output = undefined;
var outerr: *Output = undefined;

var term: Term = .{};
var temp: *TempMem = undefined;

pub fn main() void {
    log.info("Vanish init.", .{});
    // Terminal Setup
    //
    term.init();
    defer term.cooked();

    // Allocate Memory
    //
    var memblk = Blocks{ .offset = MEMORY_OFFSET };
    memblk.reserve(.static, Aliases, 1);
    memblk.reserve(.static, History, 1);
    memblk.reserve(.static, BumpAlloc, 1);
    memblk.reserve(.static, CommandBuffers, 1);
    memblk.reserve(.static, Input, 1);
    memblk.reserve(.static, Output, 2);
    memblk.reserve(.static, TempMem, 1);
    memblk.commit();
    defer memblk.release();

    // Initialize Memory
    //
    var static_blk = memblk.block(.static);
    const aliases = static_blk.create(Aliases);
    const history = static_blk.create(History);
    const combufs = static_blk.create(CommandBuffers);
    input = static_blk.create(Input);
    output = static_blk.create(Output);
    outerr = static_blk.create(Output);
    temp = static_blk.create(TempMem);
    // aliases.init();

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
            self.refresh(newdir);
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
    combufs.reset();
    var combuf: *CommandBuffer = &combufs.buffers[0];
    var prompt = Prompt{};

    prompt.write(fs.path.basename(cwd.path()));
    prompt.write(" 👻 ");

    var dp = DebugPanel{ .term = &term };
    dp.show = false;

    term.sashimi();
    term.push(.home);
    term.push(.clear_all);
    term.push(.{ .move_to = .{ if (dp.show) 6 else 1, 1 } });
    output.write(term.buffer[0..term.head]);
    term.head = 0;

    var got_input = false;

    run: while (running) {
        defer {
            output.write(term.buffer[0..term.head]);
            term.head = 0;
            if (dp.show) {
                dp.draw();
            }

            // TODO: We dont really want to sleep here on every loop end, instead
            // it would be better to only sleep when we get no input. But this makes
            // testing difficult. Might need some flag that allows some synchronizing
            // between the test mock terminal and the shell.
            const sleep_time: usize = if (got_input) 1 else 10;
            std.Thread.sleep(std.time.ns_per_ms * sleep_time);
        }

        switch (state) {
            .Prompting => {
                combufs.reset();
                combuf = &combufs.buffers[0];
                term.sashimi();
                state = .ReadingInput;
            },
            .ReadingInput => {
                if (dp.show) {
                    dp.dbg_history(history);
                    dp.dbg_combuf(combuf);
                    dp.dbg_combufs(combufs);
                }

                term.write("\r");
                term.push(.clear_line);
                term.write(prompt.buffer[0..prompt.head]);
                term.write(combuf.buffer[0..combuf.head]);

                got_input = false;
                if (input.read_byte()) |byte| {
                    got_input = true;
                    switch (byte) {
                        asc.CTRL_C => {
                            term.write("CTRL_C");
                            running = false;
                        },
                        asc.LINE_FEED, asc.CAR_RETURN => {
                            state = if (combuf.head == 0) .Prompting else .Parsing;
                            term.write("\r\n");
                        },
                        asc.BACKSPACE, asc.DELETE => {
                            if (combuf.head > 0) {
                                term.write_byte(asc.BACKSPACE);
                                term.push(.clear_right);
                                combuf.drop(1);
                            }
                        },
                        asc.HORIZ_TAB => {
                            // :Completions
                            //
                            var args_iter = combuf.iterator();

                            command = .{ .argc = 0, .argv = undefined };

                            while (args_iter.next()) |arg| {
                                if (command.argc < 32) {
                                    command.argv[command.argc] = arg;
                                    command.argc += 1;
                                } else {
                                    @panic("No application needs more than 32 args! Right!?!?");
                                }
                            }

                            if (command.argc < 2) {
                                // TODO: Support command completion
                                continue :run;
                            } else {
                                // Path Completion
                                term.push(.save);
                                const arg = command.argv[command.argc - 1];

                                const slash_pos = stx.index(arg, '/');

                                var search_dir = cwd.dir;
                                var prefix = arg;
                                if (slash_pos) |pos| {
                                    search_dir = cwd.dir.openDir(arg[0..pos], .{ .iterate = true }) catch unreachable;
                                    prefix = arg[pos + 1 ..];
                                }

                                var completions: usize = 0;
                                var extend_buf: [256]u8 = undefined;
                                var extend: []u8 = extend_buf[0..256];
                                var found = false;
                                var dir_iter = search_dir.iterate();

                                term.write("\r\n");
                                term.push(.clear_down);
                                // TODO: This needs to be buffered for two reasons
                                // 1) To provide proper handling when the prompt is
                                //    at the bottom of the screen. Our cursor position
                                //    needs to change and not simply be restored as there
                                //    is a scroll up by an unknown number of lines.
                                // 2) We want the results sorted.
                                while (dir_iter.next() catch null) |entry| {
                                    if (std.mem.startsWith(u8, entry.name, prefix)) {
                                        const completion = std.fs.path.basename(entry.name);
                                        if (extend.len > 0) {
                                            const ending = completion[prefix.len..];
                                            if (found) {
                                                const end = @min(extend.len, ending.len);
                                                for (0..end) |idx| {
                                                    if (extend[idx] != ending[idx]) {
                                                        extend = extend[0..idx];
                                                        break;
                                                    }
                                                }
                                            } else {
                                                found = true;
                                                stx.memcpy(extend_buf[0..], ending);
                                                extend = extend_buf[0..ending.len];
                                            }
                                        }
                                        completions += 1;
                                        term.write(completion);
                                        term.write("\t");
                                    }
                                }

                                if (completions == 1) {
                                    term.write("\r");
                                    term.push(.clear_right);
                                }

                                term.push(.restore);
                                if (completions > 0) {
                                    if (extend.len > 0) {
                                        combuf.insert(combuf.head, extend);
                                        term.write(extend);
                                    }

                                    if (completions == 1) {
                                        var path = temp.alloc(prefix.len + extend.len);
                                        stx.memcpy(path, prefix);
                                        stx.memcpy(path[prefix.len..], extend);
                                        const path_dir = cwd.dir.openDir(path, .{ .iterate = true }) catch null;
                                        if (path_dir) |_| {
                                            combuf.insert(combuf.head, "/");
                                            term.write_byte('/');
                                        } else {
                                            combuf.insert(combuf.head, " ");
                                            term.write_byte(' ');
                                        }
                                    }
                                }
                            }
                        },
                        asc.ESCAPE => {
                            const csi_esc = (input.read_byte() orelse 0) == '[';
                            if (csi_esc) {
                                const esc_byte = input.read_byte() orelse 0;

                                switch (esc_byte) {
                                    'A' => { // Key Up
                                        if (history.prev_line()) |line| {
                                            if (combufs.prev()) |cb| {
                                                combuf = cb;
                                            } else {
                                                combufs.insert(line);
                                                combuf = combufs.prev().?;
                                            }
                                        }

                                        term.head = 0;
                                        term.write("\r");
                                        term.push(.clear_line);
                                        term.write(prompt.buffer[0..prompt.head]);
                                        term.write(combuf.buffer[0..combuf.head]);
                                    },
                                    'B' => { // Key Down
                                        if (history.next_line()) |_| {
                                            combuf = combufs.next().?;
                                        }
                                        term.head = 0;
                                        term.write("\r");
                                        term.push(.clear_line);
                                        term.write(prompt.buffer[0..prompt.head]);
                                        term.write(combuf.buffer[0..combuf.head]);
                                    },
                                    'C' => { // Key right
                                    },
                                    'D' => { // Key left
                                    },
                                    else => {
                                        term.write("Unknown Escape Key");
                                    },
                                }
                            } else {
                                term.write("Bad Escape Sequence");
                                state = .Prompting;
                                continue :run;
                            }
                        },
                        ' ' => {
                            if (combuf.head > 0) {
                                term.write_byte(byte);
                                combuf.push(byte);
                            }
                        },
                        else => {
                            @branchHint(.likely);
                            // TODO: Completion Hint
                            term.write_byte(byte);
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

                var runbuf = CommandBuffer{};
                combuf.copy(&runbuf);
                var args_iter = runbuf.iterator();

                // :ExpandAlias
                //
                while (true) {
                    if (args_iter.peek()) |arg| {
                        if (aliases.find(arg)) |replacement| {
                            const replacing_self = std.mem.startsWith(u8, replacement, arg);
                            runbuf.replace(arg, replacement);
                            if (!replacing_self) continue;
                        }
                    }
                    break;
                }

                const try_cmd = args_iter.peek().?;

                if (Builtins.from_str(try_cmd)) |builtin| {
                    command = .{ .argc = 0, .argv = undefined };

                    while (args_iter.next()) |arg| if (arg.len > 0) {
                        if (command.argc < 32) {
                            command.argv[command.argc] = arg;
                            command.argc += 1;
                        } else {
                            @panic("No application needs more than 32 args! Right!?!?");
                        }
                    };
                    command.builtin = builtin;
                    state = .ExecutingBuiltin;
                    continue :run;
                }

                // :SearchPath
                //
                var slash_pos: usize = 0;
                while (slash_pos < try_cmd.len) : (slash_pos += 1) {
                    if (try_cmd[slash_pos] == '/') {
                        outerr.writeln("Found path command");
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
                                    term.write("Permission Denied\r\n");
                                    state = .Prompting;
                                    continue :run;
                                },
                            };

                            var new_argv: [psx.PATH_MAX]u8 = undefined;
                            stx.memcpy(new_argv[0..], path_str);
                            new_argv[path_str.len] = '/';
                            runbuf.insert(0, new_argv[0..(path_str.len + 1)]);
                            break :path;
                        }
                    } else {
                        term.write("Command not found\r\n");
                        state = .Prompting;
                        continue :run;
                    }
                }

                command = .{ .argc = 0, .argv = undefined };

                while (args_iter.next()) |arg| if (arg.len > 0) {
                    if (command.argc < 32) {
                        command.argv[command.argc] = arg;
                        command.argc += 1;
                    } else {
                        @panic("No application needs more than 32 args! Right!?!?");
                    }
                };

                state = .ExecutingCommand;
            },
            .ExecutingBuiltin => {
                // term.cooked();
                defer state = .Prompting;

                switch (command.builtin.?) {
                    .clear => {
                        term.push(.clear_all);
                        term.push(.{ .move_to = .{ if (dp.show) 6 else 1, 1 } });
                    },
                    .exit => running = false,
                    .pwd => {
                        term.write(cwd.path());
                        term.write("\r\n");
                    },
                    .cd => {
                        if (command.argc > 1) {
                            const reldir = command.argv[1];
                            cwd.chdir(reldir) catch |err| {
                                outerr.println("Failed to open dir: {!}", .{err});
                                continue :run;
                            };
                            prompt.reset();
                            prompt.write(fs.path.basename(cwd.path()));
                            prompt.write(" 👻 ");
                        }
                    },
                }
                history.insert(combuf.command_slice());
            },
            .ExecutingCommand => {
                term.cooked();
                defer state = .Prompting;

                // TODO: Rewrite this doing the fork/execve ourselves
                // so we dont have to deal with zig allocsators
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                const allocator = scratch.allocator();

                term.write("+ ");
                for (command.argv[0..command.argc]) |arg| {
                    term.write_byte(' ');
                    term.write(arg);
                }
                term.write("\r\n");

                var child = std.process.Child.init(command.argv[0..command.argc], allocator);
                child.stdin_behavior = .Inherit;
                child.stdout_behavior = .Inherit;
                child.stderr_behavior = .Inherit;

                child.spawn() catch unreachable;
                const child_term = child.wait() catch unreachable;

                switch (child_term) {
                    .Exited => |exit_code| {
                        if (exit_code == 0) {
                            history.insert(combuf.command_slice());
                        }
                    },
                    .Signal => {
                        term.write("Signaled\n");
                    },
                    .Stopped => {
                        term.write("Stopped\n");
                    },
                    .Unknown => {
                        term.write("Unknown\n");
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
    // [len][alias] [len][command]
    // [u8] [[N]u8] [u8] [[N]u8]
    return struct {
        buffer: [size]u8 = undefined,
        head: usize = 0,

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

const CommandBuffers = struct {
    buffers: [64]CommandBuffer = undefined,
    head: usize = 0,
    cursor: usize = 0,

    pub fn reset(self: *CommandBuffers) void {
        self.head = 1;
        self.cursor = 0;
        self.buffers[0] = CommandBuffer{};
    }

    pub fn insert(self: *CommandBuffers, bytes: []const u8) void {
        self.buffers[self.head] = CommandBuffer{};
        if (bytes.len > 0) {
            self.buffers[self.head].insert(0, bytes);
        }
        self.head += 1;
    }

    pub fn next(self: *CommandBuffers) ?*CommandBuffer {
        if (self.cursor > 0) {
            self.cursor -= 1;
            return &self.buffers[self.cursor];
        } else return null;
    }

    pub fn prev(self: *CommandBuffers) ?*CommandBuffer {
        if (self.cursor < self.head - 1) {
            self.cursor += 1;
            return &self.buffers[self.cursor];
        } else return null;
    }

    pub fn debug() void {}
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

    pub fn copy(self: *CommandBuffer, to: *CommandBuffer) void {
        stx.memcpy(to.buffer[0..], self.buffer[0..self.head]);
        to.head = self.head;
        to.version = 0;
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
        self.version += 1;
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
        self.version += 1;
    }

    pub fn iterator(self: *CommandBuffer) Iterator {
        return .{
            .prompt = self,
            .cursor = 0,
            .buffer = self.buffer[0..self.head],
            .version = self.version,
        };
    }

    pub const Iterator = struct {
        const State = enum { Unescaped, EscapedDouble, EscapedSingle };

        prompt: *CommandBuffer,
        buffer: []const u8,
        cursor: usize = 0,
        version: usize = 0,

        fn refresh(self: *Iterator) void {
            self.buffer = self.prompt.buffer[0..self.prompt.head];
            self.version = self.prompt.version;
            self.cursor = 0;
        }

        pub fn next(self: *Iterator) ?[]const u8 {
            if (self.version != self.prompt.version) {
                self.refresh();
            }

            if (self.parse(self.cursor)) |arg| {
                self.cursor = self.skip_spaces(self.cursor);
                self.cursor += arg.len;
                assert(self.cursor <= self.buffer.len);

                return dequote(arg);
            } else {
                return null;
            }
        }

        pub fn peek(self: *Iterator) ?[]const u8 {
            if (self.version != self.prompt.version) {
                self.refresh();
            }

            if (self.parse(self.cursor)) |arg| {
                return dequote(arg);
            } else {
                return null;
            }
        }

        fn parse(self: *Iterator, from: usize) ?[]const u8 {
            if (self.buffer.len == from) {
                return null;
            }
            const begin = self.skip_spaces(from);
            if (self.buffer.len == begin) {
                return self.buffer[begin..begin];
            }

            // TODO: Handle backslash escapes
            var state: Iterator.State = .Unescaped;
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

            assert(state == .Unescaped);
            assert(begin <= end);

            return self.buffer[begin..end];
        }

        fn skip_spaces(self: *Iterator, offset: usize) usize {
            var result = offset;
            while (self.buffer.len > result and self.buffer[result] == ' ') {
                result += 1;
            }
            return result;
        }

        fn dequote(arg: []const u8) []const u8 {
            if (is_quoted(arg)) {
                return arg[1 .. arg.len - 1];
            }
            return arg;
        }

        fn is_quoted(arg: []const u8) bool {
            return arg.len > 2 and (arg[0] == asc.DQUOTE or arg[0] == asc.SQUOTE) and arg[0] == arg[arg.len - 1];
        }
    };
};

pub fn U8(n: u64) u8 {
    return @intCast(n);
}

const DebugPanel = struct {
    term: *Term,
    buffers: [64][32]u8 = undefined,
    buflens: [64]u8 = undefined,
    head: usize = 0,
    show: bool = true,

    pub fn print(self: *DebugPanel, comptime fmt: []const u8, args: anytype) void {
        const res = std.fmt.bufPrint(self.buffers[self.head][0..31], fmt, args) catch unreachable;
        self.buflens[self.head] = U8(res.len);
        self.head += 1;
    }

    pub fn draw(self: *DebugPanel) void {
        defer self.head = 0;
        term.push(.save);
        defer term.push(.restore);

        const cols: u8 = 5;
        const rows: u8 = @max(5, U8((self.head + (cols - 1)) / cols));

        for (0..rows) |row| {
            term.push(.{ .move_to = .{ U8(row + 1), 1 } });
            term.push(.clear_line);
            term.write_byte(U8(row + 1 + '0'));
            term.write(": ");

            for (0..cols) |col| {
                term.push(.{ .move_col = U8(col * 32 + 4) });
                const idx = row * cols + col;
                if (idx < self.head) {
                    self.term.write(self.buffers[idx][0..self.buflens[idx]]);
                }
            }
        }
    }

    fn dbg_history(dp: *DebugPanel, history: *History) void {
        // const hist = history.ring.readable_slice();
        // var cursor: usize = 0;

        dp.print("HC: {d}/{d}", .{ history.cursor, history.ring.head.raw });
        dp.print("HB: {s}", .{history.current()});
        // var count: usize = 1;
        // while (cursor < hist.len) {
        //     const len = hist[cursor];
        //     dp.print("H{d}: {s}", .{ count, hist[cursor + 1 .. cursor + 1 + len] });
        //     cursor += len + 2;
        //     count += 1;
        // }
    }

    fn dbg_combuf(dp: *DebugPanel, combuf: *CommandBuffer) void {
        dp.print("CA:{d} {s}", .{ combuf.head, combuf.buffer[0..combuf.head] });
    }

    fn dbg_combufs(dp: *DebugPanel, combufs: *CommandBuffers) void {
        // var count: usize = 1;
        dp.print("CC:{d}/{d}", .{ combufs.cursor, combufs.head });
        dp.print("CB:{s}", .{combufs.buffers[combufs.cursor].command_slice()});
        // for (combufs.buffers[0..combufs.head]) |buf| {
        //     dp.print("C{d}: {s}", .{ count, buf.buffer[0..buf.head] });
        //     count += 1;
        // }
    }
};

// :HistoryList
pub fn HistoryList(comptime cap: usize) type {
    stx.assert_log2(cap);
    assert(cap > 16 * 1024);

    // The format of this buffer is laid out in the following way:
    // [len][str][len]
    // This makes it a kind of intrusive doubly linked list using
    // 8 bit offsets as pointers to the next fat string.
    //
    // The len is strictly the str length and does not account for the
    // 2 len bytes themselves.
    //
    // The cursor is virtual, like rings head/tail, and is pinened to
    // head on each insert.
    const RB = RingBuffer(cap, false);

    return struct {
        ring: RB = undefined,
        cursor: usize = 0,

        const Self = @This();
        const MAX_LINE = 256;

        pub fn init(self: *Self) void {
            self.ring.init("History");
        }

        pub fn insert(self: *Self, line: []const u8) void {
            assert(line.len < 255);

            const count = line.len + 2;
            const line_len: u8 = @intCast(line.len);

            assert(count <= MAX_LINE);

            var writable = self.ring.writable_slice().len;

            if (count > writable) {
                self.ring.commit(writable);
            }

            writable = self.ring.writable_slice().len;

            if (count > writable) {
                self.ring.release(self.ring.buffer[self.ring.tail.raw] + 2);
            }

            const slice = self.ring.writable_slice()[0..count];

            slice[0] = line_len;
            stx.memcpy(slice[1..], line);
            slice[line_len + 1] = line_len;
            self.ring.commit(line_len + 2);
            self.cursor = self.ring.head.raw;
        }

        pub fn current(self: *Self) []const u8 {
            if (self.cursor == self.ring.head.raw) {
                return self.ring.buffer[self.cursor..self.cursor];
            }

            const p_cursor = self.cursor & RB.MASK;
            const line_len = self.ring.buffer[p_cursor];
            return self.ring.buffer[p_cursor + 1 .. p_cursor + line_len + 1];
        }

        pub fn prev_line(self: *Self) ?[]const u8 {
            if (self.cursor == self.ring.tail.raw) {
                return null;
            }

            const p_cursor = (self.cursor - 1) & RB.MASK;
            const line_len = self.ring.buffer[p_cursor];
            const line = self.ring.buffer[p_cursor - line_len .. p_cursor];
            self.cursor -= line_len + 2;
            return line;
        }

        pub fn next_line(self: *Self) ?[]const u8 {
            if (self.cursor == self.ring.head.raw) {
                return null;
            }

            {
                const p_cursor = self.cursor & RB.MASK;
                const line_len = self.ring.buffer[p_cursor];
                self.cursor += line_len + 2;
                if (self.cursor == self.ring.head.raw) {
                    return self.ring.buffer[self.cursor..self.cursor];
                }
            }

            {
                const p_cursor = self.cursor & RB.MASK;
                const line_len = self.ring.buffer[p_cursor];
                const line = self.ring.buffer[p_cursor + 1 .. p_cursor + line_len + 1];
                return line;
            }
        }
    };
}

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
            outerr.println("stdin: {any}", .{err});
        }

        return null;
    }
};

const Output = struct {
    head: u8 = 0,
    len: usize = 0,

    pub fn write_byte(self: *Output, byte: u8) void {
        _ = self;
        const count = psx.write(psx.STDOUT_FILENO, &[_]u8{byte}) catch unreachable;
        assert(count == 1);
    }

    pub fn write(self: *Output, bytes: []const u8) void {
        _ = self;
        const count = psx.write(psx.STDOUT_FILENO, bytes) catch unreachable;
        assert(count == bytes.len);
    }

    pub fn print(self: *Output, comptime fmt: []const u8, args: anytype) void {
        var buffer: [1024]u8 = undefined;
        const res = std.fmt.bufPrint(buffer[0..1024], fmt, args) catch unreachable;
        self.write(res);
    }

    pub fn writeln(self: *Output, buffer: []const u8) void {
        self.write(buffer);
        self.write("\r\n");
    }

    pub fn println(self: *Output, comptime fmt: []const u8, args: anytype) void {
        self.print(fmt ++ "\r\n", args);
    }
};

const Prompt = struct {
    buffer: [32]u8 = undefined,
    head: usize = 0,

    fn reset(self: *Prompt) void {
        self.head = 0;
    }

    fn write(self: *Prompt, bytes: []const u8) void {
        stx.memcpy(self.buffer[self.head..], bytes);
        self.head += bytes.len;
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
        pub const MASK = size - 1;

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

const Term = struct {
    welldone: psx.termios = undefined,
    rare: psx.termios = undefined,

    output: *Output = undefined,
    buffer: [1 * MB]u8 = undefined,
    head: usize = 0,

    pub fn init(self: *Term) void {
        self.welldone = psx.tcgetattr(std.posix.STDIN_FILENO) catch unreachable;
        self.rare = self.welldone;

        self.rare.iflag.BRKINT = false;
        self.rare.iflag.ICRNL = false;
        self.rare.iflag.INPCK = false;
        self.rare.iflag.ISTRIP = false;
        self.rare.iflag.IXON = false;

        self.rare.lflag.ICANON = false;
        self.rare.lflag.ECHO = false;
        self.rare.lflag.ISIG = false;
        self.rare.lflag.IEXTEN = false;

        self.rare.oflag.OPOST = false;

        self.rare.cflag.CSIZE = psx.CSIZE.CS8;
        self.rare.cc[@intFromEnum(std.c.V.MIN)] = 1;
        self.rare.cc[@intFromEnum(std.c.V.TIME)] = 0;
    }

    pub fn cooked(self: *Term) void {
        psx.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.welldone) catch unreachable;
    }

    pub fn sashimi(self: *Term) void {
        psx.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.rare) catch unreachable;
    }

    pub fn write(self: *Term, bytes: []const u8) void {
        stx.memcpy(self.buffer[self.head..], bytes);
        self.head += bytes.len;
    }

    pub fn write_fmt(self: *Term, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const res = std.fmt.bufPrint(buf[0..1024], fmt, args) catch unreachable;
        self.write(res);
    }

    pub fn write_byte(self: *Term, byte: u8) void {
        self.buffer[self.head] = byte;
        self.head += 1;
    }

    pub fn push(self: *Term, code: AnsiCode) void {
        switch (code) {
            // zig fmt: off
            .home            => self.csi("H"),
            .save            => self.csi("s"),
            .restore         => self.csi("u"),
            .clear_down      => self.csi("0J"),
            .clear_up        => self.csi("1J"),
            .clear_all       => self.csi("2J"),
            .clear_right     => self.csi("0K"),
            .clear_left      => self.csi("1K"),
            .clear_line      => self.csi("2K"),
            .move_up         => |n| self.csi_fmt("{d}A", .{n}),
            .move_down       => |n| self.csi_fmt("{d}B", .{n}),
            .move_right      => |n| self.csi_fmt("{d}C", .{n}),
            .move_left       => |n| self.csi_fmt("{d}D", .{n}),
            .move_down_line  => |n| self.csi_fmt("{d}E", .{n}),
            .move_up_line    => |n| self.csi_fmt("{d}F", .{n}),
            .move_col        => |n| self.csi_fmt("{d}G", .{n}),
            .move_to         => |n| self.csi_fmt("{d};{d}H", .{n[0], n[1]}),
            .scroll_up       => |n| self.csi_fmt("{d}S", .{n}),
            .scroll_down     => |n| self.csi_fmt("{d}T", .{n}),
            // else => {},
            // zig fmt: on
        }
    }

    fn csi(self: *Term, bytes: []const u8) void {
        self.buffer[self.head..][0..2].* = .{ asc.ESCAPE, '[' };
        self.head += 2;
        self.write(bytes);
    }

    fn csi_fmt(self: *Term, comptime fmt: []const u8, args: anytype) void {
        var buf: [64]u8 = undefined;
        const res = std.fmt.bufPrint(buf[0..64], fmt, args) catch unreachable;
        self.csi(res);
    }

    test "term push" {
        var test_term = Term{};
        test_term.push(.home);
        try t.expectEqual(3, test_term.head);
        try t.expectEqualStrings("\x1b[H", test_term.buffer[0..3]);
        test_term.push(.clear_all);
        try t.expectEqual(7, test_term.head);
        try t.expectEqualStrings("\x1b[2J", test_term.buffer[3..7]);
        test_term.push(.{ .move_to = .{ 5, 1 } });
        try t.expectEqual(13, test_term.head);
        try t.expectEqualStrings("\x1b[5;1H", test_term.buffer[7..13]);
        test_term.push(.{ .move_to = .{ 212, 109 } });
        try t.expectEqual(23, test_term.head);
        try t.expectEqualStrings("\x1b[212;109H", test_term.buffer[13..23]);
    }
};

const AnsiCode = union(enum) {
    move_up: u8,
    move_down: u8,
    move_right: u8,
    move_left: u8,
    move_up_line: u8,
    move_down_line: u8,
    move_col: u8,
    move_to: struct { u8, u8 },
    scroll_up: u8,
    scroll_down: u8,
    home,
    save,
    restore,
    clear_up,
    clear_down,
    clear_all,
    clear_right,
    clear_left,
    clear_line,
};

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
//
test {
    t.refAllDecls(@This());
}
