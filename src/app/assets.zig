const std = @import("std");
const A = std.mem.Allocator;

// const kb = @import("zigkm-kb");
const m = @import("zigkm-math");
const stb = @import("zigkm-stb");
const platform = @import("zigkm-platform");
const zigimg = @import("zigimg");

const platform_asset_data = switch (platform.platform) {
    .android => @import("android_asset_data.zig"),
    .ios => @import("ios_asset_data.zig"),
    .web => @import("wasm_asset_data.zig"),
    .server => unreachable,
};

pub const TextureWrapMode = enum {
    clampToEdge,
    repeat,
};

pub const TextureFilter = enum {
    linear,
    nearest,
};

pub const TextureLoadRequest = struct {
    path: []const u8,
    filter: TextureFilter,
    wrapMode: TextureWrapMode,
};

pub const TextureLoadResponse = struct {
    texId: u64,
    size: m.V2u,
    // Only used for .layer "images" (PSD layers).
    canvasSize: m.V2u,
    topLeft: m.V2i,
};

pub const TextureData = struct {
    texId: u64,
    size: m.V2u,
    // Only used for .layer "images" (PSD layers).
    canvasSize: m.V2u,
    topLeft: m.V2i,
};

pub const FontLoadRequest = struct {
    path: []const u8,
    atlasSize: u32,
    size: f32,
    scale: f32,
    lineHeight: f32,
    kerning: f32,
};

pub const FontLoadResponse = struct {
    fontData: *const FontLoadData,
};

pub const FontCharData = struct {
    offset: m.V2,
    size: m.V2,
    uvOffset: m.V2,
    advanceX: f32,
};

pub const FontLoadData = struct {
    size: f32,
    scale: f32,
    ascent: f32,
    descent: f32,
    lineGap: f32,
    charData: [256]FontCharData,
    // kbBuf: [256 * 1024]u8,
    // kbFont: kb.kbts_font,

    const Self = @This();

    pub fn load(self: *Self, atlasSize: usize, fontFileData: []const u8, size: f32, scale: f32, a: A) ![]u8
    {
        var tempArena = std.heap.ArenaAllocator.init(a);
        defer tempArena.deinit();
        var tempAllocator = tempArena.allocator();

        const fontFileDataCopy = try tempAllocator.dupe(u8, fontFileData);
        _ = fontFileDataCopy;

        self.size = size;
        self.scale = scale;

        var fontInfo: stb.c.stbtt_fontinfo = undefined;
        if (stb.c.stbtt_InitFont(&fontInfo, &fontFileData[0], 0) == 0) {
            return error.stbtt_InitFont;
        }
        const stbScale = stb.c.stbtt_ScaleForMappingEmToPixels(&fontInfo, size / self.scale);

        var ascent: c_int = undefined;
        var descent: c_int = undefined;
        var lineGap: c_int = undefined;
        stb.c.stbtt_GetFontVMetrics(&fontInfo, &ascent, &descent, &lineGap);
        self.ascent = @as(f32, @floatFromInt(ascent)) * stbScale;
        self.descent = @as(f32, @floatFromInt(descent)) * stbScale;
        self.lineGap = @as(f32, @floatFromInt(lineGap)) * stbScale;

        const width = atlasSize;
        const height = atlasSize;
        var pixelBytes = try a.alloc(u8, width * height);
        @memset(pixelBytes, 0);
        var context: stb.c.stbtt_pack_context = undefined;
        if (stb.c.stbtt_PackBegin(&context, &pixelBytes[0], @intCast(width), @intCast(height), @intCast(width), 1, &tempAllocator) != 1) {
            return error.stbtt_PackBegin;
        }
        const oversampleN = 1;
        stb.c.stbtt_PackSetOversampling(&context, oversampleN, oversampleN);

        var charData = try tempAllocator.alloc(stb.c.stbtt_packedchar, self.charData.len);
        if (stb.c.stbtt_PackFontRange(&context, &fontFileData[0], 0, stb.c.STBTT_POINT_SIZE(size / scale), 0, @intCast(charData.len), &charData[0]) != 1) {
            return error.stbtt_PackFontRange;
        }

        stb.c.stbtt_PackEnd(&context);

        for (charData, 0..) |cd, i| {
            const sizeF: m.V2 = @floatFromInt(m.V2i{cd.x1 - cd.x0, cd.y1 - cd.y0});
            self.charData[i] = FontCharData {
                .offset = .{cd.xoff, -(sizeF[1] + cd.yoff)},
                .size = sizeF,
                .uvOffset = .{
                    @as(f32, @floatFromInt(cd.x0)) / @as(f32, @floatFromInt(width)),
                    @as(f32, @floatFromInt(height - cd.y1)) / @as(f32, @floatFromInt(height)), // TODO should do -1 ?
                },
                .advanceX = cd.xadvance,
            };
        }

        // const alignment = 8;
        // @memset(std.mem.asBytes(&self.kbFont), 0);
        // const scratchSize = kb.kbts_ReadFontHeader(&self.kbFont, fontFileDataCopy.ptr, fontFileDataCopy.len);
        // const scratch = try tempAllocator.allocWithOptions(u8, @intCast(scratchSize), alignment, null);
        // const permSize = kb.kbts_ReadFontData(&self.kbFont, scratch.ptr, scratch.len);
        // if (permSize > self.kbBuf.len) {
        //     std.log.err("kb_text_shape font too big permSize={}", .{permSize});
        //     return error.kbts_fail;
        // }
        // _ = kb.kbts_PostReadFontInitialize(&self.kbFont, &self.kbBuf[0], permSize);
        // if (kb.kbts_FontIsValid(&self.kbFont) == 0) {
        //     std.log.err("kb_text_shape font read failed err={}", .{self.kbFont.Error});
        // }

        return pixelBytes;
    }
};

pub const FontData = struct {
    atlasData: TextureData,
    size: f32,
    scale: f32,
    ascent: f32,
    descent: f32,
    lineGap: f32,
    lineHeight: f32,
    kerning: f32,
    charData: [256]FontCharData,
    // kbBuf: [256 * 1024]u8,
    // kbFont: kb.kbts_font,
};

pub const AssetLoadState = enum {
    free,
    loading,
    loaded,
};

pub fn AssetsWithIds(comptime FontEnum: type, comptime TextureEnum: type) type
{
    const maxFonts = @typeInfo(FontEnum).@"enum".fields.len;
    const maxTextures = @typeInfo(TextureEnum).@"enum".fields.len;

    const FontId = FontEnum;
    const TextureId = TextureEnum;

    const T = struct {
        assets: Assets(maxFonts, maxTextures),

        const Self = @This();

        pub fn load(self: *Self) !void
        {
            self.assets.load();
        }

        pub fn getFontData(self: *const Self, id: FontId) ?*const FontData
        {
            return self.assets.getFontData(getFontId(id));
        }

        pub fn getFontLoadState(self: *const Self, id: FontId) AssetLoadState
        {
            return self.assets.getFontLoadState(getFontId(id));
        }

        pub fn getTextureData(self: *const Self, id: TextureId) ?*const TextureData
        {
            const theId = getTextureId(id);
            return self.assets.getTextureData(theId);
        }

        pub fn getTextureLoadState(self: *const Self, id: TextureId) AssetLoadState
        {
            const theId = getTextureId(id);
            return self.assets.getTextureLoadState(theId);
        }

        pub fn loadFont(self: *Self, id: FontId, request: *const FontLoadRequest) !void
        {
            const theId = getFontId(id);
            const newId = try self.assets.loadFont(theId, request);
            std.debug.assert(theId == newId);
        }

        pub fn onLoadedFont(self: *Self, id: u64, response: *const FontLoadResponse, a: A) void
        {
            self.assets.onLoadedFont(id, response, a);
        }

        pub fn loadTexture(self: *Self, id: TextureId, request: *const TextureLoadRequest) !void
        {
            return self.loadTexturePriority(id, request, 0);
        }

        pub fn loadTexturePriority(self: *Self, id: TextureId, request: *const TextureLoadRequest, priority: u32) !void
        {
            const theId = getTextureId(id);
            const newId = try self.assets.loadTexturePriority(theId, request, priority);
            std.debug.assert(theId == newId);
        }

        pub fn onLoadedTexture(self: *Self, id: u64, response: *const TextureLoadResponse) void
        {
            self.assets.onLoadedTexture(id, response);
        }

        pub fn loadQueued(self: *Self, maxInflight: usize) void
        {
            self.assets.loadQueued(maxInflight);
        }

        pub fn clearLoadQueue(self: *Self) void
        {
            self.assets.clearLoadQueue();
        }

        fn getFontId(id: FontId) u64
        {
            return @intFromEnum(id);
        }

        fn getTextureId(id: TextureId) u64
        {
            return @intFromEnum(id);
        }
    };

    return T;
}

pub fn Assets(comptime maxFonts: usize, comptime maxTextures: usize) type
{
    std.debug.assert(maxFonts <= std.math.maxInt(u32));
    std.debug.assert(maxTextures <= std.math.maxInt(u32));

    const T = struct {
        loader: platform_asset_data.AssetLoader(Self),
        fonts: [maxFonts]AssetWrapper(FontData),
        textures: [maxTextures]AssetWrapper(TextureData),

        const Self = @This();

        pub fn load(self: *Self) void
        {
            self.loader.load(self);
            for (&self.fonts) |*f| {
                f.state = .free;
            }
            for (&self.textures) |*t| {
                t.state = .free;
            }
        }

        pub fn getFontData(self: *const Self, id: u64) ?*const FontData
        {
            const wrapper = &self.fonts[@intCast(id)];
            if (wrapper.state != .loaded) {
                return null;
            }
            return &wrapper.t;
        }

        pub fn getFontLoadState(self: *const Self, id: u64) AssetLoadState
        {
            const wrapper = &self.fonts[@intCast(id)];
            return wrapper.state;
        }

        pub fn getTextureData(self: *const Self, id: u64) ?*const TextureData
        {
            const wrapper = &self.textures[@intCast(id)];
            if (wrapper.state != .loaded) {
                return null;
            }
            return &wrapper.t;
        }

        pub fn getTextureLoadState(self: *const Self, id: u64) AssetLoadState
        {
            const wrapper = &self.textures[@intCast(id)];
            return wrapper.state;
        }

        pub fn loadFont(self: *Self, id: ?u64, request: *const FontLoadRequest) !u64
        {
            const newId = id orelse getUnusedId(FontData, &self.fonts) orelse return error.FontsFull;
            const newIndex = @as(usize, @intCast(newId));
            self.fonts[newIndex].state = .loading;
            try self.loader.loadFontStart(newId, &self.fonts[newIndex].t, request);
            return newId;
        }

        pub fn onLoadedFont(self: *Self, id: u64, response: *const FontLoadResponse, a: A) void
        {
            _ = a;
            const index = @as(usize, @intCast(id));
            std.debug.assert(index < self.fonts.len);
            std.debug.assert(self.fonts[index].state == .loading);
            self.loader.loadFontEnd(id, &self.fonts[index].t, response);
            self.fonts[index].state = .loaded;
        }

        // Loads on the requested id's slot if not null (replaces existing texture).
        // Otherwise gets the next free id, starting from the end of the texture list.
        pub fn loadTexturePriority(self: *Self, id: ?u64, request: *const TextureLoadRequest, priority: u32) !u64
        {
            const newId = id orelse getUnusedId(TextureData, &self.textures) orelse return error.TexturesFull;
            const newIndex = @as(usize, @intCast(newId));
            self.textures[newIndex].state = .loading;
            try self.loader.loadTextureStart(newId, &self.textures[newIndex].t, request, priority);
            return newId;
        }

        pub fn onLoadedTexture(self: *Self, id: u64, response: *const TextureLoadResponse) void
        {
            const index = @as(usize, @intCast(id));
            std.debug.assert(index < self.textures.len);
            std.debug.assert(self.textures[index].state == .loading);

            if (response.size[0] != 0 and response.size[1] != 0) {
                self.loader.loadTextureEnd(id, &self.textures[index].t, response);
                self.textures[index].state = .loaded;
            }
        }

        pub fn loadQueued(self: *Self, maxInflight: usize) void
        {
            self.loader.loadQueued(maxInflight);
        }

        pub fn clearLoadQueue(self: *Self) void
        {
            self.loader.clearLoadQueue();
        }
    };

    return T;
}

fn AssetWrapper(comptime T: type) type
{
    const Wrapper = struct {
        t: T,
        state: AssetLoadState,
    };
    return Wrapper;
}

fn getUnusedId(comptime T: type, values: []const AssetWrapper(T)) ?u64
{
    var n: usize = values.len;
    while (n != 0) : (n -= 1) {
        const ind = n - 1;
        if (values[ind].state == .free) {
            return ind;
        }
    }
    return null;
}
