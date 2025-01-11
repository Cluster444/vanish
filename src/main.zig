const std = @import("std");
const types = @import("types.zig");
const posix = std.posix;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const IOPipe = types.IOPipe;
const Config = types.Config;
const State = types.State;
const SetupFn = types.SetupFn;
const RunFn = types.RunFn;

const AtomBool = std.atomic.Value(bool);
var running = AtomBool.init(true);

const PLATFORM_OFFSET = 0x1_0000_0000;
const PLATFORM_ALLOC = 16 * 1024;
const APP_OFFSET = 0x2_0000_0000;

pub fn main() !void {
    var libvanish = std.DynLib.open("libvanish.dylib") catch @panic("shitlib");
    const setup: *const SetupFn = libvanish.lookup(*const SetupFn, "setup") orelse @panic("shitfunc");
    const run: *const RunFn = libvanish.lookup(*const RunFn, "run") orelse @panic("shitfunc");

    var config: Config = .{
        .mem_size = 0,
    };

    setup(&config);

    const memory = alloc(std.heap.page_allocator, PLATFORM_OFFSET, PLATFORM_ALLOC);
    defer std.heap.page_allocator.free(memory);
    var fba = std.heap.FixedBufferAllocator.init(memory);
    const allocator = fba.allocator();

    const app_mem = alloc(std.heap.page_allocator, APP_OFFSET, config.mem_size);
    defer std.heap.page_allocator.free(app_mem);
    const input = allocator.create(IOPipe) catch @panic("shitalloc");
    const output = allocator.create(IOPipe) catch @panic("shitalloc");

    var termios = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch unreachable;
    const original_termios = termios;
    defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original_termios) catch unreachable;

    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;

    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, termios) catch unreachable;

    var app: State = .{
        .mem_ptr = app_mem.ptr,
        .mem_len = app_mem.len,
        .input = input,
        .output = output,
    };

    _ = std.Thread.spawn(.{}, read_stdin, .{ app.input, &running }) catch @panic("shitthread");
    const output_handler = std.Thread.spawn(.{}, write_stdout, .{ app.output, &running }) catch @panic("shitthread");

    run(&app);

    running.store(false, .release);

    // TODO: We don't alloc in these, so letting the OS
    // reclaim them on exit is fine. If that changes then
    // we may need to cleanup our mess, the biggest culprit
    // is the stdin.read block, not obvious how to get O_NONBLOCK
    // to work in Zig yet.
    // input_handler.join();
    output_handler.join();
}

fn write_stdout(output_buffer: *IOPipe, keep_going: *AtomBool) void {
    const stdout = std.io.getStdOut();
    while (keep_going.load(.acquire)) {
        const output = output_buffer.read_slice();
        const count = stdout.write(output) catch @panic("shitwrite");
        output_buffer.release(count);
    }
}

const psx = std.posix;

fn read_stdin(input_buffer: *IOPipe, keep_going: *AtomBool) void {
    const stdin = std.io.getStdIn();
    while (keep_going.load(.acquire)) {
        const input = input_buffer.write_slice();
        const count = stdin.read(input) catch @panic("shitread");
        input_buffer.commit(count);
    }
}

fn alloc(allocator: Allocator, comptime offset: u64, size: u64) []u8 {
    // Pulled from stdlib so we can set the VM offsets
    const hint = @atomicLoad(@TypeOf(std.heap.next_mmap_addr_hint), &std.heap.next_mmap_addr_hint, .unordered);
    const new_hint: [*]align(std.mem.page_size) u8 = @ptrFromInt(offset);
    _ = @cmpxchgStrong(@TypeOf(std.heap.next_mmap_addr_hint), &std.heap.next_mmap_addr_hint, hint, new_hint, .monotonic, .monotonic);

    return allocator.alloc(u8, size) catch @panic("shitbits");
}
