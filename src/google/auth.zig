const std = @import("std");
const A = std.mem.Allocator;

const bssl = @import("zigkm-bearssl").c;

pub const AuthType = enum {
    apiKey
};

pub const AuthData = union(AuthType) {
    apiKey: []const u8,
};

pub const AccessToken = struct {
    token: []const u8,
    expiresIn: i64,
};

/// Get a new access token from Google for a service account.
/// `keyFilePath` is the path to a JSON file with the key for the service account.
/// `scope` is the Google permission scope that the given token should have.
/// `subUser` is an optional field for the user that the service account will act on behalf of.
/// Caller must free the returned token's "token" member.
pub fn getAccessToken(a: A, keyFilePath: []const u8, scope: []const u8, subUser: ?[]const u8) !AccessToken
{
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tempAllocator = arena.allocator();

    const ServiceAccountKey = struct {
        type: []const u8,
        project_id: []const u8,
        private_key_id: []const u8,
        private_key: []const u8,
        client_email: []const u8,
        client_id: []const u8,
        auth_uri: []const u8,
        token_uri: []const u8,
        auth_provider_x509_cert_url: []const u8,
        client_x509_cert_url: []const u8,
        universe_domain: []const u8,
    };
    var serviceAccountKeyFile = try std.fs.cwd().openFile(keyFilePath, .{});
    defer serviceAccountKeyFile.close();
    var fileBuf: [4096]u8 = undefined;
    var fileReader = serviceAccountKeyFile.reader(&fileBuf);
    var jsonReader = std.json.Reader.init(tempAllocator, &fileReader.interface);
    const serviceAccountKey = try std.json.parseFromTokenSourceLeaky(ServiceAccountKey, tempAllocator, &jsonReader, .{.ignore_unknown_fields = true});

    if (!std.mem.eql(u8, serviceAccountKey.type, "service_account")) {
        return error.BadKeyFile;
    }

    const Base64Encoder = std.base64.url_safe_no_pad.Encoder;

    const jwtHeaderJson = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const jwtHeader = try allocEncodeBase64(tempAllocator, Base64Encoder, jwtHeaderJson);

    const epochTime = std.time.timestamp();
    const jwtClaimsJson = try std.fmt.allocPrint(
        tempAllocator,
        "{{"
        ++ "\"iss\":\"{s}\","
        ++ "\"sub\":\"{s}\","
        ++ "\"scope\":\"{s}\","
        ++ "\"aud\":\"{s}\","
        ++ "\"exp\":{},"
        ++ "\"iat\":{}"
        ++ "}}",
        .{
            serviceAccountKey.client_email,
            if (subUser) |sub| sub else "",
            scope,
            serviceAccountKey.token_uri,
            epochTime + 3600,
            epochTime,
        }
    );
    const jwtClaims = try allocEncodeBase64(tempAllocator, Base64Encoder, jwtClaimsJson);

    const Sha256 = std.crypto.hash.sha2.Sha256;
    var sha256 = Sha256.init(.{});
    sha256.update(jwtHeader);
    sha256.update(".");
    sha256.update(jwtClaims);
    var hash: [32]u8 = undefined;
    sha256.final(&hash);

    const privateKey = try allocParsePemFile(tempAllocator, serviceAccountKey.private_key);

    var decoder: bssl.br_skey_decoder_context = undefined;
    bssl.br_skey_decoder_init(&decoder);
    bssl.br_skey_decoder_push(&decoder, &privateKey[0], privateKey.len);
    const decoderErr = bssl.br_skey_decoder_last_error(&decoder);
    if (decoderErr != 0) {
        std.log.err("decoder error {}", .{decoderErr});
        return error.PemDecodeError;
    }

    const keyType = bssl.br_skey_decoder_key_type(&decoder);
    if (keyType != bssl.BR_KEYTYPE_RSA) {
        std.log.err("unexpected key type {}", .{keyType});
        return error.WrongKeyType;
    }

    var rsaBuf: [256]u8 = undefined;
    const pk = bssl.br_skey_decoder_get_rsa(&decoder) orelse return error.GetRsaFailed;
    const pkcs1Default = bssl.br_rsa_pkcs1_sign_get_default() orelse return error.BearSSL;
    // Zig can't parse this from the C header file yet
    const BR_HASH_OID_SHA256 = "\x09\x60\x86\x48\x01\x65\x03\x04\x02\x01";
    const result = pkcs1Default(BR_HASH_OID_SHA256, &hash[0], hash.len, pk, &rsaBuf[0]);
    if (result != 1) {
        return error.Pkcs1Failed;
    }

    const rsaBase64 = try allocEncodeBase64(tempAllocator, Base64Encoder, &rsaBuf);

    const authRequestBody = try std.fmt.allocPrint(tempAllocator,
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={s}.{s}.{s}",
        .{jwtHeader, jwtClaims, rsaBase64}
    );

    var httpClient = std.http.Client {.allocator = tempAllocator};
    defer httpClient.deinit();
    const tokenUri = try std.Uri.parse(serviceAccountKey.token_uri);
    var responseWriter = std.io.Writer.Allocating.init(tempAllocator);
    const fetchResult = try httpClient.fetch(.{
        .response_writer = &responseWriter.writer,
        .location = .{.uri = tokenUri},
        .method = .POST,
        .headers = .{
            .content_type = .{
                .override = "application/x-www-form-urlencoded",
            },
        },
        .payload = authRequestBody,
    });
    if (fetchResult.status != .ok) {
        return error.RequestFailed;
    }

    const Response = struct {
        access_token: []const u8,
        token_type: []const u8,
        expires_in: i64,
    };
    const response = std.json.parseFromSliceLeaky(Response, tempAllocator, responseWriter.written(), .{.ignore_unknown_fields = true}) catch |err| {
        std.log.err("err={} full response:\n{s}", .{err, responseWriter.written()});
        return error.BadResponse;
    };

    return .{
        .token = try a.dupe(u8, response.access_token),
        .expiresIn = response.expires_in,
    };
}

fn allocEncodeBase64(a: A, encoder: std.base64.Base64Encoder, bytes: []const u8) A.Error![]const u8
{
    const size = encoder.calcSize(bytes.len);
    const buf = try a.alloc(u8, size);
    return encoder.encode(buf, bytes);
}

fn allocDecodeBase64(a: A, decoder: std.base64.Base64Decoder, bytes: []const u8) ![]const u8
{
    const size = try decoder.calcSizeForSlice(bytes);
    const buf = try a.alloc(u8, size);
    try decoder.decode(buf, bytes);
    return buf;
}

fn allocParsePemFile(a: A, fileData: []const u8) ![]const u8
{
    const firstNewline = std.mem.indexOfScalar(u8, fileData, '\n') orelse return error.BadPem;
    if (firstNewline == fileData.len - 1) {
        return error.BadPem;
    }
    const firstLine = fileData[0..firstNewline];
    if (!std.mem.startsWith(u8, firstLine, "-----") or !std.mem.endsWith(u8, firstLine, "-----")) {
        return error.BadPem;
    }

    const lastNewline = blk2: {
        const last = std.mem.lastIndexOfScalar(u8, fileData, '\n') orelse return error.BadPem;
        if (last == fileData.len - 1) {
            // trailing newline, look for the previous one
            break :blk2 std.mem.lastIndexOfScalar(u8, fileData[0..last], '\n') orelse return error.BadPem;
        } else {
            break :blk2 last;
        }
    };
    if (lastNewline == fileData.len - 1) {
        return error.BadPem;
    }
    const lastLine = std.mem.trim(u8, fileData[lastNewline+1..], "\n");
    if (!std.mem.startsWith(u8, lastLine, "-----") or !std.mem.endsWith(u8, lastLine, "-----")) {
        return error.BadPem;
    }

    const dataBase64Newlines = fileData[firstNewline+1..lastNewline];
    const dataBase64 = try a.alloc(u8, std.mem.replacementSize(u8, dataBase64Newlines, "\n", ""));
    _ = std.mem.replace(u8, dataBase64Newlines, "\n", "", dataBase64);

    return allocDecodeBase64(a, std.base64.standard.Decoder, dataBase64);
}
