const std = @import("std");

const zkm = @import("zigkm");
const m = zkm.math;
const platform = @import("zigkm-platform");

const assets = @import("assets.zig");
const memory = @import("memory.zig");
const platform_render = switch (platform.platform) {
    .android => @import("android_render.zig"),
    .ios => @import("ios_render.zig"),
    .web => @import("wasm_render.zig"),
    else => unreachable,
};

pub const RenderState = platform_render.RenderState;

pub const GlyphIterator = @import("render_text.zig").GlyphIterator;
// pub const utf8ToGlyphs = @import("render_text.zig").utf8ToGlyphs;
pub const textRect = @import("render_text.zig").textRect;

const DirtyStuff = struct {
    offset: m.V2,
    scale: m.V2,
    anchor: m.V2,
};

pub const RenderQueue = struct {
    pub const EntryQuad = RenderEntryQuad;

    quads: zkm.BoundedArray(RenderEntryQuad, platform_render.MAX_QUADS),
    textureIds: zkm.BoundedArray(u64, platform_render.MAX_TEXTURES),
    dirtyStuff: ?DirtyStuff,

    const Self = @This();

    pub fn clear(self: *Self) void
    {
        self.quads.len = 0;
        self.textureIds.len = 1;
        self.textureIds.buffer[0] = 0;
        self.dirtyStuff = null;
    }

    pub fn setOffsetScaleAnchor(self: *Self, offset: m.V2, scale: m.V2, anchor: m.V2) void
    {
        self.dirtyStuff = .{
            .offset = offset,
            .scale = scale,
            .anchor = anchor,
        };
    }

    pub fn quad(
        self: *Self,
        bottomLeft: m.V2,
        size: m.V2,
        depth: f32,
        cornerRadius: f32,
        color: m.V4) void
    {
        self.quadGradient(
            bottomLeft,
            size,
            depth,
            cornerRadius,
            [4]m.V4 {color, color, color, color}
        );
    }

    pub fn quadGradient(
        self: *Self,
        bottomLeft: m.V2,
        size: m.V2,
        depth: f32,
        cornerRadius: f32,
        colors: [4]m.V4) void
    {
        self.quad2(bottomLeft, size, depth, cornerRadius, m.zero(2), m.one(2), 0, m.zero(4), null, colors);
    }

    pub fn texQuad(
        self: *Self,
        bottomLeft: m.V2,
        size: m.V2,
        depth: f32,
        cornerRadius: f32,
        textureData: *const assets.TextureData) void
    {
        self.texQuadColor(bottomLeft, size, depth, cornerRadius, textureData, m.COLOR_WHITE);
    }

    pub fn texQuadColor(
        self: *Self,
        bottomLeft: m.V2,
        size: m.V2,
        depth: f32,
        cornerRadius: f32,
        textureData: *const assets.TextureData,
        color: m.V4) void
    {
        self.texQuadColorUvOffset(bottomLeft, size, depth, cornerRadius, m.zero(2), m.one(2), m.zero(2), textureData, color);
    }

    pub fn texQuadColorUvOffset(
        self: *Self,
        bottomLeft: m.V2,
        size: m.V2,
        depth: f32,
        cornerRadius: f32,
        uvBottomLeft: m.V2,
        uvSize: m.V2,
        shadowSize: m.V2,
        textureData: *const assets.TextureData,
        color: m.V4) void
    {
        self.quad2(bottomLeft, size, depth, cornerRadius, uvBottomLeft, uvSize, shadowSize, textureData.texId, .{color, color, color, color});
    }

    pub fn quad2(
        self: *Self,
        bottomLeft: m.V2,
        size: m.V2,
        depth: f32,
        cornerRadius: f32,
        uvBottomLeft: m.V2,
        uvSize: m.V2,
        shadowSize: f32,
        shadowColor: m.V4,
        textureId: ?u64,
        colors: [4]m.V4) void
    {
        const textureIndex = if (textureId) |id| self.getOrPushTextureIndex(id) orelse {
            std.log.warn("textures at max capacity, skipping", .{});
            return;
        } else null;
        self.quad22(bottomLeft, size, depth, cornerRadius, uvBottomLeft, uvSize, shadowSize, shadowColor, textureIndex, colors, false);
    }

    pub fn quad22(
        self: *Self,
        bottomLeft: m.V2,
        size: m.V2,
        depth: f32,
        cornerRadius: f32,
        uvBottomLeft: m.V2,
        uvSize: m.V2,
        shadowSize: f32,
        shadowColor: m.V4,
        textureIndex: ?u32,
        colors: [4]m.V4,
        isGrayscale: bool) void
    {
        const entry = self.quads.addOne() catch {
            std.log.warn("quads at max capacity, skipping", .{});
            return;
        };
        const bottomLeftHack = blk: {
            if (self.dirtyStuff) |ds| {
                if (isGrayscale) {
                    // hack for catching text quads
                    break :blk bottomLeft;
                } else {
                    break :blk scaleOffsetAnchor(bottomLeft, size, ds.scale, ds.offset, ds.anchor);
                }
            } else {
                break :blk bottomLeft;
            }
        };
        entry.* = .{
            .colors = colors,
            .bottomLeft = bottomLeftHack,
            .size = size,
            .uvBottomLeft = uvBottomLeft,
            .uvSize = uvSize,
            .depth = depth,
            .cornerRadius = cornerRadius,
            .shadowSize = shadowSize,
            .shadowColor = shadowColor,
            .textureIndex = if (textureIndex) |index| index else 0,
            .textureMode = if (textureIndex == null) 0 else (if (isGrayscale) 2 else 1),
        };
    }

    pub fn text(
        self: *Self,
        str: []const u8,
        baselineLeft: m.V2,
        depth: f32,
        fontData: *const assets.FontData,
        color: m.V4) void
    {
        self.textSize(str, baselineLeft, depth, fontData.size * fontData.scale, fontData, color);
    }

    pub fn textSize(
        self: *Self,
        str: []const u8,
        baselineLeft: m.V2,
        depth: f32,
        size: f32,
        fontData: *const assets.FontData,
        color: m.V4) void
    {
        self.textSizeMaxWidth(str, baselineLeft, depth, size, null, fontData, color);
    }

    pub fn textMaxWidth(
        self: *Self,
        str: []const u8,
        baselineLeft: m.V2,
        depth: f32,
        width: ?f32,
        fontData: *const assets.FontData,
        color: m.V4) void
    {
        self.textSizeMaxWidth(str, baselineLeft, depth, fontData.size * fontData.scale, width, fontData, color);
    }

    pub fn textSizeMaxWidth(
        self: *Self,
        str: []const u8,
        baselineLeft: m.V2,
        depth: f32,
        size: f32,
        width: ?f32,
        fontData: *const assets.FontData,
        color: m.V4) void
    {
        const atlasTextureIndex = self.getOrPushTextureIndex(fontData.atlasData.texId) orelse {
            std.log.warn("textures at max capacity, skipping", .{});
            return;
        };
        const baselineLeftHack = blk: {
            if (self.dirtyStuff) |ds| {
                break :blk scaleOffset(baselineLeft, ds.scale, ds.offset);
            } else {
                break :blk baselineLeft;
            }
        };
        const scale = size / (fontData.size * fontData.scale);
        var glyphIt = GlyphIterator.init(str, fontData, width);
        while (glyphIt.next()) |g| {
            const pos = baselineLeftHack + g.position;
            const cornerRadius = 0;
            self.quad22(
                pos, g.size * m.splat(2, scale), depth, cornerRadius, g.uvOffset, g.uvSize, 0, m.zero(4),
                atlasTextureIndex, .{color, color, color, color}, true,
            );
        }
        // var ta = memory.getTempArena(null);
        // defer ta.reset();
        // const a = ta.allocator();
        // const glyphs = utf8ToGlyphs(str, fontData, width, a);
        // for (glyphs) |g| {
        //     const pos = m.add(baselineLeftHack, g.position);
        //     const cornerRadius = 0;
        //     self.quad22(
        //         pos, m.multScalar(g.size, scale), depth, cornerRadius, g.uvOffset, g.uvSize, 0, m.zero(4),
        //         atlasTextureIndex, .{color, color, color, color}, true,
        //     );
        // }
    }

    pub fn render(
        self: *const Self,
        renderState: *const RenderState,
        screenSize: m.V2,
        allocator: std.mem.Allocator) void
    {
        platform_render.render(self, renderState, screenSize, allocator);
    }

    pub fn getOrPushTextureIndex(self: *Self, id: u64) ?u32
    {
        // TODO: O(n^2) alert
        if (std.mem.indexOfScalar(u64, self.textureIds.slice(), id)) |index| {
            return @intCast(index);
        }
        self.textureIds.append(id) catch return null;
        return @intCast(self.textureIds.len - 1);
    }
};

const RenderEntryQuad = extern struct {
    colors: [4]m.V4, // corner colors: 0,0 | 1,0 | 1,1 | 0,1
    bottomLeft: m.V2,
    size: m.V2,
    uvBottomLeft: m.V2,
    uvSize: m.V2,
    depth: f32,
    cornerRadius: f32,
    shadowSize: f32,
    shadowColor: m.V4,
    textureIndex: u32,
    textureMode: u32,
};

fn scaleOffset(pos: m.V2, scale: m.V2, offset: m.V2) m.V2
{
    return pos * scale + offset;
}

fn scaleOffsetAnchor(pos: m.V2, size: m.V2, scale: m.V2, offset: m.V2, anchor: m.V2) m.V2
{
    return scaleOffset(pos, scale, offset) - (size * anchor);
}
