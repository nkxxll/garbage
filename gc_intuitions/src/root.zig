//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Heap = struct {};
pub const rc = @import("refcount.zig");

const ObjectType = enum {
    int,
    pair,
};

const ObjectData = union(ObjectType) {
    int: i32,
    pair: struct {
        head: *Object,
        tail: *Object,
    },
};

const Object = struct {
    marked: bool = false,
    next: ?*Object = null,
    data: ObjectData,
};

const STACK_MAX = 256;
const INITIAL_GC_THRESHOLD = 5;

pub const VM = struct {
    stack: [STACK_MAX]*Object,
    stackSize: usize,
    allocator: Allocator,

    firstObject: ?*Object,

    // current allocations and the max allocations
    numObjects: usize = 0,
    maxObjects: usize = INITIAL_GC_THRESHOLD,

    const Self = @This();

    pub fn init(gpa: Allocator) VM {
        return VM{
            .stackSize = 0,
            .allocator = gpa,
            .stack = undefined,
            .firstObject = null,
        };
    }

    pub fn push(self: *Self, object: *Object) void {
        assert(self.stackSize < STACK_MAX);
        self.stack[self.stackSize] = object;
        self.stackSize += 1;
    }

    pub fn pop(self: *Self) *Object {
        assert(self.stackSize > 0);
        self.stackSize -= 1;
        return self.stack[self.stackSize];
    }

    pub fn newObject(vm: *Self, data: anytype) !*Object {
        const object = try vm.allocator.create(Object);
        // 2. Initialize the struct fields
        object.* = Object{
            .marked = false,
            .next = vm.firstObject,
            .data = data,
        };

        vm.firstObject = object;

        vm.numObjects += 1;
        std.log.info("[GC] Created object {*}, total objects: {d}", .{ object, vm.numObjects });
        return object;
    }

    pub fn pushInt(vm: *Self, intValue: i32) !void {
        const object = try vm.newObject(ObjectData{ .int = intValue });
        vm.push(object);
        std.log.info("[GC] Pushed int {d} onto stack, stack size: {d}", .{ intValue, vm.stackSize });
    }

    pub fn pushPair(vm: *Self) !*Object {
        const tail = vm.pop();
        const head = vm.pop();
        const object = try vm.newObject(ObjectData{ .pair = .{ .head = head, .tail = tail } });

        vm.push(object);
        std.log.info("[GC] Created pair object {*}, stack size: {d}", .{ object, vm.stackSize });
        return object;
    }

    pub fn markAll(vm: *Self) void {
        std.log.info("[GC] Starting mark phase, stack size: {d}", .{vm.stackSize});
        for (0..vm.stackSize) |i| {
            vm.mark(vm.stack[i]);
        }
        std.log.info("[GC] Mark phase complete", .{});
    }

    pub fn mark(vm: *Self, object: *Object) void {
        if (object.marked) {
            std.log.info("[GC] Object {*} already marked, skipping", .{object});
            return;
        }
        object.marked = true;
        std.log.info("[GC] Marked object {*}", .{object});
        switch (object.data) {
            .int => {},
            .pair => |p| {
                std.log.info("[GC] Marking pair head and tail", .{});
                vm.mark(p.head);
                vm.mark(p.tail);
            },
        }
    }

    pub fn sweep(vm: *Self) void {
        std.log.info("[GC] Starting sweep phase, numObjects before: {d}", .{vm.numObjects});
        var object = vm.firstObject;
        vm.firstObject = null;
        var newList: ?*Object = null;
        var newListTail: ?*Object = null;
        var freedCount: usize = 0;

        while (object) |obj| {
            const next = obj.next;
            if (!obj.marked) {
                // This object wasn't reached, so free it.
                std.log.info("[GC] Freeing unmarked object {*}", .{obj});
                vm.allocator.destroy(obj);
                freedCount += 1;
                vm.numObjects -= 1;
            } else {
                // This object was reached, so unmark it and add to new list
                obj.marked = false;
                obj.next = null;
                if (newListTail) |tail| {
                    tail.next = obj;
                    newListTail = obj;
                } else {
                    newList = obj;
                    newListTail = obj;
                }
            }
            object = next;
        }

        vm.firstObject = newList;
        std.log.info("[GC] Sweep phase complete, freed {d} objects, numObjects after: {d}", .{ freedCount, vm.numObjects });
    }

    pub fn gc(vm: *Self) void {
        std.log.info("[GC] ===== Garbage Collection Started =====", .{});
        vm.markAll();
        vm.sweep();
        std.log.info("[GC] ===== Garbage Collection Complete =====", .{});
    }
};
