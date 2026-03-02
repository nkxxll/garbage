# Plan: Testing MarkAndSweepGPABacked with the Interpreter

## Problem Summary

`MarkAndSweepGPABacked` can't be plugged into the interpreter or existing tests yet due to:
1. A **circular init dependency** (GC needs `*globals`/`*scopes` from the interpreter, but the interpreter needs a `GcAllocator` at init)
2. Several **correctness bugs** in the mark/sweep implementation
3. The test helpers and `main.zig` are **hardcoded to `NoGc`**

---

## Phase 1: Fix Bugs in `MarkAndSweepGPABacked`

These must be fixed before any integration testing is meaningful.

### 1.1 `sweep()` iterates the wrong set — never collects garbage

**Bug**: `sweep()` walks `scopes`, `globals`, and `roots` (the *reachable* set) and frees unmarked items in them. But those items were just marked in `mark()`, so nothing is ever freed. Unreachable objects (the garbage) are never visited at all.

**Fix**: `sweep()` must iterate **all** entries in `self.objects`. For each object: if `marked`, clear the mark for the next cycle; if not marked, free the data and add the index to `free_list`.

```zig
fn sweep(self: *MarkAndSweepGPABacked) void {
    for (self.objects.items, 0..) |*header, i| {
        if (header.marked) {
            header.marked = false; // reset for next cycle
        } else {
            // free the data (requires knowing the type — see 1.3)
            // add @intCast(i) to free_list
        }
    }
}
```

### 1.2 `mark()` doesn't trace transitively

**Bug**: `mark()` only marks the direct values in scopes/globals/roots. If a cons cell references another cons cell, the inner one won't be marked and will be collected prematurely.

**Fix**: Extract a recursive `markValue(v: Value)` helper that:
- Marks the header at `v.payload`
- If already marked, return (cycle protection)
- If `v.tag == .cons`, recursively mark `car` and `cdr`
- If `v.tag == .closure`, recursively mark `params` and `body`
- If `v.tag == .vector`, recursively mark each element

### 1.3 `Header` needs a `tag` field for proper deallocation

**Bug**: `deinit()` and `sweep()` call `self.gpa.free(header.data)` on a `*anyopaque`. The GPA needs the correct alignment and size to free. Strings/vectors also have a secondary allocation (the duped slice) that leaks.

**Fix**: Add `tag: ValueTag` to `Header`. Then in the free path, switch on tag:
- `.number` → `destroy(f64, ptr)`
- `.cons` → `destroy(ConsCell, ptr)`
- `.closure` → `destroy(Closure, ptr)`
- `.string` → free the duped `[]u8`, then `destroy([]const u8, ptr)`
- `.vector` → free the duped `[]Value`, then `destroy([]Value, ptr)`

### 1.4 `initCapacity` error handling

`std.ArrayList(...).initCapacity(gpa, 64)` returns an error union. Use `catch @panic("OOM")` or switch to plain `.init()` and let it grow lazily (simpler, consistent with how the GPA allocs handle OOM already).

### 1.5 `sweepItem` sets `undefined`

Setting `self.objects.items[i] = undefined` means any later access is UB. Better to use a sentinel (e.g., `Header{ .marked = false, .tag = .nil, .data = undefined }`) or track liveness via the free_list/a bitset.

---

## Phase 2: Resolve the Circular Init Dependency

**Current situation**:
- `MarkAndSweepGPABacked.init()` takes `*globals` and `*scopes` (pointers into the Interpreter)
- `Interpreter.init()` takes a `GcAllocator` and initializes `globals`/`scopes` internally

**Options** (pick one):

### Option A: Two-phase init (recommended, least invasive)

1. `Interpreter.init()` takes `GcAllocator` as today.
2. After `init()`, call a new method on the GC backend to wire up the pointers:
   ```zig
   var ms = MarkAndSweepGPABacked.initPartial(allocator);
   var interp = try Interpreter.init(ms.gcAllocator(), &p.ast, allocator);
   ms.bindInterpreter(&interp.globals, &interp.scopes);
   ```
   The GC works in "no-collect" mode until `bindInterpreter` is called (or simply doesn't trigger collection during the first N allocs from `registerBuiltin`).

### Option B: Interpreter exposes globals/scopes before init

Split `Interpreter` so that `globals` and `scopes` are initialized first, then passed to both the GC and the interpreter setup. Requires more refactoring.

### Option C: GC discovers roots via a callback

Instead of holding pointers, the VTable gets a `getRoots` callback. Most flexible but largest API change.

**Recommendation**: Option A — add `initPartial` + `bindInterpreter` to `MarkAndSweepGPABacked`.

---

## Phase 3: Add Interpreter-Level Tests with MarkAndSweepGPABacked

### 3.1 Parameterize `testEval` in `interpreter.zig`

Create a `testEvalWithGc` helper that uses `MarkAndSweepGPABacked` alongside the existing `testEval` (which uses `NoGc`). Structure:

```zig
fn testEvalGc(source: [:0]const u8) !struct { value: Value, number: f64, output: []const u8 } {
    const allocator = std.testing.allocator;
    var p = parser.Parser.init(allocator, source);
    _ = try p.parseRoot();
    defer p.ast.deinit();

    var ms = gc_mod.MarkAndSweepGPABacked.initPartial(allocator);
    defer ms.deinit();

    var interp = try Interpreter.init(ms.gcAllocator(), &p.ast, allocator);
    defer interp.deinit();
    ms.bindInterpreter(&interp.globals, &interp.scopes);

    // ... same eval loop as testEval ...
}
```

### 3.2 Duplicate each existing interpreter test for the GC backend

For every `test "eval: ..."` block, add a matching `test "eval-gc: ..."` that calls `testEvalGc`. This gives you instant coverage showing that the GC produces the same results as `NoGc`. Example:

```zig
test "eval-gc: (+ 1 2) = 3" {
    const r = try testEvalGc("(+ 1 2)");
    defer std.testing.allocator.free(r.output);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), r.number, 0.001);
}
```

### 3.3 GC-specific stress tests

Add tests that specifically exercise collection:

| Test | Purpose |
|------|---------|
| **Allocation pressure** | Loop creating >25 values (the `GC_AFTER_N_ALLOCATIONS` threshold) and verify the result is still correct. E.g. sum 1..30. | 
| **Closure survival** | Define a closure, trigger GC, then call the closure — verifies transitive marking of closure params/body. |
| **List building** | Build a long list (>25 cons cells), walk it — verifies cons cell chains survive marking. |
| **set!/mutation after GC** | `(define x (cons 1 2))` + many allocs to trigger GC + `(set-car! x 99)` — verifies mutated live objects survive. |
| **Leak detection** | Use `std.testing.allocator` (which is a leak-detecting allocator) — if `deinit` doesn't free everything, the test fails automatically. |

### 3.4 Snapshot tests with GC backend

**Option**: Add a `--gc` flag to `main.zig` (or a build option) to select the GC backend. Then duplicate the snapshot test invocation:
```bash
# In snapshot_test.sh, run each fixture twice:
"$LLISP" "$fixture"           # NoGc (existing)
"$LLISP" --gc "$fixture"      # MarkAndSweepGPABacked (new)
```
Both runs must produce identical output.

---

## Phase 4: Execution Order

1. **Fix `Header` to include `tag`** (1.3)
2. **Fix `mark()` to trace transitively** (1.2)
3. **Fix `sweep()` to iterate all objects** (1.1)
4. **Fix `initCapacity` and `undefined` issues** (1.4, 1.5)
5. **Add unit tests for the GC itself** in `gc.zig` (round-trip alloc/get, mark/sweep frees unreachable, mark/sweep keeps reachable)
6. **Implement two-phase init** (Phase 2, Option A)
7. **Add `testEvalGc` + duplicate interpreter tests** (3.1, 3.2)
8. **Add GC stress tests** (3.3)
9. **Wire up snapshot tests** (3.4)

Each step should be validated with `zig build test` before moving on.
