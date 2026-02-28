const std = @import("std");
const val = @import("value.zig");
const Value = val.Value;
const ValueTag = val.ValueTag;
const ConsCell = val.ConsCell;
const Closure = val.Closure;
const Allocator = std.mem.Allocator;

/// Fat-pointer GC interface, modeled after std.mem.Allocator.
/// Backends implement the VTable; the interpreter calls typed wrappers
/// that derive the ValueTag from the comptime type.
pub const GcAllocator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        rawAlloc: *const fn (*anyopaque, ValueTag, *const anyopaque) Value,
        rawGet: *const fn (*anyopaque, ValueTag, u24) *anyopaque,
        pushRoot: *const fn (*anyopaque, Value) void,
        popRoot: *const fn (*anyopaque) void,
        writeBarrier: *const fn (*anyopaque, Value, Value) void,
        collectGarbage: *const fn (*anyopaque) void,
    };

    /// Allocate a GC-managed object. Tag derived from comptime type.
    /// Supported: f64, ConsCell, Closure, []const u8, []const Value
    pub fn alloc(self: GcAllocator, comptime T: type, data: T) Value {
        const tag = comptime typeToTag(T);
        return self.vtable.rawAlloc(self.ptr, tag, @ptrCast(&data));
    }

    /// Get a mutable pointer to stored object by type and payload index.
    pub fn get(self: GcAllocator, comptime T: type, payload: u24) *T {
        const tag = comptime typeToTag(T);
        return @ptrCast(@alignCast(self.vtable.rawGet(self.ptr, tag, payload)));
    }

    // --- Cons convenience ---
    pub fn getCar(self: GcAllocator, idx: u24) Value {
        return self.get(ConsCell, idx).car;
    }
    pub fn getCdr(self: GcAllocator, idx: u24) Value {
        return self.get(ConsCell, idx).cdr;
    }
    pub fn setCar(self: GcAllocator, idx: u24, v: Value) void {
        self.get(ConsCell, idx).car = v;
    }
    pub fn setCdr(self: GcAllocator, idx: u24, v: Value) void {
        self.get(ConsCell, idx).cdr = v;
    }

    // --- Scalar convenience ---
    pub fn getNumber(self: GcAllocator, idx: u24) f64 {
        return self.get(f64, idx).*;
    }
    pub fn getClosure(self: GcAllocator, idx: u24) *Closure {
        return self.get(Closure, idx);
    }
    pub fn getString(self: GcAllocator, idx: u24) []const u8 {
        return self.get([]const u8, idx).*;
    }
    pub fn getVectorSlice(self: GcAllocator, idx: u24) []Value {
        return self.get([]Value, idx).*;
    }

    // --- Root / barrier / collect ---
    pub fn pushRoot(self: GcAllocator, root: Value) void {
        self.vtable.pushRoot(self.ptr, root);
    }
    pub fn popRoot(self: GcAllocator) void {
        self.vtable.popRoot(self.ptr);
    }
    pub fn writeBarrier(self: GcAllocator, parent: Value, child: Value) void {
        self.vtable.writeBarrier(self.ptr, parent, child);
    }
    pub fn collectGarbage(self: GcAllocator) void {
        self.vtable.collectGarbage(self.ptr);
    }

    fn typeToTag(comptime T: type) ValueTag {
        if (T == f64) return .number;
        if (T == ConsCell) return .cons;
        if (T == Closure) return .closure;
        if (T == []const u8) return .string;
        if (T == []const Value) return .vector;
        if (T == []Value) return .vector;
        @compileError("unsupported GC type: " ++ @typeName(T));
    }
};

const MarkAndSweepGPABacked = struct {
    gpa: Allocator,
    roots: std.ArrayList(Header),

    const Header = struct {
        // todo dont know what I need here exactly
        val: Value,
        size: usize,
    };
    // todo alloc
    // todo free (is a real free with the gpa
    // garbage collect after a certain number of allocation calls
    fn init(gpa: Allocator) MarkAndSweepGPABacked {
        // make gpa
        return MarkAndSweepGPABacked{
            .gpa = gpa,
            .roots = std.ArrayList(Header).initCapacity(gpa, 16),
        };
    }

    // return interface
};

/// Trivial non-collecting backend. Arena-backed pools, never reclaims.
pub const NoGc = struct {
    arena: std.heap.ArenaAllocator,
    numbers: std.ArrayList(f64),
    cons_cells: std.ArrayList(ConsCell),
    closures: std.ArrayList(Closure),
    strings: std.ArrayList([]const u8),
    vectors: std.ArrayList([]Value),
    roots: std.ArrayList(Value),

    pub fn init(backing: std.mem.Allocator) NoGc {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .numbers = .{},
            .cons_cells = .{},
            .closures = .{},
            .strings = .{},
            .vectors = .{},
            .roots = .{},
        };
    }

    pub fn deinit(self: *NoGc) void {
        self.arena.deinit();
    }

    pub fn gcAllocator(self: *NoGc) GcAllocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = GcAllocator.VTable{
        .rawAlloc = rawAlloc,
        .rawGet = rawGet,
        .pushRoot = pushRootFn,
        .popRoot = popRootFn,
        .writeBarrier = writeBarrierFn,
        .collectGarbage = collectGarbageFn,
    };

    fn a(self: *NoGc) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn rawAlloc(ctx: *anyopaque, tag: ValueTag, data: *const anyopaque) Value {
        const self: *NoGc = @ptrCast(@alignCast(ctx));
        const alloc = self.a();
        const payload: u24 = switch (tag) {
            .number => appendPool(f64, &self.numbers, alloc, data),
            .cons => appendPool(ConsCell, &self.cons_cells, alloc, data),
            .closure => appendPool(Closure, &self.closures, alloc, data),
            .string => blk: {
                const str = @as(*const []const u8, @ptrCast(@alignCast(data))).*;
                const duped = alloc.dupe(u8, str) catch @panic("OOM");
                const idx: u24 = @intCast(self.strings.items.len);
                self.strings.append(alloc, duped) catch @panic("OOM");
                break :blk idx;
            },
            .vector => blk: {
                const items = @as(*const []const Value, @ptrCast(@alignCast(data))).*;
                const duped = alloc.alloc(Value, items.len) catch @panic("OOM");
                @memcpy(duped, items);
                const idx: u24 = @intCast(self.vectors.items.len);
                self.vectors.append(alloc, duped) catch @panic("OOM");
                break :blk idx;
            },
            else => unreachable,
        };
        return .{ .tag = tag, .payload = payload };
    }

    fn appendPool(comptime T: type, pool: *std.ArrayList(T), alloc: std.mem.Allocator, data: *const anyopaque) u24 {
        const v = @as(*const T, @ptrCast(@alignCast(data))).*;
        const idx: u24 = @intCast(pool.items.len);
        pool.append(alloc, v) catch @panic("OOM");
        return idx;
    }

    fn rawGet(ctx: *anyopaque, tag: ValueTag, payload: u24) *anyopaque {
        const self: *NoGc = @ptrCast(@alignCast(ctx));
        return switch (tag) {
            .number => @ptrCast(&self.numbers.items[payload]),
            .cons => @ptrCast(&self.cons_cells.items[payload]),
            .closure => @ptrCast(&self.closures.items[payload]),
            .string => @ptrCast(&self.strings.items[payload]),
            .vector => @ptrCast(&self.vectors.items[payload]),
            else => unreachable,
        };
    }

    fn pushRootFn(ctx: *anyopaque, root: Value) void {
        const self: *NoGc = @ptrCast(@alignCast(ctx));
        self.roots.append(self.a(), root) catch @panic("OOM");
    }

    fn popRootFn(ctx: *anyopaque) void {
        const self: *NoGc = @ptrCast(@alignCast(ctx));
        _ = self.roots.pop();
    }

    fn writeBarrierFn(_: *anyopaque, _: Value, _: Value) void {}
    fn collectGarbageFn(_: *anyopaque) void {}
};

// --- Tests ---

test "NoGc: number round-trip" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const v = gc.alloc(f64, 3.14);
    try std.testing.expectEqual(ValueTag.number, v.tag);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), gc.getNumber(v.payload), 0.001);
}

test "NoGc: cons round-trip" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const n1 = gc.alloc(f64, 1.0);
    const n2 = gc.alloc(f64, 2.0);
    const pair = gc.alloc(ConsCell, .{ .car = n1, .cdr = n2 });

    try std.testing.expectEqual(ValueTag.cons, pair.tag);
    try std.testing.expect(n1.eql(gc.getCar(pair.payload)));
    try std.testing.expect(n2.eql(gc.getCdr(pair.payload)));
}

test "NoGc: string round-trip" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const v = gc.alloc([]const u8, "hello");
    try std.testing.expectEqual(ValueTag.string, v.tag);
    try std.testing.expectEqualStrings("hello", gc.getString(v.payload));
}

test "NoGc: vector round-trip" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const a = gc.alloc(f64, 1.0);
    const b = gc.alloc(f64, 2.0);
    const vec = gc.alloc([]const Value, &.{ a, b });

    try std.testing.expectEqual(ValueTag.vector, vec.tag);
    const items = gc.getVectorSlice(vec.payload);
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
    const c = gc.getClosure(v.payload);
    try std.testing.expect(params.eql(c.params));
    try std.testing.expectEqual(@as(u16, 2), c.arity);
}

test "NoGc: setCar/setCdr mutation" {
    var nogc = NoGc.init(std.testing.allocator);
    defer nogc.deinit();
    const gc = nogc.gcAllocator();

    const pair = gc.alloc(ConsCell, .{ .car = val.nil_value, .cdr = val.nil_value });
    const n = gc.alloc(f64, 42.0);

    gc.setCar(pair.payload, n);
    gc.setCdr(pair.payload, val.true_value);

    try std.testing.expect(n.eql(gc.getCar(pair.payload)));
    try std.testing.expect(val.true_value.eql(gc.getCdr(pair.payload)));
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
