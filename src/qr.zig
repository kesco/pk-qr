// SPDX-License-Identifier: GPL-3.0-or-later
//! Version 5 / 纠错等级 L / 字节模式的二维码矩阵编码器。
//! 只实现这一种组合：37×37、单块、106 数据码字 + 28 纠错码字。
//! 规范与图形参数见 docs/protocol.md 第 4 节；本文件不接触 I/O。

const std = @import("std");
const pentax = @import("pentax.zig");

pub const version: u8 = 5;
pub const size: usize = 37;
pub const data_codewords: usize = 106;
pub const ecc_codewords: usize = 28;
pub const total_codewords: usize = 134;
pub const total_bits: usize = total_codewords * 8;

/// 纠错等级 L 在格式信息中的 2 位编码。
pub const ecc_level_bits: u3 = 1;

pub const Matrix = struct {
    modules: [size][size]bool = @splat(@splat(false)),
    /// 功能图案（定位、定时、对齐、格式信息、暗模块）占用的位置。
    is_function: [size][size]bool = @splat(@splat(false)),

    pub fn get(m: *const Matrix, x: usize, y: usize) bool {
        return m.modules[y][x];
    }
};

pub const FormatInfo = struct {
    ecc_bits: u3,
    mask: u3,
};

/// 按惩罚分选掩码，返回最终矩阵。
pub fn encode(payload: *const pentax.Payload) Matrix {
    var best: Matrix = undefined;
    var best_penalty: u32 = std.math.maxInt(u32);
    var mask: u3 = 0;
    while (true) : (mask += 1) {
        const candidate = encodeWithMask(payload, mask);
        const score = penalty(&candidate);
        if (score < best_penalty) {
            best_penalty = score;
            best = candidate;
        }
        if (mask == 7) break;
    }
    return best;
}

pub fn encodeWithMask(payload: *const pentax.Payload, mask: u3) Matrix {
    var m = Matrix{};
    const codewords = codewordsFor(payload);
    drawFunctionPatterns(&m, mask);
    drawCodewords(&m, &codewords);
    applyMask(&m, mask);
    return m;
}

// ---------------------------------------------------------------- 位流与码字

fn appendBits(out: []u8, bit_len: *usize, value: u32, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const shift: u5 = @intCast(count - 1 - i);
        if ((value >> shift) & 1 != 0) {
            const pos = bit_len.*;
            out[pos / 8] |= @as(u8, 1) << @intCast(7 - pos % 8);
        }
        bit_len.* += 1;
    }
}

/// 字节模式：`0100` + 8 位长度 + 64 字节，随后终止符与填充字节。
fn codewordsFor(payload: *const pentax.Payload) [total_codewords]u8 {
    var out: [total_codewords]u8 = @splat(0);
    var bit_len: usize = 0;

    appendBits(&out, &bit_len, 0b0100, 4);
    appendBits(&out, &bit_len, payload.len, 8);
    for (payload) |ch| appendBits(&out, &bit_len, ch, 8);

    const capacity_bits = data_codewords * 8;
    const terminator = @min(@as(usize, 4), capacity_bits - bit_len);
    appendBits(&out, &bit_len, 0, terminator);
    while (bit_len % 8 != 0) appendBits(&out, &bit_len, 0, 1);

    var pad: u8 = 0xEC;
    while (bit_len < capacity_bits) {
        appendBits(&out, &bit_len, pad, 8);
        pad = if (pad == 0xEC) 0x11 else 0xEC;
    }

    const ecc = rsRemainder(out[0..data_codewords], ecc_codewords);
    @memcpy(out[data_codewords..], &ecc);
    return out;
}

fn gfMul(a_in: u8, b: u8) u8 {
    var a = a_in;
    var product: u8 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if ((b >> @intCast(i)) & 1 != 0) product ^= a;
        const high = a & 0x80;
        a <<= 1;
        if (high != 0) a ^= 0x1D;
    }
    return product;
}

fn rsDivisor(comptime degree: usize) [degree]u8 {
    var result: [degree]u8 = @splat(0);
    result[degree - 1] = 1;
    var root: u8 = 1;
    for (0..degree) |_| {
        for (0..degree) |j| {
            result[j] = gfMul(result[j], root);
            if (j + 1 < degree) result[j] ^= result[j + 1];
        }
        root = gfMul(root, 0x02);
    }
    return result;
}

fn rsRemainder(data: []const u8, comptime degree: usize) [degree]u8 {
    const divisor = comptime blk: {
        @setEvalBranchQuota(200_000);
        break :blk rsDivisor(degree);
    };
    var rem: [degree]u8 = @splat(0);
    for (data) |byte| {
        const factor = byte ^ rem[0];
        var i: usize = 0;
        while (i + 1 < degree) : (i += 1) rem[i] = rem[i + 1];
        rem[degree - 1] = 0;
        for (0..degree) |j| rem[j] ^= gfMul(divisor[j], factor);
    }
    return rem;
}

// ------------------------------------------------------------------ 功能图案

fn setFunction(m: *Matrix, x: usize, y: usize, dark: bool) void {
    m.modules[y][x] = dark;
    m.is_function[y][x] = true;
}

fn drawFinder(m: *Matrix, cx: isize, cy: isize) void {
    var dy: isize = -4;
    while (dy <= 4) : (dy += 1) {
        var dx: isize = -4;
        while (dx <= 4) : (dx += 1) {
            const x = cx + dx;
            const y = cy + dy;
            if (x < 0 or y < 0 or x >= size or y >= size) continue;
            const distance = @max(@abs(dx), @abs(dy));
            setFunction(m, @intCast(x), @intCast(y), distance != 2 and distance != 4);
        }
    }
}

fn drawAlignment(m: *Matrix, cx: usize, cy: usize) void {
    var dy: isize = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: isize = -2;
        while (dx <= 2) : (dx += 1) {
            const distance = @max(@abs(dx), @abs(dy));
            setFunction(
                m,
                @intCast(@as(isize, @intCast(cx)) + dx),
                @intCast(@as(isize, @intCast(cy)) + dy),
                distance != 1,
            );
        }
    }
}

fn bitAt(bits: u15, index: usize) bool {
    return (bits >> @intCast(index)) & 1 != 0;
}

/// 5 位数据（纠错等级 + 掩码）经 BCH(15,5) 生成，异或 0x5412。
pub fn formatBits(mask: u3) u15 {
    const data: u15 = (@as(u15, ecc_level_bits) << 3) | mask;
    var rem: u15 = data;
    for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return ((data << 10) | rem) ^ 0x5412;
}

fn drawFormatBits(m: *Matrix, mask: u3) void {
    const bits = formatBits(mask);

    for (0..6) |i| setFunction(m, 8, i, bitAt(bits, i));
    setFunction(m, 8, 7, bitAt(bits, 6));
    setFunction(m, 8, 8, bitAt(bits, 7));
    setFunction(m, 7, 8, bitAt(bits, 8));
    var i: usize = 9;
    while (i < 15) : (i += 1) setFunction(m, 14 - i, 8, bitAt(bits, i));

    for (0..8) |j| setFunction(m, size - 1 - j, 8, bitAt(bits, j));
    i = 8;
    while (i < 15) : (i += 1) setFunction(m, 8, size - 15 + i, bitAt(bits, i));

    // 暗模块
    setFunction(m, 8, size - 8, true);
}

fn drawFunctionPatterns(m: *Matrix, mask: u3) void {
    for (0..size) |i| {
        setFunction(m, 6, i, i % 2 == 0);
        setFunction(m, i, 6, i % 2 == 0);
    }
    drawFinder(m, 3, 3);
    drawFinder(m, size - 4, 3);
    drawFinder(m, 3, size - 4);
    // 版本 5 的对齐图案中心集合 {6, 30}，去掉与定位图案重叠后只剩 (30,30)。
    drawAlignment(m, 30, 30);
    drawFormatBits(m, mask);
}

// ------------------------------------------------------------------ 数据放置

fn maskBit(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (y / 2 + x / 3) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        else => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
    };
}

fn applyMask(m: *Matrix, mask: u3) void {
    for (0..size) |y| {
        for (0..size) |x| {
            if (m.is_function[y][x]) continue;
            if (maskBit(mask, x, y)) m.modules[y][x] = !m.modules[y][x];
        }
    }
}

fn drawCodewords(m: *Matrix, codewords: *const [total_codewords]u8) void {
    var bit_index: usize = 0;
    var right: isize = size - 1;
    while (right >= 1) : (right -= 2) {
        if (right == 6) right = 5;
        const right_u: usize = @intCast(right);
        const upward = ((right_u + 1) & 2) == 0;
        for (0..size) |vert| {
            const y = if (upward) size - 1 - vert else vert;
            for (0..2) |j| {
                const x = right_u - j;
                if (m.is_function[y][x]) continue;
                var dark = false;
                if (bit_index < total_bits) {
                    const byte = codewords[bit_index / 8];
                    dark = (byte >> @intCast(7 - bit_index % 8)) & 1 != 0;
                    bit_index += 1;
                }
                m.modules[y][x] = dark;
            }
        }
    }
}

// ------------------------------------------------------------------ 惩罚评分

fn penalty(m: *const Matrix) u32 {
    var result: u32 = 0;

    // 规则 1：行/列中 5 个以上连续同色。
    for (0..size) |y| {
        var run: u32 = 1;
        for (1..size) |x| {
            if (m.modules[y][x] == m.modules[y][x - 1]) {
                run += 1;
                if (run == 5) {
                    result += 3;
                } else if (run > 5) {
                    result += 1;
                }
            } else {
                run = 1;
            }
        }
    }
    for (0..size) |x| {
        var run: u32 = 1;
        for (1..size) |y| {
            if (m.modules[y][x] == m.modules[y - 1][x]) {
                run += 1;
                if (run == 5) {
                    result += 3;
                } else if (run > 5) {
                    result += 1;
                }
            } else {
                run = 1;
            }
        }
    }

    // 规则 2：2×2 同色块。
    for (0..size - 1) |y| {
        for (0..size - 1) |x| {
            const c = m.modules[y][x];
            if (c == m.modules[y][x + 1] and c == m.modules[y + 1][x] and c == m.modules[y + 1][x + 1]) {
                result += 3;
            }
        }
    }

    // 规则 3：类似定位图案的 1:1:3:1:1 序列。
    const pattern_a: u11 = 0b10111010000;
    const pattern_b: u11 = 0b00001011101;
    for (0..size) |y| {
        var window: u11 = 0;
        for (0..size) |x| {
            window = ((window << 1) | @intFromBool(m.modules[y][x])) & 0x7FF;
            if (x >= 10 and (window == pattern_a or window == pattern_b)) result += 40;
        }
    }
    for (0..size) |x| {
        var window: u11 = 0;
        for (0..size) |y| {
            window = ((window << 1) | @intFromBool(m.modules[y][x])) & 0x7FF;
            if (y >= 10 and (window == pattern_a or window == pattern_b)) result += 40;
        }
    }

    // 规则 4：暗模块比例偏离 50%，每 5% 记 10 分。
    var dark: u32 = 0;
    for (0..size) |y| {
        for (0..size) |x| dark += @intFromBool(m.modules[y][x]);
    }
    const total: u32 = size * size;
    const deviation = if (dark * 20 > total * 10) dark * 20 - total * 10 else total * 10 - dark * 20;
    result += (deviation / total) * 10;

    return result;
}

// -------------------------------------------------------------- 读回（测试用）

/// 从矩阵读回格式信息（逆序执行 drawFormatBits）。
pub fn readFormatInfo(m: *const Matrix) FormatInfo {
    var bits: u15 = 0;
    for (0..6) |i| {
        if (m.modules[i][8]) bits |= @as(u15, 1) << @intCast(i);
    }
    if (m.modules[7][8]) bits |= @as(u15, 1) << 6;
    if (m.modules[8][8]) bits |= @as(u15, 1) << 7;
    if (m.modules[8][7]) bits |= @as(u15, 1) << 8;
    var i: usize = 9;
    while (i < 15) : (i += 1) {
        if (m.modules[8][14 - i]) bits |= @as(u15, 1) << @intCast(i);
    }
    const info: u5 = @intCast(((bits ^ 0x5412) >> 10) & 0x1f);
    return .{
        .ecc_bits = @intCast((info >> 3) & 0x3),
        .mask = @intCast(info & 0x7),
    };
}

/// 去掉掩码后按之字形顺序读回 134 个码字。
pub fn readCodewords(m: *const Matrix, mask: u3) [total_codewords]u8 {
    var out: [total_codewords]u8 = @splat(0);
    var bit_index: usize = 0;
    var right: isize = size - 1;
    while (right >= 1) : (right -= 2) {
        if (right == 6) right = 5;
        const right_u: usize = @intCast(right);
        const upward = ((right_u + 1) & 2) == 0;
        for (0..size) |vert| {
            const y = if (upward) size - 1 - vert else vert;
            for (0..2) |j| {
                const x = right_u - j;
                if (m.is_function[y][x]) continue;
                if (bit_index >= total_bits) continue;
                const dark = m.modules[y][x] != maskBit(mask, x, y);
                if (dark) out[bit_index / 8] |= @as(u8, 1) << @intCast(7 - bit_index % 8);
                bit_index += 1;
            }
        }
    }
    return out;
}

/// 从码字流按位读取，供测试解析位流。
fn readBits(codewords: []const u8, start: usize, count: usize) u32 {
    var value: u32 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const pos = start + i;
        const bit: u32 = @intFromBool((codewords[pos / 8] >> @intCast(7 - pos % 8)) & 1 != 0);
        value = (value << 1) | bit;
    }
    return value;
}

// --------------------------------------------------------------------- 测试

test "格式信息与已知 L 级码表一致" {
    const expected = [_]u15{ 0x77C4, 0x72F3, 0x7DAA, 0x789D, 0x662F, 0x6318, 0x6C41, 0x6976 };
    for (expected, 0..) |bits, mask_index| {
        const mask: u3 = @intCast(mask_index);
        try std.testing.expectEqual(bits, formatBits(mask));
    }
}

test "格式信息读回与写入一致" {
    const payload = pentax.payload(
        pentax.modelInfo(.k1ii),
        pentax.features[0],
        "1234567",
    );
    var mask_index: u3 = 0;
    while (true) : (mask_index += 1) {
        const m = encodeWithMask(&payload, mask_index);
        const info = readFormatInfo(&m);
        try std.testing.expectEqual(mask_index, info.mask);
        try std.testing.expectEqual(ecc_level_bits, info.ecc_bits);
        if (mask_index == 7) break;
    }
}

test "功能图案位置" {
    const payload = pentax.payload(
        pentax.modelInfo(.k3iii),
        pentax.features[3],
        "0012345",
    );
    const m = encodeWithMask(&payload, 0);

    // 三个定位图案的角点。
    for ([_][2]usize{ .{ 0, 0 }, .{ size - 1, 0 }, .{ 0, size - 1 } }) |corner| {
        const x = corner[0];
        const y = corner[1];
        try std.testing.expect(m.modules[y][x]);
    }
    // 7×7 同心结构：外环暗、第二环亮、3×3 暗，最外圈为亮分隔符。
    try std.testing.expect(m.modules[0][0]);
    try std.testing.expect(!m.modules[1][1]);
    try std.testing.expect(m.modules[2][2]);
    try std.testing.expect(!m.modules[5][3]);
    try std.testing.expect(m.modules[6][6]);
    try std.testing.expect(!m.modules[7][7]);

    // 定时图案：第 6 行/列交替。
    for (8..29) |i| {
        try std.testing.expectEqual(i % 2 == 0, m.modules[6][i]);
        try std.testing.expectEqual(i % 2 == 0, m.modules[i][6]);
    }

    // 唯一对齐图案中心 (30,30) 为暗，±1 为亮，±2 为暗。
    try std.testing.expect(m.modules[30][30]);
    try std.testing.expect(!m.modules[30][29]);
    try std.testing.expect(m.modules[30][28]);
    try std.testing.expect(m.modules[28][28]);

    // 暗模块固定在 (8, 29)。
    try std.testing.expect(m.modules[size - 8][8]);
}

test "码字读回并解析回 payload" {
    const vectors = @import("vectors.zig");
    for (vectors.all) |vector| {
        const model = std.meta.stringToEnum(pentax.Model, vector.model).?;
        const info = pentax.modelInfo(model);
        const serial = try pentax.normalizeSerial(vector.serial);
        for (info.features, 0..) |feature, index| {
            const payload = pentax.payload(info, feature, serial);
            const m = encode(&payload);
            const info_read = readFormatInfo(&m);
            const codewords = readCodewords(&m, info_read.mask);

            // 模式 0100 + 8 位长度 64 + 64 字节 ASCII。
            try std.testing.expectEqual(@as(u8, 0b0100), readBits(&codewords, 0, 4));
            const length: usize = readBits(&codewords, 4, 8);
            try std.testing.expectEqual(@as(usize, 64), length);

            var decoded: [64]u8 = undefined;
            for (&decoded, 0..) |*slot, i| {
                slot.* = @intCast(readBits(&codewords, 12 + i * 8, 8));
            }
            try std.testing.expectEqualStrings(vector.payloads[index], &decoded);
            try std.testing.expectEqualStrings(&payload, &decoded);
        }
    }
}

test "编码确定性" {
    const payload = pentax.payload(
        pentax.modelInfo(.k1ii),
        pentax.features[1],
        "12345678901234567890",
    );
    const a = encode(&payload);
    const b = encode(&payload);
    try std.testing.expectEqualDeep(a, b);
}
