const std = @import("std");
const Src = std.builtin.SourceLocation;

pub const ZoneCtx = struct {
    pub fn end(self: ZoneCtx) void
    {
        _ = self;
    }
};

pub fn zoneN(comptime src: Src, name: [*:0]const u8) ZoneCtx
{
    _ = src;
    _ = name;
    return .{};
}

pub fn frameMarkNamed(name: [*:0]const u8) void
{
    _ = name;
}

pub fn message(str: []const u8) void
{
    _ = str;
}
