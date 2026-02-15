# Implementation Progress

## Step 1: `src/value.zig` — ✅ DONE
- Value (packed u32: 8-bit tag + 24-bit payload)
- ValueTag enum (nil, number, boolean, cons, symbol, string, vector, closure, builtin)
- Sentinel constants (nil_value, true_value, false_value)
- Pool data structs (ConsCell, Closure, VectorData, StringSpan)
- Value.eql helper
- Tests pass: size check, sentinel patterns, eql, tag distinctness

## Step 2: `src/symbol.zig` — ✅ DONE
- SymbolTable with intern/getName
- Packed char buffer + spans + StringHashMapUnmanaged for dedup
- Tests pass: dedup, distinct indices, getName round-trip

## Step 3: `src/gc.zig` — ✅ DONE
- GcAllocator fat-pointer interface with 6-entry VTable (rawAlloc, rawGet, pushRoot, popRoot, writeBarrier, collectGarbage)
- Generic `alloc(comptime T, val)` / `get(comptime T, payload)` — tag derived from comptime type
- Typed convenience wrappers: getCar/getCdr/setCar/setCdr, getNumber, getClosure, getString, getVectorSlice
- NoGc backend: arena-backed pools, no free lists, no collection
- Tests pass: number, cons, string, vector, closure round-trips, setCar/setCdr mutation, pushRoot/popRoot

## Step 4: `src/gc/mark_sweep.zig` — 🔲 DEFERRED
- Will be built later; using placeholder NoGc for now

## Step 5: `src/interpreter.zig` — ✅ DONE
- (a) Struct + init with builtin registration, pre-interned special form symbols
- (b) Scope pool + envLookup/envExtend/envSet with parent chain → globals fallback
- (c) astToValue: handles all AST node tags (number, symbol, string, boolean, list, quote, vector, dotted_list)
- (d) eval + special forms: quote, define (simple + function shorthand), set!, if, lambda, begin
- (e) apply: builtin dispatch + closure call with scope extension
- (f) builtins: +, -, *, /, cons, car, cdr, eq?, null?, list, display, newline, <, >, =, not, set-car!, set-cdr!
- writeValue for display output
- Tests pass: arithmetic, define, if, lambda, factorial recursion, cons/car/cdr, eq?, null?, quote, begin, set!, list, nested closures

## Step 6: `src/main.zig` — ✅ DONE
- CLI wiring: reads source file, parses, evaluates all top-level forms, prints output
- Usage: `zig build run -- <file>`
- End-to-end verified: `(fact 10)` → 3628800

## What's Next
- [ ] `src/gc/mark_sweep.zig` — Real mark-and-sweep GC backend
- [ ] More builtins (make-vector, vector-ref, vector-set!, etc.)
- [ ] REPL mode
- [ ] Error reporting with source locations
- [ ] GC stress tests
