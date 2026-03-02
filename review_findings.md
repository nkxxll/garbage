# Code Review Findings

Review of `gc.zig`, `interpreter.zig`, and `value.zig`.

---

## Critical — Broken / Non-compiling Code

### 1. `MarkAndSweepGPABacked.rawAlloc` has an empty body
**File:** `gc.zig` L132–136

The function body is completely empty. This struct will not compile if ever instantiated.

### 2. `MarkAndSweepGPABacked.rawGet` uses invalid Zig comparisons
**File:** `gc.zig` L143–145

```zig
assert(h != undefined);
assert(h.data != undefined);
assert(h.data != null);
```

Zig has no JavaScript-style `undefined` or `null` for structs/pointers like this. `undefined` in Zig is `@import("std").mem.zeroes(...)` or the special `undefined` value which cannot be compared with `!=`. Pointer-typed fields in Zig are never nullable unless declared `?*T`. This code will not compile.

### 3. `MarkAndSweepGPABacked.init` has type mismatches
**File:** `gc.zig` L96–121

- Field `roots` is `std.ArrayList(Value)` but initialized as `std.ArrayList(Header).initCapacity(...)` (L117).
- Field `globals` is `*std.AutoArrayHashMapUnmanaged(u24, Value)` but the `init` parameter is `*std.AutoHashMapUnmanaged(u24, Value)` (different map type).
- Fields `objects` and `freeList` are never initialized at all.

### 4. `MarkAndSweepGPABacked.pushRootFn` calls non-existent method `self.a()`
**File:** `gc.zig` L151

The struct has a `gpa` field but no `a()` helper (unlike `NoGc` which does). Should be `self.gpa` instead.

---

## High — Design & Correctness Issues

### 5. VTable `rawAlloc` cannot propagate allocation errors
**File:** `gc.zig` L20

`rawAlloc` returns `Value`, not `!Value`. All backends are forced to `@panic("OOM")` on allocation failure instead of returning an error. This makes the interpreter unrecoverable on OOM.

### 6. No bounds check on u24 payload index overflow
**File:** `gc.zig` L239 (and similar `@intCast` sites)

`@intCast(pool.items.len)` will panic at runtime if more than 16,777,215 objects of a single type are allocated, but there is no graceful handling — this is a silent hard limit with no user-facing error.

### 7. `Value.eql` compares payload indices, not semantic values
**File:** `value.zig` L7–9

Two separately-allocated `Value`s holding the same `f64` will have different payloads and `eql` returns `false`. This is partially mitigated in `builtinEq` (which special-cases numbers), but `eql` is used un-guarded in `builtinNot` (L534) — `(not 0.0)` allocated at two different points would behave inconsistently.

### 8. `evalDefine` always writes to globals, ignoring current scope
**File:** `interpreter.zig` L277

```zig
try self.globals.put(self.backing, first.payload, result);
```

In standard Scheme, `(define x ...)` inside a `lambda` or `begin` should create a local binding. This implementation always mutates the global environment, which is incorrect for lexically-scoped Scheme.

### 9. Scopes are never returned to the free list — scope leak
**File:** `interpreter.zig` L127–151

`envExtend` allocates scopes (or pops from `scope_free`), but after a closure returns, the scope is never pushed back onto `scope_free`. Every function call permanently consumes a scope slot. The free-list mechanism exists but is never fed.

### 10. No tail-call optimization (TCO)
**File:** `interpreter.zig` L335–343, L358–371

`evalBegin` and `apply` recurse through `eval`. Tail-recursive Scheme programs (idiomatic Scheme style, e.g. loops via recursion) will blow the Zig call stack. For a Lisp interpreter this is a significant omission — Scheme *requires* proper tail calls per spec.

### 11. Circular module dependency
**File:** `gc.zig` L10, `interpreter.zig` L4

`gc.zig` imports `Scope` from `interpreter.zig`, and `interpreter.zig` imports from `gc.zig`. Zig allows this, but it is a design smell — the GC layer should not depend on the interpreter layer. The `Scope` import is only needed by `MarkAndSweepGPABacked` which stores `*std.ArrayList(Scope)`. The GC should receive root-marking callbacks instead.

---

## Medium — Missing Validation & Robustness

### 12. No arity checking on builtin calls
**File:** `interpreter.zig` L447–551

Builtins like `+`, `-`, `car`, etc. assume a fixed argument count but never verify it. Calling `(+ 1)` or `(+ 1 2 3)` will silently read garbage from the cons list or ignore extra args. The `args2` helper (L390–394) blindly destructures without checking.

### 13. Arithmetic builtins are not variadic
**File:** `interpreter.zig` L447–467

Scheme's `+`, `-`, `*` are variadic (e.g., `(+ 1 2 3 4)`). This implementation only handles exactly 2 arguments, which is non-standard.

### 14. `evalQuote` doesn't validate its argument list
**File:** `interpreter.zig` L267–269

If `(quote)` is evaluated with no arguments (e.g., maliciously constructed cons cell), `args.payload` will index into arbitrary memory. There's no check that `args.tag == .cons`.

### 15. Sentinel value `maxInt(u24)` for "no parent scope"
**File:** `interpreter.zig` L284, L326

```zig
const env_id: u24 = if (scope) |s| s else std.math.maxInt(u24);
```

Using a magic sentinel is fragile. If exactly 16,777,215 scopes exist, this collides with a valid scope ID. Idiomatic Zig would use `?u24` (optional) in the `Closure` struct.

### 16. `evalArgList` is recursive — can stack-overflow on long lists
**File:** `interpreter.zig` L345–354

Evaluating `(f a1 a2 ... a10000)` recurses 10,000 times through `evalArgList`. An iterative approach (build list in reverse, then reverse) would be safer.

---

## Low — Dead Code, Style, Hygiene

### 17. `VectorData` and `StringSpan` are unused dead code
**File:** `value.zig` L43–51

These structs are defined but never referenced anywhere. The GC stores vectors as `[]Value` and strings as `[]const u8` directly.

### 18. `MarkAndSweepGPABacked` has TODO comments and stub implementations
**File:** `gc.zig` L107–109, L160–161

```zig
// todo alloc
// todo free (is a real free with the gpa
// garbage collect after a certain number of allocation calls
```

`writeBarrierFn` and `collectGarbageFn` are empty no-ops. This entire struct is dead/WIP code checked into the repository alongside working code, making it unclear what is production-ready.

### 19. `MarkAndSweepGPABacked` has no `deinit` or `gcAllocator()` method
**File:** `gc.zig` L94–162

Unlike `NoGc`, this backend has no way to clean up or to construct a `GcAllocator` handle, making it unusable even if the compile errors were fixed.

### 20. `writeValue` doesn't escape strings
**File:** `interpreter.zig` L415

`(display "hello\"world")` — strings with quotes or backslashes are printed raw without escaping, producing ambiguous output.

### 21. `getVectorSlice` returns mutable `[]Value` through a `[]const Value`-typed pool
**File:** `gc.zig` L65–67

The `alloc` path stores `[]const Value` → the pool is `ArrayList([]Value)` → `getVectorSlice` returns `[]Value`. The const-to-mutable promotion via pointer cast is a soundness concern — callers can silently mutate vector contents without a write barrier.
