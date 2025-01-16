const std = @import("std");
const psx = std.posix;

var welldone: psx.termios = undefined;
var raw: psx.termios = undefined;

pub fn cook_it() void {
    psx.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, welldone) catch unreachable;
}

pub fn go_raw() void {
    psx.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch unreachable;
}
