const std = @import("std");

const zkm = @import("zigkm");
const m = zkm.math;
const platform = @import("zigkm-platform");

const exports = @import("exports.zig");

const android_bindings = @import("android_bindings.zig");
const ios_bindings = @import("ios_bindings.zig");

pub const PointerSource = enum {
    Mouse,
    Touch,
};

pub const InputState = struct
{
    mouseState: MouseState,
    keyboardState: KeyboardState,
    deviceState: DeviceState,
    touchState: TouchState,
    pointerSource: PointerSource,
    fileDragState: FileDragState,

    const Self = @This();

    pub fn clear(self: *Self) void
    {
        self.mouseState.clear();
        self.keyboardState.clear();
        self.touchState.clear();
        self.pointerSource = .Mouse;
        self.fileDragState.clear();
    }

    pub fn updateStart(self: *Self) void
    {
        self.touchState.updateStart();
        self.fileDragState.updateStart();
    }

    pub fn updateEnd(self: *Self) void
    {
        self.mouseState.clear();
        self.keyboardState.clear();
        self.touchState.updateEnd();
        self.fileDragState.updateEnd();
    }

    pub fn addClickEvent(self: *Self, event: ClickEvent) void
    {
        self.mouseState.addClickEvent(event);
        self.pointerSource = .Mouse;
    }

    pub fn addWheelDelta(self: *Self, delta: m.V2i) void
    {
        self.mouseState.wheelDelta += delta;
    }

    pub fn addKeyEvent(self: *Self, event: KeyEvent) void
    {
        self.keyboardState.addKeyEvent(event);
    }

    pub fn addUtf32(self: *Self, utf32: []const u32) void
    {
        self.keyboardState.addUtf32(utf32);
    }

    pub fn addTouchEvent(self: *Self, event: TouchEvent) void
    {
        self.touchState.addTouchEvent(event);
        self.pointerSource = .Touch;
    }

    pub fn addFileDragEvent(self: *Self, event: FileDragEvent) void
    {
        self.fileDragState.addFileDragEvent(event);
    }
};

pub const ClickType = enum {
    Left,
    Middle,
    Right,
    Other,
};

pub const ClickEvent = struct {
    pos: m.V2i,
    clickType: ClickType,
    down: bool,
};

pub const MouseState = struct {
    pos: m.V2i,
    wheelDelta: m.V2i,
    clickEvents: zkm.BoundedArray(ClickEvent, 64),

    const Self = @This();

    pub fn anyClick(self: *const Self, clickType: ClickType) bool
    {
        for (self.clickEvents.slice()) |c| {
            if (c.clickType == clickType and c.down) {
                return true;
            }
        }
        return false;
    }

    fn clear(self: *Self) void
    {
        self.wheelDelta = .{0, 0};
        self.clickEvents.len = 0;
    }

    fn addClickEvent(self: *Self, event: ClickEvent) void
    {
        const e = self.clickEvents.addOne() catch return;
        e.* = event;
    }
};

pub const KeyEvent = struct {
    keyCode: i32,
    down: bool,
};

pub const KeyboardState = struct {
    keyEvents: zkm.BoundedArray(KeyEvent, 64),
    utf32: zkm.BoundedArray(u32, 4096),

    const Self = @This();

    fn clear(self: *Self) void
    {
        self.keyEvents.len = 0;
        self.utf32.len = 0;
    }

    fn addKeyEvent(self: *Self, event: KeyEvent) void
    {
        const k = self.keyEvents.addOne() catch return;
        k.* = event;
    }

    fn addUtf32(self: *Self, utf32: []const u32) void
    {
        self.utf32.appendSlice(utf32) catch return;
    }

    pub fn keyDown(self: Self, keyCode: i32) bool
    {
        var latestDown = false;
        for (self.keyEvents.slice()) |e| {
            if (e.keyCode == keyCode) {
                latestDown = e.down;
            }
        }
        return latestDown;
    }
};

pub const DeviceState = struct {
    angles: m.V3,
};

pub const TouchPhase = enum
{
    Begin,
    Still,
    Move,
    End,
    Cancel,
};

pub const TouchEvent = struct
{
    id: u64,
    pos: m.V2i,
    tapCount: u32,
    phase: TouchPhase,
};

const ActiveTouch = struct
{
    id: u64,
    new: bool, // new this frame?
    ending: bool, // ending this frame?
    updated: bool, // updated this frame? internal
    posStart: m.V2i,
    i: u32, // index of current pos
    n: u32, // number of active elements in pos
    pos: [10]m.V2i,

    const Self = @This();

    pub fn isTap(self: *const Self) bool
    {
        // TODO: actually, if we started in one point, scrolled, then came back to that point,
        // we should still not count that as a tap...
        const thresholdPixels = 10;
        const pos = self.getPos();
        return m.magSqI(2, pos - self.posStart) < (thresholdPixels * thresholdPixels);
    }

    pub fn getPos(self: *const Self) m.V2i
    {
        std.debug.assert(self.i < self.pos.len);
        std.debug.assert(self.n != 0);
        std.debug.assert(self.n <= self.pos.len);

        return self.pos[self.i];
    }

    pub fn getPrevPos(self: *const Self) ?m.V2i
    {
        std.debug.assert(self.i < self.pos.len);
        std.debug.assert(self.n <= self.pos.len);

        if (self.n <= 1) {
            return null;
        }
        const prevInd = if (self.i == 0) self.pos.len - 1 else self.i - 1;
        return self.pos[prevInd];
    }

    pub fn getWeightedVel(self: *const Self) m.V2
    {
        std.debug.assert(self.i < self.pos.len);
        std.debug.assert(self.n != 0);
        std.debug.assert(self.n <= self.pos.len);

        const weights = [10]f32 {
            0.5,
            3.0,
            2.0,
            1.5,
            1.0,
            0.75,
            0.5,
            0.4,
            0.3,
            0.2,
        };

        var mean = m.zero(2);

        var i = self.i;
        var n: u32 = 0;
        while (n < self.n - 1) : (n += 1) {
            const iPrev = if (i == 0) @as(u32, @intCast(self.pos.len - 1)) else i - 1;
            const delta = self.pos[i] - self.pos[iPrev];
            mean = mean + @as(m.V2, @floatFromInt(delta)) * m.splat(2, weights[n]);
            i = iPrev;
        }

        return mean / m.splat(2, @floatFromInt(self.n));
    }

    fn addPos(self: *Self, pos: m.V2i) void
    {
        std.debug.assert(self.i < self.pos.len);
        std.debug.assert(self.n <= self.pos.len);

        var newIndex = self.i + 1;
        if (newIndex >= self.pos.len) {
            newIndex = 0;
        }
        self.pos[newIndex] = pos;
        self.i = newIndex;

        if (self.n < self.pos.len) {
            self.n += 1;
        }
    }
};

pub const TouchState = struct
{
    touchEvents: zkm.BoundedArray(TouchEvent, 4096),
    activeTouches: zkm.BoundedArray(ActiveTouch, 64),

    const Self = @This();

    pub fn anyTap(self: *const Self) bool
    {
        for (self.activeTouches.slice()) |t| {
            if (t.ending and t.isTap()) {
                return true;
            }
        }
        return false;
    }

    fn clear(self: *Self) void
    {
        self.touchEvents.len = 0;
        self.activeTouches.len = 0;
    }

    fn addTouchEvent(self: *Self, event: TouchEvent) void
    {
        const e = self.touchEvents.addOne() catch return;
        e.* = event;
    }

    fn updateStart(self: *Self) void
    {
        for (self.activeTouches.slice()) |*t| {
            t.updated = false;
        }

        for (self.touchEvents.slice()) |e| {
            var foundIndex: usize = self.activeTouches.len;
            for (self.activeTouches.slice(), 0..) |touch, j| {
                if (e.id == touch.id) {
                    foundIndex = j;
                    break;
                }
            }

            if (foundIndex != self.activeTouches.len) {
                switch (e.phase) {
                    .Begin => {
                        std.log.err("begin phase on active touch event", .{});
                    },
                    .Still, .Move => {
                        self.activeTouches.buffer[foundIndex].addPos(e.pos);
                        self.activeTouches.buffer[foundIndex].updated = true;
                    },
                    .End, .Cancel => {
                        self.activeTouches.buffer[foundIndex].addPos(e.pos);
                        self.activeTouches.buffer[foundIndex].updated = true;
                        self.activeTouches.buffer[foundIndex].ending = true;
                    },
                }
            } else {
                if (e.phase != .Begin) {
                    std.log.err("missed begin for touch", .{});
                    continue;
                }
                var t = self.activeTouches.addOne() catch {
                    std.log.err("No more space for active touches", .{});
                    continue;
                };
                t.* = .{
                    .id = e.id,
                    .new = true,
                    .ending = false,
                    .updated = true,
                    .posStart = e.pos,
                    .i = 0,
                    .n = 0,
                    .pos = undefined,
                };
                t.addPos(e.pos);
            }
        }

        for (self.activeTouches.slice()) |*t| {
            if (!t.updated) {
                t.addPos(t.getPos());
            }
        }
    }

    fn updateEnd(self: *Self) void
    {
        var i: usize = 0;
        while (i < self.activeTouches.len) {
            if (self.activeTouches.buffer[i].ending) {
                self.activeTouches.buffer[i] = self.activeTouches.buffer[self.activeTouches.len - 1];
                self.activeTouches.len -= 1;
                continue; // don't increment i
            }

            self.activeTouches.buffer[i].new = false;
            i += 1;
        }

        self.touchEvents.len = 0;
    }
};

pub const FileDragPhase = enum {
    start,
    move,
    end,
};

pub const FileDragEvent = struct {
    pos: m.V2i,
    phase: FileDragPhase,
};

pub const ActiveFileDrag = struct {
    pos: m.V2i,
    new: bool, // new this frame?
    ending: bool, // ending this frame?
};

pub const FileDragState = struct {
    events: zkm.BoundedArray(FileDragEvent, 4096),
    active: ?ActiveFileDrag,

    const Self = @This();

    fn addFileDragEvent(self: *Self, event: FileDragEvent) void
    {
        self.events.append(event) catch return;
    }

    fn clear(self: *Self) void
    {
        self.events.len = 0;
        self.active = null;
    }

    fn updateStart(self: *Self) void
    {
        for (self.events.slice()) |e| {
            var active: ActiveFileDrag = undefined;
            if (self.active) |a| {
                active = a;
            } else {
                active = .{
                    .pos = e.pos,
                    .new = true,
                    .ending = false,
                };
            }
            active.pos = e.pos;
            switch (e.phase) {
                .start => {
                    active.new = true;
                },
                .move => {},
                .end => {
                    active.ending = true;
                },
            }
            self.active = active;
        }
    }

    fn updateEnd(self: *Self) void
    {
        if (self.active) |*a| {
            if (a.ending) {
                self.active = null;
            } else {
                a.new = false;
            }
        }
        self.events.len = 0;
    }
};

pub fn setSoftwareKeyboardVisible(visible: bool) void
{
    if (!@import("builtin").is_test) {
        switch (platform.platform) {
            .android => {
                android_bindings.displayKeyboard(visible);
            },
            .ios => {
                ios_bindings.setKeyboardVisible(exports._contextPtr, visible);
            },
            .web => {},
            .server => @compileError("Unsupported platform server"),
        }
    }
}
