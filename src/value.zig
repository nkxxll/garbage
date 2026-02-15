const std = @import("std");

pub const Value = packed struct {
    tag: ValueTag,
    payload: u24,

    pub fn eql(a: Value, b: Value) bool {
        return a.tag == b.tag and a.payload == b.payload;
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
};

// Sentinel constants
pub const nil_value = Value{ .tag = .nil, .payload = 0 };
pub const true_value = Value{ .tag = .boolean, .payload = 1 };
pub const false_value = Value{ .tag = .boolean, .payload = 0 };

// Pool data types — flat structs stored in parallel arrays

pub const ConsCell = struct {
    car: Value,
    cdr: Value,
};

pub const Closure = struct {
    params: Value, // cons list of symbols, or nil
    body: Value, // cons list of body expressions
    env_id: u24, // index into Scope pool (captured lexical scope)
    arity: u16,
};

pub const VectorData = struct {
    start: u32, // index into shared Value buffer
    len: u16,
};

pub const StringSpan = struct {
    start: u32, // index into packed byte buffer
    len: u16,
};

// --- Tests ---

test "Value is exactly 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Value));
}

test "sentinel values have expected bit patterns" {
    try std.testing.expectEqual(ValueTag.nil, nil_value.tag);
    try std.testing.expectEqual(@as(u24, 0), nil_value.payload);

    try std.testing.expectEqual(ValueTag.boolean, true_value.tag);
    try std.testing.expectEqual(@as(u24, 1), true_value.payload);

    try std.testing.expectEqual(ValueTag.boolean, false_value.tag);
    try std.testing.expectEqual(@as(u24, 0), false_value.payload);
}

test "Value.eql works" {
    try std.testing.expect(nil_value.eql(nil_value));
    try std.testing.expect(true_value.eql(true_value));
    try std.testing.expect(!nil_value.eql(true_value));
    try std.testing.expect(!true_value.eql(false_value));

    const a = Value{ .tag = .cons, .payload = 42 };
    const b = Value{ .tag = .cons, .payload = 42 };
    const c = Value{ .tag = .cons, .payload = 43 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "Value tags are distinct" {
    const tags = [_]ValueTag{ .nil, .number, .boolean, .cons, .symbol, .string, .vector, .closure, .builtin };
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
