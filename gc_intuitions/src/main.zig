const std = @import("std");
const garbage = @import("garbage");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("Memory Leaked!");
    }

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: garbage -bgc | -rc\n", .{});
        return;
    }

    const mode = args[1];
    if (std.mem.eql(u8, mode, "-bgc")) {
        runMarkSweepTest(allocator);
    } else if (std.mem.eql(u8, mode, "-rc")) {
        runRefcountTest(allocator);
    } else {
        std.debug.print("Unknown flag: {s}\nUsage: garbage -bgc | -rc\n", .{mode});
    }
}

fn runMarkSweepTest(allocator: std.mem.Allocator) void {
    std.log.info("Starting mark-sweep GC test", .{});

    var vm = garbage.VM.init(allocator);

    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        std.log.info("\n--- Iteration {d} ---", .{i});

        vm.pushInt(i) catch unreachable;
        vm.pushInt(i + 100) catch unreachable;
        vm.pushInt(i + 200) catch unreachable;

        std.log.info("\n--- Surprise gc {d} ---", .{i});
        vm.gc();

        _ = vm.pushPair() catch unreachable;

        if (@mod(i, 3) == 2) {
            const objectsToKeep: usize = if (@mod(i, 6) == 2) 1 else 2;
            std.log.info("Popping objects but keeping {d} on stack...", .{objectsToKeep});

            while (vm.stackSize > objectsToKeep) {
                _ = vm.pop();
            }

            std.log.info("Stack now has {d} objects, triggering GC...", .{vm.stackSize});
            vm.gc();
            std.log.info("After GC, stack still has {d} objects (should be same)", .{vm.stackSize});
        }
    }

    std.log.info("\n--- Clearing stack ---", .{});
    while (vm.stackSize > 0) {
        _ = vm.pop();
    }

    std.log.info("--- Final GC ---", .{});
    vm.gc();

    std.log.info("Test complete!", .{});
}

fn runRefcountTest(allocator: std.mem.Allocator) void {
    std.log.info("Starting reference counting test", .{});

    var vm = garbage.rc.VM.init(allocator);

    // Create some integers
    var a = vm.createInt(1);
    var b = vm.createInt(2);
    const c = vm.createInt(3);
    std.log.info("Created ints: a=1 b=2 c=3", .{});

    // Create a pair (a, b) — this retains a and b
    const pair1 = vm.createPair(a, b);
    std.log.info("Created pair1=(a, b), a.count={d} b.count={d}", .{ a.count, b.count });

    // Create a nested pair (pair1, c)
    const pair2 = vm.createPair(pair1, c);
    std.log.info("Created pair2=(pair1, c), pair1.count={d} c.count={d}", .{ pair1.count, c.count });

    // Test assign: reassign a to point to c
    a = vm.assign(a, c);
    std.log.info("After assign a=c: a.count={d} (old a freed if count hit 0)", .{ a.count });

    // Test assign: reassign b to point to c
    b = vm.assign(b, c);
    std.log.info("After assign b=c: b.count={d}", .{ b.count });

    // Release our local references
    vm.release(a);
    vm.release(b);
    vm.release(c);
    std.log.info("Released a, b, c locals", .{});

    // Release the pairs — this should cascade and free everything
    vm.release(pair1);
    std.log.info("Released pair1", .{});
    vm.release(pair2);
    std.log.info("Released pair2 — all memory should be freed", .{});

    std.log.info("Test complete!", .{});
}
