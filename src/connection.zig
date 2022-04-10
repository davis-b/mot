const std = @import("std");
const net = std.net;

const mot = @import("main.zig");
const windows = @import("windows.zig");

/// Prepends mot packet headers to sent messages.
/// Handles simple sending and receiving.
pub fn Connection(comptime msg_len_t: type) type {
    return struct {
        const This = @This();
        allocator: *std.mem.Allocator,
        stream: net.Stream,
        delimiter: mot.Mot(msg_len_t),

        /// Windows only.
        /// Windows sockets can have an 'overlapped' flag, allowing for simultaneous
        /// read and write calls to occur.
        /// This requires changing the send() argument as well, thus we track it here.
        windows_overlapped_flag: bool = false,
        windows_events: ?[2]std.os.windows.HANDLE = null,

        /// Takes an active socket fd.
        /// Does not use the given socket until we being to recv() and send().
        pub fn init(allocator: *std.mem.Allocator, socket: std.os.socket_t) !This {
            return This{
                .allocator = allocator,
                .stream = net.Stream{ .handle = socket },
                .delimiter = try mot.Mot(msg_len_t).init(allocator),
            };
        }

        /// Closes the connection and frees the memory we have allocated.
        pub fn deinit(self: *This) void {
            self.delimiter.deinit();
            self.stream.close();
        }

        /// Sends a message and appropriate mot header
        pub fn send(self: *This, msg: []const u8) !void {
            // Create header and check for message validity.
            const header = try self.delimiter.make_header(msg);

            const sent_hdr_amount = try self.socket_write(header[0..]);
            if (sent_hdr_amount != header.len) return error.HeaderSend;

            const sent_msg_amount = try self.socket_write(msg);
            if (sent_msg_amount != msg.len) return error.MessageSend;
        }

        /// Caller owns the returned bytes.
        /// Blocks until a complete message has been received.
        pub fn recv(self: *This, buffer: []u8) ![]u8 {
            while (true) {
                if (self.pop_msg()) |result| {
                    return result;
                }
                _ = try self.recv_nomsg(buffer);
            }
        }

        /// Reads from the socket, but does not return any completed messages.
        /// To receive completed messages after calling this function, the caller
        /// should call the 'pop_msg' function.
        /// Can block when reading from the socket, otherwise nonblocking.
        /// Returns whether or not the read buffer was fully utilized or not.
        pub fn recv_nomsg(self: *This, buffer: []u8) !bool {
            const read_bytes = self.socket_read(buffer) catch |err| {
                switch (err) {
                    error.ConnectionResetByPeer => return error.ConnectionClosed,
                    else => return err,
                }
            };
            if (read_bytes == 0) {
                return error.ConnectionClosed;
            }

            try self.delimiter.recv(buffer[0..read_bytes]);
            return read_bytes == buffer.len;
        }

        /// Returns a stored message, if available.
        pub fn pop_msg(self: *This) ?[]u8 {
            return self.delimiter.get_message();
        }

        /// Stream.write() calls the underlying WriteFile function with 
        /// invalid arguments if our Windows socket has the OVERLAPPED flag.
        /// Thus, we call the function ourselves with the context of that flag.
        fn socket_write(self: *This, data: []const u8) !usize {
            if (std.builtin.os.tag == .windows and self.windows_overlapped_flag) {
                if (self.windows_events == null) {
                    self.windows_events = .{ try windows.create_event(), try windows.create_event() };
                }
                const result = windows.write_file_async(self.stream.handle, data, self.windows_events.?[1]);
                return result;
            } else return self.stream.write(data);
        }

        /// Stream.read() calls the underlying ReadFile function with 
        /// invalid arguments if our Windows socket has the OVERLAPPED flag.
        /// Thus, we call the function ourselves with the context of that flag.
        fn socket_read(self: *This, buffer: []u8) !usize {
            if (std.builtin.os.tag == .windows and self.windows_overlapped_flag) {
                if (self.windows_events == null) {
                    self.windows_events = .{ try windows.create_event(), try windows.create_event() };
                }
                const result = windows.read_file_async(self.stream.handle, buffer, self.windows_events.?[0]);
                return result;
            } else return self.stream.read(buffer);
        }
    };
}
