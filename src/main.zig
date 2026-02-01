const std = @import("std");
const ansiParser = @import("ansi-parser.zig");
const screen = @import("screen.zig");
const render = @import("render.zig");

// IOCtl constants
const TIOCGPTN: u32 = 0x80045430;
const TIOCSPTLCK: u32 = 0x40045431;
const TIOCSCTTY: u32 = 0x540E;
const TIOCGWINSZ: u32 = 0x5413;
const TIOCSWINSZ: u32 = 0x5414;

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

fn getTerminalSize() !Winsize {
    var size: Winsize = undefined;
    const ret = std.os.linux.ioctl(std.posix.STDIN_FILENO, TIOCGWINSZ, @intFromPtr(&size));
    if (ret != 0) {
        return error.IoctlFailed;
    }
    return size;
}

fn setTerminalSize(fd: std.posix.fd_t, rows: u16, cols: u16) !void {
    var size = Winsize{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    const ret = std.os.linux.ioctl(fd, TIOCSWINSZ, @intFromPtr(&size));
    if (ret != 0) {
        return error.IoctlFailed;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get terminal size
    const term_size = try getTerminalSize();
    const inner_width = term_size.ws_col - 2; // Account for left and right border
    const inner_height = term_size.ws_row - 2; // Account for top and bottom border

    // Initialize screen buffer
    var scr = try screen.Screen.init(allocator, inner_width, inner_height);
    defer scr.deinit();

    // Initialize parser
    var parser = ansiParser.Parser{};

    // Initialize renderer
    var renderer = render.Renderer.init(std.posix.STDOUT_FILENO);

    // Open pseudo terminal master
    const pseudo_terminal_fd = std.posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch unreachable;
    defer std.posix.close(pseudo_terminal_fd);

    // Unlock PTY
    var unlock: c_int = 0;
    const unlock_ret = std.os.linux.ioctl(pseudo_terminal_fd, TIOCSPTLCK, @intFromPtr(&unlock));
    if (unlock_ret != 0) {
        std.debug.print("TIOCSPTLCK error code {d}\n", .{unlock_ret});
        return;
    }

    // Get slave PTY number
    var slave_terminal_num: c_uint = 0;
    const get_pt_ret = std.os.linux.ioctl(pseudo_terminal_fd, TIOCGPTN, @intFromPtr(&slave_terminal_num));
    if (get_pt_ret != 0) {
        std.debug.print("TIOCGPTN error code {d}\n", .{get_pt_ret});
        return;
    }

    // Set PTY size to inner dimensions
    try setTerminalSize(pseudo_terminal_fd, inner_height, inner_width);

    const pid = try std.posix.fork();
    if (pid == 0) {
        // CHILD PROCESS
        const path = std.fmt.allocPrint(allocator, "/dev/pts/{d}", .{slave_terminal_num}) catch unreachable;
        const slave_terminal_fd = std.posix.open(path, .{ .ACCMODE = .RDWR }, 0) catch unreachable;
        _ = std.os.linux.setsid();

        const set_controlling_tty_ret = std.os.linux.ioctl(slave_terminal_fd, TIOCSCTTY, 0);
        if (set_controlling_tty_ret != 0) {
            std.debug.print("TIOCSCTTY error code {d}\n", .{set_controlling_tty_ret});
            return;
        }

        try std.posix.dup2(slave_terminal_fd, std.posix.STDIN_FILENO);
        try std.posix.dup2(slave_terminal_fd, std.posix.STDOUT_FILENO);
        try std.posix.dup2(slave_terminal_fd, std.posix.STDERR_FILENO);

        const shell = std.posix.getenvZ("SHELL") orelse "/bin/sh";
        const argv = [_:null]?[*:0]const u8{shell};
        return std.posix.execvpeZ(shell, &argv, std.c.environ);
    } else {
        // PARENT PROCESS
        var fds = [_]std.posix.pollfd{
            .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = pseudo_terminal_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        var buf: [4096]u8 = undefined;

        // Set terminal to raw mode
        const original_tc_attrs = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch unreachable;
        var tc_attrs = original_tc_attrs;
        tc_attrs.lflag.ECHO = false;
        tc_attrs.lflag.ICANON = false;
        tc_attrs.lflag.ISIG = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, tc_attrs) catch unreachable;

        // Clear screen and do initial render
        renderer.clear();
        renderer.render(&scr);

        while (true) {
            const TIMEOUT = -1;
            _ = std.posix.poll(&fds, TIMEOUT) catch unreachable;

            // Handle stdin input -> write to PTY
            if (fds[0].revents & std.posix.POLL.IN != 0) {
                const bytes_read = std.posix.read(fds[0].fd, &buf) catch unreachable;
                _ = std.posix.write(pseudo_terminal_fd, buf[0..bytes_read]) catch unreachable;
            }
            if (fds[0].revents & std.posix.POLL.HUP != 0) {
                break;
            }

            // Handle PTY output -> parse and render
            if (fds[1].revents & std.posix.POLL.IN != 0) {
                const bytes_read = std.posix.read(fds[1].fd, &buf) catch unreachable;

                // Feed each byte to the parser and apply actions to screen
                for (buf[0..bytes_read]) |byte| {
                    const action = parser.feed(byte);
                    scr.processAction(action);
                }

                // Render the updated screen
                renderer.render(&scr);
            }
            if (fds[1].revents & std.posix.POLL.HUP != 0) {
                break;
            }
        }

        // Restore terminal attributes
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, original_tc_attrs) catch unreachable;

        // Clear screen on exit
        renderer.clear();
    }
}
