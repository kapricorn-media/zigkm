const std = @import("std");
const builtin = @import("builtin");
const A = std.mem.Allocator;

const z = @cImport({
    @cInclude("zlib.h");
});

const interface = @import("interface.zig");

const FRAGMENT_SIZE = 1024;
const MAX_FRAGMENTS = 255;
const SERIAL_ENDIANNESS = std.builtin.Endian.little;

pub const PacketClient = struct {
    index: u32,
    inputs: [4]interface.PlayerInput,
};

comptime {
    std.debug.assert(@sizeOf(PacketClient) < FRAGMENT_SIZE);
}

pub const PacketServer = struct {
    index: u32,
    prevAcks: u32,
    inputLag: i8,
    playerIndex: u8,
    input: interface.TickInput,
    state: interface.State,
};

const Frag = struct {
    n: u16,
    buf: [FRAGMENT_SIZE]u8,
};

const FragPacketState = struct {
    sequence: u16,
    fragmentMask: std.bit_set.StaticBitSet(MAX_FRAGMENTS),
    fragmentReceived: std.bit_set.StaticBitSet(MAX_FRAGMENTS),
    fragments: [MAX_FRAGMENTS]Frag,
};

pub const FragState = struct {
    const WINDOW = 512;

    packets: [WINDOW]FragPacketState,

    // Assuming this structured is cleared to zero, it ALMOST works except for packet[0].
    pub fn init(self: *FragState) void
    {
        self.packets[0].sequence = 1;
    }
};

const FragHeader = struct {
    sequence: u16,
    numFragments: u8,
    fragment: u8,
};

pub const Socket = struct {
    socket: std.posix.socket_t,
    receiveBuffer: [FRAGMENT_SIZE * 2]u8 align(8),

    pub fn init(port: u16) !Socket
    {
        const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(socket);

        const bindAddress = try std.net.Address.parseIp4("0.0.0.0", port);
        try std.posix.bind(socket, &bindAddress.any, bindAddress.getOsSockLen());
        return .{
            .socket = socket,
            .receiveBuffer = undefined,
        };
    }

    pub fn deinit(self: *Socket) void
    {
        std.posix.close(self.socket);
    }

    pub fn sendClient(self: *Socket, packet: PacketClient, address: std.net.Address, a: A) bool
    {
        const bytes = serializeCompressAny(PacketClient, &packet, a) catch return false;
        self.send(bytes, address);
        return true;
    }

    pub fn sendServer(self: *Socket, packet: PacketServer, address: std.net.Address, sequence: *u16, a: A) bool
    {
        const bytes = serializeCompressAny(PacketServer, &packet, a) catch return false;
        self.sendFrag(bytes, address, sequence);
        return true;
    }

    pub fn receiveClient(self: *Socket, address: *std.net.Address, a: A) ?PacketClient
    {
        const n = self.receive(&self.receiveBuffer, address) orelse return null;
        const bytes = self.receiveBuffer[0..n];
        var packet: PacketClient = undefined;
        deserializeDecompressAny(PacketClient, bytes, &packet, a) catch |err| {
            std.log.err("packet deserialize failed err={}", .{err});
            return null;
        };
        return packet;
    }

    pub fn receiveServer(self: *Socket, address: *std.net.Address, packetSize: *usize, fragState: *FragState, a: A) ?PacketServer
    {
        const n = self.receive(&self.receiveBuffer, address) orelse return null;
        packetSize.* = n;
        var headerReader = std.io.Reader.fixed(self.receiveBuffer[0..4]);
        var fragHeader: FragHeader = undefined;
        deserializeAny(FragHeader, &headerReader, &fragHeader) catch {
            std.log.err("FragHeader deserialize failed", .{});
            return null;
        };

        const bytes = self.receiveBuffer[4..n];
        std.debug.assert(bytes.len <= FRAGMENT_SIZE);
        if (bytes.len > FRAGMENT_SIZE) {
            // Drop packet
            return null;
        }

        const seqIndex = fragHeader.sequence % FragState.WINDOW;
        var packet = &fragState.packets[seqIndex];
        // TODO we need a better check...
        if (packet.sequence != fragHeader.sequence) {
            packet.sequence = fragHeader.sequence;
            packet.fragmentMask = .initEmpty();
            packet.fragmentMask.setRangeValue(.{.start = 0, .end = fragHeader.numFragments}, true);
            packet.fragmentReceived = .initEmpty();
        }
        if (fragHeader.fragment < MAX_FRAGMENTS) {
            packet.fragmentReceived.set(fragHeader.fragment);
            @memcpy(packet.fragments[fragHeader.fragment].buf[0..bytes.len], bytes);
            packet.fragments[fragHeader.fragment].n = @intCast(bytes.len);
        }

        if (packet.fragmentReceived.eql(packet.fragmentMask)) {
            // Because of the modulo lookup on seqIndex, adding one will guarantee that it mismatches future packet sequence numbers, so it will get reset.
            packet.sequence += 1;

            // TODO catch?
            var packetBytes = std.ArrayList(u8).initCapacity(a, FRAGMENT_SIZE * 4) catch return null;
            const numFragments = packet.fragmentMask.count();
            for (0..numFragments) |i| {
                const frag = packet.fragments[i];
                packetBytes.appendSlice(a, frag.buf[0..frag.n]) catch return null;
            }

            var packetServer: PacketServer = undefined;
            deserializeDecompressAny(PacketServer, packetBytes.items, &packetServer, a) catch |err| {
                std.log.err("packet deserialize failed err={}", .{err});
                return null;
            };
            return packetServer;
        }

        return null;
    }

    fn sendFrag(self: *Socket, payload: []const u8, address: std.net.Address, sequence: *u16) void
    {
        std.debug.assert(payload.len != 0);
        var buf: [4 + FRAGMENT_SIZE]u8 = undefined;

        const n = ((payload.len - 1) / FRAGMENT_SIZE) + 1;
        std.debug.assert(n <= MAX_FRAGMENTS);
        for (0..n) |i| {
            const fragHeader = FragHeader {
                .sequence = sequence.*,
                .numFragments = @intCast(n),
                .fragment = @intCast(i),
            };

            var bufWriter = std.io.Writer.fixed(&buf);
            serializeAny(FragHeader, &fragHeader, &bufWriter) catch {
                std.log.err("FragHeader serialize failed", .{});
                return;
            };
            std.debug.assert(bufWriter.end == 4);

            const iStart = i * FRAGMENT_SIZE;
            const iEnd = @min(iStart + FRAGMENT_SIZE, payload.len);
            const slice = payload[iStart..iEnd];
            _ = bufWriter.writeAll(slice) catch {
                std.log.err("bufWriter write failed", .{});
                return;
            };
            // const payloadLen = 4 + slice.len;
            // @memcpy(buf[4..payloadLen], slice);

            const bytes = bufWriter.buffer[0..bufWriter.end];
            self.send(bytes, address);
        }

        sequence.* += 1;
    }

    pub fn send(self: *Socket, payload: []const u8, address: std.net.Address) void
    {
        std.debug.assert(payload.len <= FRAGMENT_SIZE + 4);

        if (std.posix.sendto(self.socket, payload, 0, &address.any, address.getOsSockLen())) |n| {
            if (n != payload.len) {
                std.log.err("sendto bytes mismatch {} vs {}", .{n, payload.len});
            }
        } else |err| {
            std.log.err("sendto err {}", .{err});
        }
    }

    pub fn receive(self: *Socket, buf: []u8, address: *std.net.Address) ?usize
    {
        var addr: std.posix.sockaddr = undefined;
        var addrLen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        if (std.posix.recvfrom(self.socket, buf, 0, &addr, &addrLen)) |n| {
            address.* = std.net.Address.initPosix(@alignCast(&addr));
            return n;
        } else |err| {
            switch (err) {
                error.WouldBlock => {},
                else => |err2| {
                    if (builtin.os.tag == .windows and err2 == error.ConnectionResetByPeer) {
                        // Windows returns this sometimes when communicating with localhost.
                        // Ignore...
                    } else {
                        std.log.err("recvfrom err {}", .{err2});
                    }
                }
            }
            return null;
        }
    }
};

fn deflateOneShot(bytes: []const u8, a: A) ![]const u8
{
    var stream: z.z_stream = std.mem.zeroes(z.z_stream);
    const initErr = z.deflateInit2(&stream, 9, z.Z_DEFLATED, z.MAX_WBITS, 8, z.Z_DEFAULT_STRATEGY);
    if (initErr != z.Z_OK) {
        return error.deflateInit2;
    }

    const maxSize = z.deflateBound(&stream, @intCast(bytes.len));
    const outBuf = try a.alloc(u8, maxSize);
    stream.next_in = @constCast(@ptrCast(bytes.ptr));
    stream.avail_in = @intCast(bytes.len);
    stream.next_out = @ptrCast(outBuf.ptr);
    stream.avail_out = @intCast(outBuf.len);

    const deflateErr = z.deflate(&stream, z.Z_FINISH);
    if (deflateErr != z.Z_STREAM_END) {
        _ = z.deflateEnd(&stream);
        return error.noEnd;
    }

    const outLen = stream.total_out;
    _ = z.deflateEnd(&stream);
    return outBuf[0..outLen];
}

fn inflateOneShot(bytes: []const u8, a: A) ![]const u8
{
    var stream: z.z_stream = std.mem.zeroes(z.z_stream);
    const initErr = z.inflateInit2(&stream, z.MAX_WBITS);
    if (initErr != z.Z_OK) {
        return error.deflateInit2;
    }

    const outBuf = try a.alloc(u8, 8 * 1024 * 1024);

    stream.next_in = @constCast(@ptrCast(bytes.ptr));
    stream.avail_in = @intCast(bytes.len);
    stream.next_out = @ptrCast(outBuf.ptr);
    stream.avail_out = @intCast(outBuf.len);

    const inflateErr = z.inflate(&stream, z.Z_NO_FLUSH);
    if (inflateErr != z.Z_STREAM_END) {
        _ = z.inflateEnd(&stream);
        return error.noEnd;
    }

    const outLen = stream.total_out;
    _ = z.deflateEnd(&stream);
    return outBuf[0..outLen];
}

fn serializeCompressAny(comptime T: type, ptr: *const T, a: A) ![]const u8
{
    var bytesRaw = std.io.Writer.Allocating.init(a);
    try serializeAny(T, ptr, &bytesRaw.writer);
    return deflateOneShot(bytesRaw.written(), a);
}

fn deserializeDecompressAny(comptime T: type, bytes: []const u8, ptr: *T, a: A) !void
{
    const rawBytes = try inflateOneShot(bytes, a);
    var reader = std.io.Reader.fixed(rawBytes);
    try deserializeAny(T, &reader, ptr);
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

fn serializeAny(comptime T: type, ptr: *const T, writer: *std.io.Writer) !void
{
    const typeInfo = @typeInfo(T);
    switch (typeInfo) {
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
                            try serializeAny(f.type, &@field(ptr.*, f.name), writer);
                        }
                    }
                },
                .@"packed" => {
                    try serializeAny(ti.backing_integer.?, @ptrCast(ptr), writer);
                    // try writer.writeInt(ti.backing_integer.?, @bitCast(ptr.*), SERIAL_ENDIANNESS);
                },
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
        else => {
            @compileLog("Unsupported type", T);
        },
    }
}

fn deserializeAny(comptime T: type, reader: *std.io.Reader, ptr: *T) !void
{
    const typeInfo = @typeInfo(T);
    switch (typeInfo) {
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
                try deserializeAny(ti.child, reader, &ptr[i]);
            }
        },
        .array => |ti| {
            for (0..ti.len) |i| {
                try deserializeAny(ti.child, reader, &ptr[i]);
            }
        },
        .@"struct" => |ti| {
            switch (ti.layout) {
                .auto, .@"extern" => {
                    inline for (ti.fields) |f| {
                        if (comptime shouldSerializeField(f)) {
                            try deserializeAny(f.type, reader, &@field(ptr.*, f.name));
                        }
                    }
                },
                .@"packed" => {
                    const IntType = ti.backing_integer.?;
                    var intValue: IntType = undefined;
                    try deserializeAny(IntType, reader, &intValue);
                    ptr.* = @bitCast(intValue);
                },
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
            try deserializeAny(tagType, reader, &tag);
            switch (tag) {
                inline else => |tagValue| {
                    ptr.* = @unionInit(T, @tagName(tagValue), undefined);
                    const PayloadType = @TypeOf(@field(ptr.*, @tagName(tagValue)));
                    try deserializeAny(PayloadType, reader, &@field(ptr.*, @tagName(tagValue)));
                }
            }
        },
        else => {
            @compileLog("Unsupported type", T);
        },
    }
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

    const TYPES = .{
        Test1,
        PacketClient,
        PacketServer,
    };
    inline for (TYPES) |T| {
        var original: T = undefined;
        @memset(std.mem.asBytes(&original), 0);

        const bytes = try serializeCompressAny(T, &original, a);
        var deserialized: T = undefined;
        @memset(std.mem.asBytes(&deserialized), 0);
        try deserializeDecompressAny(T, bytes, &deserialized, a);

        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&original), std.mem.asBytes(&deserialized));
    }
}
