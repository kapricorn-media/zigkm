const std = @import("std");

// pub const tracy = TracyLive;
pub const tracy = TracyStub;

const Src = std.builtin.SourceLocation;

const TracyStub = struct {
    pub const ZoneCtx = struct {
        pub fn end(self: ZoneCtx) void
        {
            _ = self;
        }
    };

    pub fn zoneN(comptime src: Src, name: [*:0]const u8) ZoneCtx
    {
        _ = src;
        _ = name;
        return .{};
    }

    pub fn frameMarkNamed(name: [*:0]const u8) void
    {
        _ = name;
    }

    pub fn message(str: []const u8) void
    {
        _ = str;
    }
};

const TracyLive = struct {
    const c = @cImport({
        @cDefine("TRACY_ENABLE", "");
        @cInclude("TracyC.h");
    });

    pub const ZoneCtx = struct {
        zone: c.TracyCZoneCtx,

        fn init(comptime src: Src, name: ?[*:0]const u8, color: u32) ZoneCtx
        {
            const static = struct {
                var loc: c.___tracy_source_location_data = undefined;
                var src2: Src = src;
            };
            static.loc = .{
                .name = name,
                .function = src.fn_name.ptr,
                .file = src.file.ptr,
                .line = src.line,
                .color = color,
            };
            const zone = c.___tracy_emit_zone_begin(&static.loc, 1);
            return .{.zone = zone};
        }

        pub fn end(self: ZoneCtx) void
        {
            c.___tracy_emit_zone_end(self.zone);
        }
    };

    pub fn zoneN(comptime src: Src, name: [*:0]const u8) ZoneCtx
    {
        return ZoneCtx.init(src, name, 0);
    }

    pub fn frameMarkNamed(name: [*:0]const u8) void
    {
        c.___tracy_emit_frame_mark(name);
    }

    pub fn message(str: []const u8) void
    {
        c.___tracy_emit_message(str.ptr, str.len, 0);
    }
};
