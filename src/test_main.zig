const std = @import("std");
const dbg = std.debug;
const stx = @import("stx.zig");
const tst = @import("testing.zig");

const tests = @import("tests.zig");

const psx = std.posix;

const assert = std.debug.assert;

const t = std.testing;

const Shell = tst.Shell;
const Buffer = tst.Buffer;
const set_mask = tst.set_mask;

const VANISH = "./zig-out/bin/vanish";
const GHOST = " 👻 ";

pub fn main() !void {
    var shell = Shell{ .cmd = VANISH };
    shell.init();
    defer shell.deinit();
    shell.fork();

    var read_buf: Buffer = .{};
    var mask_buf: Buffer = .{};

    set_mask(&shell, &read_buf, &mask_buf);
    assert(mask_buf.head > 0);
    assert(std.mem.eql(u8, GHOST, mask_buf.last(6)));

    try tests.Input.run(&shell, &read_buf, &mask_buf);
    try tests.Builtin.run(&shell, &read_buf, &mask_buf);
    try tests.History.run(&shell, &read_buf, &mask_buf);

    dbg.print("SUCCESS!!!!\n", .{});
}
