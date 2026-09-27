//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const linux = std.os.linux;

pub const EvLoop = struct {
    ring: linux.IoUring,

    pub const Completion = struct { context: *anyopaque, callback: *const fn (*anyopaque, i32) void };

    pub fn init(entries: u16) !EvLoop {
        const ring = try linux.IoUring.init(entries, 0);

        return .{ .ring = ring };
    }

    pub fn deinit(self: *EvLoop) void {
        // Caller must finish all requests before destroying the ring.
        self.ring.deinit();
    }

    /// Queues an openat request. The path must remain valid until completion.
    /// The callback receives the file descriptor or negative Linux errno.
    pub fn open(
        self: *EvLoop,
        completion: *Completion,
        dir_fd: linux.fd_t,
        path: [*:0]const u8,
        flags: linux.O,
        mode: std.posix.mode_t,
    ) !void {
        _ = try self.ring.openat(@intCast(@intFromPtr(completion)), dir_fd, path, flags, mode);
    }

    /// Queues a positional read. The buffer must remain valid until completion.
    /// The callback receives bytes read (0 at EOF) or negative Linux errno.
    pub fn read(
        self: *EvLoop,
        completion: *Completion,
        fd: linux.fd_t,
        buffer: []u8,
        offset: u64,
    ) !void {
        _ = try self.ring.read(@intCast(@intFromPtr(completion)), fd, .{ .buffer = buffer }, offset);
    }

    /// Queues a positional write. The buffer must remain valid until completion.
    /// The callback receives bytes written (possibly short) or negative Linux errno.
    pub fn write(
        self: *EvLoop,
        completion: *Completion,
        fd: linux.fd_t,
        buffer: []const u8,
        offset: u64,
    ) !void {
        _ = try self.ring.write(@intCast(@intFromPtr(completion)), fd, buffer, offset);
    }

    /// Submits queued operations and calls back for every available completion.
    /// Returns the number of callbacks invoked; never waits for an unfinished I/O.
    pub fn run(self: *EvLoop) !void {
        _ = try self.ring.submit();

        var cqes: [32]linux.io_uring_cqe = undefined;
        while (true) {
            const count = try self.ring.copy_cqes(&cqes, 0);
            if (count == 0) break;

            for (cqes[0..count]) |cqe| {
                const completion: *Completion = @ptrFromInt(@as(usize, @intCast(cqe.user_data)));
                completion.callback(completion.context, cqe.res);
            }
        }
    }
};

test "open/write/read" {
    const Callbacks = struct {
        const data = "hello";
        var loop: *EvLoop = undefined;
        var fd: ?linux.fd_t = null;
        var buffer: [data.len]u8 = undefined;
        var failure: ?anyerror = null;
        var done = false;

        fn onOpen(result: i32) void {
            if (result < 0) {
                failure = error.OpenFailed;
                done = true;
                return;
            }
            fd = @intCast(result);
            loop.write(onWrite, fd.?, data, 10) catch |err| {
                failure = err;
                done = true;
            };
        }

        fn onWrite(result: i32) void {
            if (result != data.len) {
                failure = error.WriteFailed;
                done = true;
                return;
            }
            loop.read(onRead, fd.?, &buffer, 10) catch |err| {
                failure = err;
                done = true;
            };
        }

        fn onRead(result: i32) void {
            if (result != data.len) {
                failure = error.ReadFailed;
                done = true;
                return;
            }
            std.testing.expectEqualStrings(data, &buffer) catch |err| {
                failure = err;
            };
            done = true;
        }
    };
    Callbacks.fd = null;
    Callbacks.failure = null;
    Callbacks.done = false;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loop = try EvLoop.init(8);
    defer loop.deinit();
    Callbacks.loop = &loop;
    defer if (Callbacks.fd) |fd| {
        _ = linux.close(fd);
    };

    try loop.open(Callbacks.onOpen, tmp.dir.handle, "data", .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .TRUNC = true,
    }, 0o600);
    for (0..1_000_000) |_| {
        if (Callbacks.done) break;
        try loop.run();
    }
    try std.testing.expect(Callbacks.done);
    if (Callbacks.failure) |err| return err;
}
