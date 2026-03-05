const std = @import("std");
const Allocator = std.mem.Allocator;

const val = @import("../value.zig");
const ConsCell = val.ConsCell;
const Closure = val.Closure;
const Value = val.ValueDataIndex;
const ScopeFor = @import("gc_interface.zig").ScopeFor;
const Scope = ScopeFor(Value);
const ValueTag = val.ValueTag;
const GcAllocatorFor = @import("gc_interface.zig").GcAllocatorFor;
const GcAllocator = GcAllocatorFor(Value);

const MarkAndSweepGPABacked = @This();

/// Mark-and-sweep GC backed by the general-purpose allocator.
///
/// Every managed object is allocated as a single `GcWrapped(T)` that
/// places a small `GcHeader` (intrusive linked-list node) immediately
/// before the payload `T` in memory.  `Value.data` stores the raw
/// pointer to the payload, so `rawGet` is a zero-indirection cast with
/// no array lookup.  The linked list (`first` → `gh.next` → …) gives
/// the GC everything it needs for mark and sweep without a parallel
/// index array or a free-list of recycled indices.
/// NOTE: the last change introduced a new regression made the code nicer but is way
/// slower and uses more peek memory. Focussing on the pool gc now but the we will come back.
gpa: Allocator,
roots: std.ArrayList(Value),
/// Head of the intrusive singly-linked list of all live GC objects.
first: ?*GcHeader,
globals: ?*std.AutoHashMapUnmanaged(usize, Value) = null,

bytes_allocated_since_gc: usize = 0,
gc_threshold: usize = 1024,
total_live_bytes: usize = 0,

/// Intrusive linked-list node stored at the start of every GcWrapped(T).
/// Because it is the first field, a `*GcHeader` can be @ptrCast'd
/// directly to `*GcWrapped(T)` without any address arithmetic.
pub const GcHeader = struct {
    next: ?*GcHeader,
    marked: bool,
    tag: ValueTag,
};

/// One heap allocation that holds the GcHeader followed by the payload.
/// `header` must be the first field so that `@ptrCast(*GcHeader)` gives
/// a valid `*GcWrapped(T)`.
fn GcWrapped(comptime T: type) type {
    return struct {
        header: GcHeader,
        data: T,
    };
}

pub fn init(gpa: Allocator) MarkAndSweepGPABacked {
    return .{ .gpa = gpa, .roots = .{}, .first = null };
}

/// Wire up the interpreter's globals after interpreter init.
pub fn bindInterpreter(
    self: *MarkAndSweepGPABacked,
    globals: *std.AutoHashMapUnmanaged(usize, Value),
) void {
    self.globals = globals;
}

pub fn deinit(self: *MarkAndSweepGPABacked) void {
    var cur = self.first;
    while (cur) |gh| {
        const next = gh.next;
        self.freeHeader(gh);
        cur = next;
    }
    self.roots.deinit(self.gpa);
}

pub fn gcAllocator(self: *MarkAndSweepGPABacked) GcAllocator {
    return .{ .ptr = @ptrCast(self), .vtable = &vtable };
}

const vtable = GcAllocator.VTable{
    .rawAlloc = rawAlloc,
    .rawGet = rawGet,
    .pushRoot = pushRootFn,
    .popRoot = popRootFn,
};

fn sizeOfAllocation(tag: ValueTag, data: *const anyopaque) usize {
    return @sizeOf(GcHeader) + switch (tag) {
        .number => @sizeOf(f64),
        .cons => @sizeOf(ConsCell),
        .closure => @sizeOf(Closure),
        .scope => @sizeOf(Scope),
        .string => @sizeOf([]const u8) + @as(*const []const u8, @ptrCast(@alignCast(data))).*.len,
        .vector => @sizeOf([]Value) + @as(*const []const Value, @ptrCast(@alignCast(data))).*.len * @sizeOf(Value),
        else => unreachable,
    };
}

fn sizeOfHeader(gh: *GcHeader) usize {
    return @sizeOf(GcHeader) + switch (gh.tag) {
        .number => @sizeOf(f64),
        .cons => @sizeOf(ConsCell),
        .closure => @sizeOf(Closure),
        .scope => @sizeOf(Scope),
        .string => @as(*GcWrapped([]const u8), @ptrCast(gh)).data.len,
        .vector => @as(*GcWrapped([]Value), @ptrCast(gh)).data.len * @sizeOf(Value),
        else => unreachable,
    };
}


/// and return a Value whose .data is @intFromPtr(&wrapped.data).
fn allocWrapped(self: *MarkAndSweepGPABacked, comptime T: type, tag: ValueTag, value: T) Value {
    const w = self.gpa.create(GcWrapped(T)) catch @panic("OOM");
    w.* = .{ .header = .{ .next = self.first, .marked = false, .tag = tag }, .data = value };
    self.first = &w.header;
    return Value.from_ptr(tag, &w.data);
}

fn rawAlloc(ctx: *anyopaque, tag: ValueTag, data: *const anyopaque) Value {
    const self: *MarkAndSweepGPABacked = @ptrCast(@alignCast(ctx));
    const size = sizeOfAllocation(tag, data);
    self.total_live_bytes += size;
    self.bytes_allocated_since_gc += size;
    if (self.bytes_allocated_since_gc >= self.gc_threshold) {
        self.mark();
        self.sweep();
        self.bytes_allocated_since_gc = 0;
    }
    return switch (tag) {
        .number => self.allocWrapped(f64, tag, @as(*const f64, @ptrCast(@alignCast(data))).*),
        .cons => self.allocWrapped(ConsCell, tag, @as(*const ConsCell, @ptrCast(@alignCast(data))).*),
        .closure => self.allocWrapped(Closure, tag, @as(*const Closure, @ptrCast(@alignCast(data))).*),
        .scope => self.allocWrapped(Scope, tag, @as(*const Scope, @ptrCast(@alignCast(data))).*),
        .string => blk: {
            const str = @as(*const []const u8, @ptrCast(@alignCast(data))).*;
            const duped = self.gpa.dupe(u8, str) catch @panic("OOM");
            break :blk self.allocWrapped([]const u8, tag, duped);
        },
        .vector => blk: {
            const items = @as(*const []const Value, @ptrCast(@alignCast(data))).*;
            const duped = self.gpa.alloc(Value, items.len) catch @panic("OOM");
            @memcpy(duped, items);
            break :blk self.allocWrapped([]Value, tag, duped);
        },
        else => unreachable,
    };
}

/// Value.data already IS the pointer to the object — no indirection needed.
fn rawGet(_: *anyopaque, _: ValueTag, payload: usize) *anyopaque {
    return @ptrFromInt(payload);
}

fn pushRootFn(ctx: *anyopaque, root: Value) void {
    const self: *MarkAndSweepGPABacked = @ptrCast(@alignCast(ctx));
    self.roots.append(self.gpa, root) catch @panic("OOM");
}

fn popRootFn(ctx: *anyopaque) void {
    const self: *MarkAndSweepGPABacked = @ptrCast(@alignCast(ctx));
    _ = self.roots.pop();
}

// --- GcHeader ↔ payload pointer helpers ---

/// Recover the GcHeader for a live Value.
/// v.data == @intFromPtr(&GcWrapped(T).data), so @fieldParentPtr
/// gives back the containing GcWrapped(T) and its header.
fn headerFromValue(v: Value) *GcHeader {
    return switch (v.tag) {
        .number => headerOf(f64, v.data),
        .cons => headerOf(ConsCell, v.data),
        .closure => headerOf(Closure, v.data),
        .string => headerOf([]const u8, v.data),
        .vector => headerOf([]Value, v.data),
        .scope => headerOf(Scope, v.data),
        else => unreachable,
    };
}

fn headerOf(comptime T: type, data_as_int: usize) *GcHeader {
    const data_ptr: *T = @ptrFromInt(data_as_int);
    const wrapped: *GcWrapped(T) = @fieldParentPtr("data", data_ptr);
    return &wrapped.header;
}

/// Free the GcWrapped(T) allocation (and any owned heap memory) for gh.
fn freeHeader(self: *MarkAndSweepGPABacked, gh: *GcHeader) void {
    self.total_live_bytes -= sizeOfHeader(gh);
    switch (gh.tag) {
        .number => self.gpa.destroy(@as(*GcWrapped(f64), @ptrCast(gh))),
        .cons => self.gpa.destroy(@as(*GcWrapped(ConsCell), @ptrCast(gh))),
        .closure => self.gpa.destroy(@as(*GcWrapped(Closure), @ptrCast(gh))),
        .string => {
            const w = @as(*GcWrapped([]const u8), @ptrCast(gh));
            self.gpa.free(w.data);
            self.gpa.destroy(w);
        },
        .vector => {
            const w = @as(*GcWrapped([]Value), @ptrCast(gh));
            self.gpa.free(w.data);
            self.gpa.destroy(w);
        },
        .scope => {
            const w = @as(*GcWrapped(Scope), @ptrCast(gh));
            w.data.table.deinit(w.data.alloc);
            self.gpa.destroy(w);
        },
        else => unreachable,
    }
}

// --- Mark phase ---

pub fn mark(self: *MarkAndSweepGPABacked) void {
    if (self.globals) |globals| {
        var it = globals.valueIterator();
        while (it.next()) |v| self.markValue(v.*);
    }
    for (self.roots.items) |v| self.markValue(v);
}

fn markValue(self: *MarkAndSweepGPABacked, v: Value) void {
    switch (v.tag) {
        .number, .string => {
            headerFromValue(v).marked = true;
        },
        .cons => {
            const h = headerFromValue(v);
            if (h.marked) return;
            h.marked = true;
            const cell: *ConsCell = @ptrFromInt(v.data);
            self.markValue(cell.car);
            self.markValue(cell.cdr);
        },
        .closure => {
            const h = headerFromValue(v);
            if (h.marked) return;
            h.marked = true;
            const c: *Closure = @ptrFromInt(v.data);
            self.markValue(c.params);
            self.markValue(c.body);
            if (c.env_id != std.math.maxInt(usize))
                self.markValue(Value{ .tag = .scope, .data = c.env_id });
        },
        .scope => {
            const h = headerFromValue(v);
            if (h.marked) return;
            h.marked = true;
            const scope: *Scope = @ptrFromInt(v.data);
            var it = scope.table.valueIterator();
            while (it.next()) |item| self.markValue(item.*);
            if (scope.parent) |parent_id|
                self.markValue(Value{ .tag = .scope, .data = parent_id });
        },
        .vector => {
            const h = headerFromValue(v);
            if (h.marked) return;
            h.marked = true;
            const slice: *[]Value = @ptrFromInt(v.data);
            for (slice.*) |item| self.markValue(item);
        },
        else => {},
    }
}

// --- Sweep phase ---

pub fn sweep(self: *MarkAndSweepGPABacked) void {
    var cur_ptr: *?*GcHeader = &self.first;
    while (cur_ptr.*) |gh| {
        if (gh.marked) {
            gh.marked = false; // reset for next cycle
            cur_ptr = &gh.next;
        } else {
            cur_ptr.* = gh.next; // unlink before freeing
            self.freeHeader(gh);
        }
    }
    self.gc_threshold = @max(1024, self.total_live_bytes * 2);
}
