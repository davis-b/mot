const std = @import("std");
usingnamespace std.os.linux;

/// When writing to a socket whose reading end is closed,
/// we receive a sigpipe signal as well as a sigpipe error
/// function response.
/// The default action for the sigpipe signal is for our program
/// to exit ungracefully. By ignoring the signal, we allow
/// our program to process the error via normal routes.
/// Thus, this function sets the sigpipe signal to be ignored.
pub fn ignore_sigpipe_signal() !void {
    var mask = [_]u32{0} ** 32;
    var action = Sigaction{
        .mask = mask,
        .flags = 0,
        .handler = .{
            .sigaction = SIG_IGN,
        },
        .restorer = null,
    };
    const result = sigaction(SIGPIPE, &action, null);

    if (result != 0) return error.UnableToRegisterFn;
}

/// Restore default signal handling functionality.
pub fn restore_sigpipe_signal() !void {
    var mask = [_]u32{0} ** 32;
    var action = Sigaction{
        .mask = mask,
        .flags = 0,
        .handler = .{
            .sigaction = SIG_DFL,
        },
        .restorer = null,
    };
    const result = sigaction(SIGPIPE, &action, null);

    if (result != 0) return error.UnableToRegisterFn;
}
