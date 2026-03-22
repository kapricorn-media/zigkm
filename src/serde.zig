const std = @import("std");
const builtin = @import("builtin");
const A = std.mem.Allocator;

pub const SERIAL_ENDIANNESS = std.builtin.Endian.little;

pub fn serializeAny(comptime T: type, ptr: *const T, writer: *std.io.Writer) std.io.Writer.Error!void
{
    const typeInfo = @typeInfo(T);
    switch (typeInfo) {
        .void => {},
        .bool => {
            try writer.writeByte(if (ptr.*) 1 else 0);
        },
        .int => |ti| {
            const IntType = getIntTypePad(ti.signedness, ti.bits);
            try writer.writeInt(IntType, ptr.*, SERIAL_ENDIANNESS);
        },
        .float => {
            try writer.writeAll(std.mem.asBytes(ptr));
        },
        .vector => |ti| {
            for (0..ti.len) |i| {
                try serializeAny(ti.child, &ptr[i], writer);
            }
        },
        .array => |ti| {
            for (0..ti.len) |i| {
                try serializeAny(ti.child, &ptr[i], writer);
            }
        },
        .@"struct" => |ti| {
            if (@hasDecl(T, "serialize")) {
                comptime std.debug.assert(@hasDecl(T, "deserialize"));
                try ptr.serialize(writer);
            } else {
                switch (ti.layout) {
                    .auto, .@"extern" => {
                        inline for (ti.fields) |f| {
                            if (comptime shouldSerializeField(f)) {
                                try serializeAny(f.type, &@field(ptr.*, f.name), writer);
                            }
                        }
                    },
                    .@"packed" => {
                        try serializeAny(ti.backing_integer.?, @ptrCast(ptr), writer);
                        // try writer.writeInt(ti.backing_integer.?, @bitCast(ptr.*), SERIAL_ENDIANNESS);
                    },
                }
            }
        },
        .@"enum" => |ti| {
            try writer.writeInt(ti.tag_type, @intFromEnum(ptr.*), SERIAL_ENDIANNESS);
        },
        .@"union" => |ti| {
            if (ti.layout != .auto) {
                @compileLog("Unsupported union layout", ti.layout);
            }
            const tagType = ti.tag_type orelse @compileLog("Unsupported untagged union");
            const tag = std.meta.activeTag(ptr.*);
            try serializeAny(tagType, &tag, writer);
            switch (tag) {
                inline else => |tagValue| {
                    const PayloadType = @TypeOf(@field(ptr.*, @tagName(tagValue)));
                    try serializeAny(PayloadType, &@field(ptr.*, @tagName(tagValue)), writer);
                }
            }
        },
        .optional => |ti| {
            try writer.writeByte(if (ptr.* == null) 0 else 1);
            if (ptr.*) |*v| {
                try serializeAny(ti.child, v, writer);
            }
        },
        .pointer => |ti| {
            if (ti.size != .slice) {
                @compileLog("Unsupported type", T);
            }
            try writer.writeInt(u64, ptr.len, SERIAL_ENDIANNESS);
            const tiChild = @typeInfo(ti.child);
            if (tiChild == .int and tiChild.int.bits == 8) {
                if (ptr.len > 0) {
                    try writer.writeAll(ptr.*);
                }
            } else {
                for (0..ptr.len) |i| {
                    try serializeAny(ti.child, &ptr.*[i], writer);
                }
            }
        },
        else => {
            @compileLog("Unsupported type", T);
        },
    }
}

pub fn deserializeAny(comptime T: type, a: A, reader: *std.io.Reader, ptr: *T) (A.Error || std.io.Reader.Error)!void
{
    const typeInfo = @typeInfo(T);
    switch (typeInfo) {
        .void => {},
        .bool => {
            const byte = try reader.takeByte();
            ptr.* = byte != 0;
        },
        .int => |ti| {
            const IntType = getIntTypePad(ti.signedness, ti.bits);
            const value = try reader.takeInt(IntType, SERIAL_ENDIANNESS);
            ptr.* = @intCast(value);
        },
        .float => {
            try reader.readSliceAll(std.mem.asBytes(ptr));
        },
        .vector => |ti| {
            // TODO optimize bool Vector?
            for (0..ti.len) |i| {
                try deserializeAny(ti.child, a, reader, &ptr[i]);
            }
        },
        .array => |ti| {
            for (0..ti.len) |i| {
                try deserializeAny(ti.child, a, reader, &ptr[i]);
            }
        },
        .@"struct" => |ti| {
            if (@hasDecl(T, "deserialize")) {
                comptime std.debug.assert(@hasDecl(T, "serialize"));
                try ptr.deserialize(reader);
            } else {
                switch (ti.layout) {
                    .auto, .@"extern" => {
                        inline for (ti.fields) |f| {
                            if (comptime shouldSerializeField(f)) {
                                try deserializeAny(f.type, a, reader, &@field(ptr.*, f.name));
                            }
                        }
                    },
                    .@"packed" => {
                        const IntType = ti.backing_integer.?;
                        var intValue: IntType = undefined;
                        try deserializeAny(IntType, a, reader, &intValue);
                        ptr.* = @bitCast(intValue);
                    },
                }
            }
        },
        .@"enum" => |ti| {
            ptr.* = @enumFromInt(try reader.takeInt(ti.tag_type, SERIAL_ENDIANNESS));
        },
        .@"union" => |ti| {
            if (ti.layout != .auto) {
                @compileLog("Unsupported union layout", ti.layout);
            }
            const tagType = ti.tag_type orelse @compileLog("Unsupported untagged union");
            var tag: tagType = undefined;
            try deserializeAny(tagType, a, reader, &tag);
            switch (tag) {
                inline else => |tagValue| {
                    ptr.* = @unionInit(T, @tagName(tagValue), undefined);
                    const PayloadType = @TypeOf(@field(ptr.*, @tagName(tagValue)));
                    try deserializeAny(PayloadType, a, reader, &@field(ptr.*, @tagName(tagValue)));
                }
            }
        },
        .optional => |ti| {
            const byte = try reader.takeByte();
            if (byte == 0) {
                ptr.* = null;
            } else {
                var v: ti.child = undefined;
                try deserializeAny(ti.child, a, reader, &v);
                ptr.* = v;
            }
        },
        .pointer => |ti| {
            if (ti.size != .slice) {
                @compileLog("Unsupported type", T);
            }
            const len = try reader.takeInt(u64, SERIAL_ENDIANNESS);
            ptr.* = try a.alloc(ti.child, @intCast(len));
            const tiChild = @typeInfo(ti.child);
            if (tiChild == .int and tiChild.int.bits == 8) {
                if (ptr.len > 0) {
                    try reader.readSliceAll(ptr.*);
                }
            } else {
                for (ptr.*) |*element| {
                    try deserializeAny(ti.child, a, reader, element);
                }
            }
        },
        else => {
            @compileLog("Unsupported type", T);
        },
    }
}

fn getIntTypePad(comptime signedness: std.builtin.Signedness, comptime bits: comptime_int) type
{
    if (bits <= 8) {
        return if (signedness == .signed) i8 else u8;
    } else if (bits <= 16) {
        return if (signedness == .signed) i16 else u16;
    } else if (bits <= 32) {
        return if (signedness == .signed) i32 else u32;
    } else if (bits <= 64) {
        return if (signedness == .signed) i64 else u64;
    } else if (bits <= 128) {
        return if (signedness == .signed) i128 else u128;
    } else if (bits <= 256) {
        return if (signedness == .signed) i256 else u256;
    } else {
        unreachable;
    }
}

fn shouldSerializeField(comptime field: std.builtin.Type.StructField) bool
{
    return !std.mem.startsWith(u8, field.name, "ns_");
}

test "ser/de" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Test1 = struct {
        a: u32,
        b: f32,
        c: u64,
        d: bool,
    };

    const Test2 = struct {
        a: union(enum(u8)) {
            enum1: void,
            enum2: bool,
            enum3: f32,
            enum4: struct {
                width: u64,
                height: u64,
            },
        },
        b: f32,
        c: enum(u16) {
            test1,
            test2,
        },
    };

    const TYPES = .{
        Test1,
        Test2,
    };
    inline for (TYPES) |T| {
        var original: T = undefined;
        @memset(std.mem.asBytes(&original), 0);

        var writer = std.io.Writer.Allocating.init(a);
        try serializeAny(T, &original, &writer.writer);

        var reader = std.io.Reader.fixed(writer.written());
        var deserialized: T = undefined;
        @memset(std.mem.asBytes(&deserialized), 0);
        try deserializeAny(T, a, &reader, &deserialized);

        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&original), std.mem.asBytes(&deserialized));
    }
}
