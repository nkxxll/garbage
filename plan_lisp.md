# Lisp Interpreter Requirements

## 1. The Core Data Structures

At its heart, GC is about managing a graph of objects. To make this interesting, you need more than just integers.

* **Cons Cells:** The bread and butter. This allows for linked lists and tree structures, which are essential for testing recursive marking.
* **Fixnums (Integers):** Essential for "Tagged Pointers." You need a way to distinguish between a raw value and a memory address.
* **Symbols/Strings:** These are great for testing "long-lived" data that might stay in a "Tenured" generation.
* **Vectors (Arrays):** **Crucial.** Fixed-size arrays allow you to test "large object" allocation and contiguous memory scanning.

---

## 2. Minimalist Feature Set

To keep implementation fast, stick to a **Lisp-1** (like Scheme) or a very thin **Lisp-2**.

### Essential Language Constructs

* **`quote`**: To get raw data into the system.
* **`define` / `set!**`: You **must** have mutation. Without `set!`, you can't create circular references, which are the ultimate test for a GC (and why reference counting often fails).
* **`lambda`**: Functions are objects too! This allows you to test "lexical closures"—objects that hold onto their environment even when the function isn't running.
* **`if`**: Basic control flow.

### The "GC Stress" Built-ins

* **`loop` or Recursion:** You need a way to allocate thousands of objects quickly.
* **`make-vector`**: To test heap fragmentation.

---

## 3. The "Pluggable" Architecture

Since your goal is to swap GC strategies, your VM should interact with memory through a **Memory Abstraction Layer**.

| Component | Responsibility |
| --- | --- |
| **The Allocator** | A function like `allocate(size_t bytes)`. In a Mark-and-Sweep system, this looks for free list holes; in a Copying GC, it just bumps a pointer. |
| **The Root Set** | A registry of "always-alive" pointers (the global environment and the current execution stack). The GC must start scanning from here. |
| **Write Barrier** | If you plan to test **Generational GC**, you need a hook every time a pointer is updated (e.g., `set-car!`) to track old-to-young references. |

---

## 4. Implementation Strategy: The "Tagged Pointer"

The easiest way to make your Lisp "GC-ready" is to use **Pointer Tagging**. Instead of storing raw pointers, use the last 2-3 bits of a 64-bit integer to identify the type:

* `00`: Pointer to a Cons cell
* `01`: Immediate Integer
* `10`: Symbol

This allows the GC to scan the stack and immediately know what is a "root" to be followed and what is just a number.

---

## Why this works for a Demo

By implementing a simple `(loop ...)` that builds a massive tree and then "drops" the reference to the root, you can visually (or via logs) demonstrate:

1. **Stop-the-world pauses.**
2. **Memory compaction** (moving objects to the beginning of the heap).
3. **Throughput** (how many allocations per second each strategy handles).

**Would you like me to provide a C or Rust snippet for a basic tagged-pointer object representation to get your memory layout started?**
