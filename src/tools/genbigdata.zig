const builtin = @import("builtin");
const std = @import("std");

const appkm = @import("zigkm-app");
const bigdata = appkm.bigdata;

pub const std_options = std.Options {
    .log_level = .info,
};

pub fn main() !void
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3 and args.len != 4) {
        std.log.err("Expected arguments: <path> <outfile> [existing-path]", .{});
        return error.BadArgs;
    }

    var data: bigdata.Data = undefined;
    if (args.len == 4) {
        const existingPath = args[3];
        try data.loadFromFile(existingPath, allocator);
    } else {
        data.load(allocator);
    }
    defer data.deinit();

    const dirPath = args[1];
    try data.fillFromFilesystem(dirPath, allocator);

    const outFile = args[2];
    try data.saveToFile(outFile, allocator);

    std.log.info("Generated and saved \"{s}\" directory to file \"{s}\"", .{dirPath, outFile});
}
