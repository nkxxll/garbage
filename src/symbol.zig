const std = @import("std");

pub const SymbolTable = struct {
    chars: std.ArrayList(u8),
    spans: std.ArrayList(Span),
    lookup: std.StringHashMapUnmanaged(u24),

    pub const Span = struct { start: u32, len: u16 };

    pub fn init() SymbolTable {
        return .{
            .chars = .{},
            .spans = .{},
            .lookup = .{},
        };
    }

    pub fn deinit(self: *SymbolTable, allocator: std.mem.Allocator) void {
        self.chars.deinit(allocator);
        self.spans.deinit(allocator);
        self.lookup.deinit(allocator);
    }

    /// Intern a symbol name. Returns existing index if already known,
    /// otherwise appends to storage and returns new index.
    pub fn intern(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8) !u24 {
        if (self.lookup.get(name)) |existing| {
            return existing;
        }
        const idx: u24 = @intCast(self.spans.items.len);
        const start: u32 = @intCast(self.chars.items.len);
        try self.chars.appendSlice(allocator, name);
        try self.spans.append(allocator, .{
            .start = start,
            .len = @intCast(name.len),
        });
        // The key for lookup must point into our own chars buffer
        const key = self.chars.items[start .. start + name.len];
        try self.lookup.put(allocator, key, idx);
        return idx;
    }

    /// Get the string name for a symbol index.
    pub fn getName(self: SymbolTable, id: u24) []const u8 {
        const span = self.spans.items[id];
        return self.chars.items[span.start .. span.start + span.len];
    }
};

// --- Tests ---

test "intern same string returns same index" {
    const allocator = std.testing.allocator;
    var st = SymbolTable.init();
    defer st.deinit(allocator);

    const a = try st.intern(allocator, "hello");
    const b = try st.intern(allocator, "hello");
    try std.testing.expectEqual(a, b);
}

test "different strings get different indices" {
    const allocator = std.testing.allocator;
    var st = SymbolTable.init();
    defer st.deinit(allocator);

    const a = try st.intern(allocator, "foo");
    const b = try st.intern(allocator, "bar");
    try std.testing.expect(a != b);
}

test "getName round-trips correctly" {
    const allocator = std.testing.allocator;
    var st = SymbolTable.init();
    defer st.deinit(allocator);

    const id1 = try st.intern(allocator, "define");
    const id2 = try st.intern(allocator, "lambda");
    const id3 = try st.intern(allocator, "if");

    try std.testing.expectEqualStrings("define", st.getName(id1));
    try std.testing.expectEqualStrings("lambda", st.getName(id2));
    try std.testing.expectEqualStrings("if", st.getName(id3));
}

test "intern multiple then re-intern all" {
    const allocator = std.testing.allocator;
    var st = SymbolTable.init();
    defer st.deinit(allocator);

    const names = [_][]const u8{ "a", "b", "c", "d", "e" };
    var ids: [5]u24 = undefined;
    for (names, 0..) |name, i| {
        ids[i] = try st.intern(allocator, name);
    }
    // Re-intern all — should return same indices
    for (names, 0..) |name, i| {
        const again = try st.intern(allocator, name);
        try std.testing.expectEqual(ids[i], again);
    }
}
