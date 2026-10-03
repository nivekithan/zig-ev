const std = @import("std");
const Io = std.Io;

const zig_ev = @import("zig_ev");

const DoneTracker = struct {
    is_done: bool,
    fn init() DoneTracker {
        return .{ .is_done = false };
    }
    fn markItDone(self: *DoneTracker, result: i32) void {
        std.debug.print("[markItDoneCallback] result: {}", .{result});
        self.*.is_done = true;
    }
};

pub fn main() !void {
    var ev_loop = try zig_ev.EvLoop.init(32);
    defer ev_loop.deinit();
    var program = KvProgram.init(&ev_loop);
    var done_tracker = DoneTracker.init();

    var put_request = KvProgram.PutRequest.init(
        "test.txt",
        "world",
        ev_loop.completion(DoneTracker, &done_tracker, DoneTracker.markItDone),
    );

    try program.put_key(&put_request);

    while (!done_tracker.is_done) try ev_loop.run();
}

const KvProgram = struct {
    ev_loop: *zig_ev.EvLoop,

    fn init(ev_loop: *zig_ev.EvLoop) KvProgram {
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

    fn put_key(
        self: *KvProgram,
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
        std.debug.print("[write callback] key: {s}, value: {s}, res: {}\n", .{ request.key, request.value, res });

        request.on_done.callback(request.on_done.context, 1);
    }

    fn close_callback(request: *PutRequest, res: i32) void {
        std.debug.print("[close callback] key: {s}, value: {s}, res: {}\n", .{ request.key, request.value, res });

        request.on_done.callback(request.on_done.context, 1);
    }
};
