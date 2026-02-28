const builtin = @import("builtin");
const std = @import("std");
const root = @import("root");

const platform = @import("zigkm-platform");

comptime {
    switch (platform.platform) {
        .android, .ios, .web => {},
        else => |p| {
            @compileLog("Unsupported platform for zigkm-app", p);
        },
    }
}

pub const App = if (@hasDecl(root, "App")) root.App else @compileError("Missing App in root");
pub const MEMORY_FOOTPRINT = if (@hasDecl(root, "MEMORY_FOOTPRINT")) root.MEMORY_FOOTPRINT else @compileError("Missing MEMORY_FOOTPRINT in root");

comptime {
    if (@sizeOf(App) > MEMORY_FOOTPRINT) {
        @compileLog("MEMORY_FOOTPRINT ({}) not large enough for App ({})", .{
            @sizeOf(App), MEMORY_FOOTPRINT
        });
        unreachable;
    }

    if (!@hasField(App, "inputState")) {
        @compileLog("App type missing field inputState");
        unreachable;
    }
}
