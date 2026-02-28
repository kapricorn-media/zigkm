const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;

/// Do these indices represent a full queue?
fn isFullIndices(start: u32, end: u32, comptime S: u32) bool
{
    return if (end >= S - 1) start == 0 else start == (end + 1);
}

/// Single-producer single-consumer multithreaded queue. "Lock-free".
pub fn FixedQueue(comptime T: type, comptime S: u32) type
{
    return struct {
        buffer: [S]T = undefined,
        start: std.atomic.Value(u32) = .{.raw = 0},
        end: std.atomic.Value(u32) = .{.raw = 0},

        const Self = @This();

        // Not really thread-safe, kind of...
        pub fn clear(self: *Self) void
        {
            self.start.store(0, .unordered);
            self.end.store(0, .unordered);
        }

        // Producer enqueue.
        pub fn enqueue(self: *Self, value: T) bool
        {
            const e = self.end.load(.unordered);
            assert(e < S);
            const s = self.start.load(.acquire);
            assert(s < S);
            if (isFullIndices(s, e, S)) {
                return false;
            }
            self.buffer[e] = value;

            const eNew = if (e >= S - 1) 0 else e + 1;
            self.end.store(eNew, .release);
            return true;
        }

        // Consumer dequeue.
        pub fn dequeue(self: *Self) ?T
        {
            const s = self.start.load(.unordered);
            assert(s < S);
            const e = self.end.load(.acquire);
            assert(e < S);
            if (s == e) {
                return null;
            }
            const value = self.buffer[s];

            const sNew = if (s >= S - 1) 0 else s + 1;
            self.start.store(sNew, .release);
            return value;
        }
    };
}
