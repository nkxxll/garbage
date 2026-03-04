const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const val = @import("../value.zig");
const ConsCell = val.ConsCell;
const Closure = val.Closure;
const Value = val.Value;
const ScopeFor = @import("gc_interface.zig").ScopeFor;
const Scope = ScopeFor(Value);
const ValueTag = val.ValueTag;
const GcAllocatorFor = @import("gc_interface.zig").GcAllocatorFor;
const GcAllocator = GcAllocatorFor(Value);

const CopyingGC = @This();

backing: Allocator,
fba: FixedBufferAllocator,
buffers: [2][]u8,
current_buffer: u2 = 0,
alloc: std.heap.page_allocator,

const GcObject = struct {
    value: Value,
    forward: *anyopaque,
};

fn init(backing: Allocator) CopyingGC {
    // goal here is that we allocate two full pages if the pages are filled up after a garbage collection we exchange the "next" page with two pages of data and free the first page or make a realloc
    const page_size = std.heap.pageSize();
    const buffer_one = try CopyingGC.alloc.alloc(u8, page_size);
    const buffer_two = try CopyingGC.alloc.alloc(u8, page_size);
    const buffers = .{ buffer_one, buffer_two };
    const fba = FixedBufferAllocator.init(buffers[CopyingGC.current_buffer]);
    return .{
        .backing = backing,
        .buffers = buffers,
        .fba = fba,
        .current_buffer = CopyingGC.current_buffer,
    };
}
