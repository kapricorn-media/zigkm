const std = @import("std");

const google = @import("zigkm-google");
const httpz = @import("httpz");
const platform = @import("zigkm-platform");
const serialize = @import("zigkm-serialize");

const A = std.mem.Allocator;
const OOM = A.Error;

pub const PwHashError = error {PwHashError};
pub const LoginError = OOM || error {
    WrongPassword,
};
pub const RegisterError = OOM || PwHashError;
pub const VerifyError = OOM || PwHashError || error {
    NoVerifyData,
    BadVerify,
};

pub const UserId = u128;
pub const SessionId = u64;
pub const VerifyId = u64;

const pwHashParams = std.crypto.pwhash.argon2.Params { .t = 50, .m = 4096, .p = 2 };

pub const UserRecord = struct {
    id: UserId,
    user: []const u8,
    email: ?[]const u8,
    emailVerified: bool,
    passwordHash: [128]u8,
};

pub const Session = struct {
    userId: UserId,
    expirationUtcS: i64,
};

pub const VerifyData = struct {
    verifyIdHash: [128]u8,
    expirationUtcS: i64,
};

pub const RegisterResult = struct {
    record: UserRecord,
    verifyId: ?VerifyId,
};

pub const State = struct {
    lock: std.Thread.RwLock,
    sessions: SessionMap,
    verifies: VerifyMap,
    prng: std.Random.DefaultPrng,
    csprng: std.Random.DefaultCsprng,
    sessionDurationS: i64,
    emailVerifyExpirationS: i64,
    savePath: []const u8,

    const Self = @This();
    const SERIALIZE_VERSION = 0;
    const SessionMap = std.AutoArrayHashMapUnmanaged(SessionId, Session);
    const VerifyMap = std.AutoArrayHashMapUnmanaged(UserId, VerifyData);

    const SerialSession = struct {
        k: SessionId,
        v: Session,
    };
    const SerialVerify = struct {
        k: UserId,
        v: VerifyData,
    };

    const Serial = struct {
        sessions: []SerialSession,
        verifies: []SerialVerify,
    };

    pub fn init(sessionDurationS: i64, emailVerifyExpirationS: i64, savePath: []const u8) Self
    {
        const seedPrng = std.crypto.random.int(u64);
        var seedCsprng: [32]u8 = undefined;
        std.crypto.random.bytes(&seedCsprng);

        return .{
            .sessions = .{},
            .verifies = .{},
            .prng = .init(seedPrng),
            .csprng = .init(seedCsprng),
            .lock = .{},
            .sessionDurationS = sessionDurationS,
            .emailVerifyExpirationS = emailVerifyExpirationS,
            .savePath = savePath,
        };
    }

    pub fn deinit(self: *Self, aPerm: A) void
    {
        self.sessions.deinit(aPerm);
        self.verifies.deinit(aPerm);
    }

    pub fn load(self: *Self, aPerm: A, a: A) !void
    {
        self.lock.lock();
        defer self.lock.unlock();

        var file = try std.fs.cwd().openFile(self.savePath, .{});
        defer file.close();
        var fileBuf: [4096]u8 = undefined;
        var fileReader = file.reader(&fileBuf);
        var jsonReader = std.json.Reader.init(a, &fileReader.interface);
        const parsed = try std.json.parseFromTokenSource(Serial, a, &jsonReader, .{});

        for (parsed.value.sessions) |s| {
            try self.sessions.put(aPerm, s.k, s.v);
        }
    }

    pub fn save(self: *Self, a: A) !void
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var sessions = std.ArrayList(SerialSession){};
        var sessionsIt = self.sessions.iterator();
        while (sessionsIt.next()) |kv| {
            try sessions.append(a, .{
                .k = kv.key_ptr.*,
                .v = kv.value_ptr.*,
            });
        }

        var verifies = std.ArrayList(SerialVerify){};
        var verifiesIt = self.verifies.iterator();
        while (verifiesIt.next()) |kv| {
            try verifies.append(a, .{
                .k = kv.key_ptr.*,
                .v = kv.value_ptr.*,
            });
        }

        var file = try std.fs.cwd().createFile(self.savePath, .{});
        defer file.close();
        var fileBuf: [4096]u8 = undefined;
        var fileWriter = file.writer(&fileBuf);
        try std.json.Stringify.value(Serial {
            .sessions = sessions.items,
            .verifies = verifies.items,
        }, .{.whitespace = .indent_1}, &fileWriter.interface);
        try fileWriter.end();
    }

    pub fn getSession(self: *Self, sessionId: SessionId) ?Session
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        const sessionData = self.sessions.get(sessionId) orelse return null;
        const now = std.time.timestamp();
        if (now >= sessionData.expirationUtcS) {
            self.lock.unlockShared();
            defer self.lock.lockShared();
            self.lock.lock();
            defer self.lock.unlock();

            if (!self.sessions.swapRemove(sessionId)) {
                std.log.err("Failed to clear session", .{});
            }
            std.log.info("SESSION EXPIRED", .{});
            return null;
        }
        return sessionData;
    }

    pub fn login(self: *Self, record: UserRecord, password: []const u8, aPerm: A, a: A) LoginError!SessionId
    {
        self.lock.lock();
        defer self.lock.unlock();

        const pwHash = std.mem.sliceTo(&record.passwordHash, 0);
        std.crypto.pwhash.argon2.strVerify(pwHash, password, .{.allocator = a}) catch return error.WrongPassword;
        const sessionId = self.csprng.random().int(SessionId);
        try self.sessions.put(aPerm, sessionId, .{
            .userId = record.id,
            .expirationUtcS = std.time.timestamp() + self.sessionDurationS,
        });
        std.log.info("LOGGED IN {} ({s})", .{record.id, record.user});
        return sessionId;
    }

    pub fn logoff(self: *Self, sessionId: SessionId) void
    {
        self.lock.lock();
        defer self.lock.unlock();

        const sessionData = self.sessions.get(sessionId) orelse {
            std.log.warn("Logoff with no session", .{});
            return;
        };
        if (!self.sessions.swapRemove(sessionId)) {
            std.log.warn("Failed to clear session {}", .{sessionId});
        }
        std.log.info("LOGGED OFF {}", .{sessionData.userId});
    }

    pub fn register(self: *Self, user: []const u8, email: ?[]const u8, password: []const u8, aPerm: A, a: A) RegisterError!RegisterResult
    {
        self.lock.lock();
        defer self.lock.unlock();

        const userId = self.prng.random().int(UserId);
        var result = RegisterResult{
            .record = .{
                .id = userId,
                .user = user,
                .email = email,
                .emailVerified = false,
                .passwordHash = undefined,
            },
            .verifyId = null,
        };
        @memset(&result.record.passwordHash, 0);
        _ = std.crypto.pwhash.argon2.strHash(password, .{
            .allocator = a,
            .params = pwHashParams,
        }, &result.record.passwordHash) catch return error.PwHashError;
        std.log.info("REGISTERED {s}", .{user});

        if (email) |e| {
            const verifyId = self.csprng.random().int(VerifyId);
            result.verifyId = verifyId;
            const verifyResult = try self.verifies.getOrPut(aPerm, userId);
            verifyResult.value_ptr.* = .{
                .verifyIdHash = undefined,
                .expirationUtcS = std.time.timestamp() + self.emailVerifyExpirationS,
            };
            @memset(&verifyResult.value_ptr.*.verifyIdHash, 0);
            _ = std.crypto.pwhash.argon2.strHash(&std.mem.toBytes(verifyId), .{
                .allocator = aPerm,
                .params = pwHashParams,
            }, &verifyResult.value_ptr.*.verifyIdHash) catch return error.PwHashError;

            std.log.info("VERIFICATION SENT {} ({s})", .{userId, e});
        }
        return result;
    }

    pub fn unregister(self: *Self, userId: UserId) void
    {
        self.lock.lock();
        defer self.lock.unlock();

        while (true) {
            var done = true;
            var it = self.sessions.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.userId == userId) {
                    const sessionId = entry.key_ptr.*;
                    if (!self.sessions.swapRemove(sessionId)) {
                        std.log.err("Failed to clear session {} for user ID {}", .{sessionId, userId});
                    }
                    done = false;
                    break;
                }
            }
            if (done) {
                break;
            }
        }

        std.log.info("UNREGISTERED {}", .{userId});
    }

    pub fn verify(self: *Self, userId: UserId, verifyId: u64, a: A) !void
    {
        self.lock.lock();
        defer self.lock.unlock();

        const verifyData = self.verifies.get(userId) orelse return error.NoVerifyData;
        const verifyIdBytes = std.mem.toBytes(verifyId);
        std.crypto.pwhash.argon2.strVerify(&verifyData.verifyIdHash, &verifyIdBytes, .{.allocator = a}) catch return error.BadVerify;
        _ = self.verifies.swapRemove(userId);

        std.log.info("VERIFIED {}", .{userId});
    }
};

pub fn parseNewlineStrings(comptime T: type, data: []const u8, allowExtra: bool) !T
{
    var result: T = undefined;
    var splitIt = std.mem.splitScalar(u8, data, '\n');

    const typeInfo = @typeInfo(T);
    inline for (typeInfo.@"struct".fields) |f| {
        @field(result, f.name) = splitIt.next() orelse return error.MissingField;
    }
    if (!allowExtra and splitIt.next() != null) {
        return error.ExtraField;
    }
    return result;
}

pub fn writeNewlineStrings(comptime T: type, t: T, allocator: A) ![]const u8
{
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const typeInfo = @typeInfo(T);
    inline for (typeInfo.Struct.fields, 0..) |f, i| {
        if (i != 0) {
            try buf.append('\n');
        }
        try buf.appendSlice(@field(t, f.name));
    }
    return buf.toOwnedSlice();
}

pub fn getSessionId(req: *httpz.Request) ?u64
{
    // TODO customize cookie? idk, global constant is probably fine
    const sessionIdStr = req.header(platform.SESSION_ID_COOKIE) orelse return null;
    const sessionId = std.fmt.parseUnsigned(u64, sessionIdStr, 16) catch return null;
    return sessionId;
}

pub const Endpoints = struct {
    login: []const u8,
    logout: []const u8,
    register: []const u8,
    unregister: []const u8,
    verify: []const u8,
};

const EndpointResult = union(enum) {
    none: void,
    register: struct {
        result: RegisterResult,
        reqBody: []const u8,
    },
    unregister: UserId,
};

pub fn authEndpoints(
    comptime T: type,
    rows: []const T,
    req: *httpz.Request,
    res: *httpz.Response,
    state: *State,
    endpoints: Endpoints,
    aPerm: A, a: A) !EndpointResult
{
    const maybeSessionId = getSessionId(req);
    const maybeSession = if (maybeSessionId) |sid| state.getSession(sid) else null;

    if (req.method == .GET) {
        if (std.mem.eql(u8, req.url.path, endpoints.verify)) {
            const queryParams = try req.query();
            const userIdString = queryParams.get("userId") orelse {
                std.log.err("Verify missing userId", .{});
                res.status = 400;
                return .{.none = {}};
            };
            const userId = std.fmt.parseUnsigned(UserId, userIdString, 16) catch {
                std.log.err("Verify invalid userId", .{});
                res.status = 400;
                return .{.none = {}};
            };
            const verifyIdString = queryParams.get("verifyId") orelse {
                std.log.err("Verify missing verifyId", .{});
                res.status = 400;
                return .{.none = {}};
            };
            const verifyId = std.fmt.parseUnsigned(VerifyId, verifyIdString, 16) catch {
                std.log.err("Verify invalid verifyId", .{});
                res.status = 400;
                return .{.none = {}};
            };

            state.verify(userId, verifyId, a) catch |err| {
                std.log.err("Verify failed {}", .{err});
                res.status = 400;
                return .{.none = {}};
            };
            state.save(a) catch |err| {
                std.log.err("auth state save err={}", .{err});
            };

            res.status = 302;
            res.header("Location", "/verified");
        }
    } else if (req.method == .POST) {
        if (std.mem.eql(u8, req.url.path, endpoints.login)) {
            const body = req.body() orelse {
                res.status = 400;
                return .{.none = {}};
            };
            const LoginData = struct {
                user: []const u8,
                password: []const u8,
            };
            const loginData = parseNewlineStrings(LoginData, body, false) catch {
                res.status = 400;
                return .{.none = {}};
            };
            if (loginData.user.len == 0) {
                res.status = 400;
                return .{.none = {}};
            }

            var maybeRecord: ?UserRecord = null;
            for (rows) |*r| {
                if (std.mem.eql(u8, r.record.user, loginData.user)) {
                    maybeRecord = r.record;
                    break;
                }
            }
            const record = maybeRecord orelse {
                try res.writer().writeAll("user");
                res.status = 401;
                return .{.none = {}};
            };

            const sessionId = state.login(record, loginData.password, aPerm, a) catch |err| {
                switch (err) {
                    error.WrongPassword => {
                        try res.writer().writeAll("password");
                    },
                    else => {},
                }
                res.status = 401;
                return .{.none = {}};
            };
            state.save(a) catch |err| {
                std.log.err("auth state save err={}", .{err});
            };

            try res.writer().print("{x}", .{sessionId});
        } else if (std.mem.eql(u8, req.url.path, endpoints.logout)) {
            const session = maybeSession orelse {
                res.status = 401;
                return .{.none = {}};
            };
            _ = session;
            const sessionId = maybeSessionId orelse {
                res.status = 500;
                return .{.none = {}};
            };

            state.logoff(sessionId);
            state.save(a) catch |err| {
                std.log.err("auth state save err={}", .{err});
            };

            try res.writer().writeByte('y');
        } else if (std.mem.eql(u8, req.url.path, endpoints.register)) {
            const body = req.body() orelse {
                res.status = 400;
                return .{.none = {}};
            };
            const RegisterData = struct {
                user: []const u8,
                password: []const u8,
            };
            const registerData = parseNewlineStrings(RegisterData, body, true) catch {
                res.status = 400;
                return .{.none = {}};
            };
            if (registerData.user.len == 0) {
                res.status = 400;
                return .{.none = {}};
            }
            if (registerData.password.len < 8) {
                res.status = 400;
                return .{.none = {}};
            }

            const result = try state.register(registerData.user, registerData.user, registerData.password, aPerm, a);
            state.save(a) catch |err| {
                std.log.err("auth state save err={}", .{err});
            };

            try res.writer().writeByte('y');

            return .{.register = .{
                .result = result,
                .reqBody = body,
            }};
        } else if (std.mem.eql(u8, req.url.path, endpoints.unregister)) {
            const session = maybeSession orelse {
                res.status = 401;
                return .{.none = {}};
            };

            state.unregister(session.userId);
            state.save(a) catch |err| {
                std.log.err("auth state save err={}", .{err});
            };

            try res.writer().writeByte('y');
            return .{.unregister = session.userId};
        }
    }

    return .{.none = {}};
}
