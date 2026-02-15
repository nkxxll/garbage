# Lisp Tokenizer Plan

Modeled after the [Zig standard library tokenizer](https://github.com/ziglang/zig/blob/master/lib/std/zig/tokenizer.zig): a hand-written, single-pass, labeled state machine that lazily produces tokens on demand.

---

## 1. Struct Layout

```zig
pub const Tokenizer = struct {
    buffer: [:0]const u8, // null-terminated source input
    index: usize,         // current byte position

    pub fn init(buffer: [:0]const u8) Tokenizer { ... }
    pub fn next(self: *Tokenizer) Token { ... }
};
```

- **Null-terminated input** — eliminates bounds checks; `buffer[index]` is always safe.
- **Lazy iteration** — `next()` returns one token per call, no up-front allocation.

---

## 2. Token Type

```zig
pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        // Delimiters
        l_paren,        // (
        r_paren,        // )
        l_bracket,      // [   (vector literal shorthand)
        r_bracket,      // ]

        // Literals
        number_literal, // 42, -7, 0xFF (if desired)
        string_literal, // "hello"
        symbol,         // foo, define, lambda, +, <=, set!

        // Special prefixes
        quote,          // '
        hash,           // # (for #t, #f, #(...) vector literals)

        // Dot (for dotted pairs: (a . b))
        dot,

        // Meta
        eof,
        invalid,
    };
};
```

### Token design notes

| Choice | Rationale |
|--------|-----------|
| Keywords are **not** separate tags | Lisp has no reserved words at the lexical level; `define`, `lambda`, `if`, `quote`, `set!` are all symbols. The parser/evaluator distinguishes them. |
| `quote` is its own tag | `'expr` is syntactic sugar for `(quote expr)` and is easier to handle as a distinct token. |
| `hash` tag | Covers `#t`, `#f` booleans and `#(` vector literal prefix. The parser combines `hash` + following chars. |
| `dot` tag | Required for dotted-pair notation `(a . b)`, separated from symbols so the parser can detect it. |

---

## 3. State Machine

The `next()` function uses Zig's `state: switch (State) { ... continue :state .foo; }` pattern.

```zig
const State = enum {
    start,
    symbol,
    number,
    string_literal,
    string_escape,
    comment,
    hash,
    minus,           // could be negative number or symbol like `-`
};
```

### State transitions

```
start
 ├── whitespace/newline → skip, stay in start
 ├── ';'               → comment (consume until newline, loop back to start)
 ├── '('               → emit l_paren
 ├── ')'               → emit r_paren
 ├── '['               → emit l_bracket
 ├── ']'               → emit r_bracket
 ├── '\''              → emit quote
 ├── '#'               → emit hash
 ├── '"'               → string_literal
 ├── '-'               → minus (look ahead: digit → number, else → symbol)
 ├── '0'...'9'         → number
 ├── '.'               → dot (if next is whitespace/paren/eof) or symbol (if .foo)
 ├── symbol-start-char → symbol
 ├── 0 (null)          → emit eof
 └── else              → emit invalid

symbol (loop)
 ├── symbol-continue-char → stay in symbol
 └── delimiter/whitespace/eof → emit symbol (don't consume delimiter)

number (loop)
 ├── '0'...'9'              → stay in number
 └── delimiter/whitespace   → emit number_literal

string_literal (loop)
 ├── '"'       → emit string_literal (consume closing quote)
 ├── '\\'      → string_escape
 ├── 0 (null)  → emit invalid (unterminated)
 └── any       → stay in string_literal

string_escape
 └── any char  → back to string_literal

comment (loop)
 ├── '\n' / 0  → back to start
 └── any       → stay in comment
```

### Character classes

```
symbol-start:    a-z A-Z ! $ % & * + - / : < = > ? @ ^ _ ~
symbol-continue: symbol-start + 0-9 . ! ?
delimiter:       ( ) [ ] " ; ' ` , whitespace NUL
```

These classes cover the full range of Scheme/Lisp symbol characters including operators like `+`, `<=`, `set!`, and `make-vector`.

---

## 4. Public API

```zig
// Initialize from null-terminated source
pub fn init(buffer: [:0]const u8) Tokenizer

// Return next token, advance index
pub fn next(self: *Tokenizer) Token

// Extract the source text of a token
pub fn slice(self: Tokenizer, token: Token) []const u8 {
    return self.buffer[token.loc.start..token.loc.end];
}
```

Usage:

```zig
var tok = Tokenizer.init(source);
while (true) {
    const token = tok.next();
    if (token.tag == .eof) break;
    // process token
}
```

---

## 5. File Location

```
src/
  tokenizer.zig      ← the tokenizer
```

---

## 6. Implementation Order

1. **Skeleton** — `Tokenizer` struct, `Token` struct with `Tag` enum, `init`, `next` returning `.eof`.
2. **Whitespace + single-char tokens** — `( ) [ ] ' .` and whitespace skipping.
3. **Comments** — `;` to end-of-line.
4. **Symbols** — multi-char identifier/operator scanning with keyword-free design.
5. **Number literals** — integer scanning (negative numbers via `minus` state).
6. **String literals** — with escape sequence support (`\\`, `\"`, `\n`, `\t`).
7. **Hash prefix** — `#` token for booleans and vector literals.
8. **Invalid/error tokens** — catch-all for unexpected bytes.
9. **Tests** — unit tests using `std.testing` for each token type, edge cases (empty input, unterminated strings, nested parens, dotted pairs, symbol edge cases like `set!`).

---

## 7. Test Cases to Cover

| Input | Expected tokens |
|-------|-----------------|
| `(define x 42)` | `l_paren symbol symbol number_literal r_paren eof` |
| `(lambda (x) x)` | `l_paren symbol l_paren symbol r_paren symbol r_paren eof` |
| `'(1 2 3)` | `quote l_paren number_literal number_literal number_literal r_paren eof` |
| `(set! x 10)` | `l_paren symbol symbol number_literal r_paren eof` |
| `"hello"` | `string_literal eof` |
| `#t #f` | `hash symbol hash symbol eof` (or parser combines) |
| `(a . b)` | `l_paren symbol dot symbol r_paren eof` |
| `; comment\n42` | `number_literal eof` |
| `(make-vector 100)` | `l_paren symbol number_literal r_paren eof` |
| `-7` | `number_literal eof` |
| `+` | `symbol eof` |
