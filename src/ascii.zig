// zig fmt: off
// ASCII Codes
//
pub const NULL       = 0x00;
pub const START_HEAD = 0x01;
pub const START_TEXT = 0x02;
pub const END_TEXT   = 0x03;
pub const END_TRANSM = 0x04;
pub const ENQUIRY    = 0x05;
pub const ACK        = 0x06;
pub const BELL       = 0x07;
pub const BACKSPACE  = 0x08;
pub const HORIZ_TAB  = 0x09;
pub const LINE_FEED  = 0x0A;
pub const VERT_TAB   = 0x0B;
pub const FORM_FEED  = 0x0C;
pub const CAR_RETURN = 0x0D;
pub const SHIFT_OUT  = 0x0E;
pub const SHIFT_IN   = 0x0F;
pub const ESCAPE     = 0x1B;
pub const SPACE      = 0x20;
pub const DQUOTE     = 0x22;
pub const SQUOTE     = 0x27;
pub const DELETE     = 0x7F;

pub const CTRL_C     = END_TEXT;
// zig fmt: on
