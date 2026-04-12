const std = @import("std");

const m = @import("zigkm").math;

const defs = @import("defs.zig");
const memory = @import("memory.zig");

// TODO there could be a wrapper class for defs.App defined here, maybe...

pub fn load(app: *defs.App, buf: []u8, screenSize: m.V2u, scale: f32) !void
{
    std.log.info("app load ({}x{}, {}) ({} MB)", .{screenSize[0], screenSize[1], scale, buf.len / 1024 / 1024});

    // Default-initialize all custom user fields
    app.* = .{
        .memory = undefined,
        .inputState = undefined,
        .renderState = undefined,
        .assets = undefined,
    };

    app.memory = memory.Memory.init(buf, @sizeOf(defs.App));
    app.inputState.clear();
    try app.renderState.load();
    try app.assets.load();

    try app.load(screenSize, scale);
}

pub fn updateAndRender(app: *defs.App, screenSize: m.V2u, timestampUs: i64, scrollY: i32) i32
{
    app.inputState.updateStart();
    defer app.inputState.updateEnd();

    const maxInflight = 8;
    app.assets.loadQueued(maxInflight);

    return app.updateAndRender(screenSize, timestampUs, scrollY);
}

// TODO hooks for everything else? input stuff, assets, network, idk...
