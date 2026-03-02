const std = @import("std");

pub const Value = struct {
    tag: ValueTag,
    data: usize,

    pub const nil_value = Value{ .tag = .nil, .data = 0 };
    pub const true_value = Value{ .tag = .boolean, .data = 1 };
    pub const false_value = Value{ .tag = .boolean, .data = 0 };

    pub fn init(tag: ValueTag, data: usize) Value {
        return .{
            .tag = tag,
            .data = data,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.tag == b.tag and a.data == b.data;
    }

    /// Return the data field as an index (for index-based GC backends).
    pub fn get_index(self: Value) usize {
        return self.data;
    }

    /// Set the data field from an index (for index-based GC backends).
    pub fn set_index(self: *Value, idx: usize) void {
        self.data = idx;
    }

    /// Construct a Value from a tag and index.
    pub fn from_index(tag: ValueTag, idx: usize) Value {
        return .{ .tag = tag, .data = idx };
    }

    /// Interpret the data field as a pointer (for pointer-based GC backends).
    pub fn get_ptr(self: Value, comptime T: type) *T {
        return @ptrFromInt(self.data);
    }

    /// Construct a Value from a tag and pointer.
    pub fn from_ptr(tag: ValueTag, ptr: anytype) Value {
        return .{ .tag = tag, .data = @intFromPtr(ptr) };
    }
};

pub const ValueTag = enum(u8) {
    nil,
    number,
    boolean,
    cons,
    symbol,
    string,
    vector,
    closure,
    builtin,
    scope,
};

/// Comptime contract check for any type used as a Value in the GC system.
pub fn assertValueInterface(comptime V: type) void {
    const info = @typeInfo(V);
    if (info != .@"struct") @compileError("Value type must be a struct");
    const fields = info.@"struct".fields;
    if (fields.len < 1)
        @compileError("Value type must have at least 1 field");
    if (!std.mem.eql(u8, fields[0].name, "tag") or fields[0].type != ValueTag)
        @compileError("Value field 0 must be `tag: ValueTag`");
    if (!@hasDecl(V, "eql"))
        @compileError("Value type must declare `fn eql(V, V) bool`");
    if (!@hasDecl(V, "nil_value"))
        @compileError("Value type must declare `nil_value`");
    if (!@hasDecl(V, "true_value"))
        @compileError("Value type must declare `true_value`");
    if (!@hasDecl(V, "false_value"))
        @compileError("Value type must declare `false_value`");
    if (@sizeOf(V) != @sizeOf(Value))
        @compileError("Value type must be the same size as the base Value");
}

// Sentinel constants (re-exported from Value for backward compatibility)
pub const nil_value = Value.nil_value;
pub const true_value = Value.true_value;
pub const false_value = Value.false_value;

// Pool data types — flat structs stored in parallel arrays

pub fn ConsCellFor(comptime V: type) type {
    return struct {
        car: V,
        cdr: V,
    };
}
pub const ConsCell = ConsCellFor(Value);

pub fn ClosureFor(comptime V: type) type {
    return struct {
        params: V, // cons list of symbols, or nil
        body: V, // cons list of body expressions
        env_id: usize, // index into Scope pool (captured lexical scope)
        arity: u16,
    };
}
pub const Closure = ClosureFor(Value);

pub const VectorData = struct {
    start: u32, // index into shared Value buffer
    len: u16,
};

pub const StringSpan = struct {
    start: u32, // index into packed byte buffer
    len: u16,
};

// --- Tests ---

test "Value can hold a pointer" {
    try std.testing.expect(@sizeOf(Value) >= @sizeOf(usize) + 1);
}

test "sentinel values have expected bit patterns" {
    try std.testing.expectEqual(ValueTag.nil, nil_value.tag);
    try std.testing.expectEqual(@as(usize, 0), nil_value.data);

    try std.testing.expectEqual(ValueTag.boolean, true_value.tag);
    try std.testing.expectEqual(@as(usize, 1), true_value.data);

    try std.testing.expectEqual(ValueTag.boolean, false_value.tag);
    try std.testing.expectEqual(@as(usize, 0), false_value.data);
}

test "Value.eql works" {
    try std.testing.expect(nil_value.eql(nil_value));
    try std.testing.expect(true_value.eql(true_value));
    try std.testing.expect(!nil_value.eql(true_value));
    try std.testing.expect(!true_value.eql(false_value));

    const a = Value{ .tag = .cons, .data = 42 };
    const b = Value{ .tag = .cons, .data = 42 };
    const c = Value{ .tag = .cons, .data = 43 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "Value tags are distinct" {
    const tags = [_]ValueTag{ .nil, .number, .boolean, .cons, .symbol, .string, .vector, .closure, .builtin, .scope };
    for (tags, 0..) |t1, i| {
        for (tags, 0..) |t2, j| {
            if (i == j) {
                try std.testing.expectEqual(t1, t2);
            } else {
                try std.testing.expect(t1 != t2);
            }
        }
    }
}

test "Value.from_index and get_index round-trip" {
    const v = Value.from_index(.number, 42);
    try std.testing.expectEqual(ValueTag.number, v.tag);
    try std.testing.expectEqual(@as(usize, 42), v.get_index());
}

test "Value.from_ptr and get_ptr round-trip" {
    var x: u64 = 123;
    const v = Value.from_ptr(.number, &x);
    try std.testing.expectEqual(ValueTag.number, v.tag);
    const ptr = v.get_ptr(u64);
    try std.testing.expectEqual(@as(u64, 123), ptr.*);
}

test "assertValueInterface accepts Value" {
    comptime assertValueInterface(Value);
}

test "assertValueInterface accepts a custom Value with same layout" {
    const CustomValue = struct {
        tag: ValueTag,
        data: usize,

        const Self = @This();

        pub const nil_value = Self{ .tag = .nil, .data = 0 };
        pub const true_value = Self{ .tag = .boolean, .data = 1 };
        pub const false_value = Self{ .tag = .boolean, .data = 0 };

        pub fn eql(a: Self, b: Self) bool {
            return a.tag == b.tag and a.data == b.data;
        }

        pub fn from_index(tag: ValueTag, idx: usize) Self {
            return .{ .tag = tag, .data = idx };
        }
    };
    comptime assertValueInterface(CustomValue);
}
