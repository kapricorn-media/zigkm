const std = @import("std");
const A = std.mem.Allocator;

const m = @import("zigkm").math;
const zigimg = @import("zigimg");

pub const ImageDataFormat = enum(u8) {
    Raw       = 0,
    RLE       = 1,
    ZipNoPred = 2,
    ZipPred   = 3,
};

pub const LayerBlendMode = enum {
    Normal,
    Multiply,
};

pub const LayerChannelId = enum(i16) {
    UserMask = -2,
    Alpha    = -1,
    Red      = 0,
    Green    = 1,
    Blue     = 2,
};

pub const LayerChannelData = struct {
    id: LayerChannelId,
    dataFormat: ImageDataFormat,
    data: []const u8,
};

pub const LayerType = enum {
    other,
    group_start,
    group_end,
};

pub const LayerData = struct {
    name: []const u8,
    topLeft: m.V2i,
    size: m.V2u,
    opacity: u8,
    blendMode: ?LayerBlendMode,
    visible: bool,
    channels: []LayerChannelData,
    layerType: LayerType,

    const Self = @This();

    pub fn getPixelDataImage(self: *const Self, channel: ?LayerChannelId, topLeft: m.V2i, image: zigimg.Image, dst: m.RectU, isPsb: bool) !m.RectU
    {
        if (channel != null) {
            return error.Unsupported;
        }

        const imageSize = m.V2u{@intCast(image.width), @intCast(image.height)};
        if (dst.max[0] > imageSize[0] or dst.max[1] > imageSize[1]) {
            return error.OutOfBounds;
        }

        const topLeftMax = @max(topLeft, self.topLeft);// m.max(topLeft, self.topLeft);
        const layerTopLeft: m.V2u = @intCast(topLeftMax - self.topLeft);//).toVec2usize();
        if (layerTopLeft[0] >= self.size[0] or layerTopLeft[1] >= self.size[1]) {
            return error.OutOfBounds;
        }

        const srcSizeCapped = @min(dst.size(), self.size - layerTopLeft);
        const dstTopLeftOffset: m.V2u = @intCast(@max(topLeftMax - topLeft, m.V2i{0, 0}));
        const dstTopLeft = dst.min + dstTopLeftOffset;
        std.debug.assert(dstTopLeft[0] <= imageSize[0] and dstTopLeft[1] <= imageSize[1]);
        const dstSizeCapped = @min(srcSizeCapped, imageSize - dstTopLeft);
        const src = m.RectU.init(layerTopLeft, dstSizeCapped);
        const dstAdjusted = m.RectU.init(dst.min + dstTopLeftOffset, dstSizeCapped);

        for (self.channels) |c| {
            if (channel) |cc| {
                if (cc != c.id) {
                    continue;
                }
            }

            const channelOffset: usize = blk: {
                if (channel == null) {
                    break :blk switch (c.id) {
                        .Red => 0,
                        .Green => 1,
                        .Blue => 2,
                        .Alpha => 3,
                        else => continue,
                    };
                } else {
                    break :blk 0;
                }
            };

            switch (c.dataFormat) {
                .Raw => readPixelDataRaw(c.data, self.size, src, image, dstAdjusted, channelOffset),
                .RLE => try readPixelDataLRE(c.data, self.size, src, image, dstAdjusted, channelOffset, isPsb),
                else => return error.UnsupportedDataFormat,
            }
        }

        return dstAdjusted;
    }

    pub fn getPixelDataCanvasSize(self: *const Self, channel: ?LayerChannelId, canvasSize: m.V2u, a: A) !zigimg.Image
    {
        const topLeft = m.max(self.topLeft, m.V2i{0, 0});
        const bottomRight = m.min(m.add(self.topLeft, self.size.toVec2i()), canvasSize.toVec2i());
        if (bottomRight.x <= 0 and bottomRight.y <= 0) {
            return zigimg.Image {
                .a = undefined,
                .width = 0,
                .height = 0,
            };
        }
        const size = m.sub(bottomRight.toVec2usize(), topLeft.toVec2usize());
        var image = try zigimg.Image.create(a, size.x, size.y, .rgba32);
        std.mem.set(u8, image.pixels.asBytes(), 0);
        const dst = m.RectU.init(m.V2u{0, 0}, size);
        const result = try self.getPixelDataImage(channel, topLeft, image, dst);
        _ = result;
        return image;
    }

    pub fn getPixelData(self: *const Self, channel: ?LayerChannelId, isPsb: bool, a: A) !zigimg.Image
    {
        const image = try zigimg.Image.create(a, self.size[0], self.size[1], .rgba32);
        const dst = m.RectU.init(m.V2u{0, 0}, self.size);
        const result = try self.getPixelDataImage(channel, self.topLeft, image, dst, isPsb);
        std.debug.assert(std.meta.eql(dst, result));
        return image;
    }

    pub fn isGroupEnd(self: *const Self) bool
    {
        return self.name.len >= 3 and self.name[0] == '<' and self.name[1] == '/' and self.name[self.name.len - 1] == '>';
    }
};

pub const PsdFile = struct {
    a: A,
    isPsb: bool,
    canvasSize: m.V2u,
    data: []const u8,
    layers: []LayerData,

    const Self = @This();

    pub fn load(self: *Self, data: []const u8, a: A) !void
    {
        self.a = a;
        self.data = data;

        var reader = Reader.init(data);

        // section: header
        const HeaderRaw = extern struct {
            signature: [4]u8,
            version: [2]u8,
            reserved: [6]u8,
            channels: [2]u8,
            height: [4]u8,
            width: [4]u8,
            depth: [2]u8,
            colorMode: [2]u8,
        };
        comptime {
            std.debug.assert(@sizeOf(HeaderRaw) == 4 + 2 + 6 + 2 + 4 + 4 + 2 + 2);
        }

        const Header = struct {
            signature: [4]u8,
            version: u16,
            reserved: [6]u8,
            channels: u16,
            height: u32,
            width: u32,
            depth: u16,
            colorMode: u16,
        };

        const headerRaw = try reader.readStruct(HeaderRaw);
        var header = Header {
            .signature = headerRaw.signature,
            .version = std.mem.readInt(u16, &headerRaw.version, .big),
            .reserved = headerRaw.reserved,
            .channels = std.mem.readInt(u16, &headerRaw.channels, .big),
            .height = std.mem.readInt(u32, &headerRaw.height, .big),
            .width = std.mem.readInt(u32, &headerRaw.width, .big),
            .depth = std.mem.readInt(u16, &headerRaw.depth, .big),
            .colorMode = std.mem.readInt(u16, &headerRaw.colorMode, .big),
        };

        if (!std.mem.eql(u8, &header.signature, "8BPS")) {
            return error.InvalidSignature;
        }

        if (header.version != 1 and header.version != 2) {
            return error.InvalidVersion;
        }
        self.isPsb = header.version == 2;
        if (header.depth != 8) {
            return error.UnsupportedColorDepth;
        }

        const colorModeRgb = 3;
        if (header.colorMode != colorModeRgb) {
            return error.UnsupportedColorMode;
        }

        self.canvasSize = m.V2u {header.width, header.height};

        // section: color mode data
        const colorModeData = try reader.readLengthAndBytes(u32);
        _ = colorModeData;

        // section: image resources
        const imageResources = try reader.readLengthAndBytes(u32);
        _ = imageResources;

        // section: layer and mask information
        const layerMaskInfoIndexBefore = reader.index;
        const layerMaskInfo = if (self.isPsb) try reader.readLengthAndBytes(u64) else try reader.readLengthAndBytes(u32);
        if (layerMaskInfo.len > 0) {
            var layerMaskInfoReader = Reader.init(layerMaskInfo);
            const layersInfoLength: u64 = if (self.isPsb) try layerMaskInfoReader.readInt(u64) else try layerMaskInfoReader.readInt(u32);
            _ = layersInfoLength;

            const layerCountSigned = try layerMaskInfoReader.readInt(i16);
            const layerCount: u32 = if (layerCountSigned < 0) @intCast(-layerCountSigned) else @intCast(layerCountSigned);
            self.layers = try a.alloc(LayerData, layerCount);

            for (self.layers) |*layer| {
                const top = try layerMaskInfoReader.readInt(i32);
                const left = try layerMaskInfoReader.readInt(i32);
                const bottom = try layerMaskInfoReader.readInt(i32);
                const right = try layerMaskInfoReader.readInt(i32);
                layer.topLeft = m.V2i{left, top};
                layer.size = m.V2u{@intCast(right - left), @intCast(bottom - top)};

                const channels = try layerMaskInfoReader.readInt(u16);
                layer.channels = try a.alloc(LayerChannelData, channels);
                for (layer.channels) |*c| {
                    const idInt = try layerMaskInfoReader.readInt(i16);
                    const size: u64 = if (self.isPsb) try layerMaskInfoReader.readInt(u64) else try layerMaskInfoReader.readInt(u32);
                    const id = std.meta.intToEnum(LayerChannelId, idInt) catch |err| {
                        std.log.err("Unknown channel ID {}", .{idInt});
                        return err;
                    };
                    if (size < @sizeOf(u16)) {
                        return error.BadChannelSize;
                    }
                    c.* = LayerChannelData {
                        .id = id,
                        .dataFormat = .Raw,
                        .data = undefined,
                    };
                    c.data.len = size - @sizeOf(u16); // data minus compression ID
                }

                const LayerMaskData2 = extern struct {
                    blendModeSignature: [4]u8,
                    blendModeKey: [4]u8,
                    opacity: u8,
                    clipping: u8,
                    flags: u8,
                    zero: u8,
                };

                const layerMaskData2 = try layerMaskInfoReader.readStruct(LayerMaskData2);
                if (!std.mem.eql(u8, &layerMaskData2.blendModeSignature, "8BIM")) {
                    return error.InvalidBlendModeSignature;
                }
                layer.opacity = layerMaskData2.opacity;
                layer.blendMode = stringToBlendMode(&layerMaskData2.blendModeKey);
                layer.visible = (layerMaskData2.flags & 0b00000010) == 0;

                layer.name = "";
                layer.layerType = .other;
                const extraData = try layerMaskInfoReader.readLengthAndBytes(u32);
                if (extraData.len > 0) {
                    var extraDataReader = Reader.init(extraData);
                    const maskAdjustmentData = try extraDataReader.readLengthAndBytes(u32);
                    _ = maskAdjustmentData;
                    const blendRangeData = try extraDataReader.readLengthAndBytes(u32);
                    _ = blendRangeData;
                    layer.name = try extraDataReader.readPascalString();

                    extraDataReader.index = nextMultipleOf4(extraDataReader.index);
                    while (extraDataReader.remainingBytes().len > 0) {
                        const signature = try extraDataReader.readBytes(4);
                        if (!std.mem.eql(u8, &signature, "8BIM") and !std.mem.eql(u8, &signature, "8B64")) {
                            return error.BadLayerInfo;
                        }
                        const key = try extraDataReader.readBytes(4);
                        const additionalData = try extraDataReader.readLengthAndBytes(u32);
                        var additionalDataReader = Reader.init(additionalData);
                        if (std.mem.eql(u8, &key, "lsct")) {
                            const layerType = try additionalDataReader.readInt(u32);
                            if (layerType == 1 or layerType == 2) {
                                layer.layerType = .group_start;
                            } else if (layerType == 3) {
                                layer.layerType = .group_end;
                            }
                        }
                    }
                }
            }

            for (self.layers) |*layer| {
                for (layer.channels) |*c| {
                    const formatInt = try layerMaskInfoReader.readInt(i16);
                    const format = std.meta.intToEnum(ImageDataFormat, formatInt) catch |err| {
                        std.log.err("Unknown data format {}", .{formatInt});
                        return err;
                    };
                    c.dataFormat = format;
                    const dataStart = layerMaskInfoIndexBefore + @as(u64, if (self.isPsb) @sizeOf(u64) else @sizeOf(u32)) + layerMaskInfoReader.index;
                    const dataEnd = dataStart + c.data.len;
                    c.data = data[dataStart..dataEnd];

                    if (!layerMaskInfoReader.hasRemaining(c.data.len)) {
                        return error.OutOfBounds;
                    }
                    layerMaskInfoReader.index += c.data.len;
                }
            }
        }

        // section: image data
        const imageData = reader.remainingBytes();
        _ = imageData;
    }

    pub fn deinit(self: *Self) void
    {
        for (self.layers) |layer| {
            self.a.free(layer.channels);
        }
        self.a.free(self.layers);
    }
};

fn readPixelDataRaw(
    data: []const u8,
    layerSize: m.V2u,
    src: m.RectU,
    image: zigimg.Image,
    dst: m.RectU,
    channelOffset: usize) void
{
    std.debug.assert(image.pixels == .rgba32);
    std.debug.assert(@reduce(.And, src.size() == dst.size()));
    std.debug.assert(src.max[0] <= layerSize[0] and src.max[1] <= layerSize[1]);

    const srcSize = src.size();
    var y: usize = 0;
    while (y < srcSize[1]) : (y += 1) {
        const yIn = src.min[1] + y;
        const yOut = dst.min[1] + y;

        var x: usize = 0;
        while (x < srcSize[0]) : (x += 1) {
            const xIn = src.min[0] + x;
            const xOut = dst.min[0] + x;

            const inIndex = yIn * layerSize[0] + xIn;
            const outIndex = yOut * image.width + xOut;
            const pixelPtr = &image.pixels.rgba32[outIndex];
            var pixelPtrBytes = @as(*[4]u8, @ptrCast(pixelPtr));
            pixelPtrBytes[channelOffset] = data[inIndex];
        }
    }
}

fn readRowLength(comptime IntType: type, rowLengths: []const u8, row: usize) IntType
{
    const ptr: *const [@sizeOf(IntType)]u8 = @ptrCast(&rowLengths[row * @sizeOf(IntType)]);
    return std.mem.readInt(IntType, ptr, .big);
}

fn readPixelDataLRE(
    data: []const u8,
    layerSize: m.V2u,
    src: m.RectU,
    image: zigimg.Image,
    dst: m.RectU,
    channelOffset: usize,
    isPsb: bool) !void
{
    std.debug.assert(image.pixels == .rgba32);
    std.debug.assert(@reduce(.And, src.size() == dst.size()));
    std.debug.assert(src.max[0] <= layerSize[0] and src.max[1] <= layerSize[1]);

    const rowLengthsN = layerSize[1] * @as(u32, if (isPsb) 4 else 2);
    if (rowLengthsN > data.len) {
        return error.OutOfBounds;
    }
    const rowLengths = data[0..rowLengthsN];

    var remaining = data[rowLengthsN..];
    var y: usize = 0;
    while (y < layerSize[1]) : (y += 1) {
        const rowLength = if (isPsb) readRowLength(u32, rowLengths, y) else readRowLength(u16, rowLengths, y);
        const rowData = remaining[0..rowLength];
        remaining = remaining[rowLength..];

        if (y < src.min[1] or y >= src.max[1]) continue;
        const yOut = y - src.min[1] + dst.min[1];

        // Parse data in PackBits format
        // https://en.wikipedia.org/wiki/PackBits
        var x: usize = 0;
        var rowInd: usize = 0;
        while (true) {
            if (rowInd >= rowData.len) {
                break;
            }
            const header = @as(i8, @bitCast(rowData[rowInd]));
            rowInd += 1;

            if (header == -128) {
                continue;
            } else if (header < 0) {
                if (rowInd >= rowData.len) {
                    return error.BadRowData;
                }
                const byte = rowData[rowInd];
                rowInd += 1;
                const repeats: i32 = 1 - @as(i32, @intCast(header));
                var i: usize = 0;
                while (i < repeats) : ({i += 1; x += 1;}) {
                    if (x < src.min[0] or x >= src.max[0]) continue;
                    const xOut = x - src.min[0] + dst.min[0];
                    const outIndex = yOut * image.width + xOut;

                    const pixelPtr = &image.pixels.rgba32[outIndex];
                    var pixelPtrBytes = @as(*[4]u8, @ptrCast(pixelPtr));
                    pixelPtrBytes[channelOffset] = byte;
                    // * buf.channels + channelOffset;
                    // buf.data[outIndex] = byte;
                }
            } else if (header >= 0) {
                const n: u32 = 1 + @as(u32, @intCast(header));
                if (rowInd + n > rowData.len) {
                    return error.BadRowData;
                }

                var i: usize = 0;
                while (i < n) : ({i += 1; x += 1;}) {
                    const byte = rowData[rowInd + i];
                    if (x < src.min[0] or x >= src.max[0]) continue;
                    const xOut = x - src.min[0] + dst.min[0];
                    const outIndex = yOut * image.width + xOut;

                    const pixelPtr = &image.pixels.rgba32[outIndex];
                    var pixelPtrBytes = @as(*[4]u8, @ptrCast(pixelPtr));
                    pixelPtrBytes[channelOffset] = byte;
                    // * buf.channels + channelOffset;
                    // buf.data[outIndex] = byte;
                }
                rowInd += n;
            }
        }

        if (x != layerSize[0]) {
            std.log.err("row width mismatch x={} layerSize.x={}", .{x, layerSize[0]});
            return error.RowWidthMismatch;
        }
    }
}

fn stringToBlendMode(str: []const u8) ?LayerBlendMode
{
    const map = std.StaticStringMap(LayerBlendMode).initComptime(.{
        .{ "norm", .Normal },
        .{ "mul ", .Multiply },
    });
    return map.get(str);
}

fn nextMultipleOf4(n: usize) usize
{
    return (n + 3) & ~@as(usize, 3);
}

const Reader = struct {
    data: []const u8,
    index: usize,

    const Self = @This();

    fn init(data: []const u8) Self
    {
        return Self {
            .data = data,
            .index = 0,
        };
    }

    fn remainingBytes(self: *const Self) []const u8
    {
        std.debug.assert(self.index <= self.data.len);
        return self.data[self.index..];
    }

    fn hasRemaining(self: *const Self, size: usize) bool
    {
        return self.index + size <= self.data.len;
    }

    fn readStruct(self: *Self, comptime T: type) !*const T
    {
        std.debug.assert(@typeInfo(T) == .@"struct");

        const size = @sizeOf(T);
        if (!self.hasRemaining(size)) {
            return error.OutOfBounds;
        }

        const ptr = @as(*const T, @ptrCast(&self.data[self.index]));
        self.index += size;
        return ptr;
    }

    fn readBytes(self: *Self, comptime N: usize) ![N]u8
    {
        if (!self.hasRemaining(N)) {
            return error.OutOfBounds;
        }
        var result: [N]u8 = undefined;
        @memcpy(&result, self.data[self.index..self.index + N]);
        self.index += N;
        return result;
    }

    fn readInt(self: *Self, comptime T: type) !T
    {
        const size = @sizeOf(T);
        if (!self.hasRemaining(size)) {
            return error.OutOfBounds;
        }

        const ptr: *const [size]u8 = @ptrCast(&self.data[self.index]);
        const value = std.mem.readInt(T, ptr, .big);
        self.index += size;
        return value;
    }

    fn readLengthAndBytes(self: *Self, comptime LengthType: type) ![]const u8
    {
        const length = try self.readInt(LengthType);
        if (!self.hasRemaining(length)) {
            return error.OutOfBounds;
        }
        const end = self.index + length;
        const slice = self.data[self.index..end];
        self.index = end;
        return slice;
    }

    fn readPascalString(self: *Self) ![]const u8
    {
        return self.readLengthAndBytes(u8);
    }
};

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fileReadBuf: [4 * 1024]u8 = undefined;
    var fileBuf = try a.alloc(u8, 512 * 1024 * 1024);

    // const psdBytes = @embedFile("test.psd");
    // const filePath = "data/sprites/test.psd";
    // const filePath = "data/sprites/coral_region.psb";
    const filePath = "data/sprites/characters.psd";
    var f = try std.fs.cwd().openFile(filePath, .{});
    defer f.close();
    var fr = f.reader(&fileReadBuf);
    const fLen = try fr.interface.readSliceShort(fileBuf);
    const psdBytes = fileBuf[0..fLen];

    var psd: PsdFile = undefined;
    try psd.load(psdBytes, a);

    std.log.info("{} x {} | {} layers", .{psd.canvasSize[0], psd.canvasSize[1], psd.layers.len});
    for (psd.layers, 0..) |layer, i| {
        std.log.info("layer {}: {s} ({} at {})", .{i, layer.name, layer.size, layer.topLeft});
        if (layer.isGroupEnd()) {
            std.log.info("group end", .{});
        } else {
            if (layer.size[0] != 0 and layer.size[1] != 0) {
                const pixels = try layer.getPixelData(null, psd.isPsb, a);
                std.log.info("pixel data {} x {}", .{pixels.width, pixels.height});
            }
        }
    }
}
