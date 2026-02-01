const std = @import("std");

// Kernel magic numbers?
// IOCtl Get PseudoTty Number
const TIOCGPTN: u32 = 0x80045430;
// IOCtl Set PSeudoTty Lock
const TIOCSPTLCK: u32 = 0x40045431;
// IOCtl Set Controll TTY
const TIOCSCTTY = 0x540E;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const pseudo_terminal_fd = std.posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch unreachable;

    var unlock: c_int = 0;
    const unlock_ret = std.os.linux.ioctl(pseudo_terminal_fd, TIOCSPTLCK, @intFromPtr(&unlock));
    if (unlock_ret != 0) {
        std.debug.print("TIOCSPTLCK error code {d}", .{unlock_ret});
        return;
    }

    var slave_terminal_num: c_uint = 0;
    const get_pt_ret = std.os.linux.ioctl(pseudo_terminal_fd, TIOCGPTN, @intFromPtr(&slave_terminal_num));
    if (get_pt_ret != 0) {
        std.debug.print("TIOCGPTN error code {d}", .{get_pt_ret});
        return;
    }

    const pid = try std.posix.fork();
    if (pid == 0) {
        // CHILD
        const path = std.fmt.allocPrint(allocator, "/dev/pts/{d}", .{slave_terminal_num}) catch unreachable;
        const slave_terminal_fd = std.posix.open(path, .{ .ACCMODE = .RDWR }, 0) catch unreachable;
        _ = std.os.linux.setsid();
        const set_controlling_tty_ret = std.os.linux.ioctl(slave_terminal_fd, TIOCSCTTY, 0);
        if (set_controlling_tty_ret != 0) {
            std.debug.print("TIOCSCTTY error code {d}", .{set_controlling_tty_ret});
            return;
        }

        try std.posix.dup2(slave_terminal_fd, std.posix.STDIN_FILENO);
        try std.posix.dup2(slave_terminal_fd, std.posix.STDOUT_FILENO);
        try std.posix.dup2(slave_terminal_fd, std.posix.STDERR_FILENO);

        const shell = std.posix.getenvZ("SHELL") orelse "/bin/sh";

        const argv = [_:null]?[*:0]const u8{shell};
        return std.posix.execvpeZ(shell, &argv, std.c.environ);
    } else {
        // Master
        var fds = [_]std.posix.pollfd{
            .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }, // stdin
            .{ .fd = pseudo_terminal_fd, .events = std.posix.POLL.IN, .revents = 0 }, // master
        };
        var buf: [1024]u8 = undefined;

        // TODO handle error
        const original_tc_attrs = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch unreachable;
        var tc_attrs = original_tc_attrs;
        tc_attrs.lflag.ECHO = false;
        tc_attrs.lflag.ICANON = false;
        tc_attrs.lflag.ISIG = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, tc_attrs) catch unreachable;

        while (true) {
            const TIMEOUT = -1; // Wait forever
            // TODO handle error
            _ = std.posix.poll(&fds, TIMEOUT) catch unreachable;
            if (fds[0].revents & std.posix.POLL.IN != 0) {
                // TODO handle error
                const bytes_read = std.posix.read(fds[0].fd, &buf) catch unreachable;
                _ = std.posix.write(fds[1].fd, buf[0..bytes_read]) catch unreachable;
            }
            if (fds[0].revents & std.posix.POLL.HUP != 0) {
                break;
            }
            if (fds[1].revents & std.posix.POLL.IN != 0) {
                const bytes_read = std.posix.read(fds[1].fd, &buf) catch unreachable;
                _ = std.posix.write(fds[0].fd, buf[0..bytes_read]) catch unreachable;
            }
            if (fds[1].revents & std.posix.POLL.HUP != 0) {
                break;
            }
        }

        // TODO handle error
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, original_tc_attrs) catch unreachable;
    }
}
