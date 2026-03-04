const std = @import("std");
const Allocator = std.mem.Allocator;

const val = @import("../value.zig");
const ConsCell = val.ConsCell;
const Closure = val.Closure;
const Value = val.Value;
const ScopeFor = @import("gc_interface.zig").ScopeFor;
const Scope = ScopeFor(Value);
const ValueTag = val.ValueTag;
const GcAllocatorFor = @import("gc_interface.zig").GcAllocatorFor;
const GcAllocator = GcAllocatorFor(Value);

const MarkAndSweepMemoryPool = @This();

/// Mark-and-sweep GC backed by per-type memory pools.
/// Each allocated object is tracked via a Descriptor (tag + pool pointer).
/// Value.data is the index into the descriptor array; the bitmap is indexed
/// directly by Value.data without any reverse lookup.
backing: Allocator,
numbers: std.heap.MemoryPool(f64),
cons_cells: std.heap.MemoryPool(ConsCell),
closures: std.heap.MemoryPool(Closure),
strings: std.heap.MemoryPool([]const u8),
vectors: std.heap.MemoryPool([]Value),
scopes: std.heap.MemoryPool(Scope),
/// Parallel descriptor array.  objects.items[i].data is the pool pointer
/// for the object whose Value carries payload index i.
objects: std.ArrayList(Descriptor),
free_list: std.ArrayList(usize),

roots: std.ArrayList(Value),
globals: ?*std.AutoHashMapUnmanaged(usize, Value) = null,

bytes_allocated_since_gc: usize = 0,
gc_threshold: usize = 1024,
total_live_bytes: usize = 0,

/// tag == .nil is the freed-slot sentinel.
const Descriptor = struct {
    tag: ValueTag,
    marked: bool = false,
    data: *anyopaque,
};

pub fn init(backing: Allocator) MarkAndSweepMemoryPool {
    return .{
        .backing = backing,
        .numbers = std.heap.MemoryPool(f64).init(backing),
        .cons_cells = std.heap.MemoryPool(ConsCell).init(backing),
        .closures = std.heap.MemoryPool(Closure).init(backing),
        .strings = std.heap.MemoryPool([]const u8).init(backing),
        .vectors = std.heap.MemoryPool([]Value).init(backing),
        .scopes = std.heap.MemoryPool(Scope).init(backing),
        .objects = std.ArrayList(Descriptor).initCapacity(backing, 128) catch @panic("OOM"),
        .free_list = std.ArrayList(usize).initCapacity(backing, 128) catch @panic("OOM"),
        .roots = std.ArrayList(Value).initCapacity(backing, 128) catch @panic("OOM"),
    };
}

pub fn deinit(self: *MarkAndSweepMemoryPool) void {
    for (self.objects.items) |desc| {
        if (desc.tag == .nil) continue;
        self.freeDescriptor(desc);
    }
    self.numbers.deinit();
    self.cons_cells.deinit();
    self.closures.deinit();
    self.strings.deinit();
    self.vectors.deinit();
    self.scopes.deinit();
    self.objects.deinit(self.backing);
    self.free_list.deinit(self.backing);
    self.roots.deinit(self.backing);
}

/// Wire up the interpreter's globals after interpreter init.
pub fn bindInterpreter(
    self: *MarkAndSweepMemoryPool,
    globals: *std.AutoHashMapUnmanaged(usize, Value),
) void {
    self.globals = globals;
}

pub fn gcAllocator(self: *MarkAndSweepMemoryPool) GcAllocator {
    return .{ .ptr = @ptrCast(self), .vtable = &vtable };
}

const vtable = GcAllocator.VTable{
    .rawAlloc = rawAlloc,
    .rawGet = rawGet,
    .pushRoot = pushRootFn,
    .popRoot = popRootFn,
};



/// Append a descriptor, reusing a free slot when available.
/// Returns the descriptor index (= the Value payload).
fn descriptorAppend(self: *MarkAndSweepMemoryPool, desc: Descriptor) usize {
    if (self.free_list.pop()) |free_idx| {
        self.objects.items[free_idx] = desc;
        return free_idx;
    }
    const idx = self.objects.items.len;
    self.objects.append(self.backing, desc) catch @panic("OOM");
    return idx;
}

fn freeDescriptor(self: *MarkAndSweepMemoryPool, desc: Descriptor) void {
    self.total_live_bytes -= sizeOfDescriptor(desc);
    switch (desc.tag) {
        .number => self.numbers.destroy(@as(*f64, @ptrCast(@alignCast(desc.data)))),
        .cons => self.cons_cells.destroy(@as(*ConsCell, @ptrCast(@alignCast(desc.data)))),
        .closure => self.closures.destroy(@as(*Closure, @ptrCast(@alignCast(desc.data)))),
        .string => {
            const slice_ptr = @as(*[]const u8, @ptrCast(@alignCast(desc.data)));
            self.backing.free(slice_ptr.*);
            self.strings.destroy(slice_ptr);
        },
        .vector => {
            const slice_ptr = @as(*[]Value, @ptrCast(@alignCast(desc.data)));
            self.backing.free(slice_ptr.*);
            self.vectors.destroy(slice_ptr);
        },
        .scope => {
            const scope_ptr = @as(*Scope, @ptrCast(@alignCast(desc.data)));
            scope_ptr.table.deinit(scope_ptr.alloc);
            self.scopes.destroy(scope_ptr);
        },
        else => unreachable,
    }
}

fn sizeOfAllocation(tag: ValueTag, data: *const anyopaque) usize {
    return switch (tag) {
        .number => @sizeOf(f64),
        .cons => @sizeOf(ConsCell),
        .closure => @sizeOf(Closure),
        .scope => @sizeOf(Scope),
        .string => @sizeOf([]const u8) + @as(*const []const u8, @ptrCast(@alignCast(data))).*.len,
        .vector => @sizeOf([]Value) + @as(*const []const Value, @ptrCast(@alignCast(data))).*.len * @sizeOf(Value),
        else => unreachable,
    };
}

fn sizeOfDescriptor(desc: Descriptor) usize {
    return switch (desc.tag) {
        .number => @sizeOf(f64),
        .cons => @sizeOf(ConsCell),
        .closure => @sizeOf(Closure),
        .scope => @sizeOf(Scope),
        .string => @sizeOf([]const u8) + @as(*[]const u8, @ptrCast(@alignCast(desc.data))).*.len,
        .vector => @sizeOf([]Value) + @as(*[]Value, @ptrCast(@alignCast(desc.data))).*.len * @sizeOf(Value),
        else => unreachable,
    };
}



fn rawAlloc(ctx: *anyopaque, tag: ValueTag, data: *const anyopaque) Value {
    const self: *MarkAndSweepMemoryPool = @ptrCast(@alignCast(ctx));
    const size = sizeOfAllocation(tag, data);
    self.total_live_bytes += size;
    self.bytes_allocated_since_gc += size;
    if (self.bytes_allocated_since_gc >= self.gc_threshold) {
        self.mark();
        self.sweep();
        self.bytes_allocated_since_gc = 0;
    }
    const idx: usize = switch (tag) {
        .number => blk: {
            const ptr = self.numbers.create() catch @panic("OOM");
            ptr.* = @as(*const f64, @ptrCast(@alignCast(data))).*;
            break :blk self.descriptorAppend(.{ .tag = tag, .data = @ptrCast(ptr) });
        },
        .cons => blk: {
            const ptr = self.cons_cells.create() catch @panic("OOM");
            ptr.* = @as(*const ConsCell, @ptrCast(@alignCast(data))).*;
            break :blk self.descriptorAppend(.{ .tag = tag, .data = @ptrCast(ptr) });
        },
        .closure => blk: {
            const ptr = self.closures.create() catch @panic("OOM");
            ptr.* = @as(*const Closure, @ptrCast(@alignCast(data))).*;
            break :blk self.descriptorAppend(.{ .tag = tag, .data = @ptrCast(ptr) });
        },
        .string => blk: {
            const str = @as(*const []const u8, @ptrCast(@alignCast(data))).*;
            const duped = self.backing.dupe(u8, str) catch @panic("OOM");
            const slice_ptr = self.strings.create() catch @panic("OOM");
            slice_ptr.* = duped;
            break :blk self.descriptorAppend(.{ .tag = tag, .data = @ptrCast(slice_ptr) });
        },
        .vector => blk: {
            const items = @as(*const []const Value, @ptrCast(@alignCast(data))).*;
            const duped = self.backing.alloc(Value, items.len) catch @panic("OOM");
            @memcpy(duped, items);
            const slice_ptr = self.vectors.create() catch @panic("OOM");
            slice_ptr.* = duped;
            break :blk self.descriptorAppend(.{ .tag = tag, .data = @ptrCast(slice_ptr) });
        },
        .scope => blk: {
            const ptr = self.scopes.create() catch @panic("OOM");
            ptr.* = @as(*const Scope, @ptrCast(@alignCast(data))).*;
            break :blk self.descriptorAppend(.{ .tag = tag, .data = @ptrCast(ptr) });
        },
        else => unreachable,
    };
    return Value.from_index(tag, idx);
}

fn rawGet(ctx: *anyopaque, _: ValueTag, payload: usize) *anyopaque {
    const self: *MarkAndSweepMemoryPool = @ptrCast(@alignCast(ctx));
    return self.objects.items[payload].data;
}

fn pushRootFn(ctx: *anyopaque, root: Value) void {
    const self: *MarkAndSweepMemoryPool = @ptrCast(@alignCast(ctx));
    self.roots.append(self.backing, root) catch @panic("OOM");
}

fn popRootFn(ctx: *anyopaque) void {
    const self: *MarkAndSweepMemoryPool = @ptrCast(@alignCast(ctx));
    _ = self.roots.pop();
}

fn writeBarrierFn(_: *anyopaque, _: Value, _: Value) void {}
fn collectGarbageFn(_: *anyopaque) void {}

// --- Mark phase ---

pub fn mark(self: *MarkAndSweepMemoryPool) void {
    if (self.globals) |globals| {
        var it = globals.valueIterator();
        while (it.next()) |v| self.markValue(v.*);
    }
    for (self.roots.items) |v| self.markValue(v);
}

fn markValue(self: *MarkAndSweepMemoryPool, v: Value) void {
    switch (v.tag) {
        .number, .string => {
            self.objects.items[v.data].marked = true;
        },
        .cons => {
            if (self.objects.items[v.data].marked) return;
            self.objects.items[v.data].marked = true;
            const cell = @as(*ConsCell, @ptrCast(@alignCast(self.objects.items[v.data].data)));
            self.markValue(cell.car);
            self.markValue(cell.cdr);
        },
        .closure => {
            if (self.objects.items[v.data].marked) return;
            self.objects.items[v.data].marked = true;
            const c = @as(*Closure, @ptrCast(@alignCast(self.objects.items[v.data].data)));
            self.markValue(c.params);
            self.markValue(c.body);
            if (c.env_id != std.math.maxInt(usize))
                self.markValue(Value.from_index(.scope, c.env_id));
        },
        .scope => {
            if (self.objects.items[v.data].marked) return;
            self.objects.items[v.data].marked = true;
            const scope = @as(*Scope, @ptrCast(@alignCast(self.objects.items[v.data].data)));
            var it = scope.table.valueIterator();
            while (it.next()) |item| self.markValue(item.*);
            if (scope.parent) |parent_id|
                self.markValue(Value.from_index(.scope, parent_id));
        },
        .vector => {
            if (self.objects.items[v.data].marked) return;
            self.objects.items[v.data].marked = true;
            const slice = @as(*[]Value, @ptrCast(@alignCast(self.objects.items[v.data].data)));
            for (slice.*) |item| self.markValue(item);
        },
        else => {},
    }
}

// --- Sweep phase ---

pub fn sweep(self: *MarkAndSweepMemoryPool) void {
    for (self.objects.items, 0..) |*desc, i| {
        if (desc.tag == .nil) continue; // already-freed slot
        if (desc.marked) {
            desc.marked = false; // reset for next cycle
        } else {
            self.freeDescriptor(desc.*);
            desc.* = .{ .tag = .nil, .marked = false, .data = undefined };
            self.free_list.append(self.backing, i) catch @panic("OOM");
        }
    }
    self.gc_threshold = @max(1024, self.total_live_bytes * 2);
}
