const std = @import("std");
const dbg = std.debug;

const tst = @import("../testing.zig");
const Shell = tst.Shell;
const Buffer = tst.Buffer;
const set_mask = tst.set_mask;
const expect_fmt = tst.expect_fmt;
const expect_str = tst.expect_str;
const expect_int = tst.expect_int;
const TestFn = tst.TestFn;
const TestError = tst.TestError;

const GHOST = " 👻 ";

pub const BuiltinTests = struct {
    pub fn run(shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) !void {
        set_mask(shell, read_buf, mask_buf);
        dbg.print("Test: Builtin cd\n", .{});
        try exec(test_cd_up, shell, read_buf, mask_buf);

        set_mask(shell, read_buf, mask_buf);
        dbg.print("Test: Builtin pwd\n", .{});
        try exec(test_pwd, shell, read_buf, mask_buf);

        set_mask(shell, read_buf, mask_buf);
        dbg.print("Test: Builtin cd (back)\n", .{});
        try exec(test_cd_down, shell, read_buf, mask_buf);
    }

    fn exec(test_fn: TestFn, shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) TestError!void {
        try test_fn(shell, read_buf, mask_buf);
    }

    fn test_cd_up(shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) TestError!void {
        const input = "cd tmp/test";
        var cursor: usize = 0;
        shell.write(input);

        while (cursor < input.len) {
            shell.read(read_buf);
            try expect_int(mask_buf.head + cursor + 1, read_buf.head);
            cursor += 1;
            try expect_fmt(read_buf, "{s}{s}", .{ mask_buf.all(), input[0..cursor] });
        }
        shell.write("\n");
        shell.read(read_buf);
        try expect_str("\r\n", read_buf.last(2));
        shell.read(read_buf);
        try expect_str("\r\x1b[2Ktest" ++ GHOST, read_buf.all());
    }

    fn test_pwd(shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) TestError!void {
        const input = "pwd";
        var cursor: usize = 0;
        shell.write(input);

        while (cursor < input.len) {
            shell.read(read_buf);
            try expect_int(mask_buf.head + cursor + 1, read_buf.head);
            cursor += 1;
            try expect_fmt(read_buf, "{s}{s}", .{ mask_buf.all(), input[0..cursor] });
        }
        shell.write("\n");
        shell.read(read_buf);
        try expect_str("\r\n", read_buf.last(2));

        shell.read(read_buf);
        try expect_str("/home/cluster444/code/zig/vanish/tmp/test\r\n", read_buf.all());
        shell.read(read_buf);
        try expect_str(mask_buf.all(), read_buf.all());
    }

    fn test_cd_down(shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) TestError!void {
        const input = "cd ../..";
        var cursor: usize = 0;
        shell.write(input);

        while (cursor < input.len) {
            shell.read(read_buf);
            try expect_int(mask_buf.head + cursor + 1, read_buf.head);
            cursor += 1;
            try expect_fmt(read_buf, "{s}{s}", .{ mask_buf.all(), input[0..cursor] });
        }

        shell.write("\n");
        shell.read(read_buf);
        try expect_str("\r\n", read_buf.last(2));
        shell.read(read_buf);
        try expect_str("\r\x1b[2Kvanish" ++ GHOST, read_buf.all());
    }
};
