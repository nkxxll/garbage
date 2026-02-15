# Plan: Mark-and-Sweep GC + Interpreter Implementation

A step-by-step plan to implement the mark-and-sweep garbage collector and tree-walking interpreter, using index-based pools (mirroring the AST's `NodeId` → `ArrayList` pattern from `src/parser.zig`).

---

## Phase 1: Runtime Value Representation — `src/value.zig`

### 1.1 The `Value` Handle

A 32-bit tagged index. No pointers to GC-managed objects ever escape into user code.

```zig
pub const Value = packed struct {
    tag: ValueTag,
    payload: u24,
};

pub const ValueTag = enum(u8) {
    nil,
    number,
    boolean,
    cons,
    symbol,
    string,
    vector,
    closure,
    builtin,
};
```

Sentinel values:

```zig
pub const nil_value = Value{ .tag = .nil, .payload = 0 };
pub const true_value = Value{ .tag = .boolean, .payload = 1 };
pub const false_value = Value{ .tag = .boolean, .payload = 0 };
```

### 1.2 Pool Data Types

Flat structs stored in parallel arrays:

```zig
pub const ConsCell = struct { car: Value, cdr: Value };

pub const Closure = struct {
    params: Value,   // cons list of symbols, or nil
    body: Value,     // cons list of body expressions
    env_id: u24,     // index into the Scope pool (captured lexical scope)
    arity: u16,
};

pub const VectorData = struct {
    start: u32,      // index into a shared Value buffer
    len: u16,
};
```

Strings are stored as `(start, len)` into a packed byte buffer (like the parser stores source slices via `Loc`).

Numbers are stored as `f128` in a dedicated number pool. The 24-bit payload is an index into that pool, so numeric precision is not limited by the `Value` width.

### 1.3 Tests

- `Value` is exactly 4 bytes (`@sizeOf(Value) == 4`).
- Round-trip: create a number `Value` via the pool, read back the `f128`.
- Nil/true/false sentinels have expected bit patterns.

---

## Phase 2: Symbol Table — `src/symbol.zig`

### 2.1 Design

```zig
pub const SymbolTable = struct {
    chars: std.ArrayList(u8),           // packed character storage
    spans: std.ArrayList(Span),         // (start, len) per symbol
    lookup: std.StringHashMap(u24),     // string → symbol index

    pub const Span = struct { start: u32, len: u16 };

    pub fn intern(self: *SymbolTable, alloc: Allocator, name: []const u8) u24 { ... }
    pub fn getName(self: SymbolTable, id: u24) []const u8 { ... }
};
```

- `intern()` deduplicates: if the string is already known, return existing index.
- Symbol comparison is `a.payload == b.payload`.

### 2.2 Tests

- Interning the same string twice returns the same index.
- Different strings get different indices.
- `getName` round-trips correctly.

---

## Phase 3: GC Interface — `src/gc.zig`

### 3.1 VTable Definition

Define the `GcAllocator` fat-pointer interface as described in `plan_gc_interface.md`. Keep vtable methods minimal for the first pass:

```zig
pub const GcAllocator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocNumber: *const fn (*anyopaque, f128) Value,
        allocCons: *const fn (*anyopaque, Value, Value) Value,
        allocVector: *const fn (*anyopaque, []const Value) Value,
        allocClosure: *const fn (*anyopaque, Value, Value, Value, u16) Value,
        allocString: *const fn (*anyopaque, []const u8) Value,
        writeBarrier: *const fn (*anyopaque, Value, Value) void,
        collectGarbage: *const fn (*anyopaque) void,
        pushRoot: *const fn (*anyopaque, Value) void,
        popRoot: *const fn (*anyopaque) void,
        getNumber: *const fn (*anyopaque, u24) f128,
        getCar: *const fn (*anyopaque, u24) Value,
        getCdr: *const fn (*anyopaque, u24) Value,
        setCar: *const fn (*anyopaque, u24, Value) void,
        setCdr: *const fn (*anyopaque, u24, Value) void,
        getVectorItems: *const fn (*anyopaque, u24) []Value,
        getClosure: *const fn (*anyopaque, u24) Closure,
        getString: *const fn (*anyopaque, u24) []const u8,
    };

    // Convenience wrappers
    pub fn allocCons(self: GcAllocator, car: Value, cdr: Value) Value {
        return self.vtable.allocCons(self.ptr, car, cdr);
    }
    // ... one wrapper per vtable entry
};
```

### 3.2 Tests

- None yet — tested through backends.

---

## Phase 4: Mark-and-Sweep Backend — `src/gc/mark_sweep.zig`

This is the core of the GC work. Index-based, free-list managed, no pointer magic.

### 4.1 Pool Structure

```zig
const MarkSweep = struct {
    backing: Allocator,

    // Number pool (f128 values indexed by payload)
    numbers: std.ArrayList(f128),
    number_marks: std.DynamicBitSet,
    number_free: std.ArrayList(u24),

    // Cons pool (parallel arrays, like parser's nodes + list_items)
    cons_cars: std.ArrayList(Value),
    cons_cdrs: std.ArrayList(Value),
    cons_marks: std.DynamicBitSet,
    cons_free: std.ArrayList(u24),   // stack of free indices

    // Vector pool
    vector_meta: std.ArrayList(VectorData),
    vector_items: std.ArrayList(Value),  // shared item storage
    vector_marks: std.DynamicBitSet,
    vector_free: std.ArrayList(u24),

    // Closure pool
    closures: std.ArrayList(Closure),
    closure_marks: std.DynamicBitSet,
    closure_free: std.ArrayList(u24),

    // String pool
    string_chars: std.ArrayList(u8),
    string_spans: std.ArrayList(StringSpan),
    string_marks: std.DynamicBitSet,
    string_free: std.ArrayList(u24),

    // Root stack
    roots: std.ArrayList(Value),

    // Stats
    alloc_count: usize,
    gc_threshold: usize,
};
```

### 4.2 Allocation (with free list)

```zig
fn allocCons(self: *MarkSweep, car: Value, cdr: Value) Value {
    if (self.cons_free.items.len > 0) {
        // Reuse from free list
        const idx = self.cons_free.pop();
        self.cons_cars.items[idx] = car;
        self.cons_cdrs.items[idx] = cdr;
        self.cons_marks.unset(idx);
        return Value{ .tag = .cons, .payload = idx };
    }
    // Grow pool
    self.maybeCollect();
    const idx = self.cons_cars.items.len;
    self.cons_cars.append(self.backing, car);
    self.cons_cdrs.append(self.backing, cdr);
    // grow bitset...
    return Value{ .tag = .cons, .payload = @intCast(idx) };
}
```

### 4.3 Mark Phase

Recursive walk from roots. Since values are tagged, the marker dispatches on tag:

```zig
fn mark(self: *MarkSweep, val: Value) void {
    switch (val.tag) {
        .nil, .boolean, .builtin => return,  // no heap data
        .number => {
            self.number_marks.set(val.payload);
            return;
        },
        .cons => {
            if (self.cons_marks.isSet(val.payload)) return;  // already marked
            self.cons_marks.set(val.payload);
            self.mark(self.cons_cars.items[val.payload]);
            self.mark(self.cons_cdrs.items[val.payload]);
        },
        .vector => {
            if (self.vector_marks.isSet(val.payload)) return;
            self.vector_marks.set(val.payload);
            const meta = self.vector_meta.items[val.payload];
            for (self.vector_items.items[meta.start..meta.start + meta.len]) |item| {
                self.mark(item);
            }
        },
        .closure => {
            if (self.closure_marks.isSet(val.payload)) return;
            self.closure_marks.set(val.payload);
            const c = self.closures.items[val.payload];
            self.mark(c.params);
            self.mark(c.body);
            // c.env_id is a scope index, not a Value — traced via markRoots
        },
        .symbol, .string => {
            // Mark to prevent sweep; no children to trace
            if (val.tag == .string) self.string_marks.set(val.payload);
            // Symbols are interned, never freed
        },
    }
}
```

### 4.4 Sweep Phase

Walk each pool, push unmarked slots onto free list, clear all marks:

```zig
fn sweep(self: *MarkSweep) void {
    // Sweep cons pool
    for (0..self.cons_cars.items.len) |i| {
        if (!self.cons_marks.isSet(i)) {
            self.cons_free.append(self.backing, @intCast(i));
        }
    }
    self.cons_marks.setAll(false);  // reset for next cycle

    // Same for vector, closure, string pools...
}
```

### 4.5 Collection Trigger

```zig
fn maybeCollect(self: *MarkSweep) void {
    self.alloc_count += 1;
    if (self.alloc_count >= self.gc_threshold) {
        self.collectGarbage();
        self.alloc_count = 0;
        // Grow threshold if still under pressure
    }
}

fn collectGarbage(self: *MarkSweep) void {
    // Mark from all roots
    for (self.roots.items) |root| {
        self.mark(root);
    }
    // Sweep all pools
    self.sweep();
}
```

### 4.6 VTable Wiring

```zig
pub fn init(backing: Allocator) GcAllocator {
    const self = backing.create(MarkSweep) catch unreachable;
    self.* = .{ .backing = backing, ... };
    return .{
        .ptr = @ptrCast(self),
        .vtable = &vtable,
    };
}

const vtable = GcAllocator.VTable{
    .allocCons = @ptrCast(&allocConsImpl),
    // ... all other entries
};
```

### 4.7 Tests

- Allocate cons cells, verify car/cdr retrieval by index.
- Allocate, drop all roots, collect → free list grows.
- Allocate, keep some roots, collect → only unreachable freed.
- Circular references: `(set-car! a a)` → mark terminates, doesn't stack overflow.
- Reuse: after sweep, new allocs reuse freed indices.
- Threshold: GC triggers automatically after N allocs.

---

## Phase 5: Environment Representation — `src/env.zig`

### 5.1 Design: HashMap Global + Scope Chain for Locals

Following the approach in `global_environment_representation.md`, the global environment uses a hash map for O(1) lookup, while local environments use a linked scope chain. This avoids the O(n) linear scan that cons-list environments would require for every variable reference.

#### Global Environment

```zig
/// Maps interned symbol IDs (u24) to Values.
/// Lives on the Interpreter, persists for the entire session.
globals: std.AutoHashMap(u24, Value),
```

- `(define x 10)` → `globals.put(sym_x, Value{ .tag = .number, ... })`
- Redefinition naturally overwrites: `globals.put(sym_x, new_val)`
- Builtin registration at init: `globals.put(sym_plus, Value{ .tag = .builtin, .payload = 0 })`

#### Local Scopes (Scope Chain)

When a closure is called, a new `Scope` is created for its local bindings. Scopes form a linked chain via `parent`, ultimately terminating at a sentinel (lookup falls through to the global hash map).

```zig
pub const Scope = struct {
    table: std.AutoHashMap(u24, Value),  // symbol ID → value
    parent: ?u24,                         // index of parent Scope, or null (= use globals)
};
```

Scopes are stored in a pool on the interpreter (not GC-managed — they are tied to the call stack):

```zig
scopes: std.ArrayList(Scope),
scope_free: std.ArrayList(u24),  // free list for recycled scope slots
```

#### Lookup Algorithm

```zig
fn envLookup(self: *Interpreter, scope_id: ?u24, sym: u24) !Value {
    // Walk the scope chain first (local frames)
    var current = scope_id;
    while (current) |id| {
        const scope = &self.scopes.items[id];
        if (scope.table.get(sym)) |val| return val;
        current = scope.parent;
    }
    // Fall through to global hash map
    return self.globals.get(sym) orelse error.UnboundVariable;
}
```

#### envExtend — Creating a New Local Frame

```zig
fn envExtend(self: *Interpreter, parent: ?u24, params: Value, args: Value) !u24 {
    // Allocate or reuse a Scope slot
    const id = if (self.scope_free.items.len > 0)
        self.scope_free.pop()
    else blk: {
        self.scopes.append(self.backing, undefined);
        break :blk @intCast(self.scopes.items.len - 1);
    };
    self.scopes.items[id] = Scope{
        .table = std.AutoHashMap(u24, Value).init(self.backing),
        .parent = parent,
    };
    // Zip params and args into the table
    var p = params;
    var a = args;
    while (p.tag == .cons) {
        const sym_id = self.gc.getCar(p.payload).payload;
        const val = self.gc.getCar(a.payload);
        self.scopes.items[id].table.put(sym_id, val);
        p = self.gc.getCdr(p.payload);
        a = self.gc.getCdr(a.payload);
    }
    return id;
}
```

#### envSet — Mutating an Existing Binding

```zig
fn envSet(self: *Interpreter, scope_id: ?u24, sym: u24, val: Value) !void {
    var current = scope_id;
    while (current) |id| {
        const scope = &self.scopes.items[id];
        if (scope.table.getPtr(sym)) |ptr| { ptr.* = val; return; }
        current = scope.parent;
    }
    // set! in global scope
    if (self.globals.getPtr(sym)) |ptr| { ptr.* = val; return; }
    return error.UnboundVariable;
}
```

### 5.2 Why This Design

| Aspect | Cons-list env (old) | HashMap global + Scope chain (new) |
|--------|--------------------|------------------------------------|
| Global lookup | O(n) per access | O(1) hash lookup |
| Local lookup | O(n) per frame | O(1) per frame |
| Redefinition | Shadows (wastes cons cells) | In-place overwrite |
| GC pressure | Every binding = 2 cons cells | No GC pressure (scopes are Zig-managed) |
| Simplicity | Requires walking nested cons lists | Direct hash map operations |

### 5.3 GC Interaction

Scopes hold `Value`s that reference GC-managed objects. During mark phase, the GC must trace:
1. All values in `globals` (the global hash map).
2. All values in every live `Scope.table` (active scope chain entries).

The mark phase root enumeration becomes:

```zig
fn markRoots(self: *MarkSweep, interp: *Interpreter) void {
    // Mark explicit root stack
    for (self.roots.items) |v| self.mark(v);
    // Mark global environment
    var git = interp.globals.valueIterator();
    while (git.next()) |val| self.mark(val.*);
    // Mark all live scope tables
    for (interp.scopes.items) |scope| {
        var sit = scope.table.valueIterator();
        while (sit.next()) |val| self.mark(val.*);
    }
}
```

### 5.4 Tests

- Global: `define` then lookup → correct value.
- Global: redefine → overwrites, old value gone.
- Local: extend scope, lookup local → shadows global.
- Local: lookup falls through to global when not in local scope.
- `set!` mutates binding in correct scope (local or global).
- Lookup missing binding → `UnboundVariable` error.

---

## Phase 6: Interpreter — `src/interpreter.zig`

### 6.1 Core Structure

```zig
pub const Interpreter = struct {
    gc: GcAllocator,
    symbols: SymbolTable,
    globals: std.AutoHashMap(u24, Value),  // global environment (symbol ID → value)
    scopes: std.ArrayList(Scope),          // pool of local scope frames
    scope_free: std.ArrayList(u24),        // free list for recycled scope slots
    ast: *const parser.Ast,                // the parsed source
    backing: Allocator,

    pub fn init(gc: GcAllocator, ast: *const parser.Ast, alloc: Allocator) Interpreter { ... }
};
```

During `init`, all builtins are registered directly into `globals`.

### 6.2 AST → Value Conversion

Walk the parser's `Ast` nodes and produce `Value` handles:

```zig
fn astToValue(self: *Interpreter, node_id: parser.NodeId) Value {
    const node = self.ast.nodes.items[node_id];
    switch (node.tag) {
        .number => {
            const n = std.fmt.parseFloat(f128, self.ast.slice(node.loc)) catch ...;
            return self.gc.allocNumber(n);
        },
        .symbol => {
            const name = self.ast.slice(node.loc);
            const id = self.symbols.intern(self.gc.backing, name);
            return Value{ .tag = .symbol, .payload = id };
        },
        .string => {
            return self.gc.allocString(self.ast.slice(node.loc));
        },
        .boolean => return if (node.data.boolean) true_value else false_value,
        .list => {
            // Convert to a cons list
            const items = self.ast.listSlice(node.data.list);
            var result = nil_value;
            var i = items.len;
            while (i > 0) {
                i -= 1;
                const val = self.astToValue(items[i]);
                self.gc.pushRoot(val);
                result = self.gc.allocCons(val, result);
                self.gc.popRoot();
            }
            return result;
        },
        .quote => {
            const inner = self.astToValue(node.data.quote);
            const quote_sym = Value{ .tag = .symbol, .payload = self.symbols.intern(..., "quote") };
            return self.gc.allocCons(quote_sym, self.gc.allocCons(inner, nil_value));
        },
        // ... vector, dotted_list
    }
}
```

### 6.3 Eval — Special Forms + Apply

```zig
fn eval(self: *Interpreter, expr: Value, scope: ?u24) EvalError!Value {
    switch (expr.tag) {
        .number, .boolean, .nil, .string, .vector => return expr,  // self-evaluating
        .symbol => return self.envLookup(scope, expr.payload),
        .cons => {
            const head_val = self.gc.getCar(expr.payload);
            const args_list = self.gc.getCdr(expr.payload);

            // Check special forms by symbol identity
            if (head_val.tag == .symbol) {
                if (head_val.payload == self.sym_quote) return self.evalQuote(args_list);
                if (head_val.payload == self.sym_define) return self.evalDefine(args_list, scope);
                if (head_val.payload == self.sym_set) return self.evalSet(args_list, scope);
                if (head_val.payload == self.sym_if) return self.evalIf(args_list, scope);
                if (head_val.payload == self.sym_lambda) return self.evalLambda(args_list, scope);
                if (head_val.payload == self.sym_begin) return self.evalBegin(args_list, scope);
            }

            // Function application
            const func = try self.eval(head_val, scope);
            const evaled_args = try self.evalList(args_list, scope);
            return self.apply(func, evaled_args);
        },
        else => return error.EvalError,
    }
}
```

The `scope` parameter is `?u24`: `null` means "global scope only" (top-level evaluation), otherwise it's an index into `self.scopes`.

### 6.4 Special Forms

| Form                           | Behavior                             |
| ------------------------------ | ------------------------------------ |
| `(quote x)`                    | Return `x` unevaluated               |
| `(define sym expr)`            | Eval `expr`, bind in `globals` map   |
| `(set! sym expr)`              | Eval `expr`, mutate existing binding |
| `(if test then else)`          | Eval `test`, branch                  |
| `(lambda (params...) body...)` | Create closure capturing current `scope` |
| `(begin e1 e2 ... en)`         | Eval all, return last                |

### 6.5 Apply

```zig
fn apply(self: *Interpreter, func: Value, args: Value) !Value {
    switch (func.tag) {
        .builtin => {
            const builtin_fn = self.builtins[func.payload];
            return builtin_fn(self, args);
        },
        .closure => {
            const c = self.gc.getClosure(func.payload);
            // Extend the closure's captured scope with a new local frame
            const parent_scope: ?u24 = if (c.env_id == std.math.maxInt(u24)) null else c.env_id;
            const new_scope = try self.envExtend(parent_scope, c.params, args);
            return self.evalBegin(c.body, new_scope);
        },
        else => return error.NotCallable,
    }
}
```

### 6.6 Builtins

Minimum set for testing GC pressure:

| Builtin                                    | Purpose                                |
| ------------------------------------------ | -------------------------------------- |
| `+`, `-`, `*`, `/`                         | Arithmetic (f128 via number pool)      |
| `cons`, `car`, `cdr`                       | Pair operations                        |
| `eq?`                                      | Identity comparison (index equality)   |
| `null?`                                    | Check for nil                          |
| `list`                                     | Variadic list constructor              |
| `display`, `newline`                       | Output                                 |
| `make-vector`, `vector-ref`, `vector-set!` | Vector ops (tests large allocs)        |
| `set-car!`, `set-cdr!`                     | Mutation (tests write barrier, cycles) |

### 6.7 Tests

- `(+ 1 2)` → 3
- `(define x 10) x` → 10
- `(if #t 1 2)` → 1
- `((lambda (x) x) 42)` → 42
- `(define (fact n) (if (eq? n 0) 1 (* n (fact (- n 1))))) (fact 5)` → 120
- `(cons 1 2)` → dotted pair
- `(car (cons 1 2))` → 1
- `(set! x 20) x` → 20
- GC stress: allocate many cons cells in a loop, verify no crash and memory reuse

---

## Phase 7: Main Wiring — `src/main.zig`

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Parse args for --gc flag and source file
    const source = readSourceFile(allocator);
    var p = Parser.init(allocator, source);
    const root = try p.parseRoot();

    const gc = mark_sweep.init(allocator);
    var interp = Interpreter.init(gc, &p.ast, allocator);
    defer interp.deinit();

    // Evaluate all top-level forms (scope = null → global only)
    const root_items = p.ast.listSlice(p.ast.nodes.items[root].data.list);
    for (root_items) |node_id| {
        const val = interp.astToValue(node_id);
        _ = try interp.eval(val, null);
    }
}
```

---

## Implementation Checklist

- [ ] `src/value.zig` — Value, ValueTag, ConsCell, Closure, VectorData
- [ ] `src/symbol.zig` — SymbolTable with intern/getName
- [ ] `src/gc.zig` — GcAllocator interface
- [ ] `src/gc/mark_sweep.zig` — pools, alloc, mark, sweep, free list
- [ ] `src/env.zig` — Scope struct, envLookup, envExtend, envSet
- [ ] `src/interpreter.zig` — astToValue, eval, apply, special forms, builtins
- [ ] `src/main.zig` — CLI wiring, parse → interpret pipeline
- [ ] Integration tests: factorial, fibonacci, list manipulation, GC stress

---

## Design Constraints

1. **No raw pointers to GC objects** — everything is a `Value` (32-bit tagged index).
2. **Pools are `ArrayList`s** — same as `parser.Ast.nodes` and `parser.Ast.list_items`.
3. **Free list is a stack of indices** — `ArrayList(u24)` of recycled slots.
4. **Mark bitset per pool** — `DynamicBitSet`, one bit per slot.
5. **Symbols are never freed** — interned permanently (like parser source slices).
6. **Global env is a `AutoHashMap(u24, Value)`** — O(1) lookup by interned symbol ID. Local scopes use a `Scope` chain with `parent` pointer, falling through to globals.
7. **`pushRoot`/`popRoot`** — interpreter explicitly protects temporaries during eval.
