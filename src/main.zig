const std = @import("std");
const Io = std.Io;

const zig_ev = @import("zig_ev");

pub fn main() !void {
    var ev_loop = try zig_ev.EvLoop.init(32);
    defer ev_loop.deinit();
    var engine = KvEngine.init(&ev_loop);
    var kv_server = KVServer.init(&ev_loop, &engine, std.heap.page_allocator);
    var server = TcpServer.init(
        &ev_loop,
        9090,
        ev_loop.completion(KVServer, &kv_server, KVServer.on_connection),
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

const KVServer = struct {
    ev_loop: *zig_ev.EvLoop,
    engine: *KvEngine,
    allocator: std.mem.Allocator,

    const Connection = struct {
        server: *KVServer,
        fd: std.os.linux.fd_t,
        completion: zig_ev.EvLoop.Completion = undefined,
        input: [4096]u8 = undefined,
        received: usize = 0,
        key: [255:0]u8 = undefined,
        value: [4096]u8 = undefined,
        response: [4128]u8 = undefined,
        request: union(enum) {
            none,
            get: KvEngine.GetRequest,
            put: KvEngine.PutRequest,
        } = .none,
    };

    fn init(ev_loop: *zig_ev.EvLoop, engine: *KvEngine, allocator: std.mem.Allocator) KVServer {
        return .{ .ev_loop = ev_loop, .engine = engine, .allocator = allocator };
    }

    fn on_connection(self: *KVServer, fd: i32) void {
        std.debug.assert(fd >= 0);
        const connection = self.allocator.create(Connection) catch
            @panic("failed to allocate KV connection");
        connection.* = .{ .server = self, .fd = fd };
        connection.completion = self.ev_loop.completion(Connection, connection, recv_callback);
        self.ev_loop.recv(&connection.completion, fd, &connection.input, 0) catch
            @panic("failed to queue KV recv");
    }

    fn recv_callback(connection: *Connection, res: i32) void {
        std.debug.assert(connection.completion.operation == .recv);
        std.debug.assert(res >= 0);
        if (res == 0) {
            close_connection(connection);
            return;
        }

        connection.received += @intCast(res);
        const bytes = connection.input[0..connection.received];
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |end| {
            process_request(connection, bytes[0..end]);
            return;
        }
        if (connection.received == connection.input.len) {
            send_response(connection, "ERROR request too large\n");
            return;
        }

        const ev_loop = connection.server.ev_loop;
        connection.completion = ev_loop.completion(Connection, connection, recv_callback);
        ev_loop.recv(&connection.completion, connection.fd, connection.input[connection.received..], 0) catch
            @panic("failed to queue KV recv");
    }

    const ParsedRequest = struct {
        operation: enum { get, put },
        key: []const u8,
        value: []const u8,
    };

    const ParseError = error{ InvalidOperation, MissingValue, InvalidKey };

    /// Returned slices borrow the input line; parsing does not allocate or perform I/O.
    fn parse_request(line: []const u8) ParseError!ParsedRequest {
        const is_put = std.mem.startsWith(u8, line, "PUT ");
        const is_get = std.mem.startsWith(u8, line, "GET ");
        if (!is_put and !is_get) {
            return error.InvalidOperation;
        }

        const arguments = line[4..];
        const key_end = if (is_put) std.mem.indexOfScalar(u8, arguments, ' ') orelse {
            return error.MissingValue;
        } else arguments.len;

        const key = arguments[0..key_end];
        if (key.len == 0 or key.len > 255) {
            return error.InvalidKey;
        }

        return .{
            .operation = if (is_put) .put else .get,
            .key = key,
            .value = if (is_put) arguments[key_end + 1 ..] else "",
        };
    }

    fn process_request(connection: *Connection, line: []const u8) void {
        const parsed = parse_request(line) catch |err| {
            send_response(connection, switch (err) {
                error.InvalidOperation => "ERROR expected GET or PUT\n",
                error.MissingValue => "ERROR expected key and value\n",
                error.InvalidKey => "ERROR invalid key\n",
            });
            return;
        };
        @memcpy(connection.key[0..parsed.key.len], parsed.key);
        connection.key[parsed.key.len] = 0;

        const path = connection.key[0..parsed.key.len :0];
        const server = connection.server;

        if (parsed.operation == .put) {
            connection.request = .{ .put = KvEngine.PutRequest.init(
                path,
                parsed.value,
                server.ev_loop.completion(Connection, connection, put_done),
            ) };
            server.engine.put_key(&connection.request.put) catch
                @panic("failed to start KV put");
            return;
        }

        connection.request = .{ .get = KvEngine.GetRequest.init(
            path,
            &connection.value,
            server.ev_loop.completion(Connection, connection, get_done),
        ) };
        server.engine.get_key(&connection.request.get) catch
            @panic("failed to start KV get");
    }

    fn put_done(connection: *Connection, res: i32) void {
        _ = res;
        send_response(connection, "OK\n");
    }

    fn get_done(connection: *Connection, res: i32) void {
        std.debug.assert(res >= 0);
        const length = connection.request.get.bytes_read;
        const response = std.fmt.bufPrint(&connection.response, "VALUE {d}\n{s}", .{
            length, connection.value[0..length],
        }) catch @panic("KV response buffer too small");
        send_response(connection, response);
    }

    fn send_response(connection: *Connection, bytes: []const u8) void {
        const ev_loop = connection.server.ev_loop;
        connection.completion = ev_loop.completion(Connection, connection, send_callback);
        ev_loop.send(&connection.completion, connection.fd, bytes, std.os.linux.MSG.NOSIGNAL) catch
            @panic("failed to queue KV send");
    }

    fn send_callback(connection: *Connection, res: i32) void {
        std.debug.assert(connection.completion.operation == .send);
        std.debug.assert(res > 0);

        const input = connection.completion.operation.send;
        const sent: usize = @intCast(res);
        std.debug.assert(sent <= input.buffer.len);

        if (sent < input.buffer.len) {
            send_response(connection, input.buffer[sent..]);
            return;
        }
        close_connection(connection);
    }

    fn close_connection(connection: *Connection) void {
        const ev_loop = connection.server.ev_loop;
        connection.completion = ev_loop.completion(Connection, connection, close_callback);
        ev_loop.close(&connection.completion, connection.fd) catch
            @panic("failed to queue KV client close");
    }

    fn close_callback(connection: *Connection, res: i32) void {
        std.debug.assert(connection.completion.operation == .close);
        std.debug.assert(res == 0);

        const allocator = connection.server.allocator;
        allocator.destroy(connection);
    }
};

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
