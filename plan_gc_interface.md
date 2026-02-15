# Plan: Pluggable GC Interface for the Interpreter

## The Core Idea

Define a `GcAllocator` interface as a Zig "fat pointer" pattern (like `std.mem.Allocator`) that the interpreter calls for all object lifecycle operations. GC backends implement the vtable; a CLI flag selects which one to instantiate.

**Key principle:** Use index-based addressing (not raw pointers) throughout, mirroring the AST design in `src/parser.zig` where `NodeId = usize` indexes into `ArrayList`s. This gives cache locality, cheap handles, and trivial compaction support.

---

## 1. The Handle — Index-Based Object References

All runtime values are represented as a small tagged handle, not a pointer:

```zig
pub const ObjectId = u32;  // index into a typed pool

pub const Value = packed struct {
    tag: ValueTag,
    payload: u24,  // index into the relevant pool, or inline fixnum
};

pub const ValueTag = enum(u8) {
    nil,
    fixnum,     // payload IS the value (no pool lookup)
    cons,       // payload indexes into ConsPool
    symbol,     // payload indexes into SymbolTable
    string,     // payload indexes into StringPool
    vector,     // payload indexes into VectorPool
    closure,    // payload indexes into ClosurePool
    boolean,    // payload is 0 or 1
    builtin,    // payload indexes into builtins table
};
```

This mirrors the parser's `NodeId` → `nodes.items[id]` pattern but for runtime values.

---

## 2. The Interface — `src/gc.zig`

```zig
pub const GcAllocator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Allocate a cons cell, returns its index
        allocCons: *const fn (ptr: *anyopaque, car: Value, cdr: Value) Value,
        /// Allocate a vector, returns its index
        allocVector: *const fn (ptr: *anyopaque, items: []const Value) Value,
        /// Allocate a closure, returns its index
        allocClosure: *const fn (ptr: *anyopaque, params: Value, body: Value, env: Value) Value,
        /// Allocate/intern a string, returns its index
        allocString: *const fn (ptr: *anyopaque, bytes: []const u8) Value,
        /// Write barrier (no-op for mark-sweep)
        writeBarrier: *const fn (ptr: *anyopaque, parent: Value, child: Value) void,
        /// Force a full collection cycle
        collectGarbage: *const fn (ptr: *anyopaque) void,
        /// Register/unregister a root
        pushRoot: *const fn (ptr: *anyopaque, root: Value) void,
        popRoot: *const fn (ptr: *anyopaque) void,
        /// Dereference a cons cell by index
        getCons: *const fn (ptr: *anyopaque, index: u24) *ConsCell,
        /// Dereference a vector by index
        getVector: *const fn (ptr: *anyopaque, index: u24) []Value,
        /// Dereference a closure by index
        getClosure: *const fn (ptr: *anyopaque, index: u24) *Closure,
    };

    // Convenience wrappers calling through vtable
    pub fn allocCons(self: GcAllocator, car: Value, cdr: Value) Value { ... }
    // ... etc
};
```

---

## 3. Object Pools (Index-Based, No Pointer Chasing)

Instead of a single `Object` struct with a `gc_header`, use **typed pools** — parallel arrays for each object kind. Each pool has its own free list (as an index chain) and a mark bitset.

```zig
pub const ConsCell = struct { car: Value, cdr: Value };

pub const ConsPool = struct {
    cars: std.ArrayList(Value),
    cdrs: std.ArrayList(Value),
    marks: std.DynamicBitSet,
    free_head: ?u24,            // head of free list (index chain)
    next_free: std.ArrayList(u24), // free list: next_free[i] = next free slot
};
```

This is the same pattern as the parser's `nodes: ArrayList(Node)` + `list_items: ArrayList(NodeId)` — flat arrays indexed by ID.

---

## 4. Symbol Interning — `src/symbol.zig`

```zig
pub const SymbolTable = struct {
    /// All symbol characters packed contiguously
    chars: std.ArrayList(u8),
    /// (start, len) pairs for each symbol
    spans: std.ArrayList(Span),
    /// string → symbol index for dedup
    lookup: std.StringHashMap(u24),

    pub const Span = struct { start: u32, len: u16 };
};
```

Symbol comparison becomes `symA.payload == symB.payload` (integer compare).

---

## 5. Backend Implementations

Each in its own file, returning a `GcAllocator`:

| File | Strategy | Pool metadata |
|------|----------|---------------|
| `src/gc/mark_sweep.zig` | Mark-and-sweep + free list | mark bitset per pool |
| `src/gc/refcount.zig` | Reference counting | count per slot |
| `src/gc/copying.zig` | Semi-space copying | forwarding index |
| `src/gc/generational.zig` | Generational (young/old) | generation + mark bit |

Each exposes:

```zig
pub fn init(backing_allocator: std.mem.Allocator) GcAllocator { ... }
```

---

## 6. CLI Wiring — `src/main.zig`

```zig
const gc_choice = args.option("--gc") orelse "mark-sweep";
const gc = switch (gc_choice) {
    "mark-sweep" => mark_sweep.init(allocator),
    "refcount"   => refcount.init(allocator),
    else         => fatal("unknown gc backend"),
};
var interpreter = Interpreter.init(gc);
```

---

## 7. Interpreter Integration

The interpreter takes a `GcAllocator` and uses `Value` handles exclusively:

```zig
pub const Interpreter = struct {
    gc: GcAllocator,
    global_env: Value,
    symbol_table: SymbolTable,

    pub fn eval(self: *Interpreter, expr: Value, env: Value) Value {
        switch (expr.tag) {
            .symbol => return self.envLookup(env, expr),
            .cons => {
                const cell = self.gc.getCons(expr.payload);
                // apply / special forms ...
            },
            .fixnum, .boolean, .nil, .string => return expr,
            // ...
        }
    }
};
```

---

## 8. Implementation Order

1. **`src/value.zig`** — `Value`, `ValueTag`, pool structs (`ConsCell`, `Closure`, etc.)
2. **`src/symbol.zig`** — `SymbolTable` (interning)
3. **`src/gc.zig`** — `GcAllocator` interface (vtable)
4. **`src/gc/mark_sweep.zig`** — First backend (mark-sweep with free list)
5. **`src/interpreter.zig`** — Tree-walking eval over the AST, using `GcAllocator` + `Value`
6. **`src/main.zig`** — CLI flag parsing, wiring
7. Later backends: refcount, copying, generational

---

## Key Design Decisions

- **Indices over pointers**: `Value` is a 32-bit tagged index (like `NodeId` in the parser), not a pointer. Pools are flat `ArrayList`s. This gives cache locality, 4-byte handles, and makes compaction trivial.
- **Typed pools**: Cons cells, vectors, closures each get their own pool with parallel arrays. The GC marks/sweeps per pool.
- **Symbol interning**: Symbols stored once in a packed char buffer; comparison is integer equality.
- **Write barrier as vtable method**: no-op for mark-sweep, essential for generational.
- **`pushRoot`/`popRoot` stack**: interpreter explicitly protects temporaries.
- **Type-erased vtable**: backends swappable at runtime without recompilation.
