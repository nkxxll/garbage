const std = @import("std");

pub const SymbolTable = struct {
    names: std.ArrayList([]const u8),
    lookup: std.StringHashMapUnmanaged(u24),

    pub fn init() SymbolTable {
        return .{
            .names = .{},
            .lookup = .{},
        };
    }

    pub fn deinit(self: *SymbolTable, allocator: std.mem.Allocator) void {
        for (self.names.items) |name| {
            allocator.free(name);
        }
        self.names.deinit(allocator);
        self.lookup.deinit(allocator);
    }

    /// Intern a symbol name. Returns existing index if already known,
    /// otherwise appends to storage and returns new index.
    pub fn intern(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8) !u24 {
        if (self.lookup.get(name)) |existing| {
            return existing;
        }
        const idx: u24 = @intCast(self.names.items.len);
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try self.names.append(allocator, owned);
        try self.lookup.put(allocator, owned, idx);
        return idx;
    }

    /// Get the string name for a symbol index.
    pub fn getName(self: SymbolTable, id: u24) []const u8 {
        return self.names.items[id];
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
