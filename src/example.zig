const std = @import("std");
const dispatch = @import("dispatch");

const case = dispatch.case;
const binding = dispatch.binding;

fn onTen(ctx: *anyopaque, v: i32) anyerror!void {
    _ = ctx;
    std.debug.assert(v == 10);
    std.debug.print("Value is 10 indeed\n", .{});
}

pub fn main() !void {
    const decision = dispatch.build(i32, .{
        .cases = &.{
            case(@as(i32, 10), onTen),
            case(@as(i32, 11), binding("a", struct {
                pub fn a(ctx: *anyopaque, v: i32) anyerror!void {
                    _ = v;
                    _ = ctx;
                    return error.ErrorExample;
                }
                pub fn err(ctx: *anyopaque, v: i32, e: anyerror) anyerror!void {
                    _ = ctx;
                    std.debug.print("Error handler called [v/e]: {}/{}\n", .{ v, e });
                }
            }).withCatch("err")),
            case(@as(i32, -1), binding("b", struct {
                pub fn b(ctx: *anyopaque, v: i32) anyerror!void {
                    _ = ctx;
                    std.debug.print("value is: {}\n", .{v});
                }
            })),
            case(@as(i32, -2), binding("b", struct {
                pub fn b(ctx: *anyopaque, v: i32) anyerror!void {
                    _ = ctx;
                    std.debug.print("value is: {}\n", .{v});
                }
            })),
            case(@as(i32, -10), binding("b", struct {
                pub fn b(ctx: *anyopaque, v: i32) anyerror!void {
                    _ = ctx;
                    std.debug.print("value is: {}\n", .{v});
                }
            })),
            case(@as(i32, -5), binding("b", struct {
                pub fn b(ctx: *anyopaque, v: i32) anyerror!void {
                    _ = ctx;
                    std.debug.print("value is: {}\n", .{v});
                }
            })),
            case(@as(i32, 5), binding("b", struct {
                pub fn b(ctx: *anyopaque, v: i32) anyerror!void {
                    _ = ctx;
                    std.debug.print("value is: {}\n", .{v});
                }
            })),
        },
    });

    try decision.do(&.{}, -10);
    try decision.do(&.{}, 10);
    try decision.do(&.{}, 11);
}
