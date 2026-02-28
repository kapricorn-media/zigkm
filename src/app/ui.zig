const std = @import("std");
const A = std.mem.Allocator;
const OOM = A.Error;

const m = @import("zigkm-math");
const zkl = @import("zigkm-lib");

const assets = @import("assets.zig");
const input = @import("input.zig");
const render = @import("render.zig");
const tree = @import("tree.zig");

const DEFAULT_DEPTH = 0.5;

pub fn State(comptime maxMemory: usize) type
{
    const maxElements = maxMemory / @sizeOf(Element);
    if (maxElements == 0) {
        unreachable;
    }

    const S = struct {
        elements: zkl.BoundedArray(Element, maxElements),
        parent: *Element,
        active: ?*Element,
        screenSize: m.V2,
        frame: u64,
        defaultDepth: f32,

        const Self = @This();

        fn findElementWithHash(self: *Self, hash: u64) ?*Element
        {
            for (self.elements.slice()) |*e| {
                if (e.hash == hash) {
                    return e;
                }
            }
            return null;
        }

        pub fn clear(self: *Self) void
        {
            self.elements.len = 1;

            // add root and set as parent
            std.debug.assert(self.elements.buffer.len > 0);
            self.elements.buffer[0] = .{
                .firstChild = &self.elements.buffer[0],
                .lastChild = &self.elements.buffer[0],
                .nextSibling = &self.elements.buffer[0],
                .prevSibling = &self.elements.buffer[0],
                .parent = &self.elements.buffer[0],

                .hash = 0,
                .lastFrameTouched = 0,

                .data = .{
                    .size = .{.{.children = {}}, .{.children = {}}},
                },
                .pos = .{0, 0},
                .offset = .{0, 0},
                .size = .{0, 0},
                .hover = false,
                .pressed = .{},
                .clicked = .{},
                .scrollVel = .{0, 0},
            };
            self.parent = &self.elements.buffer[0];
            self.active = null;
            self.frame = 0;
            self.defaultDepth = DEFAULT_DEPTH;

            input.setSoftwareKeyboardVisible(false);
        }

        pub fn prepare(self: *Self, inputState: *const input.InputState, screenSize: m.V2, deltaS: f32, a: A) void
        {
            self.screenSize = screenSize;

            var treeIt = tree.TreeIterator(Element).init(a);
            var newActive: ?*Element = null;
            {
                // UI interactions based on current frame's input and last frame's layout.
                for (self.elements.slice()) |*e| {
                    e.hover = false;
                    e.pressed = .{};
                    e.clicked = .{};
                }

                const root = &self.elements.slice()[0];
                const mousePosF: m.V2 = @floatFromInt(inputState.mouseState.pos);

                treeIt.prepare(root, .PostOrder) catch return;
                while (treeIt.next() catch return) |e| {
                    if (!isEnabled(e)) {
                        continue;
                    }

                    const pos = getElementRenderPos(e, screenSize);
                    const size: m.V2 = .{e.size[0], e.size[1]};
                    const rect = m.Rect.init(pos, size);
                    const maxScrollX = getMaxScrollX(e);
                    const maxScrollY = getMaxScrollY(e);
                    switch (inputState.pointerSource) {
                        .Mouse => {
                            if (m.vInRect(mousePosF, rect)) {
                                e.hover = true;
                                if (e.data.flags.clickable) {
                                    for (inputState.mouseState.clickEvents.slice()) |c| {
                                        const cPos: m.V2 = @floatFromInt(c.pos);
                                        if (c.clickType == .Left and c.down and m.vInRect(cPos, rect)) {
                                            // e.clicked = true;
                                            // self.active = e;
                                            // break;
                                            if (shouldBeActive(newActive, e)) {
                                                newActive = e;
                                            }
                                        }
                                    }
                                }
                                if (e.data.flags.scrollable) {
                                    if (e.data.targetOffsetX == null) {
                                        e.offset[0] += @floatFromInt(inputState.mouseState.wheelDelta[0]);
                                        e.offset[0] = std.math.clamp(e.offset[0], -maxScrollX, 0);
                                    }
                                    if (e.data.targetOffsetY == null) {
                                        e.offset[1] -= @floatFromInt(inputState.mouseState.wheelDelta[1]);
                                        e.offset[1] = std.math.clamp(e.offset[1], -maxScrollY, 0);
                                    }
                                }
                            }
                        },
                        .Touch => {
                            if (e.data.flags.clickable) {
                                for (inputState.touchState.activeTouches.slice()) |t| {
                                    const tPos: m.V2 = @floatFromInt(t.getPos());
                                    if (t.ending and t.isTap() and m.vInRect(tPos, rect)) {
                                        if (shouldBeActive(newActive, e)) {
                                            newActive = e;
                                        }
                                    }
                                    if (m.vInRect(tPos, rect)) {
                                        e.pressed.left = true;
                                    }
                                }
                            }
                            if (e.data.flags.scrollable) {
                                for (inputState.touchState.activeTouches.slice()) |t| {
                                    const tPrevPos: m.V2 = @floatFromInt(t.getPrevPos() orelse continue);
                                    const tPosStart: m.V2 = @floatFromInt(t.posStart);
                                    if (m.vInRect(tPosStart, rect)) {
                                        if (t.ending) {
                                            const meanVel = t.getWeightedVel();
                                            e.scrollVel = .{meanVel[0], -meanVel[1]};
                                        } else {
                                            e.scrollVel = .{0, 0};
                                            const tPos: m.V2 = @floatFromInt(t.getPos());
                                            if (e.data.targetOffsetX == null) {
                                                e.offset[0] += tPos[0] - tPrevPos[0];
                                                e.offset[0] = std.math.clamp(e.offset[0], -maxScrollX, 0);
                                            }
                                            if (e.data.targetOffsetY == null) {
                                                e.offset[1] -= tPos[1] - tPrevPos[1];
                                                e.offset[1] = std.math.clamp(e.offset[1], -maxScrollY, 0);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (newActive) |active| {
                active.clicked.left = true;
                self.active = active;
            }

            // Unset active element on unrelated clicks/taps.
            // Also, show or hide the software keyboard accordingly.
            if (inputState.mouseState.anyClick(.Left) or inputState.touchState.anyTap()) {
                if (self.active) |active| {
                    if (!active.clicked.left) {
                        input.setSoftwareKeyboardVisible(false);
                        self.active = null;
                    } else if (active.data.flags.opensKeyboard) {
                        input.setSoftwareKeyboardVisible(true);
                    }
                }
            }

            for (self.elements.slice()) |*e| {
                if (!isEnabled(e) or !e.data.flags.scrollable) continue;

                const maxScroll = .{getMaxScrollX(e), getMaxScrollY(e)};
                const hasTargetOffset = [2]bool {e.data.targetOffsetX != null, e.data.targetOffsetY != null};
                const targetOffset = .{e.data.targetOffsetX orelse 0, e.data.targetOffsetY orelse 0};
                inline for (0..2) |axis| {
                    if (hasTargetOffset[axis]) {
                        e.scrollVel[axis] = 0;
                        e.offset[axis] = m.dampTo(e.offset[axis], targetOffset[axis], 0.001, deltaS);
                    } else {
                        e.offset[axis] += e.scrollVel[axis];
                        if (e.offset[axis] < -maxScroll[axis]) {
                            e.offset[axis] = -maxScroll[axis];
                            e.scrollVel[axis] = 0;
                        } else if (e.offset[axis] > 0) {
                            e.offset[axis] = 0;
                            e.scrollVel[axis] = 0;
                        }

                        const deccelerationRate = 0.05;
                        const zeroSpeed = 0.1;
                        e.scrollVel[axis] = m.dampTo(e.scrollVel[axis], 0, deccelerationRate, deltaS);
                        if (std.math.approxEqAbs(f32, e.scrollVel[axis], 0.0, zeroSpeed)) {
                            e.scrollVel[axis] = 0.0;
                        }
                    }
                }
            }

            self.frame += 1;

            self.parent = &self.elements.buffer[0];
            for (self.elements.slice()) |*e| {
                e.parent = e;
                e.firstChild = e;
                e.lastChild = e;
                e.nextSibling = e;
                e.prevSibling = e;
            }
        }

        pub fn pushParent(self: *Self, e: *Element) void
        {
            self.parent = e;
        }

        pub fn popParent(self: *Self) void
        {
            std.debug.assert(self.parent.parent != self.parent);
            self.parent = self.parent.parent;
        }

        pub fn setDefaultDepth(self: *Self, depth: f32) f32
        {
            const prev = self.defaultDepth;
            self.defaultDepth = depth;
            return prev;
        }

        pub fn elementWithHash(self: *Self, hash: u64, data: ElementData) !*Element
        {
            var new = false;
            var e: *Element = blk: {
                if (self.findElementWithHash(hash)) |e| {
                    break :blk e;
                }

                const e = try self.elements.addOne();
                new = true;
                break :blk e;
            };

            if (!new and e.lastFrameTouched == self.frame) {
                std.log.err("Element with dupe hash {} {}", .{hash, data});
                unreachable;
            }
            if (data.size[1] == .text and data.size[0] != .text and data.size[0] != .pixels) {
                // We only support text sizes with other parent/child-independent sizes.
                std.log.err("Unsupported size params {} {}", .{hash, data});
                unreachable;
            }

            e.parent = self.parent;
            if (self.parent.firstChild == self.parent) {
                // parent has no children yet
                self.parent.firstChild = e;
                self.parent.lastChild = e;
            }
            e.firstChild = e;
            e.lastChild = e;
            e.nextSibling = e;
            e.prevSibling = self.parent.lastChild;
            self.parent.lastChild.nextSibling = e;
            self.parent.lastChild = e;

            e.hash = hash;
            e.lastFrameTouched = self.frame;

            e.data = data;
            if (e.data.depth == null) {
                e.data.depth = self.defaultDepth;
            }

            if (new) {
                e.pos = .{0, 0};
                e.offset = .{0, 0};
                e.size = .{0, 0};
                e.hover = false;
                e.pressed = .{};
                e.clicked = .{};
                e.scrollVel = .{0, 0};
            }

            return e;
        }

        pub fn element(self: *Self, hashable: anytype, data: ElementData) OOM!*Element
        {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, hashable, .Deep);
            const hash = hasher.final();
            return self.elementWithHash(hash, data);
        }

        fn layoutWithTreeIt(self: *Self, treeIt: *tree.TreeIterator(Element)) OOM!void
        {
            { // trim outdated elements
                var i: usize = 1;
                while (i < self.elements.len) {
                    const e = &self.elements.buffer[i];
                    if (e.lastFrameTouched != self.frame) {
                        self.elements.buffer[i] = self.elements.buffer[self.elements.len - 1];
                        self.elements.len -= 1;
                        continue;
                    }
                    i += 1;
                }
            }

            // Calculate independent sizes
            for (self.elements.slice()) |*e| {
                var textSize = [2]f32 {0, 0};
                if (e.data.text) |t| {
                    const maxWidth = switch (e.data.size[0]) {
                        .pixels => |v| v,
                        else => null,
                    };
                    const textRect = render.textRect(t.text, t.fontData, maxWidth);
                    const textSizeVec = textRect.size();
                    textSize[0] = textSizeVec[0];
                    textSize[1] = textSizeVec[1];
                }
                inline for (0..2) |axis| {
                    switch (e.data.size[axis]) {
                        .pixels => |v| {
                            e.size[axis] = v;
                        },
                        .text => {
                            e.size[axis] = textSize[axis];
                        },
                        .parentFrac, .children => {},
                    }
                }
            }

            var root = &self.elements.slice()[0];

            // Calculate upward-dependent sizes, except for .parentFrac -> .children
            try treeIt.prepare(root, .PreOrder);
            while (try treeIt.next()) |e| {
                if (e != e.parent) {
                    inline for (0..2) |axis| {
                        if (e.data.size[axis] == .parentFrac and e.parent.data.size[axis] != .children) {
                            e.size[axis] = e.parent.size[axis] * e.data.size[axis].parentFrac;
                        }
                    }
                }
            }

            // Calculate downward-dependent sizes
            try treeIt.prepare(root, .PostOrder);
            while (try treeIt.next()) |e| {
                if (e.firstChild != e) {
                    inline for (0..2) |axis| {
                        if (e.data.size[axis] == .children) {
                            e.size[axis] = getChildrenSize(e, axis);
                        }
                    }
                }
            }

            // Calculate upward-dependent sizes, for .parentFrac -> .children
            try treeIt.prepare(root, .PreOrder);
            while (try treeIt.next()) |e| {
                if (e != e.parent) {
                    inline for (0..2) |axis| {
                        if (e.data.size[axis] == .parentFrac and e.parent.data.size[axis] == .children) {
                            e.size[axis] = e.parent.size[axis] * e.data.size[axis].parentFrac;
                        }
                    }
                }
            }

            // Calculate positions
            try treeIt.prepare(root, .PreOrder);
            root.pos[0] = 0;
            root.pos[1] = 0;
            while (try treeIt.next()) |e| {
                if (!isEnabled(e)) continue;

                const prevOrNull = findFirstEnabledPrev(e);
                var pos = e.parent.pos;
                inline for (0..2) |axis| {
                    if (e.data.pos[axis]) |p| {
                        pos[axis] = p;
                    } else {
                        pos[axis] += e.parent.offset[axis];
                        if (prevOrNull) |prev| {
                            const stack = getStack(e.parent.data.flags, axis);
                            const float = getFloat(e.data.flags, axis);
                            const floatPrev = getFloat(prev.data.flags, axis);
                            if (stack and !float and !floatPrev) {
                                pos[axis] = prev.pos[axis];
                                pos[axis] += prev.size[axis];
                            }
                        }
                        if (getCenter(e.data.flags, axis)) {
                            pos[axis] += e.parent.size[axis] / 2;
                            pos[axis] -= e.size[axis] / 2;
                        }
                    }
                }
                e.pos = pos;
            }
        }

        pub fn layout(self: *Self, a: A) OOM!void
        {
            var treeIt = tree.TreeIterator(Element).init(a);
            try self.layoutWithTreeIt(&treeIt);
        }

        pub fn layoutAndDraw(self: *Self, renderState: *render.RenderState, a: A) OOM!void
        {
            var treeIt = tree.TreeIterator(Element).init(a);
            const root = &self.elements.slice()[0];
            try self.layoutWithTreeIt(&treeIt);

            var renderQueue = try a.create(render.RenderQueue);
            renderQueue.clear();

            // Calculate render positions and draw
            try treeIt.prepare(root, .PreOrder);
            while (try treeIt.next()) |e| {
                if (!isEnabled(e)) continue;

                const size: m.V2 = .{e.size[0], e.size[1]};
                const pos = getElementRenderPos(e, self.screenSize);
                const depth = e.data.depth orelse DEFAULT_DEPTH;
                var renderQuad = false;
                inline for (0..4) |i| {
                    renderQuad = renderQuad or @reduce(.Or, e.data.colors[i] != m.zero(4));
                }
                if (renderQuad) {
                    if (e.data.textureData) |td| {
                        renderQueue.quad2(pos, size, depth, e.data.cornerRadius, td.uvBottomLeft, td.uvSize, e.data.shadowSize, e.data.shadowColor, td.tex.texId, e.data.colors);
                    } else {
                        renderQueue.quad22(pos, size, depth, e.data.cornerRadius, m.zero(2), m.one(2), e.data.shadowSize, e.data.shadowColor, null, e.data.colors, false);
                    }
                }
                if (e.data.text) |t| {
                    const maxWidth = blk: {
                        switch (e.data.size[0]) {
                            .text => break :blk null,
                            else => break :blk e.size[0],
                        }
                    };
                    const textPosX = blk: {
                        switch (t.alignX) {
                            .left => break :blk pos[0],
                            .center => {
                                const textRect = render.textRect(t.text, t.fontData, maxWidth);
                                break :blk pos[0] + size[0] / 2 - textRect.size()[0] / 2;
                            },
                            .right => {
                                const textRect = render.textRect(t.text, t.fontData, maxWidth);
                                break :blk pos[0] + size[0] - textRect.size()[0];
                            },
                        }
                    };
                    const textPosY = blk: {
                        switch (t.alignY) {
                            .top => break :blk pos[1] + e.size[1] - t.fontData.ascent,
                            .center => {
                                const textRect = render.textRect(t.text, t.fontData, maxWidth);
                                break :blk pos[1] + (e.size[1] - textRect.size()[1]) / 2;
                            },
                            .bottom => break :blk pos[1],
                        }
                    };
                    const textPos: m.V2 = .{textPosX, textPosY};
                    renderQueue.textMaxWidth(t.text, textPos, depth, maxWidth, t.fontData, t.color);
                }
            }

            renderQueue.render(renderState, self.screenSize, a);
        }
    };
    return S;
}

fn shouldBeActive(current: ?*Element, new: *Element) bool
{
    if (current) |c| {
        const newDepth = new.data.depth orelse DEFAULT_DEPTH;
        const depth = c.data.depth orelse DEFAULT_DEPTH;
        return newDepth < depth;
    } else {
        return true;
    }
}

pub const SizeKind = enum {
    pixels,
    parentFrac,
    text,
    children,
};

pub const Size = union(SizeKind) {
    pixels: f32,
    parentFrac: f32,
    text: void,
    children: void,
};

pub const ElementFlags = packed struct {
    // layout
    enabled: bool = true,
    floatX: bool = false,
    floatY: bool = false,
    // centerX and centerY can only be used for a single child element within a parent
    centerX: bool = false,
    centerY: bool = false,
    childrenStackX: bool = false,
    childrenStackY: bool = true,

    // interaction
    clickable: bool = false,
    scrollable: bool = false,
    opensKeyboard: bool = false,
};

pub const TextAlignX = enum {
    left,
    center,
    right,
};

pub const TextAlignY = enum {
    top,
    center,
    bottom,
};

pub const WhichClick = packed struct {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
};

pub const ElementTextData = struct {
    text: []const u8,
    fontData: *const assets.FontData,
    alignX: TextAlignX = .left,
    alignY: TextAlignY = .top,
    color: m.V4,
};

pub const ElementTextureData = struct {
    tex: *const assets.TextureData,
    uvBottomLeft: m.V2 = .{0, 0},
    uvSize: m.V2 = .{1, 1},
};

pub const ElementData = struct {
    size: [2]Size = .{.{.children = {}}, .{.children = {}}},
    flags: ElementFlags = .{},
    colors: [4]m.V4 = .{m.zero(4)} ** 4,
    depth: ?f32 = null,
    cornerRadius: f32 = 0,
    shadowSize: f32 = 0,
    shadowColor: m.V4 = m.zero(4),
    text: ?ElementTextData = null,
    textureData: ?ElementTextureData = null,
    pos: [2]?f32 = .{null, null},
    targetOffsetX: ?f32 = null,
    targetOffsetY: ?f32 = null,
};

pub const Element = struct {
    // tree
    firstChild: *Self,
    lastChild: *Self,
    nextSibling: *Self,
    prevSibling: *Self,
    parent: *Self,

    // hash
    hash: u64,
    lastFrameTouched: u64,

    // data
    // Supplied by UI usage code every frame.
    data: ElementData,

    // Computed at the end of the frame, will "lag" by 1 frame.
    pos: [2]f32,
    offset: [2]f32,
    size: [2]f32,
    // Computed at the start of the frame, based on previous frame's data.
    hover: bool,
    pressed: WhichClick,
    clicked: WhichClick,
    scrollVel: [2]f32,

    const Self = @This();
};

fn getFloat(flags: ElementFlags, comptime axis: comptime_int) bool
{
    return if (axis == 0) flags.floatX else flags.floatY;
}

fn getStack(flags: ElementFlags, comptime axis: comptime_int) bool
{
    return if (axis == 0) flags.childrenStackX else flags.childrenStackY;
}

fn getCenter(flags: ElementFlags, comptime axis: comptime_int) bool
{
    return if (axis == 0) flags.centerX else flags.centerY;
}

fn getElementRenderPos(e: *Element, screenSize: m.V2) m.V2
{
    return .{e.pos[0], screenSize[1] - e.pos[1] - e.size[1]};
}

fn getChildrenSize(e: *Element, comptime axis: comptime_int) f32
{
    var size: f32 = 0;

    const stack = getStack(e.data.flags, axis);
    var child = e.firstChild;
    while (true) : (child = child.nextSibling) {
        const flags = child.data.flags;
        if (!flags.enabled) continue;

        const float = getFloat(flags, axis);
        if (float or !stack) {
            size = @max(size, child.size[axis]);
        } else {
            size += child.size[axis];
        }

        if (child.nextSibling == child) {
            break;
        }
    }
    return size;
}

fn findFirstEnabledPrev(e: *Element) ?*Element
{
    var ee = e;
    while (true) {
        const prev = ee.prevSibling;
        if (prev == ee) {
            return null;
        }
        if (prev.data.flags.enabled) {
            return prev;
        }
        ee = prev;
    }
}

/// Checks if e and all its parents are enabled.
fn isEnabled(e: *Element) bool
{
    var ee = e;
    while (true) {
        if (!ee.data.flags.enabled) {
            return false;
        }
        ee = ee.parent;
        if (ee == ee.parent) {
            return true;
        }
    }
}

fn getMaxScrollX(e: *Element) f32
{
    return @max(getChildrenSize(e, 0) - e.size[0], 0);
}

fn getMaxScrollY(e: *Element) f32
{
    return @max(getChildrenSize(e, 1) - e.size[1], 0);
}

test "layout"
{
    // All allocations done by these functions are temporary and don't free,
    // so memory leaks are expected. Use an arena to catch them all and free in bulk.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const screenSize: m.V2 = .{500, 400};
    const marginX = 50;
    const centerSize = screenSize[0] - marginX * 2;

    const size = 512 * 1024;
    var uiState = try allocator.create(State(size));
    uiState.clear();
    var inputState: input.InputState = undefined;
    inputState.clear();
    uiState.prepare(&inputState, screenSize, 0, allocator);

    // content
    {
        const content = try uiState.element(@src(), .{
            .size = .{
                .{.children = {}}, .{.children = {}},
            },
            .flags = .{
                .childrenStackX = true,
                .childrenStackY = false,
            },
        });

        uiState.pushParent(content);
        defer uiState.popParent();

        _ = try uiState.element(@src(), .{
            .size = .{
                .{.pixels = marginX}, .{.parentFrac = 1},
            },
        });

        // center content
        {
            const center = try uiState.element(@src(), .{
                .size = .{
                    .{.pixels = centerSize}, .{.children = {}},
                },
            });

            uiState.pushParent(center);
            defer uiState.popParent();

            _ = try uiState.element(@src(), .{
                .size = .{
                    .{.pixels = 200}, .{.pixels = 100},
                },
            });
        }

        _ = try uiState.element(@src(), .{
            .size = .{
                .{.pixels = marginX}, .{.parentFrac = 1},
            },
        });
    }

    _ = try uiState.element(@src(), .{
        .size = .{
            .{.pixels = screenSize[0]}, .{.pixels = 150},
        },
    });

    try uiState.layout(allocator);

    const elements = uiState.elements.slice();
    try std.testing.expectEqual(@as(usize, 1 + 6), elements.len); // root + 6 elements

    try std.testing.expectEqual([2]f32{0, 0}, elements[0].pos);
    try std.testing.expectEqual([2]f32{screenSize[0], 250}, elements[0].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[1].pos);
    try std.testing.expectEqual([2]f32{screenSize[0], 100}, elements[1].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[2].pos);
    try std.testing.expectEqual([2]f32{marginX, 100}, elements[2].size);

    try std.testing.expectEqual([2]f32{marginX, 0}, elements[3].pos);
    try std.testing.expectEqual([2]f32{centerSize , 100}, elements[3].size);

    try std.testing.expectEqual([2]f32{marginX, 0}, elements[4].pos);
    try std.testing.expectEqual([2]f32{200, 100}, elements[4].size);

    try std.testing.expectEqual([2]f32{screenSize[0] - marginX, 0}, elements[5].pos);
    try std.testing.expectEqual([2]f32{marginX, 100}, elements[5].size);

    try std.testing.expectEqual([2]f32{0, 100}, elements[6].pos);
    try std.testing.expectEqual([2]f32{screenSize[0], 150}, elements[6].size);
}

test "diagonal layout"
{
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const screenSize: m.V2 = .{500, 400};

    const size = 512 * 1024;
    var uiState = try allocator.create(State(size));
    uiState.clear();
    var inputState: input.InputState = undefined;
    inputState.clear();
    uiState.prepare(&inputState, screenSize, 0, allocator);

    const diag = try uiState.element(@src(), .{
        .size = .{.{.children = {}}, .{.children = {}}},
        .flags = .{.childrenStackX = true, .childrenStackY = true},
    });
    uiState.pushParent(diag);
    defer uiState.popParent();

    _ = try uiState.element(@src(), .{
        .size = .{.{.pixels = 50}, .{.pixels = 100}},
    });

    _ = try uiState.element(@src(), .{
        .size = .{.{.pixels = 50}, .{.pixels = 50}},
    });

    _ = try uiState.element(@src(), .{
        .size = .{.{.pixels = 200}, .{.pixels = 25}},
    });

    try uiState.layout(allocator);

    const elements = uiState.elements.slice();
    try std.testing.expectEqual(@as(usize, 1 + 4), elements.len);

    try std.testing.expectEqual([2]f32{0, 0}, elements[0].pos);
    try std.testing.expectEqual([2]f32{300, 175}, elements[0].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[1].pos);
    try std.testing.expectEqual([2]f32{300, 175}, elements[1].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[2].pos);
    try std.testing.expectEqual([2]f32{50, 100}, elements[2].size);

    try std.testing.expectEqual([2]f32{50, 100}, elements[3].pos);
    try std.testing.expectEqual([2]f32{50, 50}, elements[3].size);

    try std.testing.expectEqual([2]f32{100, 150}, elements[4].pos);
    try std.testing.expectEqual([2]f32{200, 25}, elements[4].size);
}

test "centerX+centerY"
{
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const screenSize: m.V2 = .{500, 400};

    const size = 512 * 1024;
    var uiState = try allocator.create(State(size));
    uiState.clear();
    var inputState: input.InputState = undefined;
    inputState.clear();
    uiState.prepare(&inputState, screenSize, 0, allocator);

    const parent = try uiState.element(@src(), .{
        .size = .{.{.pixels = 500}, .{.pixels = 400}},
    });
    uiState.pushParent(parent);
    defer uiState.popParent();

    _ = try uiState.element(@src(), .{
        .size = .{.{.pixels = 80}, .{.pixels = 200}},
        .flags = .{.centerX = true, .centerY = true},
    });

    try uiState.layout(allocator);

    const elements = uiState.elements.slice();
    try std.testing.expectEqual(@as(usize, 1 + 2), elements.len);

    try std.testing.expectEqual([2]f32{0, 0}, elements[0].pos);
    try std.testing.expectEqual([2]f32{500, 400}, elements[0].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[1].pos);
    try std.testing.expectEqual([2]f32{500, 400}, elements[1].size);

    try std.testing.expectEqual([2]f32{210, 100}, elements[2].pos);
    try std.testing.expectEqual([2]f32{80, 200}, elements[2].size);
}

test "centerY with children size"
{
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const screenSize: m.V2 = .{500, 400};

    const size = 512 * 1024;
    var uiState = try allocator.create(State(size));
    uiState.clear();
    var inputState: input.InputState = undefined;
    inputState.clear();
    uiState.prepare(&inputState, screenSize, 0, allocator);

    const parent = try uiState.element(@src(), .{
        .size = .{.{.pixels = 500}, .{.pixels = 400}},
    });
    uiState.pushParent(parent);
    defer uiState.popParent();

    const centered = try uiState.element(@src(), .{
        .size = .{.{.pixels = 200}, .{.children = {}}},
        .flags = .{.centerY = true},
    });
    uiState.pushParent(centered);
    defer uiState.popParent();

    _ = try uiState.element(@src(), .{
        .size = .{.{.parentFrac = 1}, .{.pixels = 20}},
    });
    _ = try uiState.element(@src(), .{
        .size = .{.{.parentFrac = 1}, .{.pixels = 100}},
    });
    _ = try uiState.element(@src(), .{
        .size = .{.{.parentFrac = 1}, .{.pixels = 2}},
    });

    try uiState.layout(allocator);

    const elements = uiState.elements.slice();
    try std.testing.expectEqual(@as(usize, 1 + 5), elements.len);

    try std.testing.expectEqual([2]f32{0, 0}, elements[0].pos);
    try std.testing.expectEqual([2]f32{500, 400}, elements[0].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[1].pos);
    try std.testing.expectEqual([2]f32{500, 400}, elements[1].size);

    const yPos = (400 - 122) / 2;
    try std.testing.expectEqual([2]f32{0, yPos}, elements[2].pos);
    try std.testing.expectEqual([2]f32{200, 122}, elements[2].size);

    try std.testing.expectEqual([2]f32{0, yPos}, elements[3].pos);
    try std.testing.expectEqual([2]f32{200, 20}, elements[3].size);

    try std.testing.expectEqual([2]f32{0, yPos + 20}, elements[4].pos);
    try std.testing.expectEqual([2]f32{200, 100}, elements[4].size);

    try std.testing.expectEqual([2]f32{0, yPos + 20 + 100}, elements[5].pos);
    try std.testing.expectEqual([2]f32{200, 2}, elements[5].size);
}

test "layout with scroll and float"
{
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const screenSize: m.V2 = .{500, 400};

    const size = 512 * 1024;
    var uiState = try allocator.create(State(size));
    uiState.clear();
    var inputState: input.InputState = undefined;
    inputState.clear();
    uiState.prepare(&inputState, screenSize, 0, allocator);

    {
        const scroll = try uiState.element(@src(), .{
            .size = .{
                .{.pixels = screenSize[0]}, .{.pixels = screenSize[1]},
            },
        });
        uiState.pushParent(scroll);
        defer uiState.popParent();

        const scrollContent = try uiState.element(@src(), .{
            .size = .{
                .{.pixels = screenSize[0]}, .{.children = {}},
            },
        });
        uiState.pushParent(scrollContent);
        defer uiState.popParent();

        const top = try uiState.element(@src(), .{
            .size = .{
                .{.pixels = 500}, .{.pixels = 50},
            },
        });
        uiState.pushParent(top);
        defer uiState.popParent();

        _ = try uiState.element(@src(), .{
            .size = .{
                .{.parentFrac = 1}, .{.parentFrac = 1},
            },
            .flags = .{
                .floatX = true,
                .floatY = true,
            },
        });

        _ = try uiState.element(@src(), .{
            .size = .{
                .{.parentFrac = 0.5}, .{.parentFrac = 1},
            },
            .flags = .{
                .floatX = true,
                .floatY = true,
            },
        });
    }

    try uiState.layout(allocator);

    const elements = uiState.elements.slice();
    try std.testing.expectEqual(@as(usize, 1 + 5), elements.len);

    try std.testing.expectEqual([2]f32{0, 0}, elements[0].pos);
    try std.testing.expectEqual([2]f32{screenSize[0], screenSize[1]}, elements[0].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[1].pos);
    try std.testing.expectEqual([2]f32{screenSize[0], screenSize[1]}, elements[1].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[2].pos);
    try std.testing.expectEqual([2]f32{500, 50}, elements[2].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[3].pos);
    try std.testing.expectEqual([2]f32{500, 50}, elements[3].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[4].pos);
    try std.testing.expectEqual([2]f32{500, 50}, elements[4].size);

    try std.testing.expectEqual([2]f32{0, 0}, elements[5].pos);
    try std.testing.expectEqual([2]f32{250, 50}, elements[5].size);
}

test "layout across frames"
{
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const screenSize = m.V2{1920, 1080};
    const size = 512 * 1024;
    var uiState = try allocator.create(State(size));
    uiState.clear();

    var inputState: input.InputState = undefined;
    inputState.clear();

    { // frame 1
        uiState.prepare(&inputState, screenSize, 0, allocator);

        const screen = try uiState.elementWithHash(1, .{
             .size = .{
                .{.pixels = 500}, .{.pixels = 500},
            },
        });

        uiState.pushParent(screen);
        defer uiState.popParent();

        _ = try uiState.elementWithHash(2, .{
            .size = .{
                .{.pixels = 50}, .{.parentFrac = 0.9},
            },
        });

        _ = try uiState.elementWithHash(3, .{
            .size = .{
                .{.pixels = 500}, .{.pixels = 20},
            },
        });

        try uiState.layout(allocator);

        const elements = uiState.elements.slice();
        try std.testing.expectEqual(@as(usize, 1 + 3), elements.len);

        try std.testing.expectEqual([2]f32{0, 0}, elements[0].pos);
        try std.testing.expectEqual([2]f32{500, 500}, elements[0].size);

        try std.testing.expectEqual([2]f32{0, 0}, elements[1].pos);
        try std.testing.expectEqual([2]f32{500, 500}, elements[1].size);

        try std.testing.expectEqual([2]f32{0, 0}, elements[2].pos);
        try std.testing.expectEqual([2]f32{50, 450}, elements[2].size);

        try std.testing.expectEqual([2]f32{0, 450}, elements[3].pos);
        try std.testing.expectEqual([2]f32{500, 20}, elements[3].size);
    }

    { // frame 2
        uiState.prepare(&inputState, screenSize, 0, allocator);

        const screen = try uiState.elementWithHash(1, .{
             .size = .{
                .{.pixels = 500}, .{.pixels = 500},
            },
        });

        uiState.pushParent(screen);
        defer uiState.popParent();

        _ = try uiState.elementWithHash(2, .{
            .size = .{
                .{.pixels = 50}, .{.parentFrac = 0.9},
            },
        });

        _ = try uiState.elementWithHash(3, .{
            .size = .{
                .{.pixels = 500}, .{.pixels = 20},
            },
        });

        try uiState.layout(allocator);

        const elements = uiState.elements.slice();
        try std.testing.expectEqual(@as(usize, 1 + 3), elements.len);

        try std.testing.expectEqual([2]f32{0, 0}, elements[0].pos);
        try std.testing.expectEqual([2]f32{500, 500}, elements[0].size);

        try std.testing.expectEqual([2]f32{0, 0}, elements[1].pos);
        try std.testing.expectEqual([2]f32{500, 500}, elements[1].size);

        try std.testing.expectEqual([2]f32{0, 0}, elements[2].pos);
        try std.testing.expectEqual([2]f32{50, 450}, elements[2].size);

        try std.testing.expectEqual([2]f32{0, 450}, elements[3].pos);
        try std.testing.expectEqual([2]f32{500, 20}, elements[3].size);
    }
}
