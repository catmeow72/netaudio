const std = @import("std");
const main = @import("main.zig");
const Server = @This();

const Connection = struct {
    socket: std.posix.socket_t,
    queue: [8192]u8,
    queue_pos: usize,
    queue_mutex: std.Thread.Mutex,
    thread: std.Thread,
    pub fn recv(self: *Connection, buf: []u8) !usize {
        const len = @min(self.queue.items.len, buf.len);
        @memcpy(buf[0..len], self.queue.items[0..len]);
        if (len < self.queue.items.len) {
            std.mem.copyForwards(&self.queue, self.queue[len..]);
        }
        self.queue_pos = 0;
        return len;
    }
    fn threadfunc(self: *Connection) !void {
        while (!main.done) {
        self.queue_pos += std.posix.read(self.socket, self.queue[self.queue_pos..])
        }
    }
};
sockets: std.ArrayList(Connection),
pub fn init() !Server {}
