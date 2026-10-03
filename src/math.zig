const std = @import("std");

pub const V2 = @Vector(2, f32);
pub const V3 = @Vector(3, f32);
pub const V4 = @Vector(4, f32);

pub const Ray = struct {
    origin: V3,
    dir: V3,
};

/// Column-major 4x4 matrix.
pub const Mat4 = [16]f32;
pub const Quat = [4]f32;

pub const V2i = @Vector(2, i32);
pub const V2u = @Vector(2, u32);
pub const V3i = @Vector(3, i32);
pub const V3u = @Vector(3, u32);

pub fn RectT(comptime T: type) type {
    const VT = @Vector(2, T);
    const RT = struct {
        min: VT,
        max: VT,

        const Self = @This();

        pub fn init(origin: VT, size_: VT) Self {
            return .{
                .min = origin,
                .max = origin + size_,
            };
        }

        pub fn size(r: Self) VT {
            return r.max - r.min;
        }
    };
    return RT;
}

pub const Rect = RectT(f32);
pub const RectI = RectT(i32);
pub const RectU = RectT(u32);

pub const COLOR_BLACK: V4 = .{ 0, 0, 0, 1 };
pub const COLOR_WHITE: V4 = .{ 1, 1, 1, 1 };

pub fn vXfZ(v: V2, f: f32) V3 {
    return .{ v[0], f, v[1] };
}

pub fn vXYf(v: V2, f: f32) V3 {
    return .{ v[0], v[1], f };
}

pub fn vX0Z(v: V2) V3 {
    return vXfZ(v, 0);
}

pub fn vXY0(v: V2) V3 {
    return vXYf(v, 0);
}

pub fn vXZ(v: V3) V2 {
    return .{ v[0], v[2] };
}

pub fn colorU8(v: @Vector(4, u8)) V4 {
    return @as(V4, @floatFromInt(v)) / @as(V4, @splat(255.0));
}

pub fn colorHex(hex: []const u8) !V4 {
    if (hex.len != 6 and hex.len != 8) {
        return error.BadHex;
    }
    const r = try std.fmt.parseUnsigned(u8, hex[0..2], 16);
    const g = try std.fmt.parseUnsigned(u8, hex[2..4], 16);
    const b = try std.fmt.parseUnsigned(u8, hex[4..6], 16);
    const a = if (hex.len == 8) try std.fmt.parseUnsigned(u8, hex[6..8], 16) else 255;
    return colorU8(.{ r, g, b, a });
}

pub fn randF(rand: std.Random, range: V2) f32 {
    return rand.float(f32) * (range[1] - range[0]) + range[0];
}

pub fn randAngle(rand: std.Random) f32 {
    return rand.float(f32) * std.math.tau;
}

pub fn round(v: f32, decimals: u8) f32 {
    const mult = std.math.pow(f32, 10.0, @floatFromInt(decimals));
    return @round(v * mult) / mult;
}

pub fn lerpV(a: anytype, b: anytype, t: anytype) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    const tSplat: T = @splat(t);
    return @mulAdd(T, b - a, tSplat, a);
}

// Given "value" is the result of a lerp between "a" and "b", return the "t" that produced it.
pub fn invLerp(a: anytype, b: anytype, value: anytype) @TypeOf(a, b, value) {
    return (value - a) / (b - a);
}

pub fn easeOut(t: f32, k: f32) f32 {
    return 1.0 - std.math.pow(f32, 1.0 - t, k);
}

// Maps input range [0, inf) to [0, 1) with an asymptote at 1.
// Lower k parameter results in a faster approach to 1.
pub fn asym(t: f32, k: f32) f32 {
    return -k / (t + k) + 1;
}

pub fn smootherstep(t: f32) f32 {
    const tt = std.math.clamp(t, 0, 1);
    return tt * tt * tt * (tt * (tt * 6 - 15) + 10);
}

// Frame-rate-independent damping of value v to a target value.

pub fn dampTo(v: f32, target: f32, rate: f32, dt: f32) @TypeOf(v, target) {
    return std.math.lerp(v, target, 1.0 - std.math.pow(f32, rate, dt));
}

pub fn dampToV(v: anytype, target: anytype, rate: f32, dt: f32) @TypeOf(v, target) {
    return lerpV(v, target, 1.0 - std.math.pow(f32, rate, dt));
}

// Unsigned subtraction that avoids underflow by "flooring" the result at 0.
// subFloor(5, 3) = 2
// subFloor(3, 5) = 0
pub fn subFloor(v1: anytype, v2: @TypeOf(v1)) @TypeOf(v1) {
    const TI = @typeInfo(@TypeOf(v1));
    comptime std.debug.assert(TI == .int and TI.int.signedness == .unsigned);
    return if (v1 >= v2) v1 - v2 else 0;
}

pub fn cross2(v1: V2, v2: V2) f32 {
    return v1[0] * v2[1] - v1[1] * v2[0];
}

pub fn zero(comptime N: comptime_int) @Vector(N, f32) {
    return @splat(0);
}

pub fn one(comptime N: comptime_int) @Vector(N, f32) {
    return @splat(1);
}

pub fn splat(comptime N: comptime_int, v: f32) @Vector(N, f32) {
    return @splat(v);
}

pub fn dot(comptime N: comptime_int, v1: @Vector(N, f32), v2: @Vector(N, f32)) f32 {
    var result: f32 = 0;
    inline for (0..N) |i| {
        result += v1[i] * v2[i];
    }
    return result;
}

pub fn magSq(comptime N: comptime_int, v: @Vector(N, f32)) f32 {
    var result: f32 = 0;
    inline for (0..N) |i| {
        result += v[i] * v[i];
    }
    return result;
}

pub fn magSqI(comptime N: comptime_int, v: @Vector(N, i32)) i32 {
    var result: i32 = 0;
    inline for (0..N) |i| {
        result += v[i] * v[i];
    }
    return result;
}

pub fn mag(comptime N: comptime_int, v: @Vector(N, f32)) f32 {
    return std.math.sqrt(magSq(N, v));
}

pub fn distSq(comptime N: comptime_int, v1: @Vector(N, f32), v2: @Vector(N, f32)) f32 {
    return magSq(N, v1 - v2);
}

pub fn dist(comptime N: comptime_int, v1: @Vector(N, f32), v2: @Vector(N, f32)) f32 {
    return mag(N, v1 - v2);
}

pub fn normalizeOrZero(comptime N: comptime_int, v: @Vector(N, f32)) @Vector(N, f32) {
    if (@reduce(.And, v == @as(@Vector(N, f32), @splat(0)))) {
        return v;
    }
    const m = mag(N, v);
    return v / splat(N, m);
}

// v shortened to length maxMag if it's longer, otherwise unchanged.
pub fn clampMag(comptime N: comptime_int, v: @Vector(N, f32), maxMag: f32) @Vector(N, f32) {
    const m = mag(N, v);
    return if (m > maxMag) v * splat(N, maxMag / m) else v;
}

pub fn cross3(a: V3, b: V3) V3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub fn quatFromAxisAngle(axis: V3, radians: f32) Quat {
    const normalizedAxis = normalizeOrZero(3, axis);
    const halfAngle = radians * 0.5;
    const s = @sin(halfAngle);
    return .{
        normalizedAxis[0] * s,
        normalizedAxis[1] * s,
        normalizedAxis[2] * s,
        @cos(halfAngle),
    };
}

pub fn quatMultiply(a: Quat, b: Quat) Quat {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}

pub fn quatNormalize(q: Quat) Quat {
    const length = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (length == 0.0) return .{ 0.0, 0.0, 0.0, 1.0 };
    return .{ q[0] / length, q[1] / length, q[2] / length, q[3] / length };
}

pub fn transformPoint(matrix: Mat4, point: V3) V3 {
    return .{
        matrix[0] * point[0] + matrix[4] * point[1] + matrix[8] * point[2] + matrix[12],
        matrix[1] * point[0] + matrix[5] * point[1] + matrix[9] * point[2] + matrix[13],
        matrix[2] * point[0] + matrix[6] * point[1] + matrix[10] * point[2] + matrix[14],
    };
}

pub fn transformVector(matrix: Mat4, vector: V3) V3 {
    return .{
        matrix[0] * vector[0] + matrix[4] * vector[1] + matrix[8] * vector[2],
        matrix[1] * vector[0] + matrix[5] * vector[1] + matrix[9] * vector[2],
        matrix[2] * vector[0] + matrix[6] * vector[1] + matrix[10] * vector[2],
    };
}

pub fn identity() Mat4 {
    return .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}

pub fn translation(v: V3) Mat4 {
    var result = identity();
    result[12] = v[0];
    result[13] = v[1];
    result[14] = v[2];
    return result;
}

pub fn scale(v: V3) Mat4 {
    return .{
        v[0], 0,    0,    0,
        0,    v[1], 0,    0,
        0,    0,    v[2], 0,
        0,    0,    0,    1,
    };
}

pub fn rotationX(radians: f32) Mat4 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{
        1, 0,  0, 0,
        0, c,  s, 0,
        0, -s, c, 0,
        0, 0,  0, 1,
    };
}

pub fn rotationY(radians: f32) Mat4 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{
        c, 0, -s, 0,
        0, 1, 0,  0,
        s, 0, c,  0,
        0, 0, 0,  1,
    };
}

pub fn rotationZ(radians: f32) Mat4 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{
        c,  s, 0, 0,
        -s, c, 0, 0,
        0,  0, 1, 0,
        0,  0, 0, 1,
    };
}

pub fn rotationXYZ(radians: V3) Mat4 {
    return multiply(rotationZ(radians[2]), multiply(rotationY(radians[1]), rotationX(radians[0])));
}

/// Returns the world-space normal for each Euler rotation ring. rotationXYZ
/// applies X, then Y, then Z, so each axis is transformed only by the
/// rotations which precede it in the matrix product:
///
///   X: parent * Rz * Ry
///   Y: parent * Rz
///   Z: parent
///
/// A rotation around a ring's own axis is intentionally omitted because it
/// cannot change the ring's plane.
pub fn rotationXYZRingAxes(parent: Mat4, radians: V3) [3]V3 {
    const afterZ = multiply(parent, rotationZ(radians[2]));
    const afterZY = multiply(afterZ, rotationY(radians[1]));
    return .{
        normalizeOrZero(3, transformVector(afterZY, .{ 1.0, 0.0, 0.0 })),
        normalizeOrZero(3, transformVector(afterZ, .{ 0.0, 1.0, 0.0 })),
        normalizeOrZero(3, transformVector(parent, .{ 0.0, 0.0, 1.0 })),
    };
}

pub fn quatToMat4(q: Quat) Mat4 {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    const x2 = x + x;
    const y2 = y + y;
    const z2 = z + z;
    const xx = x * x2;
    const xy = x * y2;
    const xz = x * z2;
    const yy = y * y2;
    const yz = y * z2;
    const zz = z * z2;
    const wx = w * x2;
    const wy = w * y2;
    const wz = w * z2;

    return .{
        1.0 - (yy + zz), xy + wz,         xz - wy,         0,
        xy - wz,         1.0 - (xx + zz), yz + wx,         0,
        xz + wy,         yz - wx,         1.0 - (xx + yy), 0,
        0,               0,               0,               1,
    };
}

pub fn perspective(fovYRadians: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fovYRadians * 0.5);
    const nf = 1.0 / (near - far);
    return .{
        f / aspect, 0, 0,                       0,
        0,          f, 0,                       0,
        0,          0, (far + near) * nf,       -1,
        0,          0, (2.0 * far * near) * nf, 0,
    };
}

pub fn multiply(a: Mat4, b: Mat4) Mat4 {
    var result: Mat4 = undefined;
    for (0..4) |column| {
        for (0..4) |row| {
            result[column * 4 + row] =
                a[0 * 4 + row] * b[column * 4 + 0] +
                a[1 * 4 + row] * b[column * 4 + 1] +
                a[2 * 4 + row] * b[column * 4 + 2] +
                a[3 * 4 + row] * b[column * 4 + 3];
        }
    }
    return result;
}

pub fn inverse(matrix: Mat4) ?Mat4 {
    var augmented: [4][8]f32 = undefined;
    for (0..4) |row| {
        for (0..4) |column| {
            augmented[row][column] = matrix[column * 4 + row];
            augmented[row][column + 4] = if (row == column) 1.0 else 0.0;
        }
    }

    for (0..4) |column| {
        var pivotRow = column;
        for (column + 1..4) |row| {
            if (@abs(augmented[row][column]) > @abs(augmented[pivotRow][column])) pivotRow = row;
        }
        if (@abs(augmented[pivotRow][column]) < 0.000001) return null;

        if (pivotRow != column) {
            const temporary = augmented[column];
            augmented[column] = augmented[pivotRow];
            augmented[pivotRow] = temporary;
        }

        const pivot = augmented[column][column];
        for (0..8) |i| augmented[column][i] /= pivot;

        for (0..4) |row| {
            if (row == column) continue;
            const factor = augmented[row][column];
            for (0..8) |i| augmented[row][i] -= factor * augmented[column][i];
        }
    }

    var result: Mat4 = undefined;
    for (0..4) |row| {
        for (0..4) |column| result[column * 4 + row] = augmented[row][column + 4];
    }
    return result;
}

/// Instantaneous motion of point around an axis through origin, per radian.
pub fn rotationPositionDerivative(axis: V3, origin: V3, point: V3) V3 {
    return cross3(axis, point - origin);
}

/// Solves a 3x3 row-major linear system using Gaussian elimination with
/// partial pivoting.
pub fn solveLinear3(matrix: [3]V3, vector: V3) ?V3 {
    var augmented: [3][4]f32 = undefined;
    for (0..3) |row| {
        for (0..3) |column| augmented[row][column] = matrix[row][column];
        augmented[row][3] = vector[row];
    }

    for (0..3) |column| {
        var pivotRow = column;
        for (column + 1..3) |row| {
            if (@abs(augmented[row][column]) > @abs(augmented[pivotRow][column])) pivotRow = row;
        }
        if (@abs(augmented[pivotRow][column]) < 0.000001) return null;

        if (pivotRow != column) {
            const temporary = augmented[column];
            augmented[column] = augmented[pivotRow];
            augmented[pivotRow] = temporary;
        }

        const pivot = augmented[column][column];
        for (column..4) |i| augmented[column][i] /= pivot;

        for (0..3) |row| {
            if (row == column) continue;
            const factor = augmented[row][column];
            for (column..4) |i| augmented[row][i] -= factor * augmented[column][i];
        }
    }

    return .{ augmented[0][3], augmented[1][3], augmented[2][3] };
}

/// Returns the point where a ray intersects a plane, or null when the ray is
/// parallel to the plane or the intersection lies behind the ray origin.
/// Neither ray.dir nor planeNormal needs to be normalized.
pub fn rayPlaneIntersection(ray: Ray, planeOrigin: V3, planeNormal: V3) ?V3 {
    const denominator = dot(3, ray.dir, planeNormal);
    const directionLengthSquared = dot(3, ray.dir, ray.dir);
    const normalLengthSquared = dot(3, planeNormal, planeNormal);
    const parallelTolerance: f32 = 0.000001;
    if (denominator * denominator <= parallelTolerance * parallelTolerance * directionLengthSquared * normalLengthSquared) return null;

    const distance = dot(3, planeOrigin - ray.origin, planeNormal) / denominator;
    if (distance < 0.0) return null;
    return ray.origin + ray.dir * splat(3, distance);
}

pub fn projectPoint(matrix: Mat4, point: V3, screenSize: V2) ?V2 {
    const clipX = matrix[0] * point[0] + matrix[4] * point[1] + matrix[8] * point[2] + matrix[12];
    const clipY = matrix[1] * point[0] + matrix[5] * point[1] + matrix[9] * point[2] + matrix[13];
    const clipW = matrix[3] * point[0] + matrix[7] * point[1] + matrix[11] * point[2] + matrix[15];
    if (@abs(clipW) < 0.0001) return null;

    const ndcX = clipX / clipW;
    const ndcY = clipY / clipW;
    return .{
        (ndcX * 0.5 + 0.5) * screenSize[0],
        (ndcY * 0.5 + 0.5) * screenSize[1],
    };
}

pub fn distanceToSegment(point: V2, a: V2, b: V2) f32 {
    const ab = b - a;
    const ap = point - a;
    const abLengthSquared = magSq(2, ab);
    if (abLengthSquared <= 0.0001) return dist(2, point, a);

    const t = @min(@max(dot(2, ap, ab) / abLengthSquared, 0.0), 1.0);
    return dist(2, point, a + ab * splat(2, t));
}

/// Converts mouse motion parallel to a projected world-space axis into a
/// signed distance along that axis.
pub fn screenAxisDragDistance(matrix: Mat4, origin: V3, axis: V3, axisLength: f32, screenSize: V2, screenDelta: V2) f32 {
    const originScreen = projectPoint(matrix, origin, screenSize) orelse return 0.0;
    const endScreen = projectPoint(matrix, origin + axis * splat(3, axisLength), screenSize) orelse return 0.0;
    const screenAxis = endScreen - originScreen;
    const screenLengthSquared = dot(2, screenAxis, screenAxis);
    if (screenLengthSquared < 1.0) return 0.0;
    return dot(2, screenDelta, screenAxis) / screenLengthSquared * axisLength;
}

// Return the projection of vector v1 onto v2.
pub fn project(comptime N: comptime_int, v1: @Vector(N, f32), v2: @Vector(N, f32)) @Vector(N, f32) {
    return v2 * @as(@Vector(N, f32), @splat(dot(N, v1, v2)));
}

pub fn v2ToAngle(v: V2) f32 {
    const zeroRot = V2{ 1, 0 };
    if (@reduce(.And, v == zeroRot)) {
        return 0;
    }
    const c = cross2(zeroRot, v);
    const d = dot(2, zeroRot, v);
    return std.math.atan2(c, d);
}

pub fn v3ToAngle(dir: V3) f32 {
    return v2ToAngle(vXZ(dir));
}

pub fn angleToV2(a: f32) V2 {
    return normalizeOrZero(2, .{ std.math.cos(a), std.math.sin(a) });
}

pub fn angleToV3(a: f32) V3 {
    return vX0Z(angleToV2(a));
}

// Normalize angle to the range [0, tau).
pub fn normalizeAngle(a: f32) f32 {
    const mod = std.math.modf(a / std.math.tau);
    const t = if (mod.fpart < 0) mod.fpart + 1.0 else mod.fpart;
    return t * std.math.tau;
}

// Target angle when lerping between 2 normalized angles, to prevent suddent skips between 0 and tau.
// Note that the returned angle is intentionally not normalized.
pub fn targetAngle(to: f32, from: f32) f32 {
    const from1 = from - std.math.tau;
    const from2 = from + std.math.tau;
    const dist0 = @abs(to - from);
    const dist1 = @abs(to - from1);
    const dist2 = @abs(to - from2);
    if (dist0 < dist1 and dist0 < dist2) {
        return from;
    }
    if (dist1 < dist0 and dist1 < dist2) {
        return from1;
    }
    if (dist2 < dist0 and dist2 < dist1) {
        return from2;
    }
    return from;
}

pub fn lerpAngle(a1: f32, a2: f32, t: f32) f32 {
    var minDiff = a2 - a1;
    const targets = [2]f32{
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

pub fn angleTo2(from: V2, to: V2) f32 {
    const dir = to - from;
    return v2ToAngle(.{ dir[0], dir[1] });
}

// Just downcasts to 2D, not fancy 3D angle.
pub fn angleTo3(from: V3, to: V3) f32 {
    return angleTo2(vXZ(from), vXZ(to));
}

// IDK, I'm probably doing this in a really dumb way...
pub fn angleMinDiff(a1: f32, a2: f32) f32 {
    const an1 = normalizeAngle(a1);
    const an2 = normalizeAngle(a2);
    const diff1 = @abs(an2 - an1 - std.math.tau);
    const diff2 = @abs(an2 - an1);
    const diff3 = @abs(an2 - an1 + std.math.tau);
    return @min(diff1, @min(diff2, diff3));
}

pub fn vOffsetAngle(v: V2, radius: f32, angle: f32) V2 {
    return v + angleToV2(angle) * splat(2, radius);
}

pub fn vOffsetAngle3(v: V3, radius: f32, angle: f32) V3 {
    return vXfZ(vOffsetAngle(.{ v[0], v[2] }, radius, angle), v[1]);
}

// Returns the closest point to target such that the distance to pos isn't greater than range.
pub fn spellTargetMaxRange(pos: V3, target: V2, range: f32) V2 {
    var diff = vX0Z(target) - pos;
    const diffMag = mag(3, diff);
    if (diffMag <= range) {
        return target;
    } else {
        diff *= @splat(range / diffMag);
        return vXZ(pos + diff);
    }
}

pub fn vInRect(p: V2, r: Rect) bool {
    return @reduce(.And, r.min <= p) and @reduce(.And, p <= r.max);
}

pub fn isPointInArc(p: V3, origin: V3, angle: f32, arcAngle: f32, radius: f32) bool {
    const dsq = distSq(3, p, origin);
    if (dsq > radius * radius) {
        return false;
    }
    const diff = normalizeOrZero(3, p - origin);
    const angleDiff = angleMinDiff(v3ToAngle(diff), angle);
    return angleDiff <= arcAngle / 2;
}

pub fn calculateParabolaVelFromTime(start: V3, endXZ: V2, time: f32, g: f32) V3 {
    const startXZ = vXZ(start);
    const distHorizontal = dist(2, startXZ, endXZ);
    const speedXZ = distHorizontal / time;
    var velXZ = normalizeOrZero(2, endXZ - startXZ);
    velXZ *= @splat(speedXZ);
    const speedY = -(2.0 * start[1] - g * time * time) / (2.0 * time);
    return .{ velXZ[0], speedY, velXZ[1] };
}

pub fn calculateParabolaVelFromSpeed(start: V3, endXZ: V2, speedXZ: f32, g: f32) V3 {
    const distHorizontal = dist(2, vXZ(start), endXZ);
    const time = distHorizontal / speedXZ;
    return calculateParabolaVelFromTime(start, endXZ, time, g);
}

pub fn rayCircleIntersection(rayOrigin: V2, rayDir: V2, center: V2, circleRadius: f32, outT1: *f32, outT2: *f32) bool {
    const rayToCircle = center - rayOrigin;
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

// Unlike the lower level rayCircleIntersection, this only returns the closest hit in the direction of the ray.
// This includes intersections where the ray is inside the circle.
pub fn rayCircleHit(rayOrigin: V2, rayDir: V2, center: V2, radius: f32) HitInfo {
    var t1: f32 = undefined;
    var t2: f32 = undefined;
    if (rayCircleIntersection(rayOrigin, rayDir, center, radius, &t1, &t2)) {
        const t = if (t1 >= 0) t1 else if (t2 >= 0) t2 else return .noHit();
        const hitPos = rayOrigin + rayDir * splat(2, t);
        return .{
            .hit = true,
            .t = t,
            .pos = hitPos,
            .normal = normalizeOrZero(2, hitPos - center),
        };
    } else {
        return .noHit();
    }
}

test "rayCircleIntersection" {
    const TestCase = struct {
        rayOrigin: V2,
        rayDir: V2,
        center: V2,
        radius: f32,
        hit: bool,
        t1: f32 = 0,
        t2: f32 = 0,
    };

    const cases = [_]TestCase{
        .{
            .rayOrigin = .{ 0, 0 },
            .rayDir = .{ 1, 0 },
            .center = .{ 3, 0 },
            .radius = 1,
            .hit = true,
            .t1 = 2, // t1 is the first intersection, going in the direction of the ray
            .t2 = 4,
        },
        .{
            // ray and circle flipped, same t1+t2
            .rayOrigin = .{ 0, 0 },
            .rayDir = .{ -1, 0 },
            .center = .{ -3, 0 },
            .radius = 1,
            .hit = true,
            .t1 = 2,
            .t2 = 4,
        },
        .{
            // vertical, same t1+t2
            .rayOrigin = .{ 0, 0 },
            .rayDir = .{ 0, 1 },
            .center = .{ 0, 3 },
            .radius = 1,
            .hit = true,
            .t1 = 2,
            .t2 = 4,
        },
        .{
            // only circle is flipped, so t1+t2 are negative
            .rayOrigin = .{ 0, 0 },
            .rayDir = .{ 1, 0 },
            .center = .{ -3, 0 },
            .radius = 1,
            .hit = true,
            .t1 = -4,
            .t2 = -2,
        },
        .{
            .rayOrigin = .{ 0, 0 },
            .rayDir = .{ 1, 0 },
            .center = .{ 0, 0 },
            .radius = 1,
            .hit = true,
            .t1 = -1, // "first" intersection is negative (backwards) because the ray is inside the circle
            .t2 = 1,
        },
        .{
            .rayOrigin = .{ 0, 0 },
            .rayDir = .{ 1, 0 },
            .center = .{ 3, 3 },
            .radius = 1,
            .hit = false,
        },
    };

    for (cases) |case| {
        var t1: f32 = undefined;
        var t2: f32 = undefined;
        const hit = rayCircleIntersection(case.rayOrigin, case.rayDir, case.center, case.radius, &t1, &t2);
        try std.testing.expectEqual(case.hit, hit);
        if (case.hit) {
            try std.testing.expectEqual(case.t1, t1);
            try std.testing.expectEqual(case.t2, t2);
        }
    }
}

pub fn lineCircleHit(p1: V2, p2: V2, center: V2, radius: f32) HitInfo {
    const lineLength = mag(2, p2 - p1);
    if (lineLength == 0) {
        return .noHit();
    }

    const dir = (p2 - p1) / splat(2, lineLength);
    var t1: f32 = undefined;
    var t2: f32 = undefined;
    if (rayCircleIntersection(p1, dir, center, radius, &t1, &t2)) {
        var maybeT: ?f32 = null;
        if (0 <= t1 and t1 <= lineLength) {
            maybeT = t1;
        }
        if (0 <= t2 and t2 <= lineLength) {
            maybeT = t2;
        }
        if (maybeT) |t| {
            const pos = p1 + dir * splat(2, t);
            return .{
                .hit = true,
                .t = t,
                .pos = pos,
                .normal = normalizeOrZero(2, pos - center),
            };
        }
    }

    return .noHit();
}

test "lineCircleHit" {
    const TestCase = struct {
        p1: V2,
        p2: V2,
        center: V2,
        radius: f32,
        expectedHit: HitInfo,
    };

    const cases = [_]TestCase{
        .{
            .p1 = .{ 0, 0 },
            .p2 = .{ 0, 0 },
            .center = .{ 0, 0 },
            .radius = 0,
            .expectedHit = .{
                .hit = false,
                .t = undefined,
                .pos = undefined,
                .normal = undefined,
            },
        },
        .{
            .p1 = .{ 0, 0 },
            .p2 = .{ 1, 0 },
            .center = .{ 1, 0 },
            .radius = 0.5,
            .expectedHit = .{
                .hit = true,
                .t = 0.5,
                .pos = .{ 0.5, 0 },
                .normal = .{ -1, 0 },
            },
        },
    };

    for (cases) |case| {
        const hit = lineCircleHit(case.p1, case.p2, case.center, case.radius);
        if (case.expectedHit.hit) {
            try std.testing.expectEqual(case.expectedHit, hit);
        } else {
            try std.testing.expectEqual(false, hit.hit);
        }
    }
}

pub fn lineLineIntersection(a1: V2, a2: V2, b1: V2, b2: V2, outT: *f32, outIntersection: *V2) bool {
    outIntersection.* = .{ 0, 0 };
    const b = a2 - a1;
    const d = b2 - b1;
    const bdCross = cross2(b, d);
    if (bdCross == 0) {
        // Lines are parallel. This *could* be an infinite intersection, but we consider it no intersection.
        return false;
    }

    const c = b1 - a1;
    outT.* = cross2(c, d) / bdCross;
    if (outT.* < 0 or outT.* > 1) return false;

    const u = cross2(c, b) / bdCross;
    if (u < 0 or u > 1) return false;

    outIntersection.* = a1 + @as(V2, @splat(outT.*)) * b;
    return true;
}

pub fn lineLineHit(a1: V2, a2: V2, b1: V2, b2: V2) HitInfo {
    const b = a2 - a1;
    const d = b2 - b1;
    const bdCross = cross2(b, d);
    if (bdCross == 0) {
        // Lines are parallel. This *could* be an infinite intersection, but we consider it no intersection.
        return .noHit();
    }

    const c = b1 - a1;
    const t = cross2(c, d) / bdCross;
    if (t < 0 or t > 1) return .noHit();

    const u = cross2(c, b) / bdCross;
    if (u < 0 or u > 1) return .noHit();

    const bDir = normalizeOrZero(2, b2 - b1);
    return .{
        .hit = true,
        .t = t,
        .pos = a1 + @as(V2, @splat(t)) * b,
        .normal = if (bdCross > 0) .{ -bDir[1], bDir[0] } else .{ bDir[1], -bDir[0] },
    };
}

const CODE_X_UNDER: u4 = 0b0001;
const CODE_X_OVER: u4 = 0b0010;
const CODE_Y_UNDER: u4 = 0b0100;
const CODE_Y_OVER: u4 = 0b1000;

fn cohenSutherlandOutcode(p: V2, rect: Rect) u4 {
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

pub fn lineRectIntersection(a1: V2, a2: V2, rect: Rect) bool {
    const a1Code = cohenSutherlandOutcode(a1, rect);
    const a2Code = cohenSutherlandOutcode(a2, rect);
    if ((a1Code | a2Code) == 0) {
        // Both inside.
        return false;
    } else if ((a1Code & a2Code) != 0) {
        // No intersection is possible.
        return false;
    } else {
        const r3 = V2{ rect.min[0], rect.max[1] };
        const r4 = V2{ rect.max[0], rect.min[1] };
        var t: f32 = undefined;
        var int: V2 = undefined;
        const out1 = lineLineIntersection(a1, a2, rect.min, r3, &t, &int);
        const out2 = lineLineIntersection(a1, a2, rect.min, r4, &t, &int);
        const out3 = lineLineIntersection(a1, a2, r3, rect.max, &t, &int);
        const out4 = lineLineIntersection(a1, a2, r4, rect.max, &t, &int);
        return out1 or out2 or out3 or out4;
    }
}

pub fn lineRectHit(p1: V2, p2: V2, rect: Rect) HitInfo {
    const p1Code = cohenSutherlandOutcode(p1, rect);
    const p2Code = cohenSutherlandOutcode(p2, rect);
    if ((p1Code | p2Code) == 0) {
        // Both inside.
        return .noHit();
    } else if ((p1Code & p2Code) != 0) {
        // No intersection is possible.
        return .noHit();
    } else {
        const r3 = V2{ rect.min[0], rect.max[1] };
        const r4 = V2{ rect.max[0], rect.min[1] };

        const hit1 = lineLineHit(p1, p2, rect.min, r3);
        if (hit1.hit) return hit1;
        const hit2 = lineLineHit(p1, p2, rect.min, r4);
        if (hit2.hit) return hit2;
        const hit3 = lineLineHit(p1, p2, r3, rect.max);
        if (hit3.hit) return hit3;
        const hit4 = lineLineHit(p1, p2, r4, rect.max);
        if (hit4.hit) return hit4;
    }

    return .noHit();
}

// TODO maybe all intersections should use HitInfo?
pub const HitInfo = struct {
    hit: bool,
    t: f32,
    pos: V2,
    normal: V2,

    pub fn noHit() HitInfo {
        return .{
            .hit = false,
            .t = std.math.floatMax(f32),
            .pos = .{ 0, 0 },
            .normal = .{ 0, 0 },
        };
    }
};

pub fn linePolygonHit(p1: V2, p2: V2, polygon: []const V2) HitInfo {
    var hit = HitInfo{
        .hit = false,
        .t = std.math.floatMax(f32),
        .pos = .{ 0, 0 },
        .normal = .{ 0, 0 },
    };
    if (polygon.len == 0) {
        return hit;
    }

    for (0..polygon.len) |i| {
        const indPrev = if (i == 0) polygon.len - 1 else i - 1;
        const poly1 = polygon[indPrev];
        const poly2 = polygon[i];
        var t: f32 = undefined;
        var int: V2 = undefined;
        if (lineLineIntersection(p1, p2, poly1, poly2, &t, &int)) {
            if (t < hit.t) {
                const lineVec = poly2 - poly1;
                const d = normalizeOrZero(2, lineVec);
                const cross = cross2(lineVec, p1 - poly1);
                var normal: V2 = undefined;
                if (cross > 0) {
                    normal = .{ -d[1], d[0] };
                } else {
                    normal = .{ d[1], -d[0] };
                }
                hit = .{
                    .hit = true,
                    .t = t,
                    .pos = int,
                    .normal = normal,
                };
            }
        }
    }

    return hit;
}

pub const CollideAndSlideParams = struct { maxBounces: u8, skinWidth: f32 };

pub fn collideAndSlide(p: V2, delta: V2, params: CollideAndSlideParams, context: anytype, comptime collideFn: fn (@TypeOf(context), p: V2, delta: V2) HitInfo) V2 {
    return collideAndSlideRecursive(p, delta, params, 0, context, collideFn);
}

fn collideAndSlideRecursive(p: V2, delta: V2, params: CollideAndSlideParams, bounce: u32, context: anytype, comptime collideFn: fn (@TypeOf(context), p: V2, delta: V2) HitInfo) V2 {
    if (bounce >= params.maxBounces) {
        return .{ 0, 0 };
    }

    const closestHit = collideFn(context, p, delta);
    if (closestHit.hit) {
        // blocked.* = true;
        // const deltaMag = mag(2, delta);
        // if (deltaMag == 0) return delta;
        // const deltaDir = delta / @as(V2, @splat(deltaMag));

        const t = @max(closestHit.t - params.skinWidth, 0);
        const toHit = delta * @as(V2, @splat(t));
        const remaining = delta - toHit;
        const remainingMag = mag(2, remaining);
        const hitTangent: V2 = .{ -closestHit.normal[1], closestHit.normal[0] };
        var remainingSnapped = normalizeOrZero(2, project(2, remaining, hitTangent));
        remainingSnapped *= @splat(remainingMag);
        return toHit + collideAndSlideRecursive(p + toHit, remainingSnapped, params, bounce + 1, context, collideFn);
    } else {
        return delta;
    }
}

test "line line intersection" {
    const Case = struct {
        a1: V2,
        a2: V2,
        b1: V2,
        b2: V2,
        intersect: bool,
    };
    const CASES = [_]Case{
        .{
            .a1 = .{ 0, 0 },
            .a2 = .{ 1, 0 },
            .b1 = .{ 0, 0 },
            .b2 = .{ 0, 1 },
            .intersect = true,
        },
        .{
            .a1 = .{ 0, 0 },
            .a2 = .{ 1, 0.5 },
            .b1 = .{ 0.1, 0.1 },
            .b2 = .{ 0.9, 0.1 },
            .intersect = true,
        },
        .{
            .a1 = .{ 0, 0 },
            .a2 = .{ 1, 0.5 },
            .b1 = .{ 0.9, 0.1 },
            .b2 = .{ 0.9, 0.9 },
            .intersect = true,
        },
    };
    for (CASES) |c| {
        var t: f32 = undefined;
        var int: V2 = undefined;
        const out = lineLineIntersection(c.a1, c.a2, c.b1, c.b2, &t, &int);
        if (out != c.intersect) {
            std.log.err("{}", .{c});
            return error.Mismatch;
        }
    }
}

test "line rect intersection" {
    const Case = struct {
        a1: V2,
        a2: V2,
        rect: Rect,
        expectedOut: bool,
    };
    const rect = Rect{
        .min = .{ 0.1, 0.1 },
        .max = .{ 0.9, 0.9 },
    };
    const CASES = [_]Case{
        .{
            .a1 = .{ 0, 0 },
            .a2 = .{ 1, 0 },
            .rect = rect,
            .expectedOut = false,
        },
        .{
            .a1 = .{ 0, 0 },
            .a2 = .{ 0, 1 },
            .rect = rect,
            .expectedOut = false,
        },
        .{
            .a1 = .{ 0, 0 },
            .a2 = .{ 1, 1 },
            .rect = rect,
            .expectedOut = true,
        },
        .{
            .a1 = .{ 1, 0 },
            .a2 = .{ 0, 1 },
            .rect = rect,
            .expectedOut = true,
        },
        .{
            .a1 = .{ 0, 0 },
            .a2 = .{ 1, 0.5 },
            .rect = rect,
            .expectedOut = true,
        },
        .{
            .a1 = .{ 0.5, 0 },
            .a2 = .{ 0.5, 1 },
            .rect = rect,
            .expectedOut = true,
        },
        .{
            .a1 = .{ 0.5, 0 },
            .a2 = .{ 1, 1 },
            .rect = rect,
            .expectedOut = true,
        },
        .{
            .a1 = .{ 0, 0 },
            .a2 = .{ 0.11, 1 },
            .rect = rect,
            .expectedOut = false,
        },
        .{
            .a1 = .{ -0.5, 0.5 },
            .a2 = .{ 0.5, -0.5 },
            .rect = rect,
            .expectedOut = false,
        },
        .{
            .a1 = .{ -0.5, 0.5 },
            .a2 = .{ 0.5, -0.5 },
            .rect = .{
                .min = .{ 0, 0 },
                .max = .{ 1, 1 },
            },
            .expectedOut = true, // glancing hit
        },
        .{
            // Both inside
            .a1 = .{ 0.4, 0.4 },
            .a2 = .{ 0.6, 0.6 },
            .rect = rect,
            .expectedOut = false,
        },
    };
    for (CASES, 0..) |c, i| {
        // var int: V2 = undefined;
        const out = lineRectIntersection(c.a1, c.a2, c.rect);
        if (out != c.expectedOut) {
            std.log.err("{}: {}", .{ i, c });
            return error.Mismatch;
        }
    }
}

test "ray plane intersection" {
    const hit = rayPlaneIntersection(
        .{
            .origin = .{ 1.0, 2.0, 3.0 },
            .dir = .{ 2.0, 1.0, -1.0 },
        },
        .{ 0.0, 6.0, 0.0 },
        .{ 0.0, 2.0, 0.0 },
    ) orelse return error.ExpectedIntersection;
    try std.testing.expectEqual(@as(V3, .{ 9.0, 6.0, -1.0 }), hit);

    try std.testing.expect(rayPlaneIntersection(
        .{
            .origin = .{ 0.0, 0.0, 0.0 },
            .dir = .{ 1.0, 0.0, 0.0 },
        },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
    ) == null);

    try std.testing.expect(rayPlaneIntersection(
        .{
            .origin = .{ 0.0, 0.0, 0.0 },
            .dir = .{ 0.0, 0.0, 1.0 },
        },
        .{ 0.0, 0.0, -1.0 },
        .{ 0.0, 0.0, 1.0 },
    ) == null);
}

test "matrix inverse" {
    const matrix = multiply(
        perspective(std.math.degreesToRadians(45.0), 16.0 / 9.0, 0.1, 100.0),
        multiply(translation(.{ 1.0, -2.0, -8.0 }), rotationXYZ(.{ 0.2, -0.4, 0.1 })),
    );
    const product = multiply(matrix, inverse(matrix) orelse return error.ExpectedInverse);
    const expected = identity();
    for (product, expected) |actual, wanted| {
        try std.testing.expectApproxEqAbs(wanted, actual, 0.0001);
    }
}

test "cross product is perpendicular to both inputs" {
    const a: V3 = .{ 0.2, -0.7, 1.1 };
    const b: V3 = .{ 1.3, 0.4, -0.5 };
    const result = cross3(a, b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot(3, result, a), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot(3, result, b), 0.0001);
}

test "Euler position derivatives match finite differences" {
    const parent = multiply(translation(.{ 0.7, -0.2, 1.1 }), multiply(rotationY(0.31), rotationX(-0.27)));
    const radians: V3 = .{ 0.43, -0.52, 0.68 };
    const localPoint: V3 = .{ 0.8, -0.3, 0.2 };
    const jointPosition = transformPoint(parent, zero(3));
    const worldPoint = transformPoint(multiply(parent, rotationXYZ(radians)), localPoint);
    const axes = rotationXYZRingAxes(parent, radians);
    const epsilon: f32 = 0.001;

    for (0..3) |axis| {
        var beforeAngles = radians;
        var afterAngles = radians;
        beforeAngles[axis] -= epsilon;
        afterAngles[axis] += epsilon;
        const before = transformPoint(multiply(parent, rotationXYZ(beforeAngles)), localPoint);
        const after = transformPoint(multiply(parent, rotationXYZ(afterAngles)), localPoint);
        const finiteDifference = (after - before) / splat(3, epsilon * 2.0);
        const analytical = rotationPositionDerivative(axes[axis], jointPosition, worldPoint);
        for (0..3) |i| {
            try std.testing.expectApproxEqAbs(analytical[i], finiteDifference[i], 0.0002);
        }
    }
}

test "solve 3x3 linear system" {
    const solution = solveLinear3(
        .{
            .{ 3.0, 2.0, -1.0 },
            .{ 2.0, -2.0, 4.0 },
            .{ -1.0, 0.5, -1.0 },
        },
        .{ 1.0, -2.0, 0.0 },
    ) orelse return error.ExpectedSolution;
    const expected: V3 = .{ 1.0, -2.0, -2.0 };
    for (0..3) |i| {
        try std.testing.expectApproxEqAbs(expected[i], solution[i], 0.0001);
    }
}

test "screen axis drag projects mouse motion onto world axis" {
    const screenSize: V2 = .{ 100.0, 100.0 };
    const distance = screenAxisDragDistance(
        identity(),
        zero(3),
        .{ 1.0, 0.0, 0.0 },
        0.5,
        screenSize,
        .{ 10.0, 6.0 },
    );
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), distance, 0.0001);

    const perpendicular = screenAxisDragDistance(
        identity(),
        zero(3),
        .{ 1.0, 0.0, 0.0 },
        0.5,
        screenSize,
        .{ 0.0, 10.0 },
    );
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), perpendicular, 0.0001);
}
