const std = @import("std");
const ansiParser = @import("ansi-parser.zig");

pub const Cell = struct {
    char: u21 = ' ',
    fg_color: ?u8 = null,
    bg_color: ?u8 = null,
    fg_rgb: ?ansiParser.Rgb = null,
    bg_rgb: ?ansiParser.Rgb = null,
    bold: bool = false,
    underline: bool = false,
};

pub const Screen = struct {
    cells: [][]Cell,
    width: u16,
    height: u16,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_visible: bool = true,

    // Current style applied to new characters
    current_fg: ?u8 = null,
    current_bg: ?u8 = null,
    current_fg_rgb: ?ansiParser.Rgb = null,
    current_bg_rgb: ?ansiParser.Rgb = null,
    current_bold: bool = false,
    current_underline: bool = false,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Screen {
        const cells = try allocator.alloc([]Cell, height);
        for (cells) |*row| {
            row.* = try allocator.alloc(Cell, width);
            for (row.*) |*cell| {
                cell.* = Cell{};
            }
        }

        return Screen{
            .cells = cells,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Screen) void {
        for (self.cells) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.cells);
    }

    pub fn putChar(self: *Screen, char: u21) void {
        if (self.cursor_row < self.height and self.cursor_col < self.width) {
            self.cells[self.cursor_row][self.cursor_col] = Cell{
                .char = char,
                .fg_color = self.current_fg,
                .bg_color = self.current_bg,
                .fg_rgb = self.current_fg_rgb,
                .bg_rgb = self.current_bg_rgb,
                .bold = self.current_bold,
                .underline = self.current_underline,
            };
            self.cursor_col += 1;

            // Wrap to next line if at end
            if (self.cursor_col >= self.width) {
                self.cursor_col = 0;
                if (self.cursor_row < self.height - 1) {
                    self.cursor_row += 1;
                }
            }
        }
    }

    pub fn setCursor(self: *Screen, row: u16, col: u16) void {
        self.cursor_row = @min(row, self.height -| 1);
        self.cursor_col = @min(col, self.width -| 1);
    }

    pub fn moveCursor(self: *Screen, dir: ansiParser.MoveCursorRelativeDirection, n: u16) void {
        switch (dir) {
            .up => self.cursor_row -|= n,
            .down => self.cursor_row = @min(self.cursor_row + n, self.height -| 1),
            .left => self.cursor_col -|= n,
            .right => self.cursor_col = @min(self.cursor_col + n, self.width -| 1),
        }
    }

    pub fn eraseLine(self: *Screen, mode: ansiParser.EraseMode) void {
        const row = self.cursor_row;
        if (row >= self.height) return;

        switch (mode) {
            .to_end => {
                for (self.cursor_col..self.width) |col| {
                    self.cells[row][col] = Cell{};
                }
            },
            .to_start => {
                for (0..self.cursor_col + 1) |col| {
                    self.cells[row][col] = Cell{};
                }
            },
            .all => {
                for (0..self.width) |col| {
                    self.cells[row][col] = Cell{};
                }
            },
        }
    }

    pub fn eraseDisplay(self: *Screen, mode: ansiParser.EraseMode) void {
        switch (mode) {
            .to_end => {
                // Erase from cursor to end of screen
                self.eraseLine(.to_end);
                for ((self.cursor_row + 1)..self.height) |row| {
                    for (0..self.width) |col| {
                        self.cells[row][col] = Cell{};
                    }
                }
            },
            .to_start => {
                // Erase from start to cursor
                for (0..self.cursor_row) |row| {
                    for (0..self.width) |col| {
                        self.cells[row][col] = Cell{};
                    }
                }
                self.eraseLine(.to_start);
            },
            .all => {
                // Erase entire screen
                for (0..self.height) |row| {
                    for (0..self.width) |col| {
                        self.cells[row][col] = Cell{};
                    }
                }
            },
        }
    }

    pub fn applyStyle(self: *Screen, sgr: ansiParser.SgrAttribute) void {
        if (sgr.reset) {
            self.current_fg = null;
            self.current_bg = null;
            self.current_fg_rgb = null;
            self.current_bg_rgb = null;
            self.current_bold = false;
            self.current_underline = false;
        }
        if (sgr.bold) |b| self.current_bold = b;
        if (sgr.underline) |u| self.current_underline = u;
        if (sgr.fg_color) |c| {
            self.current_fg = c;
            self.current_fg_rgb = null;
        }
        if (sgr.bg_color) |c| {
            self.current_bg = c;
            self.current_bg_rgb = null;
        }
        if (sgr.fg_rgb) |rgb| {
            self.current_fg_rgb = rgb;
            self.current_fg = null;
        }
        if (sgr.bg_rgb) |rgb| {
            self.current_bg_rgb = rgb;
            self.current_bg = null;
        }
    }

    pub fn carriageReturn(self: *Screen) void {
        self.cursor_col = 0;
    }

    pub fn lineFeed(self: *Screen) void {
        if (self.cursor_row < self.height - 1) {
            self.cursor_row += 1;
        } else {
            // Scroll up: move all rows up by 1, clear last row
            self.scrollUp(1);
        }
    }

    pub fn backspace(self: *Screen) void {
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
        }
    }

    pub fn tab(self: *Screen) void {
        // Move to next tab stop (every 8 columns)
        const next_tab = (self.cursor_col / 8 + 1) * 8;
        self.cursor_col = @min(next_tab, self.width - 1);
    }

    fn scrollUp(self: *Screen, n: u16) void {
        const shift = @min(n, self.height);

        // Move rows up
        for (0..(self.height - shift)) |row| {
            for (0..self.width) |col| {
                self.cells[row][col] = self.cells[row + shift][col];
            }
        }

        // Clear bottom rows
        for ((self.height - shift)..self.height) |row| {
            for (0..self.width) |col| {
                self.cells[row][col] = Cell{};
            }
        }
    }

    /// Process an action from the ANSI parser
    pub fn processAction(self: *Screen, action: ansiParser.Action) void {
        switch (action) {
            .none => {},
            .print => |char| self.putChar(char),
            .carriage_return => self.carriageReturn(),
            .line_feed => self.lineFeed(),
            .backspace => self.backspace(),
            .tab => self.tab(),
            .bell => {}, // Could trigger a visual bell
            .move_cursor => |pos| self.setCursor(pos.x, pos.y),
            .move_cursor_relative => |rel| self.moveCursor(rel.dir, rel.n),
            .erase_display => |mode| self.eraseDisplay(mode),
            .erase_line => |mode| self.eraseLine(mode),
            .sgr => |sgr| self.applyStyle(sgr),
            .cursor_visible => |visible| self.cursor_visible = visible,
        }
    }
};

// Tests
test "init and deinit" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    try std.testing.expectEqual(@as(u16, 80), screen.width);
    try std.testing.expectEqual(@as(u16, 24), screen.height);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_col);
}

test "putChar advances cursor" {
    var screen = try Screen.init(std.testing.allocator, 10, 5);
    defer screen.deinit();

    screen.putChar('H');
    screen.putChar('i');

    try std.testing.expectEqual(@as(u21, 'H'), screen.cells[0][0].char);
    try std.testing.expectEqual(@as(u21, 'i'), screen.cells[0][1].char);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor_col);
}

test "putChar wraps at end of line" {
    var screen = try Screen.init(std.testing.allocator, 5, 3);
    defer screen.deinit();

    for ("Hello") |c| screen.putChar(c);
    screen.putChar('!');

    try std.testing.expectEqual(@as(u16, 1), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor_col);
    try std.testing.expectEqual(@as(u21, '!'), screen.cells[1][0].char);
}

test "setCursor" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursor(10, 20);
    try std.testing.expectEqual(@as(u16, 10), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 20), screen.cursor_col);

    // Clamp to bounds
    screen.setCursor(100, 200);
    try std.testing.expectEqual(@as(u16, 23), screen.cursor_row);
    try std.testing.expectEqual(@as(u16, 79), screen.cursor_col);
}

test "moveCursor relative" {
    var screen = try Screen.init(std.testing.allocator, 80, 24);
    defer screen.deinit();

    screen.setCursor(10, 10);
    screen.moveCursor(.up, 3);
    try std.testing.expectEqual(@as(u16, 7), screen.cursor_row);

    screen.moveCursor(.down, 5);
    try std.testing.expectEqual(@as(u16, 12), screen.cursor_row);

    screen.moveCursor(.left, 4);
    try std.testing.expectEqual(@as(u16, 6), screen.cursor_col);

    screen.moveCursor(.right, 10);
    try std.testing.expectEqual(@as(u16, 16), screen.cursor_col);
}

test "eraseLine" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    for ("0123456789") |c| screen.putChar(c);
    screen.setCursor(0, 5);

    screen.eraseLine(.to_end);
    try std.testing.expectEqual(@as(u21, '4'), screen.cells[0][4].char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cells[0][5].char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cells[0][9].char);
}

test "eraseDisplay all" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    for ("Hello") |c| screen.putChar(c);
    screen.eraseDisplay(.all);

    try std.testing.expectEqual(@as(u21, ' '), screen.cells[0][0].char);
    try std.testing.expectEqual(@as(u21, ' '), screen.cells[0][4].char);
}

test "applyStyle and putChar with color" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.applyStyle(.{ .fg_color = 1, .bold = true });
    screen.putChar('X');

    try std.testing.expectEqual(@as(?u8, 1), screen.cells[0][0].fg_color);
    try std.testing.expectEqual(true, screen.cells[0][0].bold);
}

test "lineFeed scrolls when at bottom" {
    var screen = try Screen.init(std.testing.allocator, 5, 3);
    defer screen.deinit();

    // Fill first row
    for ("Line1") |c| screen.putChar(c);
    screen.carriageReturn();
    screen.lineFeed();

    // Fill second row
    for ("Line2") |c| screen.putChar(c);
    screen.carriageReturn();
    screen.lineFeed();

    // Fill third row (bottom)
    for ("Line3") |c| screen.putChar(c);
    screen.carriageReturn();
    screen.lineFeed(); // This should scroll

    // Line1 should be gone, Line2 should be at top
    try std.testing.expectEqual(@as(u21, 'L'), screen.cells[0][0].char);
    try std.testing.expectEqual(@as(u21, 'i'), screen.cells[0][1].char);
    try std.testing.expectEqual(@as(u21, 'n'), screen.cells[0][2].char);
    try std.testing.expectEqual(@as(u21, 'e'), screen.cells[0][3].char);
    try std.testing.expectEqual(@as(u21, '2'), screen.cells[0][4].char);
}

test "processAction integrates with parser" {
    var screen = try Screen.init(std.testing.allocator, 10, 3);
    defer screen.deinit();

    screen.processAction(.{ .print = 'A' });
    screen.processAction(.{ .print = 'B' });
    screen.processAction(.carriage_return);
    screen.processAction(.line_feed);
    screen.processAction(.{ .print = 'C' });

    try std.testing.expectEqual(@as(u21, 'A'), screen.cells[0][0].char);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cells[0][1].char);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cells[1][0].char);
}
