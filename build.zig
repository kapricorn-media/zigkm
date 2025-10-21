const std = @import("std");

const raylibBuild = @import("raylib");

pub fn build(b: *std.Build) !void
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlibDep = b.dependency("zlib", .{});
    const zlib = b.addLibrary(.{
        .linkage = .static,
        .name = "zlib",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    zlib.installHeadersDirectory(zlibDep.path("."), "", .{});
    zlib.root_module.addIncludePath(zlibDep.path("."));
    zlib.root_module.addCSourceFiles(.{
        .root = zlibDep.path("."),
        .files = &.{
            "adler32.c",
            "compress.c",
            "crc32.c",
            "deflate.c",
            "gzclose.c",
            "gzlib.c",
            "gzread.c",
            "gzwrite.c",
            "inflate.c",
            "infback.c",
            "inftrees.c",
            "inffast.c",
            "trees.c",
            "uncompr.c",
            "zutil.c",
        },
        .flags = &.{
            "-std=c90",
        },
    });
    zlib.linkLibC();

    const raylib = b.dependency("raylib", .{
        .linux_display_backend = .X11,
    });
    const raygui = b.dependency("raygui", .{});
    const rlLib = try raylibBuild.compileRaylib(raylib.builder, target, optimize, .{
        .linux_display_backend = .X11,
        .opengl_version = .gl_3_3,
    });
    raylibBuild.addRaygui(b, rlLib, raygui, .{
        .linux_display_backend = .X11,
    });

    const module = b.addModule("zigkm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const moduleRl = b.addModule("zigkm-raylib", .{
        .root_source_file = b.path("src/raylib.zig"),
        .target = target,
        .optimize = optimize,
    });
    moduleRl.addImport("zigkm", module);
    moduleRl.addIncludePath(raylib.builder.path("src"));
    moduleRl.linkLibrary(rlLib);

    const testStep = b.step("test", "Test");
    const testSrcs = [_][]const u8 {
        // "src/collision.zig",
        "src/math.zig",
        "src/network.zig",
    };
    for (testSrcs) |src| {
        const testTarget = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(testTarget);

        const runTest = b.addRunArtifact(testTarget);
        // runTest.skip_foreign_checks = true;
        testStep.dependOn(&runTest.step);
    }
}
