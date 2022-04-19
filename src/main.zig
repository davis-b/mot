const std = @import("std");
const os = std.os;
const testing = std.testing;

/// Sits on top of the TCP stack.
/// Stores received data until a complete "message" has arrived.
/// This module ensures messages sent in separate send calls will be received in distinct and complete messages.
/// Does not do any byte transformations between native and net endianness beyond our own header.
pub fn Mot(comptime msg_len_t: type) type {
    return struct {
        /// Contains any meta-information that we require for each message.
        const Header = packed struct {
            /// Using a static number of bytes at the header stage of a message,
            /// we determine or set the length of the upcoming message.
            msg_len: msg_len_t,
        };
        const This = @This();

        /// Used to allocate message buffers.
        allocator: *std.mem.Allocator,

        /// Contains completed messages.
        /// A single call to recv() can fill this with more than one message.
        messages: std.ArrayList([]u8),

        /// This is the active message we are adding new data to.
        /// Multiple of these can be cycled through in a single recv() call.
        /// Will be null in the time between completing a message 
        /// and receiving the next header.
        incomplete_message: ?Buffer = null,

        /// Since headers can come in separate recv() calls, we store partial header data
        /// here in the same way we store partial message data.
        header: Buffer,

        pub fn init(allocator: *std.mem.Allocator) !This {
            return This{
                .allocator = allocator,
                .messages = std.ArrayList([]u8).init(allocator),
                .header = try Buffer.init(allocator, @sizeOf(Header)),
            };
        }

        pub fn deinit(self: *This) void {
            if (self.incomplete_message) |*buffer| {
                buffer.deinit();
            }

            // Free all stored and unread messages.
            while (self.messages.popOrNull()) |m| {
                self.allocator.free(m);
            }
            self.messages.deinit();
            self.header.deinit();
        }

        /// Returns the bytes for a header that should be sent before the message body.
        /// The header is in net-endian byte format.
        /// Can fail if the message is empty or too large.
        pub fn make_header(self: *This, message: []const u8) ![@sizeOf(Header)]u8 {
            if (message.len == 0) return error.MessageTooSmall;
            if (message.len > std.math.maxInt(msg_len_t)) return error.MessageTooLarge;
            const len = std.mem.nativeToBig(msg_len_t, @intCast(msg_len_t, message.len));
            const header = Header{ .msg_len = len };
            return std.mem.toBytes(header);
        }

        /// Processes each new chunk of data that streams in.
        /// Buffers message data and splits separate messages into distinct slices.
        /// To access completed messages, call get_message().
        /// Copies the given bytes; the caller is allowed to modify or free them after this function call.
        /// Will allocate memory for the upcoming message when we finish building that message's header.
        pub fn recv(self: *This, bytes: []const u8) !void {
            var head: usize = 0;
            while (head < bytes.len) {
                if (self.has_incomplete_header()) {
                    head += self.process_bytes_for_header(bytes[head..]) catch |err| {
                        switch (err) {
                            error.OutOfMemory => return error.OutOfMemoryHeader,
                            error.ZeroLengthMessage => return err,
                        }
                    };
                } else {
                    head += self.process_bytes_for_message(bytes[head..]) catch |err| {
                        switch (err) {
                            error.OutOfMemory => return error.OutOfMemoryMsg,
                        }
                    };
                }
            }
            std.debug.assert(head == bytes.len);
        }

        /// Returns a single complete message, or null if no complete messages are stored.
        /// Returns messages in the order they were received.
        /// Caller is responsible for freeing returned bytes.
        pub fn get_message(self: *This) ?[]u8 {
            if (self.messages.items.len != 0) {
                return self.messages.orderedRemove(0);
            }
            return null;
        }

        /// Returns whether or not our current header is complete (false) or partial (true).
        fn has_incomplete_header(self: *This) bool {
            return self.header.available() > 0;
        }

        /// Sets our current header, if it has arrived.
        /// Returns how many bytes we read.
        fn process_bytes_for_header(self: *This, bytestream: []const u8) !usize {
            const written = self.header.append_some(bytestream);
            std.debug.assert(written <= bytestream.len);

            // Check to see if we have completed building a header.
            if (self.header.available() == 0) {
                try self.on_completed_header();
            } else {
                // If we do not have a complete header, it should only be because we ran out of bytes.
                std.debug.assert(written == bytestream.len);
            }

            return written;
        }

        /// Initializes a message buffer based on the information in our newly received header.
        /// Expects the given header's data to be in net-endian format and will convert it to native.
        fn on_completed_header(self: *This) !void {
            var header = std.mem.bytesAsValue(Header, self.header.data[0..@sizeOf(Header)]);
            header.msg_len = std.mem.bigToNative(msg_len_t, header.msg_len);
            if (header.msg_len == 0) return error.ZeroLengthMessage;
            self.incomplete_message = try Buffer.init(self.allocator, header.msg_len);
        }

        /// Writes the given bytes into our current message buffer.
        /// Returns how many bytes we read/wrote.
        /// Can read anywhere from 1 to bytestream.len bytes.
        /// Can only read fewer bytes than given if we finish building our current message.
        fn process_bytes_for_message(self: *This, bytestream: []const u8) !usize {
            // Copy some or all of byte stream into our buffer.
            const written = self.incomplete_message.?.append_some(bytestream);
            std.debug.assert(written <= bytestream.len);

            // Check to see if message has been completed.
            if (self.incomplete_message.?.available() == 0) {
                try self.complete_a_message();
            }

            return written;
        }

        /// Adds our current worked on message to our list of messages.
        /// Resets our other state to a starting position.
        fn complete_a_message(self: *This) !void {
            try self.messages.append(self.incomplete_message.?.data);
            self.incomplete_message = null;
            self.header.reset();
        }
    };
}

pub const Buffer = struct {
    allocator: *std.mem.Allocator,

    data: []u8,

    /// This is the index where our next write will start.
    head: usize = 0,

    pub fn init(allocator: *std.mem.Allocator, size: usize) !Buffer {
        return Buffer{
            .allocator = allocator,
            .data = try allocator.alloc(u8, size),
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
    }

    /// Resets this Buffer's state to what it was after init().
    /// Does not allocate or free memory. 
    /// Handy for reusing the same sized buffer.
    /// Be sure not to have any pointers to the data held by 
    /// this buffer before calling this function.
    pub fn reset(self: *Buffer) void {
        std.mem.set(u8, self.data[0..self.head], 0);
        self.head = 0;
    }

    /// Returns whether or not this buffer has been filled.
    pub fn is_full(self: *Buffer) bool {
        return self.head == self.data.len;
    }

    /// Returns the number of unused elements in this buffer.
    pub fn available(self: *Buffer) usize {
        return self.data.len - self.head;
    }

    /// Appends data to this buffer, up to our size limit.
    /// Returns the number of bytes we appended from new_data.
    pub fn append_some(self: *Buffer, new_data: []const u8) usize {
        const copy_amount = std.math.min(self.available(), new_data.len);
        std.mem.copy(u8, self.data[self.head..], new_data[0..copy_amount]);
        self.head += copy_amount;
        return copy_amount;
    }

    /// Appends data to this buffer.
    /// Returns an error if we would not be able to fit 
    /// all of the new_data in this buffer.
    pub fn append(self: *Buffer, new_data: []const u8) !void {
        if (new_data.len > self.available()) {
            return error.SizeError;
        }
        std.mem.copy(u8, self.data[self.head..], new_data);
        self.head += new_data.len;
    }
};

const test_msg_len_t = u16;
const TestHeader = Mot(test_msg_len_t).Header;
test "receive" {
    const allocator = testing.allocator;
    var conn = try Mot(test_msg_len_t).init(allocator);
    defer conn.deinit();

    const header_bytes = try conn.make_header("abc");
    var stream = [_][]const u8{
        header_bytes[0..1],
        header_bytes[1..],
        "a",
        "b",
        "c",
    };

    // Null value with the proper type for ease of testing.
    // expectEqual has the syntax (expected, actual), therefore we want to put null first.
    // However, there is a type error if we pass in a regular old null value as the first value.
    const Null: ?[]u8 = null;

    // Partial header.
    try conn.recv(stream[0]);
    try testing.expectEqual(Null, conn.get_message());

    // Full header.
    try conn.recv(stream[1]);
    try testing.expectEqual(Null, conn.get_message());

    // Partial message.
    try conn.recv(stream[2]);
    try testing.expectEqual(Null, conn.get_message());

    // Partial message 2.
    try conn.recv(stream[3]);
    try testing.expectEqual(Null, conn.get_message());

    // Finish the message.
    try conn.recv(stream[4]);
    const msg = conn.get_message().?;
    try testing.expect(std.mem.eql(u8, msg, "abc"));
    allocator.free(msg);

    // Full header.
    try conn.recv(header_bytes[0..]);
    try testing.expectEqual(Null, conn.get_message());
}

test "deinit with unread messages; memory leak test." {
    const allocator = testing.allocator;
    var conn = try Mot(test_msg_len_t).init(allocator);
    defer conn.deinit();

    const msg = "foo";
    const header_bytes = try conn.make_header(msg[0..]);

    // var over_the_wire = try allocator.alloc(u8, header_bytes.len + msg.len);
    var over_the_wire: [msg.len + @sizeOf(TestHeader)]u8 = undefined;
    // defer allocator.free(over_the_wire);
    std.mem.copy(u8, over_the_wire[0..], header_bytes[0..]);
    std.mem.copy(u8, over_the_wire[header_bytes.len..], msg[0..]);

    try conn.recv(over_the_wire[0..]);
    allocator.free(conn.get_message().?);
    try conn.recv(over_the_wire[0..]);
    try conn.recv(over_the_wire[0..]);
}

test "try to send invalid length messages" {
    var conn = try Mot(test_msg_len_t).init(testing.allocator);
    defer conn.deinit();

    const too_large = [_]u8{0} ** (std.math.maxInt(test_msg_len_t) + 1);
    try testing.expectError(error.MessageTooSmall, conn.make_header(""));
    try testing.expectError(error.MessageTooLarge, conn.make_header(too_large[0..]));
}

test "send" {
    var conn = try Mot(test_msg_len_t).init(testing.allocator);
    defer conn.deinit();

    const msg = "abc";
    const expected = TestHeader{ .msg_len = msg.len };
    const result_bytes = try conn.make_header(msg);
    var result_header = std.mem.bytesToValue(TestHeader, result_bytes[0..]);
    result_header.msg_len = std.mem.bigToNative(test_msg_len_t, result_header.msg_len);
    try testing.expectEqual(expected, result_header);
}

test "round trip; send and receive" {
    const allocator = testing.allocator;
    var conn = try Mot(test_msg_len_t).init(allocator);
    defer conn.deinit();

    const msg = "foo bar";
    const header = try conn.make_header(msg);

    // header and then msg would now get sent over the wire
    var received: [msg.len + @sizeOf(TestHeader)]u8 = undefined;
    std.mem.copy(u8, received[0..], header[0..]);
    std.mem.copy(u8, received[header.len..], msg);

    for ([_]u1{0} ** 3) |_| {
        for (received[0 .. received.len - 1]) |byte| {
            try conn.recv(([1]u8{byte})[0..]);
            try testing.expectEqual(@as(?[]u8, null), conn.get_message());
        }
        try conn.recv(([1]u8{received[received.len - 1]})[0..]);
        // try testing.expectEqual(msg[0..], conn.get_message().?);
        const result = conn.get_message().?;
        defer allocator.free(result);

        // Assert the original message matches the returned message.
        try testing.expect(std.mem.eql(u8, msg, result));
    }
}
