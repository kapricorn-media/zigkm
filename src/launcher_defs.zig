const std = @import("std");

pub const ClientMainArgs = extern struct {
    dataDirLen: u32,
    dataDirPtr: [*]const u8,
    hasServerAddress: bool,
    serverAddress: std.net.Address,
};

pub const ReturnCode = enum(c_int) {
    exit_to_desktop = 0,
    exit_to_launcher,
    go_multiplayer,
    err,
};

pub const ClientMainFn = fn(args: *const ClientMainArgs) callconv(.c) ReturnCode;
