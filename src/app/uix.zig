//! Helpers and wrapper utilities built on top of the core UI framework in "ui.zig".

const std = @import("std");

const m = @import("zigkm-math");
const platform = @import("zigkm-platform");

const assets = @import("assets.zig");
const input = @import("input.zig");
const ui = @import("ui.zig");
const wasm_bindings = @import("wasm_bindings.zig");

const OOM = std.mem.Allocator.Error;

const hideBuf = [1]u8{'*'} ** 1024;

pub fn xFromAspect(y: f32, size: m.V2) f32
{
    return y / size[1] * size[0];
}

pub fn yFromAspect(x: f32, size: m.V2) f32
{
    return x / size[0] * size[1];
}

pub fn xFromAspectTex(y: f32, textureData: *const assets.TextureData) f32
{
    return xFromAspect(y, @floatFromInt(textureData.size));
}

pub fn yFromAspectTex(x: f32, textureData: *const assets.TextureData) f32
{
    return yFromAspect(x, @floatFromInt(textureData.size));
}

pub fn spacerX(hashable: anytype, uiState: anytype, size: ui.Size) OOM!void
{
    _ = try uiState.element(hashable, .{.size = .{size, .{.parentFrac = 1}}});
}

pub fn spacerY(hashable: anytype, uiState: anytype, size: ui.Size) OOM!void
{
    _ = try uiState.element(hashable, .{.size = .{.{.parentFrac = 1}, size}});
}

pub fn color4(color: m.V4) [4]m.V4
{
    return .{color, color, color, color};
}

pub const Container = struct {
    e: *ui.Element,

    pub fn init(hashable: anytype, uiState: anytype, vertical: bool, data: ui.ElementData) OOM!Container
    {
        var d = data;
        d.flags.childrenStackX = !vertical;
        d.flags.childrenStackY = vertical;
        const e = try uiState.element(.{@src(), hashable}, d);
        uiState.pushParent(e);
        return .{.e = e};
    }

    pub fn deinit(self: Container, uiState: anytype) void
    {
        _ = self;
        uiState.popParent();
    }
};

const ElementPadResult = struct {
    outer: *ui.Element,
    inner: *ui.Element,
};

/// Pads are, in order: left, right, top, bottom.
pub fn elementPad(hashable: anytype, uiState: anytype, outerData: ui.ElementData, innerData: ui.ElementData, pad: [4]f32) OOM!ElementPadResult
{
    var outerDataOverride = outerData;
    outerDataOverride.size = .{.{.children = {}}, .{.children = {}}};
    outerDataOverride.flags.childrenStackX = true;
    outerDataOverride.flags.childrenStackY = true;
    const outer = try uiState.element(.{@src(), hashable}, outerDataOverride);
    uiState.pushParent(outer);
    defer uiState.popParent();

    _ = try uiState.element(.{@src(), hashable}, .{
        .size = .{.{.pixels = pad[0]}, .{.pixels = pad[2]}},
    });

    const inner = try uiState.element(.{@src(), hashable}, innerData);

    _ = try uiState.element(.{@src(), hashable}, .{
        .size = .{.{.pixels = pad[1]}, .{.pixels = pad[3]}},
    });

    return .{.outer = outer, .inner = inner};
}

pub const MarginXView = struct {
    pad: ElementPadResult,

    const Self = @This();

    pub fn init(hashable: anytype, uiState: anytype, width: f32, margin: f32, flags: ui.ElementFlags) OOM!Self
    {
        const pad = try elementPad(hashable, uiState, .{}, .{
            .size = .{.{.pixels = width - margin * 2}, .{.children = {}}},
            .flags = flags,
        }, [4]f32 {margin, margin, 0, 0});
        uiState.pushParent(pad.inner);

        return .{.pad = pad};
    }

    pub fn deinit(self: Self, uiState: anytype) OOM!void
    {
        _ = self;

        // Kind of hacky - we gotta pop twice for the inner and outer items of elementPad.
        uiState.popParent();
        uiState.popParent();
    }

    pub fn innerWidth(self: Self) f32
    {
        return self.pad.inner.data.size[0].pixels;
    }
};

pub const ScrollXView = struct {
    scroll: *ui.Element,

    const Self = @This();

    pub fn init(hashable: anytype, uiState: anytype, size: m.V2, colorsScroll: [4]m.V4, colorsContent: [4]m.V4) OOM!Self
    {
        const scroll = try uiState.element(.{@src(), hashable}, .{
            .size = .{.{.pixels = size[0]}, .{.pixels = size[1]}},
            .colors = colorsScroll,
            .flags = .{
                .clickable = true,
                .scrollable = true,
            },
        });
        uiState.pushParent(scroll);

        const scrollContent = try uiState.element(.{@src(), hashable}, .{
            .size = .{.{.children = {}}, .{.pixels = size[1]}},
            .colors = colorsContent,
            .flags = .{
                .childrenStackX = true,
                .childrenStackY = false,
            },
        });
        uiState.pushParent(scrollContent);

        return .{.scroll = scroll};
    }

    pub fn deinit(self: Self, uiState: anytype) void
    {
        _ = self;
        uiState.popParent();
        uiState.popParent();
    }
};

pub const ScrollYView = struct {
    scroll: *ui.Element,
    content: *ui.Element,

    const Params = struct {
        size: [2]ui.Size,
        colorsScroll: [4]m.V4 = .{m.zero(4), m.zero(4), m.zero(4), m.zero(4)},
        colorsContent: [4]m.V4 = .{m.zero(4), m.zero(4), m.zero(4), m.zero(4)},
    };

    pub fn init(hashable: anytype, uiState: anytype, params: Params) OOM!ScrollYView
    {
        const scroll = try uiState.element(.{@src(), hashable}, .{
            .size = params.size,
            .colors = params.colorsScroll,
            .flags = .{.scrollable = true},
        });
        uiState.pushParent(scroll);

        const scrollContent = try uiState.element(.{@src(), hashable}, .{
            .size = .{.{.parentFrac = 1}, .{.children = {}}},
            .colors = params.colorsContent,
        });
        uiState.pushParent(scrollContent);

        return .{
            .scroll = scroll,
            .content = scrollContent,
        };
    }

    pub fn deinit(self: ScrollYView, uiState: anytype) void
    {
        _ = self;
        uiState.popParent();
        uiState.popParent();
    }
};

pub const ScrollXViewSnappy = struct {
    scroll: ScrollXView,

    const Self = @This();

    pub fn init(hashable: anytype, i: *u32, n: u32, uiState: anytype, size: m.V2, colorsScroll: [4]m.V4, colorsContent: [4]m.V4) OOM!Self
    {
        var self = Self {
            .scroll = try ScrollXView.init(hashable, uiState, size, colorsScroll, colorsContent),
        };
        if (self.scroll.scroll.pressed) {
            const offsetX = -self.scroll.scroll.offset[0];
            const iF = (offsetX + size[0] / 2) / size[0];
            i.* = @intFromFloat(iF);
            i.* = std.math.clamp(i.*, 0, n);
        } else {
            const targetOffsetX = -size[0] * @as(f32, @floatFromInt(i.*));
            self.scroll.scroll.data.targetOffsetX = targetOffsetX;
            // self.scroll.scroll.offset[0] = targetOffsetX;
        }
        return self;
    }

    pub fn deinit(self: Self, uiState: anytype) void
    {
        self.scroll.deinit(uiState);
    }
};

pub const Accordion = struct {
    parent: *ui.Element,
    width: f32,
    open: *bool,

    const Self = @This();

    pub fn init(hashable: anytype, uiState: anytype, width: f32, open: *bool) OOM!Self
    {
        const acc = try uiState.element(.{@src(), hashable}, .{
            .size = .{.{.pixels = width}, .{.children = {}}},
            .flags = .{.clickable = true},
        });
        uiState.pushParent(acc);

        if (acc.clicked.left) {
            open.* = !open.*;
        }

        return .{
            .parent = acc,
            .width = width,
            .open = open,
        };
    }

    pub fn beginContent(self: Self, hashable: anytype, uiState: anytype) OOM!void
    {
        uiState.popParent();

        const content = try uiState.element(.{@src(), hashable}, .{
            .size = .{.{.pixels = self.width}, .{.children = {}}},
            .flags = .{.enabled = self.open.*},
        });
        uiState.pushParent(content);
    }

    pub fn deinit(self: Self, uiState: anytype) void
    {
        _ = self;
        uiState.popParent();
    }
};

const ButtonParams = struct {
    size: [2]ui.Size,
    flags: ui.ElementFlags = .{},
    colors: [4]m.V4 = .{m.zero(4), m.zero(4), m.zero(4), m.zero(4)},
    cornerRadius: f32 = 0,
    depth: ?f32 = null,
    text: ?ui.ElementTextData = null,
    textureData: ?ui.ElementTextureData = null,
};

pub fn button(hashable: anytype, uiState: anytype, params: ButtonParams) OOM!bool
{
    var flags = params.flags;
    flags.clickable = true;
    var element = try uiState.element(hashable, .{
        .size = params.size,
        .flags = flags,
        .colors = params.colors,
        .cornerRadius = params.cornerRadius,
        .text = params.text,
        .textureData = params.textureData,
    });
    if (params.depth) |d| {
        element.data.depth = d;
    }
    return element.clicked.left;
}

/// Helper type for managing textInput buffers.
pub fn TextInput(comptime size: u32) type
{
    const Buf = struct {
        buf: [size]u8 = [_]u8{0} ** size,

        const Self = @This();

        pub fn slice(self: *const Self) []const u8
        {
            const len = std.mem.indexOfScalar(u8, &self.buf, 0) orelse self.buf.len;
            return self.buf[0..len];
        }

        pub fn clear(self: *Self) void
        {
            @memset(&self.buf, 0);
        }
    };
    return Buf;
}

pub const TextInputParams = struct {
    textBuf: []u8,
    fontData: *const assets.FontData,
    alignX: ui.TextAlignX = .left,
    alignY: ui.TextAlignY = .center,
    textColor: m.V4,
    size: [2]ui.Size,
    colors: [4]m.V4,
    colorsActive: [4]m.V4,
    depth: ?f32 = null,
    cornerRadius: f32 = 0,
    hide: bool = false, // for sensitive inputs, like password fields
    multiline: bool = false,
    pad: [4]f32 = .{0, 0, 0, 0},
};

pub const TextInputResult = struct {
    element: *ui.Element,
    changed: bool,
    enter: bool,
    tab: bool,
};

pub fn textInput(hashable: anytype, uiState: anytype, inputState: *const input.InputState, params: TextInputParams) OOM!TextInputResult
{
    var result = TextInputResult {
        .element = undefined,
        .changed = false,
        .enter = false,
        .tab = false,
    };

    var sizeMinusPad = params.size;
    if (sizeMinusPad[0] == .pixels) {
        sizeMinusPad[0].pixels -= (params.pad[0] + params.pad[1]);
    }
    if (sizeMinusPad[1] == .pixels) {
        sizeMinusPad[1].pixels -= (params.pad[2] + params.pad[3]);
    }
    const element = try elementPad(.{@src(), hashable}, uiState, .{
        .flags = .{.clickable = true, .opensKeyboard = true},
        .colors = params.colors,
        .cornerRadius = params.cornerRadius,
    }, .{
        .size = sizeMinusPad,
    }, params.pad);

    result.element = element.outer;
    if (params.depth) |d| {
        element.outer.data.depth = d;
    }

    const textEnd = std.mem.indexOfScalar(u8, params.textBuf, 0) orelse params.textBuf.len;
    var newTextEnd = textEnd;
    if (uiState.active == element.outer) {
        if (platform.platform == .web) {
            // TODO is this laggy?
            // TODO position at cursor, not element
            wasm_bindings.focusTextInput(@intFromFloat(element.inner.pos[0]), @intFromFloat(element.inner.pos[1]));
        }
        var utf8Buf: [4]u8 = undefined;
        element.outer.data.colors = params.colorsActive;
        for (inputState.keyboardState.utf32.slice()) |u| {
            const utf8N = std.unicode.utf8Encode(@intCast(u), &utf8Buf) catch continue;
            if (utf8N == 0) continue;
            const utf8 = utf8Buf[0..utf8N];
            if (utf8.len == 1 and utf8[0] == 8) {
                if (newTextEnd > 0) {
                    var utf8View = std.unicode.Utf8View.init(params.textBuf[0..newTextEnd]) catch {
                        // Very weird if this happens, just clear buffer...
                        newTextEnd = 0;
                        continue;
                    };
                    var utf8It = utf8View.iterator();
                    var lastSliceSize: usize = 0;
                    while (utf8It.nextCodepointSlice()) |slice| {
                        lastSliceSize = slice.len;
                    }
                    @memset(params.textBuf[newTextEnd - lastSliceSize..newTextEnd], 0);
                    newTextEnd -= lastSliceSize;
                    result.changed = true;
                }
            } else if (utf8.len == 1 and utf8[0] == 9) {
                result.tab = true;
            } else if (utf8.len == 1 and (utf8[0] == 10 or utf8[0] == 13)) {
                if (params.multiline) {
                    if (newTextEnd < params.textBuf.len) {
                        params.textBuf[newTextEnd] = '\n';
                        newTextEnd += 1;
                        result.changed = true;
                    }
                }
                result.enter = true;
            } else {
                if (newTextEnd + utf8.len <= params.textBuf.len) {
                    @memcpy(params.textBuf[newTextEnd..newTextEnd + utf8.len], utf8);
                    newTextEnd += utf8.len;
                    result.changed = true;
                }
            }
        }
    }

    std.debug.assert(newTextEnd <= hideBuf.len);
    const buf = if (params.hide) hideBuf[0..newTextEnd] else params.textBuf[0..newTextEnd];
    element.inner.data.text = .{
        .text = buf,
        .fontData = params.fontData,
        .alignX = params.alignX,
        .alignY = params.alignY,
        .color = params.textColor,
    };

    return result;
}

const TestSetup = struct {
    const stateSize = 1024 * 1024;

    arena: std.heap.ArenaAllocator,
    uiState: *ui.State(stateSize),
    inputState: *input.InputState,

    const Self = @This();

    fn init() !Self
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = arena.allocator();

        var uiState = try allocator.create(ui.State(stateSize));
        uiState.clear();

        var inputState = try allocator.create(input.InputState);
        inputState.clear();

        uiState.prepare(inputState, m.zero(2), 0, allocator);

        return .{
            .arena = arena,
            .uiState = uiState,
            .inputState = inputState,
        };
    }

    fn deinit(self: *Self) void
    {
        self.arena.deinit();
    }
};

const TestExpected = struct {
    pos: ?[2]f32 = null,
    size: ?[2]f32 = null,
};

fn checkExpected(expected: []const TestExpected, elements: []ui.Element) !void
{
    try std.testing.expectEqual(expected.len, elements.len);
    for (expected, 0..) |e, i| {
        if (e.pos) |p| try std.testing.expectEqual(p, elements[i].pos);
        if (e.size) |s| try std.testing.expectEqual(s, elements[i].size);
    }
}

test "elementPad"
{
    var testSetup = try TestSetup.init();
    defer testSetup.deinit();
    const allocator = testSetup.arena.allocator();
    const uiState = testSetup.uiState;

    _ = try elementPad(@src(), uiState, .{}, .{
        .size = .{.{.pixels = 100}, .{.pixels = 50}},
    }, [_]f32 {20, 10, 7, 8});

    const expected = [_]TestExpected {
        .{.pos = .{0, 0}, .size = .{130, 65}},
        .{.pos = .{0, 0}, .size = .{130, 65}},
        .{.pos = .{0, 0}, .size = .{20, 7}},
        .{.pos = .{20, 7}, .size = .{100, 50}},
        .{.pos = .{120, 57}, .size = .{10, 8}},
    };

    try uiState.layout(allocator);
    try checkExpected(&expected, uiState.elements.slice());
}

test "margin"
{
    var testSetup = try TestSetup.init();
    defer testSetup.deinit();
    const allocator = testSetup.arena.allocator();
    const uiState = testSetup.uiState;

    {
        const width = 100;
        const margin = 20;
        const view = try MarginXView.init(@src(), uiState, width, margin, .{});
        defer view.deinit(uiState) catch {};

        try spacerY(@src(), uiState, .{.pixels = 400});
    }

    const expected = [_]TestExpected {
        .{.pos = .{0, 0}, .size = .{100, 400}},
        .{.pos = .{0, 0}, .size = .{100, 400}},
        .{.pos = .{0, 0}, .size = .{20, 0}},
        .{.pos = .{20, 0}, .size = .{60, 400}},
        .{.pos = .{80, 400}, .size = .{20, 0}},
        .{.pos = .{20, 0}, .size = .{60, 400}},
    };

    try uiState.layout(allocator);
    try checkExpected(&expected, uiState.elements.slice());
}
