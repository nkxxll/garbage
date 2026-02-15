const std = @import("std");
const parser = @import("parser.zig");
const val = @import("value.zig");
const gc_mod = @import("gc.zig");
const symbol_mod = @import("symbol.zig");

const Value = val.Value;
const ConsCell = val.ConsCell;
const Closure = val.Closure;
const GcAllocator = gc_mod.GcAllocator;
const SymbolTable = symbol_mod.SymbolTable;

pub const EvalError = error{
    UnboundVariable,
    NotCallable,
    TypeError,
    ArityMismatch,
    DivisionByZero,
    InvalidSyntax,
} || std.mem.Allocator.Error;

pub const Scope = struct {
    table: std.AutoHashMapUnmanaged(u24, Value),
    parent: ?u24,
};

pub const Interpreter = struct {
    const BuiltinFn = *const fn (*Interpreter, Value) EvalError!Value;

    gc: GcAllocator,
    symbols: SymbolTable,
    globals: std.AutoHashMapUnmanaged(u24, Value),
    scopes: std.ArrayList(Scope),
    scope_free: std.ArrayList(u24),
    ast: *const parser.Ast,
    backing: std.mem.Allocator,
    builtins: std.ArrayList(BuiltinFn),
    output: std.ArrayList(u8),

    // Pre-interned symbol IDs for special forms
    sym_quote: u24,
    sym_define: u24,
    sym_set: u24,
    sym_if: u24,
    sym_lambda: u24,
    sym_begin: u24,

    pub fn init(gc: GcAllocator, ast: *const parser.Ast, backing: std.mem.Allocator) !Interpreter {
        var self = Interpreter{
            .gc = gc,
            .symbols = SymbolTable.init(),
            .globals = .{},
            .scopes = .{},
            .scope_free = .{},
            .ast = ast,
            .backing = backing,
            .builtins = .{},
            .output = .{},
            .sym_quote = undefined,
            .sym_define = undefined,
            .sym_set = undefined,
            .sym_if = undefined,
            .sym_lambda = undefined,
            .sym_begin = undefined,
        };

        self.sym_quote = try self.symbols.intern(backing, "quote");
        self.sym_define = try self.symbols.intern(backing, "define");
        self.sym_set = try self.symbols.intern(backing, "set!");
        self.sym_if = try self.symbols.intern(backing, "if");
        self.sym_lambda = try self.symbols.intern(backing, "lambda");
        self.sym_begin = try self.symbols.intern(backing, "begin");

        try self.registerBuiltin("+", builtinAdd);
        try self.registerBuiltin("-", builtinSub);
        try self.registerBuiltin("*", builtinMul);
        try self.registerBuiltin("/", builtinDiv);
        try self.registerBuiltin("cons", builtinCons);
        try self.registerBuiltin("car", builtinCar);
        try self.registerBuiltin("cdr", builtinCdr);
        try self.registerBuiltin("eq?", builtinEq);
        try self.registerBuiltin("null?", builtinNull);
        try self.registerBuiltin("list", builtinList);
        try self.registerBuiltin("display", builtinDisplay);
        try self.registerBuiltin("newline", builtinNewline);
        try self.registerBuiltin("<", builtinLt);
        try self.registerBuiltin(">", builtinGt);
        try self.registerBuiltin("=", builtinNumEq);
        try self.registerBuiltin("not", builtinNot);
        try self.registerBuiltin("set-car!", builtinSetCar);
        try self.registerBuiltin("set-cdr!", builtinSetCdr);

        return self;
    }

    pub fn deinit(self: *Interpreter) void {
        self.globals.deinit(self.backing);
        for (self.scopes.items) |*scope| {
            scope.table.deinit(self.backing);
        }
        self.scopes.deinit(self.backing);
        self.scope_free.deinit(self.backing);
        self.builtins.deinit(self.backing);
        self.symbols.deinit(self.backing);
        self.output.deinit(self.backing);
    }

    fn registerBuiltin(self: *Interpreter, name: []const u8, func: BuiltinFn) !void {
        const sym_id = try self.symbols.intern(self.backing, name);
        const idx: u24 = @intCast(self.builtins.items.len);
        try self.builtins.append(self.backing, func);
        try self.globals.put(self.backing, sym_id, .{ .tag = .builtin, .payload = idx });
    }

    // --- Environment ---

    fn envLookup(self: *Interpreter, scope: ?u24, sym: u24) EvalError!Value {
        var current = scope;
        while (current) |s| {
            if (self.scopes.items[s].table.get(sym)) |v| return v;
            current = self.scopes.items[s].parent;
        }
        if (self.globals.get(sym)) |v| return v;
        return error.UnboundVariable;
    }

    fn envExtend(self: *Interpreter, parent: ?u24, params: Value, args: Value) !u24 {
        const scope_id: u24 = if (self.scope_free.items.len > 0)
            self.scope_free.pop().?
        else blk: {
            const id: u24 = @intCast(self.scopes.items.len);
            try self.scopes.append(self.backing, .{ .table = .{}, .parent = null });
            break :blk id;
        };

        var scope = &self.scopes.items[scope_id];
        scope.parent = parent;
        scope.table.clearRetainingCapacity();

        var p = params;
        var a = args;
        while (p.tag == .cons) {
            const param_sym = self.gc.getCar(p.payload);
            const arg_val = self.gc.getCar(a.payload);
            try scope.table.put(self.backing, param_sym.payload, arg_val);
            p = self.gc.getCdr(p.payload);
            a = self.gc.getCdr(a.payload);
        }

        return scope_id;
    }

    fn envSet(self: *Interpreter, scope: ?u24, sym: u24, v: Value) EvalError!void {
        var current = scope;
        while (current) |s| {
            if (self.scopes.items[s].table.getPtr(sym)) |ptr| {
                ptr.* = v;
                return;
            }
            current = self.scopes.items[s].parent;
        }
        if (self.globals.getPtr(sym)) |ptr| {
            ptr.* = v;
            return;
        }
        return error.UnboundVariable;
    }

    // --- AST → Value ---

    pub fn astToValue(self: *Interpreter, node_id: parser.NodeId) EvalError!Value {
        const node = self.ast.nodes.items[node_id];
        switch (node.tag) {
            .number => {
                const n = std.fmt.parseFloat(f64, node.data.number) catch return error.TypeError;
                return self.gc.alloc(f64, n);
            },
            .symbol => {
                const id = try self.symbols.intern(self.backing, node.data.symbol);
                return Value{ .tag = .symbol, .payload = id };
            },
            .string => {
                const raw = node.data.string;
                const content = raw[1 .. raw.len - 1];
                return self.gc.alloc([]const u8, content);
            },
            .boolean => return if (node.data.boolean) val.true_value else val.false_value,
            .list => {
                const items = self.ast.listSlice(node.data.list);
                var result = val.nil_value;
                var i = items.len;
                while (i > 0) {
                    i -= 1;
                    const v = try self.astToValue(items[i]);
                    self.gc.pushRoot(v);
                    self.gc.pushRoot(result);
                    result = self.gc.alloc(ConsCell, .{ .car = v, .cdr = result });
                    self.gc.popRoot();
                    self.gc.popRoot();
                }
                return result;
            },
            .quote => {
                const inner = try self.astToValue(node.data.quote);
                self.gc.pushRoot(inner);
                const inner_cons = self.gc.alloc(ConsCell, .{ .car = inner, .cdr = val.nil_value });
                self.gc.popRoot();
                const quote_sym = Value{ .tag = .symbol, .payload = self.sym_quote };
                return self.gc.alloc(ConsCell, .{ .car = quote_sym, .cdr = inner_cons });
            },
            .vector => {
                const items = self.ast.listSlice(node.data.vector);
                var converted = std.ArrayList(Value){};
                defer converted.deinit(self.backing);
                for (items) |item_id| {
                    const v = try self.astToValue(item_id);
                    try converted.append(self.backing, v);
                }
                return self.gc.alloc([]const Value, converted.items);
            },
            .dotted_list => {
                const head_items = self.ast.dottedSlice(node.data.dotted_list);
                var result = try self.astToValue(node.data.dotted_list.tail);
                var i = head_items.len;
                while (i > 0) {
                    i -= 1;
                    const v = try self.astToValue(head_items[i]);
                    self.gc.pushRoot(v);
                    self.gc.pushRoot(result);
                    result = self.gc.alloc(ConsCell, .{ .car = v, .cdr = result });
                    self.gc.popRoot();
                    self.gc.popRoot();
                }
                return result;
            },
        }
    }

    // --- Eval ---

    pub fn eval(self: *Interpreter, expr: Value, scope: ?u24) EvalError!Value {
        switch (expr.tag) {
            .number, .boolean, .nil, .string, .vector, .builtin, .closure => return expr,
            .symbol => return self.envLookup(scope, expr.payload),
            .cons => {
                const head_val = self.gc.getCar(expr.payload);
                const args_list = self.gc.getCdr(expr.payload);

                if (head_val.tag == .symbol) {
                    if (head_val.payload == self.sym_quote) return self.evalQuote(args_list);
                    if (head_val.payload == self.sym_define) return self.evalDefine(args_list, scope);
                    if (head_val.payload == self.sym_set) return self.evalSet(args_list, scope);
                    if (head_val.payload == self.sym_if) return self.evalIf(args_list, scope);
                    if (head_val.payload == self.sym_lambda) return self.evalLambda(args_list, scope);
                    if (head_val.payload == self.sym_begin) return self.evalBegin(args_list, scope);
                }

                const func = try self.eval(head_val, scope);
                self.gc.pushRoot(func);
                const evaled_args = try self.evalArgList(args_list, scope);
                self.gc.popRoot();
                return self.apply(func, evaled_args);
            },
        }
    }

    fn evalQuote(self: *Interpreter, args: Value) Value {
        return self.gc.getCar(args.payload);
    }

    fn evalDefine(self: *Interpreter, args: Value, scope: ?u24) EvalError!Value {
        const first = self.gc.getCar(args.payload);
        if (first.tag == .symbol) {
            // (define sym expr)
            const expr = self.gc.getCar(self.gc.getCdr(args.payload).payload);
            const result = try self.eval(expr, scope);
            try self.globals.put(self.backing, first.payload, result);
        } else if (first.tag == .cons) {
            // (define (name params...) body...)
            const name = self.gc.getCar(first.payload);
            const params = self.gc.getCdr(first.payload);
            const body = self.gc.getCdr(args.payload);
            const arity: u16 = @intCast(self.listLen(params));
            const env_id: u24 = if (scope) |s| s else std.math.maxInt(u24);
            const closure = self.gc.alloc(Closure, .{
                .params = params,
                .body = body,
                .env_id = env_id,
                .arity = arity,
            });
            try self.globals.put(self.backing, name.payload, closure);
        } else {
            return error.InvalidSyntax;
        }
        return val.nil_value;
    }

    fn evalSet(self: *Interpreter, args: Value, scope: ?u24) EvalError!Value {
        const sym = self.gc.getCar(args.payload);
        const expr = self.gc.getCar(self.gc.getCdr(args.payload).payload);
        const result = try self.eval(expr, scope);
        try self.envSet(scope, sym.payload, result);
        return val.nil_value;
    }

    fn evalIf(self: *Interpreter, args: Value, scope: ?u24) EvalError!Value {
        const test_expr = self.gc.getCar(args.payload);
        const rest = self.gc.getCdr(args.payload);
        const then_expr = self.gc.getCar(rest.payload);
        const else_rest = self.gc.getCdr(rest.payload);

        const test_val = try self.eval(test_expr, scope);
        if (!test_val.eql(val.false_value) and !test_val.eql(val.nil_value)) {
            return self.eval(then_expr, scope);
        } else if (else_rest.tag != .nil) {
            return self.eval(self.gc.getCar(else_rest.payload), scope);
        } else {
            return val.nil_value;
        }
    }

    fn evalLambda(self: *Interpreter, args: Value, scope: ?u24) EvalError!Value {
        const params = self.gc.getCar(args.payload);
        const body = self.gc.getCdr(args.payload);
        const arity: u16 = @intCast(self.listLen(params));
        const env_id: u24 = if (scope) |s| s else std.math.maxInt(u24);
        return self.gc.alloc(Closure, .{
            .params = params,
            .body = body,
            .env_id = env_id,
            .arity = arity,
        });
    }

    fn evalBegin(self: *Interpreter, args: Value, scope: ?u24) EvalError!Value {
        var current = args;
        var result = val.nil_value;
        while (current.tag == .cons) {
            result = try self.eval(self.gc.getCar(current.payload), scope);
            current = self.gc.getCdr(current.payload);
        }
        return result;
    }

    fn evalArgList(self: *Interpreter, list: Value, scope: ?u24) EvalError!Value {
        if (list.tag == .nil) return val.nil_value;
        if (list.tag != .cons) return error.TypeError;

        const evaled_car = try self.eval(self.gc.getCar(list.payload), scope);
        self.gc.pushRoot(evaled_car);
        const evaled_cdr = try self.evalArgList(self.gc.getCdr(list.payload), scope);
        self.gc.popRoot();
        return self.gc.alloc(ConsCell, .{ .car = evaled_car, .cdr = evaled_cdr });
    }

    // --- Apply ---

    fn apply(self: *Interpreter, func: Value, args: Value) EvalError!Value {
        switch (func.tag) {
            .builtin => {
                return self.builtins.items[func.payload](self, args);
            },
            .closure => {
                const c = self.gc.getClosure(func.payload);
                const parent_scope: ?u24 = if (c.env_id == std.math.maxInt(u24)) null else c.env_id;
                const new_scope = try self.envExtend(parent_scope, c.params, args);
                return self.evalBegin(c.body, new_scope);
            },
            else => return error.NotCallable,
        }
    }

    // --- Helpers ---

    fn listLen(self: *Interpreter, list: Value) usize {
        var count: usize = 0;
        var current = list;
        while (current.tag == .cons) {
            count += 1;
            current = self.gc.getCdr(current.payload);
        }
        return count;
    }

    fn getNum(self: *Interpreter, v: Value) EvalError!f64 {
        if (v.tag != .number) return error.TypeError;
        return self.gc.getNumber(v.payload);
    }

    fn args2(self: *Interpreter, args: Value) struct { Value, Value } {
        const a = self.gc.getCar(args.payload);
        const b = self.gc.getCar(self.gc.getCdr(args.payload).payload);
        return .{ a, b };
    }

    // --- Value display ---

    pub fn writeValue(self: *Interpreter, v: Value) !void {
        switch (v.tag) {
            .nil => try self.output.appendSlice(self.backing, "()"),
            .number => {
                const n = self.gc.getNumber(v.payload);
                if (n == @trunc(n) and !std.math.isNan(n) and !std.math.isInf(n) and @abs(n) < 1e15) {
                    var buf: [32]u8 = undefined;
                    const str = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(n))}) catch unreachable;
                    try self.output.appendSlice(self.backing, str);
                } else {
                    var buf: [64]u8 = undefined;
                    const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
                    try self.output.appendSlice(self.backing, str);
                }
            },
            .boolean => try self.output.appendSlice(self.backing, if (v.payload == 1) "#t" else "#f"),
            .symbol => try self.output.appendSlice(self.backing, self.symbols.getName(v.payload)),
            .string => try self.output.appendSlice(self.backing, self.gc.getString(v.payload)),
            .cons => {
                try self.output.append(self.backing, '(');
                try self.writeValue(self.gc.getCar(v.payload));
                var cdr = self.gc.getCdr(v.payload);
                while (cdr.tag == .cons) {
                    try self.output.append(self.backing, ' ');
                    try self.writeValue(self.gc.getCar(cdr.payload));
                    cdr = self.gc.getCdr(cdr.payload);
                }
                if (cdr.tag != .nil) {
                    try self.output.appendSlice(self.backing, " . ");
                    try self.writeValue(cdr);
                }
                try self.output.append(self.backing, ')');
            },
            .vector => {
                try self.output.appendSlice(self.backing, "#(");
                const items = self.gc.getVectorSlice(v.payload);
                for (items, 0..) |item, i| {
                    if (i > 0) try self.output.append(self.backing, ' ');
                    try self.writeValue(item);
                }
                try self.output.append(self.backing, ')');
            },
            .closure => try self.output.appendSlice(self.backing, "#<closure>"),
            .builtin => try self.output.appendSlice(self.backing, "#<builtin>"),
        }
    }

    // --- Builtins ---

    fn builtinAdd(self: *Interpreter, args: Value) EvalError!Value {
        const a, const b = self.args2(args);
        return self.gc.alloc(f64, try self.getNum(a) + try self.getNum(b));
    }

    fn builtinSub(self: *Interpreter, args: Value) EvalError!Value {
        const a, const b = self.args2(args);
        return self.gc.alloc(f64, try self.getNum(a) - try self.getNum(b));
    }

    fn builtinMul(self: *Interpreter, args: Value) EvalError!Value {
        const a, const b = self.args2(args);
        return self.gc.alloc(f64, try self.getNum(a) * try self.getNum(b));
    }

    fn builtinDiv(self: *Interpreter, args: Value) EvalError!Value {
        const a, const b = self.args2(args);
        const bn = try self.getNum(b);
        if (bn == 0) return error.DivisionByZero;
        return self.gc.alloc(f64, try self.getNum(a) / bn);
    }

    fn builtinCons(self: *Interpreter, args: Value) EvalError!Value {
        const a, const b = self.args2(args);
        return self.gc.alloc(ConsCell, .{ .car = a, .cdr = b });
    }

    fn builtinCar(self: *Interpreter, args: Value) EvalError!Value {
        const pair = self.gc.getCar(args.payload);
        if (pair.tag != .cons) return error.TypeError;
        return self.gc.getCar(pair.payload);
    }

    fn builtinCdr(self: *Interpreter, args: Value) EvalError!Value {
        const pair = self.gc.getCar(args.payload);
        if (pair.tag != .cons) return error.TypeError;
        return self.gc.getCdr(pair.payload);
    }

    fn builtinEq(self: *Interpreter, args: Value) EvalError!Value {
        const a, const b = self.args2(args);
        if (a.tag == .number and b.tag == .number) {
            return if (self.gc.getNumber(a.payload) == self.gc.getNumber(b.payload))
                val.true_value
            else
                val.false_value;
        }
        return if (a.eql(b)) val.true_value else val.false_value;
    }

    fn builtinNull(self: *Interpreter, args: Value) EvalError!Value {
        const a = self.gc.getCar(args.payload);
        return if (a.tag == .nil) val.true_value else val.false_value;
    }

    fn builtinList(_: *Interpreter, args: Value) EvalError!Value {
        return args;
    }

    fn builtinDisplay(self: *Interpreter, args: Value) EvalError!Value {
        const v = self.gc.getCar(args.payload);
        try self.writeValue(v);
        return val.nil_value;
    }

    fn builtinNewline(self: *Interpreter, _: Value) EvalError!Value {
        try self.output.append(self.backing, '\n');
        return val.nil_value;
    }

    fn builtinLt(self: *Interpreter, args: Value) EvalError!Value {
        const a, const b = self.args2(args);
        return if (try self.getNum(a) < try self.getNum(b)) val.true_value else val.false_value;
    }

    fn builtinGt(self: *Interpreter, args: Value) EvalError!Value {
        const a, const b = self.args2(args);
        return if (try self.getNum(a) > try self.getNum(b)) val.true_value else val.false_value;
    }

    fn builtinNumEq(self: *Interpreter, args: Value) EvalError!Value {
        const a, const b = self.args2(args);
        return if (try self.getNum(a) == try self.getNum(b)) val.true_value else val.false_value;
    }

    fn builtinNot(self: *Interpreter, args: Value) EvalError!Value {
        const a = self.gc.getCar(args.payload);
        return if (a.eql(val.false_value) or a.eql(val.nil_value)) val.true_value else val.false_value;
    }

    fn builtinSetCar(self: *Interpreter, args: Value) EvalError!Value {
        const pair, const new_val = self.args2(args);
        if (pair.tag != .cons) return error.TypeError;
        self.gc.setCar(pair.payload, new_val);
        self.gc.writeBarrier(pair, new_val);
        return val.nil_value;
    }

    fn builtinSetCdr(self: *Interpreter, args: Value) EvalError!Value {
        const pair, const new_val = self.args2(args);
        if (pair.tag != .cons) return error.TypeError;
        self.gc.setCdr(pair.payload, new_val);
        self.gc.writeBarrier(pair, new_val);
        return val.nil_value;
    }
};

// --- Tests ---

fn testEval(source: [:0]const u8) !struct { value: Value, number: f64, output: []const u8 } {
    const allocator = std.testing.allocator;
    var p = parser.Parser.init(allocator, source);
    _ = try p.parseRoot();
    defer p.ast.deinit();

    var nogc = gc_mod.NoGc.init(allocator);
    defer nogc.deinit();

    var interp = try Interpreter.init(nogc.gcAllocator(), &p.ast, allocator);
    defer interp.deinit();

    const root_node = p.ast.nodes.items[p.ast.root];
    const root_items = p.ast.listSlice(root_node.data.list);

    var last_result = val.nil_value;
    for (root_items) |node_id| {
        const v = try interp.astToValue(node_id);
        last_result = try interp.eval(v, null);
    }

    const number = if (last_result.tag == .number) interp.gc.getNumber(last_result.payload) else 0;
    // Copy output before cleanup
    const output = try allocator.dupe(u8, interp.output.items);
    return .{ .value = last_result, .number = number, .output = output };
}

test "eval: (+ 1 2) = 3" {
    const r = try testEval("(+ 1 2)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectEqual(val.ValueTag.number, r.value.tag);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), r.number, 0.001);
}

test "eval: (define x 10) x = 10" {
    const r = try testEval("(define x 10) x");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), r.number, 0.001);
}

test "eval: (if #t 1 2) = 1" {
    const r = try testEval("(if #t 1 2)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r.number, 0.001);
}

test "eval: (if #f 1 2) = 2" {
    const r = try testEval("(if #f 1 2)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), r.number, 0.001);
}

test "eval: ((lambda (x) x) 42) = 42" {
    const r = try testEval("((lambda (x) x) 42)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), r.number, 0.001);
}

test "eval: factorial (fact 5) = 120" {
    const r = try testEval("(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 5)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), r.number, 0.001);
}

test "eval: (car (cons 1 2)) = 1" {
    const r = try testEval("(car (cons 1 2))");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r.number, 0.001);
}

test "eval: (cdr (cons 1 2)) = 2" {
    const r = try testEval("(cdr (cons 1 2))");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), r.number, 0.001);
}

test "eval: (eq? 1 1) = #t" {
    const r = try testEval("(eq? 1 1)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.value.eql(val.true_value));
}

test "eval: (null? ()) = #t" {
    const r = try testEval("(null? ())");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.value.eql(val.true_value));
}

test "eval: quote returns unevaluated" {
    const r = try testEval("'foo");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectEqual(val.ValueTag.symbol, r.value.tag);
}

test "eval: (begin 1 2 3) = 3" {
    const r = try testEval("(begin 1 2 3)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), r.number, 0.001);
}

test "eval: set! mutates binding" {
    const r = try testEval("(define x 1) (set! x 20) x");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), r.number, 0.001);
}

test "eval: (list 1 2 3) builds list" {
    const r = try testEval("(car (list 1 2 3))");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r.number, 0.001);
}

test "eval: nested lambda (closure)" {
    const r = try testEval("(define (make-adder n) (lambda (x) (+ n x))) ((make-adder 10) 5)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), r.number, 0.001);
}
