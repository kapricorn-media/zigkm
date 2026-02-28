const std = @import("std");
const builtin = @import("builtin");

const m = @import("zigkm-math");

const defs = @import("defs.zig");
const hooks = @import("hooks.zig");
const bindings = @import("ios_bindings.zig");
const ios = bindings.ios;
const memory = @import("memory.zig");

pub const std_options = std.Options {
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .info,
        .ReleaseFast => .info,
        .ReleaseSmall => .info,
    },
    .logFn = myLogFn,
};

pub var _contextPtr: *bindings.Context = undefined;

const MemoryPtrType = ?*anyopaque;

fn castAppType(mem: MemoryPtrType) *defs.App
{
    return @ptrCast(@alignCast(mem));
}

export fn onStart(contextVoidPtr: ?*anyopaque, width: u32, height: u32, scale: f64) ?*anyopaque
{
    const context = @as(*bindings.Context, @ptrCast(contextVoidPtr orelse return null));
    _contextPtr = context;

    const alignment = 16;
    const mem = std.heap.page_allocator.alignedAlloc(u8, alignment, defs.MEMORY_FOOTPRINT) catch |err| {
        std.log.err("Failed to allocate memory, error {}", .{err});
        return null;
    };
    @memset(mem, 0);

    const app = @as(*defs.App, @ptrCast(mem.ptr));
    const screenSize: m.V2u = .{width, height};
    hooks.load(app, mem, screenSize, @floatCast(scale)) catch |err| {
        std.log.err("app load failed, err {}", .{err});
        return null;
    };

    return @ptrCast(mem.ptr);
}

export fn onExit(contextVoidPtr: ?*anyopaque, data: MemoryPtrType) void
{
    std.log.info("onExit", .{});

    const context = @as(*bindings.Context, @ptrCast(contextVoidPtr orelse return));
    _ = context;

    const app = castAppType(data);
    _ = app;
}

export fn onTouchEvents(data: MemoryPtrType, length: u32, touchEvents: [*]const ios.TouchEvent) void
{
    if (data == null) {
        return;
    }
    var app = castAppType(data);

    for (touchEvents[0..length]) |touchEvent| {
        app.inputState.addTouchEvent(.{
            .id = touchEvent.id,
            .pos = .{@intCast(touchEvent.x), @intCast(touchEvent.y)},
            .tapCount = touchEvent.tapCount,
            .phase = switch (touchEvent.phase) {
                ios.TOUCH_PHASE_UNKNOWN, ios.TOUCH_PHASE_UNSUPPORTED => {
                    std.log.err("bad touch phase", .{});
                    continue;
                },
                ios.TOUCH_PHASE_BEGIN => .Begin,
                ios.TOUCH_PHASE_STATIONARY => .Still,
                ios.TOUCH_PHASE_MOVE => .Move,
                ios.TOUCH_PHASE_END => .End,
                ios.TOUCH_PHASE_CANCEL => .Cancel,
                else => {
                    std.log.err("unknown touch phase", .{});
                    continue;
                },
            }
        });
    }
}

export fn onTextUtf32(data: MemoryPtrType, length: u32, utf32: [*]const u32) void
{
    if (data == null) {
        return;
    }
    var app = castAppType(data);
    for (utf32[0..length]) |codepoint| {
        app.inputState.keyboardState.utf32.append(codepoint) catch break;
    }
}

export fn onHttp(data: MemoryPtrType, method: ios.HttpMethod, url: ios.Slice, code: c_uint, responseBody: ios.Slice) void
{
    if (data == null) {
        return;
    }
    var app = castAppType(data);

    const methodZ = bindings.fromHttpMethod(method);
    const urlZ = bindings.fromCSlice(url);
    const responseBodyZ = bindings.fromCSlice(responseBody);

    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    app.onHttp(methodZ, urlZ, code, responseBodyZ, a);
}

export fn onAppLink(data: MemoryPtrType, url: ios.Slice) void
{
    if (data == null) {
        return;
    }
    var app = castAppType(data);

    const urlZ = bindings.fromCSlice(url);

    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    app.onAppLink(urlZ, a);
}

export fn updateAndRender(contextVoidPtr: ?*anyopaque, data: MemoryPtrType, width: u32, height: u32) c_int
{
    const context = @as(*bindings.Context, @ptrCast(contextVoidPtr orelse return 0));
    _ = context;

    if (data == null) {
        return 0;
    }
    const app = castAppType(data);

    const screenSize: m.V2u = .{width, height};
    const timestampUs = std.time.microTimestamp();
    const scrollY = 0;
    return hooks.updateAndRender(app, screenSize, timestampUs, scrollY);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn
{
    _ = error_return_trace;
    _ = ret_addr;

    std.log.err("PANIC!", .{});
    std.log.err("{s}", .{msg});
    std.posix.abort();

    // const stderr = std.io.getStdErr().writer();
    // if (stackTrace) |trace| {
    //     trace.format("", .{}, stderr) catch |err| {
    //         std.log.err("panic - failed to print stack trace: {}", .{err});
    //     };
    // }
    // std.builtin.default_panic(message, stackTrace, v);
}

fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void
{
    // TODO risky? too much stack space?
    var logBuffer: [2048]u8 = undefined;
    const scopeStr = if (scope == .default) "[ ] " else "[" ++ @tagName(scope) ++ "] ";
    const fullFormat = "ZIG." ++ @tagName(level) ++ ": " ++ scopeStr ++ format;
    const str = std.fmt.bufPrintZ(&logBuffer, fullFormat, args) catch {
        bindings.log("ZIG.error: log overflow, failed to print");
        return;
    };
    bindings.log(str);
}
