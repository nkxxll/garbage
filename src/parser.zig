const std = @import("std");
const tokenizer = @import("tokenizer.zig");

pub const NodeId = usize;

pub const Node = struct {
    tag: Tag,
    loc: tokenizer.Token.Loc,
    data: Data,

    pub const Tag = enum {
        number,
        string,
        symbol,
        boolean,
        list,
        vector,
        quote,
        dotted_list,
    };

    pub const List = struct {
        start: usize,
        len: usize,
    };

    pub const DottedList = struct {
        start: usize,
        len: usize,
        tail: NodeId,
    };

    pub const Data = union(Tag) {
        number: []const u8,
        string: []const u8,
        symbol: []const u8,
        boolean: bool,
        list: List,
        vector: List,
        quote: NodeId,
        dotted_list: DottedList,
    };
};

pub const Ast = struct {
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    nodes: std.ArrayList(Node),
    list_items: std.ArrayList(NodeId),
    root: NodeId,

    pub fn init(allocator: std.mem.Allocator, source: [:0]const u8) Ast {
        return .{
            .allocator = allocator,
            .source = source,
            .nodes = .{},
            .list_items = .{},
            .root = 0,
        };
    }

    pub fn deinit(self: *Ast) void {
        self.nodes.deinit(self.allocator);
        self.list_items.deinit(self.allocator);
    }

    pub fn slice(self: Ast, loc: tokenizer.Token.Loc) []const u8 {
        return self.source[loc.start..loc.end];
    }

    pub fn listSlice(self: Ast, list: Node.List) []const NodeId {
        return self.list_items.items[list.start .. list.start + list.len];
    }

    pub fn dottedSlice(self: Ast, list: Node.DottedList) []const NodeId {
        return self.list_items.items[list.start .. list.start + list.len];
    }
};

pub const Parser = struct {
    tokenizer: tokenizer.Tokenizer,
    current: tokenizer.Token,
    ast: Ast,

    pub fn init(allocator: std.mem.Allocator, source: [:0]const u8) Parser {
        var tokenizer_instance = tokenizer.Tokenizer.init(source);
        const first = tokenizer_instance.next();
        return .{
            .tokenizer = tokenizer_instance,
            .current = first,
            .ast = Ast.init(allocator, source),
        };
    }

    pub const Error = error{
        UnexpectedEof,
        UnexpectedToken,
        InvalidToken,
        InvalidDot,
    } || std.mem.Allocator.Error;

    pub fn parseRoot(self: *Parser) Error!NodeId {
        var items = std.ArrayList(NodeId){};
        defer items.deinit(self.ast.allocator);
        const start_loc = self.current.loc.start;

        while (self.current.tag != .eof) {
            const expr = try self.parseExpr();
            try items.append(self.ast.allocator, expr);
        }

        const items_start = self.ast.list_items.items.len;
        try self.ast.list_items.appendSlice(self.ast.allocator, items.items);
        const len = items.items.len;
        const end_loc = self.current.loc.end;
        const root_id = try self.addNode(.list, Node.List{ .start = items_start, .len = len }, .{ .start = start_loc, .end = end_loc });
        self.ast.root = root_id;
        return root_id;
    }

    fn parseExpr(self: *Parser) Error!NodeId {
        switch (self.current.tag) {
            .l_paren => return self.parseDelimited(.r_paren, .list, self.current.loc.start),
            .l_bracket => return self.parseDelimited(.r_bracket, .vector, self.current.loc.start),
            .number_literal => {
                const token = self.current;
                self.advance();
                return self.addNode(.number, self.ast.slice(token.loc), token.loc);
            },
            .string_literal => {
                const token = self.current;
                self.advance();
                return self.addNode(.string, self.ast.slice(token.loc), token.loc);
            },
            .symbol => {
                const token = self.current;
                self.advance();
                return self.addNode(.symbol, self.ast.slice(token.loc), token.loc);
            },
            .quote => {
                const quote_loc = self.current.loc;
                self.advance();
                const expr = try self.parseExpr();
                const expr_loc = self.ast.nodes.items[expr].loc;
                const loc = tokenizer.Token.Loc{ .start = quote_loc.start, .end = expr_loc.end };
                return self.addNode(.quote, expr, loc);
            },
            .hash => {
                const hash_loc = self.current.loc;
                self.advance();
                return self.parseHash(hash_loc);
            },
            .dot => return error.InvalidDot,
            .r_paren, .r_bracket => return error.UnexpectedToken,
            .eof => return error.UnexpectedEof,
            .invalid => return error.InvalidToken,
        }
    }

    fn parseHash(self: *Parser, hash_loc: tokenizer.Token.Loc) Error!NodeId {
        switch (self.current.tag) {
            .symbol => {
                const sym_loc = self.current.loc;
                self.advance();
                const combined_loc = tokenizer.Token.Loc{ .start = hash_loc.start, .end = sym_loc.end };
                const slice = self.ast.slice(combined_loc);
                if (std.mem.eql(u8, slice, "#t")) {
                    return self.addNode(.boolean, true, combined_loc);
                }
                if (std.mem.eql(u8, slice, "#f")) {
                    return self.addNode(.boolean, false, combined_loc);
                }
                return self.addNode(.symbol, slice, combined_loc);
            },
            .l_paren => return self.parseDelimited(.r_paren, .vector, hash_loc.start),
            else => return error.UnexpectedToken,
        }
    }

    fn parseDelimited(self: *Parser, end_tag: tokenizer.Token.Tag, list_tag: Node.Tag, start_loc: usize) Error!NodeId {
        self.advance();
        var items = std.ArrayList(NodeId){};
        defer items.deinit(self.ast.allocator);
        var dotted_tail: ?NodeId = null;

        while (true) {
            if (self.current.tag == end_tag) {
                const end_loc = self.current.loc.end;
                self.advance();
                const items_start = self.ast.list_items.items.len;
                try self.ast.list_items.appendSlice(self.ast.allocator, items.items);
                const len = items.items.len;
                if (dotted_tail) |tail| {
                    if (list_tag != .list) return error.InvalidDot;
                    try self.ast.nodes.append(self.ast.allocator, .{
                        .tag = .dotted_list,
                        .loc = .{ .start = start_loc, .end = end_loc },
                        .data = .{ .dotted_list = .{ .start = items_start, .len = len, .tail = tail } },
                    });
                    return self.ast.nodes.items.len - 1;
                }
                    const list_data = Node.List{ .start = items_start, .len = len };
                const data: Node.Data = if (list_tag == .vector)
                    .{ .vector = list_data }
                else
                    .{ .list = list_data };
                try self.ast.nodes.append(self.ast.allocator, .{
                    .tag = list_tag,
                    .loc = .{ .start = start_loc, .end = end_loc },
                    .data = data,
                });
                return self.ast.nodes.items.len - 1;
            }

            switch (self.current.tag) {
                .eof => return error.UnexpectedEof,
                .dot => {
                    if (list_tag != .list) return error.InvalidDot;
                    if (dotted_tail != null) return error.InvalidDot;
                    if (items.items.len == 0) return error.InvalidDot;
                    self.advance();
                    dotted_tail = try self.parseExpr();
                    if (self.current.tag != end_tag) return error.InvalidDot;
                },
                else => {
                    const expr = try self.parseExpr();
                    try items.append(self.ast.allocator, expr);
                },
            }
        }
    }

    fn addNode(self: *Parser, comptime tag: Node.Tag, payload: anytype, loc: tokenizer.Token.Loc) std.mem.Allocator.Error!NodeId {
        const data: Node.Data = switch (tag) {
            .number => .{ .number = payload },
            .string => .{ .string = payload },
            .symbol => .{ .symbol = payload },
            .boolean => .{ .boolean = payload },
            .list => .{ .list = payload },
            .vector => .{ .vector = payload },
            .quote => .{ .quote = payload },
            .dotted_list => .{ .dotted_list = payload },
        };
        try self.ast.nodes.append(self.ast.allocator, .{ .tag = tag, .loc = loc, .data = data });
        return self.ast.nodes.items.len - 1;
    }

    fn advance(self: *Parser) void {
        self.current = self.tokenizer.next();
    }
};

pub fn parse(allocator: std.mem.Allocator, source: [:0]const u8) Parser.Error!Ast {
    var parser = Parser.init(allocator, source);
    errdefer parser.ast.deinit();
    _ = try parser.parseRoot();
    return parser.ast;
}

test "parser builds lists and atoms" {
    var ast = try parse(std.testing.allocator, "(define x 42)");
    defer ast.deinit();

    const root_node = ast.nodes.items[ast.root];
    try std.testing.expectEqual(Node.Tag.list, root_node.tag);
    const root_items = ast.listSlice(root_node.data.list);
    try std.testing.expectEqual(@as(usize, 1), root_items.len);

    const list_node = ast.nodes.items[root_items[0]];
    try std.testing.expectEqual(Node.Tag.list, list_node.tag);
    const list_items = ast.listSlice(list_node.data.list);
    try std.testing.expectEqual(@as(usize, 3), list_items.len);

    try std.testing.expectEqualStrings("define", ast.nodes.items[list_items[0]].data.symbol);
    try std.testing.expectEqualStrings("x", ast.nodes.items[list_items[1]].data.symbol);
    try std.testing.expectEqualStrings("42", ast.nodes.items[list_items[2]].data.number);
}

test "parser handles quotes, dotted pairs, vectors, and booleans" {
    var ast = try parse(std.testing.allocator, "'foo (a . b) #(1 2) #t #f [3 4]");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    try std.testing.expectEqual(@as(usize, 6), root_items.len);

    const quote_node = ast.nodes.items[root_items[0]];
    try std.testing.expectEqual(Node.Tag.quote, quote_node.tag);
    const quoted_symbol = ast.nodes.items[quote_node.data.quote];
    try std.testing.expectEqualStrings("foo", quoted_symbol.data.symbol);

    const dotted_node = ast.nodes.items[root_items[1]];
    try std.testing.expectEqual(Node.Tag.dotted_list, dotted_node.tag);
    const dotted_items = ast.dottedSlice(dotted_node.data.dotted_list);
    try std.testing.expectEqual(@as(usize, 1), dotted_items.len);
    try std.testing.expectEqualStrings("a", ast.nodes.items[dotted_items[0]].data.symbol);
    try std.testing.expectEqualStrings("b", ast.nodes.items[dotted_node.data.dotted_list.tail].data.symbol);

    try std.testing.expectEqual(Node.Tag.vector, ast.nodes.items[root_items[2]].tag);
    try std.testing.expectEqual(Node.Tag.boolean, ast.nodes.items[root_items[3]].tag);
    try std.testing.expectEqual(true, ast.nodes.items[root_items[3]].data.boolean);
    try std.testing.expectEqual(Node.Tag.boolean, ast.nodes.items[root_items[4]].tag);
    try std.testing.expectEqual(false, ast.nodes.items[root_items[4]].data.boolean);
    try std.testing.expectEqual(Node.Tag.vector, ast.nodes.items[root_items[5]].tag);
}

test "parser: empty input" {
    var ast = try parse(std.testing.allocator, "");
    defer ast.deinit();

    const root_node = ast.nodes.items[ast.root];
    try std.testing.expectEqual(Node.Tag.list, root_node.tag);
    const root_items = ast.listSlice(root_node.data.list);
    try std.testing.expectEqual(@as(usize, 0), root_items.len);
}

test "parser: nested lists" {
    var ast = try parse(std.testing.allocator, "((a b) (c d))");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    try std.testing.expectEqual(@as(usize, 1), root_items.len);

    const outer = ast.nodes.items[root_items[0]];
    try std.testing.expectEqual(Node.Tag.list, outer.tag);
    const outer_items = ast.listSlice(outer.data.list);
    try std.testing.expectEqual(@as(usize, 2), outer_items.len);

    const first = ast.nodes.items[outer_items[0]];
    try std.testing.expectEqual(Node.Tag.list, first.tag);
    const first_items = ast.listSlice(first.data.list);
    try std.testing.expectEqual(@as(usize, 2), first_items.len);
    try std.testing.expectEqualStrings("a", ast.nodes.items[first_items[0]].data.symbol);
    try std.testing.expectEqualStrings("b", ast.nodes.items[first_items[1]].data.symbol);

    const second = ast.nodes.items[outer_items[1]];
    const second_items = ast.listSlice(second.data.list);
    try std.testing.expectEqualStrings("c", ast.nodes.items[second_items[0]].data.symbol);
    try std.testing.expectEqualStrings("d", ast.nodes.items[second_items[1]].data.symbol);
}

test "parser: multiple top-level expressions" {
    var ast = try parse(std.testing.allocator, "1 2 3");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    try std.testing.expectEqual(@as(usize, 3), root_items.len);
    try std.testing.expectEqualStrings("1", ast.nodes.items[root_items[0]].data.number);
    try std.testing.expectEqualStrings("2", ast.nodes.items[root_items[1]].data.number);
    try std.testing.expectEqualStrings("3", ast.nodes.items[root_items[2]].data.number);
}

test "parser: string literal" {
    var ast = try parse(std.testing.allocator, "\"hello world\"");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    try std.testing.expectEqual(@as(usize, 1), root_items.len);
    try std.testing.expectEqual(Node.Tag.string, ast.nodes.items[root_items[0]].tag);
    try std.testing.expectEqualStrings("\"hello world\"", ast.nodes.items[root_items[0]].data.string);
}

test "parser: nested quote" {
    var ast = try parse(std.testing.allocator, "''x");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    try std.testing.expectEqual(@as(usize, 1), root_items.len);

    const outer_quote = ast.nodes.items[root_items[0]];
    try std.testing.expectEqual(Node.Tag.quote, outer_quote.tag);

    const inner_quote = ast.nodes.items[outer_quote.data.quote];
    try std.testing.expectEqual(Node.Tag.quote, inner_quote.tag);

    const sym = ast.nodes.items[inner_quote.data.quote];
    try std.testing.expectEqualStrings("x", sym.data.symbol);
}

test "parser: quote list" {
    var ast = try parse(std.testing.allocator, "'(1 2)");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    const quote_node = ast.nodes.items[root_items[0]];
    try std.testing.expectEqual(Node.Tag.quote, quote_node.tag);

    const inner = ast.nodes.items[quote_node.data.quote];
    try std.testing.expectEqual(Node.Tag.list, inner.tag);
    const items = ast.listSlice(inner.data.list);
    try std.testing.expectEqual(@as(usize, 2), items.len);
}

test "parser: hash vector #(...)" {
    var ast = try parse(std.testing.allocator, "#(a b c)");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    try std.testing.expectEqual(@as(usize, 1), root_items.len);

    const vec = ast.nodes.items[root_items[0]];
    try std.testing.expectEqual(Node.Tag.vector, vec.tag);
    const vec_items = ast.listSlice(vec.data.vector);
    try std.testing.expectEqual(@as(usize, 3), vec_items.len);
    try std.testing.expectEqualStrings("a", ast.nodes.items[vec_items[0]].data.symbol);
}

test "parser: bracket vector" {
    var ast = try parse(std.testing.allocator, "[a b c]");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    const vec = ast.nodes.items[root_items[0]];
    try std.testing.expectEqual(Node.Tag.vector, vec.tag);
    const vec_items = ast.listSlice(vec.data.vector);
    try std.testing.expectEqual(@as(usize, 3), vec_items.len);
}

test "parser: empty list" {
    var ast = try parse(std.testing.allocator, "()");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    try std.testing.expectEqual(@as(usize, 1), root_items.len);

    const empty = ast.nodes.items[root_items[0]];
    try std.testing.expectEqual(Node.Tag.list, empty.tag);
    const items = ast.listSlice(empty.data.list);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "parser: comments are skipped" {
    var ast = try parse(std.testing.allocator, "; this is a comment\n42");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    try std.testing.expectEqual(@as(usize, 1), root_items.len);
    try std.testing.expectEqualStrings("42", ast.nodes.items[root_items[0]].data.number);
}

test "parser: negative number" {
    var ast = try parse(std.testing.allocator, "-42");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    try std.testing.expectEqual(@as(usize, 1), root_items.len);
    try std.testing.expectEqual(Node.Tag.number, ast.nodes.items[root_items[0]].tag);
    try std.testing.expectEqualStrings("-42", ast.nodes.items[root_items[0]].data.number);
}

test "parser: dotted list with multiple head elements" {
    var ast = try parse(std.testing.allocator, "(a b c . d)");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    const dotted = ast.nodes.items[root_items[0]];
    try std.testing.expectEqual(Node.Tag.dotted_list, dotted.tag);
    const head = ast.dottedSlice(dotted.data.dotted_list);
    try std.testing.expectEqual(@as(usize, 3), head.len);
    try std.testing.expectEqualStrings("a", ast.nodes.items[head[0]].data.symbol);
    try std.testing.expectEqualStrings("b", ast.nodes.items[head[1]].data.symbol);
    try std.testing.expectEqualStrings("c", ast.nodes.items[head[2]].data.symbol);
    try std.testing.expectEqualStrings("d", ast.nodes.items[dotted.data.dotted_list.tail].data.symbol);
}

test "parser: error on unmatched paren" {
    try std.testing.expectError(error.UnexpectedEof, parse(std.testing.allocator, "(a b"));
}

test "parser: error on unexpected close paren" {
    try std.testing.expectError(error.UnexpectedToken, parse(std.testing.allocator, ")"));
}

test "parser: error on dot in vector" {
    try std.testing.expectError(error.InvalidDot, parse(std.testing.allocator, "[a . b]"));
}

test "parser: error on leading dot" {
    try std.testing.expectError(error.InvalidDot, parse(std.testing.allocator, "(. a)"));
}

test "parser: error on multiple dots" {
    try std.testing.expectError(error.InvalidDot, parse(std.testing.allocator, "(a . b . c)"));
}

test "parser: deeply nested structure" {
    var ast = try parse(std.testing.allocator, "(((x)))");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    const l1 = ast.nodes.items[root_items[0]];
    const l2 = ast.nodes.items[ast.listSlice(l1.data.list)[0]];
    const l3 = ast.nodes.items[ast.listSlice(l2.data.list)[0]];
    try std.testing.expectEqualStrings("x", ast.nodes.items[ast.listSlice(l3.data.list)[0]].data.symbol);
}

test "parser: lambda expression" {
    var ast = try parse(std.testing.allocator, "(lambda (x y) (+ x y))");
    defer ast.deinit();

    const root_items = ast.listSlice(ast.nodes.items[ast.root].data.list);
    const lambda = ast.nodes.items[root_items[0]];
    const items = ast.listSlice(lambda.data.list);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("lambda", ast.nodes.items[items[0]].data.symbol);

    const params = ast.nodes.items[items[1]];
    try std.testing.expectEqual(Node.Tag.list, params.tag);
    const param_items = ast.listSlice(params.data.list);
    try std.testing.expectEqual(@as(usize, 2), param_items.len);

    const body = ast.nodes.items[items[2]];
    try std.testing.expectEqual(Node.Tag.list, body.tag);
    const body_items = ast.listSlice(body.data.list);
    try std.testing.expectEqualStrings("+", ast.nodes.items[body_items[0]].data.symbol);
}
