const std = @import("std");
const dbg = std.debug;
const tst = @import("../testing.zig");
const Shell = tst.Shell;
const Buffer = tst.Buffer;
const set_mask = tst.set_mask;
const expect_fmt = tst.expect_fmt;
const TestFn = tst.TestFn;
const TestError = tst.TestError;

pub const HistoryTests = struct {
    pub fn run(shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) !void {
        set_mask(shell, read_buf, mask_buf);
        dbg.print("Test: history up/down\n", .{});
        try exec(test_traversal, shell, read_buf, mask_buf);
    }

    fn exec(test_fn: TestFn, shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) TestError!void {
        try test_fn(shell, read_buf, mask_buf);
    }

    fn test_traversal(shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) TestError!void {
        const up = "\x1b[A";
        const down = "\x1b[B";

        shell.write(up);
        shell.read(read_buf);
        shell.read(read_buf);
        try expect_fmt(read_buf, "{s}{s}", .{ mask_buf.all(), "cd ../.." });

        shell.write(up);
        shell.read(read_buf);
        shell.read(read_buf);
        try expect_fmt(read_buf, "{s}{s}", .{ mask_buf.all(), "pwd" });

        shell.write(up);
        shell.read(read_buf);
        shell.read(read_buf);
        try expect_fmt(read_buf, "{s}{s}", .{ mask_buf.all(), "cd tmp/test" });

        shell.write(up);
        shell.read(read_buf);
        shell.read(read_buf);
        try expect_fmt(read_buf, "{s}{s}", .{ mask_buf.all(), "cd tmp/test" });

        shell.write(down);
        shell.read(read_buf);
        shell.read(read_buf);
        try expect_fmt(read_buf, "{s}{s}", .{ mask_buf.all(), "pwd" });

        shell.write(down);
        shell.read(read_buf);
        shell.read(read_buf);
        try expect_fmt(read_buf, "{s}{s}", .{ mask_buf.all(), "cd ../.." });

        shell.write(down);
        shell.read(read_buf);
        shell.read(read_buf);
        try expect_fmt(read_buf, "{s}", .{mask_buf.all()});
    }
};
