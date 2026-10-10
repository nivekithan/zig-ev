const std = @import("std");
const Io = std.Io;

const zig_ev = @import("zig_ev");

const DoneTracker = struct {
    is_done: bool,

    fn init() DoneTracker {
        return .{ .is_done = false };
    }

    fn mark_it_done(self: *DoneTracker, result: i32) void {
        std.debug.print("[markItDoneCallback] result: {}", .{result});
        self.*.is_done = true;
    }
};

pub fn main() !void {
    var ev_loop = try zig_ev.EvLoop.init(32);
    defer ev_loop.deinit();
    var echo_server = EchoServer.init(&ev_loop, std.heap.page_allocator);
    var server = TcpServer.init(
        &ev_loop,
        9090,
        ev_loop.completion(EchoServer, &echo_server, EchoServer.on_connection),
    );

    try server.start();
    while (true) try ev_loop.run();
}

const TcpServer = struct {
    ev_loop: *zig_ev.EvLoop,
    address: std.os.linux.sockaddr.in,
    fd: std.os.linux.fd_t = undefined,
    completion: zig_ev.EvLoop.Completion = undefined,
    on_connection: zig_ev.EvLoop.Completion,

    fn init(ev_loop: *zig_ev.EvLoop, port: u16, on_connection: zig_ev.EvLoop.Completion) TcpServer {
        return .{
            .ev_loop = ev_loop,
            .on_connection = on_connection,
            .address = .{
                .port = std.mem.nativeToBig(u16, port),
                .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
            },
        };
    }

    fn start(self: *TcpServer) !void {
        self.completion = self.ev_loop.completion(TcpServer, self, socket_callback);
        try self.ev_loop.socket(
            &self.completion,
            std.os.linux.AF.INET,
            std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC,
            std.os.linux.IPPROTO.TCP,
            0,
        );
    }

    fn socket_callback(self: *TcpServer, res: i32) void {
        std.debug.assert(self.completion.operation == .socket);
        std.debug.assert(res >= 0);
        self.fd = res;

        self.completion = self.ev_loop.completion(TcpServer, self, bind_callback);
        self.ev_loop.bind(
            &self.completion,
            self.fd,
            @ptrCast(&self.address),
            @sizeOf(std.os.linux.sockaddr.in),
            0,
        ) catch @panic("failed to queue bind");
    }

    fn bind_callback(self: *TcpServer, res: i32) void {
        std.debug.assert(self.completion.operation == .bind);
        std.debug.assert(res == 0);

        self.completion = self.ev_loop.completion(TcpServer, self, listen_callback);
        self.ev_loop.listen(&self.completion, self.fd, 511, 0) catch @panic("failed to queue listen");
    }

    fn listen_callback(self: *TcpServer, res: i32) void {
        std.debug.assert(self.completion.operation == .listen);
        std.debug.assert(res == 0);

        std.debug.print("Listening on 127.0.0.1:{d}\n", .{std.mem.bigToNative(u16, self.address.port)});

        self.completion = self.ev_loop.completion(TcpServer, self, accept_callback);
        self.ev_loop.accept(&self.completion, self.fd, null, null, std.os.linux.SOCK.CLOEXEC) catch
            @panic("failed to queue accept");
    }

    fn accept_callback(self: *TcpServer, res: i32) void {
        std.debug.assert(self.completion.operation == .accept);
        std.debug.assert(res >= 0);

        // Hand ownership of the client socket to the connection callback.
        self.on_connection.callback(self.on_connection.context, res);
        self.completion = self.ev_loop.completion(TcpServer, self, accept_callback);
        self.ev_loop.accept(&self.completion, self.fd, null, null, std.os.linux.SOCK.CLOEXEC) catch
            @panic("failed to queue accept");
    }
};

const EchoServer = struct {
    ev_loop: *zig_ev.EvLoop,
    allocator: std.mem.Allocator,

    const Connection = struct {
        allocator: std.mem.Allocator,
        completion: zig_ev.EvLoop.Completion = undefined,
        buffer: [4096]u8 = undefined,
    };

    fn init(ev_loop: *zig_ev.EvLoop, allocator: std.mem.Allocator) EchoServer {
        return .{ .ev_loop = ev_loop, .allocator = allocator };
    }

    fn on_connection(self: *EchoServer, res: i32) void {
        std.debug.assert(res >= 0);
        const connection = self.allocator.create(Connection) catch
            @panic("failed to allocate connection");
        connection.* = .{ .allocator = self.allocator };
        connection.completion = self.ev_loop.completion(Connection, connection, recv_callback);
        self.ev_loop.recv(&connection.completion, res, &connection.buffer, 0) catch
            @panic("failed to queue recv");
    }

    fn recv_callback(self: *Connection, res: i32) void {
        std.debug.assert(self.completion.operation == .recv);
        std.debug.assert(res >= 0);

        const input = self.completion.operation.recv;
        const ev_loop = self.completion.ev_loop;

        if (res == 0) {
            self.completion = ev_loop.completion(Connection, self, close_callback);
            ev_loop.close(&self.completion, input.fd) catch
                @panic("failed to queue client close");
            return;
        }

        self.completion = ev_loop.completion(Connection, self, send_callback);
        ev_loop.send(&self.completion, input.fd, input.buffer[0..@intCast(res)], std.os.linux.MSG.NOSIGNAL) catch
            @panic("failed to queue send");
    }

    fn send_callback(self: *Connection, res: i32) void {
        std.debug.assert(self.completion.operation == .send);
        std.debug.assert(res > 0);

        const input = self.completion.operation.send;
        const ev_loop = self.completion.ev_loop;
        const sent: usize = @intCast(res);
        std.debug.assert(sent <= input.buffer.len);

        if (sent < input.buffer.len) {
            self.completion = ev_loop.completion(Connection, self, send_callback);
            ev_loop.send(&self.completion, input.fd, input.buffer[sent..], std.os.linux.MSG.NOSIGNAL) catch
                @panic("failed to queue send");
            return;
        }

        self.completion = ev_loop.completion(Connection, self, recv_callback);
        ev_loop.recv(&self.completion, input.fd, &self.buffer, 0) catch
            @panic("failed to queue recv");
    }

    fn close_callback(self: *Connection, res: i32) void {
        std.debug.assert(self.completion.operation == .close);
        std.debug.assert(res == 0);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn kv_example() !void {
    var ev_loop = try zig_ev.EvLoop.init(32);
    defer ev_loop.deinit();
    var program = KvEngine.init(&ev_loop);
    var done_tracker = DoneTracker.init();

    var put_request = KvEngine.PutRequest.init(
        "test.txt",
        "world",
        ev_loop.completion(DoneTracker, &done_tracker, DoneTracker.mark_it_done),
    );

    try program.put_key(&put_request);

    while (!done_tracker.is_done) try ev_loop.run();

    done_tracker.is_done = false;
    var buffer: [64]u8 = undefined;
    var get_request = KvEngine.GetRequest.init(
        "test.txt",
        &buffer,
        ev_loop.completion(DoneTracker, &done_tracker, DoneTracker.mark_it_done),
    );

    try program.get_key(&get_request);
    while (!done_tracker.is_done) try ev_loop.run();

    std.debug.print("\n[get result] {s}\n", .{get_request.buffer[0..get_request.bytes_read]});
}

const KvEngine = struct {
    ev_loop: *zig_ev.EvLoop,

    fn init(ev_loop: *zig_ev.EvLoop) KvEngine {
        return .{ .ev_loop = ev_loop };
    }

    const PutRequest = struct {
        key: [:0]const u8,
        value: []const u8,
        on_done: zig_ev.EvLoop.Completion,

        /// PRIVATE DON'T USE THESE
        _completion: zig_ev.EvLoop.Completion = undefined,

        fn init(key: [:0]const u8, value: []const u8, on_done: zig_ev.EvLoop.Completion) PutRequest {
            return .{ .key = key, .value = value, .on_done = on_done };
        }
    };

    const GetRequest = struct {
        key: [:0]const u8,
        buffer: []u8,
        bytes_read: usize = 0,
        on_done: zig_ev.EvLoop.Completion,

        /// PRIVATE DON'T USE THESE
        _completion: zig_ev.EvLoop.Completion = undefined,

        fn init(key: [:0]const u8, buffer: []u8, on_done: zig_ev.EvLoop.Completion) GetRequest {
            return .{ .key = key, .buffer = buffer, .on_done = on_done };
        }
    };

    /// Reads once into the caller's buffer. Request and buffer must stay alive
    /// until on_done, which receives the byte count. Assumes all I/O succeeds.
    fn get_key(self: *KvEngine, request: *GetRequest) !void {
        request.bytes_read = 0;
        request._completion = self.ev_loop.completion(GetRequest, request, get_open_callback);
        try self.ev_loop.open(&request._completion, std.os.linux.AT.FDCWD, request.key.ptr, .{ .ACCMODE = .RDONLY }, 0);
    }

    fn get_open_callback(request: *GetRequest, res: i32) void {
        std.debug.assert(request._completion.operation == .open);
        std.debug.print("[get open callback] key: {s}, res: {}\n", .{ request.key, res });

        const ev_loop = request._completion.ev_loop;
        request._completion = ev_loop.completion(GetRequest, request, get_read_callback);
        ev_loop.read(&request._completion, res, request.buffer, 0) catch {
            @panic("failed to queue get read");
        };
    }

    fn get_read_callback(request: *GetRequest, res: i32) void {
        std.debug.assert(request._completion.operation == .read);
        std.debug.print("[get read callback] key: {s}, res: {}\n", .{ request.key, res });
        request.bytes_read = @intCast(res);

        const input = request._completion.operation.read;
        const ev_loop = request._completion.ev_loop;
        request._completion = ev_loop.completion(GetRequest, request, get_close_callback);
        ev_loop.close(&request._completion, input.fd) catch {
            @panic("failed to queue get close");
        };
    }

    fn get_close_callback(request: *GetRequest, res: i32) void {
        std.debug.assert(request._completion.operation == .close);
        std.debug.print("[get close callback] key: {s}, res: {}\n", .{ request.key, res });

        request.on_done.callback(request.on_done.context, @intCast(request.bytes_read));
    }

    fn put_key(
        self: *KvEngine,
        request: *PutRequest,
    ) !void {
        request._completion = self.ev_loop.completion(PutRequest, request, open_callback);

        try self.ev_loop.open(&request._completion, std.os.linux.AT.FDCWD, request.key.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o600);
    }

    fn open_callback(request: *PutRequest, res: i32) void {
        std.debug.print("[open callback] key: {s}, value: {s}, res: {}\n", .{ request.key, request.value, res });

        const ev_loop = request._completion.ev_loop;

        request._completion = ev_loop.completion(PutRequest, request, write_callback);

        ev_loop.write(&request._completion, res, request.value, 0) catch {
            @panic("failed to create write callback");
        };
    }

    fn write_callback(request: *PutRequest, res: i32) void {
        std.debug.assert(request._completion.operation == .write);

        std.debug.print("[write callback] key: {s}, value: {s}, res: {}\n", .{ request.key, request.value, res });

        const input = request._completion.operation.write;
        const ev_loop = request._completion.ev_loop;

        request._completion = ev_loop.completion(PutRequest, request, close_callback);

        ev_loop.close(&request._completion, input.fd) catch {
            @panic("failed to create close callback");
        };
    }

    fn close_callback(request: *PutRequest, res: i32) void {
        std.debug.print("[close callback] key: {s}, value: {s}, res: {}\n", .{ request.key, request.value, res });

        request.on_done.callback(request.on_done.context, 1);
    }
};
