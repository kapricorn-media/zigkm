const platform = @import("zigkm-platform");

pub const assets = @import("assets.zig");
pub const bigdata = @import("bigdata.zig");
pub const defs = @import("defs.zig");
pub const input = @import("input.zig");
pub const memory = @import("memory.zig");
pub const net = @import("net.zig");
pub const render = @import("render.zig");
// pub const server_utils = @import("server_utils.zig");
pub const ui = @import("ui.zig");
pub const uix = @import("uix.zig");

pub const android_bindings = @import("android_bindings.zig");
pub const ios_bindings = @import("ios_bindings.zig");
pub const wasm_bindings = @import("wasm_bindings.zig");

pub const exports = switch (platform.platform) {
    .android => @import("android_exports.zig"),
    .ios => @import("ios_exports.zig"),
    .web => @import("wasm_exports.zig"),
    .server => unreachable,
};
