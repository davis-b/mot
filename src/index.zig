const std = @import("std");

pub const Connection = @import("connection.zig").Connection;
pub const core = @import("main.zig");

const linux = @import("linux.zig");
const windows = @import("windows.zig");

/// Initializes WSA network functionality for Windows.
/// Registers a SIGPIPE handler for Linux.
pub fn init() !void {
    switch (std.builtin.os.tag) {
        .windows => {
            _ = try std.os.windows.WSAStartup(2, 2);
        },
        .linux => {
            try linux.ignore_sigpipe_signal();
        },
        else => @compileError("Unsupported OS" ++ std.builtin.os.tag),
    }
}

/// Deinits Windows' WSA networking.
/// Unregisters our SIGPIPE handler in Linux.
pub fn deinit() !void {
    switch (std.builtin.os.tag) {
        .windows => {
            try std.os.windows.WSACleanup();
        },
        .linux => {
            try linux.restore_sigpipe_signal();
        },
        else => @compileError("Unsupported OS" ++ std.builtin.os.tag),
    }
}
