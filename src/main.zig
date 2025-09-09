const std = @import("std");
const clap = @import("clap");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
var stderr_buf: [1024]u8 = undefined;
var sock_buf: [1024]u8 = undefined;
pub var done: std.atomic.Value(bool) = .init(false);
var writer_mutex: std.Thread.Mutex = .{};
const Command = enum {
    none,
    playback,
    recording,
};
fn choose_device(cmd: Command, nameInput: ?[]const u8) !u32 {
    const devs = blk: {
        var output: std.ArrayList(u32) = try .initCapacity(std.heap.smp_allocator, 64);
        if (cmd != .recording) {
            var len: c_int = 0;
            const c_ptr = c.SDL_GetAudioPlaybackDevices(&len);
            if (c_ptr == null) {
                std.log.err("Failed to get recording devices: {s}", .{c.SDL_GetError()});
            } else {
                try output.appendSlice(std.heap.smp_allocator, c_ptr[0..@intCast(len)]);
            }
        }
        if (cmd != .playback) {
            var len: c_int = 0;
            const c_ptr = c.SDL_GetAudioRecordingDevices(&len);
            if (c_ptr == null) {
                std.log.err("Failed to get recording devices: {s}", .{c.SDL_GetError()});
            } else {
                try output.appendSlice(std.heap.smp_allocator, c_ptr[0..@intCast(len)]);
            }
        }

        if (output.items.len == 0) {
            return error.NoAudioDevices;
        }
        break :blk try output.toOwnedSlice(std.heap.smp_allocator);
    };
    if (cmd == .none) {
        return 0;
    }
    const chosen = blk: {
        var names: [][]const u8 = try std.heap.smp_allocator.alloc([]const u8, devs.len);
        defer std.heap.smp_allocator.free(names);
        for (devs, 0..) |dev, i| {
            const name = std.mem.sliceTo(c.SDL_GetAudioDeviceName(dev), 0);
            names[i] = name;
            std.log.info("Device ID {d}: {s}", .{ dev, name });
        }
        var argsIter = std.process.args();
        _ = argsIter.skip();
        var output: ?usize = null;
        if (nameInput) |v| {
            for (names, 0..) |name, i| {
                if (std.mem.eql(u8, name, v)) {
                    output = i;
                    break;
                }
            }
        } else {
            output = 0;
        }
        if (output) |i| {
            std.log.info("Chose device: {s} (ID: {d})", .{ names[i], devs[i] });
            break :blk devs[i];
        } else {
            return error.InvalidSelection;
        }
    };
    return chosen;
}
fn waitloop() !void {
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{
            .handler = &struct {
                fn callback(_: c_int) callconv(.c) void {
                    done.store(true, .release);
                }
            }.callback,
        },
        .flags = 0,
        .mask = std.posix.sigfillset(),
    }, null);
    {
        while (!done.load(.acquire)) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}
pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_AUDIO)) {
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();
    const spec: c.SDL_AudioSpec = .{
        .channels = 2,
        .format = c.SDL_AUDIO_F32BE,
        .freq = 48000,
    };
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Displays this help message.
        \\-n, --dev-name <str>      Sets the name of the device to use.
        \\-p, --port <u16>          Sets the port to use. Default: 6483
        \\-l, --list                Only list the devices available.
        \\-c, --connect <str>       Connect to a server and send it raw F32LE 2ch PCM audio.
        \\-L, --listen <str>        Listen for incomming connections and play back the audio.
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = std.heap.smp_allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };

    defer res.deinit();
    const con_addr: ?[]const u8 = res.args.connect;
    const listen = res.args.listen;
    const dev_name = res.args.@"dev-name";
    const binName = blk: {
        const path = try std.fs.selfExePathAlloc(std.heap.c_allocator);
        defer std.heap.c_allocator.free(path);
        break :blk try std.heap.c_allocator.dupeZ(u8, std.fs.path.stem(path));
    };
    defer std.heap.c_allocator.free(binName);
    if (res.args.help != 0) {
        var w2 = std.fs.File.stderr().writer(&stderr_buf);
        const w = &w2.interface;
        try w.print("{s} ", .{binName});
        try clap.usage(w, clap.Help, &params);
        try w.writeAll("\n");
        try clap.help(w, clap.Help, &params, .{});
        try w.flush();
        return;
    }
    if ((con_addr != null) == (listen != null)) {
        if (listen != null) { // and con_addr != null
            return error.TooManyCommands;
        } else if (res.args.list != 0) {
            if (dev_name != null) {
                std.log.warn("Specifying a device name when only listing out devices does nothing.", .{});
            }
            _ = try choose_device(.none, null);
            return;
        } else {
            var w2 = std.fs.File.stderr().writer(&stderr_buf);
            const w = &w2.interface;
            try w.writeAll("No command specified.\n");
            try w.print("{s} ", .{binName});
            try clap.usage(w, clap.Help, &params);
            try w.writeAll("\nAdd --help for help.\n");
            try w.flush();
            std.process.exit(1);
        }
    }
    const port: u16 = res.args.port orelse 6483;
    if (con_addr) |host| {
        var sock = try std.net.tcpConnectToHost(std.heap.smp_allocator, host, port);
        defer sock.close();
        var w = sock.writer(&sock_buf);
        const CallbackData = struct {
            buf: std.ArrayList(u8),
            w2: *std.io.Writer,
            last_error: anyerror!void = {},
            fn set_last_error(self: *@This(), err: anyerror) void {
                self.last_error = err;
                done.store(true, .release);
            }
            pub fn handle_stream(self: *@This(), stream: ?*c.SDL_AudioStream, avail: c_int, _: c_int) callconv(.c) void {
                self.buf.resize(std.heap.smp_allocator, @as(usize, @intCast(avail))) catch unreachable;
                self.buf.resize(std.heap.smp_allocator, @as(usize, @intCast(c.SDL_GetAudioStreamData(stream, @ptrCast(self.buf.items.ptr), @intCast(self.buf.items.len))))) catch unreachable;
                self.w2.writeAll(self.buf.items) catch unreachable;
                self.w2.flush() catch unreachable;
                self.buf.clearAndFree(std.heap.smp_allocator);
            }
            pub fn deinit(self: *@This()) void {
                done.store(true, .release);
                self.buf.deinit(std.heap.smp_allocator);
            }
            pub fn init(w2: *std.io.Writer) !@This() {
                return .{
                    .w2 = w2,
                    .buf = try .initCapacity(std.heap.smp_allocator, 64),
                };
            }
        };
        var ctx = try CallbackData.init(&w.interface);
        defer ctx.deinit();
        const chosen = try choose_device(.recording, dev_name);
        const stream = c.SDL_OpenAudioDeviceStream(chosen, &spec, @ptrCast(&CallbackData.handle_stream), @ptrCast(&ctx));
        defer c.SDL_DestroyAudioStream(stream);
        if (!c.SDL_ResumeAudioStreamDevice(stream)) {
            std.log.err("Resume failed: {s}", .{c.SDL_GetError()});
            return error.ResumeFailed;
        }
        try waitloop();
        try ctx.last_error;
    } else if (listen) |addr| {
        const address = try std.net.Address.resolveIp(addr, port);
        const tpe: u32 = std.posix.SOCK.STREAM;
        const proto = std.posix.IPPROTO.TCP;
        const listener = try std.posix.socket(address.any.family, tpe, proto);
        defer std.posix.close(listener);

        try std.posix.setsockopt(listener, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.posix.bind(listener, &address.any, address.getOsSockLen());
        try std.posix.listen(listener, 128);
        const CallbackData = struct {
            buf: [8192]u8 = undefined,
            buf_remainder: usize = 0,
            sock: std.posix.socket_t,
            last_error: anyerror!void = {},
            fn set_last_error(self: *@This(), err: anyerror) void {
                self.last_error = err;
                done.store(true, .release);
            }
            pub fn handle_stream(self: *@This(), stream: ?*c.SDL_AudioStream, _: c_int, _: c_int) callconv(.c) void {
                const recv_len = std.posix.read(self.sock, self.buf[self.buf_remainder..]) catch |err| return self.set_last_error(err);
                const full_len = recv_len + self.buf_remainder;
                self.buf_remainder = full_len % 8;
                _ = c.SDL_PutAudioStreamData(stream, &self.buf, @intCast(full_len - self.buf_remainder));
                std.mem.copyForwards(u8, self.buf[self.buf_remainder..], self.buf[full_len - self.buf_remainder .. full_len]);
            }
            pub fn deinit(_: *@This()) void {
                done.store(true, .release);
            }
            pub fn init(s: std.posix.socket_t) @This() {
                return .{
                    .sock = s,
                };
            }
        };
        const chosen = try choose_device(.playback, dev_name);
        var client_addr: std.net.Address = undefined;
        var client_addr_len: std.posix.socklen_t = @sizeOf(std.net.Address);
        const socket = try std.posix.accept(listener, &client_addr.any, &client_addr_len, 0);
        defer std.posix.close(socket);
        var ctx = CallbackData.init(socket);
        defer ctx.deinit();
        const stream = c.SDL_OpenAudioDeviceStream(chosen, &spec, @ptrCast(&CallbackData.handle_stream), @ptrCast(&ctx));
        defer c.SDL_DestroyAudioStream(stream);
        if (!c.SDL_ResumeAudioStreamDevice(stream)) {
            std.log.err("Resume failed: {s}", .{c.SDL_GetError()});
            return error.ResumeFailed;
        }
        try waitloop();
        try ctx.last_error;
    }
}
