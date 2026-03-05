const std = @import("std");

const val = @import("../value.zig");
const ConsCell = val.ConsCell;
const Closure = val.Closure;
const Value = val.ValueDataIndex;
const ScopeFor = @import("gc_interface.zig").ScopeFor;
const Scope = ScopeFor(Value);
const ValueTag = val.ValueTag;
const GcAllocatorFor = @import("gc_interface.zig").GcAllocatorFor;
const GcAllocator = GcAllocatorFor(Value);

const NoGc = @This();
/// Trivial non-collecting backend. Arena-backed pools, never reclaims.
arena: std.heap.ArenaAllocator,
numbers: std.ArrayList(f64),
cons_cells: std.ArrayList(ConsCell),
closures: std.ArrayList(Closure),
strings: std.ArrayList([]const u8),
vectors: std.ArrayList([]Value),
scopes: std.ArrayList(Scope),
roots: std.ArrayList(Value),

pub fn init(backing: std.mem.Allocator) NoGc {
    return .{
        .arena = std.heap.ArenaAllocator.init(backing),
        .numbers = .{},
        .cons_cells = .{},
        .closures = .{},
        .strings = .{},
        .vectors = .{},
        .scopes = .{},
        .roots = .{},
    };
}

pub fn deinit(self: *NoGc) void {
    for (self.scopes.items) |*scope| {
        scope.table.deinit(scope.alloc);
    }
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
};

fn a(self: *NoGc) std.mem.Allocator {
    return self.arena.allocator();
}

fn rawAlloc(ctx: *anyopaque, tag: ValueTag, data: *const anyopaque) Value {
    const self: *NoGc = @ptrCast(@alignCast(ctx));
    const alloc = self.a();
    const idx: usize = switch (tag) {
        .number => appendPool(f64, &self.numbers, alloc, data),
        .cons => appendPool(ConsCell, &self.cons_cells, alloc, data),
        .closure => appendPool(Closure, &self.closures, alloc, data),
        .scope => appendPool(Scope, &self.scopes, alloc, data),
        .string => blk: {
            const str = @as(*const []const u8, @ptrCast(@alignCast(data))).*;
            const duped = alloc.dupe(u8, str) catch @panic("OOM");
            const i = self.strings.items.len;
            self.strings.append(alloc, duped) catch @panic("OOM");
            break :blk i;
        },
        .vector => blk: {
            const items = @as(*const []const Value, @ptrCast(@alignCast(data))).*;
            const duped = alloc.alloc(Value, items.len) catch @panic("OOM");
            @memcpy(duped, items);
            const i = self.vectors.items.len;
            self.vectors.append(alloc, duped) catch @panic("OOM");
            break :blk i;
        },
        else => unreachable,
    };
    return Value.from_index(tag, idx);
}

fn appendPool(comptime T: type, pool: *std.ArrayList(T), alloc: std.mem.Allocator, data: *const anyopaque) usize {
    const v = @as(*const T, @ptrCast(@alignCast(data))).*;
    const idx = pool.items.len;
    pool.append(alloc, v) catch @panic("OOM");
    return idx;
}

fn rawGet(ctx: *anyopaque, tag: ValueTag, payload: usize) *anyopaque {
    const self: *NoGc = @ptrCast(@alignCast(ctx));
    return switch (tag) {
        .number => @ptrCast(&self.numbers.items[payload]),
        .cons => @ptrCast(&self.cons_cells.items[payload]),
        .closure => @ptrCast(&self.closures.items[payload]),
        .string => @ptrCast(&self.strings.items[payload]),
        .vector => @ptrCast(&self.vectors.items[payload]),
        .scope => @ptrCast(&self.scopes.items[payload]),
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
