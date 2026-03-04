const std = @import("std");
const dispatch = @import("dispatch");

const case = dispatch.case;
const binding = dispatch.binding;

// fn onTen(ctx: *anyopaque, v: i32) anyerror!void {
//     _ = ctx;
//     std.debug.assert(v == 10);
//     std.debug.print("Value is 10 indeed\n", .{});
// }

const CasesTag = enum {
    first,
    second,
    third,
};

const Cases = union(CasesTag) {
    first: First,
    second: bool,
    third: i32,

    const First = struct {
        string: []const u8,
        add: f32,
    };

    fn onFirst(ctx: *anyopaque, f: Cases) anyerror!void {
        _ = ctx;
        std.debug.print("This is a string {s} and a float {}\n", .{ f.first.string, f.first.add });
    }

    fn onSecond(ctx: *anyopaque, s: Cases) anyerror!void {
        _ = ctx;
        std.debug.print("{}\n", .{s.second});
    }

    fn onThird(ctx: *anyopaque, t: Cases) anyerror!void {
        _ = ctx;
        std.debug.print("{}+2 = {}\n", .{ t.third, t.third + 2 });
    }
};

pub fn main() !void {
    const decision = dispatch.build(Cases, .{
        .cases = &.{
            case(Cases.first, Cases.onFirst),
            case(Cases.second, Cases.onSecond),
            case(Cases.third, Cases.onThird),
        },
    });

    try decision.do(&.{}, Cases{ .first = .{ .string = "Hello ", .add = 42.0 } });
    try decision.do(&.{}, Cases{ .second = true });
    try decision.do(&.{}, Cases{ .third = 10 });

    // const decision = dispatch.build(i32, .{
    //     .cases = &.{
    //         case(@as(i32, 10), onTen),
    //         case(@as(i32, 11), binding("a", struct {
    //             pub fn a(ctx: *anyopaque, v: i32) anyerror!void {
    //                 _ = v;
    //                 _ = ctx;
    //                 return error.ErrorExample;
    //             }
    //             pub fn err(ctx: *anyopaque, v: i32, e: anyerror) anyerror!void {
    //                 _ = ctx;
    //                 std.debug.print("Error handler called [v/e]: {}/{}\n", .{ v, e });
    //             }
    //         }).withCatch("err")),
    //         case(@as(i32, -1), binding("b", struct {
    //             pub fn b(ctx: *anyopaque, v: i32) anyerror!void {
    //                 _ = ctx;
    //                 std.debug.print("value is: {}\n", .{v});
    //             }
    //         })),
    //         case(@as(i32, -2), binding("b", struct {
    //             pub fn b(ctx: *anyopaque, v: i32) anyerror!void {
    //                 _ = ctx;
    //                 std.debug.print("value is: {}\n", .{v});
    //             }
    //         })),
    //         case(@as(i32, -10), binding("b", struct {
    //             pub fn b(ctx: *anyopaque, v: i32) anyerror!void {
    //                 _ = ctx;
    //                 std.debug.print("value is: {}\n", .{v});
    //             }
    //         })),
    //         case(@as(i32, -5), binding("b", struct {
    //             pub fn b(ctx: *anyopaque, v: i32) anyerror!void {
    //                 _ = ctx;
    //                 std.debug.print("value is: {}\n", .{v});
    //             }
    //         })),
    //         case(@as(i32, 5), binding("b", struct {
    //             pub fn b(ctx: *anyopaque, v: i32) anyerror!void {
    //                 _ = ctx;
    //                 std.debug.print("value is: {}\n", .{v});
    //             }
    //         })),
    //     },
    // });

    // try decision.do(&.{}, -10);
    // try decision.do(&.{}, 10);
    // try decision.do(&.{}, 11);
}
