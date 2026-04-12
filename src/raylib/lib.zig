const std = @import("std");

const m = @import("zigkm").math;

pub const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rlgl.h");

    @cInclude("raygui.h");
});

pub fn v2(x: f32, y: f32) c.Vector2
{
    return .{.x = x, .y = y};
}

pub fn v2v(v: m.V2) c.Vector2
{
    return v2(v[0], v[1]);
}

pub fn v3(x: f32, y: f32, z: f32) c.Vector3
{
    return .{.x = x, .y = y, .z = z};
}

pub fn v3v(v: m.V3) c.Vector3
{
    return v3(v[0], v[1], v[2]);
}

pub fn v4(x: f32, y: f32, z: f32, w: f32) c.Vector4
{
    return .{.x = x, .y = y, .z = z, .w = w};
}

pub fn v4v(v: m.V4) c.Vector4
{
    return v4(v[0], v[1], v[2], v[3]);
}

pub fn color(r: u8, g: u8, b: u8, a: u8) c.Color
{
    return .{.r = r, .g = g, .b = b, .a = a};
}

pub fn colorF(r: f32, g: f32, b: f32, a: f32) c.Color
{
    return c.ColorFromNormalized(v4(r, g, b, a));
}

pub fn colorV(v: @Vector(4, f32)) c.Color
{
    return colorF(v[0], v[1], v[2], v[3]);
}

pub fn colorLerp(c1: c.Color, c2: c.Color, t: f32) c.Color
{
    const c1n = c.ColorNormalize(c1);
    const c2n = c.ColorNormalize(c2);
    return c.ColorFromNormalized(c.Vector4Lerp(c1n, c2n, t));
}

pub fn rectV(pos: c.Vector2, size: c.Vector2) c.Rectangle
{
    return .{
        .x = pos.x,
        .y = pos.y,
        .width = size.x,
        .height = size.y,
    };
}

pub fn rect(r: m.Rect) c.Rectangle
{
    return .{
        .x = r.min[0],
        .y = r.min[1],
        .width = r.max[0] - r.min[0],
        .height = r.max[1] - r.min[1],
    };
}

pub const InitWindowParams = struct {
    name: [*c]const u8,
    size: union(enum) {
        windowed: struct {
            pos: m.V2,
            size: m.V2,
        },
        windowedAuto: struct {
            heightFrac: f32,
            aspect: f32,
        },
        fullscreen: void,
    },
    flags: c_uint = c.FLAG_VSYNC_HINT | c.FLAG_MSAA_4X_HINT | c.FLAG_WINDOW_RESIZABLE,
};

pub fn windowSizeFromHeightFracAspect(heightFrac: f32, aspect: f32) m.V2
{
    const height = @as(f32, @floatFromInt(c.GetMonitorHeight(c.GetCurrentMonitor()))) * heightFrac;
    return .{height * aspect, height};
}

pub fn initWindow(params: InitWindowParams) void
{
    c.SetConfigFlags(params.flags);
    c.InitWindow(800, 600, params.name);

    c.BeginDrawing();
    c.ClearBackground(c.BLACK);
    c.EndDrawing();

    var windowInfo: ?struct {
        pos: m.V2,
        size: m.V2,
    } = null;
    switch (params.size) {
        .windowed => |p| {
            windowInfo = .{
                .pos = p.pos,
                .size = p.size,
            };
        },
        .windowedAuto => |p| {
            windowInfo = .{
                .pos = .{100, 100},
                .size = windowSizeFromHeightFracAspect(p.heightFrac, p.aspect),
            };
        },
        .fullscreen => {
            c.ToggleBorderlessWindowed();
        },
    }

    if (windowInfo) |wi| {
        c.SetWindowPosition(@intFromFloat(wi.pos[0]), @intFromFloat(wi.pos[1]));
        c.SetWindowSize(@intFromFloat(wi.size[0]), @intFromFloat(wi.size[1]));
    }
}
