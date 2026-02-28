const std = @import("std");

const google = @import("zigkm-google");

pub fn main() !void
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 1 + 4) {
        std.log.err("Expected 4 arguments: <path to service account key JSON> <from-email> <from-name> <to-email>", .{});
        return error.BadArgs;
    }

    const keyPath = args[1];
    const fromEmail = args[2];
    const fromName = args[3];
    const toEmail = args[4];
    var gmailClient = google.gmail.Client.init(allocator, keyPath, fromEmail);
    defer gmailClient.deinit();

    const subject = "Gmail API Test";
    const body = "The quick brown fox jumps over the lazy dog.\n\nHave a good day!\n\nBest,\nzigkm.";
    try gmailClient.send(fromName, toEmail, null, subject, body);

    std.log.info("Sent email from {s} (as \"{s}\") to {s}", .{fromEmail, fromName, toEmail});
}
