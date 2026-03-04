const std = @import("std");
const parser = @import("parser.zig");
const val = @import("value.zig");
const gc_mod = @import("gc.zig");
const symbol_mod = @import("symbol.zig");

const SymbolTable = symbol_mod.SymbolTable;

pub const EvalError = error{
    UnboundVariable,
    NotCallable,
    TypeError,
    ArityMismatch,
    DivisionByZero,
    InvalidSyntax,
} || std.mem.Allocator.Error;

pub fn InterpreterFor(comptime GcAlloc: type) type {
    const V = GcAlloc.ValueType;
    const ConsCellT = val.ConsCellFor(V);
    const ClosureT = val.ClosureFor(V);
    const ScopeT = gc_mod.ScopeFor(V);

    return struct {
        const Self = @This();
        const BuiltinFn = *const fn (*Self, V) EvalError!V;

        gc: GcAlloc,
        symbols: SymbolTable,
        globals: std.AutoHashMapUnmanaged(usize, V),
        ast: *const parser.Ast,
        backing: std.mem.Allocator,
        builtins: std.ArrayList(BuiltinFn),
        output: std.ArrayList(u8),

        // Pre-interned symbol IDs for special forms
        sym_quote: usize,
        sym_define: usize,
        sym_set: usize,
        sym_if: usize,
        sym_lambda: usize,
        sym_begin: usize,

        pub fn init(gc: GcAlloc, ast: *const parser.Ast, backing: std.mem.Allocator) !Self {
            var self = Self{
                .gc = gc,
                .symbols = SymbolTable.init(),
                .globals = .{},
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

        pub fn deinit(self: *Self) void {
            self.globals.deinit(self.backing);
            self.builtins.deinit(self.backing);
            self.symbols.deinit(self.backing);
            self.output.deinit(self.backing);
        }

        fn registerBuiltin(self: *Self, name: []const u8, func: BuiltinFn) !void {
            const sym_id = try self.symbols.intern(self.backing, name);
            const idx = self.builtins.items.len;
            try self.builtins.append(self.backing, func);
            try self.globals.put(self.backing, sym_id, V.from_index(.builtin, idx));
        }

        // --- Environment ---

        fn envLookup(self: *Self, scope: ?usize, sym: usize) EvalError!V {
            var current = scope;
            while (current) |s| {
                const sc = self.gc.getScope(s);
                if (sc.table.get(sym)) |v| return v;
                current = sc.parent;
            }
            if (self.globals.get(sym)) |v| return v;
            return error.UnboundVariable;
        }

        fn envExtend(self: *Self, parent: ?usize, params: V, args: V) !usize {
            const scope_val = self.gc.alloc(ScopeT, .{ .table = .{}, .parent = parent, .alloc = self.backing });
            const scope_id = scope_val.data;

            var scope = self.gc.getScope(scope_id);

            var p = params;
            var a = args;
            while (p.tag == .cons) {
                const param_sym = self.gc.getCar(p.data);
                const arg_val = self.gc.getCar(a.data);
                try scope.table.put(self.backing, param_sym.data, arg_val);
                p = self.gc.getCdr(p.data);
                a = self.gc.getCdr(a.data);
            }

            return scope_id;
        }

        fn envSet(self: *Self, scope: ?usize, sym: usize, v: V) EvalError!void {
            var current = scope;
            while (current) |s| {
                const sc = self.gc.getScope(s);
                if (sc.table.getPtr(sym)) |ptr| {
                    ptr.* = v;
                    return;
                }
                current = sc.parent;
            }
            if (self.globals.getPtr(sym)) |ptr| {
                ptr.* = v;
                return;
            }
            return error.UnboundVariable;
        }

        // --- AST → Value ---

        pub fn astToValue(self: *Self, node_id: parser.NodeId) EvalError!V {
            const node = self.ast.nodes.items[node_id];
            switch (node.tag) {
                .number => {
                    const n = std.fmt.parseFloat(f64, node.data.number) catch return error.TypeError;
                    return self.gc.alloc(f64, n);
                },
                .symbol => {
                    const id = try self.symbols.intern(self.backing, node.data.symbol);
                    return V.from_index(.symbol, id);
                },
                .string => {
                    const raw = node.data.string;
                    const content = raw[1 .. raw.len - 1];
                    return self.gc.alloc([]const u8, content);
                },
                .boolean => return if (node.data.boolean) V.true_value else V.false_value,
                .list => {
                    const items = self.ast.listSlice(node.data.list);
                    var result = V.nil_value;
                    var i = items.len;
                    while (i > 0) {
                        i -= 1;
                        self.gc.pushRoot(result);
                        const v = try self.astToValue(items[i]);
                        self.gc.pushRoot(v);
                        result = self.gc.alloc(ConsCellT, .{ .car = v, .cdr = result });
                        self.gc.popRoot();
                        self.gc.popRoot();
                    }
                    return result;
                },
                .quote => {
                    const inner = try self.astToValue(node.data.quote);
                    self.gc.pushRoot(inner);
                    const inner_cons = self.gc.alloc(ConsCellT, .{ .car = inner, .cdr = V.nil_value });
                    self.gc.popRoot();
                    const quote_sym = V.from_index(.symbol, self.sym_quote);
                    return self.gc.alloc(ConsCellT, .{ .car = quote_sym, .cdr = inner_cons });
                },
                .vector => {
                    const items = self.ast.listSlice(node.data.vector);
                    var converted = std.ArrayList(V){};
                    defer converted.deinit(self.backing);
                    for (items) |item_id| {
                        const v = try self.astToValue(item_id);
                        try converted.append(self.backing, v);
                    }
                    return self.gc.alloc([]const V, converted.items);
                },
                .dotted_list => {
                    const head_items = self.ast.dottedSlice(node.data.dotted_list);
                    var result = try self.astToValue(node.data.dotted_list.tail);
                    var i = head_items.len;
                    while (i > 0) {
                        i -= 1;
                        self.gc.pushRoot(result);
                        const v = try self.astToValue(head_items[i]);
                        self.gc.pushRoot(v);
                        result = self.gc.alloc(ConsCellT, .{ .car = v, .cdr = result });
                        self.gc.popRoot();
                        self.gc.popRoot();
                    }
                    return result;
                },
            }
        }

        // --- Eval ---

        pub fn eval(self: *Self, expr: V, scope: ?usize) EvalError!V {
            switch (expr.tag) {
                .number, .boolean, .nil, .string, .vector, .builtin, .closure, .scope => return expr,
                .symbol => return self.envLookup(scope, expr.data),
                .cons => {
                    self.gc.pushRoot(expr);
                    defer self.gc.popRoot();
                    const head_val = self.gc.getCar(expr.data);
                    const args_list = self.gc.getCdr(expr.data);

                    if (head_val.tag == .symbol) {
                        if (head_val.data == self.sym_quote) return self.evalQuote(args_list);
                        if (head_val.data == self.sym_define) return self.evalDefine(args_list, scope);
                        if (head_val.data == self.sym_set) return self.evalSet(args_list, scope);
                        if (head_val.data == self.sym_if) return self.evalIf(args_list, scope);
                        if (head_val.data == self.sym_lambda) return self.evalLambda(args_list, scope);
                        if (head_val.data == self.sym_begin) return self.evalBegin(args_list, scope);
                    }

                    const func = try self.eval(head_val, scope);
                    self.gc.pushRoot(func);
                    const evaled_args = try self.evalArgList(args_list, scope);
                    self.gc.pushRoot(evaled_args);
                    const result = try self.apply(func, evaled_args);
                    self.gc.popRoot();
                    self.gc.popRoot();
                    return result;
                },
            }
        }

        fn evalQuote(self: *Self, args: V) V {
            return self.gc.getCar(args.data);
        }

        fn evalDefine(self: *Self, args: V, scope: ?usize) EvalError!V {
            const first = self.gc.getCar(args.data);
            if (first.tag == .symbol) {
                // (define sym expr)
                const expr = self.gc.getCar(self.gc.getCdr(args.data).data);
                const result = try self.eval(expr, scope);
                try self.globals.put(self.backing, first.data, result);
            } else if (first.tag == .cons) {
                // (define (name params...) body...)
                const name = self.gc.getCar(first.data);
                const params = self.gc.getCdr(first.data);
                const body = self.gc.getCdr(args.data);
                const arity: u16 = @intCast(self.listLen(params));
                const env_id: usize = if (scope) |s| s else std.math.maxInt(usize);
                self.gc.pushRoot(params);
                self.gc.pushRoot(body);
                const closure = self.gc.alloc(ClosureT, .{
                    .params = params,
                    .body = body,
                    .env_id = env_id,
                    .arity = arity,
                });
                self.gc.popRoot();
                self.gc.popRoot();
                try self.globals.put(self.backing, name.data, closure);
            } else {
                return error.InvalidSyntax;
            }
            return V.nil_value;
        }

        fn evalSet(self: *Self, args: V, scope: ?usize) EvalError!V {
            const sym = self.gc.getCar(args.data);
            const expr = self.gc.getCar(self.gc.getCdr(args.data).data);
            const result = try self.eval(expr, scope);
            try self.envSet(scope, sym.data, result);
            return V.nil_value;
        }

        fn evalIf(self: *Self, args: V, scope: ?usize) EvalError!V {
            const test_expr = self.gc.getCar(args.data);
            const rest = self.gc.getCdr(args.data);
            const then_expr = self.gc.getCar(rest.data);
            const else_rest = self.gc.getCdr(rest.data);

            const test_val = try self.eval(test_expr, scope);
            if (!test_val.eql(V.false_value) and !test_val.eql(V.nil_value)) {
                return self.eval(then_expr, scope);
            } else if (else_rest.tag != .nil) {
                return self.eval(self.gc.getCar(else_rest.data), scope);
            } else {
                return V.nil_value;
            }
        }

        fn evalLambda(self: *Self, args: V, scope: ?usize) EvalError!V {
            const params = self.gc.getCar(args.data);
            const body = self.gc.getCdr(args.data);
            const arity: u16 = @intCast(self.listLen(params));
            const env_id: usize = if (scope) |s| s else std.math.maxInt(usize);
            self.gc.pushRoot(params);
            self.gc.pushRoot(body);
            const result = self.gc.alloc(ClosureT, .{
                .params = params,
                .body = body,
                .env_id = env_id,
                .arity = arity,
            });
            self.gc.popRoot();
            self.gc.popRoot();
            return result;
        }

        fn evalBegin(self: *Self, args: V, scope: ?usize) EvalError!V {
            var current = args;
            var result = V.nil_value;
            while (current.tag == .cons) {
                result = try self.eval(self.gc.getCar(current.data), scope);
                current = self.gc.getCdr(current.data);
            }
            return result;
        }

        fn evalArgList(self: *Self, list: V, scope: ?usize) EvalError!V {
            if (list.tag == .nil) return V.nil_value;
            if (list.tag != .cons) return error.TypeError;

            const evaled_car = try self.eval(self.gc.getCar(list.data), scope);
            self.gc.pushRoot(evaled_car);
            const evaled_cdr = try self.evalArgList(self.gc.getCdr(list.data), scope);
            self.gc.pushRoot(evaled_cdr);
            const result = self.gc.alloc(ConsCellT, .{ .car = evaled_car, .cdr = evaled_cdr });
            self.gc.popRoot();
            self.gc.popRoot();
            return result;
        }

        // --- Apply ---

        fn apply(self: *Self, func: V, args: V) EvalError!V {
            switch (func.tag) {
                .builtin => {
                    return self.builtins.items[func.data](self, args);
                },
                .closure => {
                    const c = self.gc.getClosure(func.data);
                    const parent_scope: ?usize = if (c.env_id == std.math.maxInt(usize)) null else c.env_id;
                    const new_scope = try self.envExtend(parent_scope, c.params, args);
                    self.gc.pushRoot(V.from_index(.scope, new_scope));
                    const result = try self.evalBegin(c.body, new_scope);
                    self.gc.popRoot();
                    return result;
                },
                else => return error.NotCallable,
            }
        }

        // --- Helpers ---

        fn listLen(self: *Self, list: V) usize {
            var count: usize = 0;
            var current = list;
            while (current.tag == .cons) {
                count += 1;
                current = self.gc.getCdr(current.data);
            }
            return count;
        }

        fn getNum(self: *Self, v: V) EvalError!f64 {
            if (v.tag != .number) return error.TypeError;
            return self.gc.getNumber(v.data);
        }

        fn args2(self: *Self, args: V) struct { V, V } {
            const a = self.gc.getCar(args.data);
            const b = self.gc.getCar(self.gc.getCdr(args.data).data);
            return .{ a, b };
        }

        // --- Value display ---

        pub fn writeValue(self: *Self, v: V) !void {
            switch (v.tag) {
                .nil => try self.output.appendSlice(self.backing, "()"),
                .number => {
                    const n = self.gc.getNumber(v.data);
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
                .boolean => try self.output.appendSlice(self.backing, if (v.data == 1) "#t" else "#f"),
                .symbol => try self.output.appendSlice(self.backing, self.symbols.getName(@intCast(v.data))),
                .string => try self.output.appendSlice(self.backing, self.gc.getString(v.data)),
                .cons => {
                    try self.output.append(self.backing, '(');
                    try self.writeValue(self.gc.getCar(v.data));
                    var cdr = self.gc.getCdr(v.data);
                    while (cdr.tag == .cons) {
                        try self.output.append(self.backing, ' ');
                        try self.writeValue(self.gc.getCar(cdr.data));
                        cdr = self.gc.getCdr(cdr.data);
                    }
                    if (cdr.tag != .nil) {
                        try self.output.appendSlice(self.backing, " . ");
                        try self.writeValue(cdr);
                    }
                    try self.output.append(self.backing, ')');
                },
                .vector => {
                    try self.output.appendSlice(self.backing, "#(");
                    const items = self.gc.getVectorSlice(v.data);
                    for (items, 0..) |item, i| {
                        if (i > 0) try self.output.append(self.backing, ' ');
                        try self.writeValue(item);
                    }
                    try self.output.append(self.backing, ')');
                },
                .closure => try self.output.appendSlice(self.backing, "#<closure>"),
                .builtin => try self.output.appendSlice(self.backing, "#<builtin>"),
                .scope => try self.output.appendSlice(self.backing, "#<scope>"),
            }
        }

        // --- Builtins ---

        fn builtinAdd(self: *Self, args: V) EvalError!V {
            const a, const b = self.args2(args);
            return self.gc.alloc(f64, try self.getNum(a) + try self.getNum(b));
        }

        fn builtinSub(self: *Self, args: V) EvalError!V {
            const a, const b = self.args2(args);
            return self.gc.alloc(f64, try self.getNum(a) - try self.getNum(b));
        }

        fn builtinMul(self: *Self, args: V) EvalError!V {
            const a, const b = self.args2(args);
            return self.gc.alloc(f64, try self.getNum(a) * try self.getNum(b));
        }

        fn builtinDiv(self: *Self, args: V) EvalError!V {
            const a, const b = self.args2(args);
            const bn = try self.getNum(b);
            if (bn == 0) return error.DivisionByZero;
            return self.gc.alloc(f64, try self.getNum(a) / bn);
        }

        fn builtinCons(self: *Self, args: V) EvalError!V {
            const a, const b = self.args2(args);
            return self.gc.alloc(ConsCellT, .{ .car = a, .cdr = b });
        }

        fn builtinCar(self: *Self, args: V) EvalError!V {
            const pair = self.gc.getCar(args.data);
            if (pair.tag != .cons) return error.TypeError;
            return self.gc.getCar(pair.data);
        }

        fn builtinCdr(self: *Self, args: V) EvalError!V {
            const pair = self.gc.getCar(args.data);
            if (pair.tag != .cons) return error.TypeError;
            return self.gc.getCdr(pair.data);
        }

        fn builtinEq(self: *Self, args: V) EvalError!V {
            const a, const b = self.args2(args);
            if (a.tag == .number and b.tag == .number) {
                return if (self.gc.getNumber(a.data) == self.gc.getNumber(b.data))
                    V.true_value
                else
                    V.false_value;
            }
            return if (a.eql(b)) V.true_value else V.false_value;
        }

        fn builtinNull(self: *Self, args: V) EvalError!V {
            const a = self.gc.getCar(args.data);
            return if (a.tag == .nil) V.true_value else V.false_value;
        }

        fn builtinList(_: *Self, args: V) EvalError!V {
            return args;
        }

        fn builtinDisplay(self: *Self, args: V) EvalError!V {
            const v = self.gc.getCar(args.data);
            try self.writeValue(v);
            return V.nil_value;
        }

        fn builtinNewline(self: *Self, _: V) EvalError!V {
            try self.output.append(self.backing, '\n');
            return V.nil_value;
        }

        fn builtinLt(self: *Self, args: V) EvalError!V {
            const a, const b = self.args2(args);
            return if (try self.getNum(a) < try self.getNum(b)) V.true_value else V.false_value;
        }

        fn builtinGt(self: *Self, args: V) EvalError!V {
            const a, const b = self.args2(args);
            return if (try self.getNum(a) > try self.getNum(b)) V.true_value else V.false_value;
        }

        fn builtinNumEq(self: *Self, args: V) EvalError!V {
            const a, const b = self.args2(args);
            return if (try self.getNum(a) == try self.getNum(b)) V.true_value else V.false_value;
        }

        fn builtinNot(self: *Self, args: V) EvalError!V {
            const a = self.gc.getCar(args.data);
            return if (a.eql(V.false_value) or a.eql(V.nil_value)) V.true_value else V.false_value;
        }

        fn builtinSetCar(self: *Self, args: V) EvalError!V {
            const pair, const new_val = self.args2(args);
            if (pair.tag != .cons) return error.TypeError;
            self.gc.setCar(pair.data, new_val);
            return V.nil_value;
        }

        fn builtinSetCdr(self: *Self, args: V) EvalError!V {
            const pair, const new_val = self.args2(args);
            if (pair.tag != .cons) return error.TypeError;
            self.gc.setCdr(pair.data, new_val);
            return V.nil_value;
        }
    };
}

const Interpreter = InterpreterFor(gc_mod.GcAllocator);

// --- Tests ---

const Value = val.Value;

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

    const number = if (last_result.tag == .number) interp.gc.getNumber(last_result.data) else 0;
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

// --- GC tests ---

fn testEvalGc(source: [:0]const u8) !struct { value: Value, number: f64, output: []const u8 } {
    const allocator = std.testing.allocator;
    var p = parser.Parser.init(allocator, source);
    _ = try p.parseRoot();
    defer p.ast.deinit();

    var ms = gc_mod.MarkAndSweepGPABacked.init(allocator);
    defer ms.deinit();

    var interp = try Interpreter.init(ms.gcAllocator(), &p.ast, allocator);
    defer interp.deinit();
    ms.bindInterpreter(&interp.globals);

    const root_node = p.ast.nodes.items[p.ast.root];
    const root_items = p.ast.listSlice(root_node.data.list);

    var last_result = val.nil_value;
    for (root_items) |node_id| {
        const v = try interp.astToValue(node_id);
        last_result = try interp.eval(v, null);
    }

    const number = if (last_result.tag == .number) interp.gc.getNumber(last_result.data) else 0;
    const output = try allocator.dupe(u8, interp.output.items);
    return .{ .value = last_result, .number = number, .output = output };
}

test "eval-gc: (+ 1 2) = 3" {
    const r = try testEvalGc("(+ 1 2)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectEqual(val.ValueTag.number, r.value.tag);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), r.number, 0.001);
}

test "eval-gc: (define x 10) x = 10" {
    const r = try testEvalGc("(define x 10) x");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), r.number, 0.001);
}

test "eval-gc: (if #t 1 2) = 1" {
    const r = try testEvalGc("(if #t 1 2)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r.number, 0.001);
}

test "eval-gc: (if #f 1 2) = 2" {
    const r = try testEvalGc("(if #f 1 2)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), r.number, 0.001);
}

test "eval-gc: ((lambda (x) x) 42) = 42" {
    const r = try testEvalGc("((lambda (x) x) 42)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), r.number, 0.001);
}

test "eval-gc: factorial (fact 5) = 120" {
    const r = try testEvalGc("(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 5)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), r.number, 0.001);
}

test "eval-gc: (car (cons 1 2)) = 1" {
    const r = try testEvalGc("(car (cons 1 2))");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r.number, 0.001);
}

test "eval-gc: (cdr (cons 1 2)) = 2" {
    const r = try testEvalGc("(cdr (cons 1 2))");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), r.number, 0.001);
}

test "eval-gc: (eq? 1 1) = #t" {
    const r = try testEvalGc("(eq? 1 1)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.value.eql(val.true_value));
}

test "eval-gc: (null? ()) = #t" {
    const r = try testEvalGc("(null? ())");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.value.eql(val.true_value));
}

test "eval-gc: quote returns unevaluated" {
    const r = try testEvalGc("'foo");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectEqual(val.ValueTag.symbol, r.value.tag);
}

test "eval-gc: (begin 1 2 3) = 3" {
    const r = try testEvalGc("(begin 1 2 3)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), r.number, 0.001);
}

test "eval-gc: set! mutates binding" {
    const r = try testEvalGc("(define x 1) (set! x 20) x");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), r.number, 0.001);
}

test "eval-gc: (list 1 2 3) builds list" {
    const r = try testEvalGc("(car (list 1 2 3))");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r.number, 0.001);
}

test "eval-gc: nested lambda (closure)" {
    const r = try testEvalGc("(define (make-adder n) (lambda (x) (+ n x))) ((make-adder 10) 5)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), r.number, 0.001);
}

// --- GC stress tests ---

test "eval-gc: allocation pressure (sum 30 exceeds GC threshold)" {
    const r = try testEvalGc("(define (sum n) (if (= n 0) 0 (+ n (sum (- n 1))))) (sum 30)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 465.0), r.number, 0.001);
}

test "eval-gc: closure survives GC cycles" {
    const r = try testEvalGc(
        \\(define (make-adder n) (lambda (x) (+ n x)))
        \\(define add5 (make-adder 5))
        \\(+ 0 1) (+ 0 2) (+ 0 3) (+ 0 4) (+ 0 5)
        \\(+ 0 6) (+ 0 7) (+ 0 8) (+ 0 9) (+ 0 10)
        \\(+ 0 11) (+ 0 12) (+ 0 13) (+ 0 14) (+ 0 15)
        \\(+ 0 16) (+ 0 17) (+ 0 18) (+ 0 19) (+ 0 20)
        \\(+ 0 21) (+ 0 22) (+ 0 23) (+ 0 24) (+ 0 25)
        \\(+ 0 26) (+ 0 27) (+ 0 28) (+ 0 29) (+ 0 30)
        \\(add5 10)
    );
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), r.number, 0.001);
}

test "eval-gc: long list building and traversal" {
    const r = try testEvalGc(
        \\(define (build n)
        \\  (if (= n 0)
        \\      (list)
        \\      (cons n (build (- n 1)))))
        \\(define (sum-list xs)
        \\  (if (null? xs) 0 (+ (car xs) (sum-list (cdr xs)))))
        \\(sum-list (build 30))
    );
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 465.0), r.number, 0.001);
}

test "eval-gc: set! mutation after GC cycles" {
    const r = try testEvalGc(
        \\(define x (cons 1 2))
        \\(+ 0 1) (+ 0 2) (+ 0 3) (+ 0 4) (+ 0 5)
        \\(+ 0 6) (+ 0 7) (+ 0 8) (+ 0 9) (+ 0 10)
        \\(+ 0 11) (+ 0 12) (+ 0 13) (+ 0 14) (+ 0 15)
        \\(+ 0 16) (+ 0 17) (+ 0 18) (+ 0 19) (+ 0 20)
        \\(+ 0 21) (+ 0 22) (+ 0 23) (+ 0 24) (+ 0 25)
        \\(+ 0 26) (+ 0 27) (+ 0 28) (+ 0 29) (+ 0 30)
        \\(set-car! x 99)
        \\(car x)
    );
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), r.number, 0.001);
}

test "eval-gc: multiple higher-order functions (scope reuse bug)" {
    const r = try testEvalGc(
        \\(define (map fn lst)
        \\  (if (null? lst) (list) (cons (fn (car lst)) (map fn (cdr lst)))))
        \\(define (filter pred lst)
        \\  (if (null? lst) (list)
        \\      (if (pred (car lst)) (cons (car lst) (filter pred (cdr lst))) (filter pred (cdr lst)))))
        \\(define (foldl op acc lst)
        \\  (if (null? lst) acc (foldl op (op acc (car lst)) (cdr lst))))
        \\(define (sq x) (* x x))
        \\(define (gt3 x) (> x 3))
        \\(define (add a b) (+ a b))
        \\(display (map sq (list 1 2 3)))
        \\(display (filter gt3 (list 1 2 3 4 5)))
        \\(display (foldl add 0 (list 1 2 3)))
    );
    defer std.testing.allocator.free(r.output);
    try std.testing.expectEqualStrings("(1 4 9)(4 5)6", r.output);
}
