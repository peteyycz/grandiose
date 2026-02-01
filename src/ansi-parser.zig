const std = @import("std");

const csiParamParser = @import("csi-parameter-parser.zig");

pub const MoveCursorRelativeDirection = enum { up, down, left, right };
pub const EraseMode = enum { to_end, to_start, all };
pub const Color = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,
};
pub const Rgb = struct { r: u8, g: u8, b: u8 };
pub const SgrAttribute = struct {
    reset: bool = false,
    bold: ?bool = null,
    underline: ?bool = null,
    fg_color: ?u8 = null,
    bg_color: ?u8 = null,
    fg_rgb: ?Rgb = null,
    bg_rgb: ?Rgb = null,
};

pub const Action = union(enum) {
    none,
    print: u21,
    carriage_return,
    line_feed,
    backspace,
    tab,
    bell,

    // Controls
    move_cursor: struct { x: u16, y: u16 },
    move_cursor_relative: struct { dir: MoveCursorRelativeDirection, n: u16 },
    erase_display: EraseMode,
    erase_line: EraseMode,
    sgr: SgrAttribute,
    cursor_visible: bool,
};

const State = enum { ground, escape, csi_state, utf8 };

fn parseSgr(params: csiParamParser.ParseResult) SgrAttribute {
    var attr = SgrAttribute{};

    // ESC[m with no params means reset
    if (params.len == 0) {
        attr.reset = true;
        return attr;
    }

    var i: u8 = 0;
    while (i < params.len) : (i += 1) {
        const p = params.params[i];
        switch (p) {
            0 => attr.reset = true,
            1 => attr.bold = true,
            4 => attr.underline = true,
            22 => attr.bold = false,
            24 => attr.underline = false,
            30...37 => attr.fg_color = @intCast(p - 30),
            40...47 => attr.bg_color = @intCast(p - 40),
            90...97 => attr.fg_color = @intCast(p - 90 + 8),
            100...107 => attr.bg_color = @intCast(p - 100 + 8),
            38 => {
                if (i + 2 < params.len and params.params[i + 1] == 5) {
                    // 256-color foreground: 38;5;N
                    attr.fg_color = @intCast(params.params[i + 2]);
                    i += 2;
                } else if (i + 4 < params.len and params.params[i + 1] == 2) {
                    // True color foreground: 38;2;R;G;B
                    attr.fg_rgb = .{
                        .r = @intCast(params.params[i + 2]),
                        .g = @intCast(params.params[i + 3]),
                        .b = @intCast(params.params[i + 4]),
                    };
                    i += 4;
                }
            },
            48 => {
                if (i + 2 < params.len and params.params[i + 1] == 5) {
                    // 256-color background: 48;5;N
                    attr.bg_color = @intCast(params.params[i + 2]);
                    i += 2;
                } else if (i + 4 < params.len and params.params[i + 1] == 2) {
                    // True color background: 48;2;R;G;B
                    attr.bg_rgb = .{
                        .r = @intCast(params.params[i + 2]),
                        .g = @intCast(params.params[i + 3]),
                        .b = @intCast(params.params[i + 4]),
                    };
                    i += 4;
                }
            },
            else => {},
        }
    }

    return attr;
}

pub const Parser = struct {
    state: State = .ground,

    csi_parameters: [32]u8 = undefined,
    csi_parameters_len: u8 = 0,

    // UTF-8 multi-byte handling
    utf8_buf: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_expected: u8 = 0,

    pub fn feed(self: *Parser, byte: u8) Action {
        // Handle UTF-8 continuation bytes
        if (self.state == .utf8) {
            if (byte >= 0x80 and byte <= 0xBF) {
                self.utf8_buf[self.utf8_len] = byte;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_expected) {
                    self.state = .ground;
                    const codepoint = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_len]) catch return .none;
                    return .{ .print = codepoint };
                }
                return .none;
            } else {
                // Invalid continuation, reset and process this byte normally
                self.state = .ground;
                self.utf8_len = 0;
            }
        }

        return switch (byte) {
            '\r' => .carriage_return,
            '\n' => .line_feed,
            0x08 => .backspace,
            '\t' => .tab,
            0x07 => .bell,
            0x20...0x7E => switch (self.state) {
                .ground => .{ .print = byte },
                .escape => {
                    if (byte == '[') {
                        self.state = .csi_state;
                    }
                    return .none;
                },
                .csi_state => switch (byte) {
                    0x40...0x7E => self.dispatchCsi(byte),
                    else => {
                        self.csi_parameters[self.csi_parameters_len] = byte;
                        self.csi_parameters_len += 1;
                        return .none;
                    },
                },
                .utf8 => .none, // Already handled above
            },
            0x1B => {
                self.state = .escape;
                return .none;
            },
            // UTF-8 multi-byte sequence starts
            0xC0...0xDF => {
                // 2-byte sequence
                self.state = .utf8;
                self.utf8_buf[0] = byte;
                self.utf8_len = 1;
                self.utf8_expected = 2;
                return .none;
            },
            0xE0...0xEF => {
                // 3-byte sequence
                self.state = .utf8;
                self.utf8_buf[0] = byte;
                self.utf8_len = 1;
                self.utf8_expected = 3;
                return .none;
            },
            0xF0...0xF7 => {
                // 4-byte sequence
                self.state = .utf8;
                self.utf8_buf[0] = byte;
                self.utf8_len = 1;
                self.utf8_expected = 4;
                return .none;
            },
            else => .none,
        };
    }

    pub fn feedSlice(self: *Parser, bytes: []const u8) Action {
        var result: Action = .none;
        for (bytes) |b| result = self.feed(b);
        return result;
    }

    fn dispatchCsi(self: *Parser, byte: u8) Action {
        self.state = .ground;
        defer self.csi_parameters_len = 0;

        const raw_params = self.csi_parameters[0..self.csi_parameters_len];

        // Check for private mode sequences (starting with ?)
        if (raw_params.len > 0 and raw_params[0] == '?') {
            const params = csiParamParser.parse(raw_params[1..]);
            return self.dispatchPrivateCsi(byte, params);
        }

        const params = csiParamParser.parse(raw_params);

        return switch (byte) {
            'H' => .{ .move_cursor = .{
                .x = if (params.len >= 1) params.params[0] else 0,
                .y = if (params.len >= 2) params.params[1] else 0,
            } },
            'A', 'B', 'C', 'D' => .{ .move_cursor_relative = .{
                .dir = switch (byte) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    else => unreachable,
                },
                .n = if (params.len >= 1) params.params[0] else 1,
            } },
            'J', 'K' => blk: {
                const mode: EraseMode = switch (if (params.len >= 1) params.params[0] else 0) {
                    0 => .to_end,
                    1 => .to_start,
                    2 => .all,
                    else => .to_end,
                };
                break :blk if (byte == 'J') .{ .erase_display = mode } else .{ .erase_line = mode };
            },
            'm' => .{ .sgr = parseSgr(params) },
            else => .none,
        };
    }

    fn dispatchPrivateCsi(_: *Parser, byte: u8, params: csiParamParser.ParseResult) Action {
        if (params.len >= 1 and params.params[0] == 25) {
            // ?25h = show cursor, ?25l = hide cursor
            return switch (byte) {
                'h' => .{ .cursor_visible = true },
                'l' => .{ .cursor_visible = false },
                else => .none,
            };
        }
        return .none;
    }
};

test "printable character emits print action" {
    var parser = Parser{};
    try std.testing.expectEqual(parser.feed('e'), Action{ .print = 'e' });
    try std.testing.expectEqual(parser.feed('c'), Action{ .print = 'c' });
    try std.testing.expectEqual(parser.feed('h'), Action{ .print = 'h' });
    try std.testing.expectEqual(parser.feed('o'), Action{ .print = 'o' });
}

test "single byte special characters" {
    var parser = Parser{};
    try std.testing.expectEqual(parser.feed('\r'), Action.carriage_return);
    try std.testing.expectEqual(parser.feed('\n'), Action.line_feed);
    try std.testing.expectEqual(parser.feed(0x08), Action.backspace);
    try std.testing.expectEqual(parser.feed('\t'), Action.tab);
    try std.testing.expectEqual(parser.feed(0x07), Action.bell);
}

test "ESC[H escape sequence" {
    var parser = Parser{};
    try std.testing.expectEqual(Action{ .move_cursor = .{ .x = 0, .y = 0 } }, parser.feedSlice("\x1b[H"));
    try std.testing.expectEqual(Action{ .move_cursor = .{ .x = 10, .y = 93 } }, parser.feedSlice("\x1b[10;93H"));
}

test "ESC[1A/B/C/D escape sequence" {
    var parser = Parser{};
    try std.testing.expectEqual(Action{ .move_cursor_relative = .{ .dir = .up, .n = 1 } }, parser.feedSlice("\x1b[1A"));
    try std.testing.expectEqual(Action{ .move_cursor_relative = .{ .dir = .down, .n = 5 } }, parser.feedSlice("\x1b[5B"));
    try std.testing.expectEqual(Action{ .move_cursor_relative = .{ .dir = .right, .n = 3 } }, parser.feedSlice("\x1b[3C"));
    try std.testing.expectEqual(Action{ .move_cursor_relative = .{ .dir = .left, .n = 2 } }, parser.feedSlice("\x1b[2D"));
}

test "ESC[J erase display" {
    var parser = Parser{};
    try std.testing.expectEqual(Action{ .erase_display = .to_end }, parser.feedSlice("\x1b[J"));
    try std.testing.expectEqual(Action{ .erase_display = .to_end }, parser.feedSlice("\x1b[0J"));
    try std.testing.expectEqual(Action{ .erase_display = .to_start }, parser.feedSlice("\x1b[1J"));
    try std.testing.expectEqual(Action{ .erase_display = .all }, parser.feedSlice("\x1b[2J"));
}

test "ESC[K erase line" {
    var parser = Parser{};
    try std.testing.expectEqual(Action{ .erase_line = .to_end }, parser.feedSlice("\x1b[K"));
    try std.testing.expectEqual(Action{ .erase_line = .all }, parser.feedSlice("\x1b[2K"));
}

test "ESC[m SGR attributes" {
    var parser = Parser{};

    // Reset
    try std.testing.expectEqual(Action{ .sgr = .{ .reset = true } }, parser.feedSlice("\x1b[m"));
    try std.testing.expectEqual(Action{ .sgr = .{ .reset = true } }, parser.feedSlice("\x1b[0m"));

    // Bold
    try std.testing.expectEqual(Action{ .sgr = .{ .bold = true } }, parser.feedSlice("\x1b[1m"));

    // Underline
    try std.testing.expectEqual(Action{ .sgr = .{ .underline = true } }, parser.feedSlice("\x1b[4m"));

    // Foreground colors (basic 8)
    try std.testing.expectEqual(Action{ .sgr = .{ .fg_color = @intFromEnum(Color.red) } }, parser.feedSlice("\x1b[31m"));
    try std.testing.expectEqual(Action{ .sgr = .{ .fg_color = @intFromEnum(Color.green) } }, parser.feedSlice("\x1b[32m"));

    // Bright foreground
    try std.testing.expectEqual(Action{ .sgr = .{ .fg_color = @intFromEnum(Color.bright_red) } }, parser.feedSlice("\x1b[91m"));

    // Background colors
    try std.testing.expectEqual(Action{ .sgr = .{ .bg_color = @intFromEnum(Color.blue) } }, parser.feedSlice("\x1b[44m"));
    try std.testing.expectEqual(Action{ .sgr = .{ .bg_color = @intFromEnum(Color.bright_cyan) } }, parser.feedSlice("\x1b[106m"));

    // Combined: bold + red fg + blue bg
    try std.testing.expectEqual(Action{ .sgr = .{
        .bold = true,
        .fg_color = @intFromEnum(Color.red),
        .bg_color = @intFromEnum(Color.blue),
    } }, parser.feedSlice("\x1b[1;31;44m"));
}

test "ESC[38;5;Nm 256-color mode" {
    var parser = Parser{};

    // 256-color foreground
    try std.testing.expectEqual(Action{ .sgr = .{ .fg_color = 196 } }, parser.feedSlice("\x1b[38;5;196m"));
    try std.testing.expectEqual(Action{ .sgr = .{ .fg_color = 0 } }, parser.feedSlice("\x1b[38;5;0m"));
    try std.testing.expectEqual(Action{ .sgr = .{ .fg_color = 255 } }, parser.feedSlice("\x1b[38;5;255m"));

    // 256-color background
    try std.testing.expectEqual(Action{ .sgr = .{ .bg_color = 21 } }, parser.feedSlice("\x1b[48;5;21m"));

    // Combined: bold + 256-color fg + 256-color bg
    try std.testing.expectEqual(Action{ .sgr = .{
        .bold = true,
        .fg_color = 196,
        .bg_color = 21,
    } }, parser.feedSlice("\x1b[1;38;5;196;48;5;21m"));
}

test "ESC[38;2;R;G;Bm true color mode" {
    var parser = Parser{};

    // True color foreground
    try std.testing.expectEqual(Action{ .sgr = .{ .fg_rgb = .{ .r = 255, .g = 128, .b = 0 } } }, parser.feedSlice("\x1b[38;2;255;128;0m"));

    // True color background
    try std.testing.expectEqual(Action{ .sgr = .{ .bg_rgb = .{ .r = 0, .g = 0, .b = 255 } } }, parser.feedSlice("\x1b[48;2;0;0;255m"));

    // Combined: bold + true color fg + true color bg
    try std.testing.expectEqual(Action{ .sgr = .{
        .bold = true,
        .fg_rgb = .{ .r = 255, .g = 0, .b = 0 },
        .bg_rgb = .{ .r = 0, .g = 255, .b = 0 },
    } }, parser.feedSlice("\x1b[1;38;2;255;0;0;48;2;0;255;0m"));
}

test "ESC[?25h/l cursor visibility" {
    var parser = Parser{};

    // Show cursor
    try std.testing.expectEqual(Action{ .cursor_visible = true }, parser.feedSlice("\x1b[?25h"));

    // Hide cursor
    try std.testing.expectEqual(Action{ .cursor_visible = false }, parser.feedSlice("\x1b[?25l"));
}

test "UTF-8 multi-byte characters" {
    var parser = Parser{};

    // ❯ is U+276F, encoded as 0xE2 0x9D 0xAF (3 bytes)
    try std.testing.expectEqual(Action.none, parser.feed(0xE2));
    try std.testing.expectEqual(Action.none, parser.feed(0x9D));
    try std.testing.expectEqual(Action{ .print = 0x276F }, parser.feed(0xAF));

    // € is U+20AC, encoded as 0xE2 0x82 0xAC (3 bytes)
    try std.testing.expectEqual(Action{ .print = 0x20AC }, parser.feedSlice("\xe2\x82\xac"));

    // 2-byte: é is U+00E9, encoded as 0xC3 0xA9
    try std.testing.expectEqual(Action{ .print = 0x00E9 }, parser.feedSlice("\xc3\xa9"));

    // 4-byte: 😀 is U+1F600, encoded as 0xF0 0x9F 0x98 0x80
    try std.testing.expectEqual(Action{ .print = 0x1F600 }, parser.feedSlice("\xf0\x9f\x98\x80"));
}
