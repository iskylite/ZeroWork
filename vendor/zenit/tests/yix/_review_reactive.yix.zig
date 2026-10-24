// GENERATED FILE, do not edit: generated from review_reactive.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
pub var store: ?*ui.Signal(i32) = null;
fn readStore() i32 { return store.?.get(); }
fn peekStore() i32 { return store.?.peek(); }
fn storeSource() *ui.Signal(i32) { return store.?; }
fn twice(x: i32) i32 { return x * 2; }
pub fn ExternalOnly(args: anytype) ui.view.ComponentOf(__yix_ExternalOnly) {
    return ui.view.component(__yix_ExternalOnly, ui.reactive.props.coerce(ExternalOnlyProps, args));
}
pub const ExternalOnlyProps = struct {
};
fn __yix_ExternalOnly(__yix_props: ExternalOnlyProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_call2: {
        const __yix_Raw = @TypeOf(readStore());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) readStore() else __yix_d1: {
        const __yix_T = @TypeOf(readStore());
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return readStore();
        } }.__yix_compute);
    };
    }), ""), .{ __yix_call2: {
        const __yix_Raw = @TypeOf(readStore());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) readStore() else __yix_d1: {
        const __yix_T = @TypeOf(readStore());
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return readStore();
        } }.__yix_compute);
    };
    }, })));
    __yix_root.meta.ownership.meta.component_name = "ExternalOnly";
    return __yix_root;

}
pub fn ExternalWithProp(args: anytype) ui.view.ComponentOf(__yix_ExternalWithProp) {
    return ui.view.component(__yix_ExternalWithProp, ui.reactive.props.coerce(ExternalWithPropProps, args));
}
pub const ExternalWithPropProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
};
fn __yix_ExternalWithProp(__yix_props: ExternalWithPropProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(readStore() + n.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .n = n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return readStore() + __yix_ctx.n.get();
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(readStore() + n.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .n = n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return readStore() + __yix_ctx.n.get();
        } }.__yix_compute);
    }, })));
    __yix_root.meta.ownership.meta.component_name = "ExternalWithProp";
    return __yix_root;

}
pub fn PeekOnly(args: anytype) ui.view.ComponentOf(__yix_PeekOnly) {
    return ui.view.component(__yix_PeekOnly, ui.reactive.props.coerce(PeekOnlyProps, args));
}
pub const PeekOnlyProps = struct {
};
fn __yix_PeekOnly(__yix_props: PeekOnlyProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_call2: {
        const __yix_Raw = @TypeOf(peekStore());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) peekStore() else __yix_d1: {
        const __yix_T = @TypeOf(peekStore());
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return peekStore();
        } }.__yix_compute);
    };
    }), ""), .{ __yix_call2: {
        const __yix_Raw = @TypeOf(peekStore());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) peekStore() else __yix_d1: {
        const __yix_T = @TypeOf(peekStore());
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return peekStore();
        } }.__yix_compute);
    };
    }, })));
    __yix_root.meta.ownership.meta.component_name = "PeekOnly";
    return __yix_root;

}
pub fn ReturnedSource(args: anytype) ui.view.ComponentOf(__yix_ReturnedSource) {
    return ui.view.component(__yix_ReturnedSource, ui.reactive.props.coerce(ReturnedSourceProps, args));
}
pub const ReturnedSourceProps = struct {
};
fn __yix_ReturnedSource(__yix_props: ReturnedSourceProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_call2: {
        const __yix_Raw = @TypeOf(storeSource());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) storeSource() else __yix_d1: {
        const __yix_T = @TypeOf(storeSource());
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return storeSource();
        } }.__yix_compute);
    };
    }), ""), .{ __yix_call2: {
        const __yix_Raw = @TypeOf(storeSource());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) storeSource() else __yix_d1: {
        const __yix_T = @TypeOf(storeSource());
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return storeSource();
        } }.__yix_compute);
    };
    }, })));
    __yix_root.meta.ownership.meta.component_name = "ReturnedSource";
    return __yix_root;

}
pub fn Pure(args: anytype) ui.view.ComponentOf(__yix_Pure) {
    return ui.view.component(__yix_Pure, ui.reactive.props.coerce(PureProps, args));
}
pub const PureProps = struct {
};
fn __yix_Pure(__yix_props: PureProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_call2: {
        const __yix_Raw = @TypeOf(twice(4));
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) twice(4) else __yix_d1: {
        const __yix_T = @TypeOf(twice(4));
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return twice(4);
        } }.__yix_compute);
    };
    }), ""), .{ __yix_call2: {
        const __yix_Raw = @TypeOf(twice(4));
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) twice(4) else __yix_d1: {
        const __yix_T = @TypeOf(twice(4));
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return twice(4);
        } }.__yix_compute);
    };
    }, })));
    __yix_root.meta.ownership.meta.component_name = "Pure";
    return __yix_root;

}
pub fn ExternalVisible(args: anytype) ui.view.ComponentOf(__yix_ExternalVisible) {
    return ui.view.component(__yix_ExternalVisible, ui.reactive.props.coerce(ExternalVisibleProps, args));
}
pub const ExternalVisibleProps = struct {
};
fn __yix_ExternalVisible(__yix_props: ExternalVisibleProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .visible = __yix_call2: {
        const __yix_Raw = @TypeOf(readStore() > 0);
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) readStore() > 0 else __yix_d1: {
        const __yix_T = @TypeOf(readStore() > 0);
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return readStore() > 0;
        } }.__yix_compute);
    };
    }, }, .{ }));
    __yix_root.meta.ownership.meta.component_name = "ExternalVisible";
    return __yix_root;

}
fn nullValue() @TypeOf(null) { return null; }
fn NullReceiver(args: anytype) @TypeOf(ui.view.text(.{}, "nil")) {
    return ui.view.text(.{}, if (args.value == null) "nil" else "set");
}
const TypeConfig = struct { T: type };
fn typeConfig() TypeConfig { return .{ .T = i32 }; }
fn TypeReceiver(args: anytype) @TypeOf(ui.view.text(.{}, "i32")) {
    return ui.view.text(.{}, @typeName(args.config.T));
}
pub fn NullCall(args: anytype) ui.view.ComponentOf(__yix_NullCall) {
    return ui.view.component(__yix_NullCall, ui.reactive.props.coerce(NullCallProps, args));
}
pub const NullCallProps = struct {
};
fn __yix_NullCall(__yix_props: NullCallProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, NullReceiver(.{ .value = __yix_call2: {
        const __yix_Raw = @TypeOf(nullValue());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) nullValue() else __yix_d1: {
        const __yix_T = if (ui.view.attrType(NullReceiver, "value")) |__yix_A| __yix_A else @TypeOf(nullValue());
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return nullValue();
        } }.__yix_compute);
    };
    }, }));
    __yix_root.meta.ownership.meta.component_name = "NullCall";
    return __yix_root;

}
pub fn ComptimeStructCall(args: anytype) ui.view.ComponentOf(__yix_ComptimeStructCall) {
    return ui.view.component(__yix_ComptimeStructCall, ui.reactive.props.coerce(ComptimeStructCallProps, args));
}
pub const ComptimeStructCallProps = struct {
};
fn __yix_ComptimeStructCall(__yix_props: ComptimeStructCallProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, TypeReceiver(.{ .config = __yix_call2: {
        const __yix_Raw = @TypeOf(typeConfig());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) typeConfig() else __yix_d1: {
        const __yix_T = if (ui.view.attrType(TypeReceiver, "config")) |__yix_A| __yix_A else @TypeOf(typeConfig());
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return typeConfig();
        } }.__yix_compute);
    };
    }, }));
    __yix_root.meta.ownership.meta.component_name = "ComptimeStructCall";
    return __yix_root;

}
const reviewRecipe = ui.cva(.{ .base = .{ .gap = @as(f32, 7) } });
pub fn StaticRecipeCall(args: anytype) ui.view.ComponentOf(__yix_StaticRecipeCall) {
    return ui.view.component(__yix_StaticRecipeCall, ui.reactive.props.coerce(StaticRecipeCallProps, args));
}
pub const StaticRecipeCallProps = struct {
};
fn __yix_StaticRecipeCall(__yix_props: StaticRecipeCallProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = reviewRecipe.of(.{}), }, .{ }));
    __yix_root.meta.ownership.meta.component_name = "StaticRecipeCall";
    return __yix_root;

}
const MixedConfig = struct { comptime T: type = i32, value: i32 };
fn readMixed() MixedConfig { return .{ .value = readStore() }; }
fn MixedReceiver(args: anytype) ui.view.ComponentOf(__yix_MixedReceiver) {
    return ui.view.component(__yix_MixedReceiver, ui.reactive.props.coerce(MixedReceiverProps, args));
}
const MixedReceiverProps = struct {
    config: ui.Source(MixedConfig),
};
fn __yix_MixedReceiver(__yix_props: MixedReceiverProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const config = __yix_props.config;
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(config.peek().value);
        break :__yix_d1 try scope.derive(__yix_T, .{ .config = config, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.config.get().value;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(config.peek().value);
        break :__yix_d1 try scope.derive(__yix_T, .{ .config = config, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.config.get().value;
        } }.__yix_compute);
    }, })));
    __yix_root.meta.ownership.meta.component_name = "MixedReceiver";
    return __yix_root;

}
pub fn MixedRuntimeCall(args: anytype) ui.view.ComponentOf(__yix_MixedRuntimeCall) {
    return ui.view.component(__yix_MixedRuntimeCall, ui.reactive.props.coerce(MixedRuntimeCallProps, args));
}
pub const MixedRuntimeCallProps = struct {
};
fn __yix_MixedRuntimeCall(__yix_props: MixedRuntimeCallProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, MixedReceiver(.{ .config = __yix_call2: {
        const __yix_Raw = @TypeOf(readMixed());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) readMixed() else __yix_d1: {
        const __yix_T = if (ui.view.attrType(MixedReceiver, "config")) |__yix_A| __yix_A else @TypeOf(readMixed());
        break :__yix_d1 try scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return readMixed();
        } }.__yix_compute);
    };
    }, }));
    __yix_root.meta.ownership.meta.component_name = "MixedRuntimeCall";
    return __yix_root;

}

//# yix-map-data [[253,253],[1677,319],[2876,403],[4268,465],[5724,535],[7060,590],[8464,1070],[9453,1142],[10595,1293],[11306,1501],[12490,1588]]

//# yix-map review_reactive.yix
