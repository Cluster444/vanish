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

pub const InputTests = struct {
    pub fn run(shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) !void {
        set_mask(shell, read_buf, mask_buf);
        dbg.print("Test: Write Char\n", .{});
        try exec(test_write_char, shell, read_buf, mask_buf);

        // set_mask(shell, read_buf, mask_buf);
        dbg.print("Test: Backspace\n", .{});
        try exec(test_backspace, shell, read_buf, mask_buf);
    }

    fn exec(test_fn: TestFn, shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) TestError!void {
        try test_fn(shell, read_buf, mask_buf);
    }

    fn test_write_char(shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) TestError!void {
        const input = "abcdef";
        var cursor: usize = 0;
        shell.write(input);

        while (cursor < input.len) {
            shell.read(read_buf);
            try expect_int(mask_buf.head + cursor + 1, read_buf.head);
            cursor += 1;
            try expect_fmt(read_buf, "{s}{s}", .{ mask_buf.all(), input[0..cursor] });
        }
    }

    fn test_backspace(shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) TestError!void {
        const input = "\x08\x08\x08\x08\x08\x08";
        const backspace = "\x08\x1b[0K";
        const bytes = "abcdef";
        var cursor: usize = 6;
        shell.write(input);

        while (cursor > 0) {
            shell.read(read_buf);
            try expect_int(mask_buf.head + cursor + backspace.len, read_buf.head);
            try expect_fmt(read_buf, "{s}{s}{s}", .{ mask_buf.all(), bytes[0..cursor], backspace });
            cursor -= 1;
        }
    }
};
