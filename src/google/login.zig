const std = @import("std");

fn generateCsprngSeed(seed: *[32]u8) void
{
    const prngSeed: u64 = @intCast(std.time.microTimestamp());
    var prng = std.rand.DefaultPrng.init(prngSeed);
    prng.random().bytes(seed);
}

test
{
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var seed: [32]u8 = undefined;
    generateCsprngSeed(&seed);
    var csprng = std.rand.DefaultCsprng.init(seed);

    const codeVerifierBytes = 32;
    var codeVerifier: [codeVerifierBytes]u8 = undefined;
    csprng.random().bytes(&codeVerifier);

    const urlSafeBase64 = std.base64.url_safe;
    const bufLength = comptime urlSafeBase64.Encoder.calcSize(codeVerifierBytes);
    var buf: [bufLength]u8 = undefined;
    const codeVerifierString = urlSafeBase64.Encoder.encode(&buf, &codeVerifier);

    // const clientId = "346914321659-ubq8u9hur6aq8esjhsik1vklakcpqgll.apps.googleusercontent.com";
    const clientId = "346914321659-p64a97pla5h3mkp7nb4fmsl09ghqpb0h.apps.googleusercontent.com";
    const query = try std.fmt.allocPrint(allocator,
        "client_id={s}"
        ++ "&redirect_uri=http://localhost:8000/login_google"
        ++ "&response_type=code"
        ++ "&scope=email profile"
        ++ "&code_challenge={s}"
        ++ "&code_challenge_method=plain",
        .{
            clientId, codeVerifierString
        }
    );
    const queryEscaped = try std.Uri.escapeQuery(allocator, query);
    const authUri = std.Uri {
        .scheme = "https",
        .user = null,
        .password = null,
        .host = "accounts.google.com",
        .port = null,
        .path = "/o/oauth2/v2/auth",
        .query = queryEscaped,
        .fragment = null,
    };
    const authUriString = try std.fmt.allocPrint(allocator, "{+/}", .{authUri});

    std.debug.print("{s}\n", .{authUriString});
    // const authUriString = try std.fmt.allocPrint(allocator,
    //     "{s}"
    //     ++ "?client_id={s}"
    //     ++ "&redirect_uri=http://localhost:8000"
    //     ++ "&response_type=code"
    //     ++ "&scope=email profile"
    //     ++ "&code_challenge={s}"
    //     ++ "&code_challenge_method=plain",
    //     .{
    //         authEndpoint, clientId, codeVerifierString
    //     }
    // );
    // const authUriEscaped = try std.Uri.escapeString(allocator, authUriString);

    // std.debug.print("{s}", .{authUriString});

    // const authUri = try std.Uri.parse(authUriString);
    // const authHeaders = std.http.Headers.init(allocator);
    // var client = std.http.Client {.allocator = allocator};
    // var req = try client.request(.GET, authUri, authHeaders, .{});
    // try req.start();
    // try req.wait();

    // std.debug.print("response code={}\n", .{req.response.status});
    // for (req.response.headers.list.items) |h| {
    //     std.debug.print("  {s}={s}\n", .{h.name, h.value});
    // }
    // const responseBody = try req.reader().readAllAlloc(allocator, 1024 * 1024 * 1024);
    // std.debug.print("{s}\n", .{responseBody});

    // std.debug.print("Google login complete\n", .{});
}
