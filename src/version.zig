const std = @import("std");
const A = std.mem.Allocator;

const SEP = '_';

pub fn zeroString(N: comptime_int, str: *const [N]u8) []const u8
{
    const end = std.mem.indexOfScalar(u8, str, 0) orelse str.len;
    return str[0..end];
}

pub fn makeZeroString(N: comptime_int, str: []const u8) [N]u8
{
    var result: [N]u8 = undefined;
    @memset(&result, 0);
    const len = @min(str.len, N);
    @memcpy(result[0..len], str[0..len]);
    return result;
}

pub const Version = struct {
    pub const NAME_MAX = 32;

    name: [NAME_MAX]u8,
    version: std.SemanticVersion,

    pub fn format(self: @This(), writer: *std.io.Writer) std.io.Writer.Error!void
    {
        try writer.print("{s}_{f}", .{zeroString(NAME_MAX, &self.name), self.version});
    }

    pub fn parse(str: []const u8) ?Version
    {
        const sep = std.mem.indexOfScalar(u8, str, SEP) orelse return null;
        return .{
            .name = makeZeroString(NAME_MAX, str[0..sep]),
            .version = std.SemanticVersion.parse(str[sep + 1..str.len]) catch return null,
        };
    }
};
