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
