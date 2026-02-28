const std = @import("std");
const A = std.mem.Allocator;

const root = @import("root");
const platform = @import("zigkm-platform");

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

threadlocal var fba1 = std.heap.FixedBufferAllocator.init(&.{});
threadlocal var fba2 = std.heap.FixedBufferAllocator.init(&.{});

pub fn getTempArena(alias: ?TempArena) TempArena
{
    if (fba1.buffer.len == 0) {
        const buf1 = std.heap.page_allocator.alignedAlloc(u8, .@"32", MEMORY_TEMP) catch |err| {
            std.log.err("Failed to allocate memory, error {}", .{err});
            unreachable; // TODO
        };
        const buf2 = std.heap.page_allocator.alignedAlloc(u8, .@"32", MEMORY_TEMP) catch |err| {
            std.log.err("Failed to allocate memory, error {}", .{err});
            unreachable; // TODO
        };
        fba1 = std.heap.FixedBufferAllocator.init(buf1);
        fba2 = std.heap.FixedBufferAllocator.init(buf2);
    }

    if (alias) |al| {
        if (al.fbaPtr == &fba1) {
            return TempArena.init(&fba2);
        } else {
            return TempArena.init(&fba1);
        }
    } else {
        return TempArena.init(&fba1);
    }
}

pub const Memory = struct
{
    memory: []u8,
    remaining: std.heap.FixedBufferAllocator,

    const Self = @This();

    pub fn init(memory: []u8, usedOffset: usize) Memory
    {
        std.debug.assert(usedOffset <= memory.len);
        return Self {
            .memory = memory,
            .remaining = std.heap.FixedBufferAllocator.init(memory[usedOffset..]),
        };
    }
};
