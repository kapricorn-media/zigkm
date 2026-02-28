const std = @import("std");
const builtin = @import("builtin");

const m = @import("zigkm-math");

const assets = @import("assets.zig");
const defs = @import("defs.zig");
const hooks = @import("hooks.zig");
const input = @import("input.zig");
const memory = @import("memory.zig");

const wasm_bindings = @import("wasm_bindings.zig");

const MemoryPtrType = ?*anyopaque;

fn castAppType(mem: MemoryPtrType) *defs.App
{
    return @ptrCast(@alignCast(mem));
}

pub const std_options = std.Options {
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .info,
        .ReleaseFast => .info,
        .ReleaseSmall => .info,
    },
    .logFn = wasmLog,
};

pub fn wasmLog(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype) void
{
    _ = scope;

    var buf: [4096]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, format, args) catch {
        const errMsg = "bufPrint failed for format: " ++ format;
        wasm_bindings.consoleMessage(true, &errMsg[0], errMsg.len);
        return;
    };

    const isError = switch (message_level) {
        .err, .warn => true,
        .info, .debug => false,
    };
    wasm_bindings.consoleMessage(isError, &message[0], message.len);
}

fn buttonToClickType(button: c_int) input.ClickType
{
    return switch (button) {
        0 => input.ClickType.Left,
        1 => input.ClickType.Middle,
        2 => input.ClickType.Right,
        else => input.ClickType.Other,
    };
}

// App exports

fn onInit(width: c_uint, height: c_uint) callconv(.c) MemoryPtrType
{
    wasm_bindings.glClearColor(0.0, 0.0, 0.0, 0.0);
    wasm_bindings.glEnable(wasm_bindings.GL_DEPTH_TEST);
    wasm_bindings.glDepthFunc(wasm_bindings.GL_LEQUAL);

    wasm_bindings.glEnable(wasm_bindings.GL_BLEND);
    wasm_bindings.glBlendFuncSeparate(
        wasm_bindings.GL_SRC_ALPHA, wasm_bindings.GL_ONE_MINUS_SRC_ALPHA,
        wasm_bindings.GL_ONE, wasm_bindings.GL_ONE
    );

    const mem = std.heap.page_allocator.alignedAlloc(u8, .of(defs.App), defs.MEMORY_FOOTPRINT) catch |err| {
        std.log.err("Failed to allocate WASM memory, error {}", .{err});
        return null;
    };
    @memset(mem, 0);

    const app = @as(*defs.App, @ptrCast(mem.ptr));
    const screenSize: m.V2u = .{width, height};
    const scale = 1.0;
    hooks.load(app, mem, screenSize, scale) catch |err| {
        std.log.err("app load failed, err {}", .{err});
        return null;
    };

    return @ptrCast(mem.ptr);
}

fn onAnimationFrame(mem: MemoryPtrType, width: c_uint, height: c_uint, scrollY: c_int, timestampUs: c_int) callconv(.c) c_int
{
    wasm_bindings.bindNullFramebuffer();
    wasm_bindings.glClear(wasm_bindings.GL_COLOR_BUFFER_BIT | wasm_bindings.GL_DEPTH_BUFFER_BIT);

    const app = castAppType(mem);
    const screenSize: m.V2u = .{width, height};
    return hooks.updateAndRender(app, screenSize, @intCast(timestampUs), scrollY);
}

fn onMouseMove(mem: MemoryPtrType, x: c_int, y: c_int) callconv(.c) void
{
    var app = castAppType(mem);
    app.inputState.mouseState.pos = .{x, y};
}

fn onMouseDown(mem: MemoryPtrType, button: c_int, x: c_int, y: c_int) callconv(.c) void
{
    var app = castAppType(mem);
    app.inputState.addClickEvent(.{
        .pos = .{x, y},
        .clickType = buttonToClickType(button),
        .down = true,
    });
}

fn onMouseUp(mem: MemoryPtrType, button: c_int, x: c_int, y: c_int) callconv(.c) void
{
    var app = castAppType(mem);
    app.inputState.addClickEvent(.{
        .pos = .{x, y},
        .clickType = buttonToClickType(button),
        .down = false,
    });
}

fn onMouseWheel(mem: MemoryPtrType, deltaX: c_int, deltaY: c_int) callconv(.c) void
{
    var app = castAppType(mem);
    app.inputState.addWheelDelta(.{deltaX, deltaY});
}

fn onKeyDown(mem: MemoryPtrType, keyCode: c_int) callconv(.c) void
{
    var app = castAppType(mem);
    app.inputState.addKeyEvent(.{
        .keyCode = keyCode,
        .down = true,
    });
    switch (keyCode) {
        8, 9, 13 => {
            // backspace, tab, enter (respectively)
            app.inputState.addUtf32(&.{@intCast(keyCode)});
        },
        else => {},
    }
}

fn onUtf32(mem: MemoryPtrType, utf32: c_uint) callconv(.c) void
{
    var app = castAppType(mem);
    app.inputState.addUtf32(&.{utf32});
}

fn onTouchStart(mem: MemoryPtrType, id: c_int, x: c_int, y: c_int, force: f32, radiusX: c_int, radiusY: c_int) callconv(.c) void
{
    _ = force;
    _ = radiusX; _ = radiusY;

    var app = castAppType(mem);
    app.inputState.addTouchEvent(.{
        .id = @intCast(id),
        .pos = .{x, y},
        .tapCount = 1,
        .phase = .Begin,
    });
}

fn onTouchMove(mem: MemoryPtrType, id: c_int, x: c_int, y: c_int, force: f32, radiusX: c_int, radiusY: c_int) callconv(.c) void
{
    _ = force;
    _ = radiusX; _ = radiusY;

    var app = castAppType(mem);
    app.inputState.addTouchEvent(.{
        .id = @intCast(id),
        .pos = .{x, y},
        .tapCount = 1,
        .phase = .Move,
    });
}

fn onTouchEnd(mem: MemoryPtrType, id: c_int, x: c_int, y: c_int, force: f32, radiusX: c_int, radiusY: c_int) callconv(.c) void
{
    _ = force;
    _ = radiusX; _ = radiusY;

    var app = castAppType(mem);
    app.inputState.addTouchEvent(.{
        .id = @intCast(id),
        .pos = .{x, y},
        .tapCount = 1,
        .phase = .End,
    });
}

fn onTouchCancel(mem: MemoryPtrType, id: c_int, x: c_int, y: c_int, force: f32, radiusX: c_int, radiusY: c_int) callconv(.c) void
{
    _ = force;
    _ = radiusX; _ = radiusY;

    var app = castAppType(mem);
    app.inputState.addTouchEvent(.{
        .id = @intCast(id),
        .pos = .{x, y},
        .tapCount = 1,
        .phase = .Cancel,
    });
}

fn onPopState(mem: MemoryPtrType) callconv(.c) void
{
    var app = castAppType(mem);
    app.onBack();
}

fn onDeviceOrientation(mem: MemoryPtrType, alpha: f32, beta: f32, gamma: f32) callconv(.c) void
{
    var app = castAppType(mem);
    app.inputState.deviceState.angles[0] = alpha;
    app.inputState.deviceState.angles[1] = beta;
    app.inputState.deviceState.angles[2] = gamma;
}

fn onHttp(mem: MemoryPtrType, method: c_uint, code: c_uint, uriLen: c_uint, dataLen: c_int) callconv(.c) void
{
    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    const methodZ = wasm_bindings.intToHttpMethod(method);

    var uri = a.alloc(u8, uriLen) catch {
        std.log.err("Failed to allocate uri", .{});
        return;
    };
    if (wasm_bindings.fillDataBuffer(&uri[0], uri.len) != 1) {
        std.log.err("fillDataBuffer failed for uri", .{});
        return;
    }

    const data = a.alloc(u8, @intCast(dataLen)) catch {
        std.log.err("Failed to allocate data", .{});
        return;
    };
    if (wasm_bindings.fillDataBuffer(data.ptr, data.len) != 1) {
        std.log.err("fillDataBuffer failed for data", .{});
        return;
    }

    var app = castAppType(mem);
    app.onHttp(methodZ, uri, code, data, a);
}

fn onFileDrag(mem: MemoryPtrType, phase: c_uint, x: c_int, y: c_int) callconv(.c) void
{
    var app = castAppType(mem);
    const p: input.FileDragPhase = switch (phase) {
        0 => .start,
        1 => .move,
        2 => .end,
        else => .move,
    };
    app.inputState.addFileDragEvent(.{
        .pos = .{x, y},
        .phase = p,
    });
    // Mouse state is not updated in the usual way during file drags.
    app.inputState.mouseState.pos = .{x, y};
}

fn onDropFile(mem: MemoryPtrType, nameLen: c_uint, dataLen: c_uint) callconv(.c) void
{
    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    var name = a.alloc(u8, nameLen) catch {
        std.log.err("Failed to allocate uri", .{});
        return;
    };
    if (wasm_bindings.fillDataBuffer(&name[0], name.len) != 1) {
        std.log.err("fillDataBuffer failed for name", .{});
        return;
    }

    const data = a.alloc(u8, @intCast(dataLen)) catch {
        std.log.err("Failed to allocate data", .{});
        return;
    };
    if (wasm_bindings.fillDataBuffer(data.ptr, data.len) != 1) {
        std.log.err("fillDataBuffer failed for data", .{});
        return;
    }

    var app = castAppType(mem);
    app.onDropFile(name, data, a);
    // Seems like end-phase file drag event is ommitted on file drop.
    app.inputState.addFileDragEvent(.{.pos = .{0, 0}, .phase = .end});
}

fn onLoadedFont(mem: MemoryPtrType, id: c_uint, fontDataLen: c_uint) callconv(.c) void
{
    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    var fontDataBuf = a.allocWithOptions(u8, fontDataLen, .of(assets.FontLoadData), null) catch {
        std.log.err("Failed to allocate fontDataBuf", .{});
        return;
    };
    if (wasm_bindings.fillDataBuffer(&fontDataBuf[0], fontDataBuf.len) != 1) {
        std.log.err("fillDataBuffer failed", .{});
        return;
    }
    if (fontDataBuf.len != @sizeOf(assets.FontLoadData)) {
        std.log.err("FontLoadData size mismatch", .{});
        return;
    }
    const fontData = @as(*const assets.FontLoadData, @ptrCast(fontDataBuf.ptr));

    var app = castAppType(mem);
    app.assets.onLoadedFont(id, &.{.fontData = fontData}, a);
}

fn onLoadedTexture(mem: MemoryPtrType, id: c_uint, texId: c_uint, width: c_uint, height: c_uint, canvasWidth: c_uint, canvasHeight: c_uint, topLeftX: c_int, topLeftY: c_int) callconv(.c) void
{
    const size: m.V2u = .{width, height};
    const canvasSize: m.V2u = .{canvasWidth, canvasHeight};
    const topLeft: m.V2i = .{topLeftX, topLeftY};

    var app = castAppType(mem);
    app.assets.onLoadedTexture(id, &.{.texId = texId, .size = size, .canvasSize = canvasSize, .topLeft = topLeft});
}

// non-App exports

fn loadFontDataInternal(atlasSize: c_int, fontDataLen: c_uint, fontSize: f32, scale: f32) !void
{
    std.log.info("loadFontData atlasSize={} fontSize={d:.3} scale={d:.3}", .{atlasSize, fontSize, scale});

    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    var fontDataBuf = try a.alloc(u8, fontDataLen);
    if (wasm_bindings.fillDataBuffer(&fontDataBuf[0], fontDataBuf.len) != 1) {
        return error.FillDataBuffer;
    }

    var fontData = try a.create(assets.FontLoadData);
    const pixelBytes = try fontData.load(@intCast(atlasSize), fontDataBuf, fontSize, scale, a);

    if (wasm_bindings.addReturnValueBuf(&pixelBytes[0], pixelBytes.len) != 1) {
        return error.AddReturnValue;
    }
    const fontDataBytes = std.mem.asBytes(fontData);
    if (wasm_bindings.addReturnValueBuf(&fontDataBytes[0], fontDataBytes.len) != 1) {
        return error.AddReturnValue;
    }
}

// Returns 1 on success, 0 on failure
fn loadFontData(atlasSize: c_int, fontDataLen: c_uint, fontSize: f32, scale: f32) callconv(.c) c_int
{
    loadFontDataInternal(atlasSize, fontDataLen, fontSize, scale) catch |err| {
        std.log.err("loadFontData failed atlasSize={} fontSize={d:.3} scale={d:.3} err={}", .{atlasSize, fontSize, scale, err});
        return 0;
    };
    return 1;
}

pub fn register() void
{
    @export(&onInit, .{.name = "onInit", .linkage = .strong});
    @export(&onAnimationFrame, .{.name = "onAnimationFrame", .linkage = .strong});
    @export(&onMouseMove, .{.name = "onMouseMove", .linkage = .strong});
    @export(&onMouseDown, .{.name = "onMouseDown", .linkage = .strong});
    @export(&onMouseUp, .{.name = "onMouseUp", .linkage = .strong});
    @export(&onMouseWheel, .{.name = "onMouseWheel", .linkage = .strong});
    @export(&onKeyDown, .{.name = "onKeyDown", .linkage = .strong});
    @export(&onUtf32, .{.name = "onUtf32", .linkage = .strong});
    @export(&onTouchStart, .{.name = "onTouchStart", .linkage = .strong});
    @export(&onTouchMove, .{.name = "onTouchMove", .linkage = .strong});
    @export(&onTouchEnd, .{.name = "onTouchEnd", .linkage = .strong});
    @export(&onTouchCancel, .{.name = "onTouchCancel", .linkage = .strong});
    @export(&onPopState, .{.name = "onPopState", .linkage = .strong});
    @export(&onDeviceOrientation, .{.name = "onDeviceOrientation", .linkage = .strong});
    @export(&onHttp, .{.name = "onHttp", .linkage = .strong});
    @export(&onFileDrag, .{.name = "onFileDrag", .linkage = .strong});
    @export(&onDropFile, .{.name = "onDropFile", .linkage = .strong});
    @export(&onLoadedFont, .{.name = "onLoadedFont", .linkage = .strong});
    @export(&onLoadedTexture, .{.name = "onLoadedTexture", .linkage = .strong});
    @export(&loadFontData, .{.name = "loadFontData", .linkage = .strong});
}
