const std = @import("std");
const builtin = @import("builtin");
const A = std.mem.Allocator;

const zlib = @cImport({
    @cInclude("zlib.h");
});

const interface = @import("net_interface.zig");
const memory = @import("memory.zig");
const tracy = @import("tracy.zig").tracy;

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
    var stream: zlib.z_stream = std.mem.zeroes(zlib.z_stream);
    const initErr = zlib.deflateInit2(&stream, 9, zlib.Z_DEFLATED, zlib.MAX_WBITS, 8, zlib.Z_DEFAULT_STRATEGY);
    if (initErr != zlib.Z_OK) {
        return error.deflateInit2;
    }

    const maxSize = zlib.deflateBound(&stream, @intCast(bytes.len));
    const outBuf = try a.alloc(u8, maxSize);
    stream.next_in = @constCast(@ptrCast(bytes.ptr));
    stream.avail_in = @intCast(bytes.len);
    stream.next_out = @ptrCast(outBuf.ptr);
    stream.avail_out = @intCast(outBuf.len);

    const deflateErr = zlib.deflate(&stream, zlib.Z_FINISH);
    if (deflateErr != zlib.Z_STREAM_END) {
        _ = zlib.deflateEnd(&stream);
        return error.noEnd;
    }

    const outLen = stream.total_out;
    _ = zlib.deflateEnd(&stream);
    return outBuf[0..outLen];
}

fn inflateOneShot(bytes: []const u8, a: A) ![]const u8
{
    var stream: zlib.z_stream = std.mem.zeroes(zlib.z_stream);
    const initErr = zlib.inflateInit2(&stream, zlib.MAX_WBITS);
    if (initErr != zlib.Z_OK) {
        return error.deflateInit2;
    }

    const outBuf = try a.alloc(u8, 8 * 1024 * 1024);

    stream.next_in = @constCast(@ptrCast(bytes.ptr));
    stream.avail_in = @intCast(bytes.len);
    stream.next_out = @ptrCast(outBuf.ptr);
    stream.avail_out = @intCast(outBuf.len);

    const inflateErr = zlib.inflate(&stream, zlib.Z_NO_FLUSH);
    if (inflateErr != zlib.Z_STREAM_END) {
        _ = zlib.inflateEnd(&stream);
        return error.noEnd;
    }

    const outLen = stream.total_out;
    _ = zlib.deflateEnd(&stream);
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
        else => {
            @compileLog("Unsupported type", T);
        },
    }
}

fn deserializeAny(comptime T: type, reader: *std.io.Reader, ptr: *T) !void
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
                try deserializeAny(ti.child, reader, &ptr[i]);
            }
        },
        .array => |ti| {
            for (0..ti.len) |i| {
                try deserializeAny(ti.child, reader, &ptr[i]);
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
        .optional => |ti| {
            const byte = try reader.takeByte();
            if (byte == 0) {
                ptr.* = null;
            } else {
                var v: ti.child = undefined;
                try deserializeAny(ti.child, reader, &v);
                ptr.* = v;
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

const SentPacket = struct {
    acked: bool,
    timeUs: i64,
    tickIndex: u64,
    packet: PacketClient,
};

fn CircularBuffer(comptime T: type, comptime N: usize) type
{
    const Buffer = struct {
        index: u32,
        buffer: [N]T,

        const Self = @This();

        fn add(self: *Self, value: T) void
        {
            self.buffer[self.index] = value;
            self.index = @intCast((self.index + 1) % self.buffer.len);
        }
    };
    return Buffer;
}

const PacketStats = struct {
    max: f32,
    min: f32,
    mean: f32,
};

const NetworkStats = struct {
    latencies: CircularBuffer(i64, 128),
    acks: CircularBuffer(bool, 128),
    clientPacketSizes: CircularBuffer(u16, 128),
    serverPacketSizes: CircularBuffer(u16, 128),

    pub fn calcMeanLatencyUs(self: *const NetworkStats) f64
    {
        var meanUs: f64 = 0;
        for (self.latencies.buffer) |l| {
            meanUs += @floatFromInt(l);
        }
        meanUs /= @floatFromInt(self.latencies.buffer.len);
        return meanUs;
    }

    pub fn calcPacketLoss(self: *const NetworkStats) f64
    {
        var loss: f64 = 0;
        for (self.acks.buffer) |a| {
            loss += if (a) 0 else 1;
        }
        loss /= @floatFromInt(self.acks.buffer.len);
        return loss;
    }

    pub fn calcClientPacketStats(self: *const NetworkStats) PacketStats
    {
        var result = PacketStats {
            .max = std.math.floatMin(f32),
            .min = std.math.floatMax(f32),
            .mean = 0,
        };
        for (self.clientPacketSizes.buffer) |s| {
            const sF: f32 = @floatFromInt(s);
            result.max = @max(result.max, sF);
            result.min = @min(result.min, sF);
            result.mean += sF;
        }
        result.mean /= @floatFromInt(self.clientPacketSizes.buffer.len);
        return result;
    }

    pub fn calcServerPacketStats(self: *const NetworkStats) PacketStats
    {
        var result = PacketStats {
            .max = std.math.floatMin(f32),
            .min = std.math.floatMax(f32),
            .mean = 0,
        };
        for (self.serverPacketSizes.buffer) |s| {
            const sF: f32 = @floatFromInt(s);
            result.max = @max(result.max, sF);
            result.min = @min(result.min, sF);
            result.mean += sF;
        }
        result.mean /= @floatFromInt(self.serverPacketSizes.buffer.len);
        return result;
    }
};

pub const NetStateClient = struct {
    tickIndex: u64,
    stateHistory: interface.StateHistory(128),
    playerIndex: ?interface.PlayerId,
    lastReceiveUs: i64,
    packetIndex: u32,
    fragState: FragState,
    sendBuffer: [256]SentPacket,
    recvLen: usize,
    recvBuffer: [64]PacketServer,
    netStats: NetworkStats,
    serverAddress: std.net.Address,
    sendPackets: std.atomic.Value(bool),

    exit: std.atomic.Value(bool),
    syncLock: std.Thread.Mutex,
    syncInput: interface.PlayerInput,
    syncSnapshots: [2]interface.InputState,

    const Self = @This();

    pub fn reset(self: *Self, offlineMode: bool) void
    {
        self.tickIndex = 1;
        // TODO should we reset sendBuffer?
        const last = self.getLastSnapshot();
        last.input = .{};
        last.state.reset(@intCast(std.time.milliTimestamp()));
        if (offlineMode) {
            self.playerIndex = 0;
            self.sendPackets.store(false, .release);
        }
        self.fragState.init();

        self.exit = .init(false);
        self.syncLock = .{};
    }

    pub fn getLastSnapshot(self: *Self) *interface.InputState
    {
        return self.stateHistory.getSnapshot(self.tickIndex - 1);
    }
};

pub fn netThreadClient(socket: *Socket, ns: *NetStateClient) void
{
    var nsPrevTick = std.time.nanoTimestamp();
    while (!ns.exit.load(.unordered)) {
        const nsNow = std.time.nanoTimestamp();
        const usNow: i64 = @intCast(@divTrunc(nsNow, 1000));

        var ta = memory.getTempArena(null);
        defer ta.reset();
        const a = ta.allocator();

        if (nsNow - nsPrevTick >= interface.OPTIONS.nsPerTick) {
            nsPrevTick += interface.OPTIONS.nsPerTick;

            // Apply server packets
            {
                var latestPacket: ?*const PacketServer = null;
                for (ns.recvBuffer[0..ns.recvLen]) |*packet| {
                    if (latestPacket) |p| {
                        if (packet.index > p.index) {
                            latestPacket = packet;
                        }
                    } else {
                        latestPacket = packet;
                    }
                }
                if (latestPacket) |p| {
                    const sendEntry = &ns.sendBuffer[p.index % ns.sendBuffer.len];
                    if (p.index == sendEntry.packet.index) {
                        const tickIndex = blk: {
                            if (p.inputLag < 0) {
                                break :blk sendEntry.tickIndex + @as(u64, @intCast(-p.inputLag));
                            } else {
                                break :blk sendEntry.tickIndex - @as(u64, @intCast(p.inputLag));
                            }
                        };
                        if (tickIndex > 0 and ns.tickIndex >= tickIndex) {
                            const earliestSavedTick = ns.tickIndex -| ns.stateHistory.snapshots.len;
                            if (tickIndex - 1 > earliestSavedTick) {
                                var snapshot = ns.stateHistory.getSnapshot(tickIndex - 1);
                                snapshot.input = p.input;
                                snapshot.state = p.state;
                                ns.stateHistory.tickFromTo(tickIndex, ns.tickIndex);
                            } else {
                                std.log.err("snapshot for ack expired", .{});
                            }
                        } else {
                            std.log.err("packet is in the future", .{});
                        }
                    } else {
                        std.log.err("packet for ack expired", .{});
                    }

                    var i: usize = 0;
                    while (i < ns.recvLen) {
                        const pkt = &ns.recvBuffer[i];
                        if (pkt.index <= p.index) {
                            ns.recvBuffer[i] = ns.recvBuffer[ns.recvLen - 1];
                            ns.recvLen -= 1;
                        } else {
                            i += 1;
                        }
                    }
                }
            }

            const nextPacket = &ns.sendBuffer[ns.packetIndex % ns.sendBuffer.len];
            // Record acked status for saved packet before overwriting.
            ns.netStats.acks.add(nextPacket.acked);

            nextPacket.packet.index = ns.packetIndex;
            if (ns.packetIndex > 0) {
                const prevPacket = &ns.sendBuffer[(ns.packetIndex - 1) % ns.sendBuffer.len];
                for (0..nextPacket.packet.inputs.len - 1) |i| {
                    nextPacket.packet.inputs[i] = prevPacket.packet.inputs[i + 1];
                }
            }
            ns.packetIndex += 1;

            var snapshot = ns.stateHistory.getSnapshot(ns.tickIndex);
            const snapshotPrev = ns.stateHistory.getSnapshot(ns.tickIndex - 1);
            snapshot.state = snapshotPrev.state;
            if (ns.playerIndex) |pid| {
                // State prediction
                snapshot.input = .{};
                // TODO prevent this from being used once we get an authoritative input in the past from the server
                // for (0..game.MAX_PLAYERS) |i| {
                //     snapshot.input.inputs[i] = snapshotPrev.input.inputs[i].guessNext();
                // }
                var playerInput: interface.PlayerInput = undefined;
                {
                    ns.syncLock.lock();
                    defer ns.syncLock.unlock();
                    playerInput = ns.syncInput;
                    @memset(std.mem.asBytes(&ns.syncInput), 0);
                }
                snapshot.input.inputs[pid] = playerInput;
                snapshot.state.players[pid].connected = true;

                interface.tick(&snapshot.state, &snapshot.input);
                ns.tickIndex += 1;
                nextPacket.packet.inputs[nextPacket.packet.inputs.len - 1] = playerInput;
            }
            {
                ns.syncLock.lock();
                defer ns.syncLock.unlock();

                ns.syncSnapshots[0] = snapshotPrev.*;
                ns.syncSnapshots[1] = snapshot.*;
            }

            if (ns.sendPackets.load(.acquire)) {
                const z = tracy.zoneN(@src(), "packet-client");
                defer z.end();

                if (socket.sendClient(nextPacket.packet, ns.serverAddress, a)) {
                    nextPacket.acked = false;
                    nextPacket.timeUs = usNow;
                    nextPacket.tickIndex = ns.tickIndex;
                    // state.netStats.clientPacketSizes.add(@intCast(packetBytes.len));
                } else {
                    std.log.err("packet send failed", .{});
                }
            }
        } else {
            var address: std.net.Address = undefined;
            var n: usize = undefined;
            if (socket.receiveServer(&address, &n, &ns.fragState, a)) |packet| {
                const z = tracy.zoneN(@src(), "packet-server");
                defer z.end();
                tracy.message(std.fmt.allocPrint(a, "index={} prevAcks={x} inputLag={} playerIndex={}", .{packet.index, packet.prevAcks, packet.inputLag, packet.playerIndex}) catch "");

                ns.netStats.serverPacketSizes.add(@intCast(n));
                ns.lastReceiveUs = usNow;
                if (ns.playerIndex) |i| {
                    if (i != packet.playerIndex) {
                        std.log.err("player index changed", .{});
                    }
                } else {
                    if (packet.playerIndex <= interface.OPTIONS.maxPlayers) {
                        // Player index received - we are officially connected to the server.
                        std.log.info("assigned player index {}", .{packet.playerIndex});
                        ns.playerIndex = @intCast(packet.playerIndex);
                        ns.reset(false);
                    } else {
                        std.log.err("invalid player index {}", .{packet.playerIndex});
                    }
                }

                for (0..32+1) |i| {
                    const isAcked = blk: {
                        if (i == 0) {
                            break :blk true;
                        } else {
                            const ackMask: u32 = @as(u32, 1) << @intCast(i - 1);
                            break :blk (packet.prevAcks & ackMask) != 0;
                        }
                    };
                    if (!isAcked or packet.index < i) continue;
                    const index = packet.index - i;
                    const sendEntry = &ns.sendBuffer[index % ns.sendBuffer.len];
                    if (index == sendEntry.packet.index and !sendEntry.acked) {
                        if (!sendEntry.acked) {
                            ns.netStats.latencies.add(usNow - sendEntry.timeUs);
                        }
                        sendEntry.acked = true;
                    }
                }

                if (ns.recvLen < ns.recvBuffer.len) {
                    ns.recvBuffer[ns.recvLen] = packet;
                    ns.recvLen += 1;
                } else {
                    std.log.err("too many packets from server", .{});
                }
            }
        }
    }
}

const PLAYER_TIMEOUT_SECONDS = 5;

const InputRecord = struct {
    received: bool,
    used: bool,
    input: interface.PlayerInput,
};

const Connection = struct {
    connected: bool,
    address: std.net.Address,
    lastReceiveUs: i64,
    startTick: u64,
    latestIndex: u32,
    prevAcks: u32,
    inputs: [16]InputRecord,
    inputOffset: i32,
    sequence: u16,
};

pub const NetStateServer = struct {
    tickIndex: u64,
    stateHistory: interface.StateHistory(32),
    connections: [interface.OPTIONS.maxPlayers]Connection,

    const Self = @This();

    pub fn reset(self: *Self) void
    {
        self.tickIndex = 1;
        const firstSnapshot = self.stateHistory.getSnapshot(0);
        firstSnapshot.input = .{};
        firstSnapshot.state.reset(@intCast(std.time.milliTimestamp()));
    }

    fn anyConnected(self: *const Self) bool
    {
        for (&self.connections) |c| {
            if (c.connected) return true;
        }
        return false;
    }

    fn getOrAssignPlayerIndex(self: *Self, address: std.net.Address) ?usize
    {
        for (self.connections, 0..) |conn, i| {
            if (conn.connected and conn.address.eql(address)) {
                return i;
            }
        }
        for (&self.connections, 0..) |*conn, i| {
            if (!conn.connected) {
                conn.* = .{
                    .connected = false,
                    .address = address,
                    .lastReceiveUs = 0,
                    .startTick = 0,
                    .latestIndex = 0,
                    .prevAcks = 0,
                    .inputs = undefined,
                    .inputOffset = 0,
                    .sequence = 0,
                };
                return i;
            }
        }
        return null;
    }
};

pub fn netThreadServer(socket: *Socket, ns: *NetStateServer) void
{
    var nsPrevTick = std.time.nanoTimestamp();
    var nsPrevNet = std.time.nanoTimestamp();
    while (true) {
        const nsNow = std.time.nanoTimestamp();
        const usNow: i64 = @intCast(@divTrunc(nsNow, 1000));

        var ta = memory.getTempArena(null);
        defer ta.reset();
        const a = ta.allocator();

        if (nsNow - nsPrevTick >= interface.OPTIONS.nsPerTick) {
            const tz = tracy.zoneN(@src(), "tick");
            defer tz.end();

            nsPrevTick += interface.OPTIONS.nsPerTick;

            for (&ns.connections, 0..) |*conn, pid| {
                if (conn.connected and conn.lastReceiveUs + PLAYER_TIMEOUT_SECONDS * std.time.us_per_s <= usNow) {
                    conn.connected = false;
                    std.log.info("{}: TIMEOUT p{} ({f})", .{std.time.nanoTimestamp(), pid, conn.address});
                }
            }

            if (ns.anyConnected()) {
                var currentSnapshot = ns.stateHistory.getSnapshot(ns.tickIndex);
                currentSnapshot.input = .{};

                // Replay from previous snapshots if we need to re-process any player input.
                var tickFrom = ns.tickIndex;
                for (0..interface.OPTIONS.serverInputBacklog) |i| {
                    const tickOffset = interface.OPTIONS.serverInputBacklog - i - 1;
                    if (tickOffset >= ns.tickIndex) {
                        continue;
                    }
                    const tickIndex = ns.tickIndex - tickOffset;
                    const snapshot = ns.stateHistory.getSnapshot(tickIndex);
                    for (&ns.connections, 0..) |*conn, pid| {
                        if (!conn.connected) continue;
                        const inputOffset: u32 = blk: {
                            const off = @as(i32, @intCast(tickOffset)) + conn.inputOffset;
                            if (off <= 0 or off > conn.inputs.len) continue;
                            break :blk @intCast(off);
                        };
                        const connInput = &conn.inputs[conn.inputs.len - inputOffset];
                        if (!snapshot.input.hasInput[pid] and connInput.received and !connInput.used) {
                            for (conn.inputs[0..conn.inputs.len - inputOffset]) |pastInput| {
                                if (!pastInput.used) {
                                    connInput.input.movePriorityInputs(pastInput.input);
                                }
                            }
                            snapshot.input.hasInput[pid] = true;
                            snapshot.input.inputs[pid] = connInput.input;
                            connInput.used = true;
                            tickFrom = @min(tickFrom, tickIndex);
                        }
                    }
                }
                if (tickFrom != ns.tickIndex) {
                    ns.stateHistory.tickFromTo(tickFrom, ns.tickIndex);
                }
                for (&ns.connections) |*conn| {
                    if (!conn.connected) continue;
                    conn.inputOffset -= 1;
                    conn.inputOffset = @max(conn.inputOffset, -interface.OPTIONS.serverMaxInputLag);
                }

                // Advance one tick.
                const prevSnapshot = ns.stateHistory.getSnapshot(ns.tickIndex - 1);
                currentSnapshot.state = prevSnapshot.state;
                for (&ns.connections, 0..) |*conn, i| {
                    const pid: interface.PlayerId = @intCast(i);
                    const ps = &currentSnapshot.state.players[pid];
                    const prevConnected = ps.connected;
                    ps.connected = conn.connected;
                    if (!prevConnected and conn.connected) {
                        // Player just connected, init state.
                        std.log.info("{}: CONNECTED p{} ({f})", .{std.time.nanoTimestamp(), pid, conn.address});
                    }
                    if (conn.connected and !currentSnapshot.input.hasInput[pid]) {
                        currentSnapshot.input.inputs[pid] = prevSnapshot.input.inputs[pid].guessNext();
                    }
                }

                interface.tick(&currentSnapshot.state, &currentSnapshot.input);
                ns.tickIndex += 1;
            } else {
                if (ns.tickIndex != 1) {
                    // Reset if noone is connected.
                    ns.reset();
                }
            }
            // tracy.frameMarkNamed("server");
        } else if (nsNow - nsPrevNet >= interface.OPTIONS.serverNsPerNet) {
            nsPrevNet += interface.OPTIONS.serverNsPerNet;

            if (ns.anyConnected()) {
                const tz = tracy.zoneN(@src(), "packet-server");
                defer tz.end();

                const latestSnapshot = ns.stateHistory.getSnapshot(ns.tickIndex - 1);
                for (&ns.connections, 0..) |*conn, i| {
                    if (!conn.connected) continue;
                    if (!socket.sendServer(.{
                        .index = conn.latestIndex,
                        .prevAcks = conn.prevAcks,
                        .inputLag = @intCast(conn.inputOffset),
                        .playerIndex = @intCast(i),
                        .input = latestSnapshot.input,
                        .state = latestSnapshot.state,
                    }, conn.address, &conn.sequence, a)) {
                        std.log.err("packet send failed", .{});
                    }
                }
            }
        } else {
            var address: std.net.Address = undefined;
            if (socket.receiveClient(&address, a)) |packet| {
                const tz = tracy.zoneN(@src(), "packet-client");
                defer tz.end();

                if (ns.getOrAssignPlayerIndex(address)) |pid| {
                    var conn = &ns.connections[pid];
                    conn.lastReceiveUs = usNow;
                    if (conn.connected) {
                        if (packet.index > conn.latestIndex) {
                            // New latest packet, shift existing data
                            const diff = packet.index - conn.latestIndex;
                            conn.latestIndex = packet.index;
                            conn.inputOffset += @intCast(diff);
                            if (conn.inputOffset > interface.OPTIONS.serverMaxInputLag) {
                                conn.inputOffset = interface.OPTIONS.serverMaxInputLag;
                            }
                            if (diff < 32) {
                                conn.prevAcks <<= @intCast(diff);
                                conn.prevAcks |= @as(u32, 1) << @intCast(diff - 1);
                            } else {
                                conn.prevAcks = 0;
                            }
                            if (diff < conn.inputs.len) {
                                for (0..conn.inputs.len) |i| {
                                    if (i < conn.inputs.len - diff) {
                                        conn.inputs[i] = conn.inputs[i + diff];
                                    } else {
                                        conn.inputs[i].received = false;
                                        conn.inputs[i].used = false;
                                    }
                                }
                            } else {
                                @memset(std.mem.asBytes(&conn.inputs), 0);
                            }
                        } else if (packet.index == conn.latestIndex) {
                            // TODO drop packet?
                            std.log.err("duplicate packet from {}", .{pid});
                        }

                        // Insert this packet's data in the right order, if within range
                        std.debug.assert(conn.latestIndex >= packet.index);
                        const diff = conn.latestIndex - packet.index;
                        if (diff != 0 and diff <= 32) {
                            conn.prevAcks |= @as(u32, 1) << @intCast(diff - 1);
                        }
                        for (0..packet.inputs.len) |i| {
                            const indexBase = conn.inputs.len - packet.inputs.len + i;
                            if (indexBase < diff) continue;
                            const index = indexBase - diff;
                            conn.inputs[index].received = true;
                            conn.inputs[index].input = packet.inputs[i];
                        }
                    } else {
                        conn.connected = true;
                        conn.startTick = ns.tickIndex;
                        conn.latestIndex = packet.index;
                        conn.prevAcks = 0;
                        @memset(std.mem.asBytes(&conn.inputs), 0);
                        conn.inputOffset = 1;
                        std.log.info("{}: FIRST PACKET p{} ({f})", .{std.time.nanoTimestamp(), pid, address});
                    }
                }
            }
        }
    }
}
