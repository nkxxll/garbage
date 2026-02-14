const std = @import("std");
const Allocator = std.mem.Allocator;

const ObjectType = enum {
    int,
    pair,
};

pub const RC = struct {
    count: usize = 1,
    data: ObjectData,

    const ObjectData = union(ObjectType) {
        int: i32,
        pair: struct {
            head: *RC,
            tail: *RC,
        },
    };
};

pub const VM = struct {
    allocator: Allocator,

    pub fn init(gpa: Allocator) VM {
        return .{ .allocator = gpa };
    }

    /// Create a new int object with refcount 1.
    pub fn createInt(self: *VM, value: i32) *RC {
        const el = self.allocator.create(RC) catch unreachable;
        el.* = .{ .data = .{ .int = value } };
        return el;
    }

    /// Create a new pair object with refcount 1.
    /// Retains both head and tail since the pair now references them.
    pub fn createPair(self: *VM, head: *RC, tail: *RC) *RC {
        head.count += 1;
        tail.count += 1;
        const el = self.allocator.create(RC) catch unreachable;
        el.* = .{ .data = .{ .pair = .{ .head = head, .tail = tail } } };
        return el;
    }

    /// Increment the reference count.
    pub fn retain(_: *VM, el: *RC) void {
        el.count += 1;
    }

    /// Decrement the reference count, freeing the object if it reaches zero.
    pub fn release(self: *VM, el: *RC) void {
        el.count -= 1;
        if (el.count == 0) {
            switch (el.data) {
                .int => {},
                .pair => |pair| {
                    self.release(pair.head);
                    self.release(pair.tail);
                },
            }
            self.allocator.destroy(el);
        }
    }

    /// Assign right to left: releases left, retains right, returns right.
    pub fn assign(self: *VM, left: *RC, right: *RC) *RC {
        right.count += 1;
        self.release(left);
        return right;
    }
};
