# Window Resize Handling

When you resize your terminal, the kernel sends SIGWINCH to your process. You need to:

1. Catch SIGWINCH - set up a signal handler with std.posix.sigaction
2. Get current size - ioctl(stdin, TIOCGWINSZ, &winsize)
3. Set PTY size - ioctl(master, TIOCSWINSZ, &winsize)

Functions/types you'll need:

- std.posix.sigaction - register signal handler
- std.posix.Sigaction - struct for handler config
- std.posix.SIG.WINCH - the signal number
- std.posix.winsize - struct with .row and .col
- std.posix.T.IOCGWINSZ - ioctl to get window size
- std.posix.T.IOCSWINSZ - ioctl to set window size

The tricky part: Signal handlers can't access local variables. You'll need pseudo_terminal_fd to be accessible from the handler (global
variable or similar).

Start by making pseudo_terminal_fd global, then set up the signal handler.

