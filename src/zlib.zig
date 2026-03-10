const std = @import("std");
const A = std.mem.Allocator;

const zlib = @cImport({
    @cInclude("zlib.h");
});

pub fn deflateOneShot(a: A, level: u8, bytes: []const u8) ![]u8
{
    var stream: zlib.z_stream = std.mem.zeroes(zlib.z_stream);
    const initErr = zlib.deflateInit2(&stream, level, zlib.Z_DEFLATED, zlib.MAX_WBITS, 8, zlib.Z_DEFAULT_STRATEGY);
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

pub fn inflateOneShot(bytes: []const u8, outBuf: []u8) ![]u8
{
    var stream: zlib.z_stream = std.mem.zeroes(zlib.z_stream);
    const initErr = zlib.inflateInit2(&stream, zlib.MAX_WBITS);
    if (initErr != zlib.Z_OK) {
        return error.deflateInit2;
    }

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
