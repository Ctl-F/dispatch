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

pub fn case(branchValue: anytype, prong: anytype) CasePool(@TypeOf(branchValue), anyerror).Case {
    const ExpectedProngType = CasePool(@TypeOf(branchValue), anyerror).Prong;
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

    @compileError("Expected type: " ++ @typeName(ExpectedProngType) ++ " or " ++ @typeName(ExpectedProngType.CallableType) ++ " got " ++ @typeName(ProngType));
}

pub fn binding(comptime callName: []const u8, comptime callable: type) Binding {
    return Binding{
        .definition = callable,
        .callable = callName,
        .errorHandler = null,
    };
}

pub fn CasePool(comptime BranchType: type, comptime ErrorType: type) type {
    return struct {
        const __CasePool__ = @This();

        const ConditionType = BranchType;
        const ExceptionType = ErrorType;

        pub const Prong = struct {
            const CallableType = fn (v: BranchType) ErrorType!void;
            const ErrorHandlerType = fn (v: BranchType, e: ErrorType) ErrorType!void;

            callable: ?CallableType,
            binding: ?Binding = null,
            //onError: ?ErrorHandlerType = null,

            inline fn dispatch(this: @This(), v: BranchType) ErrorType!void {
                if (this.callable) |callable| {
                    try callable(v);
                    return;
                }
                if (this.binding) |binder| {
                    @call(.auto, @field(binder.definition, binder.callable), .{v}) catch |e| {
                        if (binder.errorHandler) |onError| {
                            try @call(.auto, @field(binder.definition, onError), .{ v, e });
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
                callable: *const fn (v: BranchType) ErrorType!void,
                catcher: ?*const fn (v: BranchType, e: ErrorType) ErrorType!void,

                inline fn dispatch(this: @This(), v: BranchType) ErrorType!void {
                    this.callable(v) catch |e| {
                        if (this.catcher) |catcher| {
                            try catcher(v, e);
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

pub fn build(comptime BranchType: type, comptime casePool: CasePool(BranchType, anyerror)) type {
    return buildImpl(CasePool(BranchType, anyerror), casePool);
}

pub fn buildWithErrorType(comptime BranchType: type, comptime ErrorType: type, comptime casePool: CasePool(BranchType, ErrorType)) type {
    return buildImpl(CasePool(BranchType, ErrorType), casePool);
}

fn buildImpl(comptime CasePoolType: type, comptime casePool: CasePoolType) type {
    const ThresholdForIfChain = 5;

    if (casePool.cases.len < ThresholdForIfChain) {
        return IfChain(CasePoolType, casePool);
    }

    return JumpTable(CasePoolType, casePool);

    //@compileError("Unable to build a dispatch table from provided case pool");
}

pub const StreamedDispatchError = error{NoMatch};

fn IfChain(comptime CasePoolType: type, comptime casePool: CasePoolType) type {
    return struct {
        pub fn do(value: CasePoolType.ConditionType) (CasePoolType.ExceptionType || StreamedDispatchError)!void {
            inline for (casePool.cases) |caseValue| {
                if (caseValue.value == value) {
                    try caseValue.prong.dispatch(value);
                    return;
                }
            }
            return StreamedDispatchError.NoMatch;
        }

        pub fn doAll(values: []const CasePoolType.ConditionType) (CasePoolType.ExceptionType || StreamedDispatchError)!void {
            for (values) |value| {
                try @This().do(value);
            }
        }
    };
}

fn JumpTable(comptime CasePoolType: type, comptime casePool: CasePoolType) type {
    return struct {
        const Stats = struct {
            minCase: CasePoolType.ConditionType,
            maxCase: CasePoolType.ConditionType,
            range: usize,
            numCases: usize,
        };

        fn getStats() Stats {
            var stats = Stats{
                .minCase = std.math.maxInt(CasePoolType.ConditionType),
                .maxCase = std.math.minInt(CasePoolType.ConditionType),
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

        const TypeStats = getStats();
        const JumpTableDef = RET: {
            if (TypeStats.numCases == 0) {
                @compileError("JumpTable requires at least one case");
            }

            var table = [_]?CasePoolType.Prong.RuntimeProng{null} ** TypeStats.range;

            for (casePool.cases) |_case| {
                const idx = @as(usize, @intCast(_case.value - TypeStats.minCase));

                if (table[idx] != null) {
                    @compileError("Duplicate case value detected");
                }

                table[idx] = _case.prong.toRuntimeProng();
                // if (_case.prong.callable) |callable| {
                //     table[idx] = &callable;
                // } else if (_case.prong.binding) |binder| {
                //     table[idx] = &@field(binder.definition, binder.callable);
                // } else @compileError("prong has no valid execution path");
            }

            break :RET table;
        };

        pub fn do(value: CasePoolType.ConditionType) (CasePoolType.ExceptionType || StreamedDispatchError)!void {
            if (value < TypeStats.minCase or value > TypeStats.maxCase) {
                return StreamedDispatchError.NoMatch;
            }

            const index: usize = @intCast(value - TypeStats.minCase);

            if (JumpTableDef[index]) |prong| {
                try prong.dispatch(value);
            } else {
                return StreamedDispatchError.NoMatch;
            }
        }

        pub fn doAll(values: []const CasePoolType.ConditionType) (CasePoolType.ExceptionType || StreamedDispatchError)!void {
            for (values) |value| {
                try @This().do(value);
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
