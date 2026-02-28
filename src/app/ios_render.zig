const std = @import("std");
const A = std.mem.Allocator;

const m = @import("zigkm-math");

// const asset = @import("asset.zig");
const bindings = @import("ios_bindings.zig");
const ios = bindings.ios;
const ios_exports = @import("ios_exports.zig");

pub const MAX_QUADS = ios.MAX_QUADS;
pub const MAX_TEXTURES = ios.MAX_TEXTURES;

const RenderQueue = @import("render.zig").RenderQueue;

pub const RenderState = struct
{
    renderState: *bindings.RenderState2,

    const Self = @This();

    pub fn load(self: *Self) !void
    {
        self.* = RenderState {
            .renderState = try bindings.createRenderState(ios_exports._contextPtr),
        };
    }
};

pub fn render(renderQueue: *const RenderQueue, renderState: *const RenderState, screenSize: m.V2, a: A) void
{
    if (renderQueue.quads.len > 0) {
        var quads = a.alloc(ios.QuadInstanceData, renderQueue.quads.len) catch return;
        for (renderQueue.quads.slice(), 0..) |q, i| {
            quads[i] = .{
                .colors = .{
                    @bitCast(q.colors[0]),
                    @bitCast(q.colors[1]),
                    @bitCast(q.colors[2]),
                    @bitCast(q.colors[3]),
                },
                .bottomLeft = @bitCast(q.bottomLeft),
                .size = @bitCast(q.size),
                .uvBottomLeft = @bitCast(q.uvBottomLeft),
                .uvSize = @bitCast(q.uvSize),
                .shadowColor = @bitCast(q.shadowColor),
                .depth = q.depth,
                .cornerRadius = q.cornerRadius,
                .shadowSize = q.shadowSize,
                .textureIndex = q.textureIndex,
                .textureMode = q.textureMode,
            };
        }

        const instanceBufferBytes = std.mem.sliceAsBytes(quads);
        bindings.renderQuads(
            ios_exports._contextPtr, renderState.renderState,
            renderQueue.quads.len, instanceBufferBytes,
            renderQueue.textureIds.slice(),
            screenSize.x, screenSize.y
        );
    }
}
