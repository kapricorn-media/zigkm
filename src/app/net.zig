const std = @import("std");
const builtin = @import("builtin");
const A = std.mem.Allocator;

const platform = @import("zigkm-platform");

const exports = @import("exports.zig");
const android_bindings = @import("android_bindings.zig");
const ios_bindings = @import("ios_bindings.zig");
const wasm_bindings = @import("wasm_bindings.zig");

pub fn httpRequest(method: std.http.Method, url: []const u8, body: []const u8) void
{
    httpRequestHeader(method, url, "", "", body);
}

/// lmao...
pub fn httpRequestHeader(method: std.http.Method, url: []const u8, h1: []const u8, v1: []const u8, body: []const u8) void
{
    switch (platform.platform) {
        .android => {
            android_bindings.httpRequest(method, url, h1, v1, body);
        },
        .ios => {
            ios_bindings.httpRequest(exports._contextPtr, method, url, h1, v1, body);
        },
        .web => {
            wasm_bindings.httpRequestZ(method, url, h1, v1, body);
        },
        else => |p| {
            @compileLog("Unsupported platform", p);
        },
    }
}
