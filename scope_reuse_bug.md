# Scope Reuse Bug

## Summary

The interpreter's scope free-list (`scope_free`) recycles scope IDs, but closures
hold a stale `env_id` that can point to a recycled/overwritten scope. This causes
`UnboundVariable` errors when multiple closure-producing or recursive higher-order
functions are defined and called in the same program.

## How to reproduce

The following program crashes with `UnboundVariable`:

```scheme
(define (map fn lst)
  (if (null? lst) (list) (cons (fn (car lst)) (map fn (cdr lst)))))
(define (filter pred lst)
  (if (null? lst) (list)
      (if (pred (car lst)) (cons (car lst) (filter pred (cdr lst))) (filter pred (cdr lst)))))
(define (foldl op acc lst)
  (if (null? lst) acc (foldl op (op acc (car lst)) (cdr lst))))
(define (sq x) (* x x))
(define (gt3 x) (> x 3))
(define (add a b) (+ a b))
(display (map sq (list 1 2 3)))
(display (filter gt3 (list 1 2 3 4 5)))
(display (foldl add 0 (list 1 2 3)))
```

Any two of the three higher-order functions work fine; adding the third triggers the bug.
Similarly, defining three closure-producing functions (e.g. `curry-add`, `make-adder-pair`,
`outer`) and calling all three fails.

## Root cause

In `interpreter.zig`, `envExtend` (line ~127) pops a scope ID from `scope_free` and
reuses it:

```zig
fn envExtend(self: *Interpreter, parent: ?u24, params: Value, args: Value) !u24 {
    const scope_id: u24 = if (self.scope_free.items.len > 0)
        self.scope_free.pop().?
    else blk: { ... };
    var scope = &self.scopes.items[scope_id];
    scope.parent = parent;
    scope.table.clearRetainingCapacity();
    // ...
}
```

When a closure is created (via `evalLambda` or `evalDefine` with function shorthand),
it captures the current scope as `env_id`. When that scope is later freed and recycled
by a different function call, the closure's `env_id` now points to a completely different
scope with different bindings (or none at all).

### Sequence that triggers the bug

1. `(map sq (list 1 2 3))` — `map` recurses, creating and freeing scopes (e.g. scope 0, 1, 2).
2. After `map` returns, those scope IDs go back into `scope_free`.
3. `(filter gt3 ...)` — reuses the recycled scope IDs, overwriting their contents.
4. Any closure that still references the old scope ID via `env_id` now looks up
   variables in the wrong scope → `UnboundVariable`.

## Possible fixes

1. **Reference counting on scopes**: Don't free a scope while any live closure references it.
2. **Copy-on-reuse**: When recycling a scope ID, check that no closure's `env_id` points to it
   (expensive).
3. **Don't recycle scopes**: Remove `scope_free` entirely; just append new scopes. Simpler but
   uses more memory (the GC can't reclaim scope slots).
4. **Persistent/immutable environments**: Use a linked structure (e.g. cons-based env) that
   the GC manages, so environments are only collected when truly unreachable.
