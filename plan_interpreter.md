# Plan: Interpreter Implementation

How `src/interpreter.zig` takes a `GcAllocator` and walks the AST from `src/parser.zig`.

---

## Prerequisites (implement first)

These modules must exist before the interpreter can be built:

| File | What it provides |
|------|-----------------|
| `src/value.zig` | `Value` (packed u32: 8-bit tag + 24-bit payload), `ValueTag`, `ConsCell`, `Closure`, `VectorData`, sentinel constants (`nil_value`, `true_value`, `false_value`) |
| `src/symbol.zig` | `SymbolTable` — intern/getName, packed char buffer + spans + hash dedup |
| `src/gc.zig` | `GcAllocator` — fat-pointer vtable interface (allocCons, getCar, getCdr, allocNumber, getNumber, pushRoot, popRoot, etc.) |
| `src/gc/mark_sweep.zig` | First backend implementing `GcAllocator` with typed pools, free lists, mark bitsets |

---

## Step 1: Interpreter Struct

The interpreter owns the GC handle, symbol table, environments, and a reference to the parsed AST.

```zig
pub const Interpreter = struct {
    gc: GcAllocator,
    symbols: SymbolTable,
    globals: std.AutoHashMap(u24, Value),   // interned symbol ID → Value
    scopes: std.ArrayList(Scope),           // pool of local scope frames
    scope_free: std.ArrayList(u24),         // recycled scope slot indices
    ast: *const parser.Ast,
    backing: std.mem.Allocator,

    // Pre-interned symbol IDs for special forms (avoid hashing on every eval)
    sym_quote: u24,
    sym_define: u24,
    sym_set: u24,
    sym_if: u24,
    sym_lambda: u24,
    sym_begin: u24,
};
```

`init()` takes `GcAllocator`, `*const parser.Ast`, and a backing `std.mem.Allocator`. It interns the special-form names and registers builtins into `globals`.

---

## Step 2: Scope (local environments)

```zig
pub const Scope = struct {
    table: std.AutoHashMap(u24, Value),
    parent: ?u24,  // index into Interpreter.scopes, or null → fall through to globals
};
```

Scopes are **not** GC-managed — they live in a pool on the interpreter and are recycled via `scope_free`. This keeps the GC focused on Lisp-level heap objects.

### Lookup algorithm

1. Walk `scope.parent` chain checking `scope.table.get(sym)`.
2. If chain exhausted (parent == null), check `globals.get(sym)`.
3. If missing → `error.UnboundVariable`.

### envExtend

Called on function application: allocate (or recycle) a Scope, zip params + args into its table, set parent to the closure's captured scope.

### envSet

Walk scope chain then globals, mutate in-place. Used by `set!`.

---

## Step 3: AST → Value Conversion

Walk `parser.Ast` nodes and produce GC-managed `Value` handles. This is the bridge between the parser's index-based tree and the interpreter's cons-based runtime.

| AST Node Tag | Conversion |
|-------------|-----------|
| `.number` | Parse `f128` from source slice → `gc.allocNumber(n)` |
| `.symbol` | Intern name via `symbols.intern()` → `Value{ .tag = .symbol, .payload = id }` |
| `.string` | `gc.allocString(slice)` |
| `.boolean` | `true_value` or `false_value` |
| `.list` | Fold right: `items[n-1..0]` → nested `gc.allocCons(val, acc)`, starting from `nil_value` |
| `.quote` | Convert inner, wrap as `(quote inner)` cons list |
| `.vector` | `gc.allocVector(converted_items)` |
| `.dotted_list` | Fold right like list, but use `tail` value instead of `nil_value` as initial accumulator |

**Root protection**: before each `allocCons` in the list fold, `pushRoot` the accumulator to protect it from GC triggered by the next allocation. `popRoot` after.

---

## Step 4: eval — The Core Loop

```
fn eval(self: *Interpreter, expr: Value, scope: ?u24) EvalError!Value
```

| `expr.tag` | Action |
|-----------|--------|
| `.number`, `.boolean`, `.nil`, `.string`, `.vector` | Self-evaluating — return as-is |
| `.symbol` | `envLookup(scope, expr.payload)` |
| `.cons` | Extract `car` (head) and `cdr` (args). If head is a symbol, check for special forms by comparing `payload` against pre-interned IDs. Otherwise, eval head and args, then `apply`. |

### Special forms dispatch

Check `head_val.payload ==` against pre-interned symbol IDs (`sym_quote`, `sym_define`, etc.) — this is an integer compare, no string matching.

---

## Step 5: Special Forms

| Form | Implementation |
|------|---------------|
| `(quote x)` | Return `x` unevaluated (car of args) |
| `(define sym expr)` | Eval `expr`, `globals.put(sym.payload, result)` |
| `(set! sym expr)` | Eval `expr`, `envSet(scope, sym.payload, result)` |
| `(if test then else?)` | Eval test; if not `false_value`/`nil_value`, eval then-branch, else eval else-branch (or nil) |
| `(lambda (params...) body...)` | `gc.allocClosure(params_value, body_value, scope, arity)` — captures current scope |
| `(begin e1 e2 ... en)` | Eval all sequentially, return last result |

---

## Step 6: apply

```
fn apply(self: *Interpreter, func: Value, args: Value) !Value
```

| `func.tag` | Action |
|-----------|--------|
| `.builtin` | Index into builtins table, call `builtin_fn(self, args)` |
| `.closure` | `gc.getClosure(func.payload)` → extend captured scope with new frame (zip params/args) → `evalBegin(body, new_scope)` |
| else | `error.NotCallable` |

---

## Step 7: Builtins

Register during `init()` as `Value{ .tag = .builtin, .payload = index }` in `globals`.

### Minimum set

| Builtin | Signature | Purpose |
|---------|-----------|---------|
| `+`, `-`, `*`, `/` | `(op a b)` | Arithmetic via number pool |
| `cons` | `(cons a b)` | Pair construction |
| `car`, `cdr` | `(car pair)` | Pair access |
| `eq?` | `(eq? a b)` | Identity (tag + payload equality) |
| `null?` | `(null? x)` | Check for nil |
| `list` | `(list a b ...)` | Variadic → cons chain |
| `display`, `newline` | `(display x)` | Output |
| `<`, `>`, `=` | `(< a b)` | Numeric comparison |
| `not` | `(not x)` | Boolean negation |
| `set-car!`, `set-cdr!` | `(set-car! pair val)` | Mutation + write barrier |

---

## Step 8: Error Handling

```zig
pub const EvalError = error{
    UnboundVariable,
    NotCallable,
    TypeError,
    ArityMismatch,
    DivisionByZero,
} || std.mem.Allocator.Error;
```

Errors propagate as Zig error unions. No try/catch in the Lisp yet (can add later).

---

## Step 9: GC Integration Points

The interpreter interacts with the GC at these points:

1. **Allocation**: every `astToValue` list fold, every `cons`/`list` builtin call, every closure creation.
2. **Root protection**: `pushRoot`/`popRoot` around temporaries during eval (e.g., after evaluating the function but before evaluating args).
3. **Root enumeration**: the GC's mark phase needs to trace:
   - The explicit root stack (`gc.roots`)
   - All values in `globals`
   - All values in every live `Scope.table`
4. **Write barrier**: called from `set-car!`/`set-cdr!` via `gc.writeBarrier(parent, child)` — no-op for mark-sweep, needed for generational.

---

## Step 10: Wiring in main.zig

```zig
const gc = mark_sweep.init(allocator);
var interp = Interpreter.init(gc, &p.ast, allocator);
defer interp.deinit();

const root_items = p.ast.listSlice(p.ast.nodes.items[p.ast.root].data.list);
var last_result = value.nil_value;
for (root_items) |node_id| {
    const val = interp.astToValue(node_id);
    last_result = try interp.eval(val, null);
}
```

---

## Implementation Order

1. **`src/value.zig`** — Value type, tags, sentinels, pool data structs
2. **`src/symbol.zig`** — SymbolTable (intern, getName)
3. **`src/gc.zig`** — GcAllocator vtable interface
4. **`src/gc/mark_sweep.zig`** — First backend (pools, alloc, mark, sweep)
5. **`src/interpreter.zig`** — in this order:
   a. Struct + init (with builtin registration)
   b. Scope + envLookup/envExtend/envSet
   c. astToValue (AST → runtime Value bridge)
   d. eval + special forms (quote, define, if, lambda, begin, set!)
   e. apply (builtin dispatch + closure call)
   f. Builtins (arithmetic, cons/car/cdr, eq?, display)
6. **`src/main.zig`** — CLI wiring

## Tests (per step)

| Step | Test |
|------|------|
| 5a | `Interpreter.init` succeeds, builtins in globals |
| 5b | Lookup/extend/set on scopes |
| 5c | `astToValue` round-trips numbers, symbols, lists |
| 5d | `(+ 1 2)` → 3, `(if #t 1 2)` → 1, `(define x 10) x` → 10 |
| 5e | `((lambda (x) x) 42)` → 42, `(fact 5)` → 120 |
| 5f | `(cons 1 2)`, `(car ...)`, `(eq? ...)` |
| GC stress | Allocate 10k cons cells in a loop, verify no crash |
