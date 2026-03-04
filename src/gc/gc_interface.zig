const std = @import("std");
const Allocator = std.mem.Allocator;
const val = @import("../value.zig");
const ValueTag = val.ValueTag;

pub fn ScopeFor(comptime V: type) type {
    return struct {
        table: std.AutoHashMapUnmanaged(usize, V),
        parent: ?usize,
        alloc: Allocator,
    };
}

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
