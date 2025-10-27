const std = @import("std");
const root = @import("root");
const A = std.mem.Allocator;
const OOM = A.Error;

pub fn FixedMemory(comptime StateType: type, comptime N: usize) type
{
    const stateSize = @sizeOf(StateType);
    comptime {
        if (stateSize > N) {
            @compileLog(stateSize, N);
            unreachable;
        }
    }

    return struct {
        permanent: [N]u8 align(@alignOf(StateType)),
        remaining: std.heap.FixedBufferAllocator,

        const Self = @This();

        pub fn init(a: A) OOM!*Self
        {
            var self = try a.create(Self);
            self.remaining = .init(self.permanent[stateSize..]);
            return self;
        }

        pub fn state(self: *Self) *StateType
        {
            return @ptrCast(&self.permanent);
        }
    };
}

pub const MEMORY_TEMP = if (@hasDecl(root, "MEMORY_TEMP")) root.MEMORY_TEMP else @compileError("Missing MEMORY_TEMP in root");

const TempArena = struct {
    fbaPtr: *std.heap.FixedBufferAllocator,
    index: usize,

    fn init(fbaPtr: *std.heap.FixedBufferAllocator) TempArena
    {
        return .{
            .fbaPtr = fbaPtr,
            .index = fbaPtr.end_index,
        };
    }

    pub fn reset(self: *TempArena) void
    {
        self.fbaPtr.end_index = self.index;
    }

    pub fn allocator(self: *TempArena) A
    {
        return self.fbaPtr.allocator();
    }
};

threadlocal var tb1 = std.heap.FixedBufferAllocator.init(&.{});
threadlocal var tb2 = std.heap.FixedBufferAllocator.init(&.{});

pub fn getTempArena(alias: ?TempArena) TempArena
{
    if (tb1.buffer.len == 0) {
        const buf1 = std.heap.page_allocator.alignedAlloc(u8, .@"16", MEMORY_TEMP) catch |err| {
            std.log.err("Failed to allocate memory, error {}", .{err});
            unreachable; // TODO
        };
        const buf2 = std.heap.page_allocator.alignedAlloc(u8, .@"16", MEMORY_TEMP) catch |err| {
            std.log.err("Failed to allocate memory, error {}", .{err});
            unreachable; // TODO
        };
        tb1 = std.heap.FixedBufferAllocator.init(buf1);
        tb2 = std.heap.FixedBufferAllocator.init(buf2);
    }
    if (alias) |al| {
        if (al.fbaPtr == &tb1) {
            return TempArena.init(&tb2);
        } else {
            return TempArena.init(&tb1);
        }
    } else {
        return TempArena.init(&tb1);
    }
}
