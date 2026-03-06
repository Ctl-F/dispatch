const std = @import("std");
const util = @import("util");

pub const CasePoolConfig = struct {
    method: enum { auto, ifChain, nativeSwitch, jumpTable } = .auto,
};

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

/// unwrap the cases inside of a tagged-union. This is useful for bulk declaring cases in a tagged union.
/// The method will go through each enum value in the tag and create a binding for a function with that name
/// and a provided prefix.
/// Example:
/// const Operations = union(enum){
///    print: i32,
///    add: Pair,
///    mul: Pair,
///
///    const Pair = struct{ a: i32, b: i32 };
///
///    pub fn do_print(ctx: *anyopaque, val: i32) anyerror!void {
///        _ = ctx;
///        std.debug.print("Value is: {}\n", .{ val });
///    }
///
///    pub fn do_add(ctx: *anyopaque, val: Pair) anyerror!void {
///        _ = ctx;
///        std.debug.print("{} + {} = {}\n", .{ val.a, val.b, val.a + val.b });
///    }
///
///    pub fn do_mul(ctx: *anyopaque, val: Pair) anyerror!void {
///       _ = ctx;
///       std.debug.print("{} * {} = {}\n", .{ val.a, val.b, val.a * val.b });
///    }
///
/// };
/// (...)
/// fn main() !void {
///     const dispatch = dispatch.build(Operations, .{ .cases = dispatch.unwrapCases(Operations, "on_") }, .{});
///
///     try dispatch.do(&.{}, Pair{ .add = .{ .a = 2, .b = 3 } });
///
/// }
///
///
pub fn unwrapCases(bindee: type, comptime prefix: []const u8) []const CasePool(bindee, anyopaque, anyerror).Case {
    const CasePoolType = CasePool(bindee, anyopaque, anyerror);
    const info = @typeInfo(bindee);

    if (info != .@"union") {
        @compileError("unwrapCases case only be used with a tagged union.");
    }

    const unionInfo = info.@"union";

    if (unionInfo.tag_type == null) {
        @compileError("unwrapCases expects a tagged union.");
    }

    const tags = unionInfo.tag_type.?;
    const tagsInfo = @typeInfo(tags).@"enum";

    comptime var cases: [tagsInfo.fields.len]CasePoolType.Case = undefined;

    inline for (tagsInfo.fields, 0..) |field, idx| {
        const _binding = binding(prefix ++ field.name, bindee);
        const instance = @unionInit(bindee, field.name, util.default(@FieldType(bindee, field.name)));
        cases[idx] = CasePoolType.Case{ .value = instance, .prong = .{ .binding = _binding, .callable = null } };
    }

    const casesConcrete = cases;

    return &casesConcrete;
}

/// Manually define a case in a set. branchValue is the value that we are matching against and the prong
/// is a function or binding to execute when the dispatched value is equal to the branch value.
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

/// Creates a binding for a function call inside of a type (struct/enum/union/etc)
/// This is the correct way to call such functions and is the main way that we can allow
/// duck-typing of tagged-union variant handlers. Bindings are more useful than raw functions
/// since they can provide error-handler overrides using .withCatch.
/// TODO: implement makeBinding function to wrap raw functions into a binding allowing for catch semantics.
pub fn binding(comptime callName: []const u8, comptime callable: type) Binding {
    return Binding{
        .definition = callable,
        .callable = callName,
        .errorHandler = null,
    };
}

/// This is the main type we define in order to create a dispatch strategy. We define
/// the BranchType (type we match/switch on), the ContextType (user metadata) and the ErrorType (possible error set returned)
/// void can be passed in as the context type or error type if those arent needed, however the default is anyopaque and anyerror
/// for more leinient handling.
pub fn CasePool(comptime BranchType: type, comptime ContextType: type, comptime ErrorType: type) type {
    return struct {
        const __CasePool__ = @This();

        const BranchTy = BranchType;
        const ErrorTy = ErrorType;
        const ContextTy = ContextType;

        fn cmpCase(ctx: *anyopaque, a: Case, b: Case) bool {
            _ = ctx;
            return a.value < b.value;
        }
        fn hasDuplicates(comptime cases: []Case) bool {
            comptime {
                std.sort.block(Case, cases, &.{}, cmpCase);

                for (1..cases.len) |i| {
                    if (std.meta.eql(cases[i], cases[i - 1])) return true;
                }
                return false;
            }
        }

        /// a comptime "execution branch" that can be a comptime-known function or a binding.
        pub const Prong = struct {
            const CallableType = fn (ctx: *ContextType, v: BranchType) ErrorType!void;
            const ErrorHandlerType = fn (ctx: *ContextType, v: BranchType, e: ErrorType) ErrorType!void;

            callable: ?CallableType,
            binding: ?Binding = null,

            inline fn dispatch(this: @This(), ctx: *ContextType, v: anytype) ErrorType!void {
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

            /// a Runtime execution branch needed for JumpTables.
            const RuntimeProng = struct {
                callable: *const fn (ctx: *ContextType, v: BranchType) ErrorType!void,
                catcher: ?*const fn (ctx: *ContextType, v: BranchType, e: ErrorType) ErrorType!void,

                // TODO: see if we need to convert this v to anytype also
                // I think we're ok keeping this as a BranchType because
                // RuntimeProng is only ever used for JumpTables which require the branchtype
                // anyway. Whereas we need anytype in the non-runtime Prong to accomodate tagged-unions
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

        /// A case pairing the branch match value with the execution prong.
        pub const Case = struct {
            value: BranchType,
            prong: __CasePool__.Prong,
        };

        cases: []const Case,
    };
}

/// build a CasePool from a branch type and a set of cases
pub fn build(comptime BranchType: type, comptime casePool: CasePool(BranchType, anyopaque, anyerror), comptime config: CasePoolConfig) type {
    return buildImpl(CasePool(BranchType, anyopaque, anyerror), casePool, config);
}
/// build a CasePool from a branch type and a set of cases
/// also providing a context type
pub fn buildWithContextType(comptime BranchType: type, comptime ContextType: type, comptime casePool: CasePool(BranchType, ContextType, anyerror), comptime config: CasePoolConfig) type {
    return buildImpl(CasePool(BranchType, ContextType, anyerror), casePool, config);
}

/// build a CasePool from a branch type and a set of cases
/// but also providing the context type and the error type
pub fn buildWithErrorType(comptime BranchType: type, comptime ContextType: type, comptime ErrorType: type, comptime casePool: CasePool(BranchType, ContextType, ErrorType), comptime config: CasePoolConfig) type {
    return buildImpl(CasePool(BranchType, ContextType, ErrorType), casePool, config);
}

fn buildImpl(comptime CasePoolType: type, comptime casePool: CasePoolType, comptime config: CasePoolConfig) type {
    // TODO: If an enum set doesn't need optimized-streaming we should fall back to an IfChain so that we aren't generating O(n^2) branches at comptime
    // we will introduce a flag in config so the user can communicate intent
    // IfChain -> O(n) branches, faster compilation times and has the potential for similar opimizations in constrained set cases
    // NativeSwitch -> O(n^2) branches at comptime -> pruned to O(n) runtime branches. Slower comptime, better execution, allows for threaded-dispatch

    switch (config.method) {
        .auto => {},
        .ifChain => return IfChain(CasePoolType, casePool),
        .jumpTable => return JumpTable(CasePoolType, casePool),
        .nativeSwitch => return NativeSwitch(CasePoolType, casePool),
    }
    // auto select logic here:
    // TODO: Improve heuristics to determine which dispatch method to use
    const ThresholdForIfChain = 5;

    if (casePool.cases.len < ThresholdForIfChain) {
        return IfChain(CasePoolType, casePool);
    }

    switch (@typeInfo(CasePoolType.BranchTy)) {
        .@"enum", .@"union" => return NativeSwitch(CasePoolType, casePool),
        .int, .comptime_int => return JumpTable(CasePoolType, casePool), //TODO: add mechanism to coerce ints into enum types and use NativeSwitch for better optimizations
        else => @compileError("Type not supported for dispatch"), // TODO: Hash-based dispatch for strings/structs/floats/etc.
    }
}

pub const StreamedDispatchError = error{NoMatch};

/// IfChain dispatch method. If possible we generate a pattern that zig can optimize (potentially) into a switch statement under the hood
/// if not we do the naive approach. For small sets this will likely be optimal even without the switch optimization
fn IfChain(comptime CasePoolType: type, comptime casePool: CasePoolType) type {
    return struct {
        inline fn isConstrainedSet() bool {
            return switch (@typeInfo(CasePoolType.BranchTy)) {
                .@"union", .@"enum" => true,
                else => false,
            };
        }

        inline fn casesAreContiguous() bool {
            comptime {
                if (isConstrainedSet()) return true;

                if (getCasesMinMax()) |minMax| {
                    if (minMax.max - minMax.min == casePool.cases.len and !CasePoolType.hasDuplicates(casePool.cases)) {
                        return true;
                    }
                    return false;
                }
                return false;
            }
        }

        fn getCasesMinMax() ?struct { min: CasePoolType.BranchTy, max: CasePoolType.BranchTy } {
            comptime {
                if (!util.canMinMax(CasePoolType.BranchTy)) {
                    return null;
                }

                var minMax: struct { min: CasePoolType.BranchTy, max: CasePoolType.BranchTy } = .{
                    .min = util.maxValue(CasePoolType.BranchTy),
                    .max = util.minValue(CasePoolType.BranchTy),
                };

                for (casePool.cases) |_case| {
                    minMax.min = @min(_case.value, minMax.min);
                    minMax.max = @max(_case.value, minMax.max);
                }

                return minMax;
            }
        }

        pub inline fn do(ctx: *CasePoolType.ContextTy, value: CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            if (comptime casesAreContiguous()) {
                // the min/max logic isn't needed for a constrained set (enum/union) since you can't generally provide a value outside of an
                // enum set for comparing.
                if (comptime !isConstrainedSet()) {

                    // if cases are min/max able and contiguous e.g. no holes
                    // then we can adopt this pattern which allows us to insert an unreachable
                    // at the end of the inline for and the optimizer can refactor this into a
                    // switch statement.
                    const minMax = getCasesMinMax().?;

                    if (value < minMax.min or value > minMax.max) {
                        return StreamedDispatchError.NoMatch;
                    }
                }

                inline for (casePool.cases) |caseValue| {
                    if (std.meta.eql(caseValue.value, value)) {
                        try caseValue.prong.dispatch(ctx, value);
                        return;
                    }
                }

                unreachable;
            } else {
                inline for (casePool.cases) |caseValue| {
                    if (std.meta.eql(caseValue.value, value)) {
                        try caseValue.prong.dispatch(ctx, value);
                        return;
                    }
                }
                return StreamedDispatchError.NoMatch;
            }
        }

        pub inline fn doAll(ctx: *CasePoolType.ContextTy, values: []const CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            for (values) |value| {
                try @This().do(ctx, value);
            }
        }

        //  TODO: Allow bindings for selectors
        pub inline fn doStreamed(ctx: *CasePoolType.ContextTy, value: CasePoolType.BranchTy, comptime selector: fn (c: *CasePoolType.ContextTy) ?CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            var val = value;
            while (true) {
                try do(ctx, val);

                if (selector(ctx)) |nextVal| {
                    val = nextVal;
                } else {
                    break;
                }
            }
        }
    };
}

fn JumpTable(comptime CasePoolType: type, comptime casePool: CasePoolType) type {
    const info = @typeInfo(CasePoolType.BranchTy);

    switch (info) {
        .int, .comptime_int => {},
        else => @compileError("Jump Table requires integral branch type"),
    }

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
            if (TypeStats.numCases == (TypeStats.maxCase - TypeStats.minCase + 1)) {
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

        pub inline fn do(ctx: *CasePoolType.ContextTy, value: CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
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

        pub inline fn doAll(ctx: *CasePoolType.ContextTy, values: []const CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            for (values) |value| {
                try @This().do(ctx, value);
            }
        }

        pub inline fn doStreamed(ctx: *CasePoolType.ContextTy, value: CasePoolType.BranchTy, comptime selector: fn (c: *CasePoolType.ContextTy) ?CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            var val: CasePoolType.BranchTy = value;

            while (true) {
                try do(ctx, val);

                if (selector(ctx)) |selected| {
                    val = selected;
                } else {
                    break;
                }
            }
        }
    };
}

fn NativeSwitch(comptime CasePoolType: type, comptime casePool: CasePoolType) type {
    return struct {
        pub inline fn do(ctx: *CasePoolType.ContextTy, value: CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            const fields, const isUnion = validateInfo();

            if (casePool.cases.len != fields.len) {
                @compileError("Not every enum case has a handler.");
            }

            if (comptime isUnion) {
                switch (value) {
                    inline else => |payload, tag| {
                        inline for (casePool.cases) |_case| {
                            if (comptime tag == std.meta.activeTag(_case.value)) {
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

        pub inline fn doAll(ctx: *CasePoolType.ContextTy, values: []const CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            for (values) |value| {
                try @This().do(ctx, value);
            }
        }

        fn validateInfo() struct { fields: []const std.builtin.Type.EnumField, isUnion: bool } {
            const info = @typeInfo(CasePoolType.BranchTy);

            const fields, const isUnion = switch (info) {
                .@"enum" => |enu| .{ enu.fields, false },
                .@"union" => |unu| UNU: {
                    if (unu.tag_type == null) {
                        @compileError("Union must be tagged in order to be used in a NativeSwitch dispatch.");
                    }

                    const tagType = @typeInfo(unu.tag_type.?).@"enum";

                    break :UNU .{ tagType.fields, true };
                },
                else => @compileError("NativeSwitch is only allowed on enums or tagged unions."),
            };

            return .{ .fields = fields, .isUnion = isUnion };
        }

        pub inline fn doStreamed(ctx: *CasePoolType.ContextTy, value: CasePoolType.BranchTy, comptime selector: fn (c: *CasePoolType.ContextTy) ?CasePoolType.BranchTy) (CasePoolType.ErrorTy || StreamedDispatchError)!void {
            const fields, const isUnion = validateInfo();

            if (casePool.cases.len != fields.len) {
                @compileError("Not every enum case has a handler.");
            }

            if (comptime isUnion) {
                SWITCH: switch (value) {
                    inline else => |payload, tag| {
                        inline for (casePool.cases) |_case| {
                            if (comptime tag == std.meta.activeTag(_case.value)) {
                                try _case.prong.dispatch(ctx, payload);
                                if (selector(ctx)) |next| {
                                    continue :SWITCH next;
                                }
                            }
                        }
                    },
                }
            } else {
                SWITCH: switch (value) {
                    inline else => |val| {
                        inline for (casePool.cases) |_case| {
                            if (comptime val == _case.value) {
                                try _case.prong.dispatch(ctx, val);

                                if (selector(ctx)) |next| {
                                    continue :SWITCH next;
                                }
                            }
                        }
                    },
                }
            }
        }
    };
}
