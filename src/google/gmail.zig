const std = @import("std");

const auth = @import("auth.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    keyFilePath: []const u8,
    fromEmail: []const u8,
    token: ?[]const u8,
    tokenExpiration: i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, keyFilePath: []const u8, fromEmail: []const u8) Self
    {
        return Self {
            .allocator = allocator,
            .keyFilePath = keyFilePath,
            .fromEmail = fromEmail,
            .token = null,
            .tokenExpiration = 0,
        };
    }

    pub fn deinit(self: *Self) void
    {
        if (self.token) |t| {
            self.allocator.free(t);
        }
    }

    pub fn send(
        self: *Self,
        fromName: ?[]const u8,
        toEmail: []const u8,
        toName: ?[]const u8,
        subject: []const u8,
        body: []const u8) !void
    {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const tempAllocator = arena.allocator();

        const epochTime = std.time.timestamp();
        if (self.token == null or self.tokenExpiration <= epochTime) {
            try self.refreshAccessToken();
        }
        const token = self.token orelse return error.NoToken;

        const Base64UrlEnc = std.base64.url_safe.Encoder;

        const authString = try std.fmt.allocPrint(tempAllocator, "Bearer {s}", .{token});
        const emailText = try std.fmt.allocPrint(tempAllocator,
            "From: {s} <{s}>\nTo: {s} <{s}>\nSubject: {s}\n\n{s}",
            .{
                if (fromName) |name| name else "",
                self.fromEmail,
                if (toName) |name| name else "",
                toEmail,
                subject,
                body,
            }
        );
        const emailTextBase64 = try allocEncodeBase64(tempAllocator, Base64UrlEnc, emailText);
        const gmailRequestBody = try std.fmt.allocPrint(tempAllocator, "{{\"raw\":\"{s}\"}}", .{
            emailTextBase64
        });

        var httpClient = std.http.Client {.allocator = tempAllocator};
        defer httpClient.deinit();
        const uri = comptime std.Uri.parse("https://gmail.googleapis.com/gmail/v1/users/me/messages/send") catch unreachable;
        var responseWriter = std.io.Writer.Allocating.init(tempAllocator);
        const fetchResult = try httpClient.fetch(.{
            .response_writer = &responseWriter.writer,
            .location = .{.uri = uri},
            .method = .POST,
            .headers = .{
                .authorization = .{
                    .override = authString,
                },
                .accept_encoding = .{
                    .override = "application/json",
                },
                .content_type = .{
                    .override = "application/json",
                },
            },
            .payload = gmailRequestBody,
        });
        if (fetchResult.status != .ok) {
            return error.RequestFailed;
        }

        _ = std.mem.indexOf(u8, responseWriter.written(), "SENT") orelse {
            std.log.err("Gmail API response missing SENT, full response:\n{s}", .{responseWriter.written()});
            return error.NotSent;
        };
    }

    fn refreshAccessToken(self: *Self) !void
    {
        if (self.token) |t| {
            self.allocator.free(t);
            self.token = null;
        }
        const token = try auth.getAccessToken(self.allocator, self.keyFilePath, "https://www.googleapis.com/auth/gmail.send", self.fromEmail);
        self.token = token.token;
        self.tokenExpiration = std.time.timestamp() + token.expiresIn;
    }
};

fn allocEncodeBase64(
    allocator: std.mem.Allocator,
    encoder: std.base64.Base64Encoder,
    bytes: []const u8) std.mem.Allocator.Error![]const u8
{
    const size = encoder.calcSize(bytes.len);
    const buf = try allocator.alloc(u8, size);
    return encoder.encode(buf, bytes);
}
