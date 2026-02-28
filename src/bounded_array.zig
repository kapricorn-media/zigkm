const std = @import("std");

pub fn BoundedArray(comptime T: type, comptime size: usize) type
{
    const TT = struct {
        len: usize = 0,
        buffer: [size]T = undefined,

        const Self = @This();

        pub fn addOne(self: *Self) !*T
        {
            const n = self.len;
            if (n >= self.buffer.len) {
                return error.OutOfMemory;
            }
            self.len += 1;
            return &self.buffer[n];
        }

        pub fn append(self: *Self, t: T) !void
        {
            const ptr = try self.addOne();
            ptr.* = t;
        }

        pub fn appendSlice(self: *Self, s: []const T) !void
        {
            const newSize = self.len + s.len;
            if (newSize > self.buffer.len) {
                return error.OutOfMemory;
            }
            @memcpy(self.buffer[self.len..newSize], s);
            self.len = newSize;
        }

        pub fn orderedRemove(self: *Self, ind: usize) T
        {
            std.debug.assert(self.len > 0);
            std.debug.assert(ind < self.len);
            const t = self.buffer[ind];
            if (ind < self.len - 1) {
                for (ind..self.len - 1) |i| {
                    self.buffer[i] = self.buffer[i + 1];
                }
            }
            self.len -= 1;
            return t;
        }

        pub fn swapRemove(self: *Self, ind: usize) T
        {
            std.debug.assert(self.len > 0);
            std.debug.assert(ind < self.len);
            const t = self.buffer[ind];
            self.buffer[ind] = self.buffer[self.len - 1];
            self.len -= 1;
            return t;
        }

        pub fn slice(self: anytype) switch (@TypeOf(&self.buffer)) {
            *[size]T => []T,
            *const [size]T => []const T,
            else => unreachable,
        } {
            return self.buffer[0..self.len];
        }
    };

    return TT;
}