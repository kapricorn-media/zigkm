const std = @import("std");
const builtin = @import("builtin");

const raylibBuild = @import("raylib");

pub const utils = @import("build_utils.zig");
pub const version = @import("src/version.zig");

const bsslSrcs = @import("src/bearssl/srcs.zig");

var basePath: []const u8 = "."; // base path to this module
var appName: []const u8 = undefined;
var appAddress: []const u8 = undefined; // e.g. app.something.appname

const ANDROID_SDK_MIN_VERSION = 21; // Required by Google Play installer
const ANDROID_SDK_VERSION = 35;
const ANDROID_NDK_VERSION = "28.1.13356709";
const ANDROID_SDK_VERSION_STRING = std.fmt.comptimePrint("{}", .{ANDROID_SDK_VERSION});
const ANDROID_SDK_BUILDTOOLS_VERSION = "36.0.0-rc5";

const AndroidOptions = struct {
    debug: bool = true,
    pathJdk: []const u8 = "",
    pathSdk: []const u8 = "",
    keystoreAlias: []const u8 = "",
    keystorePass: []const u8 = "",
    deviceId: []const u8 = "",
};
var android: ?AndroidOptions = null;

const iosMinVersion = std.SemanticVersion {.major = 15, .minor = 0, .patch = 0};
const metalMinVersion = std.SemanticVersion {.major = 2, .minor = 4, .patch = 0};
const iosMinVersionString = std.fmt.comptimePrint("{}.{}", .{
    iosMinVersion.major, iosMinVersion.minor
});
const metalMinVersionString = std.fmt.comptimePrint("{}.{}", .{
    metalMinVersion.major, metalMinVersion.minor
});

const IOSOptions = struct {
    simulator: bool,
    certificate: []const u8,
};
var ios: ?IOSOptions = null;

const serverOutputPath = "server";

pub fn build(b: *std.Build) !void
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tracyEnabled = b.option(bool, "tracy", "Whether to enable Tracy") orelse false;

    const bearssl = b.dependency("bearssl", .{});
    const tracy = b.dependency("tracy", .{});

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = .ReleaseFast,
    });

    _ = try b.modules.put(b.dupe("zigimg"), zigimg.module("zigimg"));

    const moduleTracyImpl = b.createModule(.{
        .root_source_file = b.path(if (tracyEnabled) "src/tracy/impl.zig" else "src/tracy/stub.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (tracyEnabled) {
        const tracyClientLib = b.addLibrary(.{
            .linkage = .static,
            .name = "tracy_client",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });
        tracyClientLib.root_module.addCMacro("TRACY_ENABLE", "1");
        tracyClientLib.addCSourceFile(.{.file = tracy.path("public/TracyClient.cpp"), .flags = &.{}});
        tracyClientLib.linkLibCpp();
        if (target.result.os.tag == .windows) {
            tracyClientLib.linkSystemLibrary("ws2_32");
            tracyClientLib.linkSystemLibrary("Dbghelp");
        }
        moduleTracyImpl.addIncludePath(tracy.path("public/tracy"));
        moduleTracyImpl.linkLibrary(tracyClientLib);
    }
    const moduleTracy = b.addModule("zigkm-tracy", .{
        .root_source_file = b.path("src/tracy/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    moduleTracy.addImport("tracy_impl", moduleTracyImpl);

    const module = b.addModule("zigkm", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("zigimg", zigimg.module("zigimg"));
    module.addImport("zigkm-tracy", moduleTracy);

    if (!target.result.cpu.arch.isWasm() and target.result.abi != .android) {
        // Stuff here requires lib C (and maybe makes other assumptions about the platform).
        const zlibDep = b.dependency("zlib", .{});
        const zlib = b.addLibrary(.{
            .linkage = .static,
            .name = "zlib",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = .ReleaseFast,
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

        module.linkLibrary(zlib);

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

        const moduleRl = b.addModule("zigkm-raylib", .{
            .root_source_file = b.path("src/raylib/lib.zig"),
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

        const assetpack = b.addExecutable(.{
            .name = "assetpack",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/assetpack.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        assetpack.root_module.addImport("zigkm", module);
        assetpack.root_module.addImport("zigimg", zigimg.module("zigimg"));
        b.installArtifact(assetpack);
    }

    // const testStep = b.step("test", "Test");
    // const testSrcs = [_][]const u8 {
    //     "src/math.zig",
    // };
    // for (testSrcs) |src| {
    //     const testTarget = b.addTest(.{
    //         .root_module = b.createModule(.{
    //             .root_source_file = b.path(src),
    //             .target = target,
    //             .optimize = optimize,
    //         }),
    //     });
    //     b.installArtifact(testTarget);

    //     const runTest = b.addRunArtifact(testTarget);
    //     // runTest.skip_foreign_checks = true;
    //     testStep.dependOn(&runTest.step);
    // }

    // // zigkm-kb
    // const kbLib = b.addLibrary(.{
    //     .linkage = .static,
    //     .name = "zigkm-kb-lib",
    //     .root_module = b.createModule(.{
    //         .target = target,
    //         .optimize = optimize,
    //     }),
    // });
    // kbLib.addCSourceFiles(.{
    //     .files = &[_][]const u8{
    //         "deps/kb/kb_text_shape_impl.c",
    //     },
    //     .flags = &[_][]const u8{"-std=c11"}
    // });
    // const kbModule = b.addModule("zigkm-kb", .{
    //     .root_source_file = b.path("src/kb/kb.zig"),
    // });
    // kbModule.addIncludePath(b.path("deps/kb"));
    // kbModule.linkLibrary(kbLib);

    // zigkm-lib
    const libModule = b.addModule("zigkm-lib", .{
        .root_source_file = b.path("src/lib2.zig"),
    });

    // zigkm-math
    const mathModule = b.addModule("zigkm-math", .{
        .root_source_file = b.path("src/math.zig"),
    });

    // zigkm-serialize
    const serializeModule = b.addModule("zigkm-serialize", .{
        .root_source_file = b.path("src/serialize.zig"),
    });

    // zigkm-platform
    const platformModule = b.addModule("zigkm-platform", .{
        .root_source_file = b.path("src/platform/platform.zig"),
    });

    // zigkm-stb
    const stb = b.dependency("stb", .{});
    const stbLib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigkm-stb-lib",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    stbLib.addCSourceFiles(.{
        .files = &.{
            "src/stb/stb.c",
        },
        .flags = &.{
            "-std=c11",
        }
    });
    stbLib.root_module.addIncludePath(stb.path(""));
    const stbModule = b.addModule("zigkm-stb", .{
        .root_source_file = b.path("src/stb/lib.zig"),
    });
    stbModule.addIncludePath(stb.path(""));
    stbModule.linkLibrary(stbLib);

    // zigkm-app
    const appModule = b.addModule("zigkm-app", .{
        .root_source_file = b.path("src/app/app.zig"),
        .imports = &.{
            // .{.name = "httpz", .module = httpz.module("httpz")},
            // .{.name = "zigkm-kb", .module = kbModule},
            .{.name = "zigkm-lib", .module = libModule},
            .{.name = "zigkm-math", .module = mathModule},
            .{.name = "zigkm-platform", .module = platformModule},
            .{.name = "zigkm-stb", .module = stbModule},
            .{.name = "zigimg", .module = zigimg.module("zigimg")},
        },
    });
    appModule.addIncludePath(b.path("src/app"));
    if (android) |ao| {
        const ndkPath = try std.fs.path.join(b.allocator, &.{ao.pathSdk, "ndk", ANDROID_NDK_VERSION});
        const ndkSysroot = try std.fs.path.join(b.allocator, &.{ndkPath, "toolchains", "llvm", "prebuilt", "windows-x86_64", "sysroot", "usr"});
        appModule.addIncludePath(.{.cwd_relative = try std.fs.path.join(b.allocator, &.{ndkSysroot, "include"})});
        appModule.addIncludePath(.{.cwd_relative = try std.fs.path.join(b.allocator, &.{ndkSysroot, "include", "aarch64-linux-android"})});
    }

    // zigkm-server
    const serverModule = b.addModule("zigkm-server", .{
        .root_source_file = b.path("src/server.zig"),
        .imports = &.{
            .{.name = "httpz", .module = httpz.module("httpz")},
            .{.name = "zigkm-app", .module = appModule},
        },
    });
    _ = serverModule;

    // zigkm-bearssl
    const bsslLib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigkm-bearssl-lib",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    bsslLib.addIncludePath(bearssl.path("inc"));
    bsslLib.addIncludePath(bearssl.path("src"));
    bsslLib.addCSourceFiles(.{
        .root = bearssl.path(""),
        .files = &bsslSrcs.SRCS,
        .flags = &[_][]const u8{
            "-Wall",
            "-DBR_LE_UNALIGNED=0", // this prevent BearSSL from using undefined behaviour when doing potential unaligned access
        },
    });
    bsslLib.linkLibC();
    if (target.result.os.tag == .windows) {
        bsslLib.linkSystemLibrary("advapi32");
    }
    const bsslModule = b.addModule("zigkm-bearssl", .{
        .root_source_file = b.path("src/bearssl/bearssl.zig"),
    });
    bsslModule.addIncludePath(bearssl.path("inc"));
    bsslModule.linkLibrary(bsslLib);

    // zigkm-google
    const googleModule = b.addModule("zigkm-google", .{
        .root_source_file = b.path("src/google/google.zig"),
        .imports = &[_]std.Build.Module.Import {
            .{.name = "zigkm-bearssl", .module = bsslModule},
        },
    });

    // zigkm-auth
    const authModule = b.addModule("zigkm-auth", .{
        .root_source_file = b.path("src/auth.zig"),
        .imports = &[_]std.Build.Module.Import {
            .{.name = "httpz", .module = httpz.module("httpz")},
            .{.name = "zigkm-google", .module = googleModule},
            .{.name = "zigkm-platform", .module = platformModule},
            .{.name = "zigkm-serialize", .module = serializeModule},
        }
    });
    _ = authModule;

    const genbigdata = b.addExecutable(.{
        .name = "genbigdata",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/genbigdata.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    genbigdata.root_module.addImport("zigkm-app", appModule);
    b.installArtifact(genbigdata);

    const gmail = b.addExecutable(.{
        .name = "gmail",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/gmail.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gmail.root_module.addImport("zigkm-google", googleModule);
    gmail.linkLibrary(bsslLib);
    b.installArtifact(gmail);

    // tests
    const runTests = b.step("test", "Run all tests");
    const testSrcs = [_][]const u8 {
        "src/auth.zig",
        "src/math.zig",
        "src/net.zig",
        "src/psd.zig",
        "src/serde.zig",
        "src/serialize.zig",
        "src/app/bigdata.zig",
        "src/app/server_utils.zig",
        "src/app/tree.zig",
        "src/app/ui.zig",
        "src/app/uix.zig",
        // "src/google/login.zig",
    };
    for (testSrcs) |src| {
        const testCompile = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        // testCompile.root_module.addImport("zigkm-math", mathModule);

        const testRun = b.addRunArtifact(testCompile);
        testRun.has_side_effects = true;
        runTests.dependOn(&testRun.step);
    }
}

pub fn setupApp(
    b: *std.Build,
    bZigkm: *std.Build,
    options: struct {
        name: []const u8,
        srcApp: []const u8,
        srcServer: []const u8,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        appAddress: []const u8,
        dev: bool,
        importsClient: []const std.Build.Module.Import = &.{},
        importsServer: []const std.Build.Module.Import = &.{},
    },
) !void {
    const a = b.allocator;

    const targetWasm = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const httpz = bZigkm.dependency("httpz", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const zigkm = b.dependency("zigkm", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const zigkmWasm = b.dependency("zigkm", .{
        .target = targetWasm,
        .optimize = options.optimize,
    });
    // TODO hmmm, fix...
    var modulesWasm: std.ArrayList(std.Build.Module) = .{};
    for (options.importsClient) |import| {
        var module = try modulesWasm.addOne(a);
        module.* = import.module.*;
        module.resolved_target = targetWasm;
    }

    basePath = zigkm.path(".").getPath(b);
    appName = options.name;
    appAddress = options.appAddress;

    const server = b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(options.srcServer),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{.name = "httpz", .module = httpz.module("httpz")},
                .{.name = "zigkm-app", .module = zigkm.module("zigkm-app")},
                .{.name = "zigkm-platform", .module = zigkm.module("zigkm-platform")},
                .{.name = "zigkm-server", .module = zigkm.module("zigkm-server")},
            },
        }),
    });
    for (options.importsServer) |import| {
        server.root_module.addImport(import.name, import.module);
    }

    const wasm = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path(options.srcApp),
            .target = targetWasm,
            .optimize = options.optimize,
            .imports = &.{
                .{.name = "zigkm-app", .module = zigkmWasm.module("zigkm-app")},
                .{.name = "zigkm-lib", .module = zigkmWasm.module("zigkm-lib")},
                .{.name = "zigkm-math", .module = zigkmWasm.module("zigkm-math")},
                .{.name = "zigkm-platform", .module = zigkmWasm.module("zigkm-platform")},
                .{.name = "zigkm-serialize", .module = zigkmWasm.module("zigkm-serialize")},
                .{.name = "zigkm-stb", .module = zigkmWasm.module("zigkm-stb")},
            },
        }),
    });
    wasm.entry = .disabled;
    wasm.root_module.export_symbol_names = &.{
        "onInit",
        "onAnimationFrame",
        "onMouseMove",
        "onMouseDown",
        "onMouseUp",
        "onMouseWheel",
        "onKeyDown",
        "onUtf32",
        "onTouchStart",
        "onTouchMove",
        "onTouchEnd",
        "onTouchCancel",
        "onPopState",
        "onDeviceOrientation",
        "onHttp",
        "onFileDrag",
        "onDropFile",
        "onLoadedFont",
        "onLoadedTexture",
        "loadFontData",
    };
    for (modulesWasm.items, 0..) |*m, i| {
        wasm.root_module.addImport(options.importsClient[i].name, m);
    }

    const buildServerStep = b.step("server_build", "Build server");
    const installServerStep = b.addInstallArtifact(server, .{
        .dest_dir = .{.override = .{.custom = serverOutputPath}}
    });
    buildServerStep.dependOn(&installServerStep.step);

    const installWasmStep = b.addInstallArtifact(wasm, .{
        .dest_dir = .{.override = .{.custom = serverOutputPath}}
    });
    buildServerStep.dependOn(&installWasmStep.step);
    buildServerStep.dependOn(&b.addInstallDirectory(.{
        .source_dir = zigkm.path("src/app/static"),
        .install_dir = .{.custom = "server-temp/static"},
        .install_subdir = "",
    }).step);
    buildServerStep.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("data"),
        .install_dir = .{.custom = "server-temp/static"},
        .install_subdir = "",
    }).step);
    buildServerStep.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("src/server_static"),
        .install_dir = .{.custom = "server-temp/static"},
        .install_subdir = "",
    }).step);

    const packageServerStep = b.step("server_package", "Package server");
    packageServerStep.dependOn(buildServerStep);
    packageServerStep.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("scripts/server"),
        .install_dir = .{.custom = "server"},
        .install_subdir = "scripts",
    }).step);
    packageServerStep.dependOn(&b.addInstallArtifact(zigkm.artifact("genbigdata"), .{
        .dest_dir = .{.override = .{.custom = "tools"}}
    }).step);
    packageServerStep.makeFn = stepPackageServer;

    const buildAppStep = b.step("app_build", "Build and install app");
    const packageAppStep = b.step("app_package", "Package app");
    packageAppStep.dependOn(buildAppStep);
    const runAppStep = b.step("app_run", "Run app on connected device");
    runAppStep.dependOn(packageAppStep);

    const iosPathSdk = b.option([]const u8, "ios_path_sdk", "Absolute path to the iOS SDK") orelse "";
    if (iosPathSdk.len > 0) {
        // App - iOS
        const iosOptions: IOSOptions = .{
            .simulator = b.option(bool, "ios_simulator", "Whether to build for iOS simulator or a device") orelse false,
            .certificate = b.option([]const u8, "ios_certificate", "Name of certificate from Keychain") orelse "",
        };
        ios = iosOptions;

        const targetAppIosQuery = if (iosOptions.simulator)
            std.Target.Query {
                .cpu_arch = null,
                .os_tag = .ios,
                .os_version_min = .{.semver = iosMinVersion},
                .abi = .simulator,
            }
        else
            std.Target.Query {
                .cpu_arch = .aarch64,
                .os_tag = .ios,
                .os_version_min = .{.semver = iosMinVersion},
                .abi = null,
            };

        const targetAppIos = b.resolveTargetQuery(targetAppIosQuery);
        const zigkmIos = b.dependency("zigkm", .{
            .target = targetAppIos,
            .optimize = options.optimize,
        });

        var sdk = iosPathSdk;
        if (std.mem.eql(u8, sdk, "find")) {
            sdk = std.zig.system.darwin.getSdk(b.allocator, &targetAppIos.result) orelse {
                std.log.err("iOS SDK not found", .{});
                return error.MissingSDK;
            };
        }
        std.log.info("iOS SDK path: {s}", .{sdk});

        const lib = b.addLibrary(.{
            .linkage = .static,
            .name = "applib",
            .root_module = b.createModule(.{
                .root_source_file = b.path(options.srcApp),
                .target = targetAppIos,
                .optimize = options.optimize,
                .imports = &.{
                    .{.name = "zigkm-app", .module = zigkmIos.module("zigkm-app")},
                    .{.name = "zigkm-math", .module = zigkmIos.module("zigkm-math")},
                    .{.name = "zigkm-platform", .module = zigkmIos.module("zigkm-platform")},
                    .{.name = "zigkm-serialize", .module = zigkmIos.module("zigkm-serialize")},
                    .{.name = "zigkm-stb", .module = zigkmIos.module("zigkm-stb")},
                },
            }),
        });
        const frameworkPath = try std.fmt.allocPrint(b.allocator, "{s}/System/Library/Frameworks", .{sdk});
        const includePath = try std.fmt.allocPrint(b.allocator, "{s}/usr/include", .{sdk});
        const libPath = try std.fmt.allocPrint(b.allocator, "{s}/usr/lib", .{sdk});
        lib.addFrameworkPath(.{.cwd_relative = frameworkPath});
        lib.addSystemIncludePath(.{.cwd_relative = includePath});
        lib.addLibraryPath(.{.cwd_relative = libPath});
        // // TODO not sure why I need this
        // lib.addCSourceFiles(.{
        //     .root = zigkmIos.path(""),
        //     .files = &[_][]const u8{
        //         "deps/stb/stb_rect_pack_impl.c",
        //         "deps/stb/stb_truetype_impl.c",
        //     },
        //     .flags = &[_][]const u8{"-std=c11"},
        // });
        // lib.bundle_compiler_rt = true;

        const appPath = try std.fmt.allocPrint(b.allocator, "ios/Payload/{s}.app", .{appName});
        const appInstallStep = b.addInstallArtifact(lib, .{
            .dest_dir = .{.override = .{.custom = "ios"}}
        });
        const installDataStep = b.addInstallDirectory(.{
            .source_dir = b.path("data"),
            .install_dir = .{.custom = appPath},
            .install_subdir = "",
        });
        const installDataIosStep = b.addInstallDirectory(.{
            .source_dir = b.path("data_ios"),
            .install_dir = .{.custom = appPath},
            .install_subdir = "",
        });
        buildAppStep.dependOn(&appInstallStep.step);
        buildAppStep.dependOn(&installDataStep.step);
        buildAppStep.dependOn(&installDataIosStep.step);

        packageAppStep.makeFn = stepPackageAppIos;
        runAppStep.makeFn = stepRunAppIos;
    }

    const androidPathSdk = b.option([]const u8, "android_path_sdk", "Absolute path to the Android SDK") orelse "";
    if (androidPathSdk.len > 0) {
        // App - Android
        const ao: AndroidOptions = .{
            .debug = options.dev,
            .pathJdk = b.option([]const u8, "android_path_jdk", "Absolute path to the JDK") orelse "",
            .pathSdk = androidPathSdk,
            .keystoreAlias = b.option([]const u8, "android_keystore_alias", "Android keystore alias") orelse "",
            .keystorePass = b.option([]const u8, "android_keystore_pass", "Android keystore password") orelse "",
            .deviceId = b.option([]const u8, "android_device_id", "Android device ID") orelse "",
        };
        android = ao;

        const targetAppAndroidQuery = std.Target.Query {
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .android,
            .android_api_level = ANDROID_SDK_MIN_VERSION,
        };
        const targetAppAndroid = b.resolveTargetQuery(targetAppAndroidQuery);
        const zigkmAndroid = b.dependency("zigkm", .{
            .target = targetAppAndroid,
            .optimize = options.optimize,
        });

        const lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "applib",
            .root_module = b.createModule(.{
                .root_source_file = b.path(options.srcApp),
                .target = targetAppAndroid,
                .optimize = options.optimize,
                .pic = true,
            }),
        });
        const installAssembly = b.addInstallBinFile(lib.getEmittedAsm(), "hello.s");
        b.getInstallStep().dependOn(&installAssembly.step);
        lib.root_module.addImport("zigkm-app", zigkmAndroid.module("zigkm-app"));
        lib.root_module.addImport("zigkm-lib", zigkmAndroid.module("zigkm-lib"));
        lib.root_module.addImport("zigkm-math", zigkmAndroid.module("zigkm-math"));
        lib.root_module.addImport("zigkm-platform", zigkmAndroid.module("zigkm-platform"));
        lib.root_module.addImport("zigkm-serialize", zigkmAndroid.module("zigkm-serialize"));
        lib.root_module.addImport("zigkm-stb", zigkmAndroid.module("zigkm-stb"));
        const ndkPath = try std.fs.path.join(b.allocator, &.{ao.pathSdk, "ndk", ANDROID_NDK_VERSION});
        const ndkSysroot = try std.fs.path.join(b.allocator, &.{ndkPath, "toolchains", "llvm", "prebuilt", "windows-x86_64", "sysroot", "usr"});
        lib.addLibraryPath(.{.cwd_relative = try std.fs.path.join(b.allocator, &.{ndkSysroot, "lib", "aarch64-linux-android", ANDROID_SDK_VERSION_STRING})});
        lib.linkSystemLibrary("android");
        lib.linkSystemLibrary("EGL");
        lib.linkSystemLibrary("GLESv2");
        lib.linkSystemLibrary("log");
        lib.setLibCFile(b.path("data_android/libc.txt"));
        lib.linkLibC();

        const appPath = "hello_world";
        const appInstallStep = b.addInstallArtifact(lib, .{
            .dest_dir = .{.override = .{.custom = appPath}}
        });
        const installAndroidShadersStep = b.addInstallDirectory(.{
            .source_dir = bZigkm.path("src/app/gles3/shaders"),
            .install_dir = .{.custom = appPath},
            .install_subdir = "data/shaders",
        });
        const installDataStep = b.addInstallDirectory(.{
            .source_dir = b.path("data"),
            .install_dir = .{.custom = appPath},
            .install_subdir = "data",
        });
        const installDataAndroidStep = b.addInstallDirectory(.{
            .source_dir = b.path("data_android"),
            .install_dir = .{.custom = appPath},
            .install_subdir = "data",
        });
        buildAppStep.dependOn(&appInstallStep.step);
        buildAppStep.dependOn(&installAndroidShadersStep.step);
        buildAppStep.dependOn(&installDataStep.step);
        buildAppStep.dependOn(&installDataAndroidStep.step);

        packageAppStep.makeFn = stepPackageAppAndroid;
        runAppStep.makeFn = stepRunAppAndroid;
    }
}

fn getIosSdkFlavor() []const u8
{
    const iosOptions = ios orelse return "iphoneos";
    return if (iosOptions.simulator) "iphonesimulator" else "iphoneos";
}

fn stepPackageAppAndroid(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void
{
    _ = options;
    // Great summary of the Android build process:
    // https://timeout.userpage.fu-berlin.de/apk-builder/en/index.php

    const ao = android orelse {
        std.log.err("Android build is disabled", .{});
        return;
    };

    std.log.info("Packaging app for Android", .{});
    const a = step.owner.allocator;

    const zigkm = step.owner.dependency("zigkm", .{});
    const bundletool = zigkm.path("deps/bundletool/bundletool-all-1.17.1.jar").getPath(step.owner);
    const jarAndroidxAnnotation = zigkm.path("deps/androidx/annotation-1.5.0.jar").getPath(step.owner);
    const jarAndroidxCore = zigkm.path("deps/androidx/core-1.13.1.jar").getPath(step.owner);

    const appAddressPath = try a.dupe(u8, appAddress);
    std.mem.replaceScalar(u8, appAddressPath, '.', '/');

    {
        var buildDir = try std.fs.cwd().openDir("zig-out", .{});
        defer buildDir.close();
        try buildDir.deleteTree("android");
        try buildDir.makeDir("android");
    }

    var androidDir = try std.fs.cwd().openDir("zig-out/android", .{});
    defer androidDir.close();

    try androidDir.makeDir("classes");
    try androidDir.makeDir("compile");
    try androidDir.makeDir("gen");
    try androidDir.makeDir("staging");

    const jdk_jar = try std.fs.path.join(a, &.{
        ao.pathJdk, "bin", "jar.exe"
    });
    const jdk_jarsigner = try std.fs.path.join(a, &.{
        ao.pathJdk, "bin", "jarsigner.exe"
    });
    const jdk_java = try std.fs.path.join(a, &.{
        ao.pathJdk, "bin", "java.exe"
    });
    const jdk_javac = try std.fs.path.join(a, &.{
        ao.pathJdk, "bin", "javac.exe"
    });

    const sdk_aapt2 = try std.fs.path.join(a, &.{
        ao.pathSdk, "build-tools", ANDROID_SDK_BUILDTOOLS_VERSION, "aapt2.exe"
    });
    const sdk_androidJar = try std.fs.path.join(a, &.{
        ao.pathSdk, "platforms", "android-" ++ ANDROID_SDK_VERSION_STRING, "android.jar",
    });
    const sdk_d8 = try std.fs.path.join(a, &.{
        ao.pathSdk, "build-tools", ANDROID_SDK_BUILDTOOLS_VERSION, "d8.bat",
    });
    const sdk_zipalign = try std.fs.path.join(a, &.{
        ao.pathSdk, "build-tools", ANDROID_SDK_BUILDTOOLS_VERSION, "zipalign.exe",
    });

    // aapt2 compile
    if (!utils.execCheckTerm(&.{
        sdk_aapt2, "compile", "--dir", "data_android/res", "-o", "zig-out/android/compile"
    }, a)) {
        return error.appt2Compile;
    }

    // aapt2 link
    var aapt2LinkArgs = std.ArrayList([]const u8){};
    defer aapt2LinkArgs.deinit(a);
    try aapt2LinkArgs.appendSlice(a, &.{
        sdk_aapt2, "link",
        "--proto-format",
        "--auto-add-overlay",
        "--min-sdk-version", std.fmt.comptimePrint("{}", .{ANDROID_SDK_MIN_VERSION}),
        "--target-sdk-version", ANDROID_SDK_VERSION_STRING,
        "-I", sdk_androidJar,
        "--manifest", "data_android/AndroidManifest.xml",
        "-o", "zig-out/android/app-temp.apk",
        "--java", "zig-out/android/gen"
    });
    if (ao.debug) {
        try aapt2LinkArgs.append(a, "--debug-mode");
    }
    const flatFiles = try utils.listDirFiles("zig-out/android/compile", a);
    try aapt2LinkArgs.appendSlice(a, flatFiles.items);
    if (!utils.execCheckTerm(aapt2LinkArgs.items, a)) {
        return error.aapt2Link;
    }

    // javac
    const jars = try std.fmt.allocPrint(a, "{s};{s};{s}", .{sdk_androidJar, jarAndroidxAnnotation, jarAndroidxCore});
    const pathR = try std.fmt.allocPrint(a, "zig-out/android/gen/{s}/R.java", .{appAddressPath});
    const pathMainActivity = zigkm.path("src/app/android/MainActivity.java").getPath(step.owner);
    if (!utils.execCheckTerm(&.{
        jdk_javac,
        "-classpath", jars,
        // "-source", "1.8", "-target", "1.8",
        "-d", "zig-out/android/classes",
        pathR, pathMainActivity,
    }, a)) {
        return error.javac;
    }

    // d8
    var d8Args = std.ArrayList([]const u8){};
    defer d8Args.deinit(a);
    try d8Args.appendSlice(a, &.{
        sdk_d8,
        if (ao.debug) "--debug" else "--release",
        "--lib", sdk_androidJar,
        "--output", "zig-out/android/classes",
        jarAndroidxAnnotation, jarAndroidxCore,
    });
    const classFilesDir = try std.fmt.allocPrint(a, "zig-out/android/classes/{s}", .{appAddressPath});
    const classFilesApp = try utils.listDirFiles(classFilesDir, a);
    const classFilesZigkm = try utils.listDirFiles("zig-out/android/classes/com/kapricornmedia/zigkm", a);
    try d8Args.appendSlice(a, classFilesApp.items);
    try d8Args.appendSlice(a, classFilesZigkm.items);
    if (!utils.execCheckTerm(d8Args.items, a)) {
        return error.d8;
    }

    // unzip
    if (!utils.execCheckTermWd(&.{
        jdk_jar, "-xf", "../app-temp.apk"
    }, "zig-out/android/staging", a)) {
        return error.unzip;
    }

    // pack stuff for zip
    try androidDir.makeDir("staging/manifest");
    try androidDir.rename("staging/AndroidManifest.xml", "staging/manifest/AndroidManifest.xml");
    try androidDir.makeDir("staging/dex");
    try androidDir.rename("classes/classes.dex", "staging/dex/classes.dex");
    try androidDir.makePath("staging/lib/arm64-v8a");
    try std.fs.Dir.copyFile(std.fs.cwd(), "zig-out/hello_world/libapplib.so", androidDir, "staging/lib/arm64-v8a/libapplib.so", .{});
    try copyDir("zig-out/hello_world/data", "zig-out/android/staging/assets", a);

    // zip
    if (!utils.execCheckTermWd(&.{
        jdk_jar, "-cfM", "../base.zip", "."
    }, "zig-out/android/staging", a)) {
        return error.zip;
    }

    // bundletool build-bundle
    if (!utils.execCheckTerm(&.{
        jdk_java, "-jar", bundletool, "build-bundle",
        "--modules", "zig-out/android/base.zip",
        "--output", "zig-out/android/bundle.aab.unaligned"
    }, a)) {
        return error.bundletoolBuildBundle;
    }

    // zipalign
    if (!utils.execCheckTerm(&.{
        sdk_zipalign, "-f", "4", "zig-out/android/bundle.aab.unaligned", "zig-out/android/bundle.aab"
    }, a)) {
        return error.zipalign;
    }

    // jarsigner
    if (!utils.execCheckTerm(&.{
        jdk_jarsigner,
        "-keystore", if (ao.debug) "data_android/debug.keystore" else "keys/release.keystore",
        "-storepass", if (ao.debug) "android" else ao.keystorePass,
        "zig-out/android/bundle.aab",
        if (ao.debug) "androiddebugkey" else ao.keystoreAlias
    }, a)) {
        return error.jarsigner;
    }

    const pass = if (ao.debug) "android" else ao.keystorePass;
    const alias = if (ao.debug) "androiddebugkey" else ao.keystoreAlias;
    const ksPassArg = try std.fmt.allocPrint(a, "--ks-pass=pass:{s}", .{pass});
    const ksAliasArg = try std.fmt.allocPrint(a, "--ks-key-alias={s}", .{alias});
    const keyPassArg = try std.fmt.allocPrint(a, "--key-pass=pass:{s}", .{pass});
    const apksPath = try std.fmt.allocPrint(a, "zig-out/android/{s}.apks", .{appName});
    // bundletool build-apks
    if (!utils.execCheckTerm(&.{
        jdk_java, "-jar", bundletool, "build-apks",
        "--bundle", "zig-out/android/bundle.aab",
        "--output", apksPath,
        if (ao.debug) "--ks=data_android/debug.keystore" else "--ks=keys/release.keystore",
        ksPassArg, ksAliasArg, keyPassArg
    }, a)) {
        return error.bundletoolBuildApks;
    }
}

fn stepRunAppAndroid(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void
{
    _ = options;

    const ao = android orelse {
        std.log.err("Android build is disabled", .{});
        return;
    };

    std.log.info("Running app for Android", .{});
    const a = step.owner.allocator;

    const jdk_java = try std.fs.path.join(a, &.{
        ao.pathJdk, "bin", "java.exe"
    });

    const sdk_adb = try std.fs.path.join(a, &.{
        ao.pathSdk, "platform-tools", "adb.exe",
    });

    const zigkm = step.owner.dependency("zigkm", .{});
    const bundletool = zigkm.path("deps/bundletool/bundletool-all-1.17.1.jar").getPath(step.owner);

    const apksPath = try std.fmt.allocPrint(a, "zig-out/android/{s}.apks", .{appName});
    if (!utils.execCheckTerm(&.{
        jdk_java, "-jar", bundletool, "install-apks",
        if (ao.deviceId.len > 0) "--device-id" else "", ao.deviceId,
        "--adb", sdk_adb,
        "--apks", apksPath,
    }, a)) {
        return error.bundletoolInstallApks;
    }

    const startName = try std.fmt.allocPrint(a, "{s}/com.kapricornmedia.zigkm.MainActivity", .{appAddress});
    if (!utils.execCheckTerm(&.{
        sdk_adb,
        if (ao.deviceId.len > 0) "-s" else "", ao.deviceId,
        "shell", "am", "start", "-n", startName,
    }, a)) {
        return error.adbShell;
    }
}

fn stepPackageAppIos(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void
{
    _ = options;

    const iosOptions = ios orelse {
        std.log.err("iOS build is disabled", .{});
        return;
    };

    std.log.info("Packaging app for iOS", .{});
    const a = step.owner.allocator;

    const appBuildDirFull = "zig-out/ios";
    const appPathFull = try std.fmt.allocPrint(a, "zig-out/ios/Payload/{s}.app", .{appName});
    const iosSdkFlavor = getIosSdkFlavor();

    // Compile native code (Objective-C, maybe we can do Swift in the future)
    std.log.info("Compiling native code", .{});
    if (utils.execCheckTermStdout(&.{
        "./scripts/ios/compile_native.sh", // TODO move to zigkm-common? exe permissions are weird
        basePath, iosSdkFlavor, iosMinVersionString, appPathFull, appBuildDirFull
    }, a) == null) {
        return error.nativeCompile;
    }

    // Compile and link metal shaders
    std.log.info("Compiling shaders", .{});
    const metalTarget = if (iosOptions.simulator) "air64-apple-ios" ++ iosMinVersionString ++ "-simulator" else "air64-apple-ios" ++ iosMinVersionString;
    if (utils.execCheckTermStdout(&.{
        "xcrun", "-sdk", iosSdkFlavor,
        "metal",
        "-Werror",
        "-target", metalTarget,
        "-std=ios-metal" ++ metalMinVersionString,
        "-mios-version-min=" ++ iosMinVersionString,
        "-c", try std.mem.concat(a, u8, &[_][]const u8 {basePath, "/src/app/ios/shaders.metal"}),
        "-o", appBuildDirFull ++ "/shaders.air"
    }, a) == null) {
        return error.metalCompile;
    }
    std.log.info("Linking shaders", .{});
    const metallibPath = try std.fmt.allocPrint(a, "{s}/default.metallib", .{appPathFull});
    if (utils.execCheckTermStdout(&.{
        "xcrun", "-sdk", iosSdkFlavor,
        "metallib",
        appBuildDirFull ++ "/shaders.air",
        "-o", metallibPath
    }, a) == null) {
        return error.metalLink;
    }

    if (!iosOptions.simulator) {
        std.log.info("Running codesign", .{});
        const entitlementsPath = try std.fmt.allocPrint(a, "scripts/ios/{s}.entitlements", .{appName});
        if (utils.execCheckTermStdout(&.{
            "codesign", "-s", iosOptions.certificate, "--entitlements", entitlementsPath, appPathFull
        }, a) == null) {
            return error.codesign;
        }

        std.log.info("zipping .ipa archive", .{});
        if (utils.execCheckTermStdoutWd(&.{
            "zip", "-r", "update.ipa", "Payload"
        }, appBuildDirFull, a) == null) {
            return error.ipaZip;
        }
    }
}

fn stepRunAppIos(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void
{
    _ = options;

    const iosOptions = ios orelse {
        std.log.err("iOS build is disabled", .{});
        return;
    };

    std.log.info("Running app for iOS", .{});
    const a = step.owner.allocator;

    const appBuildDirFull = "zig-out/ios";
    const appPathFull = try std.fmt.allocPrint(a, "zig-out/ios/Payload/{s}.app", .{appName});

    if (iosOptions.simulator) {
        if (utils.execCheckTermStdout(&.{
            "xcrun", "simctl", "install", "booted", appPathFull
        }, a) == null) {
            return error.xcrunInstallError;
        }

        if (utils.execCheckTermStdout(&.{
            "xcrun", "simctl", "launch", "booted", appAddress
        }, a) == null) {
            return error.xcrunLaunchError;
        }
    } else {
        if (utils.execCheckTermStdout(&.{
            "/opt/homebrew/bin/ideviceinstaller", "-i", appBuildDirFull ++ "/update.ipa"
        }, a) == null) {
            return error.install;
        }
    }
}

fn addSdkPaths(b: *std.Build, compileStep: *std.Build.Step.Compile, target: std.Target) !void
{
    const sdk = std.zig.system.darwin.getSdk(b.allocator, &target) orelse {
        std.log.warn("No iOS SDK found, skipping", .{});
        return;
    };
    std.log.info("SDK path: {s}", .{sdk});
    if (b.sysroot == null) {
        // b.sysroot = sdk;
    }

    // const sdkPath = b.sysroot.?;
    const frameworkPath = try std.fmt.allocPrint(b.allocator, "{s}/System/Library/Frameworks", .{sdk});
    const includePath = try std.fmt.allocPrint(b.allocator, "{s}/usr/include", .{sdk});
    const libPath = try std.fmt.allocPrint(b.allocator, "{s}/usr/lib", .{sdk});

    compileStep.addFrameworkPath(.{.cwd_relative = frameworkPath});
    compileStep.addSystemIncludePath(.{.cwd_relative = includePath});
    compileStep.addLibraryPath(.{.cwd_relative = libPath});
}

fn stepPackageServer(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void
{
    _ = options;

    std.log.info("Generating bigdata file archive...", .{});
    const allocator = step.owner.allocator;

    if (utils.execCheckTermStdout(&.{
        "./zig-out/tools/genbigdata", "./zig-out/server-temp/static", "./zig-out/server/static.bigdata",
    }, allocator) == null) {
        return error.genbigdata;
    }
}

fn copyDir(srcPath: []const u8, dstPath: []const u8, allocator: std.mem.Allocator) !void
{
    const cwd = std.fs.cwd();
    try cwd.deleteTree(dstPath);
    try cwd.makePath(dstPath);

    var srcDir = try cwd.openDir(srcPath, .{.iterate = true});
    defer srcDir.close();
    var dstDir = try cwd.openDir(dstPath, .{});
    defer dstDir.close();

    var srcWalker = try srcDir.walk(allocator);
    while (try srcWalker.next()) |entry| {
        switch (entry.kind) {
            .file => {
                try std.fs.Dir.copyFile(srcDir, entry.path, dstDir, entry.path, .{});
            },
            .directory => {
                try dstDir.makeDir(entry.path);
            },
            else => {
                return error.UnhandledEntryType;
            },
        }
    }
}
