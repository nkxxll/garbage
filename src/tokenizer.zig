const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        l_paren,
        r_paren,
        l_bracket,
        r_bracket,
        number_literal,
        string_literal,
        symbol,
        quote,
        hash,
        dot,
        eof,
        invalid,
    };
};

pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,

    pub fn init(buffer: [:0]const u8) Tokenizer {
        return .{ .buffer = buffer, .index = 0 };
    }

    pub fn next(self: *Tokenizer) Token {
        const State = enum {
            start,
            symbol,
            number,
            string_literal,
            string_escape,
            comment,
            hash,
            minus,
        };

        const state: State = .start;
        var start_index: usize = self.index;

        state: switch (state) {
            .start => {
                start_index = self.index;
                const ch = self.buffer[self.index];

                if (ch == 0) {
                    return .{ .tag = .eof, .loc = .{ .start = self.index, .end = self.index } };
                }

                if (std.ascii.isWhitespace(ch)) {
                    self.index += 1;
                    continue :state .start;
                }

                switch (ch) {
                    ';' => {
                        self.index += 1;
                        continue :state .comment;
                    },
                    '(' => {
                        self.index += 1;
                        return .{ .tag = .l_paren, .loc = .{ .start = start_index, .end = self.index } };
                    },
                    ')' => {
                        self.index += 1;
                        return .{ .tag = .r_paren, .loc = .{ .start = start_index, .end = self.index } };
                    },
                    '[' => {
                        self.index += 1;
                        return .{ .tag = .l_bracket, .loc = .{ .start = start_index, .end = self.index } };
                    },
                    ']' => {
                        self.index += 1;
                        return .{ .tag = .r_bracket, .loc = .{ .start = start_index, .end = self.index } };
                    },
                    '\'' => {
                        self.index += 1;
                        return .{ .tag = .quote, .loc = .{ .start = start_index, .end = self.index } };
                    },
                    '#' => {
                        self.index += 1;
                        continue :state .hash;
                    },
                    '"' => {
                        self.index += 1;
                        continue :state .string_literal;
                    },
                    '-' => {
                        self.index += 1;
                        continue :state .minus;
                    },
                    '.' => {
                        if (isDotTerminator(self.buffer[self.index + 1])) {
                            self.index += 1;
                            return .{ .tag = .dot, .loc = .{ .start = start_index, .end = self.index } };
                        }

                        self.index += 1;
                        continue :state .symbol;
                    },
                    else => {},
                }

                if (std.ascii.isDigit(ch)) {
                    self.index += 1;
                    continue :state .number;
                }

                if (isSymbolStart(ch)) {
                    self.index += 1;
                    continue :state .symbol;
                }

                self.index += 1;
                return .{ .tag = .invalid, .loc = .{ .start = start_index, .end = self.index } };
            },
            .symbol => {
                const ch = self.buffer[self.index];
                if (isSymbolContinue(ch)) {
                    self.index += 1;
                    continue :state .symbol;
                }

                return .{ .tag = .symbol, .loc = .{ .start = start_index, .end = self.index } };
            },
            .number => {
                const ch = self.buffer[self.index];
                if (std.ascii.isDigit(ch)) {
                    self.index += 1;
                    continue :state .number;
                }

                return .{ .tag = .number_literal, .loc = .{ .start = start_index, .end = self.index } };
            },
            .string_literal => {
                const ch = self.buffer[self.index];
                switch (ch) {
                    '"' => {
                        self.index += 1;
                        return .{ .tag = .string_literal, .loc = .{ .start = start_index, .end = self.index } };
                    },
                    '\\' => {
                        self.index += 1;
                        continue :state .string_escape;
                    },
                    0 => {
                        return .{ .tag = .invalid, .loc = .{ .start = start_index, .end = self.index } };
                    },
                    else => {
                        self.index += 1;
                        continue :state .string_literal;
                    },
                }
            },
            .string_escape => {
                const ch = self.buffer[self.index];
                if (ch == 0) {
                    return .{ .tag = .invalid, .loc = .{ .start = start_index, .end = self.index } };
                }

                self.index += 1;
                continue :state .string_literal;
            },
            .comment => {
                const ch = self.buffer[self.index];
                switch (ch) {
                    0 => continue :state .start,
                    '\n' => {
                        self.index += 1;
                        continue :state .start;
                    },
                    else => {
                        self.index += 1;
                        continue :state .comment;
                    },
                }
            },
            .hash => {
                return .{ .tag = .hash, .loc = .{ .start = start_index, .end = self.index } };
            },
            .minus => {
                const ch = self.buffer[self.index];
                if (std.ascii.isDigit(ch)) {
                    continue :state .number;
                }

                continue :state .symbol;
            },
        }
    }

    pub fn slice(self: Tokenizer, token: Token) []const u8 {
        return self.buffer[token.loc.start..token.loc.end];
    }
};

fn isSymbolStart(ch: u8) bool {
    return switch (ch) {
        'a'...'z',
        'A'...'Z',
        '!',
        '$',
        '%',
        '&',
        '*',
        '+',
        '-',
        '/',
        ':',
        '<',
        '=',
        '>',
        '?',
        '@',
        '^',
        '_',
        '~',
        => true,
        else => false,
    };
}

fn isSymbolContinue(ch: u8) bool {
    return isSymbolStart(ch) or std.ascii.isDigit(ch) or ch == '.' or ch == '!' or ch == '?';
}

fn isDotTerminator(ch: u8) bool {
    return ch == 0 or std.ascii.isWhitespace(ch) or ch == '(' or ch == ')';
}

test "tokenizer cases from plan" {
    const cases = [_]struct {
        input: [:0]const u8,
        expected: []const Token.Tag,
    }{
        .{
            .input = "(define x 42)",
            .expected = &.{ .l_paren, .symbol, .symbol, .number_literal, .r_paren, .eof },
        },
        .{
            .input = "(lambda (x) x)",
            .expected = &.{ .l_paren, .symbol, .l_paren, .symbol, .r_paren, .symbol, .r_paren, .eof },
        },
        .{
            .input = "'(1 2 3)",
            .expected = &.{ .quote, .l_paren, .number_literal, .number_literal, .number_literal, .r_paren, .eof },
        },
        .{
            .input = "(set! x 10)",
            .expected = &.{ .l_paren, .symbol, .symbol, .number_literal, .r_paren, .eof },
        },
        .{
            .input = "\"hello\"",
            .expected = &.{ .string_literal, .eof },
        },
        .{
            .input = "#t #f",
            .expected = &.{ .hash, .symbol, .hash, .symbol, .eof },
        },
        .{
            .input = "(a . b)",
            .expected = &.{ .l_paren, .symbol, .dot, .symbol, .r_paren, .eof },
        },
        .{
            .input = "; comment\n42",
            .expected = &.{ .number_literal, .eof },
        },
        .{
            .input = "(make-vector 100)",
            .expected = &.{ .l_paren, .symbol, .number_literal, .r_paren, .eof },
        },
        .{
            .input = "-7",
            .expected = &.{ .number_literal, .eof },
        },
        .{
            .input = "+",
            .expected = &.{ .symbol, .eof },
        },
    };

    for (cases) |case| {
        var tokenizer = Tokenizer.init(case.input);
        var idx: usize = 0;
        while (true) {
            const token = tokenizer.next();
            try std.testing.expect(idx < case.expected.len);
            try std.testing.expectEqual(case.expected[idx], token.tag);
            idx += 1;
            if (token.tag == .eof) break;
        }
        try std.testing.expectEqual(case.expected.len, idx);
    }
}
