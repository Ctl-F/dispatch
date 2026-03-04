const std = @import("std");

const Binding = struct {
    definition: type,
    callable: []const u8,
    errorHandler: ?[]const u8,

    pub fn withCatch(this: @This(), comptime catchHandler: []const u8) @This() {
        return .{
            .definition = this.definition,
            .callable = this.callable,
            .errorHandler = catchHandler,
        };
    }
};

pub fn case(branchValue: anytype, prong: anytype) CasePool(@TypeOf(branchValue), anyopaque, anyerror).Case {
    return caseWithContext(anyopaque, branchValue, prong);
}

pub fn caseWithContext(comptime ContextType: type, branchValue: anytype, prong: anytype) CasePool(@TypeOf(branchValue), ContextType, anyerror).Case {
    const ExpectedProngType = CasePool(@TypeOf(branchValue), ContextType, anyerror).Prong;
    const ProngType = @TypeOf(prong);

    if (ProngType == ExpectedProngType) {
        return .{ .value = branchValue, .prong = prong };
    }

    if (ProngType == ExpectedProngType.CallableType) {
        return .{ .value = branchValue, .prong = .{ .callable = prong } };
    }

    if (ProngType == Binding) {
        return .{ .value = branchValue, .prong = .{ .callable = null, .binding = prong } };
    }

    return .{ .value = branchValue, .prong = .{ .callable = prong } };

    //@compileError("Expected type: " ++ @typeName(ExpectedProngType) ++ " or " ++ @typeName(ExpectedProngType.CallableType) ++ " got " ++ @typeName(ProngType));
}

pub fn binding(comptime callName: []const u8, comptime callable: type) Binding {
    return Binding{
        .definition = callable,
        .callable = callName,
        .errorHandler = null,
    };
}

pub fn CasePool(comptime BranchType: type, comptime ContextType: type, comptime ErrorType: type) type {
    return struct {
        const __CasePool__ = @This();

        const BranchTy = BranchType;
        const ErrorTy = ErrorType;
        const ContextTy = ContextType;

        pub const Prong = struct {
            const CallableType = fn (ctx: *ContextType, v: BranchType) ErrorType!void;
            const ErrorHandlerType = fn (ctx: *ContextType, v: BranchType, e: ErrorType) ErrorType!void;

            callable: ?CallableType,
            binding: ?Binding = null,

            inline fn dispatch(this: @This(), ctx: *ContextType, v: BranchType) ErrorType!void {
                if (this.callable) |callable| {
                    try callable(ctx, v);
                    return;
                }
                if (this.binding) |binder| {
                    @call(.auto, @field(binder.definition, binder.callable), .{ ctx, v }) catch |e| {
                        if (binder.errorHandler) |onError| {
                            try @call(.auto, @field(binder.definition, onError), .{ ctx, v, e });
                        } else {
                            return e;
                        }
                    };
                    return;
                }
                unreachable;
            }

            fn toRuntimeProng(this: @This()) RuntimeProng {
                if (this.callable) |_callable| {
                    return .{
                        .callable = &_callable,
                        .catcher = null,
                    };
                }
                if (this.binding) |_binder| {
                    if (_binder.errorHandler) |onError| {
                        return .{
                            .callable = &@field(_binder.definition, _binder.callable),
                            .catcher = &@field(_binder.definition, onError),
                        };
                    }

                    return .{
                        .callable = &@field(_binder.definition, _binder.callable),
                        .catcher = null,
                    };
                }
                unreachable;
            }

            const RuntimeProng = struct {
                callable: *const fn (ctx: *ContextType, v: BranchType) ErrorType!void,
                catcher: ?*const fn (ctx: *ContextType, v: BranchType, e: ErrorType) ErrorType!void,

                inline fn dispatch(this: @This(), ctx: *ContextTy, v: BranchType) ErrorType!void {
                    this.callable(ctx, v) catch |e| {
                        if (this.catcher) |catcher| {
                            try catcher(ctx, v, e);
                        } else {
                            return e;
                        }
                    };
                }
            };
        };
        pub const Case = struct {
            value: BranchType,
            prong: __CasePool__.Prong,
        };

        cases: []const Case,
    };
}

pub fn build(comptime BranchType: type, comptime casePool: CasePool(BranchType, anyopaque, anyerror)) type {
    return buildImpl(CasePool(BranchType, anyopaque, anyerror), casePool);
}

pub fn buildWithContextType(comptime BranchType: type, comptime ContextType: type, comptime casePool: CasePool(BranchType, ContextType, anyerror)) type {
    return buildImpl(CasePool(BranchType, ContextType, anyerror), casePool);
}

pub fn buildWithErrorType(comptime BranchType: type, comptime ContextType: type, comptime ErrorType: type, comptime casePool: CasePool(BranchType, ContextType, ErrorType)) type {
    return buildImpl(CasePool(BranchType, ContextType, ErrorType), casePool);
}

fn buildImpl(comptime CasePoolType: type, comptime casePool: CasePoolType) type {
    const ThresholdForIfChain = 5;

    if (casePool.cases.len < ThresholdForIfChain) {
        return IfChain(CasePoolType, casePool);
    }

    return NativeSwitch(CasePoolType, casePool);

    //@compileError("Unable to build a dispatch table from provided case pool");
}

pub const StreamedDispatchError = error{NoMatch};

fn IfChain(comptime CasePoolType: type, comptime casePool: CasePoolType) type {
    return struct {
        pub fn do(ctx: *CasePoolType.ContextTy, value: CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            inline for (casePool.cases) |caseValue| {
                if (std.meta.eql(caseValue.value, value)) {
                    try caseValue.prong.dispatch(ctx, value);
                    return;
                }
            }
            return StreamedDispatchError.NoMatch;
        }

        pub fn doAll(ctx: *CasePoolType.ContextTy, values: []const CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            for (values) |value| {
                try @This().do(ctx, value);
            }
        }
    };
}

fn JumpTable(comptime CasePoolType: type, comptime casePool: CasePoolType) type {
    return struct {
        const Stats = struct {
            minCase: CasePoolType.BranchTy,
            maxCase: CasePoolType.BranchTy,
            range: usize,
            numCases: usize,
        };

        fn getStats() Stats {
            var stats = Stats{
                .minCase = std.math.maxInt(CasePoolType.BranchTy),
                .maxCase = std.math.minInt(CasePoolType.BranchTy),
                .range = 0,
                .numCases = 0,
            };

            inline for (casePool.cases) |_case| {
                if (_case.value < stats.minCase) {
                    stats.minCase = _case.value;
                }
                if (_case.value > stats.maxCase) {
                    stats.maxCase = _case.value;
                }

                stats.numCases += 1;
            }

            stats.range = @as(usize, @intCast(stats.maxCase - stats.minCase)) + 1;

            return stats;
        }

        fn JumpTableType() type {
            if (TypeStats.numCases == (TypeStats.maxCase - TypeStats.minCase)) {
                return CasePoolType.Prong.RuntimeProng;
            }
            return ?CasePoolType.Prong.RuntimeProng;
        }

        fn JumpTableDefault() JumpTableType() {
            if (TypeStats.numCases == (TypeStats.maxCase - TypeStats.minCase)) {
                return JumpTableType(){
                    .callable = &@field(struct {
                        fn a(ctx: *CasePoolType.ContextTy, v: CasePoolType.BranchTy) CasePoolType.ErrorTy!void {
                            _ = ctx;
                            _ = v;
                            // unreachable since this function is a placeholder, and should only be used
                            // when all cases are filled in the jumptable. Therefore if this is still
                            // around it signifies a bug in jumptable type logic.
                            unreachable;
                        }
                    }, "a"),
                    .catcher = null,
                };
            }
            return null;
        }

        const TypeStats = getStats();
        const JumpTableDef = RET: {
            if (TypeStats.numCases == 0) {
                @compileError("JumpTable requires at least one case");
            }

            var table = [_]JumpTableType(){JumpTableDefault()} ** TypeStats.range;

            for (casePool.cases) |_case| {
                const idx = @as(usize, @intCast(_case.value - TypeStats.minCase));

                // if (table[idx] != JumpTableDefault()) {
                if (!std.meta.eql(table[idx], JumpTableDefault())) {
                    @compileError("Duplicate case value detected");
                }

                table[idx] = _case.prong.toRuntimeProng();
            }

            break :RET table;
        };

        pub fn do(ctx: *CasePoolType.ContextTy, value: CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            if (value < TypeStats.minCase or value > TypeStats.maxCase) {
                return StreamedDispatchError.NoMatch;
            }

            const index: usize = @intCast(value - TypeStats.minCase);

            if (comptime @typeInfo(JumpTableType()) == .Optional) {
                if (JumpTableDef[index]) |prong| {
                    try prong.dispatch(ctx, value);
                } else {
                    return StreamedDispatchError.NoMatch;
                }
            } else {
                JumpTableDef[index].dispatch(ctx, value);
            }
        }

        pub fn doAll(ctx: *CasePoolType.ContextTy, values: []const CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            for (values) |value| {
                try @This().do(ctx, value);
            }
        }
    };
}

fn NativeSwitch(comptime CasePoolType: type, comptime casePool: CasePoolType) type {
    return struct {
        pub fn do(ctx: *CasePoolType.ContextTy, value: CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            const info = @typeInfo(CasePoolType.BranchTy);

            const fields, const enumTy, const isUnion = switch (info) {
                .@"enum" => |enu| .{ enu.fields, enu, false },
                .@"union" => |unu| UNU: {
                    if (unu.tag_type == null) {
                        @compileError("Union must be tagged in order to be used in a NativeSwitch dispatch.");
                    }

                    const tagType = @typeInfo(unu.tag_type.?).@"enum";

                    break :UNU .{ tagType.fields, tagType, true };
                },
                else => @compileError("NativeSwitch is only allowed on enums or tagged unions."),
            };

            _ = enumTy; // remove it really not needed

            if (casePool.cases.len != fields.len) {
                @compileError("Not every enum case has a handler.");
            }

            if (comptime isUnion) {
                switch (value) {
                    inline else => |payload, tag| {
                        inline for (casePool.cases) |_case| {
                            if (comptime tag == _case.value) {
                                try _case.prong.dispatch(ctx, payload);
                            }
                        }
                    },
                }
            } else {
                switch (value) {
                    inline else => |val| {
                        inline for (casePool.cases) |_case| {
                            if (comptime val == _case.value) {
                                try _case.prong.dispatch(ctx, val);
                            }
                        }
                    },
                }
            }
        }

        pub fn doAll(ctx: *CasePoolType.ContextTy, values: []const CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            for (values) |value| {
                try @This().do(ctx, value);
            }
        }
    };
}

// Main API:
//
// const std = @import("std");
// const dispatch = @import("dispatch");

// const binding = dispatch.binding;
// const case = dispatch.case;

// inline fn case10() !void {
//    std.debug.print("case 10!\n", .{});
// }

// inline fn case11() !void {
//    std.debug.print("case 10 + 1!\n", .{});
// }

// inline fn case12() !void {
//    std.debug.print("case 12 is nice!\n", .{});
// }

// fn main() !void {
//   const cases = .{
//      case(10, case10),
//      case(11, case11),
//      case(12, case12),
//      case(13, binding("a", struct{
//          pub inline fn a(v: i32) !void {
//              std.debug.print("this one is from an inline-struct: {}\n", .{ v });
//          }
//
//          pub inline fn handleError(v: i32, e: anyerror) !void {
//              std.debug.print("error: {} occurred for: {}\n", .{ e, v });
//              return e;
//          }
//      }).withCatch("handleError")),
//   };

//   const myBranch = dispatch.build(cases);
//   const myValue: i32 = 10;

//   try myBranch.doAll(&.{ myValue, 11, 13 });
// }
//
//
