const std = @import("std");
const Allocator = std.mem.Allocator;

const MIN_ALLOC_SIZE = 4096;

pub const Header = struct {
    next: ?[]Header,

    const Self = @This();

    pub fn init() Header {
        return Header{
            .next = null,
        };
    }

    pub fn len(self: Self) ?usize {
        if (self.next == null) return null;
        return self.next.len();
    }
};
