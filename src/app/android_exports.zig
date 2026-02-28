const std = @import("std");
const builtin = @import("builtin");

const m = @import("zigkm-math");

const android = @import("android_bindings.zig");
const c = android.c;
const defs = @import("defs.zig");
const hooks = @import("hooks.zig");
const memory = @import("memory.zig");
const q = @import("queue.zig");

pub const std_options = std.Options {
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .info,
        .ReleaseFast => .info,
        .ReleaseSmall => .info,
    },
    .logFn = myLogFn,
};

pub var _state: *AndroidState = undefined;

const Status = enum {
    none,
    failed,
    running,
    exited,
};

const AppSignalData = union(enum) {
    configuration_changed: void,
    content_rect_changed: void,
    destroy: void,
    input_queue_created: *c.AInputQueue,
    input_queue_destroyed: void,
    low_memory: void,
    native_window_created: *c.ANativeWindow,
    native_window_destroyed: void,
    native_window_redraw_needed: *c.ANativeWindow,
    native_window_resized: *c.ANativeWindow,
    pause: void,
    resume_: void,
    save_instance_state: void,
    start: void,
    stop: void,
    window_focus_changed: bool,
};

const GLState = struct {
    display: c.EGLDisplay = c.EGL_NO_DISPLAY,
    surface: c.EGLSurface = c.EGL_NO_SURFACE,
    context: c.EGLContext = c.EGL_NO_CONTEXT,
    screenSize: m.V2u = .{0, 0},

    vbo: c.GLuint = 0,
    programRect: c.GLuint = 0,

    textureId: c.GLuint = 0,

    fn load(self: *GLState, window: *c.ANativeWindow) !void
    {
        errdefer {
            self.display = c.EGL_NO_DISPLAY;
            self.surface = c.EGL_NO_SURFACE;
            self.context = c.EGL_NO_CONTEXT;
        }

        const display = c.eglGetDisplay(c.EGL_DEFAULT_DISPLAY);
        if (c.eglInitialize(display, null, null) != c.EGL_TRUE) {
            return error.eglInitialize;
        }

        const attribsDepth24 = [_]c.EGLint {
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
            c.EGL_SURFACE_TYPE, c.EGL_WINDOW_BIT,
            c.EGL_BLUE_SIZE, 8,
            c.EGL_GREEN_SIZE, 8,
            c.EGL_RED_SIZE, 8,
            c.EGL_DEPTH_SIZE, 24,
            c.EGL_NONE
        };
        var numConfigs: c.EGLint = undefined;
        var config: c.EGLConfig = undefined;
        if (c.eglChooseConfig(display, &attribsDepth24[0], &config, 1, &numConfigs) != c.EGL_TRUE) {
            return error.eglChooseConfig;
        }
        if (numConfigs <= 0) {
            // Fall back to 16-bit depth
            const attribsDepth16 = [_]c.EGLint {
                c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
                c.EGL_SURFACE_TYPE, c.EGL_WINDOW_BIT,
                c.EGL_BLUE_SIZE, 8,
                c.EGL_GREEN_SIZE, 8,
                c.EGL_RED_SIZE, 8,
                c.EGL_DEPTH_SIZE, 16,
                c.EGL_NONE
            };
            if (c.eglChooseConfig(display, &attribsDepth16[0], &config, 1, &numConfigs) != c.EGL_TRUE) {
                return error.eglChooseConfig;
            }
        }
        if (numConfigs <= 0) {
            return error.noConfigs;
        }

        const surface = c.eglCreateWindowSurface(display, config, window, null);
        var width: c.EGLint = undefined;
        if (c.eglQuerySurface(display, surface, c.EGL_WIDTH, &width) != c.EGL_TRUE) {
            return error.eglQuerySurface;
        }
        var height: c.EGLint = undefined;
        if (c.eglQuerySurface(display, surface, c.EGL_HEIGHT, &height) != c.EGL_TRUE) {
            return error.eglQuerySurface;
        }

        const contextAttribs = [_]c.EGLint {
            c.EGL_CONTEXT_CLIENT_VERSION, 3,
            c.EGL_NONE
        };
        const context = c.eglCreateContext(display, config, null, &contextAttribs[0]);
        if (c.eglMakeCurrent(display, surface, surface, context) != c.EGL_TRUE) {
            return error.eglMakeCurrent;
        }

        c.glViewport(0, 0, width, height);
        printAllGlErrors();

        self.display = display;
        self.surface = surface;
        self.context = context;
        self.screenSize = .{@intCast(width), @intCast(height)};
        std.log.info("Loaded GL, screenSize={}", .{self.screenSize});

        const vendor = c.glGetString(c.GL_VENDOR);
        if (vendor != null) {
            std.log.info("vendor={s}", .{vendor});
        }
        const renderer = c.glGetString(c.GL_RENDERER);
        if (renderer != null) {
            std.log.info("renderer={s}", .{renderer});
        }
        const version = c.glGetString(c.GL_VERSION);
        if (version != null) {
            std.log.info("version={s}", .{version});
        }
        const glslVersion = c.glGetString(c.GL_SHADING_LANGUAGE_VERSION);
        if (glslVersion != null) {
            std.log.info("glslVersion={s}", .{glslVersion});
        }

        c.glEnable(c.GL_CULL_FACE);
        c.glFrontFace(c.GL_CCW);
        c.glDisable(c.GL_CULL_FACE);
        c.glEnable(c.GL_DEPTH_TEST);
        c.glDepthFunc(c.GL_LEQUAL);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        printAllGlErrors();
    }

    fn unload(self: *GLState) void
    {
        if (self.display != c.EGL_NO_DISPLAY) {
            _ = c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
            if (self.context != c.EGL_NO_CONTEXT) {
                _ = c.eglDestroyContext(self.display, self.context);
            }
            if (self.surface != c.EGL_NO_SURFACE) {
                _ = c.eglDestroySurface(self.display, self.surface);
            }
            _ = c.eglTerminate(self.display);
        }

        self.context = c.EGL_NO_CONTEXT;
        self.surface = c.EGL_NO_SURFACE;
        self.display = c.EGL_NO_DISPLAY;

        std.log.debug("deinit GL success", .{});
    }
};

const KeyInputData = struct {
    action: i32,
    keyCode: i32,
    codePoint: u32,
};

const AndroidState = struct {
    memory: []align(32) u8,
    activity: *c.ANativeActivity,
    signalQueue: q.FixedQueue(AppSignalData, 32),
    keyInputQueue: q.FixedQueue(KeyInputData, 1024),
    status: Status,
    appThread: std.Thread,

    config: *c.AConfiguration,
    looper: *c.ALooper,
    inputQueue: ?*c.AInputQueue,
    window: ?*c.ANativeWindow,
    contentRect: c.ARect,

    sensorManager: *c.ASensorManager,
    rotationSensor: *const c.ASensor,
    sensorEventQueue: *c.ASensorEventQueue,

    timeStartS: f64,

    glState: GLState,

    pub fn getApp(self: *AndroidState) *defs.App
    {
        return @as(*defs.App, @ptrCast(self.memory));
    }
};

const LOOPER_IDENT_INPUT: c_int = 1;
const LOOPER_IDENT_SENSOR: c_int = 2;

fn toStatePtr(ptr: *anyopaque) *AndroidState
{
    return @ptrCast(@alignCast(ptr));
}

fn getState(activity: ?*c.ANativeActivity) ?*AndroidState
{
    if (activity) |a| {
        if (a.instance) |i| {
            return toStatePtr(i);
        } else {
            return null;
        }
    } else {
        return null;
    }
}

fn trySendSignalData(activity: ?*c.ANativeActivity, signalData: AppSignalData) void
{
    if (getState(activity)) |state| {
        if (state.signalQueue.enqueue(signalData)) {
            c.ALooper_wake(state.looper);
        } else {
            std.log.err("Failed to enqueue signal {}", .{signalData});
        }
    } else {
        std.log.err("getState failed", .{});
    }
}

fn onConfigurationChanged(activity: ?*c.ANativeActivity) callconv(.c) void
{
    trySendSignalData(activity, .{.configuration_changed = {}});
}

fn onContentRectChanged(activity: ?*c.ANativeActivity, rect: ?*const c.ARect) callconv(.c) void
{
    _ = rect;
    trySendSignalData(activity, .{.content_rect_changed = {}});
}

fn onDestroy(activity: ?*c.ANativeActivity) callconv(.c) void
{
    trySendSignalData(activity, .{.destroy = {}});
}

fn onInputQueueCreated(activity: ?*c.ANativeActivity, queue: ?*c.AInputQueue) callconv(.c) void
{
    trySendSignalData(activity, .{.input_queue_created = queue orelse undefined});
}

fn onInputQueueDestroyed(activity: ?*c.ANativeActivity, queue: ?*c.AInputQueue) callconv(.c) void
{
    _ = queue;
    trySendSignalData(activity, .{.input_queue_destroyed = {}});
}

fn onLowMemory(activity: ?*c.ANativeActivity) callconv(.c) void
{
    trySendSignalData(activity, .{.low_memory = {}});
}

fn onNativeWindowCreated(activity: ?*c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.c) void
{
    trySendSignalData(activity, .{.native_window_created = window orelse undefined});
}

fn onNativeWindowDestroyed(activity: ?*c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.c) void
{
    _ = window;
    trySendSignalData(activity, .{.native_window_destroyed = {}});
}

fn onNativeWindowRedrawNeeded(activity: ?*c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.c) void
{
    trySendSignalData(activity, .{.native_window_redraw_needed = window orelse undefined});
}

fn onNativeWindowResized(activity: ?*c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.c) void
{
    trySendSignalData(activity, .{.native_window_resized = window orelse undefined});
}

fn onPause(activity: ?*c.ANativeActivity) callconv(.c) void
{
    trySendSignalData(activity, .{.pause = {}});
}

fn onResume(activity: ?*c.ANativeActivity) callconv(.c) void
{
    trySendSignalData(activity, .{.resume_ = {}});
}

fn onSaveInstanceState(activity: ?*c.ANativeActivity, outLen: ?*usize) callconv(.c) ?*anyopaque
{
    _ = outLen;
    trySendSignalData(activity, .{.save_instance_state = {}});
    // TODO this one is special, probably gotta return the data
    return null;
}

fn onStart(activity: ?*c.ANativeActivity) callconv(.c) void
{
    trySendSignalData(activity, .{.start = {}});
}

fn onStop(activity: ?*c.ANativeActivity) callconv(.c) void
{
    trySendSignalData(activity, .{.stop = {}});
}

fn onWindowFocusChanged(activity: ?*c.ANativeActivity, focused: c_int) callconv(.c) void
{
    trySendSignalData(activity, .{.window_focus_changed = focused != 0});
}

fn printAllGlErrors() void
{
    while (true) {
        const glError = c.glGetError();
        if (glError == c.GL_NO_ERROR) {
            break;
        }
        std.log.err("GL error: {}", .{glError});
    }
}

fn logAppConfig(config: *c.AConfiguration) void
{
    var lang: [2]u8 = undefined;
    c.AConfiguration_getLanguage(config, &lang[0]);
    var country: [2]u8 = undefined;
    c.AConfiguration_getCountry(config, &country[0]);

    std.log.info(
        "app config: lang={s} country={s} mcc={} mnc={} orien={} touch={} dens={} keys={} nav={} keysHidden={} navHidden={} sdk={} screenSize={} screenLong={} uiModeType={} uiModeNight={}",
        .{
            lang, country,
            c.AConfiguration_getMcc(config),
            c.AConfiguration_getMnc(config),
            c.AConfiguration_getOrientation(config),
            c.AConfiguration_getTouchscreen(config),
            c.AConfiguration_getDensity(config),
            c.AConfiguration_getKeyboard(config),
            c.AConfiguration_getNavigation(config),
            c.AConfiguration_getKeysHidden(config),
            c.AConfiguration_getNavHidden(config),
            c.AConfiguration_getSdkVersion(config),
            c.AConfiguration_getScreenSize(config),
            c.AConfiguration_getScreenLong(config),
            c.AConfiguration_getUiModeType(config),
            c.AConfiguration_getUiModeNight(config),
        }
    );
}

const MotionEventInfo = struct {
    id: u64,
    pos: m.V2i,
};

fn motionEventInfo(event: *c.AInputEvent, pointerIndex: usize, screenSizeY: f32) MotionEventInfo
{
    return .{
        .id = @intCast(c.AMotionEvent_getPointerId(event, pointerIndex)),
        .pos = .{
            @intFromFloat(c.AMotionEvent_getRawX(event, pointerIndex)),
            @intFromFloat(screenSizeY - c.AMotionEvent_getRawY(event, pointerIndex)),
        },
    };
}

fn onInputEvent(app: *defs.App, event: *c.AInputEvent, screenSize: m.V2u) bool
{
    const screenSizeYF: f32 = @floatFromInt(screenSize[1]);

    const eventType = c.AInputEvent_getType(event);
    switch (eventType) {
        c.AINPUT_EVENT_TYPE_KEY => {
            // For proper Unicode support, we don't handle key events here.
            // Let them go to dispatchKeyEvent on the Java side and hand them down manually.
            return false;
        },
        c.AINPUT_EVENT_TYPE_MOTION => {
            const actionFull = c.AMotionEvent_getAction(event);
            const action = actionFull & c.AMOTION_EVENT_ACTION_MASK;
            const ptrIndex = (actionFull & c.AMOTION_EVENT_ACTION_POINTER_INDEX_MASK) >> c.AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT;
            _ = ptrIndex;
            const ptrCount = c.AMotionEvent_getPointerCount(event);
            std.debug.assert(ptrCount > 0);
            const info0 = motionEventInfo(event, 0, screenSizeYF);
            switch (action) {
                c.AMOTION_EVENT_ACTION_DOWN => {
                    std.debug.assert(ptrCount == 1);
                    app.inputState.addTouchEvent(.{
                        .id = info0.id,
                        .pos = info0.pos,
                        .tapCount = 1,
                        .phase = .Begin,
                    });
                },
                c.AMOTION_EVENT_ACTION_UP => {
                    std.debug.assert(ptrCount == 1);
                    app.inputState.addTouchEvent(.{
                        .id = info0.id,
                        .pos = info0.pos,
                        .tapCount = 1,
                        .phase = .End,
                    });
                },
                c.AMOTION_EVENT_ACTION_MOVE => {
                    for (0..ptrCount) |ind| {
                        const info = motionEventInfo(event, ind, screenSizeYF);
                        app.inputState.addTouchEvent(.{
                            .id = info.id,
                            .pos = info.pos,
                            .tapCount = 0,
                            .phase = .Move,
                        });
                    }
                },
                c.AMOTION_EVENT_ACTION_CANCEL => {},
                c.AMOTION_EVENT_ACTION_OUTSIDE => {},
                c.AMOTION_EVENT_ACTION_POINTER_DOWN => {},
                c.AMOTION_EVENT_ACTION_POINTER_UP => {},
                c.AMOTION_EVENT_ACTION_HOVER_MOVE => {},
                c.AMOTION_EVENT_ACTION_SCROLL => {},
                c.AMOTION_EVENT_ACTION_HOVER_ENTER => {},
                c.AMOTION_EVENT_ACTION_HOVER_EXIT => {},
                c.AMOTION_EVENT_ACTION_BUTTON_PRESS => {},
                c.AMOTION_EVENT_ACTION_BUTTON_RELEASE => {},
                else => {
                    std.log.err("Unrecognized motion event action={}", .{action});
                },
            }
        },
        else => {},
    }
    return true;
}

fn androidMain(state: *AndroidState) !void
{
    errdefer {
        state.status = .failed;
    }

    android.initJniThreadLocal();

    state.config = c.AConfiguration_new() orelse {
        return error.AConfiguration_new;
    };
    c.AConfiguration_fromAssetManager(state.config, state.activity.assetManager);
    logAppConfig(state.config);

    state.looper = c.ALooper_prepare(c.ALOOPER_PREPARE_ALLOW_NON_CALLBACKS) orelse {
        return error.ALooper_prepare;
    };

    // state.sensorManager = c.ASensorManager_getInstance() orelse {
    //     return error.SensorManager;
    // };
    // state.rotationSensor = c.ASensorManager_getDefaultSensor(
    //     state.sensorManager, c.ASENSOR_TYPE_ROTATION_VECTOR
    // ) orelse {
    //     return error.getDefaultSensor;
    // };
    // state.sensorEventQueue = c.ASensorManager_createEventQueue(
    //     state.sensorManager, state.looper, LOOPER_IDENT_SENSOR, null, null
    // ) orelse {
    //     return error.EventQueue;
    // };

    state.status = .running;

    state.timeStartS = @as(f64, @floatFromInt(std.time.nanoTimestamp())) * 1_000_000_000;

    while (state.status == .running) {
        const app = state.getApp();

        while (state.signalQueue.dequeue()) |signalData| {
            std.log.debug("Processing app signal {}", .{signalData});
            switch (signalData) {
                .configuration_changed => {},
                .content_rect_changed => {},
                .destroy => {
                    state.status = .exited;
                },
                .input_queue_created => |queue| {
                    if (state.inputQueue) |currentQ| {
                        c.AInputQueue_detachLooper(currentQ);
                    }
                    state.inputQueue = queue;
                    c.AInputQueue_attachLooper(queue, state.looper, LOOPER_IDENT_INPUT, null, null);
                },
                .input_queue_destroyed => {
                    if (state.inputQueue) |currentQ| {
                        c.AInputQueue_detachLooper(currentQ);
                    }
                    state.inputQueue = null;
                },
                .low_memory => {},
                .native_window_created => |window| {
                    if (state.window) |_| {
                        state.glState.unload();
                        state.window = null;
                    }
                    state.window = window;
                    state.glState.load(window) catch |err| {
                        std.log.err("Failed to load GL state err {}", .{err});
                    };
                    // TODO where to put this?
                    hooks.load(app, state.memory, state.glState.screenSize, 1.0) catch |err| {
                        std.log.err("app load failed, err {}", .{err});
                    };
                },
                .native_window_destroyed => {
                    if (state.window) |_| {
                        state.glState.unload();
                        state.window = null;
                    }
                },
                .native_window_redraw_needed => {},
                .native_window_resized => |window| {
                    const newWidth = c.ANativeWindow_getWidth(window);
                    const newHeight = c.ANativeWindow_getHeight(window);
                    if (newWidth != state.glState.screenSize[0] or newHeight != state.glState.screenSize[1]) {
                        state.glState.unload();
                        state.glState.load(window) catch |err| {
                            std.log.err("Failed to load GL state err {}", .{err});
                        };
                    }
                },
                .pause => {},
                .resume_ => {},
                .save_instance_state => {},
                .start => {},
                .stop => {},
                .window_focus_changed => |focus| {
                    _ = focus;
                    // if (focus) {
                    //     if (c.ASensorEventQueue_enableSensor(state.sensorEventQueue, state.rotationSensor) != 0) {
                    //         std.log.err("Failed to enable rotation sensor", .{});
                    //     } else {
                    //         const usecRate = 1 * 1000 * 1000 / 60;
                    //         if (c.ASensorEventQueue_setEventRate(state.sensorEventQueue, state.rotationSensor, usecRate) != 0) {
                    //             std.log.err("Failed to set rotation sensor event rate", .{});
                    //         }
                    //     }
                    // } else {
                    //     if (c.ASensorEventQueue_disableSensor(state.sensorEventQueue, state.rotationSensor) != 0) {
                    //         std.log.err("Failed to disable rotation sensor", .{});
                    //     }
                    // }
                },
            }
        }

        while (state.keyInputQueue.dequeue()) |data| {
            const ACTION_DOWN = 0;
            const ACTION_UP = 1;
            switch (data.action) {
                ACTION_DOWN => {
                    if (data.keyCode == c.AKEYCODE_BACK) {
                        app.onBack();
                    } else if (data.keyCode == c.AKEYCODE_DEL) {
                        // Backspace.
                        app.inputState.addUtf32(&.{8});
                    } else if (data.codePoint != 0) {
                        const utf32 = [1]u32 {data.codePoint};
                        app.inputState.addUtf32(&utf32);
                    }
                },
                ACTION_UP => {},
                else => {
                    std.log.err("Unknown key input action={}", .{data.action});
                },
            }
        }

        while (true) {
            const timeout = 0;
            var events: c_int = undefined;
            var data: ?*anyopaque = undefined;
            const identInt = c.ALooper_pollAll(timeout, null, &events, &data);
            if (identInt <= 0) {
                break;
            }
            switch (identInt) {
                LOOPER_IDENT_INPUT => {
                    std.debug.assert(state.inputQueue != null);
                    var event: ?*c.AInputEvent = undefined;
                    while (c.AInputQueue_getEvent(state.inputQueue, &event) >= 0) {
                        if (c.AInputQueue_preDispatchEvent(state.inputQueue, event) != 0) {
                            continue;
                        }
                        var handled: c_int = 0;
                        if (event) |e| {
                            if (onInputEvent(app, e, state.glState.screenSize)) {
                                handled = 1;
                            }
                        }
                        c.AInputQueue_finishEvent(state.inputQueue, event, handled);
                    }
                },
                // LOOPER_IDENT_SENSOR => {
                //     var event: c.ASensorEvent = undefined;
                //     while (c.ASensorEventQueue_getEvents(state.sensorEventQueue, &event, 1) > 0) {
                //         //state.shouldDraw = true;
                //         // r = event.unnamed_0.unnamed_0.vector.unnamed_0.unnamed_0.x;
                //         // g = event.unnamed_0.unnamed_0.vector.unnamed_0.unnamed_0.y;
                //         // b = event.unnamed_0.unnamed_0.vector.unnamed_0.unnamed_0.z;
                //     }
                // },
                else => {},
            }
        }

        if (state.glState.display != null) {
            c.glClearColor(0.0, 0.0, 0.0, 0.0);
            c.glClearDepthf(1.0);
            c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);

            const screenSize = state.glState.screenSize;
            const timestampUs = std.time.microTimestamp();
            const scrollY = 0;
            _ = hooks.updateAndRender(app, screenSize, timestampUs, scrollY);

            printAllGlErrors();
            const result = c.eglSwapBuffers(state.glState.display, state.glState.surface);
            if (result != c.EGL_TRUE) {
                std.log.err("eglSwapBuffers result={} eglGetError={}", .{result, c.eglGetError()});
            }
        }
    }
}

fn Java_com_kapricornmedia_zigkm_MainActivity_onKeyInput(env: *c.JNIEnv, this: c.jobject, action: c.jint, keyCode: c.jint, codePoint: c.jint) callconv(.c) void
{
    _ = env;
    _ = this;

    if (keyCode == 0 and codePoint == 0) {
        return;
    }

    const data = KeyInputData {
        .action = action,
        .keyCode = keyCode,
        .codePoint = @intCast(codePoint),
    };
    if (_state.keyInputQueue.enqueue(data)) {
        c.ALooper_wake(_state.looper);
    } else {
        std.log.err("Failed to enqueue keyInputData={}", .{data});
    }
}

fn Java_com_kapricornmedia_zigkm_MainActivity_onHttp(env: *c.JNIEnv, this: c.jobject, method: c.jint, url: c.jstring, code: c.jint, data: c.jbyteArray) callconv(.c) void
{
    _ = this;

    _ = android.JNIEnvGuard.init(env) orelse return;
    defer android.JNIEnvGuard.deinit();

    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    const methodZ: std.http.Method = switch (method) {
        0 => .GET,
        1 => .POST,
        else => .GET,
    };
    const urlZ = android.jniToZigString(env, url, a) catch return;
    const dataZ = android.jniToZigByteArray(env, data, a) catch return;
    _state.getApp().onHttp(methodZ, urlZ, @intCast(code), dataZ, a);
}

fn Java_com_kapricornmedia_zigkm_MainActivity_onAppLink(env: *c.JNIEnv, this: c.jobject, url: c.jstring) callconv(.c) void
{
    _ = this;

    _ = android.JNIEnvGuard.init(env) orelse return;
    defer android.JNIEnvGuard.deinit();

    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    const urlZ = android.jniToZigString(env, url, a) catch return;
    _state.getApp().onAppLink(urlZ, a);
}

fn Java_com_kapricornmedia_zigkm_MainActivity_onDownloadFile(env: *c.JNIEnv, this: c.jobject, url: c.jstring, fileName: c.jstring, success: c.jboolean) callconv(.c) void
{
    _ = this;

    _ = android.JNIEnvGuard.init(env) orelse return;
    defer android.JNIEnvGuard.deinit();

    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    const urlZ = android.jniToZigString(env, url, a) catch return;
    const fileNameZ = android.jniToZigString(env, fileName, a) catch return;
    _state.getApp().onDownloadFile(urlZ, fileNameZ, success != 0, a);
}

fn ANativeActivity_onCreate(activity: *c.ANativeActivity, savedState: *anyopaque, savedStateSize: usize) callconv(.c) void
{
    _ = savedState;
    _ = savedStateSize;

    std.log.info("ANativeActivity_onCreate", .{});

    activity.callbacks.*.onConfigurationChanged = onConfigurationChanged;
    activity.callbacks.*.onContentRectChanged = onContentRectChanged;
    activity.callbacks.*.onDestroy = onDestroy;
    activity.callbacks.*.onInputQueueCreated = onInputQueueCreated;
    activity.callbacks.*.onInputQueueDestroyed = onInputQueueDestroyed;
    activity.callbacks.*.onLowMemory = onLowMemory;
    activity.callbacks.*.onNativeWindowCreated = onNativeWindowCreated;
    activity.callbacks.*.onNativeWindowDestroyed = onNativeWindowDestroyed;
    activity.callbacks.*.onNativeWindowRedrawNeeded = onNativeWindowRedrawNeeded;
    activity.callbacks.*.onNativeWindowResized = onNativeWindowResized;
    activity.callbacks.*.onPause = onPause;
    activity.callbacks.*.onResume = onResume;
    activity.callbacks.*.onSaveInstanceState = onSaveInstanceState;
    activity.callbacks.*.onStart = onStart;
    activity.callbacks.*.onStop = onStop;
    activity.callbacks.*.onWindowFocusChanged = onWindowFocusChanged;

    const appMem = std.heap.page_allocator.alignedAlloc(u8, .@"32", defs.MEMORY_FOOTPRINT) catch |err| {
        std.log.err("Failed to allocate app memory, error {}", .{err});
        return;
    };
    @memset(appMem, 0);

    // Set up android state and start app thread.
    const androidState = std.heap.page_allocator.create(AndroidState) catch |err| {
        std.log.err("Failed to allocate android state, error {}", .{err});
        return;
    };
    _state = androidState;
    activity.instance = androidState;

    androidState.* = .{
        .memory = appMem,
        .activity = activity,
        .signalQueue = .{},
        .keyInputQueue = .{},
        .status = .none,
        .appThread = undefined,

        .config = undefined,
        .looper = undefined,
        .inputQueue = null,
        .window = null,
        .contentRect = .{},

        .sensorManager = undefined,
        .rotationSensor = undefined,
        .sensorEventQueue = undefined,

        .timeStartS = 0,

        .glState = .{},
    };

    androidState.appThread = std.Thread.spawn(.{}, androidMain, .{androidState}) catch |err| {
        std.log.err("Failed to spawn app thread error {}", .{err});
        return;
    };

    std.log.info("app running", .{});
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn
{
    std.log.err("PANIC: {s}", .{msg});
    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

fn zigToAndroidLogLevel(comptime zigLevel: std.log.Level) c_int
{
    return switch (zigLevel) {
        .debug  => c.ANDROID_LOG_DEBUG,
        .info   => c.ANDROID_LOG_INFO,
        .warn   => c.ANDROID_LOG_WARN,
        .err    => c.ANDROID_LOG_ERROR,
    };
}

fn androidLogWrite(comptime level: std.log.Level, str: [:0]const u8) void
{
    const androidLevel = zigToAndroidLogLevel(level);
    _ = c.__android_log_write(androidLevel, "com.kapricornmedia.zigkm", @ptrCast(str));
}

fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void
{
    var logBuffer: [2048]u8 = undefined;
    const scopeStr = if (scope == .default) "[ ] " else "[" ++ @tagName(scope) ++ "] ";
    const fullFormat = scopeStr ++ format;
    const str = std.fmt.bufPrintZ(logBuffer[0..], fullFormat, args) catch {
        androidLogWrite(std.log.Level.err, "Log too long - failed to print");
        return;
    };
    androidLogWrite(level, str);
}

pub fn register() void
{
    @export(&Java_com_kapricornmedia_zigkm_MainActivity_onKeyInput, .{.name = "Java_com_kapricornmedia_zigkm_MainActivity_onKeyInput", .linkage = .strong});
    @export(&Java_com_kapricornmedia_zigkm_MainActivity_onHttp, .{.name = "Java_com_kapricornmedia_zigkm_MainActivity_onHttp", .linkage = .strong});
    @export(&Java_com_kapricornmedia_zigkm_MainActivity_onAppLink, .{.name = "Java_com_kapricornmedia_zigkm_MainActivity_onAppLink", .linkage = .strong});
    @export(&Java_com_kapricornmedia_zigkm_MainActivity_onDownloadFile, .{.name = "Java_com_kapricornmedia_zigkm_MainActivity_onDownloadFile", .linkage = .strong});
    @export(&ANativeActivity_onCreate, .{.name = "ANativeActivity_onCreate", .linkage = .strong});
}
