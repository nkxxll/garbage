const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const assert = std.debug.assert;

const val = @import("../value.zig");

pub const GcObject = struct {
    tag: ValueTag,
    size: usize,
    forward: ?*GcObject = null,
    data: *anyopaque,  // Pointer to the actual data
};

const Value = val.ValueDataIndex;
const Closure = val.ClosureFor(Value);
const ConsCell = val.ConsCellFor(Value);
const ScopeFor = @import("gc_interface.zig").ScopeFor;
const Scope = ScopeFor(Value);
const ValueTag = val.ValueTag;
const GcAllocatorFor = @import("gc_interface.zig").GcAllocatorFor;
const GcAllocator = GcAllocatorFor(Value);

const CopyingGC = @This();

gpa: Allocator,
page_alloc: Allocator,
buffers: [2][]u8,
current_buffer: u1 = 0,
page_size: usize,
page_size_multiplier: u8 = 1,
roots: std.ArrayList(Value),
globals: ?*std.AutoHashMapUnmanaged(usize, Value) = null,

// Separate FBA per buffer to avoid invalidating allocators
fba_buffers: [2]FixedBufferAllocator,

const LIVE_OBJECT_RATIO = 0.5;
const GC_OBJECT_SIZE = @sizeOf(GcObject);

pub fn init(backing: Allocator, page_alloc: Allocator) CopyingGC {
    const page_size = std.heap.pageSize();
    const buffer_one = page_alloc.alloc(u8, page_size) catch @panic("OOM");
    const buffer_two = page_alloc.alloc(u8, page_size) catch @panic("OOM");
    var result: CopyingGC = undefined;
    result.gpa = backing;
    result.buffers = .{ buffer_one, buffer_two };
    result.fba_buffers[0] = FixedBufferAllocator.init(result.buffers[0]);
    result.fba_buffers[1] = FixedBufferAllocator.init(result.buffers[1]);
    result.current_buffer = 0;
    result.page_size = page_size;
    result.page_alloc = page_alloc;
    result.roots = std.ArrayList(Value).initCapacity(backing, 128) catch @panic("OOM");
    result.globals = null;
    return result;
}

/// Wire up the interpreter's globals after interpreter init.
pub fn bindInterpreter(
    self: *CopyingGC,
    globals: *std.AutoHashMapUnmanaged(usize, Value),
) void {
    self.globals = globals;
}

pub fn gcAllocator(self: *CopyingGC) GcAllocator {
    return .{ .ptr = @ptrCast(self), .vtable = &vtable };
}

const vtable = GcAllocator.VTable{
    .rawAlloc = rawAlloc,
    .rawGet = rawGet,
    .pushRoot = pushRootFn,
    .popRoot = popRootFn,
};

fn createObject(self: *CopyingGC, tag: ValueTag, size: usize, data: *const anyopaque) *GcObject {
    // Use FBA for GcObject header, but GPA for data (safer during GC transitions)
    var fba_alloc = self.fba_buffers[self.current_buffer].allocator();
    const gco = fba_alloc.create(GcObject) catch @panic("FBA: OOM");
    const object_data = fba_alloc.alloc(u8, size) catch @panic("FBA: OOM");
    const src: [*]const u8 = @ptrCast(data);
    @memcpy(object_data, src[0..size]);
    gco.*.tag = tag;
    gco.*.size = size;
    gco.*.data = @ptrCast(object_data);
    gco.*.forward = null;
    return gco;
}

fn rawAlloc(ctx: *anyopaque, tag: ValueTag, data: *const anyopaque) Value {
    const self: *CopyingGC = @ptrCast(@alignCast(ctx));
    const data_size = sizeOfAllocation(tag, data);
    const header_size = GC_OBJECT_SIZE;
    const size = data_size + header_size;
    const fba = &self.fba_buffers[self.current_buffer];
    if (fba.end_index + size >= fba.buffer.len) {
        self.gc();
        // Buffers are pre-allocated large, panic if still doesn't fit
        const fba_new = &self.fba_buffers[self.current_buffer];
        if (fba_new.end_index + size >= fba_new.buffer.len) {
            @panic("Copying GC buffer exhausted - increase buffer_size");
        }
    }
    const ptr: *anyopaque = switch (tag) {
        .number, .cons, .closure, .scope => blk: {
            // |...|gcobject|data|...|
            const ptr = self.createObject(tag, data_size, data);
            break :blk ptr;
        },
        .string => blk: {
            const str = @as(*const []const u8, @ptrCast(@alignCast(data))).*;
            const ptr = self.createObject(tag, data_size, str.ptr);
            break :blk ptr;
        },
        .vector => blk: {
            const vector = @as(*const []const Value, @ptrCast(@alignCast(data))).*;
            const ptr = self.createObject(tag, data_size, vector.ptr);
            break :blk ptr;
        },
        else => unreachable,
    };
    return Value.from_ptr(tag, ptr);
}

fn rawGet(_: *anyopaque, _: ValueTag, payload: usize) *anyopaque {
    const gco: *GcObject = @ptrFromInt(payload);
    return gco.data;
}

fn pushRootFn(ctx: *anyopaque, root: Value) void {
    const self: *CopyingGC = @ptrCast(@alignCast(ctx));
    self.roots.append(self.gpa, root) catch @panic("OOM");
}

fn popRootFn(ctx: *anyopaque) void {
    const self: *CopyingGC = @ptrCast(@alignCast(ctx));
    _ = self.roots.pop();
}

fn gc(self: *CopyingGC) void {
    // switch the current buffer
    self.fbaSwitchFromToBuffer();

    if (self.globals) |globals| {
        var it = globals.valueIterator();
        while (it.next()) |v| {
            if (isGcManagedTag(v.tag)) {
                const gc_object = @as(*GcObject, @ptrFromInt(v.data));
                const new_data = self.gcCopyToToBuffer(gc_object);
                v.*.data = @intFromPtr(new_data);
            }
        }
    }
    for (self.roots.items) |*v| {
        if (isGcManagedTag(v.tag)) {
            const gc_object = @as(*GcObject, @ptrFromInt(v.data));
            const new_data = self.gcCopyToToBuffer(gc_object);
            v.*.data = @intFromPtr(new_data);
        }
    }

    if (self.shouldIncrease()) self.increaseBufferSize();
}

fn gcCopyToToBuffer(self: *CopyingGC, gc_object: *GcObject) *GcObject {
    if (gc_object.forward) |forward| return forward;

    const old_data: *const anyopaque = gc_object.data;
    const copied: *GcObject = switch (gc_object.tag) {
        .number, .string => self.createObject(gc_object.tag, gc_object.size, old_data),
        .cons => blk: {
            const old_cell: *const ConsCell = @ptrCast(@alignCast(old_data));
            var new_cell = old_cell.*;
            self.rewriteValueReference(&new_cell.car);
            self.rewriteValueReference(&new_cell.cdr);
            break :blk self.createObject(.cons, @sizeOf(ConsCell), &new_cell);
        },
        .closure => blk: {
            const old_closure: *const Closure = @ptrCast(@alignCast(old_data));
            var new_closure = old_closure.*;
            self.rewriteValueReference(&new_closure.params);
            self.rewriteValueReference(&new_closure.body);
            if (new_closure.env_id != std.math.maxInt(usize)) {
                const env_scope: *GcObject = @ptrFromInt(new_closure.env_id);
                new_closure.env_id = @intFromPtr(self.gcCopyToToBuffer(env_scope));
            }
            break :blk self.createObject(.closure, @sizeOf(Closure), &new_closure);
        },
        .vector => blk: {
            const item_count = gc_object.size / @sizeOf(Value);
            const old_items: [*]const Value = @ptrCast(@alignCast(old_data));
            var fba_alloc = self.fba_buffers[self.current_buffer].allocator();
            const new_items = fba_alloc.alloc(Value, item_count) catch @panic("FBA: OOM");
            @memcpy(new_items, old_items[0..item_count]);
            for (new_items) |*item| self.rewriteValueReference(item);
            break :blk self.createObject(.vector, gc_object.size, new_items.ptr);
        },
        .scope => blk: {
            const old_scope: *const Scope = @ptrCast(@alignCast(old_data));
            var new_scope = old_scope.*;
            var it = new_scope.table.valueIterator();
            while (it.next()) |item| self.rewriteValueReference(item);
            if (new_scope.parent) |parent_scope| {
                const parent_gc_object: *GcObject = @ptrFromInt(parent_scope);
                new_scope.parent = @intFromPtr(self.gcCopyToToBuffer(parent_gc_object));
            }
            break :blk self.createObject(.scope, @sizeOf(Scope), &new_scope);
        },
        else => unreachable,
    };

    gc_object.forward = copied;
    return copied;
}

fn rewriteValueReference(self: *CopyingGC, value: *Value) void {
    if (!isGcManagedTag(value.tag)) return;
    const old_ref: *GcObject = @ptrFromInt(value.data);
    const new_ref = self.gcCopyToToBuffer(old_ref);
    value.data = @intFromPtr(new_ref);
}

fn isGcManagedTag(tag: ValueTag) bool {
    return switch (tag) {
        .number, .cons, .closure, .string, .vector, .scope => true,
        else => false,
    };
}

fn sizeOfAllocation(tag: ValueTag, data: *const anyopaque) usize {
    return switch (tag) {
        .number => @sizeOf(f64),
        .cons => @sizeOf(ConsCell),
        .closure => @sizeOf(Closure),
        .scope => @sizeOf(Scope),
        .string => @as(*const []const u8, @ptrCast(@alignCast(data))).*.len,
        .vector => @as(*const []const Value, @ptrCast(@alignCast(data))).*.len * @sizeOf(Value),
        else => unreachable,
    };
}

pub fn deinit(self: *CopyingGC) void {
    self.roots.deinit(self.gpa);
    // Data allocations use GPA but we don't track them for cleanup
    // This is OK since interpreter is shutting down anyway
    self.page_alloc.free(self.buffers[0]);
    self.page_alloc.free(self.buffers[1]);
}

fn fbaSwitchFromToBuffer(self: *CopyingGC) void {
    self.*.current_buffer ^= 1;
    // Clear the buffer we're about to use to ensure FBA starts fresh
    @memset(self.buffers[self.current_buffer], 0);
    self.*.fba_buffers[self.current_buffer] = FixedBufferAllocator.init(self.buffers[self.current_buffer]);
}

fn shouldIncrease(self: CopyingGC) bool {
    // If we've used more than LIVE_OBJECT_RATIO of the buffer, expand next buffer
    if (self.fba_buffers[self.current_buffer].end_index == 0) return false;
    const current_live_object_ratio = @as(f64, @floatFromInt(self.fba_buffers[self.current_buffer].end_index)) / @as(f64, @floatFromInt(self.fba_buffers[self.current_buffer].buffer.len));
    if (current_live_object_ratio > LIVE_OBJECT_RATIO) return true;
    return false;
}

fn increaseBufferSize(self: *CopyingGC) void {
    const other = self.current_buffer ^ 1;
    const buffer = self.buffers[other];
    self.*.page_size_multiplier *= 2;
    self.*.buffers[other] = self.page_alloc.realloc(buffer, self.page_size_multiplier * self.page_size) catch @panic("OOM");
}
