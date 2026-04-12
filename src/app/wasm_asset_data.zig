const std = @import("std");

const zkm = @import("zigkm");
const m = zkm.math;

const assets = @import("assets.zig");
const w = @import("wasm_bindings.zig");

const TextureLoadEntry = struct {
    id: u64,
    request: assets.TextureLoadRequest,
    priority: u32,
};

pub fn AssetLoader(comptime AssetsType: type) type
{
    const Loader = struct {
        textureLoadEntries: zkm.BoundedArray(TextureLoadEntry, 1024),
        textureLoadsInflight: usize,

        const Self = @This();

        pub fn load(self: *Self, assetsPtr: *AssetsType) void
        {
            _ = assetsPtr;
            self.textureLoadEntries.len = 0;
            self.textureLoadsInflight = 0;
        }

        pub fn loadFontStart(self: *Self, id: u64, font: *assets.FontData, request: *const assets.FontLoadRequest) !void
        {
            _ = self;

            font.atlasData = .{
                .texId = w.loadFontDataJs(@intCast(id), &request.path[0], request.path.len, request.size, request.scale, @intCast(request.atlasSize)),
                .size = .{request.atlasSize, request.atlasSize},
                .canvasSize = .{0, 0},
                .topLeft = .{0, 0},
            };
            font.size = request.size;
            font.scale = request.scale;
            font.kerning = request.kerning;
            font.lineHeight = request.lineHeight;
        }

        pub fn loadFontEnd(self: *Self, id: u64, font: *assets.FontData, response: *const assets.FontLoadResponse) void
        {
            _ = self;
            _ = id;

            std.debug.assert(font.size == response.fontData.size);
            std.mem.copyForwards(assets.FontCharData, &font.charData, &response.fontData.charData);
            // @memcpy(&font.kbBuf, &response.fontData.kbBuf);
            // @memcpy(std.mem.asBytes(&font.kbFont), std.mem.asBytes(&response.fontData.kbFont));
            font.ascent = response.fontData.ascent;
            font.descent = response.fontData.descent;
            font.lineGap = response.fontData.lineGap;
        }

        pub fn loadTextureStart(self: *Self, id: u64, texture: *assets.TextureData, request: *const assets.TextureLoadRequest, priority: u32) !void
        {
            _ = texture;
            const loadEntry = try self.textureLoadEntries.addOne();
            loadEntry.* = .{
                .id = id,
                .request = request.*,
                .priority = priority,
            };
        }

        pub fn loadTextureEnd(self: *Self, id: u64, texture: *assets.TextureData, response: *const assets.TextureLoadResponse) void
        {
            _ = id;
            texture.texId = response.texId;
            texture.size = response.size;
            texture.canvasSize = response.canvasSize;
            texture.topLeft = response.topLeft;
            std.debug.assert(self.textureLoadsInflight > 0);
            self.textureLoadsInflight -= 1;
        }

        pub fn loadQueued(self: *Self, maxInflight: usize) void
        {
            const maxToLoad = if (maxInflight > self.textureLoadsInflight) maxInflight - self.textureLoadsInflight else 0;
            const numToLoad = @min(maxToLoad, self.textureLoadEntries.len);

            var i: usize = 0;
            while (i < numToLoad) : (i += 1) {
                // Choose highest-priority entry to load
                var entryIndex: usize = 0;
                const loadEntries = self.textureLoadEntries.slice();
                for (loadEntries, 0..) |entry, j| {
                    if (entry.priority < loadEntries[entryIndex].priority) {
                        entryIndex = j;
                    }
                }

                // Load chosen highest-priority entry and remove from the array
                const entry = self.textureLoadEntries.orderedRemove(entryIndex);
                const texId = w.glCreateTexture();
                w.loadTexture(
                    @intCast(entry.id), texId,
                    &entry.request.path[0], entry.request.path.len,
                    textureWrapModeToWebgl(entry.request.wrapMode),
                    textureFilterToWebgl(entry.request.filter)
                );
                self.textureLoadsInflight += 1;
            }
        }

        pub fn clearLoadQueue(self: *Self) void
        {
            self.textureLoadEntries.len = 0;
        }
    };

    return Loader;
}

fn textureFilterToWebgl(filter: assets.TextureFilter) c_uint
{
    return switch (filter) {
        .linear => w.GL_LINEAR,
        .nearest => w.GL_NEAREST,
    };
}

fn textureWrapModeToWebgl(wrapMode: assets.TextureWrapMode) c_uint
{
    return switch (wrapMode) {
        .clampToEdge => w.GL_CLAMP_TO_EDGE,
        .repeat => w.GL_REPEAT,
    };
}
