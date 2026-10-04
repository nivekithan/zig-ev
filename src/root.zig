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
        /// Inputs to the last queued operation. Paths and buffers are borrowed.
        operation: Operation = .none,

        pub const Operation = union(enum) {
            none,
            open: struct {
                dir_fd: linux.fd_t,
                path: [*:0]const u8,
                flags: linux.O,
                mode: std.posix.mode_t,
            },
            read: struct {
                fd: linux.fd_t,
                buffer: []u8,
                offset: u64,
            },
            write: struct {
                fd: linux.fd_t,
                buffer: []const u8,
                offset: u64,
            },
            close: struct {
                fd: linux.fd_t,
            },
            socket: struct {
                domain: u32,
                socket_type: u32,
                protocol: u32,
                flags: u32,
            },
            bind: struct {
                fd: linux.fd_t,
                addr: *const std.posix.sockaddr,
                addrlen: std.posix.socklen_t,
                flags: u32,
            },
        };
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
        c.operation = .{ .open = .{ .dir_fd = dir_fd, .path = path, .flags = flags, .mode = mode } };
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
        c.operation = .{ .read = .{ .fd = fd, .buffer = buffer, .offset = offset } };
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
        c.operation = .{ .write = .{ .fd = fd, .buffer = buffer, .offset = offset } };
    }

    /// Queues a close request. The completion must remain valid until completion.
    /// The callback receives 0 on success or negative Linux errno.
    pub fn close(self: *EvLoop, c: *Completion, fd: linux.fd_t) !void {
        _ = try self.ring.close(@intCast(@intFromPtr(c)), fd);
        c.ev_loop = self;
        c.operation = .{ .close = .{ .fd = fd } };
    }

    /// Queues socket creation. The completion must remain valid until completion.
    /// The callback receives the socket descriptor or negative Linux errno.
    /// flags are io_uring socket operation flags; use socket_type for SOCK flags.
    pub fn socket(
        self: *EvLoop,
        c: *Completion,
        domain: u32,
        socket_type: u32,
        protocol: u32,
        flags: u32,
    ) !void {
        _ = try self.ring.socket(@intCast(@intFromPtr(c)), domain, socket_type, protocol, flags);
        c.ev_loop = self;
        c.operation = .{ .socket = .{ .domain = domain, .socket_type = socket_type, .protocol = protocol, .flags = flags } };
    }

    /// Queues a bind request. The address and completion must remain valid until completion.
    /// The callback receives 0 on success or negative Linux errno. Pass 0 for flags.
    pub fn bind(
        self: *EvLoop,
        c: *Completion,
        fd: linux.fd_t,
        addr: *const std.posix.sockaddr,
        addrlen: std.posix.socklen_t,
        flags: u32,
    ) !void {
        _ = try self.ring.bind(@intCast(@intFromPtr(c)), fd, addr, addrlen, flags);
        c.ev_loop = self;
        c.operation = .{ .bind = .{ .fd = fd, .addr = addr, .addrlen = addrlen, .flags = flags } };
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
