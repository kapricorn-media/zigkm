const std = @import("std");

const m = @import("zigkm").math;

const w = @import("wasm_bindings.zig");

pub const MAX_QUADS = 32 * 1024;
pub const MAX_TEXTURES = 512;

// This is a limitation on the webGL shader.
pub const MAX_TEXTURES_PER_DRAW = 8;

const RenderQueue = @import("render.zig").RenderQueue;

pub const RenderState = struct
{
    quadState: QuadState,

    pub fn load(self: *RenderState) !void
    {
        try self.quadState.load();
    }
};

pub fn render(
    renderQueue: *const RenderQueue,
    renderState: *const RenderState,
    screenSize: m.V2,
    allocator: std.mem.Allocator) void
{
    const quads = renderQueue.quads.slice();

    if (quads.len > 0) {
        const quadState = &renderState.quadState;
        w.glUseProgram(quadState.programId);
        w.glBindVertexArray(quadState.vao);

        const values = &[MAX_TEXTURES_PER_DRAW]c_int {0, 1, 2, 3, 4, 5, 6, 7};
        w.glUniform1iv(quadState.texturesLoc, @ptrCast(values.ptr), values.len);
        w.glUniform2fv(quadState.screenSizeLoc, screenSize[0], screenSize[1]);

        var quadInd: usize = 0;
        const quadsCopy = allocator.dupe(RenderQueue.EntryQuad, quads) catch unreachable;
        while (quadInd < quadsCopy.len) {
            var textureIds = [MAX_TEXTURES_PER_DRAW]?u64{null, null, null, null, null, null, null, null};
            var quadInd2 = quadInd;
            while (quadInd2 < quadsCopy.len) {
                const quad = &quadsCopy[quadInd2];
                if (quad.textureMode != 0) {
                    const textureId = renderQueue.textureIds.slice()[quad.textureIndex];
                    var assignedTextureId = false;
                    for (&textureIds, 0..) |*tid, i| {
                        if (tid.*) |id| {
                            if (textureId == id) {
                                quad.textureIndex = i;
                                assignedTextureId = true;
                                break;
                            }
                        } else {
                            tid.* = textureId;
                            quad.textureIndex = i;
                            assignedTextureId = true;
                            break;
                        }
                    }
                    if (!assignedTextureId) {
                        break;
                    }
                }
                quadInd2 += 1;
            }

            for (textureIds, 0..) |tid, i| {
                if (tid) |id| {
                    w.glActiveTexture(w.GL_TEXTURE0 + i);
                    w.glBindTexture(w.GL_TEXTURE_2D, @intCast(id));
                }
            }

            const quadsSlice = quadsCopy[quadInd..quadInd2];
            w.glBindBuffer(w.GL_ARRAY_BUFFER, quadState.instanceBuffer);
            const instanceBufferBytes = std.mem.sliceAsBytes(quadsSlice);
            w.glBufferSubData(w.GL_ARRAY_BUFFER, 0, @ptrCast(instanceBufferBytes.ptr), instanceBufferBytes.len);

            w.glDrawArraysInstanced(w.GL_TRIANGLES, 0, 6, quadsSlice.len);
            quadInd = quadInd2;
        }
    }
}

const QuadState = struct {
    programId: c_uint,
    vao: c_uint,
    instanceBuffer: c_uint,
    screenSizeLoc: c_uint,
    texturesLoc: c_uint,

    const vert = @embedFile("gles3/shaders/quad.vert");
    const frag = @embedFile("gles3/shaders/quad.frag");

    pub fn load(self: *QuadState) !void
    {
        const Entry = RenderQueue.EntryQuad;
        const entrySize = @sizeOf(Entry);

        // TODO error check all these
        const vertQuadId = w.compileShader(&vert[0], vert.len, w.GL_VERTEX_SHADER);
        const fragQuadId = w.compileShader(&frag[0], frag.len, w.GL_FRAGMENT_SHADER);

        const programId = w.linkShaderProgram(vertQuadId, fragQuadId);

        const instanceBuffer = w.glCreateBuffer();
        w.glBindBuffer(w.GL_ARRAY_BUFFER, instanceBuffer);
        w.glBufferDataSize(w.GL_ARRAY_BUFFER, entrySize * MAX_QUADS, w.GL_DYNAMIC_DRAW);

        const vao = w.glCreateVertexArray();
        w.glBindVertexArray(vao);

        const AttribData = struct {
            name: []const u8,
            size: c_uint,
            type: c_uint,
            offset: c_uint,
        };
        const instanceAttribs = [_]AttribData {
            .{
                .name = "vi_colorBL",
                .size = 4,
                .type = w.GL_FLOAT,
                .offset = 0,
            },
            .{
                .name = "vi_colorBR",
                .size = 4,
                .type = w.GL_FLOAT,
                .offset = @sizeOf(m.V4),
            },
            .{
                .name = "vi_colorTL",
                .size = 4,
                .type = w.GL_FLOAT,
                .offset = @sizeOf(m.V4) * 2,
            },
            .{
                .name = "vi_colorTR",
                .size = 4,
                .type = w.GL_FLOAT,
                .offset = @sizeOf(m.V4) * 3,
            },
            .{
                .name = "vi_bottomLeftSize",
                .size = 4,
                .type = w.GL_FLOAT,
                .offset = @bitOffsetOf(Entry, "bottomLeft") / 8,
            },
            .{
                .name = "vi_uvBottomLeftSize",
                .size = 4,
                .type = w.GL_FLOAT,
                .offset = @bitOffsetOf(Entry, "uvBottomLeft") / 8,
            },
            .{
                .name = "vi_depthCornerRadius",
                .size = 2,
                .type = w.GL_FLOAT,
                .offset = @bitOffsetOf(Entry, "depth") / 8,
            },
            .{
                .name = "vi_shadowSize",
                .size = 1,
                .type = w.GL_FLOAT,
                .offset = @bitOffsetOf(Entry, "shadowSize") / 8,
            },
            .{
                .name = "vi_shadowColor",
                .size = 4,
                .type = w.GL_FLOAT,
                .offset = @bitOffsetOf(Entry, "shadowColor") / 8,
            },
            .{
                .name = "vi_textureIndexMode",
                .size = 2,
                .type = w.GL_UNSIGNED_INT,
                .offset = @bitOffsetOf(Entry, "textureIndex") / 8,
            },
        };

        for (instanceAttribs) |a| {
            const attribLoc = try getAttributeLocation(programId, a.name);
            w.glEnableVertexAttribArray(attribLoc);
            if (a.type == w.GL_FLOAT) {
                const normalized = 0;
                w.glVertexAttribPointer(attribLoc, a.size, a.type, normalized, entrySize, a.offset);
            } else {
                w.glVertexAttribIPointer(attribLoc, a.size, a.type, entrySize, a.offset);
            }
            w.glVertexAttribDivisor(attribLoc, 1);
        }

        self.* = .{
            .programId = programId,
            .vao = vao,
            .instanceBuffer = instanceBuffer,
            .screenSizeLoc = try getUniformLocation(programId, "u_screenSize"),
            .texturesLoc = try getUniformLocation(programId, "u_textures"),
        };
    }
};

fn getAttributeLocation(programId: c_uint, attributeName: []const u8) !c_uint
{
    const loc = w.glGetAttribLocation(programId, &attributeName[0], attributeName.len);
    if (loc == -1) {
        std.log.err("getAttributeLocation failed for {s}", .{attributeName});
        return error.MissingAttributeLoc;
    } else {
        return @intCast(loc);
    }
}

fn getUniformLocation(programId: c_uint, uniformName: []const u8) !c_uint
{
    const loc = w.glGetUniformLocation(programId, &uniformName[0], uniformName.len);
    if (loc == -1) {
        std.log.err("getUniformLocation failed for {s}", .{uniformName});
        return error.MissingUniformLoc;
    } else {
        return @intCast(loc);
    }
}
