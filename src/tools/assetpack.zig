const std = @import("std");
const A = std.mem.Allocator;

const zigkm = @import("zigkm");
const assetpack = zigkm.assetpack;
const memory = zigkm.memory;
const zlib = zigkm.zlib;

const zigimg = @import("zigimg");

pub const MEMORY_TEMP = 1024 * 1024 * 1024;
pub const ZLIB_LEVEL_DEFAULT = 5;

var fileBuf: [4096]u8 = undefined;

fn sanitizePath(path: []u8) void
{
    for (path) |*c| {
        if (c.* == '\\') {
            c.* = '/';
        }
    }
}

pub fn main() !void
{
    var arenaGlobal = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arenaGlobal.deinit();
    const allocator = arenaGlobal.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) {
        std.log.err("Expected args: <dir> <outFile> [<compression level>]", .{});
        return error.BadArgs;
    }
    const dirName = args[1];
    const outFileName = args[2];
    const compressionLevel = if (args.len > 3) try std.fmt.parseUnsigned(u8, args[3], 10) else ZLIB_LEVEL_DEFAULT;
    std.log.info("Packing dir \"{s}\" with compression level {}", .{dirName, compressionLevel});

    var entries: std.ArrayList(assetpack.Entry) = .{};
    var data: std.ArrayList(u8) = .{};

    var dir = try std.fs.cwd().openDir(dirName, .{.iterate = true});
    defer dir.close();

    var totalSizePrev: u64 = 0;
    var walker = try dir.walk(allocator);
    while (try walker.next()) |e| {
        var arena = memory.getTempArena(null);
        defer arena.reset();
        const a = arena.allocator();

        if (e.kind == .file) {
            var entry = try entries.addOne(allocator);
            entry.* = .{
                .path = try allocator.dupe(u8, e.path),
                .typeData = .binary,
                .uncompressedSize = 0,
                .dataStart = data.items.len,
                .dataEnd = data.items.len,
            };
            sanitizePath(entry.path);
            std.log.info("{s}", .{entry.path});

            var file = try e.dir.openFile(e.basename, .{});
            defer file.close();
            var reader = file.reader(&fileBuf);
            var bytes = std.io.Writer.Allocating.init(a);
            _ = try reader.interface.streamRemaining(&bytes.writer);

            if (std.mem.endsWith(u8, e.path, ".png")) {
                const img = try zigimg.Image.fromMemory(a, bytes.written());
                entry.typeData = .{.pixels = .{
                    .width = @intCast(img.width),
                    .height = @intCast(img.height),
                    .format = undefined,
                }};
                switch (img.pixels) {
                    .rgba32 => |p| {
                        entry.typeData.pixels.format = .rgba;
                        const imgBytes = std.mem.sliceAsBytes(p);
                        entry.uncompressedSize = imgBytes.len;
                        try data.appendSlice(allocator, try zlib.deflateOneShot(allocator, compressionLevel, imgBytes));
                    },
                    .rgb24 => |p| {
                        entry.typeData.pixels.format = .rgb;
                        const imgBytes = std.mem.sliceAsBytes(p);
                        entry.uncompressedSize = imgBytes.len;
                        try data.appendSlice(allocator, try zlib.deflateOneShot(allocator, compressionLevel, imgBytes));
                    },
                    else => {
                        std.log.err("Unsupported format {s}", .{@tagName(img.pixels)});
                        return error.ImageFormat;
                    },
                }
            } else {
                entry.typeData = .{.binary = {}};
                entry.uncompressedSize = bytes.written().len;
                const compressed = try zlib.deflateOneShot(allocator, compressionLevel, bytes.written());
                try data.appendSlice(allocator, compressed);
            }

            entry.dataEnd = data.items.len;
            totalSizePrev += bytes.written().len;
        }
    }

    const pack: assetpack.Pack = .{
        .entries = entries.items,
        .data = data.items,
        .ns_entryMap = .{},
    };
    try pack.save(outFileName);
    std.log.info("Wrote output to \"{s}\"", .{outFileName});
    std.log.info("{} -> {} bytes", .{totalSizePrev, pack.data.len});
    std.log.info("{} entries", .{entries.items.len});
}
