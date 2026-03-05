const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const val = @import("value.zig");
const Value = val.ValueDataIndex;
const ValueTag = val.ValueTag;
const ConsCell = val.ConsCell;
const Closure = val.Closure;

pub const ScopeFor = @import("gc/gc_interface.zig").ScopeFor;
pub const GcAllocatorFor = @import("gc/gc_interface.zig").GcAllocatorFor;


pub const NoGc = @import("gc/nogc.zig");
pub const MarkAndSweepMemoryPool = @import("gc/memory_pool.zig");
pub const MarkAndSweepGPABacked = @import("gc/gpa_backed.zig");
pub const CopyingGC = @import("gc/copying.zig");

pub const GcAllocator = GcAllocatorFor(Value);

// --- Tests ---
const Scope = ScopeFor(Value);

test "NoGc: number round-trip" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const v = gc.alloc(f64, 3.14);
    try std.testing.expectEqual(ValueTag.number, v.tag);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), gc.getNumber(v.data), 0.001);
}

test "NoGc: cons round-trip" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const n1 = gc.alloc(f64, 1.0);
    const n2 = gc.alloc(f64, 2.0);
    const pair = gc.alloc(ConsCell, .{ .car = n1, .cdr = n2 });

    try std.testing.expectEqual(ValueTag.cons, pair.tag);
    try std.testing.expect(n1.eql(gc.getCar(pair.data)));
    try std.testing.expect(n2.eql(gc.getCdr(pair.data)));
}

test "NoGc: string round-trip" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const v = gc.alloc([]const u8, "hello");
    try std.testing.expectEqual(ValueTag.string, v.tag);
    try std.testing.expectEqualStrings("hello", gc.getString(v.data));
}

test "NoGc: vector round-trip" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const a = gc.alloc(f64, 1.0);
    const b = gc.alloc(f64, 2.0);
    const vec = gc.alloc([]const Value, &.{ a, b });

    try std.testing.expectEqual(ValueTag.vector, vec.tag);
    const items = gc.getVectorSlice(vec.data);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(a.eql(items[0]));
    try std.testing.expect(b.eql(items[1]));
}

test "NoGc: closure round-trip" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const params = val.nil_value;
    const body = val.nil_value;
    const v = gc.alloc(Closure, .{ .params = params, .body = body, .env_id = 0, .arity = 2 });

    try std.testing.expectEqual(ValueTag.closure, v.tag);
    const c = gc.getClosure(v.data);
    try std.testing.expect(params.eql(c.params));
    try std.testing.expectEqual(@as(u16, 2), c.arity);
}

test "NoGc: setCar/setCdr mutation" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const pair = gc.alloc(ConsCell, .{ .car = val.nil_value, .cdr = val.nil_value });
    const n = gc.alloc(f64, 42.0);

    gc.setCar(pair.data, n);
    gc.setCdr(pair.data, val.true_value);

    try std.testing.expect(n.eql(gc.getCar(pair.data)));
    try std.testing.expect(val.true_value.eql(gc.getCdr(pair.data)));
}

test "MarkAndSweep: all GC-able types are collected when unreachable" {
    const allocator = std.testing.allocator;
    var ms = MarkAndSweepGPABacked.init(allocator);
    defer ms.deinit();
    const gc = ms.gcAllocator();

    // Allocate one of every GC-managed type — none are rooted.
    _ = gc.alloc(f64, 3.14);
    _ = gc.alloc(ConsCell, .{ .car = val.nil_value, .cdr = val.nil_value });
    _ = gc.alloc(Closure, .{ .params = val.nil_value, .body = val.nil_value, .env_id = std.math.maxInt(usize), .arity = 0 });
    _ = gc.alloc([]const u8, "hello");
    _ = gc.alloc([]const Value, &[_]Value{val.nil_value});

    // Verify 5 objects are linked.
    var count: usize = 0;
    var cur = ms.first;
    while (cur) |gh| {
        count += 1;
        cur = gh.next;
    }
    try std.testing.expectEqual(@as(usize, 5), count);

    // No roots, no globals → everything is unreachable.
    ms.mark();
    ms.sweep();

    // Every object must have been freed — list must be empty.
    try std.testing.expectEqual(@as(?*MarkAndSweepGPABacked.GcHeader, null), ms.first);
}

test "MarkAndSweep: rooted objects survive, unreachable ones are collected" {
    const allocator = std.testing.allocator;
    var ms = MarkAndSweepGPABacked.init(allocator);
    defer ms.deinit();
    const gc = ms.gcAllocator();

    // Rooted: should survive.
    const kept_num = gc.alloc(f64, 1.0);
    gc.pushRoot(kept_num);
    const kept_str = gc.alloc([]const u8, "keep");
    gc.pushRoot(kept_str);

    // Unreachable: should be swept.
    _ = gc.alloc(f64, 99.0);
    _ = gc.alloc(ConsCell, .{ .car = val.nil_value, .cdr = val.nil_value });
    _ = gc.alloc(Closure, .{ .params = val.nil_value, .body = val.nil_value, .env_id = std.math.maxInt(usize), .arity = 0 });
    _ = gc.alloc([]const u8, "discard");
    _ = gc.alloc([]const Value, &[_]Value{val.nil_value});

    // Verify 7 objects are linked.
    var count: usize = 0;
    var cur = ms.first;
    while (cur) |gh| {
        count += 1;
        cur = gh.next;
    }
    try std.testing.expectEqual(@as(usize, 7), count);

    ms.mark();
    ms.sweep();

    // 2 rooted survive, 5 unreachable freed.
    var live: usize = 0;
    cur = ms.first;
    while (cur) |gh| {
        live += 1;
        cur = gh.next;
    }
    try std.testing.expectEqual(@as(usize, 2), live);

    gc.popRoot();
    gc.popRoot();
}

test "NoGc: pushRoot/popRoot" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    gc.pushRoot(val.nil_value);
    gc.pushRoot(val.true_value);
    try std.testing.expectEqual(@as(usize, 2), nogc.roots.items.len);
    gc.popRoot();
    try std.testing.expectEqual(@as(usize, 1), nogc.roots.items.len);
}
