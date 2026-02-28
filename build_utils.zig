const std = @import("std");

const A = std.mem.Allocator;

fn isTermOk(term: std.process.Child.Term) bool
{
    switch (term) {
        std.process.Child.Term.Exited => |value| {
            return value == 0;
        },
        else => {
            return false;
        }
    }
}

fn checkTermStdout(execResult: std.process.Child.RunResult) ?[]const u8
{
    const ok = isTermOk(execResult.term);
    if (!ok) {
        std.log.err("{}", .{execResult.term});
        if (execResult.stdout.len > 0) {
            std.log.info("{s}", .{execResult.stdout});
        }
        if (execResult.stderr.len > 0) {
            std.log.err("{s}", .{execResult.stderr});
        }
        return null;
    }
    return execResult.stdout;
}

pub fn execCheckTermStdoutWd(argv: []const []const u8, cwd: ?[]const u8, a: A) ?[]const u8
{
    const result = std.process.Child.run(.{
        .allocator = a,
        .argv = argv,
        .cwd = cwd
    }) catch |err| {
        std.log.err("std.process.Child.run error: {}", .{err});
        return null;
    };
    return checkTermStdout(result);
}

pub fn execCheckTermStdout(argv: []const []const u8, a: A) ?[]const u8
{
    return execCheckTermStdoutWd(argv, null, a);
}

pub fn execCheckTermWd(argv: []const []const u8, cwd: ?[]const u8, a: A) bool
{
    return execCheckTermStdoutWd(argv, cwd, a) != null;
}

pub fn execCheckTerm(argv: []const []const u8, a: A) bool
{
    return execCheckTermStdoutWd(argv, null, a) != null;
}

pub fn listDirFiles(dirPathRelative: []const u8, a: A) !std.ArrayList([]const u8)
{
    var files = std.ArrayList([]const u8){};

    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(dirPathRelative, .{.iterate = true});
    var dirIt = dir.iterate();
    while (true) {
        const entryOpt = dirIt.next() catch {
            return error.IteratorError;
        };
        if (entryOpt) |entry| {
            switch (entry.kind) {
                .file => {
                    const fileNamePtr = try files.addOne(a);
                    fileNamePtr.* = try std.fmt.allocPrint(a, "{s}/{s}", .{dirPathRelative, entry.name});
                },
                else => {}
            }
        }
        else {
            break;
        }
    }

    return files;
}
