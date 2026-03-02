const std = @import("std");
const llisp = @import("llisp");

const GcBackend = enum {
    none,
    mark_sweep,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var gc_backend: GcBackend = .none;
    var file_path: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--gc=none")) {
            gc_backend = .none;
        } else if (std.mem.eql(u8, arg, "--gc=mark-sweep")) {
            gc_backend = .mark_sweep;
        } else if (std.mem.startsWith(u8, arg, "--gc=")) {
            std.debug.print("Unknown GC backend: {s}\n", .{arg[5..]});
            std.debug.print("Available: none, mark-sweep\n", .{});
            std.process.exit(1);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        } else {
            file_path = arg;
        }
    }

    if (file_path == null) {
        std.debug.print("Usage: llisp [--gc=none|mark-sweep] <file>\n", .{});
        std.process.exit(1);
    }

    const raw = try std.fs.cwd().readFileAlloc(allocator, file_path.?, 1024 * 1024);
    defer allocator.free(raw);
    const source: [:0]const u8 = try allocator.dupeZ(u8, raw);
    defer allocator.free(source);

    var p = llisp.parser.Parser.init(allocator, source);
    _ = try p.parseRoot();
    defer p.ast.deinit();

    switch (gc_backend) {
        .none => {
            var nogc = llisp.gc.NoGc.init(allocator);
            defer nogc.deinit();

            var interp = try llisp.interpreter.Interpreter.init(nogc.gcAllocator(), &p.ast, allocator);
            defer interp.deinit();

            try runInterpreter(&interp, &p.ast);
        },
        .mark_sweep => {
            var ms = llisp.gc.MarkAndSweepGPABacked.init(allocator);
            defer ms.deinit();

            var interp = try llisp.interpreter.Interpreter.init(ms.gcAllocator(), &p.ast, allocator);
            defer interp.deinit();

            ms.bindInterpreter(&interp.globals);

            try runInterpreter(&interp, &p.ast);
        },
    }
}

fn runInterpreter(interp: *llisp.interpreter.Interpreter, ast: *const llisp.parser.Ast) !void {
    const root_node = ast.nodes.items[ast.root];
    const root_items = ast.listSlice(root_node.data.list);

    for (root_items) |node_id| {
        const v = try interp.astToValue(node_id);
        _ = try interp.eval(v, null);
    }

    if (interp.output.items.len > 0) {
        const len = interp.output.items.len;
        _ = try std.posix.write(std.posix.STDOUT_FILENO, interp.output.items[0..len]);
    }
}

test {
    std.testing.refAllDecls(llisp);
}
