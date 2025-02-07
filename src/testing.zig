const std = @import("std");
const stx = @import("stx.zig");
const psx = std.posix;
const nix = std.os.linux;
const dbg = std.debug;

const t = std.testing;

pub const TestError = error{Failed};
pub const TestFn = fn (*Shell, *Buffer, *Buffer) TestError!void;

pub fn expect_fmt(buf: *Buffer, comptime fmt: []const u8, args: anytype) TestError!void {
    var tmp_buf: [1024]u8 = undefined;

    const expected = std.fmt.bufPrint(tmp_buf[0..1024], fmt, args) catch unreachable;
    const actual = buf.all();
    try expect_str(expected, actual);
}

pub fn expect_int(expected: u64, actual: u64) TestError!void {
    t.expectEqual(expected, actual) catch {
        dbg.print("expected {d}\nactual   {d}\n", .{ expected, actual });
        return error.Failed;
    };
}

pub fn expect_str(expected: []const u8, actual: []const u8) TestError!void {
    t.expectEqualStrings(expected, actual) catch {
        dbg.print("expected {x}\nactual   {x}\n", .{ expected, actual });
        dbg.print("expected {c}\nactual   {c}\n", .{ expected, actual });
        return error.Failed;
    };
}

pub fn set_mask(shell: *Shell, read_buf: *Buffer, mask_buf: *Buffer) void {
    while (true) {
        mask_buf.reset();
        shell.read(read_buf);
        if (read_buf.head > 0) {
            if (std.mem.eql(u8, "\r\x1b[2K", read_buf.first(5))) {
                mask_buf.write(read_buf.all());
                shell.read(read_buf);
                if (!std.mem.eql(u8, read_buf.all(), mask_buf.all())) continue;
                break;
            }
        }
    }
}

pub const Buffer = struct {
    const SIZE: usize = 1024 * 1024;

    buffer: [SIZE]u8 = undefined,
    head: usize = 0,

    pub fn reset(self: *Buffer) void {
        self.head = 0;
    }

    pub fn writable(self: *Buffer) []u8 {
        return self.buffer[self.head..];
    }

    pub fn write(self: *Buffer, bytes: []const u8) void {
        stx.memcpy(self.buffer[self.head..], bytes);
        self.head += bytes.len;
    }

    pub fn all(self: *Buffer) []const u8 {
        return self.buffer[0..self.head];
    }

    pub fn unused(self: *Buffer) []u8 {
        return self.buffer[self.head..];
    }

    pub fn first(self: *Buffer, count: usize) []const u8 {
        return self.all()[0..count];
    }

    pub fn last(self: *Buffer, count: usize) []const u8 {
        return self.all()[self.head - count ..];
    }
};

pub const Shell = struct {
    cmd: [*:0]const u8,
    master: psx.fd_t = undefined,
    slave: psx.fd_t = undefined,
    pty_name: []const u8 = undefined,
    child_pid: psx.pid_t = undefined,

    pub fn init(self: *Shell) void {
        openpty(&self.master, &self.slave);
    }

    pub fn deinit(self: *Shell) void {
        psx.close(self.master);
        psx.kill(self.child_pid, 15) catch unreachable;
        std.Thread.sleep(std.time.ns_per_ms * 100);
        const result = psx.waitpid(self.child_pid, psx.W.NOHANG);
        dbg.print("Child exited: {d}\n", .{result.status});
    }

    pub fn fork(self: *Shell) void {
        const pid = psx.fork() catch unreachable;
        if (pid == 0) {
            psx.close(self.master);
            psx.dup2(self.slave, psx.STDIN_FILENO) catch unreachable;
            psx.dup2(self.slave, psx.STDOUT_FILENO) catch unreachable;
            psx.dup2(self.slave, psx.STDERR_FILENO) catch unreachable;
            psx.close(self.slave);

            psx.execveZ(self.cmd, &.{null}, &.{null}) catch unreachable;
            dbg.print("EXEC failed?", .{});
        }
        self.child_pid = pid;
        psx.close(self.slave);
        dbg.print("Forked {d}\n", .{pid});
    }

    pub fn read(self: *Shell, buf: *Buffer) void {
        buf.head = psx.read(self.master, &buf.buffer) catch unreachable;
    }

    pub fn sync(self: *Shell) void {
        var buf: Buffer = .{};
        self.read(&buf);
    }

    pub fn write(self: *Shell, bytes: []const u8) void {
        _ = psx.write(self.master, bytes) catch unreachable;
    }
};

fn openpty(master: *psx.fd_t, slave: *psx.fd_t) void {
    const ptm = psx.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch unreachable;
    _ = ioctl(ptm, nix.T.IOCSPTLCK, 0) catch unreachable;
    const pts_num = ioctl(ptm, nix.T.IOCGPTN, 0) catch unreachable;

    var buf: [64]u8 = undefined;
    const result = std.fmt.bufPrintZ(&buf, "/dev/pts/{d}", .{pts_num}) catch unreachable;
    const pts = psx.open(result, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch unreachable;

    master.* = ptm;
    slave.* = pts;

    // if (term) tcseattr(slave, TCSANOW, term);
    // if (win) ioctl(s, TIOCSWINSZ, win);
}

fn ioctl(fd: psx.fd_t, request: u32, arg: usize) !usize {
    var arg_loc = arg;
    const rc = nix.ioctl(fd, request, @intFromPtr(&arg_loc));
    switch (psx.errno(rc)) {
        .SUCCESS => return arg_loc,
        else => unreachable,
    }
}
