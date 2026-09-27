const std = @import("std");
const Io = std.Io;

const zig_ev = @import("zig_ev");

pub fn main() !void {
    var ev_loop = try zig_ev.EvLoop.init(32);
    var program = Program.init(&ev_loop);

    try program.run();
}

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

    fn callback_earsed(comptime callback: *const fn (*Program, i32) void) *const fn (*anyopaque, i32) void {
        return &struct {
            fn call(context: *anyopaque, result: i32) void {
                const program: *Program = @ptrCast(@alignCast(context));
                callback(program, result);
            }
        }.call;
    }

    fn open_callback(self: *Program, res: i32) void {
        std.debug.print("From open callback {}\n", .{res});
        self.file_fd = res;

        self.completion = zig_ev.EvLoop.Completion{ .context = self, .callback = callback_earsed(write_callback) };

        self.ev_loop.write(&self.completion, self.file_fd, "Hello\n", 0) catch unreachable;
        std.debug.print("queued write callback\n", .{});
    }

    fn write_callback(self: *Program, res: i32) void {
        std.debug.print("From write callback: {}\n", .{res});

        self.completion = zig_ev.EvLoop.Completion{ .context = self, .callback = callback_earsed(read_callback) };

        self.ev_loop.read(&self.completion, self.file_fd, &self.read_buffer, 0) catch unreachable;
    }

    fn read_callback(self: *Program, res: i32) void {
        std.debug.print("From read callback: {}\n", .{res});

        std.debug.print("{s}", .{self.read_buffer});

        self.is_done = true;
    }

    fn run(self: *Program) !void {
        self.completion = zig_ev.EvLoop.Completion{ .context = self, .callback = callback_earsed(open_callback) };

        try self.ev_loop.open(&self.completion, std.os.linux.AT.FDCWD, "test.txt", .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
        }, 0o600);

        while (!self.is_done) try self.ev_loop.run();
    }
};
