const std = @import("std");
const coro = @import("zig_ev").coro;

pub fn main() !void {
    try coro.setupStackGrowth();
    defer coro.cleanupStackGrowth();

    // Both coroutines yield back to this scheduler's saved context.
    var parent_context: coro.Context = undefined;
    var coroutines = [_]coro.Coroutine{
        .{ .parent_context_ptr = &parent_context, .context = undefined },
        .{ .parent_context_ptr = &parent_context, .context = undefined },
    };

    // Reserve 8 MiB of virtual address space; initially commit 64 KiB.
    // ZIO grows the committed stack as needed.
    try coro.stackAlloc(&coroutines[0].context.stack_info, 8 * 1024 * 1024, 64 * 1024);
    defer coro.stackFree(coroutines[0].context.stack_info);
    try coro.stackAlloc(&coroutines[1].context.stack_info, 8 * 1024 * 1024, 64 * 1024);
    defer coro.stackFree(coroutines[1].context.stack_info);

    // A closure stores arguments and tracks when its function has returned.
    const Print = coro.Closure(print_callback);
    var closures = [_]Print{
        Print.init(.{@as(u8, 'A')}),
        Print.init(.{@as(u8, 'B')}),
    };
    for (&coroutines, &closures) |*coroutine, *closure| {
        coroutine.setup(&Print.start, closure);
    }

    // Each resume runs until the function yields or finishes.
    // Skip finished functions and stop when neither has work left.
    while (!closures[0].finished or !closures[1].finished) {
        for (&coroutines, &closures) |*coroutine, *closure| {
            if (!closure.finished) coroutine.step();
        }
    }
}

fn print_callback(coroutine: *coro.Coroutine, name: u8) void {
    for (1..101) |number| {
        std.debug.print("{c}: {d}\n", .{ name, number });
        coroutine.yield();
    }
}
