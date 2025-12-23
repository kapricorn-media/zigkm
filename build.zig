const std = @import("std");

const raylibBuild = @import("raylib");

pub const version = @import("src/version.zig");

pub fn build(b: *std.Build) !void
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlibDep = b.dependency("zlib", .{
        .target = .target,
        .optimize = optimize,
    });
    const zlib = b.addLibrary(.{
        .linkage = .static,
        .name = "zlib",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    zlib.installHeadersDirectory(zlibDep.path("."), "", .{});
    zlib.root_module.sanitize_c = .off; // Workaround for https://github.com/ziglang/zig/issues/23052
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
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.linkLibrary(zlib);

    const moduleRl = b.addModule("zigkm-raylib", .{
        .root_source_file = b.path("src/raylib.zig"),
        .target = target,
        .optimize = optimize,
    });
    moduleRl.addImport("zigkm", module);
    moduleRl.addIncludePath(raylib.builder.path("src"));
    moduleRl.linkLibrary(rlLib);

    const moduleConfigDummy = b.createModule(.{
        .root_source_file = b.path("src/config_dummy.zig"),
        .target = target,
        .optimize = optimize,
    });

    const launcherExe = b.addExecutable(.{
        .name = "km_launcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/launcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .windows) {
        launcherExe.subsystem = .Windows;
    }
    launcherExe.root_module.addImport("zigkm", module);
    launcherExe.root_module.addImport("zigkm-raylib", moduleRl);
    launcherExe.root_module.addImport("config", moduleConfigDummy);
    launcherExe.root_module.link_libc = true;
    b.installArtifact(launcherExe);

    const testStep = b.step("test", "Test");
    const testSrcs = [_][]const u8 {
        "src/math.zig",
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
