const builtin = @import("builtin");
const std = @import("std");

const platform = @import("zigkm-platform");

const defs = @import("defs.zig");

const exports = switch (platform.platform) {
    .android => @import("android_exports.zig"),
    .ios => @import("ios_exports.zig"),
    .web => @import("wasm_exports.zig"),
    .server => unreachable,
};

// pub usingnamespace exports;
