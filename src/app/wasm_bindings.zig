const std = @import("std");

pub fn setCursorZ(cursor: []const u8) void
{
    setCursor(&cursor[0], cursor.len);
}

pub fn getUrlAlloc(allocator: std.mem.Allocator) ![]const u8
{
    const len = getUrlLen();
    var buf = try allocator.alloc(u8, len);
    const n = getUrl(&buf[0], len);
    std.debug.assert(len == n);
    return buf;
}

pub fn setUrlZ(url: []const u8) void
{
    setUrl(&url[0], url.len);
}

pub fn pushStateZ(uri: []const u8) void
{
    pushState(&uri[0], uri.len);
}

pub fn getCookieAlloc(allocator: std.mem.Allocator, name: []const u8) ![]const u8
{
    const len = getCookieLen(name.ptr, name.len);
    if (len == 0) {
        return "";
    }
    const buf = try allocator.alloc(u8, len);
    const n = getCookie(name.ptr, name.len, buf.ptr, len);
    std.debug.assert(len == n);
    return buf;
}

pub fn setCookieZ(name: []const u8, value: []const u8, maxAgeSeconds: c_uint) void
{
    setCookie(name.ptr, name.len, value.ptr, value.len, maxAgeSeconds);
}

pub fn httpRequestZ(method: std.http.Method, uri: []const u8, h1: []const u8, v1: []const u8, body: []const u8) void
{
    httpRequest(httpMethodToInt(method), uri.ptr, uri.len, h1.ptr, h1.len, v1.ptr, v1.len, body.ptr, body.len);
}

pub fn httpMethodToInt(method: std.http.Method) c_uint
{
    return switch (method) {
        .GET => 1,
        .POST => 2,
        else => 0,
    };
}

pub fn intToHttpMethod(i: c_uint) std.http.Method
{
    return switch (i) {
        1 => .GET,
        2 => .POST,
        else => .GET,
    };
}

// Debug
pub extern fn consoleMessage(isError: bool, messagePtr: *const u8, messageLen: c_uint) void;

// Custom
pub extern fn fillDataBuffer(buf: [*c]const u8, len: c_uint) c_int; // 1 success, 0 error
pub extern fn addReturnValueFloat(value: f32) c_int;
pub extern fn addReturnValueInt(value: c_int) c_int;
pub extern fn addReturnValueBuf(ptr: *const u8, len: c_uint) c_int;
pub extern fn loadFontDataJs(id: c_uint, fontUrlPtr: *const u8, fontUrlLen: c_uint, fontSize: f32, scale: f32, atlasSize: c_uint) c_uint;

// browser / DOM
pub extern fn clearAllEmbeds() void;
pub extern fn addYoutubeEmbed(left: c_int, top: c_int, width: c_int, height: c_int, youtubeIdPtr: *const u8, youtubeIdLen: c_uint) void;

pub extern fn setCursor(cursorPtr: *const u8, cursorLen: c_uint) void;
pub extern fn setScrollY(y: c_uint) void;
pub extern fn getUrlLen() c_uint;
pub extern fn getUrl(outUrlPtr: *u8, outUrlLen: c_uint) c_uint;
pub extern fn setUrl(urlPtr: *const u8, urlLen: c_uint) void;
pub extern fn pushState(uriPtr: *const u8, uriLen: c_uint) void;
pub extern fn getCookieLen(namePtr: [*c]const u8, nameLen: c_uint) c_uint;
pub extern fn getCookie(namePtr: [*c]const u8, nameLen: c_uint, outValuePtr: [*c]u8, outValueLen: c_uint) c_uint;
pub extern fn setCookie(namePtr: [*c]const u8, nameLen: c_uint, valuePtr: [*c]const u8, valueLen: c_uint, maxAgeSeconds: c_uint) void;

pub extern fn getNowMillis() f32;

pub extern fn httpRequest(method: c_uint, uriPtr: [*c]const u8, uriLen: c_uint, h1Ptr: [*c]const u8, h1Len: c_uint, v1Ptr: [*c]const u8, v1Len: c_uint, bodyPtr: [*c]const u8, bodyLen: c_uint) void;

pub extern fn focusTextInput(x: c_int, y: c_int) void;

// GL
pub extern fn compileShader(source: *const u8 , len: c_uint, type: c_uint) c_uint;
pub extern fn linkShaderProgram(vertexShaderId: c_uint, fragmentShaderId: c_uint) c_uint;
pub extern fn createTexture(width: c_int, height: c_int, wrapMode: c_uint, filter: c_uint) c_uint;
pub extern fn createTextureWithData(width: c_int, height: c_int, channels: c_int, dataPtr: *u8, dataLen: c_uint, wrapMode: c_uint, filter: c_uint) c_uint;
pub extern fn loadTexture(id: c_uint, textureId: c_uint, imgUrlPtr: *const u8, imgUrlLen: c_uint, wrapMode: c_uint, filter: c_uint) void;
pub extern fn bindNullFramebuffer() void;

pub extern fn glClear(_: c_uint) void;
pub extern fn glClearColor(_: f32, _: f32, _: f32, _: f32) void;

pub extern fn glEnable(_: c_uint) void;

pub extern fn glBlendFunc(_: c_uint, _: c_uint) void;
pub extern fn glBlendFuncSeparate(_: c_uint, _: c_uint, _: c_uint, _: c_uint) void;
pub extern fn glDepthFunc(_: c_uint) void;

pub extern fn glGetAttribLocation(_: c_uint, _: *const u8, _: c_uint) c_int;
pub extern fn glGetUniformLocation(_: c_uint, _: *const u8, _: c_uint) c_int;

pub extern fn glUniform1i(_: c_uint, _: c_int) void;
pub extern fn glUniform1iv(_: c_uint, _: *const c_int, _: c_uint) void;
pub extern fn glUniform1fv(_: c_uint, _: f32) void;
pub extern fn glUniform2fv(_: c_uint, _: f32, _: f32) void;
pub extern fn glUniform3fv(_: c_uint, _: f32, _: f32, _: f32) void;
pub extern fn glUniform4fv(_: c_uint, _: f32, _: f32, _: f32, _: f32) void;

pub extern fn glCreateFramebuffer() c_uint;
pub extern fn glBindFramebuffer(_: c_uint, _: c_uint) void;
pub extern fn glFramebufferTexture2D(_: c_uint, _: c_uint, _: c_uint, _: c_uint, _: c_uint) void;
pub extern fn glFramebufferRenderbuffer(_: c_uint, _: c_uint, _: c_uint, _: c_uint) void;

pub extern fn glCreateRenderbuffer() c_uint;
pub extern fn glBindRenderbuffer(_: c_uint, _: c_uint) void;
pub extern fn glRenderbufferStorage(_: c_uint, _: c_uint, _: c_int, _: c_int) void;

pub extern fn glCreateBuffer() c_uint;
pub extern fn glBindBuffer(_: c_uint, _: c_uint) void;
pub extern fn glBufferDataSize(_: c_uint, _: c_uint, _: c_uint) void;
pub extern fn glBufferData(_: c_uint, _: *const u8, _: c_uint, _: c_uint) void;
pub extern fn glBufferSubData(_: c_uint, _: c_uint, _: *const u8, _: c_uint) void;

pub extern fn glCreateVertexArray() c_uint;
pub extern fn glBindVertexArray(_: c_uint) void;

pub extern fn glCreateTexture() c_uint;
pub extern fn glBindTexture(_: c_uint, _: c_uint) void;
pub extern fn glActiveTexture(_: c_uint) void;
pub extern fn glDeleteTexture(_: c_uint) void;

pub extern fn glUseProgram(_: c_uint) void;

pub extern fn glEnableVertexAttribArray(_: c_uint) void;
pub extern fn glVertexAttribPointer(_: c_uint, _: c_uint, _: c_uint, _: c_uint, _: c_uint, _: c_uint) void;
pub extern fn glVertexAttribIPointer(_: c_uint, _: c_uint, _: c_uint, _: c_uint, _: c_uint) void;

pub extern fn glVertexAttribDivisor(_: c_uint, _: c_uint) void;

pub extern fn glDrawArrays(_: c_uint, _: c_uint, _: c_uint) void;
pub extern fn glDrawArraysInstanced(_: c_uint, _: c_uint, _: c_uint, _: c_uint) void;

// Identifier constants pulled from WebGLRenderingContext
pub const GL_VERTEX_SHADER: c_uint = 35633;
pub const GL_FRAGMENT_SHADER: c_uint = 35632;
pub const GL_ARRAY_BUFFER: c_uint = 34962;
pub const GL_TRIANGLES: c_uint = 4;
pub const GL_STATIC_DRAW: c_uint = 35044;
pub const GL_DYNAMIC_DRAW: c_uint = 35048;

pub const GL_INT: c_uint = 5124;
pub const GL_UNSIGNED_INT: c_uint = 5125;
pub const GL_FLOAT: c_uint = 5126;

pub const GL_DEPTH_TEST: c_uint = 2929;
pub const GL_LESS: c_uint = 513;
pub const GL_LEQUAL: c_uint = 515;

pub const GL_BLEND: c_uint = 3042;
pub const GL_ZERO: c_uint = 0;
pub const GL_ONE: c_uint = 1;
pub const GL_SRC_ALPHA: c_uint = 770;
pub const GL_ONE_MINUS_SRC_ALPHA: c_uint = 771;

pub const GL_COLOR_BUFFER_BIT: c_uint = 16384;
pub const GL_DEPTH_BUFFER_BIT: c_uint = 256;

pub const GL_TEXTURE_2D: c_uint = 3553;
pub const GL_TEXTURE0: c_uint = 33984;

pub const GL_REPEAT: c_uint = 10497;
pub const GL_CLAMP_TO_EDGE: c_uint = 33071;

pub const GL_NEAREST: c_uint = 9728;
pub const GL_LINEAR: c_uint = 9729;

pub const GL_COLOR_ATTACHMENT0: c_uint = 36064;
pub const GL_DEPTH_ATTACHMENT: c_uint = 36096;

pub const GL_FRAMEBUFFER: c_uint = 36160;
pub const GL_RENDERBUFFER: c_uint = 36161;

pub const GL_DEPTH_COMPONENT16: c_uint = 33189;
