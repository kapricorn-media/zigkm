const std = @import("std");

const appkm = @import("zigkm-app");
const httpz = @import("httpz");

pub fn parseUrlQueryParams(comptime T: type, query: []const u8) ?T
{
    var result: T = undefined;
    const Fields = std.meta.fields(T);
    var found: [Fields.len]bool = undefined;
    @memset(&found, false);
    var queryIt = std.mem.splitScalar(u8, query, '&');
    while (queryIt.next()) |param| {
        var it = std.mem.splitScalar(u8, param, '=');
        const key = it.next() orelse break;
        const value = it.next() orelse break;
        inline for (Fields, 0..) |f, i| {
            if (std.mem.eql(u8, key, f.name)) {
                switch (@typeInfo(f.type)) {
                    .int => {
                        @field(result, f.name) = std.fmt.parseInt(f.type, value, 10) catch {
                            return null;
                        };
                    },
                    .pointer => |ti| {
                        if (ti.child == u8 and ti.size == .slice) {
                            @field(result, f.name) = value;
                        } else {
                            @compileLog("Unsupported type", f.type);
                        }
                    },
                    else => @compileLog("Unsupported type", f.type),
                }
                found[i] = true;
            }
        }
    }
    for (found) |f| {
        if (!f) return null;
    }
    return result;
}

test "parseUrlQueryParams"
{
    const T1 = struct {
        a: []const u8,
        b: []const u8,
    };
    try std.testing.expectEqualDeep(T1 {.a = "hello", .b = "goodbye"}, parseUrlQueryParams(T1, "a=hello&b=goodbye"));
    try std.testing.expectEqualDeep(null, parseUrlQueryParams(T1, "a=hello&c=goodbye"));
    try std.testing.expectEqualDeep(null, parseUrlQueryParams(T1, "c=hello&b=goodbye"));

    const T2 = struct {
        hello: u32,
        int: i16,
        theString: []const u8,
    };
    try std.testing.expectEqualDeep(T2 {.hello = 404, .int = 10000, .theString = "hello world"}, parseUrlQueryParams(T2, "hello=404&int=10000&theString=hello world"));
    try std.testing.expectEqualDeep(T2 {.hello = 495810738, .int = -100, .theString = ""}, parseUrlQueryParams(T2, "hello=495810738&int=-100&theString="));
    try std.testing.expectEqualDeep(T2 {.hello = 10, .int = 10, .theString = "1234"}, parseUrlQueryParams(T2, "hello=10&int=10&theString=1234"));
    try std.testing.expectEqualDeep(null, parseUrlQueryParams(T2, "hello=4958107382595638&int=0&theString=hello"));
    try std.testing.expectEqualDeep(null, parseUrlQueryParams(T2, "hello=10&int=-18238675843&theString=hello"));
}

pub fn responded(res: *const httpz.Response) bool
{
    // WARN(patio): This is very httpz-implementation-dependent.
    return res.status != 200 or res.pos > 0 or res.buffer.writer.buffered().len > 0 or res.body.len > 0;
}

pub fn writeFileResponse(res: *httpz.Response, relativePath: []const u8, final: bool) !void
{
    const cwd = std.fs.cwd();
    const file = cwd.openFile(relativePath, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (final) {
                return err;
            } else {
                return;
            }
        },
        else => return err,
    };
    defer file.close();
    const fileData = try file.readToEndAlloc(res.arena, 1024 * 1024 * 1024);

    res.status = 200;
    res.content_type = httpz.ContentType.forFile(relativePath);
    const writer = res.writer();
    try writer.writeAll(fileData);
    try res.write();
}

fn uriHasFileExtension(uri: []const u8) bool
{
    var dotAfterSlash = false;
    for (uri) |c| {
        if (c == '.') {
            dotAfterSlash = true;
        }
        else if (c == '/') {
            dotAfterSlash = false;
        }
    }
    return dotAfterSlash;
}

pub fn serveStatic(res: *httpz.Response, uri: []const u8, comptime dir: []const u8, final: bool) !void
{
    if (uri.len == 0) {
        return error.BadUri;
    }
    if (uri.len > 1 and uri[1] == '/') {
        return error.BadUri;
    }

    var prevWasDot = false;
    for (uri) |c| {
        if (c == '.') {
            if (prevWasDot) {
                return error.BadUri;
            }
            prevWasDot = true;
        } else {
            prevWasDot = false;
        }
    }

    const path = try std.fmt.allocPrint(res.arena, dir ++ "/{s}", .{uri[1..]});
    try writeFileResponse(res, path, final);
}

pub fn serverAppEndpoints(req: *httpz.Request, res: *httpz.Response, data: *const appkm.bigdata.Data, wasmPath: []const u8, final: bool, comptime debug: bool) !void
{
    if (req.method == .GET) {
        if (std.mem.eql(u8, req.url.path, "/main.wasm")) {
            try writeFileResponse(res, wasmPath, final);
        } else {
            const path = blk: {
                if (std.mem.containsAtLeast(u8, req.url.path, 1, ".well-known")) {
                    // Kinda hacky, but whatever
                    break :blk req.url.path;
                }

                const extension = std.fs.path.extension(req.url.path);
                if (extension.len == 0 or std.mem.eql(u8, req.url.path, "/wasm.html")) {
                    break :blk "/wasm.html";
                } else {
                    break :blk req.url.path;
                }
            };
            if (debug) {
                // For faster iteration
                serveStatic(res, path, "zig-out/server-temp/static", final) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return,
                };
            }
            const content = data.map.get(path) orelse {
                if (final) {
                    res.status = 404;
                }
                return;
            };

            res.content_type = httpz.ContentType.forFile(path);
            try res.writer().writeAll(content);
        }
    } else if (req.method == .POST) {
        // ...
    }
}
