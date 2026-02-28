const std = @import("std");

const A = std.mem.Allocator;
const OOM = A.Error;
const EOS = error {EndOfStream};
const SERIAL_ENDIANNESS = std.builtin.Endian.little;
const VERSION: u8 = 0;

// Copy an object by serializing and deserializing.
pub fn deepCopy(comptime T: type, t: *const T, aSer: A, aDe: A) (OOM || std.io.Writer.Error)!T
{
    const bytes = try serializeAlloc(T, t, aSer);
    const result = deserializeBuf(T, bytes, aDe) catch |err| switch (err) {
        error.EndOfStream => unreachable,
        else => |e| return e,
    };
    return result;
}

pub fn serializeAlloc(comptime T: type, ptr: *const T, a: A) (OOM || std.io.Writer.Error)![]const u8
{
    var bytes = std.io.Writer.Allocating.init(a);
    errdefer bytes.deinit();
    try serialize(T, ptr, &bytes.writer);
    return bytes.toOwnedSlice();
}

pub fn serialize(comptime T: type, ptr: *const T, writer: *std.io.Writer) std.io.Writer.Error!void
{
    try writer.writeByte(VERSION);
    try serializeAny(T, ptr, writer);
}

pub fn deserializeBuf(comptime T: type, buf: []const u8, a: A) (EOS || OOM)!T
{
    var bufStream = std.io.fixedBufferStream(buf);
    return deserializeValue(T, bufStream.reader(), a);
}

pub fn deserializeValue(comptime T: type, reader: anytype, a: A) (@TypeOf(reader).Error || EOS || OOM)!T
{
    var t: T = undefined;
    try deserialize(T, reader, a, &t);
    return t;
}

pub fn deserialize(comptime T: type, reader: anytype, a: A, ptr: *T) (@TypeOf(reader).Error || EOS || OOM)!void
{
    const version = try reader.readByte();
    _ = version;
    try deserializeAny(T, reader, a, ptr);
}

fn serializeAny(comptime T: type, ptr: *const T, writer: *std.io.Writer) std.io.Writer.Error!void
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
            switch (ti.layout) {
                .auto, .@"extern" => {
                    inline for (ti.fields) |f| {
                        if (comptime shouldSerializeField(f)) {
                            // const field = @field(ptr.*, f.name);
                            try serializeAny(f.type, &@field(ptr.*, f.name), writer);
                        }
                    }
                },
                .@"packed" => {
                    try writer.writeInt(ti.backing_integer.?, @bitCast(ptr.*), SERIAL_ENDIANNESS);
                },
            }
        },
        .@"enum" => |ti| {
            const intValue: ti.tag_type = @intFromEnum(ptr.*);
            try serializeAny(ti.tag_type, &intValue, writer);
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
        .optional => |ti| {
            try writer.writeByte(if (ptr.* == null) 0 else 1);
            if (ptr.*) |value| {
                try serializeAny(ti.child, &value, writer);
            }
        },
        else => {
            @compileLog("Unsupported type", T);
        },
    }
}

/// Allocator is required for slices. Another option is to require deserialization from a full in-memory buffer.
fn deserializeAny(comptime T: type, reader: anytype, a: A, ptr: *T) (@TypeOf(reader).Error || EOS || OOM)!void
{
    const typeInfo = @typeInfo(T);
    switch (typeInfo) {
        .void => {},
        .bool => {
            const byte = try reader.readByte();
            ptr.* = byte != 0;
        },
        .int => |ti| {
            const IntType = getIntTypePad(ti.signedness, ti.bits);
            const value = try reader.readInt(IntType, SERIAL_ENDIANNESS);
            ptr.* = @intCast(value);
        },
        .float => {
            try readExactly(reader, std.mem.asBytes(ptr));
        },
        .vector => |ti| {
            // TODO optimize bool Vector?
            for (0..ti.len) |i| {
                try deserializeAny(ti.child, reader, a, &ptr[i]);
            }
        },
        .array => |ti| {
            for (0..ti.len) |i| {
                try deserializeAny(ti.child, reader, a, &ptr[i]);
            }
        },
        .@"struct" => |ti| {
            switch (ti.layout) {
                .auto, .@"extern" => {
                    inline for (ti.fields) |f| {
                        if (comptime shouldSerializeField(f)) {
                            try deserializeAny(f.type, reader, a, &@field(ptr.*, f.name));
                        }
                    }
                },
                .@"packed" => {
                    ptr.* = @bitCast(try reader.readInt(ti.backing_integer.?, SERIAL_ENDIANNESS));
                },
            }
        },
        .@"enum" => |ti| {
            var valueInt: ti.tag_type = undefined;
            try deserializeAny(ti.tag_type, reader, a, &valueInt);
            ptr.* = @enumFromInt(valueInt);
        },
        .@"union" => |ti| {
            if (ti.layout != .auto) {
                @compileLog("Unsupported union layout", ti.layout);
            }
            const tagType = ti.tag_type orelse @compileLog("Unsupported untagged union");
            var tag: tagType = undefined;
            try deserializeAny(tagType, reader, a, &tag);
            switch (tag) {
                inline else => |tagValue| {
                    ptr.* = @unionInit(T, @tagName(tagValue), undefined);
                    const PayloadType = @TypeOf(@field(ptr.*, @tagName(tagValue)));
                    try deserializeAny(PayloadType, reader, a, &@field(ptr.*, @tagName(tagValue)));
                }
            }
        },
        .pointer => |ti| {
            if (ti.size != .slice) {
                @compileLog("Unsupported type", T);
            }
            const len = try reader.readInt(u64, SERIAL_ENDIANNESS);
            ptr.* = try a.alloc(ti.child, @intCast(len));
            const tiChild = @typeInfo(ti.child);
            if (tiChild == .int and tiChild.int.bits == 8) {
                if (ptr.len > 0) {
                    const readBytes = try reader.read(@constCast(ptr.*));
                    if (readBytes != ptr.len) {
                        return error.EndOfStream;
                    }
                }
            } else {
                for (ptr.*) |*element| {
                    try deserializeAny(ti.child, reader, a, @constCast(element));
                }
            }
        },
        .optional => |ti| {
            const nullByte = try reader.readByte();
            if (nullByte == 0) {
                ptr.* = null;
            } else {
                var v: ti.child = undefined;
                try deserializeAny(ti.child, reader, a, &v);
                ptr.* = v;
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
    } else {
        unreachable;
    }
}

fn shouldSerializeField(comptime field: std.builtin.Type.StructField) bool
{
    return !std.mem.startsWith(u8, field.name, "ns_");
}

fn readExactly(reader: anytype, buffer: []u8) !void
{
    const size = try reader.readAll(buffer);
    if (size != buffer.len) {
        return error.EndOfStream;
    }
}

test "serializeAny/deserializeAny"
{
    const Test = struct {
        countryCode: u16,
        number: []const u8,
    };
    const TestType = struct {
        id: u64,
        firstName: []const u8,
        lastName: []const u8,
        address: ?[]const u8,
        phones: ?[]const Test,
    };

    const TestCase = struct {
        value: TestType,
        expected: []const u8,
    };
    const cases = [_]TestCase {
        .{
            .value = .{
                .id = 0,
                .firstName = "Jeanne",
                .lastName = "Iron Maiden",
                .address = null,
                .phones = null,
            },
            .expected = "\x00"
                ++ "\x00\x00\x00\x00\x00\x00\x00\x00"
                ++ "\x06\x00\x00\x00\x00\x00\x00\x00Jeanne"
                ++ "\x0B\x00\x00\x00\x00\x00\x00\x00Iron Maiden"
                ++ "\x00"
                ++ "\x00",
        },
        .{
            .value = .{
                .id = 0x2DDF19F23081A90,
                .firstName = "Uvuvuevuevue Onyetuenwuevue",
                .lastName = "Ugbemugbem Ossas",
                .address = "Edo State, Nigeria",
                .phones = null,
            },
            .expected = "\x00"
                ++ "\x90\x1A\x08\x23\x9F\xF1\xDD\x02"
                ++ "\x1B\x00\x00\x00\x00\x00\x00\x00Uvuvuevuevue Onyetuenwuevue"
                ++ "\x10\x00\x00\x00\x00\x00\x00\x00Ugbemugbem Ossas"
                ++ "\x01\x12\x00\x00\x00\x00\x00\x00\x00Edo State, Nigeria"
                ++ "\x00",
        },
        .{
            .value = .{
                .id = 0,
                .firstName = "Chrollo",
                .lastName = "Lucilfer!",
                .address = "Greed Island?",
                .phones = &[_]Test {
                    .{.countryCode = 0x1234, .number = "1234578idifaisdjf"},
                    .{.countryCode = std.math.maxInt(u16), .number = "109230202905412"},
                },
            },
            .expected = "\x00"
                ++ "\x00\x00\x00\x00\x00\x00\x00\x00"
                ++ "\x07\x00\x00\x00\x00\x00\x00\x00Chrollo"
                ++ "\x09\x00\x00\x00\x00\x00\x00\x00Lucilfer!"
                ++ "\x01\x0D\x00\x00\x00\x00\x00\x00\x00Greed Island?"
                ++ "\x01\x02\x00\x00\x00\x00\x00\x00\x00"
                ++ "\x34\x12\x11\x00\x00\x00\x00\x00\x00\x001234578idifaisdjf"
                ++ "\xff\xff\x0F\x00\x00\x00\x00\x00\x00\x00109230202905412",
        },
    };

    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    for (cases) |c| {
        const bytes = try serializeAlloc(TestType, &c.value, a);
        defer a.free(bytes);
        try std.testing.expectEqualSlices(u8, c.expected, bytes);

        const deserialized = try deserializeBuf(TestType, bytes, arena.allocator());
        try std.testing.expectEqualDeep(c.value, deserialized);
    }
}

test "tagged union"
{
    const TaggedUnion = union(enum) {
        hello: void,
        goodbye: u32,
    };
    const cases = [_]TaggedUnion {
        .{.hello = {}},
        .{.goodbye = 1234},
    };

    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    for (cases) |c| {
        const bytes = try serializeAlloc(TaggedUnion, &c, a);
        defer a.free(bytes);

        const deserialized = try deserializeBuf(TaggedUnion, bytes, arena.allocator());
        try std.testing.expectEqualDeep(c, deserialized);
    }
}
