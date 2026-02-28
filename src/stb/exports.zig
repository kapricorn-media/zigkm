const std = @import("std");

// stb dependencies

fn allocatorCast(ptr: ?*anyopaque) *std.mem.Allocator
{
    return @ptrCast(@alignCast(ptr));
}

export fn stb_zig_assert(expression: c_int) void
{
    std.debug.assert(expression != 0);
}

export fn stb_zig_strlen(str: [*c]const i8) usize
{
    return std.mem.len(str);
}

export fn stb_zig_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque
{
    if (dest) |d| {
        if (src) |s| {
            const dSlice = @as([*]u8, @ptrCast(d))[0..n];
            const sSlice = @as([*]const u8, @ptrCast(s))[0..n];
            @memcpy(dSlice, sSlice);
        }
    }
    return dest;
}

export fn stb_zig_memset(str: ?*anyopaque, c: c_int, n: usize) ?*anyopaque
{
    if (str) |s| {
        const sSlice = @as([*]u8, @ptrCast(s))[0..n];
        @memset(sSlice, @as(u8, @intCast(c)));
    }
    return str;
}

export fn stb_zig_ifloor(x: f64) c_int
{
    return @intFromFloat(std.math.floor(x));
}

export fn stb_zig_iceil(x: f64) c_int
{
    return @intFromFloat(std.math.ceil(x));
}

export fn stb_zig_sqrt(x: f64) f64
{
    return std.math.sqrt(x);
}

export fn stb_zig_pow(x: f64, y: f64) f64
{
    return std.math.pow(f64, x, y);
}

export fn stb_zig_fmod(x: f64, y: f64) f64
{
    return @mod(x, y);
}

export fn stb_zig_cos(x: f64) f64
{
    return std.math.cos(x);
}

export fn stb_zig_acos(x: f64) f64
{
    return std.math.acos(x);
}

export fn stb_zig_fabs(x: f64) f64
{
    return @abs(x);
}

export fn stb_zig_malloc(size: usize, userData: ?*anyopaque) ?*anyopaque
{
    var allocator = allocatorCast(userData);
    // Hmm, does malloc always align to 4 or 8 bytes? I didn't know this...
    const result = allocator.alignedAlloc(u8, .@"8", size) catch |err| {
        std.log.err("stb_zig_malloc failed with err={} for size={}", .{err, size});
        return null;
    };
    return if (size == 0) null else &result[0];
}

export fn stb_zig_free(ptr: ?*anyopaque, userData: ?*anyopaque) void
{
    const allocator = allocatorCast(userData);
    _ = allocator;
    _ = ptr;
    // TODO can't free with Zig Allocator without size, so no free. YOLO!
}

export fn stb_zig_sort(base: ?*anyopaque, n: usize, size: usize, compare: ?*anyopaque) void
{
    const CompareFnType = fn(a: ?*anyopaque, b: ?*anyopaque) callconv(.c) c_int;
    const Sort = struct {
        fn lessThan(a: [*]u8, b: [*]u8, compareFn: *CompareFnType) bool
        {
            return compareFn(@ptrCast(a), @ptrCast(b)) < 0;
        }
    };

    const numItems = n / size;

    const baseBytes: [*]u8 = @ptrCast(base);
    var i: usize = 1;
    while (i < numItems) : (i += 1) {
        var j = i;
        const a: [*]u8 = @ptrCast(&baseBytes[j * size]);
        const b: [*]u8 = @ptrCast(&baseBytes[(j - 1) * size]);
        while (j > 0 and Sort.lessThan(a, b, @alignCast(@ptrCast(compare)))) : (j -= 1) {
            // swap a with b
            var tmp: u8 = undefined;
            for (0..size) |ii| {
                tmp = a[ii];
                a[ii] = b[ii];
                b[ii] = tmp;
            }
        }
    }
}

export fn zig_print(msg: [*c]u8, arg1: u32, arg2: u32, arg3: u32, arg4: u32) void
{
    std.log.info("zig_print {s} {} {} {} {}", .{msg, arg1, arg2, arg3, arg4});
}
