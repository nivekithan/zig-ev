const std = @import("std");
const Io = std.Io;

const zig_ev = @import("zig_ev");

const DoneTracker = struct {
    is_done: bool,
    fn init() DoneTracker {
        return .{ .is_done = false };
    }
    fn markItDone(self: *DoneTracker, result: i32) void {
        _ = result;
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
        zig_ev.EvLoop.Completion.init(DoneTracker, &done_tracker, DoneTracker.markItDone),
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
        request._completion = zig_ev.EvLoop.Completion.init(PutRequest, request, open_callback);

        try self.ev_loop.open(&request._completion, std.os.linux.AT.FDCWD, request.key.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o600);
    }

    fn open_callback(request: *PutRequest, res: i32) void {
        std.debug.print("open callback called key: {s}, value: {s}, res: {}\n", .{ request.key, request.value, res });
        if (res >= 0) _ = std.os.linux.close(res);
        request.on_done.callback(request.on_done.context, res);
    }
};

const Program = struct {
    ev_loop: *zig_ev.EvLoop,
    is_done: bool,
    file_fd: std.os.linux.fd_t,
    read_buffer: [6]u8,
    completion: zig_ev.EvLoop.Completion,

    fn init(ev_loop: *zig_ev.EvLoop) Program {
        const program = Program{ .ev_loop = ev_loop, .is_done = false, .read_buffer = undefined, .file_fd = 0, .completion = undefined };

        return program;
    }

    fn open_callback(self: *Program, res: i32) void {
        std.debug.print("From open callback {}\n", .{res});
        self.file_fd = res;

        self.completion = zig_ev.EvLoop.Completion.init(Program, self, write_callback);

        self.ev_loop.write(&self.completion, self.file_fd, "Hello\n", 0) catch unreachable;
        std.debug.print("queued write callback\n", .{});
    }

    fn write_callback(self: *Program, res: i32) void {
        std.debug.print("From write callback: {}\n", .{res});

        self.completion = zig_ev.EvLoop.Completion.init(Program, self, read_callback);

        self.ev_loop.read(&self.completion, self.file_fd, &self.read_buffer, 0) catch unreachable;
    }

    fn read_callback(self: *Program, res: i32) void {
        std.debug.print("From read callback: {}\n", .{res});

        std.debug.print("{s}", .{self.read_buffer});

        self.is_done = true;
    }

    fn run(self: *Program) !void {
        self.completion = zig_ev.EvLoop.Completion.init(Program, self, open_callback);

        try self.ev_loop.open(&self.completion, std.os.linux.AT.FDCWD, "test.txt", .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
        }, 0o600);

        while (!self.is_done) try self.ev_loop.run();
    }
};
