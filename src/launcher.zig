const std = @import("std");
const builtin = @import("builtin");
const A = std.mem.Allocator;

const w = @cImport({
    @cInclude("Windows.h");
});

const launcher_defs = @import("zigkm").launcher_defs;
const memory = @import("zigkm").memory;
const version = @import("zigkm").version;

const rlz = @import("zigkm-raylib");
const rl = rlz.c;

const config = @import("config");

pub const MEMORY_TEMP = 256 * 1024 * 1024;

const ClientLoadError = error {
    Missing,
    Other,
};

const DEFAULT_HEIGHT = 1080;
// const DEFAULT_HEIGHT = 1080 * 1.5;
const DEFAULT_WIDTH = DEFAULT_HEIGHT * 16.0 / 9.0;

const Client = struct {
    version: version.Version,
    loadedNs: i128,
    lib: std.DynLib,
    clientMain: *const launcher_defs.ClientMainFn,
    serverAddress: ?std.net.Address,

    fn close(self: *Client) void
    {
        self.lib.close();
    }
};

const LoadMode = enum(u8) {
    idle,
    load,
};

const LoadStep = enum(u8) {
    start,
    download,
    launch,
    err,
};

const StartMode = enum {
    offline,
    online,
    online_only,
};

const State = struct {
    exit: std.atomic.Value(bool),
    loadMode: std.atomic.Value(LoadMode),
    loadStep: LoadStep,
    startMode: StartMode,
    client: ?Client,
    loadThread: std.Thread,

    fn requestLoad(self: *State) void
    {
        self.loadStep = .start;
        self.loadMode.store(.load, .release);
    }
};

fn loadClient(v: version.Version) ClientLoadError!Client
{
    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    // TODO linux (not DLL)
    const libPath = std.fmt.allocPrint(a, "{s}/{f}/client.dll", .{config.DIR_CLIENTS, v}) catch return error.Other;
    std.log.info("Loading game dynamic library at {s}", .{libPath});
    var lib = std.DynLib.open(libPath) catch |err| switch (err) {
        error.FileNotFound => return error.Missing,
        else => return error.Other,
    };
    return .{
        .version = v,
        .loadedNs = std.time.nanoTimestamp(),
        .lib = lib,
        .clientMain = lib.lookup(*const launcher_defs.ClientMainFn, "clientMain") orelse return error.Other,
        .serverAddress = null,
    };
}

fn getSortedVersions(a: A) ![]version.Version
{
    var versions: std.ArrayList(version.Version) = .{};

    var dir = try std.fs.cwd().openDir(config.DIR_CLIENTS, .{.iterate = true});
    defer dir.close();

    var dirIt = dir.iterate();
    while (try dirIt.next()) |client| {
        if (client.kind != .directory) continue;

        const v = version.Version.parse(client.name) orelse continue;
        try versions.append(a, v);
    }

    const T = struct {
        fn lessThan(_: void, v1: version.Version, v2: version.Version) bool
        {
            return std.SemanticVersion.order(v1.version, v2.version) == .lt;
        }
    };
    std.sort.insertion(version.Version, versions.items, {}, T.lessThan);
    return versions.items;
}

fn loadOnlineClient(step: *LoadStep) !Client
{
    var ta = memory.getTempArena(null);
    defer ta.reset();
    const a = ta.allocator();

    var maybeAddr: ?std.net.Address = null;
    const addressList = try std.net.getAddressList(a, config.URI_SERVER.host.?.percent_encoded, config.URI_SERVER.port.?);
    for (addressList.addrs) |addr| {
        if (addr.any.family == std.posix.AF.INET) {
            std.log.info("{f}", .{addr});
            maybeAddr = addr;
        }
    }
    const addr = maybeAddr orelse return error.DNS;

    var httpClient = std.http.Client {.allocator = a};
    defer httpClient.deinit();

    var versionUri = config.URI_SERVER;
    versionUri.path = .{.percent_encoded = "/version"};
    var versionWriter: std.Io.Writer.Allocating = .init(a);
    const versionResult = try httpClient.fetch(.{
        .response_writer = &versionWriter.writer,
        .location = .{.uri = versionUri},
    });
    if (versionResult.status != .ok) {
        return error.VersionRequest;
    }
    const versionBytes = versionWriter.writer.buffer[0..versionWriter.writer.end];
    const v = version.Version.parse(versionBytes) orelse return error.BadVersion;
    std.log.info("Server says load v={f}", .{v});

    var client: Client = blk: {
        if (loadClient(v)) |c| {
            break :blk c;
        } else |err| switch (err) {
            error.Missing => {
                {
                    step.* = .download;

                    const dirPath = try std.fmt.allocPrint(a, "{s}/{f}", .{config.DIR_CLIENTS, v});
                    try std.fs.cwd().makePath(dirPath);
                    var outDir = try std.fs.cwd().openDir(dirPath, .{});
                    defer outDir.close();

                    var downloadUri = config.URI_SERVER;
                    downloadUri.path = .{.percent_encoded = try std.fmt.allocPrint(a, "/download?version={f}", .{v})};
                    var downloadWriter = std.Io.Writer.Allocating.init(a);
                    const downloadResult = try httpClient.fetch(.{
                        .response_writer = &downloadWriter.writer,
                        .location = .{.uri = downloadUri},
                    });
                    if (downloadResult.status != .ok) {
                        std.log.err("download status={}", .{downloadResult.status});
                        return error.DownloadRequest;
                    }
                    std.log.info("DLDLDL {}", .{downloadWriter.writer.end});

                    var tarReader = std.Io.Reader.fixed(downloadWriter.writer.buffer[0..downloadWriter.writer.end]);
                    std.tar.pipeToFileSystem(outDir, &tarReader, .{}) catch |err2| {
                        std.log.err("pipeToFileSystem err={}", .{err2});
                        return err2;
                    };
                }

                step.* = .launch;
                break :blk try loadClient(v);
            },
            error.Other => {
                return error.LoadClient;
            },
        }
    };

    var connectUri = config.URI_SERVER;
    connectUri.path = .{.percent_encoded = "/connect"};
    var connectWriter: std.Io.Writer.Allocating = .init(a);
    const connectResult = try httpClient.fetch(.{
        .response_writer = &connectWriter.writer,
        .location = .{.uri = connectUri},
    });
    if (connectResult.status != .ok) {
        return error.VersionRequest;
    }
    const connectBytes = connectWriter.writer.buffer[0..connectWriter.writer.end];
    var connectReader = std.Io.Reader.fixed(connectBytes);
    const gameServerPort = try connectReader.takeInt(u16, .big);
    std.log.info("Game server on port={}", .{gameServerPort});

    var gameServerAddr = addr;
    gameServerAddr.in.sa.port = std.mem.nativeToBig(u16, gameServerPort);
    client.serverAddress = gameServerAddr;
    std.log.info("{f}", .{gameServerAddr});
    return client;
}

fn loadThreadEntry(state: *State) void
{
    while (!state.exit.load(.acquire)) {
        const loadMode = state.loadMode.load(.acquire);
        switch (loadMode) {
            .idle => {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            },
            .load => {
                var ta = memory.getTempArena(null);
                defer ta.reset();
                const a = ta.allocator();

                if (state.startMode == .online or state.startMode == .online_only) {
                    if (loadOnlineClient(&state.loadStep)) |c| {
                        state.client = c;
                        state.loadMode.store(.idle, .release);
                        std.log.info("Loaded online client", .{});
                    } else |err| {
                        std.log.err("Online failed err={}", .{err});
                        switch (state.startMode) {
                            .online => {
                                state.startMode = .offline;
                            },
                            .offline => {
                                state.startMode = .online_only;
                            },
                            .online_only => {
                                state.loadStep = .err;
                                state.loadMode.store(.idle, .release);
                            },
                        }
                    }
                } else {
                    if (getSortedVersions(a)) |versions| {
                        if (versions.len == 0) {
                            state.startMode = .online_only;
                        } else {
                            if (loadClient(versions[0])) |c| {
                                state.client = c;
                                state.loadMode.store(.idle, .release);
                                std.log.info("Loaded offline client", .{});
                            } else |err| {
                                std.log.err("Failed to load err={}", .{err});
                                state.exit.store(true, .release);
                            }
                        }
                    } else |err| {
                        std.log.err("Failed to get versions err={}", .{err});
                        state.exit.store(true, .release);
                    }
                }
            },
        }
    }
}

pub fn main() !void
{
    var state: State = .{
        .exit = .init(false),
        .loadMode = .init(.idle),
        .loadStep = .start,
        .startMode = .offline,
        .client = null,
        .loadThread = undefined,
    };

    state.loadThread = try .spawn(.{}, loadThreadEntry, .{&state});
    defer state.loadThread.join();

    while (!state.exit.load(.acquire)) {
        if (state.loadMode.load(.acquire) != .load and state.client != null) {
            const c = &(state.client orelse unreachable);

            var ta = memory.getTempArena(null);
            defer ta.reset();
            const a = ta.allocator();

            const dataDir = std.fmt.allocPrint(a, "{s}/{f}", .{config.DIR_CLIENTS, c.version}) catch continue;
            var args: launcher_defs.ClientMainArgs = .{
                .dataDirLen = @intCast(dataDir.len),
                .dataDirPtr = dataDir.ptr,
                .hasServerAddress = false,
                .serverAddress = undefined,
            };
            if (c.serverAddress) |addr| {
                args.hasServerAddress = true;
                args.serverAddress = addr;
            }
            const result = c.clientMain(&args);
            switch (result) {
                .exit_to_desktop => {
                    state.exit.store(true, .release);
                },
                .exit_to_launcher => {
                    c.close();
                    state.client = null;
                },
                .go_multiplayer => {
                    c.close();
                    state.client = null;
                    state.startMode = .online;
                    state.requestLoad();
                },
                .err => {
                    // TODO ???
                    std.log.err("client error", .{});
                    state.exit.store(true, .release);
                },
            }
        } else {
            rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
            rl.InitWindow(DEFAULT_WIDTH, DEFAULT_HEIGHT, "Photon Cycles");
            defer rl.CloseWindow();
            rl.SetExitKey(rl.KEY_DELETE);

            while (!state.exit.load(.acquire) and !rl.WindowShouldClose()) {
                var ta = memory.getTempArena(null);
                defer ta.reset();
                const a = ta.allocator();

                rl.BeginDrawing();
                defer rl.EndDrawing();

                rl.ClearBackground(rl.BLACK);

                const loadingText = std.fmt.allocPrintSentinel(a, "Loading client mode={}", .{state.startMode}, 0) catch "Loading client";
                rl.DrawText(loadingText, 100, 100, 48, rl.WHITE);

                switch (state.loadMode.load(.acquire)) {
                    .idle => {
                        if (state.client) |_| {
                            std.log.info("Loaded client, starting...", .{});
                            break;
                        } else {
                            if (state.loadStep == .err) {
                                rl.DrawText("ERROR!", 100, 200, 24, rl.WHITE);
                            } else {
                                state.requestLoad();
                            }
                        }
                    },
                    .load => {
                        switch (state.loadStep) {
                            .start => {
                                rl.DrawText("Starting...", 100, 200, 24, rl.WHITE);
                            },
                            .download => {
                                rl.DrawText("Downloading...", 100, 200, 24, rl.WHITE);
                            },
                            .launch => {
                                rl.DrawText("Launching...", 100, 200, 24, rl.WHITE);
                            },
                            .err => {
                                rl.DrawText("ERROR!", 100, 200, 24, rl.WHITE);
                            },
                        }
                    },
                }

            }

            if (rl.WindowShouldClose()) {
                state.exit.store(true, .release);
            }
        }
    }
}
