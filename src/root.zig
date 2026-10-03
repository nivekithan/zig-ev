//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const linux = std.os.linux;

pub const EvLoop = struct {
    ring: linux.IoUring,

    pub const Completion = struct {
        context: *anyopaque,
        callback: *const fn (*anyopaque, i32) void,
        /// The loop associated with this completion.
        ev_loop: *EvLoop,
    };

    pub fn completion(
        self: *EvLoop,
        comptime Context: type,
        state: *Context,
        comptime callback: *const fn (*Context, i32) void,
    ) Completion {
        return .{
            .ev_loop = self,
            .context = state,
            .callback = &struct {
                fn call(context: *anyopaque, result: i32) void {
                    const typed_state: *Context = @ptrCast(@alignCast(context));
                    callback(typed_state, result);
                }
            }.call,
        };
    }

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
        c: *Completion,
        dir_fd: linux.fd_t,
        path: [*:0]const u8,
        flags: linux.O,
        mode: std.posix.mode_t,
    ) !void {
        _ = try self.ring.openat(@intCast(@intFromPtr(c)), dir_fd, path, flags, mode);
        c.ev_loop = self;
    }

    /// Queues a positional read. The buffer must remain valid until completion.
    /// The callback receives bytes read (0 at EOF) or negative Linux errno.
    pub fn read(
        self: *EvLoop,
        c: *Completion,
        fd: linux.fd_t,
        buffer: []u8,
        offset: u64,
    ) !void {
        _ = try self.ring.read(@intCast(@intFromPtr(c)), fd, .{ .buffer = buffer }, offset);
        c.ev_loop = self;
    }

    /// Queues a positional write. The buffer must remain valid until completion.
    /// The callback receives bytes written (possibly short) or negative Linux errno.
    pub fn write(
        self: *EvLoop,
        c: *Completion,
        fd: linux.fd_t,
        buffer: []const u8,
        offset: u64,
    ) !void {
        _ = try self.ring.write(@intCast(@intFromPtr(c)), fd, buffer, offset);
        c.ev_loop = self;
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
                const c: *Completion = @ptrFromInt(@as(usize, @intCast(cqe.user_data)));
                c.callback(c.context, cqe.res);
            }
        }
    }
};
