# Plan: Turn `Value` into a GC-Defined Interface

## Motivation

Currently `Value` is a single concrete struct (`{ tag: ValueTag, data: usize }`) shared
by every GC backend and the interpreter. All backends must encode their object references
as a `(tag, usize)` pair. This prevents a GC from attaching per-object metadata (e.g.
generation bits, forwarding pointers, colour marks, reference counts) without keeping a
separate side-table (`Header`, `Descriptor`).

**Goal:** Let each GC backend define its own `Value` representation while exposing a
common interface the interpreter programs against. A mark-and-sweep GC could embed a
`marked` bit directly in the value; a copying collector could embed a forwarding pointer;
a reference-counting collector could embed a refcount — all without touching the
interpreter.

---

## Current Architecture (summary)

```
value.zig   →  Value { tag: ValueTag, data: usize }
               ConsCell, Closure, Scope, …  (pool data types)

gc.zig      →  GcAllocator (fat-pointer vtable interface)
               ├── NoGc              (arena, no collection)
               ├── MarkAndSweepGPABacked  (GPA + Header side-table)
               └── MarkAndSweepMemoryPool (pools + Descriptor side-table)

interpreter →  uses Value + GcAllocator, never touches backend internals
```

The interpreter accesses object data exclusively through `GcAllocator` convenience
methods (`getCar`, `getNumber`, …). It never inspects `Value.data` directly except for
symbol IDs (inline) and builtin indices (inline). This is the key insight: the
interpreter already treats `Value` as mostly-opaque.

---

## Design

### 1. Make `Value` a comptime-generic type parameter

Replace the hardcoded `const Value = val.Value` import with a comptime type parameter
threaded through `GcAllocator`, `Interpreter`, and helpers.

```zig
// gc.zig
pub fn GcAllocatorFor(comptime V: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const Value = V;
        pub const VTable = struct {
            rawAlloc: *const fn (*anyopaque, ValueTag, *const anyopaque) V,
            rawGet:   *const fn (*anyopaque, ValueTag, usize) *anyopaque,
            pushRoot: *const fn (*anyopaque, V) void,
            popRoot:  *const fn (*anyopaque) void,
            // ...
        };
        // convenience wrappers stay the same, just use V instead of Value
    };
}
```

Each GC backend instantiates this with its own Value type:

```zig
pub const MarkAndSweepValue = struct {
    tag: ValueTag,
    data: usize,
    // extra metadata the GC wants:
    // (none needed here — the Header side-table already carries `marked`)
    // but a generational GC could add: generation: u2,
};
```

### 2. Define a `ValueLike` contract (duck-typing / comptime interface)

Every GC's Value type must provide this minimal surface so the interpreter can use it:

| Required declaration        | Purpose                                      |
|-----------------------------|----------------------------------------------|
| `tag: ValueTag`             | Discriminant (interpreter switches on this)  |
| `fn eql(a, b) bool`        | Structural equality                          |
| `const nil_value: Self`     | Sentinel nil                                 |
| `const true_value: Self`    | Sentinel #t                                  |
| `const false_value: Self`   | Sentinel #f                                  |

`from_index`, `from_ptr`, `get_ptr` etc. are **not** part of the contract — they are
backend-specific construction details. The `GcAllocator` vtable's `rawAlloc` is the
only thing that creates Values; each backend implements that however it likes (index
into a pool, raw pointer, NaN-boxed bits, …). The interpreter never constructs a Value
directly, it always goes through the GC interface.

A comptime check at `GcAllocatorFor` instantiation can assert these exist.

### 3. Parameterise the Interpreter

```zig
// interpreter.zig
pub fn InterpreterFor(comptime GcAlloc: type) type {
    const V = GcAlloc.Value;
    return struct {
        gc: GcAlloc,
        globals: std.AutoHashMapUnmanaged(usize, V),
        // ...
        pub fn eval(self: *@This(), expr: V, scope: ?usize) EvalError!V {
            // identical logic, just uses V everywhere
        }
    };
}

// Convenience alias for the default backend:
pub const Interpreter = InterpreterFor(GcAllocator);
```

### 4. Move pool data types (ConsCell, Closure, …) to remain shared

`ConsCell`, `Closure`, `VectorData`, `StringSpan` stay in `value.zig` as non-generic
types. They keep using the base `Value` struct (`{ tag: ValueTag, data: usize }`)
internally.

Pool types don't access `.data` directly — they just embed `Value`s as opaque blobs
(e.g. `ConsCell { car: Value, cdr: Value }`). Only the GC backends and the interpreter
read `.data`, and those accesses are (or will be) routed through the `GcAllocator`
vtable.

This means the `data` field does **not** need to be `usize`. A backend could use
`*anyopaque`, a packed `u32` handle, or whatever it wants. The comptime contract only
enforces `tag: ValueTag` as the first field. The pool types remain non-generic because
they don't care what's inside a Value — they just store them.

**Caveat:** all backends must agree on a single `Value` size so that pool types (which
embed Values by-value) are layout-compatible. In practice this means backends that need
extra metadata can either (a) use the same-sized Value struct with the extra bits packed
into the existing `data` field, or (b) store metadata externally in side-tables (which
the current backends already do with `Header.marked` / `Descriptor`).

### 5. Keep `ValueTag` shared

`ValueTag` stays in `value.zig` as a plain enum — all backends use the same tag set.

### 6. Move `Scope` into the GC backend (already done conceptually)

`Scope` is already in `gc.zig`. It should remain there because it is GC-managed state.

---

## Step-by-Step Implementation Order

### Phase 1 — Prepare (no behavioural change)

1. **Extract a `ValueInterface` comptime validator** in `value.zig`:
   ```zig
   pub fn assertValueInterface(comptime V: type) void {
       const fields = @typeInfo(V).@"struct".fields;
       // Enforce that field 0 is `tag: ValueTag`.
       if (fields.len < 1)
           @compileError("Value type must have at least 1 field");
       if (!std.mem.eql(u8, fields[0].name, "tag") or fields[0].type != ValueTag)
           @compileError("Value field 0 must be `tag: ValueTag`");
       // Contract: eql, nil_value, true_value, false_value
       if (!@hasDecl(V, "eql"))
           @compileError("Value type must declare `fn eql(V, V) bool`");
       if (!@hasDecl(V, "nil_value"))
           @compileError("Value type must declare `nil_value`");
       if (!@hasDecl(V, "true_value"))
           @compileError("Value type must declare `true_value`");
       if (!@hasDecl(V, "false_value"))
           @compileError("Value type must declare `false_value`");
       // All Value types must be the same size so pool types
       // that embed Values by-value remain layout-compatible.
       if (@sizeOf(V) != @sizeOf(Value))
           @compileError("Value type must be the same size as the base Value");
   }
   ```
   Only `tag: ValueTag` is enforced as field 0. The rest of the struct
   is the backend's business — `data` can be `usize`, `*anyopaque`,
   a packed bitfield, etc. The `@sizeOf` check ensures pool types
   (`ConsCell`, `Closure`, …) that embed Values by-value stay
   layout-compatible across backends.
2. **Add `pub const Value = val.Value;`** re-exports where needed so later replacement
   is a single-line change per file.

### Phase 2 — Generify `GcAllocator`

3. Rename `GcAllocator` → `GcAllocatorFor(comptime V: type)`.
4. Keep a default alias: `pub const GcAllocator = GcAllocatorFor(val.Value);`
5. Update all three backends to instantiate with their Value type (initially still
   `val.Value`, so no behaviour changes yet).
6. **Run all tests — everything must still pass.**

### Phase 3 — Generify the Interpreter

7. Turn `Interpreter` into `InterpreterFor(comptime GcAlloc: type)`.
8. Keep alias: `pub const Interpreter = InterpreterFor(GcAllocator);`
9. Thread `V` through `eval`, `astToValue`, builtins, `envLookup`, etc.
10. **Run all tests.**

### Phase 4 — Migrate existing backends

11. Update `NoGc`, `MarkAndSweepGPABacked`, and `MarkAndSweepMemoryPool` to use
    `GcAllocatorFor(val.Value)` instead of the old monomorphic `GcAllocator`.
12. Each backend's `gcAllocator()` method returns the parameterised type.
13. Replace all direct `.data` access in `rawAlloc`/`rawGet`/`mark`/`sweep` with
    the backend's own Value-construction helpers (e.g. `Value.from_index`), since
    `.data` as `usize` is now a per-backend choice, not a universal guarantee.
14. Remove `Value.from_index`, `Value.from_ptr`, `Value.get_ptr`, `Value.get_index`,
    `Value.set_index` from the shared `Value` struct — move them into each backend
    that still needs them as internal helpers.
15. Update `bindInterpreter` signatures to accept the generic globals map type.
16. **Run all tests — everything must still pass.**

### Phase 5 — Demonstrate with a custom Value

17. Create a `RefCountedGc` (or similar) that defines its own `Value`:
    ```zig
    pub const RcValue = struct {
        tag: ValueTag,
        data: usize,
        rc: u32 = 1,       // <-- extra metadata
    };
    ```
18. Implement the `GcAllocatorFor(RcValue)` vtable for this backend.
19. Instantiate `InterpreterFor(RcGcAllocator)` and run the test suite against it.

---

## Files Changed

| File               | Change                                                  |
|--------------------|---------------------------------------------------------|
| `value.zig`        | Add `assertValueInterface`; keep existing `Value` as-is |
| `gc.zig`           | `GcAllocator` → `GcAllocatorFor(V)`; update backends    |
| `interpreter.zig`  | `Interpreter` → `InterpreterFor(GcAlloc)`               |
| `parser.zig`       | No change (AST nodes don't contain Values)              |
| `symbol.zig`       | No change                                               |
| `main.zig`         | Update instantiation to use concrete alias              |
| `tests/`           | Parametric test helpers; run suite per backend           |

## Risks & Mitigations

- **Compile-time complexity:** Zig generics are monomorphised — each backend gets its
  own copy of the interpreter. Binary size grows but runtime cost is zero. Acceptable
  for an educational/research project.
- **ConsCell/Closure containing `Value`:** If `Value` size changes between backends,
  pool types must also be generic. Mitigate by requiring prefix-compatible layout (see
  Phase 4) or by generifying early.
- **Builtin function signatures:** Builtins take `*Interpreter` and `Value`. After
  generification they become `*InterpreterFor(GcAlloc)` and `GcAlloc.Value`. This is
  automatic via the comptime parameter, but external/plugin builtins would need to be
  generic too.

## Alternative Considered: Runtime-polymorphic Value (rejected)

Wrapping Value behind a `*const VTable` at runtime would add an indirection on every
value access. Given Values are the hottest path in a Lisp interpreter, comptime generics
are strictly better here — zero overhead, full inlining.
