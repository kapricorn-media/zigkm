const std = @import("std");

const m = @import("zigkm").math;
const zigimg = @import("zigimg");

const android = @import("android_bindings.zig");
const assets = @import("assets.zig");
const memory = @import("memory.zig");

var _state = &@import("android_exports.zig")._state;

pub fn AssetLoader(comptime AssetsType: type) type
{
    const Loader = struct {
        assetsPtr: *AssetsType,

        const Self = @This();

        pub fn load(self: *Self, assetsPtr: *AssetsType) void
        {
            std.log.info("AssetLoader load", .{});
            self.assetsPtr = assetsPtr;
        }

        pub fn loadFontStart(self: *Self, id: u64, font: *assets.FontData, request: *const assets.FontLoadRequest) !void
        {
            var ta = memory.getTempArena(null);
            defer ta.reset();
            const a = ta.allocator();

            const pathZ = try a.dupeZ(u8, request.path);
            const assetManager = _state.*.activity.assetManager orelse return error.assetManager;
            const fontFileData = try android.loadEntireFile(pathZ, assetManager, a);

            var fontLoadData = try a.create(assets.FontLoadData);
            const grayscaleBitmap = try fontLoadData.load(request.atlasSize, fontFileData, request.size, request.scale, a);
            var image = zigimg.Image {
                .width = request.atlasSize,
                .height = request.atlasSize,
                .pixels = .{
                    .grayscale8 = @ptrCast(grayscaleBitmap)
                },
            };
            try image.flipVertically(a);

            font.atlasData = .{
                .texId = try android.loadTexture(&image, .repeat, .linear),
                .size = .{request.atlasSize, request.atlasSize},
                .canvasSize = undefined,
                .topLeft = undefined,
            };
            font.size = request.size;
            font.scale = request.scale;
            font.ascent = fontLoadData.ascent;
            font.descent = fontLoadData.descent;
            font.lineGap = fontLoadData.lineGap;
            font.lineHeight = request.lineHeight;
            font.kerning = request.kerning;

            std.mem.copyForwards(assets.FontCharData, &font.charData, &fontLoadData.charData);
            // @memcpy(&font.kbBuf, &fontLoadData.kbBuf);
            // @memcpy(std.mem.asBytes(&font.kbFont), std.mem.asBytes(&fontLoadData.kbFont));

            // Just so the font is marked as loaded
            self.assetsPtr.onLoadedFont(id, &.{
                .fontData = undefined,
            }, a);
        }

        pub fn loadFontEnd(self: *Self, id: u64, font: *assets.FontData, response: *const assets.FontLoadResponse) void
        {
            _ = self;
            _ = id;
            _ = font;
            _ = response;
        }

        pub fn loadTextureStart(self: *Self, id: u64, texture: *assets.TextureData, request: *const assets.TextureLoadRequest, priority: u32) !void
        {
            _ = priority;
            var ta = memory.getTempArena(null);
            defer ta.reset();
            const a = ta.allocator();

            const pathZ = try a.dupeZ(u8, request.path);
            const assetManager = _state.*.activity.assetManager orelse return error.assetManager;
            const imageFileData = try android.loadEntireFile(pathZ, assetManager, a);
            var image = try zigimg.Image.fromMemory(a, imageFileData);
            try image.flipVertically(a);

            texture.* = .{
                .texId = try android.loadTexture(&image, .repeat, .linear),
                .size = .{@intCast(image.width), @intCast(image.height)},
                .canvasSize = undefined,
                .topLeft = undefined,
            };

            // So the texture is marked as loaded
            self.assetsPtr.onLoadedTexture(id, &.{
                .texId = id,
                .size = texture.size,
                .canvasSize = undefined,
                .topLeft = undefined,
            });
        }

        pub fn loadTextureEnd(self: *Self, id: u64, texture: *assets.TextureData, response: *const assets.TextureLoadResponse) void
        {
            _ = self;
            _ = id;
            _ = texture;
            _ = response;
        }

        pub fn loadQueued(self: *Self, maxInflight: usize) void
        {
            _ = self;
            _ = maxInflight;
        }

        pub fn clearLoadQueue(self: *Self) void
        {
            _ = self;
        }
    };

    return Loader;
}
