const std = @import("std");
const typ = @import("types.zig");
const stx = @import("stx.zig");
const mem = @import("memory.zig");
const psx = std.posix;

const assert = std.debug.assert;

const ByteAllocator = mem.ByteAllocator;
const Blocks = typ.Blocks;
const CommandBuffer = typ.CommandBuffer;
const Config = typ.Config;
const IOPipe = typ.IOPipe;
const State = typ.State;

const CfgFn = typ.SetupFn;
const RunFn = typ.RunFn;

pub const MEMORY_OFFSET = 1 << 33;

pub fn main() !void {
    var libvanish = std.DynLib.open("libvanish.dylib") catch @panic("shitlib");
    // const cfg: *const CfgFn = libvanish.lookup(*const CfgFn, "cfg") orelse @panic("shitfn");
    const run: *const RunFn = libvanish.lookup(*const RunFn, "run") orelse @panic("shitfn");

    // Terminal Setup
    //
    var termees = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch unreachable;
    const orig_termees = termees;
    defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, orig_termees) catch unreachable;
    termees.lflag.ECHO = false;
    termees.lflag.ICANON = false;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, termees) catch unreachable;

    // Allocate Memory
    //
    var memblk = Blocks{ .offset = MEMORY_OFFSET };
    memblk.reserve(.static, ByteAllocator, 1);
    memblk.reserve(.buffers, IOPipe, 2);
    memblk.reserve(.buffers, CommandBuffer, 1);
    memblk.reserve(.arena, u8, 16 * 1024);
    memblk.commit();
    defer memblk.release();

    var static_blk = memblk.block(.static);
    const app_arena = static_blk.create(ByteAllocator);
    app_arena.* = memblk.arena(.arena);

    var buffer_blk = memblk.block(.buffers);
    const input = buffer_blk.create(IOPipe);
    const output = buffer_blk.create(IOPipe);
    const cmdbuf = buffer_blk.create(CommandBuffer);
    input.init("stdin");
    output.init("stdout");
    cmdbuf.init();

    // App Config
    //:write_stdout
    // var config: Config = .{};
    // cfg(&config);

    var app: State = .{
        .running = true,
        .input = input,
        .output = output,
        .combuf = cmdbuf,
        .arena = app_arena,
    };

    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();
    var fds: [1]psx.pollfd = [_]psx.pollfd{.{ .fd = psx.STDIN_FILENO, .events = psx.POLL.IN, .revents = 0 }};

    while (app.running) {
        defer app.arena.reset();

        if (psx.poll(fds[0..], 0)) |n| {
            if (n > 0) {
                const slice = app.input.writable_slice();
                const count = stdin.read(slice) catch @panic("shitread");
                app.input.commit(count);
            }
        } else |err| {
            std.debug.print("stdin: {any}\n", .{err});
        }

        run(&app);

        while (app.output.readable_len() > 0) {
            const slice = app.output.readable_slice();
            const count = stdout.write(slice) catch @panic("shitwrite");
            app.output.release(count);
        }
    }
}
