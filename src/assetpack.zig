const std = @import("std");
const A = std.mem.Allocator;

const serde = @import("serde.zig");
const zlib = @import("zlib.zig");

pub const PixelFormat = enum(u8) {
    rgba,
    rgb,
};

pub const TypeData = union(enum(u8)) {
    binary: void,
    pixels: struct {
        width: u32,
        height: u32,
        format: PixelFormat,
    },
};

pub const Entry = struct {
    path: []u8,
    typeData: TypeData,
    uncompressedSize: u64,
    dataStart: u64,
    dataEnd: u64,
};

pub const Pack = struct {
    entries: []Entry,
    data: []u8,
    ns_entryMap: std.StringHashMapUnmanaged(*Entry),

    pub fn load(pack: *Pack, a: A, path: []const u8) !void
    {
        var fileBuf: [4096]u8 = undefined;

        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var reader = file.reader(&fileBuf);
        try serde.deserializeAny(Pack, a, &reader.interface, pack);

        pack.ns_entryMap = .{};
        try pack.updateEntryMap(a);
    }

    pub fn save(pack: *const Pack, path: []const u8) !void
    {
        var fileBuf: [4096]u8 = undefined;

        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var writer = file.writer(&fileBuf);
        try serde.serializeAny(Pack, pack, &writer.interface);
    }

    pub fn updateEntryMap(pack: *Pack, a: A) !void
    {
        pack.ns_entryMap.clearRetainingCapacity();
        for (pack.entries) |*e| {
            std.debug.assert(try pack.ns_entryMap.fetchPut(a, e.path, e) == null);
        }
    }

    pub fn getEntry(pack: *const Pack, path: []const u8) ?Entry
    {
        return (pack.ns_entryMap.get(path) orelse return null).*;
    }

    pub fn getEntryBytesUncompressed(pack: *const Pack, entry: Entry, a: A) ![]u8
    {
        const compressed = pack.data[entry.dataStart..entry.dataEnd];
        const buf = try a.alloc(u8, entry.uncompressedSize);
        return try zlib.inflateOneShot(compressed, buf);
    }
};
