const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const val = @import("value.zig");
const Value = val.Value;
const ValueTag = val.ValueTag;
const ConsCell = val.ConsCell;
const Closure = val.Closure;

pub fn ScopeFor(comptime V: type) type {
    return struct {
        table: std.AutoHashMapUnmanaged(usize, V),
        parent: ?usize,
        alloc: Allocator,
    };
}
pub const Scope = ScopeFor(Value);

/// Fat-pointer GC interface, modeled after std.mem.Allocator.
/// Backends implement the VTable; the interpreter calls typed wrappers
/// that derive the ValueTag from the comptime type.
pub fn GcAllocatorFor(comptime V: type) type {
    comptime val.assertValueInterface(V);

    const ConsCellT = val.ConsCellFor(V);
    const ClosureT = val.ClosureFor(V);
    const ScopeT = ScopeFor(V);

    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const ValueType = V;

        pub const VTable = struct {
            rawAlloc: *const fn (*anyopaque, ValueTag, *const anyopaque) V,
            rawGet: *const fn (*anyopaque, ValueTag, usize) *anyopaque,
            pushRoot: *const fn (*anyopaque, V) void,
            popRoot: *const fn (*anyopaque) void,
        };

        const Self = @This();

        /// Allocate a GC-managed object. Tag derived from comptime type.
        /// Supported: f64, ConsCell, Closure, []const u8, []const Value
        pub fn alloc(self: Self, comptime T: type, data: T) V {
            const tag = comptime typeToTag(T);
            return self.vtable.rawAlloc(self.ptr, tag, @ptrCast(&data));
        }

        /// Get a mutable pointer to stored object by type and payload index.
        pub fn get(self: Self, comptime T: type, payload: usize) *T {
            const tag = comptime typeToTag(T);
            return @ptrCast(@alignCast(self.vtable.rawGet(self.ptr, tag, payload)));
        }

        // --- Cons convenience ---
        pub fn getCar(self: Self, idx: usize) V {
            return self.get(ConsCellT, idx).car;
        }
        pub fn getCdr(self: Self, idx: usize) V {
            return self.get(ConsCellT, idx).cdr;
        }
        pub fn setCar(self: Self, idx: usize, v: V) void {
            self.get(ConsCellT, idx).car = v;
        }
        pub fn setCdr(self: Self, idx: usize, v: V) void {
            self.get(ConsCellT, idx).cdr = v;
        }

        // --- Scalar convenience ---
        pub fn getNumber(self: Self, idx: usize) f64 {
            return self.get(f64, idx).*;
        }
        pub fn getClosure(self: Self, idx: usize) *ClosureT {
            return self.get(ClosureT, idx);
        }
        pub fn getString(self: Self, idx: usize) []const u8 {
            return self.get([]const u8, idx).*;
        }
        pub fn getVectorSlice(self: Self, idx: usize) []V {
            return self.get([]V, idx).*;
        }
        pub fn getScope(self: Self, idx: usize) *ScopeT {
            return self.get(ScopeT, idx);
        }

        // --- Root / barrier / collect ---
        pub fn pushRoot(self: Self, root: V) void {
            self.vtable.pushRoot(self.ptr, root);
        }

        pub fn popRoot(self: Self) void {
            self.vtable.popRoot(self.ptr);
        }

        fn typeToTag(comptime T: type) ValueTag {
            if (T == f64) return .number;
            if (T == ConsCellT) return .cons;
            if (T == ClosureT) return .closure;
            if (T == []const u8) return .string;
            if (T == []const V) return .vector;
            if (T == []V) return .vector;
            if (T == ScopeT) return .scope;
            @compileError("unsupported GC type: " ++ @typeName(T));
        }
    };
}

pub const GcAllocator = GcAllocatorFor(Value);

/// Mark-and-sweep GC backed by per-type memory pools.
/// Each allocated object is tracked via a Descriptor (tag + pool pointer).
/// Value.data is the index into the descriptor array, exactly like
/// MarkAndSweepGPABacked, so the bitmap can be indexed directly by
/// Value.data without any reverse lookup.
pub const MarkAndSweepMemoryPool = struct {
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

    marked: std.DynamicBitSet,
    roots: std.ArrayList(Value),
    globals: ?*std.AutoHashMapUnmanaged(usize, Value) = null,

    allocation_counter: usize = 0,
    const GC_AFTER_N_ALLOCATIONS: usize = 25;

    /// tag == .nil is the freed-slot sentinel.
    const Descriptor = struct {
        tag: ValueTag,
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
            .objects = std.ArrayList(Descriptor).init(backing),
            .free_list = std.ArrayList(usize).init(backing),
            .marked = std.DynamicBitSet.initEmpty(backing, 64) catch @panic("OOM"),
            .roots = std.ArrayList(Value).init(backing),
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
        self.objects.deinit();
        self.free_list.deinit();
        self.marked.deinit();
        self.roots.deinit();
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

    fn ensureBitSetCapacity(self: *MarkAndSweepMemoryPool, index: usize) void {
        if (index >= self.marked.bit_length) {
            const new_len = @max(index + 1, self.marked.bit_length * 2);
            self.marked.resize(new_len, false) catch @panic("OOM");
        }
    }

    /// Append a descriptor, reusing a free slot when available.
    /// Returns the descriptor index (= the Value payload).
    fn descriptorAppend(self: *MarkAndSweepMemoryPool, desc: Descriptor) usize {
        if (self.free_list.pop()) |free_idx| {
            self.objects.items[free_idx] = desc;
            return free_idx;
        }
        const idx = self.objects.items.len;
        self.objects.append(desc) catch @panic("OOM");
        return idx;
    }

    fn freeDescriptor(self: *MarkAndSweepMemoryPool, desc: Descriptor) void {
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

    // --- VTable implementations ---

    fn rawAlloc(ctx: *anyopaque, tag: ValueTag, data: *const anyopaque) Value {
        const self: *MarkAndSweepMemoryPool = @ptrCast(@alignCast(ctx));
        self.allocation_counter = (self.allocation_counter + 1) % GC_AFTER_N_ALLOCATIONS;
        if (self.allocation_counter == 0) {
            self.mark();
            self.sweep();
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
        self.roots.append(root) catch @panic("OOM");
    }

    fn popRootFn(ctx: *anyopaque) void {
        const self: *MarkAndSweepMemoryPool = @ptrCast(@alignCast(ctx));
        _ = self.roots.pop();
    }

    fn writeBarrierFn(_: *anyopaque, _: Value, _: Value) void {}
    fn collectGarbageFn(_: *anyopaque) void {}

    // --- Mark phase ---

    pub fn mark(self: *MarkAndSweepMemoryPool) void {
        if (self.objects.items.len > 0)
            self.ensureBitSetCapacity(self.objects.items.len - 1);
        if (self.globals) |globals| {
            var it = globals.valueIterator();
            while (it.next()) |v| self.markValue(v.*);
        }
        for (self.roots.items) |v| self.markValue(v);
    }

    fn markValue(self: *MarkAndSweepMemoryPool, v: Value) void {
        switch (v.tag) {
            .number, .string => {
                self.marked.set(v.data);
            },
            .cons => {
                if (self.marked.isSet(v.data)) return;
                self.marked.set(v.data);
                const cell = @as(*ConsCell, @ptrCast(@alignCast(self.objects.items[v.data].data)));
                self.markValue(cell.car);
                self.markValue(cell.cdr);
            },
            .closure => {
                if (self.marked.isSet(v.data)) return;
                self.marked.set(v.data);
                const c = @as(*Closure, @ptrCast(@alignCast(self.objects.items[v.data].data)));
                self.markValue(c.params);
                self.markValue(c.body);
                if (c.env_id != std.math.maxInt(usize))
                    self.markValue(Value.from_index(.scope, c.env_id));
            },
            .scope => {
                if (self.marked.isSet(v.data)) return;
                self.marked.set(v.data);
                const scope = @as(*Scope, @ptrCast(@alignCast(self.objects.items[v.data].data)));
                var it = scope.table.valueIterator();
                while (it.next()) |item| self.markValue(item.*);
                if (scope.parent) |parent_id|
                    self.markValue(Value.from_index(.scope, parent_id));
            },
            .vector => {
                if (self.marked.isSet(v.data)) return;
                self.marked.set(v.data);
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
            if (self.marked.isSet(i)) {
                self.marked.unset(i); // reset for next cycle
            } else {
                self.freeDescriptor(desc.*);
                desc.* = .{ .tag = .nil, .data = undefined };
                self.free_list.append(i) catch @panic("OOM");
            }
        }
    }
};

pub const MarkAndSweepGPABacked = struct {
    gpa: Allocator,
    roots: std.ArrayList(Value),
    objects: std.ArrayList(Header),
    free_list: std.ArrayList(usize),
    // set via bindInterpreter after interpreter init
    globals: ?*std.AutoHashMapUnmanaged(usize, Value) = null,

    allocation_counter: usize = 0,
    const GC_AFTER_N_ALLOCATIONS: usize = 25;

    const Header = struct {
        marked: bool,
        tag: ValueTag,
        data: *anyopaque,
    };
    pub fn init(gpa: Allocator) MarkAndSweepGPABacked {
        return MarkAndSweepGPABacked{
            .gpa = gpa,
            .roots = .{},
            .objects = .{},
            .free_list = .{},
        };
    }

    /// Wire up the interpreter's globals after interpreter init.
    pub fn bindInterpreter(
        self: *MarkAndSweepGPABacked,
        globals: *std.AutoHashMapUnmanaged(usize, Value),
    ) void {
        self.globals = globals;
    }

    pub fn deinit(self: *MarkAndSweepGPABacked) void {
        self.roots.deinit(self.gpa);
        for (self.objects.items) |header| {
            if (header.tag == .nil) continue;
            self.freeObject(header);
        }
        self.objects.deinit(self.gpa);
        self.free_list.deinit(self.gpa);
    }

    pub fn gcAllocator(self: *MarkAndSweepGPABacked) GcAllocator {
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

    fn objectsAppend(self: *MarkAndSweepGPABacked, header: Header) usize {
        var header_index: usize = undefined;
        if (self.free_list.pop()) |free_header| {
            header_index = free_header;
            self.objects.items[free_header] = header;
        } else {
            header_index = self.objects.items.len;
            self.objects.append(self.gpa, header) catch @panic("OOM");
        }
        return header_index;
    }

    fn rawAlloc(ctx: *anyopaque, tag: ValueTag, data: *const anyopaque) Value {
        const self: *MarkAndSweepGPABacked = @ptrCast(@alignCast(ctx));
        self.allocation_counter = (self.allocation_counter + 1) % GC_AFTER_N_ALLOCATIONS;
        if (self.allocation_counter == 0) {
            self.mark();
            self.sweep();
        }
        switch (tag) {
            .number => {
                const ptr = self.gpa.create(f64) catch @panic("OOM");
                ptr.* = @as(*const f64, @ptrCast(@alignCast(data))).*;
                const headerIndex = self.objectsAppend(.{ .marked = false, .tag = tag, .data = @ptrCast(ptr) });
                return Value.from_index(tag, headerIndex);
            },
            .cons => {
                const ptr = self.gpa.create(ConsCell) catch @panic("OOM");
                ptr.* = @as(*const ConsCell, @ptrCast(@alignCast(data))).*;
                const headerIndex = self.objectsAppend(.{ .marked = false, .tag = tag, .data = @ptrCast(ptr) });
                return Value.from_index(tag, headerIndex);
            },
            .closure => {
                const ptr = self.gpa.create(Closure) catch @panic("OOM");
                ptr.* = @as(*const Closure, @ptrCast(@alignCast(data))).*;
                const headerIndex = self.objectsAppend(.{ .marked = false, .tag = tag, .data = @ptrCast(ptr) });
                return Value.from_index(tag, headerIndex);
            },
            .string => {
                const str = @as(*const []const u8, @ptrCast(@alignCast(data))).*;
                const duped = self.gpa.dupe(u8, str) catch @panic("OOM");
                const slice_ptr = self.gpa.create([]const u8) catch @panic("OOM");
                slice_ptr.* = duped;
                const headerIndex = self.objectsAppend(.{ .marked = false, .tag = tag, .data = @ptrCast(slice_ptr) });
                return Value.from_index(tag, headerIndex);
            },
            .vector => {
                const items = @as(*const []const Value, @ptrCast(@alignCast(data))).*;
                const duped = self.gpa.alloc(Value, items.len) catch @panic("OOM");
                @memcpy(duped, items);
                const slice_ptr = self.gpa.create([]Value) catch @panic("OOM");
                slice_ptr.* = duped;
                const headerIndex = self.objectsAppend(.{ .marked = false, .tag = tag, .data = @ptrCast(slice_ptr) });
                return Value.from_index(tag, headerIndex);
            },
            .scope => {
                const ptr = self.gpa.create(Scope) catch @panic("OOM");
                ptr.* = @as(*const Scope, @ptrCast(@alignCast(data))).*;
                const headerIndex = self.objectsAppend(.{ .marked = false, .tag = tag, .data = @ptrCast(ptr) });
                return Value.from_index(tag, headerIndex);
            },
            else => unreachable,
        }
    }

    fn mark(self: *MarkAndSweepGPABacked) void {
        if (self.globals) |globals| {
            var val_iter = globals.iterator();
            while (val_iter.next()) |entry| {
                self.markValue(entry.value_ptr.*);
            }
        }

        for (self.roots.items) |value| {
            self.markValue(value);
        }
    }

    fn markValue(self: *MarkAndSweepGPABacked, v: Value) void {
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
                if (c.env_id != std.math.maxInt(usize)) {
                    self.markValue(Value.from_index(.scope, c.env_id));
                }
            },
            .scope => {
                if (self.objects.items[v.data].marked) return;
                self.objects.items[v.data].marked = true;
                const scope = @as(*Scope, @ptrCast(@alignCast(self.objects.items[v.data].data)));
                var val_iter = scope.table.valueIterator();
                while (val_iter.next()) |value| {
                    self.markValue(value.*);
                }
                if (scope.parent) |parent_id| {
                    self.markValue(Value.from_index(.scope, parent_id));
                }
            },
            .vector => {
                if (self.objects.items[v.data].marked) return;
                self.objects.items[v.data].marked = true;
                const slice = @as(*[]Value, @ptrCast(@alignCast(self.objects.items[v.data].data)));
                for (slice.*) |item| {
                    self.markValue(item);
                }
            },
            else => {},
        }
    }

    fn freeObject(self: *MarkAndSweepGPABacked, header: Header) void {
        switch (header.tag) {
            .number => self.gpa.destroy(@as(*f64, @ptrCast(@alignCast(header.data)))),
            .cons => self.gpa.destroy(@as(*ConsCell, @ptrCast(@alignCast(header.data)))),
            .closure => self.gpa.destroy(@as(*Closure, @ptrCast(@alignCast(header.data)))),
            .string => {
                const slice_ptr = @as(*[]const u8, @ptrCast(@alignCast(header.data)));
                self.gpa.free(slice_ptr.*);
                self.gpa.destroy(slice_ptr);
            },
            .vector => {
                const slice_ptr = @as(*[]Value, @ptrCast(@alignCast(header.data)));
                self.gpa.free(slice_ptr.*);
                self.gpa.destroy(slice_ptr);
            },
            .scope => {
                const scope_ptr = @as(*Scope, @ptrCast(@alignCast(header.data)));
                scope_ptr.table.deinit(scope_ptr.alloc);
                self.gpa.destroy(scope_ptr);
            },
            else => unreachable,
        }
    }

    fn sweep(self: *MarkAndSweepGPABacked) void {
        for (self.objects.items, 0..) |*header, i| {
            if (header.tag == .nil) continue; // already freed slot
            if (header.marked) {
                header.marked = false; // reset for next cycle
            } else {
                self.freeObject(header.*);
                header.* = .{ .marked = false, .tag = .nil, .data = undefined };
                self.free_list.append(self.gpa, i) catch @panic("OOM");
            }
        }
    }

    /// in this allocator we dont have to keep references to all objects in different lists
    fn rawGet(ctx: *anyopaque, _: ValueTag, payload: usize) *anyopaque {
        const self: *MarkAndSweepGPABacked = @ptrCast(@alignCast(ctx));
        const h: Header = self.objects.items[payload];
        return h.data;
    }

    fn pushRootFn(ctx: *anyopaque, root: Value) void {
        const self: *MarkAndSweepGPABacked = @ptrCast(@alignCast(ctx));
        self.roots.append(self.gpa, root) catch @panic("OOM");
    }

    /// pops a root from the temp roots tack we dont need the return value
    fn popRootFn(ctx: *anyopaque) void {
        const self: *MarkAndSweepGPABacked = @ptrCast(@alignCast(ctx));
        _ = self.roots.pop();
    }
};

/// Trivial non-collecting backend. Arena-backed pools, never reclaims.
pub const NoGc = struct {
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
};

// --- Tests ---

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
    _ = gc.alloc(Closure, .{ .params = val.nil_value, .body = val.nil_value, .env_id = 0, .arity = 0 });
    _ = gc.alloc([]const u8, "hello");
    _ = gc.alloc([]const Value, &[_]Value{val.nil_value});

    try std.testing.expectEqual(@as(usize, 5), ms.objects.items.len);

    // No roots, no globals, no scopes → everything is unreachable.
    ms.mark();
    ms.sweep();

    // Every slot must have been freed (tag set to .nil sentinel).
    for (ms.objects.items) |header| {
        try std.testing.expectEqual(ValueTag.nil, header.tag);
    }
    // All indices recycled into the free list.
    try std.testing.expectEqual(@as(usize, 5), ms.free_list.items.len);
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
    _ = gc.alloc(Closure, .{ .params = val.nil_value, .body = val.nil_value, .env_id = 0, .arity = 0 });
    _ = gc.alloc([]const u8, "discard");
    _ = gc.alloc([]const Value, &[_]Value{val.nil_value});

    try std.testing.expectEqual(@as(usize, 7), ms.objects.items.len);

    ms.mark();
    ms.sweep();

    // 2 rooted survive, 5 unreachable freed.
    var live: usize = 0;
    for (ms.objects.items) |header| {
        if (header.tag != .nil) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), live);
    try std.testing.expectEqual(@as(usize, 5), ms.free_list.items.len);

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
