const std = @import("std");
const main = @import("main.zig");
const psx = std.posix;

pub const global = @This();

pub var term: Term = .{};
pub var temp: *main.TempMem = undefined;

const Term = struct {
    welldone: psx.termios = undefined,
    rare: psx.termios = undefined,

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
};
