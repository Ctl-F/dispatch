const std = @import("std");
const dispatch = @import("dispatch");

const TokenType = enum {
    none,
    whitesp,
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    sqr,
    openParen,
    closeParen,
    number,
};

const Token = union(TokenType) {
    none: void,
    whitesp: void,
    add: void,
    sub: void,
    mul: void,
    div: void,
    mod: void,
    pow: void,
    sqr: void,
    openParen: void,
    closeParen: void,
    number: f32,
};

const TokenContext = struct {
    literal: []const u8,
    tokens: std.ArrayList(Token),
    allocator: std.mem.Allocator,
    accumBuffer: [1028]u8 = [_]u8{0} ** 1028,
    accum: []u8 = &.{},
    currentTokenType: TokenType,

    fn pushAccum(this: *@This(), a: u8) !void {
        if (this.accum.len >= this.accumBuffer.len) {
            return error.TokenIsTooLong;
        }

        this.accumBuffer[this.accum.len] = a;
        this.accum = this.accumBuffer[0 .. this.accum.len + 1];
    }

    fn clearAccum(this: *@This()) void {
        this.accum = &.{};
    }

    fn reduceInput(this: *@This()) !void {
        if (this.literal.len == 0) return error.EmptyInput;

        this.literal = this.literal[1..];
    }
};

fn matchWhitespace(ctx: *TokenContext, d: u8) !void {
    if (ctx.currentTokenType != .none) {
        const token = switch (ctx.currentTokenType) {
            .number => RES: {
                std.debug.assert(ctx.accum.len > 0);

                const value: f32 = try std.fmt.parseFloat(f32, ctx.accum);
                break :RES Token{ .number = value };
            },
            else => @unionInit(Token, @tagName(ctx.currentTokenType), .{}),
        };

        try ctx.tokens.append(ctx.allocator, token);
    }
    ctx.clearAccum();
    ctx.currentTokenType = .whitesp;
    try ctx.pushAccum(d);
    ctx.reduceInput() catch {
        // TODO: finish
    };
}

fn matchNumber(ctx: *TokenContext, d: u8) !void {}

fn matchOperator(ctx: *TokenContext, d: u8) !void {}

const Context = struct {
    accum: f32,
};

const Operation = union(enum) {
    ld: f32,
    disp: void,
    add: f32,
    sub: f32,
    div: f32,
    mul: f32,
    mod: f32,
    sqrt: void,
    pow: f32,

    pub fn on_ld(ctx: *Context, val: f32) !void {
        std.debug.print("{} ", .{val});
        ctx.accum = val;
    }

    pub fn on_disp(ctx: *Context, _: void) !void {
        std.debug.print("= {}\n", .{ctx.accum});
    }

    pub fn on_add(ctx: *Context, add: f32) !void {
        std.debug.print("+ {} ", .{add});

        ctx.accum += add;
    }

    pub fn on_sub(ctx: *Context, val: f32) !void {
        std.debug.print("- {} ", .{val});
        ctx.accum -= val;
    }

    pub fn on_div(ctx: *Context, val: f32) !void {
        if (val == 0.0) {
            return error.DivideOnZero;
        }

        std.debug.print("/ {} ", .{val});

        ctx.accum /= val;
    }

    pub fn on_divCatch(ctx: *Context, val: f32, err: anyerror) !void {
        if (err != error.DivideByZero) return err;

        std.debug.print("Cannot divide by zero!\n", .{});
        _ = ctx;
        _ = val;
    }

    pub fn on_mul(ctx: *Context, val: f32) !void {
        std.debug.print("* {} ", .{val});
        ctx.accum *= val;
    }

    pub fn on_mod(ctx: *Context, val: f32) !void {
        if (val == 0.0) {
            return error.DivideOnZero;
        }

        std.debug.print("% {} ", .{val});

        ctx.accum = std.math.mod(f32, ctx.accum, val) catch unreachable;
    }
    pub fn on_modCatch(ctx: *Context, val: f32, err: anyerror) !void {
        if (err != error.DivideByZero) return err;

        std.debug.print("Cannot divide by zero!\n", .{});
        _ = ctx;
        _ = val;
    }

    pub fn on_sqrt(ctx: *Context, _: void) !void {
        std.debug.print("_/ sqrt({}) ", .{ctx.accum});

        ctx.accum = @sqrt(ctx.accum);
    }

    pub fn on_pow(ctx: *Context, val: f32) !void {
        std.debug.print("** {} ", .{val});

        ctx.accum = std.math.pow(f32, ctx.accum, val);
    }
};

pub fn main() !void {
    const table = dispatch.buildWithContextType(Operation, Context, .{ .cases = dispatch.unwrapCasesWithContext(Context, Operation, "on_") }, .{});

    const operations = [_]Operation{
        .{ .ld = 7 },
        .{ .mul = 6 },
        .sqr,
        .{ .add = 10 },
        .sqrt,
        .{ .mod = 3 },
        .disp,
    };

    var context: Context = .{ .accum = 0.0 };

    try table.doAll(&context, &operations);
}
