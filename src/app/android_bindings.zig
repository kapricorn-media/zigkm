const std = @import("std");
const A = std.mem.Allocator;

const m = @import("zigkm-math");
const zigimg = @import("zigimg");

const memory = @import("memory.zig");

const ANDROID_API_MIN = 21;

pub const c = @cImport({
    @cDefine("__ANDROID_API__", std.fmt.comptimePrint("{}", .{ANDROID_API_MIN}));
    @cInclude("jni.h");
    @cInclude("android/asset_manager_jni.h");
    @cInclude("android/configuration.h");
    @cInclude("android/log.h");
    @cInclude("android/looper.h");
    @cInclude("android/native_activity.h");
    @cInclude("android/native_window.h");
    @cInclude("android/sensor.h");

    @cInclude("EGL/egl.h");
    @cInclude("GLES/gl.h");
    // @cInclude("GLES2/gl2.h");
    @cInclude("GLES3/gl3.h");
});

const assets = @import("assets.zig");

var _state = &@import("android_exports.zig")._state;

// TODO clean up
// pub threadlocal var _jniEnv: ?*c.JNIEnv = null; // would be nice... TLS bug
var _ptKey: std.c.pthread_key_t = undefined;

pub fn initJniThreadLocal() void
{
    const result = std.c.pthread_key_create(&_ptKey, null);
    if (result != .SUCCESS) {
        std.log.err("pthread_key_create failed result={}", .{result});
    }
}

const JNIState = struct {
    depth: u32,
    env: *c.JNIEnv,
    vm: ?*c.JavaVM,

    fn load(self: *JNIState, env: ?*c.JNIEnv) bool
    {
        if (env) |e| {
            self.* = .{
                .depth = 1,
                .env = e,
                .vm = null,
            };
        } else {
            // Attaches the current thread to the JVM
            const vm = _state.*.activity.vm;
            var e = _state.*.activity.env;

            var attachArgs: c.JavaVMAttachArgs = undefined;
            attachArgs.version = c.JNI_VERSION_1_6;
            attachArgs.name = "NativeThread";
            attachArgs.group = c.NULL;
            const result = vm.*.*.AttachCurrentThread.?(vm, &e, &attachArgs);
            if (result == c.JNI_ERR) {
                std.log.err("AttachCurrentThread failed", .{});
                return false;
            }
            self.* = .{
                .depth = 1,
                .env = e,
                .vm = vm,
            };
        }
        return true;
    }

    fn unload(self: *JNIState) void
    {
        if (self.vm) |vm| {
            const result = vm.*.*.DetachCurrentThread.?(vm);
            if (result == c.JNI_ERR) {
                std.log.err("DetachCurrentThread failed", .{});
            }
        }
    }
};

pub const JNIEnvGuard = struct {
    pub fn init(env: ?*c.JNIEnv) ?*c.JNIEnv
    {
        var state: *JNIState = undefined;
        if (std.c.pthread_getspecific(_ptKey)) |p| {
            state = @alignCast(@ptrCast(p));
        } else {
            state = std.heap.c_allocator.create(JNIState) catch {
                std.log.err("JNIState allocation failed", .{});
                return null;
            };
            if (std.c.pthread_setspecific(_ptKey, state) != 0) {
                std.log.err("pthread_getspecific failed", .{});
                return null;
            }
            state.* = .{
                .depth = 0,
                .env = undefined,
                .vm = null,
            };
        }

        if (state.depth > 0) {
            std.debug.assert(env == null);
            state.depth += 1;
        } else {
            if (!state.load(env)) {
                return null;
            }
        }
        return state.env;
    }

    pub fn deinit() void
    {
        if (std.c.pthread_getspecific(_ptKey)) |p| {
            const state: *JNIState = @alignCast(@ptrCast(p));
            std.debug.assert(state.depth > 0);
            state.depth -= 1;
            if (state.depth == 0) {
                state.unload();
            }
        } else {
            std.log.err("No JNIState on guard deinit", .{});
        }
    }
};

pub fn loadEntireFile(path: [:0]const u8, assetManager: *c.AAssetManager, a: A) ![]const u8
{
    const asset = c.AAssetManager_open(assetManager, path, c.AASSET_MODE_BUFFER);
    if (asset == null) {
        return error.AAssetManager_open;
    }
    defer c.AAsset_close(asset);

    const size: usize = @intCast(c.AAsset_getLength64(asset));
    var buf = try a.alloc(u8, size);
    const result = c.AAsset_read(asset, &buf[0], size);
    if (result != size) {
        std.log.err("AAsset_read failed, {} expected {}", .{result, size});
        return error.AAsset_read;
    }

    return buf;
}

pub fn compileShaders(vertFile: [:0]const u8, fragFile: [:0]const u8, assetManager: *c.AAssetManager, a: A) !c.GLuint
{
    const vertSource = try loadEntireFile(vertFile, assetManager, a);
    const vertId = try compileShader(vertSource, c.GL_VERTEX_SHADER);
    const fragSource = try loadEntireFile(fragFile, assetManager, a);
    const fragId = try compileShader(fragSource, c.GL_FRAGMENT_SHADER);

    const programId = c.glCreateProgram();
    errdefer c.glDeleteProgram(programId);
    c.glAttachShader(programId, vertId);
    c.glAttachShader(programId, fragId);
    c.glLinkProgram(programId);
    var status: c.GLint = undefined;
    c.glGetProgramiv(programId, c.GL_LINK_STATUS, &status);
    if (status != c.GL_TRUE) {
        return error.glLinkProgram;
    }

    return programId;
}

fn compileShader(source: []const u8, shaderType: c.GLenum) !c.GLuint
{
    const shaderId = c.glCreateShader(shaderType);
    if (shaderId == 0) {
        return error.glCreateShader;
    }
    const sourceLen: c.GLint = @intCast(source.len);
    c.glShaderSource(shaderId, 1, &source.ptr, &sourceLen);
    c.glCompileShader(shaderId);
    var status: c.GLint = undefined;
    c.glGetShaderiv(shaderId, c.GL_COMPILE_STATUS, &status);
    if (status != c.GL_TRUE) {
        var logBuf: [1024]u8 = undefined;
        var logBufLength: c.GLsizei = undefined;
        c.glGetShaderInfoLog(shaderId, logBuf.len, &logBufLength, &logBuf[0]);
        std.log.err("Error when compiling shader:\n{s}", .{logBuf[0..@intCast(logBufLength)]});
        return error.glCompileShader;
    }
    return shaderId;
}

pub fn getAttributeLocation(programId: c.GLuint, attributeName: [:0]const u8) !c.GLuint
{
    const loc = c.glGetAttribLocation(programId, attributeName.ptr);
    if (loc == -1) {
        std.log.err("getAttributeLocation failed for {s}", .{attributeName});
        return error.glGetAttribLocation;
    }
    return @intCast(loc);
}

pub fn getUniformLocation(programId: c.GLuint, uniformName: [:0]const u8) !c.GLint
{
    const loc = c.glGetUniformLocation(programId, uniformName.ptr);
    if (loc == -1) {
        std.log.err("getUniformLocation failed for {s}", .{uniformName});
        return error.glGetUniformLocation;
    }
    return loc;
}

pub fn loadTexture(image: *zigimg.Image, wrap: assets.TextureWrapMode, filter: assets.TextureFilter) !c.GLuint
{
    var textureId: c.GLuint = undefined;
    c.glGenTextures(1, &textureId);
    c.glBindTexture(c.GL_TEXTURE_2D, textureId);
    var pixelBytes: []const u8 = undefined;
    var internalFormat: c.GLint = undefined;
    var format: c.GLuint = undefined;
    switch (image.pixels) {
        .grayscale8 => |r8| {
            pixelBytes = std.mem.sliceAsBytes(r8);
            internalFormat = c.GL_R8;
            format = c.GL_RED;
        },
        else => {
            var ta = memory.getTempArena(null);
            defer ta.reset();
            const a = ta.allocator();

            try image.convertNoFree(a, .rgba32);
            pixelBytes = std.mem.sliceAsBytes(image.pixels.rgba32);
            internalFormat = c.GL_RGBA8;
            format = c.GL_RGBA;
        },
    }
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, internalFormat, @intCast(image.width), @intCast(image.height), 0, format, c.GL_UNSIGNED_BYTE, pixelBytes.ptr);
    const wrapGl = switch (wrap) {
        .clampToEdge => c.GL_CLAMP_TO_EDGE,
        .repeat => c.GL_REPEAT,
    };
    const filterGl = switch (filter) {
        .linear => c.GL_LINEAR,
        .nearest => c.GL_NEAREST,
    };
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, wrapGl);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, wrapGl);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, filterGl);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, filterGl);

    return textureId;
}

pub fn jniToZigString(env: *c.JNIEnv, str: c.jstring, a: A) ![]const u8
{
    const length = env.*.*.GetStringLength.?(env, str);
    const chars = env.*.*.GetStringChars.?(env, str, null);
    defer env.*.*.ReleaseStringChars.?(env, str, chars);

    const u16Ptr: [*]const u16 = chars;
    const u16Slice: []const u16 = u16Ptr[0..@intCast(length)];
    return std.unicode.utf16LeToUtf8Alloc(a, u16Slice);
}

pub fn zigToJniString(env: *c.JNIEnv, str: []const u8, a: A) !c.jstring
{
    const strZ = try a.dupeZ(u8, str);
    return env.*.*.NewStringUTF.?(env, strZ);
}

pub fn jniToZigByteArray(env: *c.JNIEnv, array: c.jbyteArray, a: A) ![]const u8
{
    const length = env.*.*.GetArrayLength.?(env, array);
    const bytes = env.*.*.GetByteArrayElements.?(env, array, null);
    defer env.*.*.ReleaseByteArrayElements.?(env, array, bytes, 0);

    const bytesSlice: []const u8 = @ptrCast(bytes[0..@intCast(length)]);
    const slice = try a.alloc(u8, @intCast(length));
    @memcpy(slice, bytesSlice);
    return slice;
}

pub fn zigToJniByteArray(env: *c.JNIEnv, array: []const u8) c.jbyteArray
{
    const byteArray = env.*.*.NewByteArray.?(env, @intCast(array.len));
    const bytes = env.*.*.GetByteArrayElements.?(env, byteArray, null);
    const bytesSlice: []u8 = @ptrCast(bytes[0..array.len]);
    @memcpy(bytesSlice, array);
    env.*.*.ReleaseByteArrayElements.?(env, byteArray, bytes, 0);
    return byteArray;
}

pub fn displayKeyboard(show: bool) void
{
    const env = JNIEnvGuard.init(null) orelse return;
    defer JNIEnvGuard.deinit();

    // Retrieves NativeActivity instance.
    const lNativeActivity = _state.*.activity.clazz;
    const classNativeActivity = env.*.*.GetObjectClass.?(env, lNativeActivity);

    // Calls NativeActivity method showKeyboard(show)
    const methodTest = env.*.*.GetMethodID.?(env, classNativeActivity, "showKeyboard", "(Z)V");
    env.*.*.CallVoidMethod.?(env, lNativeActivity, methodTest, show);
}

pub fn httpRequest(method: std.http.Method, url: []const u8, h1: []const u8, v1: []const u8, body: []const u8) void
{
    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    const env = JNIEnvGuard.init(null) orelse return;
    defer JNIEnvGuard.deinit();

    // Retrieves NativeActivity instance.
    const lNativeActivity = _state.*.activity.clazz;
    const classNativeActivity = env.*.*.GetObjectClass.?(env, lNativeActivity);

    // Calls NativeActivity method httpRequest
    const jMethod = env.*.*.GetMethodID.?(env, classNativeActivity, "httpRequest", "(ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;[B)V");
    const methodInt: i32 = switch (method) {
        .GET => 0,
        .POST => 1,
        else => 2,
    };
    const urlString = zigToJniString(env, url, a) catch return; // TODO
    const h1String = zigToJniString(env, h1, a) catch return; // TODO
    const v1String = zigToJniString(env, v1, a) catch return; // TODO
    const bodyByteArray = zigToJniByteArray(env, body);
    env.*.*.CallVoidMethod.?(env, lNativeActivity, jMethod, methodInt, urlString, h1String, v1String, bodyByteArray);
}

pub fn getStatusBarHeight() u32
{
    const env = JNIEnvGuard.init(null) orelse return 0;
    defer JNIEnvGuard.deinit();

    // Retrieves NativeActivity instance.
    const lNativeActivity = _state.*.activity.clazz;
    const classNativeActivity = env.*.*.GetObjectClass.?(env, lNativeActivity);

    const jMethod = env.*.*.GetMethodID.?(env, classNativeActivity, "getStatusBarHeight", "()I");
    const height = env.*.*.CallIntMethod.?(env, lNativeActivity, jMethod);
    return @intCast(@max(height, 0));
}

pub fn writePrivateFile(fileName: []const u8, data: []const u8, a: A) bool
{
    const env = JNIEnvGuard.init(null) orelse return false;
    defer JNIEnvGuard.deinit();

    // Retrieves NativeActivity instance.
    const lNativeActivity = _state.*.activity.clazz;
    const classNativeActivity = env.*.*.GetObjectClass.?(env, lNativeActivity);

    // Calls NativeActivity method writePrivateFile
    const jMethod = env.*.*.GetMethodID.?(env, classNativeActivity, "writePrivateFile", "(Ljava/lang/String;[B)Z");
    const fileNameString = zigToJniString(env, fileName, a) catch return false;
    const dataJni = zigToJniByteArray(env, data);
    return env.*.*.CallBooleanMethod.?(env, lNativeActivity, jMethod, fileNameString, dataJni) != 0;
}

pub fn readPrivateFile(fileName: []const u8, a: A) ?[]const u8
{
    const env = JNIEnvGuard.init(null) orelse return null;
    defer JNIEnvGuard.deinit();

    // Retrieves NativeActivity instance.
    const lNativeActivity = _state.*.activity.clazz;
    const classNativeActivity = env.*.*.GetObjectClass.?(env, lNativeActivity);

    // Calls NativeActivity method readPrivateFile
    const jMethod = env.*.*.GetMethodID.?(env, classNativeActivity, "readPrivateFile", "(Ljava/lang/String;)[B");
    const fileNameString = zigToJniString(env, fileName, a) catch return null;
    const result = env.*.*.CallObjectMethod.?(env, lNativeActivity, jMethod, fileNameString);
    if (env.*.*.IsInstanceOf.?(env, result, env.*.*.FindClass.?(env, "[B")) == 0) {
        std.log.err("readPrivateFile did not return a byte array", .{});
        return null;
    }
    return jniToZigByteArray(env, result, a) catch return null;
}

pub fn downloadAndOpenFile(url: []const u8, fileName: []const u8, title: []const u8, h1: []const u8, v1: []const u8, a: A) void
{
    const env = JNIEnvGuard.init(null) orelse return;
    defer JNIEnvGuard.deinit();

    // Retrieves NativeActivity instance.
    const lNativeActivity = _state.*.activity.clazz;
    const classNativeActivity = env.*.*.GetObjectClass.?(env, lNativeActivity);

    // Calls NativeActivity method downloadAndOpenFile
    const jMethod = env.*.*.GetMethodID.?(env, classNativeActivity, "downloadAndOpenFile", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");
    const urlString = zigToJniString(env, url, a) catch return;
    const fileNameString = zigToJniString(env, fileName, a) catch return;
    const titleString = zigToJniString(env, title, a) catch return;
    const h1String = zigToJniString(env, h1, a) catch return;
    const v1String = zigToJniString(env, v1, a) catch return;
    env.*.*.CallVoidMethod.?(env, lNativeActivity, jMethod, urlString, fileNameString, titleString, h1String, v1String);
}
