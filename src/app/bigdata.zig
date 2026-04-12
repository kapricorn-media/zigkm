const std = @import("std");
const A = std.mem.Allocator;

const zkm = @import("zigkm");
const m = zkm.math;
const zigimg = @import("zigimg");

fn readIntBigEndian(comptime T: type, data: []const u8) !T
{
    var stream = std.io.fixedBufferStream(data);
    var reader = stream.reader();
    return reader.readInt(T, .big);
}

fn trim(image: zigimg.Image, slice: m.RectU) m.RectU
{
    std.debug.assert(image.pixels == .rgba32); // need alpha channel for current trim
    std.debug.assert(slice.min.x <= image.width and slice.min.y <= image.height);
    std.debug.assert(slice.max.x <= image.width and slice.max.y <= image.height);

    const sliceSize = slice.size();
    var max = slice.min;
    var min = slice.max;
    var y: usize = 0;
    while (y < sliceSize.y) : (y += 1) {
        var x: usize = 0;
        while (x < sliceSize.x) : (x += 1) {
            const pixelCoord = slice.min + m.V2{x, y};
            const pixelInd = pixelCoord.y * image.width + pixelCoord.x;
            const pixel = image.pixels.rgba32[pixelInd];
            if (pixel.a != 0) {
                max = m.max(max, pixelCoord);
                min = m.min(min, pixelCoord);
            }
        }
    }

    if (min.x > max.x and min.y > max.y) {
        return m.RectU.init(.{0, 0}, .{0, 0});
    }
    return m.RectU.init(slice.min + min, m.V2{1, 1});
}

fn deserializeMapValue(comptime T: type, data: []const u8, value: *T) !usize
{
    switch (@typeInfo(T)) {
        .int => {
            const valueU64 = try readIntBigEndian(u64, data);
            value.* = @as(T, @intCast(valueU64));
            return 8;
        },
        .pointer => |tiPtr| {
            switch (tiPtr.size) {
                .slice => {
                    if (comptime tiPtr.child != u8) {
                        @compileLog("Unsupported slice type", tiPtr.child);
                        unreachable;
                    }
                    const len = try readIntBigEndian(u64, data);
                    if (data.len < len + 8) {
                        return error.BadData;
                    }
                    value.* = data[8..8+len];
                    return 8 + len;
                },
                else => {
                    @compileLog("Unsupported type", T);
                    unreachable;
                },
            }
        },
        .array => |tiArray| {
            switch (tiArray.child) {
                u8 => {
                    @memcpy(value, data[0..tiArray.len]);
                    return tiArray.len;
                },
                else => {
                    var i: usize = 0;
                    for (value) |*v| {
                        const n = try deserializeMapValue(tiArray.child, data[i..], v);
                        i += n;
                    }
                    return i;
                }
            }
        },
        .@"struct" => |tiStruct| {
            var i: usize = 0;
            inline for (tiStruct.fields) |f| {
                const n = try deserializeMapValue(f.type, data[i..], &@field(value, f.name));
                i += n;
            }
        },
        else => {
            @compileLog("Unsupported type", T);
            unreachable;
        },
    }

    return 0;
}

fn serializeMapValue(writer: *std.io.Writer, value: anytype) !void
{
    var buf: [8]u8 = undefined;

    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => {
            const valueU64 = @as(u64, @intCast(value));
            std.mem.writeInt(u64, &buf, valueU64, .big);
            try writer.writeAll(&buf);
        },
        .pointer => |tiPtr| {
            switch (tiPtr.size) {
                .slice => {
                    if (comptime tiPtr.child != u8) {
                        @compileLog("Unsupported slice type", tiPtr.child);
                        unreachable;
                    }
                    std.mem.writeInt(u64, &buf, value.len, .big);
                    try writer.writeAll(&buf);
                    try writer.writeAll(value);
                },
                else => {
                    @compileLog("Unsupported type", T);
                    unreachable;
                },
            }
        },
        .array => |tiArray| {
            switch (tiArray.child) {
                u8 => {
                    try writer.writeAll(&value);
                },
                else => {
                    for (value) |v| {
                        try serializeMapValue(writer, v);
                    }
                }
            }
        },
        .@"struct" => |tiStruct| {
            inline for (tiStruct.fields) |f| {
                try serializeMapValue(writer, @field(value, f.name));
            }
        },
        else => {
            @compileLog("Unsupported type", T);
            unreachable;
        },
    }
}

pub fn deserializeMap(
    comptime ValueType: type,
    data: []const u8,
    map: *std.StringHashMap(ValueType)) !usize
{
    const numEntries = blk: {
        var stream = std.io.fixedBufferStream(data);
        var reader = stream.reader();
        break :blk try reader.readInt(u64, .big);
    };

    var i: usize = 8;
    var iMax: usize = 0;
    var n: usize = 0;
    while (n < numEntries) : (n += 1) {
        const pathEnd = std.mem.indexOfScalarPos(u8, data, i, 0) orelse return error.BadData;
        const path = data[i..pathEnd];
        if (pathEnd + 1 + 16 > data.len) {
            return error.BadData;
        }
        const intBuf = data[pathEnd+1..pathEnd+1+16];
        var intStream = std.io.fixedBufferStream(intBuf);
        var intReader = intStream.reader();
        const valueIndex = try intReader.readInt(u64, .big);
        const valueSize = try intReader.readInt(u64, .big);
        if (valueIndex > data.len) {
            return error.BadData;
        }
        if (valueIndex + valueSize > data.len) {
            return error.BadData;
        }
        const valueEnd = valueIndex + valueSize;
        const valueBytes = data[valueIndex..valueEnd];
        iMax = @max(iMax, valueEnd);

        i = pathEnd + 1 + 16;

        var v: ValueType = undefined;
        _ = try deserializeMapValue(ValueType, valueBytes, &v);
        try map.put(path, v);
    }

    return @max(iMax, 8);
}

pub fn serializeMap(comptime ValueType: type, map: std.StringHashMap(ValueType), a: A) ![]const u8
{
    var out = std.io.Writer.Allocating.init(a);

    try out.writer.writeInt(u64, map.count(), .big);
    var mapIt = map.iterator();
    while (mapIt.next()) |entry| {
        try out.writer.writeAll(entry.key_ptr.*);
        try out.writer.writeByte(0);
        try out.writer.splatByteAll(0, 16); // filled later
    }
    const bytes = out.written();
    // const endOfKeys = out.items.len;

    var buf: [8]u8 = undefined;
    mapIt = map.iterator();
    var i: usize = @sizeOf(u64); // skip initial map.count()
    while (mapIt.next()) |entry| {
        const dataIndex = bytes.len;
        try serializeMapValue(&out.writer, entry.value_ptr.*);
        const dataSize = bytes.len - dataIndex;

        i = std.mem.indexOfScalarPos(u8, bytes, i, 0) orelse return error.BadData;
        i += 1;
        if (i + 16 > bytes.len) {
            return error.BadData;
        }

        std.mem.writeInt(u64, &buf, dataIndex, .big);
        @memcpy(bytes[i..i+8], &buf);
        std.mem.writeInt(u64, &buf, dataSize, .big);
        @memcpy(bytes[i+8..i+16], &buf);
        i += 16;
        if (i > bytes.len) {
            return error.BadData;
        }
    }

    return out.toOwnedSlice();
}

test {
    const a = std.testing.allocator;

    var map = std.StringHashMap(SourceEntry).init(a);
    defer map.deinit();

    var entry: SourceEntry = undefined;
    @memset(&entry.md5Checksum, 6);
    for (&entry.children.buffer) |*e| {
        e.len = 0;
    }
    entry.children.len = 2;
    entry.children.set(0, "hello, world");
    entry.children.set(1, "goodbye, world");

    try map.put("entry1", entry);
    try map.put("entry1234", entry);

    const bytes = try serializeMap(SourceEntry, map, a);
    defer a.free(bytes);

    var mapOut = std.StringHashMap(SourceEntry).init(a);
    defer mapOut.deinit();
    const n = try deserializeMap(SourceEntry, bytes, &mapOut);
    try std.testing.expectEqual(n, bytes.len);
    // var mapOut = try deserializeMap(SourceEntry, bytes, a);
    // defer mapOut.deinit();

    try std.testing.expectEqual(map.count(), mapOut.count());
    var mapIt = map.iterator();
    while (mapIt.next()) |e| {
        const key = e.key_ptr.*;
        const v = mapOut.get(key) orelse {
            std.log.err("Missing key {s}", .{key});
            return error.MissingKey;
        };
        const value = e.value_ptr.*;
        try std.testing.expectEqualSlices(u8, &value.md5Checksum, &v.md5Checksum);
        try std.testing.expectEqual(value.children.len, v.children.len);
        for (value.children.buffer, 0..) |_, i| {
            try std.testing.expectEqualStrings(value.children.buffer[i], v.children.buffer[i]);
        }
    }
}

pub const SourceEntry = struct {
    md5Checksum: [16]u8,
    children: zkm.BoundedArray([]const u8, 32),
};

pub const Data = struct {
    arenaAllocator: std.heap.ArenaAllocator,
    sourceMap: std.StringHashMap(SourceEntry),
    map: std.StringHashMap([]const u8),
    bytes: ?[]const u8,

    const Self = @This();

    pub fn load(self: *Self, a: A) void
    {
        self.arenaAllocator = std.heap.ArenaAllocator.init(a);
        self.sourceMap = std.StringHashMap(SourceEntry).init(self.arenaAllocator.allocator());
        self.map = std.StringHashMap([]const u8).init(self.arenaAllocator.allocator());
        self.bytes = null;
    }

    pub fn loadFromFile(self: *Self, filePath: []const u8, a: A) !void
    {
        self.load(a);
        const selfAllocator = self.arenaAllocator.allocator();

        const cwd = std.fs.cwd();
        const file = try cwd.openFile(filePath, .{});
        defer file.close();
        const fileBytes = try file.readToEndAlloc(selfAllocator, 1024 * 1024 * 1024);

        const n1 = try deserializeMap(SourceEntry, fileBytes, &self.sourceMap);
        const n2 = try deserializeMap([]const u8, fileBytes[n1..], &self.map);
        if (n1 + n2 != fileBytes.len) {
            return error.BadData;
        }
        self.bytes = fileBytes;
    }

    pub fn saveToFile(self: *const Self, filePath: []const u8, a: A) !void
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const tempAllocator = arena.allocator();

        var file = try std.fs.cwd().createFile(filePath, .{});
        defer file.close();

        const sourceMapSerialized = try serializeMap(SourceEntry, self.sourceMap, tempAllocator);
        try file.writeAll(sourceMapSerialized);
        const mapSerialized = try serializeMap([]const u8, self.map, tempAllocator);
        try file.writeAll(mapSerialized);
    }

    pub fn deinit(self: *Self) void
    {
        self.arenaAllocator.deinit();
    }

    pub fn put(self: *Self, path: []const u8, data: []const u8, a: A) !void
    {
        _ = a;
        const selfAllocator = self.arenaAllocator.allocator();

        var sourceEntry: SourceEntry = undefined;
        var md5 = std.crypto.hash.Md5.init(.{});
        md5.update(data);
        md5.final(&sourceEntry.md5Checksum);
        sourceEntry.children.len = 0;
        // Important to clear all children for serialization logic
        for (&sourceEntry.children.buffer) |*e| {
            e.len = 0;
        }
        const pathDupe = try selfAllocator.dupe(u8, path);

        sourceEntry.children.len = 1;
        sourceEntry.children.buffer[0] = pathDupe;
        try self.map.put(pathDupe, try selfAllocator.dupe(u8, data));

        try self.sourceMap.put(pathDupe, sourceEntry);
    }

    pub fn fileExists(self: *const Self, path: []const u8, md5Checksum: *const [16]u8) bool
    {
        if (self.sourceMap.get(path)) |src| {
            if (std.mem.eql(u8, &src.md5Checksum, md5Checksum)) {
                return true;
            }
        }
        return false;
    }

    fn addIfNewOrUpdatedFilesystem(
        self: *Self, path: []const u8, fileData: []const u8, tempAllocator: A) !void
    {
        const md5 = calculateMd5Checksum(fileData);
        if (self.fileExists(path, &md5)) {
            std.log.info("Already in bigdata: {s}", .{path});
            return;
        }

        std.log.info("Inserting {s}", .{path});
        try self.put(path, fileData, tempAllocator);
    }

    pub fn fillFromFilesystem(self: *Self, path: []const u8, a: A) !void
    {
        const cwd = std.fs.cwd();
        var dir = try cwd.openDir(path, .{});
        defer dir.close();

        var dirIterable = try cwd.openDir(path, .{.iterate = true});
        defer dirIterable.close();

        var walker = try dirIterable.walk(a);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) {
                continue;
            }

            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const tempAllocator = arena.allocator();

            const file = try dir.openFile(entry.path, .{});
            defer file.close();
            const fileData = try file.readToEndAlloc(tempAllocator, 1024 * 1024 * 1024);

            const filePath = try std.fmt.allocPrint(tempAllocator, "/{s}", .{entry.path});
            std.mem.replaceScalar(u8, filePath, '\\', '/');
            try self.addIfNewOrUpdatedFilesystem(filePath, fileData, tempAllocator);
        }
    }
};

pub fn calculateMd5Checksum(data: []const u8) [16]u8
{
    var buf: [16]u8 = undefined;
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(data);
    md5.final(&buf);
    return buf;
}
