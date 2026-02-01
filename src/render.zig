const std = @import("std");
const screen = @import("screen.zig");
const ansiParser = @import("ansi-parser.zig");

pub const Renderer = struct {
    fd: std.posix.fd_t,

    pub fn init(fd: std.posix.fd_t) Renderer {
        return Renderer{ .fd = fd };
    }

    fn write(self: *Renderer, data: []const u8) void {
        _ = std.posix.write(self.fd, data) catch {};
    }

    fn print(self: *Renderer, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(slice);
    }

    pub fn render(self: *Renderer, scr: *const screen.Screen) void {
        // Hide cursor during render to avoid flicker
        self.write("\x1b[?25l");

        // Clear screen and move to top-left
        self.write("\x1b[2J\x1b[H");

        // Draw top border
        self.write("\u{250c}"); // ┌
        for (0..scr.width) |_| {
            self.write("\u{2500}"); // ─
        }
        self.write("\u{2510}\r\n"); // ┐

        // Draw each row with side borders
        for (0..scr.height) |row| {
            self.write("\u{2502}"); // │

            for (0..scr.width) |col| {
                const cell = scr.cells[row][col];
                self.renderCell(cell);
            }

            // Reset attributes after each row
            self.write("\x1b[0m");
            self.write("\u{2502}\r\n"); // │
        }

        // Draw bottom border
        self.write("\u{2514}"); // └
        for (0..scr.width) |_| {
            self.write("\u{2500}"); // ─
        }
        self.write("\u{2518}"); // ┘

        // Position cursor (add 2 for border: 1 for top border, 1 for 1-based positioning)
        self.print("\x1b[{d};{d}H", .{
            scr.cursor_row + 2,
            scr.cursor_col + 2,
        });

        // Show cursor if visible
        if (scr.cursor_visible) {
            self.write("\x1b[?25h");
        }
    }

    fn renderCell(self: *Renderer, cell: screen.Cell) void {
        var wrote_style = false;

        // Apply styles
        if (cell.bold) {
            self.write("\x1b[1m");
            wrote_style = true;
        }
        if (cell.underline) {
            self.write("\x1b[4m");
            wrote_style = true;
        }

        // Foreground color
        if (cell.fg_rgb) |rgb| {
            self.print("\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
            wrote_style = true;
        } else if (cell.fg_color) |c| {
            if (c < 8) {
                self.print("\x1b[{d}m", .{30 + @as(u16, c)});
            } else if (c < 16) {
                self.print("\x1b[{d}m", .{90 + @as(u16, c) - 8});
            } else {
                self.print("\x1b[38;5;{d}m", .{c});
            }
            wrote_style = true;
        }

        // Background color
        if (cell.bg_rgb) |rgb| {
            self.print("\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
            wrote_style = true;
        } else if (cell.bg_color) |c| {
            if (c < 8) {
                self.print("\x1b[{d}m", .{40 + @as(u16, c)});
            } else if (c < 16) {
                self.print("\x1b[{d}m", .{100 + @as(u16, c) - 8});
            } else {
                self.print("\x1b[48;5;{d}m", .{c});
            }
            wrote_style = true;
        }

        // Write character
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cell.char, &buf) catch 1;
        self.write(buf[0..len]);

        // Reset if we applied any styles
        if (wrote_style) {
            self.write("\x1b[0m");
        }
    }

    /// Clear the entire terminal screen
    pub fn clear(self: *Renderer) void {
        self.write("\x1b[2J\x1b[H");
    }
};

test "renderer can be initialized" {
    var scr = try screen.Screen.init(std.testing.allocator, 10, 3);
    defer scr.deinit();

    scr.putChar('H');
    scr.putChar('i');

    try std.testing.expectEqual(@as(u21, 'H'), scr.cells[0][0].char);
    try std.testing.expectEqual(@as(u21, 'i'), scr.cells[0][1].char);
}
