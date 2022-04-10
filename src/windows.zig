const std = @import("std");
const win = std.os.windows;
const DWORD = win.DWORD;
const OVERLAPPED = win.OVERLAPPED;
const HANDLE = win.HANDLE;

// Modified from zig std library (std.os.windows.zig) to include an hEvent object.
pub fn write_file_async(handle: HANDLE, bytes: []const u8, event: HANDLE) !usize {
    var overlapped_data: OVERLAPPED = undefined;
    const overlapped: *OVERLAPPED = blk: {
        overlapped_data = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Offset = 0,
            .OffsetHigh = 0,
            .hEvent = event,
        };
        break :blk &overlapped_data;
    };
    const adjusted_len = std.math.cast(u32, bytes.len) catch std.math.maxInt(u32);

    _ = win.kernel32.WriteFile(handle, bytes.ptr, adjusted_len, null, overlapped);
    var bytes_transferred: DWORD = undefined;
    if (win.kernel32.GetOverlappedResult(handle, overlapped, &bytes_transferred, win.TRUE) == 0) {
        switch (win.kernel32.GetLastError()) {
            .IO_PENDING => unreachable,
            .INVALID_USER_BUFFER => return error.SystemResources,
            .NOT_ENOUGH_MEMORY => return error.SystemResources,
            .OPERATION_ABORTED => return error.OperationAborted,
            .NOT_ENOUGH_QUOTA => return error.SystemResources,
            .BROKEN_PIPE => return error.BrokenPipe,
            else => |err| return win.unexpectedError(err),
        }
    }
    return bytes_transferred;
}

// Modified from zig std library (std.os.windows.zig) to include an hEvent object.
pub fn read_file_async(in_hFile: HANDLE, buffer: []u8, event: HANDLE) !usize {
    while (true) {
        const want_read_count = @intCast(DWORD, std.math.min(@as(DWORD, std.math.maxInt(DWORD)), buffer.len));
        var overlapped_data: OVERLAPPED = undefined;
        const overlapped: *OVERLAPPED = blk: {
            overlapped_data = .{
                .Internal = 0,
                .InternalHigh = 0,
                .Offset = 0,
                .OffsetHigh = 0,
                .hEvent = event,
            };
            break :blk &overlapped_data;
        };
        _ = win.kernel32.ReadFile(in_hFile, buffer.ptr, want_read_count, null, overlapped);

        var bytes_transferred: DWORD = undefined;
        if (win.kernel32.GetOverlappedResult(in_hFile, overlapped, &bytes_transferred, win.TRUE) == 0) {
            switch (win.kernel32.GetLastError()) {
                .IO_PENDING => unreachable,
                .OPERATION_ABORTED => return error.OperationAborted,
                .BROKEN_PIPE => return error.BrokenPipe,
                .HANDLE_EOF => return @as(usize, bytes_transferred),
                else => |err| return win.unexpectedError(err),
            }
        }

        return bytes_transferred;
    }
}

pub fn create_event() !HANDLE {
    // const name: [*:0]const u16 = @ptrCast([*:0]const u16, &[_]u16{ 'a', 'b', 'c', 'd' });
    const name: [*:0]const u16 = @ptrCast([*:0]const u16, &[_]u16{0});
    //const access = win.READ_CONTROL | win.SYNCHRONIZE | win.DELETE | win.EVENT_MODIFY_STATE;
    const access = win.EVENT_ALL_ACCESS;
    // const rc = win.kernel32.CreateEventExW(null, name, 0, access);
    const rc = CreateEventW(null, true, false, name);
    if (rc == null or @ptrToInt(rc.?) == 0) {
        _ = win.unexpectedError(win.kernel32.GetLastError()) catch {};
        return error.EventCreationError;
    }
    return rc.?;
}

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*win.SECURITY_ATTRIBUTES,
    bManualReset: bool,
    bInitialState: bool,
    lpName: [*:0]const u16,
) callconv(win.WINAPI) ?HANDLE;
