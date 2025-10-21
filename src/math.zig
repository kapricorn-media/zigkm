const std = @import("std");

pub const V2 = @Vector(2, f32);
pub const V3 = @Vector(3, f32);
pub const V4 = @Vector(3, f32);

pub const V2i = @Vector(2, i32);
pub const V2u = @Vector(2, u32);
pub const V3i = @Vector(3, i32);
pub const V3u = @Vector(3, u32);

pub const Rect = struct {
    min: V2,
    max: V2,
};

pub fn vXfZ(v: V2, f: f32) V3
{
    return .{v[0], f, v[1]};
}

pub fn vXYf(v: V2, f: f32) V3
{
    return .{v[0], v[1], f};
}

pub fn vX0Z(v: V2) V3
{
    return vXfZ(v, 0);
}

pub fn vXY0(v: V2) V3
{
    return vXYf(v, 0);
}

pub fn vXZ(v: V3) V2
{
    return .{v[0], v[2]};
}

pub fn randF(rand: std.Random, range: V2) f32
{
    return rand.float(f32) * (range[1] - range[0]) + range[0];
}

pub fn randAngle(rand: std.Random) f32
{
    return rand.float(f32) * std.math.tau;
}

// For @Vector types.
pub fn lerpV(a: anytype, b: anytype, t: anytype) @TypeOf(a, b)
{
    const Type = @TypeOf(a, b);
    const tSplat: Type = @splat(t);
    return @mulAdd(Type, b - a, tSplat, a);
}

// Given "value" is the result of a lerp between "a" and "b", return the "t" that produced it.
pub fn invLerp(a: anytype, b: anytype, value: anytype) @TypeOf(a, b, value)
{
    return (value - a) / (b - a);
}

pub fn easeOut(t: f32, k: f32) f32
{
    return 1.0 - std.math.pow(f32, 1.0 - t, k);
}

// Maps input range [0, inf) to [0, 1) with an asymptote at 1.
// Lower k parameter results in a faster approach to 1.
pub fn asym(t: f32, k: f32) f32
{
    return -k / (t + k) + 1;
}

pub fn smootherstep(t: f32) f32
{
    const tt = std.math.clamp(t, 0, 1);
    return tt * tt * tt * (tt * (tt * 6 - 15) + 10);
}

// Unsigned subtraction that avoids underflow by "flooring" the result at 0.
// subFloor(5, 3) = 2
// subFloor(3, 5) = 0
pub fn subFloor(v1: anytype, v2: @TypeOf(v1)) @TypeOf(v1)
{
    const TI = @typeInfo(@TypeOf(v1));
    comptime std.debug.assert(TI == .int and TI.int.signedness == .unsigned);
    return if (v1 >= v2) v1 - v2 else 0;
}

pub fn cross2(v1: V2, v2: V2) f32
{
    return v1[0] * v2[1] - v1[1] * v2[0];
}

pub fn zero(comptime N: comptime_int) @Vector(N, f32)
{
    return @splat(0);
}

pub fn splat(comptime N: comptime_int, v: f32) @Vector(N, f32)
{
    return @splat(v);
}

pub fn dot(comptime N: comptime_int, v1: @Vector(N, f32), v2: @Vector(N, f32)) f32
{
    var result: f32 = 0;
    inline for (0..N) |i| {
        result += v1[i] * v2[i];
    }
    return result;
}

pub fn magSq(comptime N: comptime_int, v: @Vector(N, f32)) f32
{
    var result: f32 = 0;
    inline for (0..N) |i| {
        result += v[i] * v[i];
    }
    return result;
}

pub fn mag(comptime N: comptime_int, v: @Vector(N, f32)) f32
{
    return std.math.sqrt(magSq(N, v));
}

pub fn distSq(comptime N: comptime_int, v1: @Vector(N, f32), v2: @Vector(N, f32)) f32
{
    return magSq(N, v1 - v2);
}

pub fn dist(comptime N: comptime_int, v1: @Vector(N, f32), v2: @Vector(N, f32)) f32
{
    return mag(N, v1 - v2);
}

pub fn normalizeOrZero(comptime N: comptime_int, v: @Vector(N, f32)) @Vector(N, f32)
{
    if (@reduce(.And, v == @as(@Vector(N, f32), @splat(0)))) {
        return v;
    }
    const m = mag(N, v);
    return v / @as(@Vector(N, f32), @splat(m));
}

// Return the projection of vector v1 onto v2.
pub fn project(comptime N: comptime_int, v1: @Vector(N, f32), v2: @Vector(N, f32)) @Vector(N, f32)
{
    return v2 * @as(@Vector(N, f32), @splat(dot(N, v1, v2)));
}

pub fn v2ToAngle(v: V2) f32
{
    const zeroRot = V2 {1, 0};
    if (@reduce(.And, v == zeroRot)) {
        return 0;
    }
    const c = cross2(zeroRot, v);
    const d = dot(2, zeroRot, v);
    return std.math.atan2(c, d);
}

pub fn v3ToAngle(dir: V3) f32
{
    return v2ToAngle(vXZ(dir));
}

pub fn angleToV2(a: f32) V2
{
    return normalizeOrZero(2, .{ std.math.cos(a), std.math.sin(a) });
}

pub fn angleToV3(a: f32) V3
{
    return vX0Z(angleToV2(a));
}

// Normalize angle to the range [0, tau).
pub fn normalizeAngle(a: f32) f32
{
    const mod = std.math.modf(a / std.math.tau);
    const t = if (mod.fpart < 0) mod.fpart + 1.0 else mod.fpart;
    return t * std.math.tau;
}

pub fn lerpAngle(a1: f32, a2: f32, t: f32) f32
{
    var minDiff = a2 - a1;
    const targets = [2]f32 {
        a2 - std.math.tau,
        a2 + std.math.tau,
    };
    for (targets) |target| {
        const diff = target - a1;
        if (@abs(diff) < @abs(minDiff)) {
            minDiff = diff;
        }
    }
    return normalizeAngle(a1 + minDiff * t);
}

pub fn angleTo2(from: V2, to: V2) f32
{
    const dir = to - from;
    return v2ToAngle(.{dir[0], -dir[1]});
}

// Just downcasts to 2D, not fancy 3D angle.
pub fn angleTo3(from: V3, to: V3) f32
{
    return angleTo2(vXZ(from), vXZ(to));
}

// IDK, I'm probably doing this in a really dumb way...
pub fn angleMinDiff(a1: f32, a2: f32) f32
{
    const an1 = normalizeAngle(a1);
    const an2 = normalizeAngle(a2);
    const diff1 = @abs(an2 - an1 - std.math.tau);
    const diff2 = @abs(an2 - an1);
    const diff3 = @abs(an2 - an1 + std.math.tau);
    return @min(diff1, @min(diff2, diff3));
}

pub fn vOffsetAngle(v: V2, radius: f32, angle: f32) V2
{
    return v + angleToV2(angle) * splat(2, radius);
}

pub fn vOffsetAngle3(v: V3, radius: f32, angle: f32) V3
{
    return vXfZ(vOffsetAngle(.{v[0], v[2]}, radius, angle), v[1]);
}

// Returns the closest point to target such that the distance to pos isn't greater than range.
pub fn spellTargetMaxRange(pos: V3, target: V2, range: f32) V2
{
    var diff = vX0Z(target) - pos;
    const diffMag = mag(3, diff);
    if (diffMag <= range) {
        return target;
    } else {
        diff *= @splat(range / diffMag);
        return vXZ(pos + diff);
    }
}

pub fn isPointInArc(p: V3, origin: V3, angle: f32, arcAngle: f32, radius: f32) bool
{
    const dsq = distSq(3, p, origin);
    if (dsq > radius * radius) {
        return false;
    }
    const diff = normalizeOrZero(3, p - origin);
    const angleDiff = angleMinDiff(v3ToAngle(diff), angle);
    return angleDiff <= arcAngle / 2;
}

pub fn calculateParabolaVelFromTime(start: V3, endXZ: V2, time: f32, g: f32) V3
{
    const startXZ = vXZ(start);
    const distHorizontal = dist(2, startXZ, endXZ);
    const speedXZ = distHorizontal / time;
    var velXZ = normalizeOrZero(2, endXZ - startXZ);
    velXZ *= @splat(speedXZ);
    const speedY = -(2.0 * start[1] - g * time * time) / (2.0 * time);
    return .{velXZ[0], speedY, velXZ[1]};
}

pub fn calculateParabolaVelFromSpeed(start: V3, endXZ: V2, speedXZ: f32, g: f32) V3
{
    const distHorizontal = dist(2, vXZ(start), endXZ);
    const time = distHorizontal / speedXZ;
    return calculateParabolaVelFromTime(start, endXZ, time, g);
}

pub fn rayCircleIntersection(rayOrigin: V2, rayDir: V2, circlePos: V2, circleRadius: f32, outT1: *f32, outT2: *f32) bool
{
    const rayToCircle = circlePos - rayOrigin;
    const rayToClosest = project(2, rayToCircle, rayDir);
    const closestToCircle = rayToCircle - rayToClosest;
    const distToCircle = mag(2, closestToCircle);
    if (distToCircle > circleRadius) {
        return false;
    } else {
        const mm = @sqrt(circleRadius * circleRadius - distToCircle * distToCircle);
        std.debug.assert(mm >= 0);
        var tBase = mag(2, rayToClosest);
        if (dot(2, rayDir, rayToClosest) < 0) {
            tBase = -tBase;
        }
        outT1.* = tBase - mm;
        outT2.* = tBase + mm;
        return true;
    }
}

pub fn lineLineIntersection(a1: V2, a2: V2, b1: V2, b2: V2, outIntersection: *V2) bool
{
    outIntersection.* = .{0, 0};
    const b = a2 - a1;
    const d = b2 - b1;
    const bdCross = cross2(b, d);
    if (bdCross == 0) {
        // Lines are parallel, infinite intersections. We consider this no intersection.
        return false;
    }

    const c = b1 - a1;
    const t = cross2(c, d) / bdCross;
    if (t < 0 or t > 1) return false;

    const u = cross2(c, b) / bdCross;
    if (u < 0 or u > 1) return false;

    outIntersection.* = a1 + @as(V2, @splat(t)) * b;

    return true;
}

const CODE_X_UNDER : u4 = 0b0001;
const CODE_X_OVER  : u4 = 0b0010;
const CODE_Y_UNDER : u4 = 0b0100;
const CODE_Y_OVER  : u4 = 0b1000;

fn cohenSutherlandOutcode(p: V2, rect: Rect) u4
{
    var outcode: u4 = 0; // 0 means inside
    if (p[0] < rect.min[0]) {
        outcode |= CODE_X_UNDER;
    } else if (p[0] > rect.max[0]) {
        outcode |= CODE_X_OVER;
    }
    if (p[1] < rect.min[1]) {
        outcode |= CODE_Y_UNDER;
    } else if (p[1] > rect.max[1]) {
        outcode |= CODE_Y_OVER;
    }
    return outcode;
}

pub fn lineRectIntersection(a1: V2, a2: V2, rect: Rect) bool
{
    const a1Code = cohenSutherlandOutcode(a1, rect);
    const a2Code = cohenSutherlandOutcode(a2, rect);
    if ((a1Code | a2Code) == 0) {
        // Both inside.
        return false;
    } else if ((a1Code & a2Code) != 0) {
        // No intersection is possible.
        return false;
    } else {
        const r3 = V2 {rect.min[0], rect.max[1]};
        const r4 = V2 {rect.max[0], rect.min[1]};
        var int: V2 = undefined;
        const out1 = lineLineIntersection(a1, a2, rect.min, r3, &int);
        const out2 = lineLineIntersection(a1, a2, rect.min, r4, &int);
        const out3 = lineLineIntersection(a1, a2, r3, rect.max, &int);
        const out4 = lineLineIntersection(a1, a2, r4, rect.max, &int);
        return out1 or out2 or out3 or out4;
    }
}

test "line line intersection"
{
    const Case = struct {
        a1: V2,
        a2: V2,
        b1: V2,
        b2: V2,
        intersect: bool,
    };
    const CASES = [_]Case {
        .{
            .a1 = .{0, 0},
            .a2 = .{1, 0},
            .b1 = .{0, 0},
            .b2 = .{0, 1},
            .intersect = true,
        },
        .{
            .a1 = .{0, 0},
            .a2 = .{1, 0.5},
            .b1 = .{0.1, 0.1},
            .b2 = .{0.9, 0.1},
            .intersect = true,
        },
        .{
            .a1 = .{0, 0},
            .a2 = .{1, 0.5},
            .b1 = .{0.9, 0.1},
            .b2 = .{0.9, 0.9},
            .intersect = true,
        },
    };
    for (CASES) |c| {
        var int: V2 = undefined;
        const out = lineLineIntersection(c.a1, c.a2, c.b1, c.b2, &int);
        if (out != c.intersect) {
            std.log.err("{}", .{c});
            return error.Mismatch;
        }
    }
}

test "line rect intersection"
{
    const Case = struct {
        a1: V2,
        a2: V2,
        rect: Rect,
        expectedOut: bool,
    };
    const rect = Rect {
        .min = .{0.1, 0.1},
        .max = .{0.9, 0.9},
    };
    const CASES = [_]Case {
        .{
            .a1 = .{0, 0},
            .a2 = .{1, 0},
            .rect = rect,
            .expectedOut = false,
        },
        .{
            .a1 = .{0, 0},
            .a2 = .{0, 1},
            .rect = rect,
            .expectedOut = false,
        },
        .{
            .a1 = .{0, 0},
            .a2 = .{1, 1},
            .rect = rect,
            .expectedOut = true,
        },
        .{
            .a1 = .{1, 0},
            .a2 = .{0, 1},
            .rect = rect,
            .expectedOut = true,
        },
        .{
            .a1 = .{0, 0},
            .a2 = .{1, 0.5},
            .rect = rect,
            .expectedOut = true,
        },
        .{
            .a1 = .{0.5, 0},
            .a2 = .{0.5, 1},
            .rect = rect,
            .expectedOut = true,
        },
        .{
            .a1 = .{0.5, 0},
            .a2 = .{1, 1},
            .rect = rect,
            .expectedOut = true,
        },
        .{
            .a1 = .{0, 0},
            .a2 = .{0.11, 1},
            .rect = rect,
            .expectedOut = false,
        },
        .{
            .a1 = .{-0.5, 0.5},
            .a2 = .{0.5, -0.5},
            .rect = rect,
            .expectedOut = false,
        },
        .{
            .a1 = .{-0.5, 0.5},
            .a2 = .{0.5, -0.5},
            .rect = .{
                .min = .{0, 0},
                .max = .{1, 1},
            },
            .expectedOut = true, // glancing hit
        },
        .{
            // Both inside
            .a1 = .{0.4, 0.4},
            .a2 = .{0.6, 0.6},
            .rect = rect,
            .expectedOut = false,
        },
    };
    for (CASES, 0..) |c, i| {
        // var int: V2 = undefined;
        const out = lineRectIntersection(c.a1, c.a2, c.rect);
        if (out != c.expectedOut) {
            std.log.err("{}: {}", .{i, c});
            return error.Mismatch;
        }
    }
}
