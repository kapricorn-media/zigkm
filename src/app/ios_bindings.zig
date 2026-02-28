const std = @import("std");

pub const ios = @cImport(@cInclude("ios/bindings.h"));

const zigimg = @import("zigimg");

pub const Context = opaque {};

pub const Buffer = opaque {};
pub const Texture = opaque {};
pub const RenderState = opaque {};
pub const RenderState2 = opaque {};

pub fn log(string: [:0]const u8) void
{
    ios.iosLog(@ptrCast(string));
}

pub fn getResourcePath() ?[]const u8
{
    const slice = ios.getResourcePath();
    if (slice.size == 0) {
        return null;
    }
    return slice.data[0..slice.size];
}

pub fn getWriteDirPath() ?[]const u8
{
    const slice = ios.getWriteDirPath();
    if (slice.size == 0) {
        return null;
    }
    return slice.data[0..slice.size];
}

pub fn createBuffer(context: *Context, length: u64) !*Buffer
{
    const buffer = ios.createBuffer(context, length);
    if (buffer == null) {
        return error.createBuffer;
    }
    return @ptrCast(buffer);
}

pub fn createAndLoadTexture(context: *Context, image: zigimg.Image) !*Texture
{
    var pixelBytes: []const u8 = undefined;
    var format: ios.TextureFormat = undefined;
    switch (image.pixels) {
        .grayscale8 => |r8| {
            pixelBytes = std.mem.sliceAsBytes(r8);
            format = ios.R8;
        },
        .rgba32 => |rgba32| {
            pixelBytes = std.mem.sliceAsBytes(rgba32);
            format = ios.RGBA8;
        },
        .bgra32 => |bgra32| {
            pixelBytes = std.mem.sliceAsBytes(bgra32);
            format = ios.BGRA8;
        },
        else => {
            std.log.err("Unsupported format: {}", .{std.meta.activeTag(image.pixels)});
            return error.UnsupportedFormat;
        },
    }
    const texture = ios.createAndLoadTexture(
        context, @intCast(image.width), @intCast(image.height), format, pixelBytes.ptr
    ) orelse {
        return error.createAndLoadTexture;
    };
    return @ptrCast(texture);
}

pub fn createRenderState(context: *Context) !*RenderState2
{
    const renderState = ios.createRenderState(context) orelse return error.createRenderState;
    return @ptrCast(renderState);
}

pub fn renderQuads(context: *Context, renderState: *const RenderState2, instances: usize, bufferData: []const u8, textureIds: []const u64, screenWidth: f32, screenHeight: f32) void
{
    return ios.renderQuads(context, @ptrCast(renderState), instances, bufferData.len, bufferData.ptr, textureIds.len, @ptrCast(textureIds), screenWidth, screenHeight);
}

pub fn renderText(context: *Context, renderState: *const RenderState2, instances: usize, bufferData: []const u8, atlases: []*const Texture, uniforms: *const ios.TextUniforms) void
{
    const renderStateC = @as(*const ios.RenderState2, @ptrCast(renderState));
    const atlasesC = @as([*c]?*const ios.Texture, @ptrCast(atlases.ptr));
    return ios.renderText(context, renderStateC, instances, bufferData.len, bufferData.ptr, atlases.len, atlasesC, uniforms);
}

pub fn setKeyboardVisible(context: *Context, visible: bool) void
{
    ios.setKeyboardVisible(context, @intFromBool(visible));
}

pub fn httpRequest(context: *Context, method: std.http.Method, url: []const u8, h1: []const u8, v1: []const u8, body: []const u8) void
{
    ios.httpRequest(context, toHttpMethod(method), toCSlice(url), toCSlice(h1), toCSlice(v1), toCSlice(body));
}

pub fn getStatusBarHeight(context: *Context) u32
{
    return ios.getStatusBarHeight(context);
}

pub fn openDocumentReader(context: *Context, docPath: []const u8, marginTop: u32, marginBottom: u32) bool
{
    return ios.openDocumentReader(context, toCSlice(docPath), marginTop, marginBottom) != 0;
}

pub fn closeDocumentReader(context: *Context) void
{
    ios.closeDocumentReader(context);
}

pub fn openUrl(context: *Context, url: []const u8) void
{
    ios.openUrl(context, toCSlice(url));
}

pub fn setClipboardContents(context: *Context, string: []const u8) void
{
    ios.setClipboardContents(context, toCSlice(string));
}

pub fn toHttpMethod(method: std.http.Method) ios.HttpMethod
{
    return switch (method) {
        .GET => ios.HTTP_GET,
        .POST => ios.HTTP_POST,
        else => ios.HTTP_UNSUPPORTED,
    };
}

pub fn fromHttpMethod(method: ios.HttpMethod) std.http.Method
{
    return switch (method) {
        ios.HTTP_GET => .GET,
        ios.HTTP_POST => .POST,
        else => .GET,
    };
}

pub fn toCSlice(slice: []const u8) ios.Slice
{
    return .{
        .size = slice.len,
        .data = @constCast(@ptrCast(slice.ptr)),
    };
}

pub fn fromCSlice(slice: ios.Slice) []const u8
{
    if (slice.size == 0) {
        return "";
    } else {
        return slice.data[0..slice.size];
    }
}
