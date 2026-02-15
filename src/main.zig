const std = @import("std");
const llisp = @import("llisp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: llisp <file>\n", .{});
        std.process.exit(1);
    }

    const raw = try std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024);
    defer allocator.free(raw);
    const source: [:0]const u8 = try allocator.dupeZ(u8, raw);
    defer allocator.free(source);

    var p = llisp.parser.Parser.init(allocator, source);
    _ = try p.parseRoot();
    defer p.ast.deinit();

    var nogc = llisp.gc.NoGc.init(allocator);
    defer nogc.deinit();

    var interp = try llisp.interpreter.Interpreter.init(nogc.gcAllocator(), &p.ast, allocator);
    defer interp.deinit();

    const root_node = p.ast.nodes.items[p.ast.root];
    const root_items = p.ast.listSlice(root_node.data.list);

    for (root_items) |node_id| {
        const v = try interp.astToValue(node_id);
        _ = try interp.eval(v, null);
    }

    if (interp.output.items.len > 0) {
        const len = interp.output.items.len;
        const written = try std.posix.write(std.posix.STDOUT_FILENO, interp.output.items[0..len]);
        _ = written;
    }
}

test {
    std.testing.refAllDecls(llisp);
}
