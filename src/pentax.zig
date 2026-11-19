// SPDX-License-Identifier: GPL-3.0-or-later
//! 宾得功能二维码的内容推导：机型/功能表、序列号规范化、payload 计算。
//! 规范见 docs/protocol.md，本文件不接触 I/O。

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Model = enum { k1, k1ii, k3iii, k3iiim };

pub const Feature = struct {
    id: u32,
    name: []const u8,
    slug: []const u8,
};

/// K-1 与 K-1 II 共用这四项功能 ID。
pub const features: [4]Feature = .{
    .{ .id = 2, .name = "渐变 ND", .slug = "gradient-nd" },
    .{ .id = 11, .name = "星点自动对焦", .slug = "star-autofocus" },
    .{ .id = 14, .name = "遥控对焦微动", .slug = "remote-focus-step" },
    .{ .id = 17, .name = "星空影像处理", .slug = "astro-processing" },
};

/// K-3 III 的功能 ID 与显示名一一对应，但数值不同。
pub const features_k3iii: [4]Feature = .{
    .{ .id = 28, .name = "渐变 ND", .slug = "gradient-nd" },
    .{ .id = 31, .name = "星点自动对焦", .slug = "star-autofocus" },
    .{ .id = 34, .name = "遥控对焦微动", .slug = "remote-focus-step" },
    .{ .id = 37, .name = "星空影像处理", .slug = "astro-processing" },
};

pub const ModelInfo = struct {
    model: Model,
    name: []const u8,
    /// 参与机型哈希的 32 位机型值。
    word: u32,
    file_prefix: []const u8,
    features: [4]Feature,
};

pub fn modelInfo(model: Model) ModelInfo {
    return switch (model) {
        .k1ii => .{ .model = .k1ii, .name = "K-1 II", .word = 78400, .file_prefix = "K1II", .features = features },
        .k1 => .{ .model = .k1, .name = "K-1", .word = 77970, .file_prefix = "K1", .features = features },
        .k3iii => .{ .model = .k3iii, .name = "K-3 III", .word = 78420, .file_prefix = "K3III", .features = features_k3iii },
        .k3iiim => .{ .model = .k3iiim, .name = "K-3 III Monochrome", .word = 78550, .file_prefix = "K3IIIM", .features = features_k3iii },
    };
}

pub const max_serial_len = 20;
/// 附加迭代次数；合并哈希之外再迭代这么多次，总计 5656 次。
pub const hash_rounds: usize = 0x1617;
pub const model_salt = "g05gdn4z621s33z2woiyxny0ehj2qh2a";
pub const feature_salt = "pcig9piz9825bd2iz0j4oe2tszkefde5";
pub const serial_salt = "urj4rwz08lyr637pzabdu8pvdo995hbs";

/// 64 个小写 ASCII 十六进制字符。
pub const Payload = [64]u8;

pub const SerialError = error{InvalidSerial};

/// 与 Python `str.strip()` 相同的空白集合。
fn isSpaceCp(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

const Codepoint = struct { cp: u21, len: usize };

fn codepointAt(bytes: []const u8, pos: usize) SerialError!Codepoint {
    const len = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch return error.InvalidSerial;
    if (pos + len > bytes.len) return error.InvalidSerial;
    const cp = std.unicode.utf8Decode(bytes[pos..][0..len]) catch return error.InvalidSerial;
    return .{ .cp = cp, .len = len };
}

/// 去掉首尾空白后要求 1–20 个 ASCII 数字；前导零保留。
pub fn normalizeSerial(input: []const u8) SerialError![]const u8 {
    var pos: usize = 0;
    var first: ?usize = null;
    var last_end: usize = 0;
    while (pos < input.len) {
        const c = try codepointAt(input, pos);
        if (!isSpaceCp(c.cp)) {
            if (first == null) first = pos;
            last_end = pos + c.len;
        }
        pos += c.len;
    }
    const start = first orelse return error.InvalidSerial;
    const serial = input[start..last_end];
    if (serial.len == 0 or serial.len > max_serial_len) return error.InvalidSerial;
    for (serial) |b| {
        if (b < '0' or b > '9') return error.InvalidSerial;
    }
    return serial;
}

fn hashParts(parts: []const []const u8, out: *[32]u8) void {
    var h = Sha256.init(.{});
    for (parts) |part| h.update(part);
    h.final(out);
}

pub fn payload(info: ModelInfo, feature: Feature, serial: []const u8) Payload {
    std.debug.assert(serial.len >= 1 and serial.len <= max_serial_len);

    var serial_bytes: [max_serial_len]u8 = @splat(0);
    @memcpy(serial_bytes[0..serial.len], serial);

    var word_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &word_le, info.word, .little);
    var feature_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &feature_le, feature.id, .little);

    var model_hash: [32]u8 = undefined;
    var feature_hash: [32]u8 = undefined;
    var serial_hash: [32]u8 = undefined;
    hashParts(&.{ model_salt, &word_le }, &model_hash);
    hashParts(&.{ feature_salt, &feature_le }, &feature_hash);
    hashParts(&.{ serial_salt, &serial_bytes }, &serial_hash);

    var digest: [32]u8 = undefined;
    hashParts(&.{ &model_hash, &feature_hash, &serial_hash }, &digest);

    var round: usize = 0;
    while (round < hash_rounds) : (round += 1) {
        var next: [32]u8 = undefined;
        Sha256.hash(&digest, &next, .{});
        digest = next;
    }

    const hex = "0123456789abcdef";
    var out: Payload = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

/// CLI 使用的机型标识（与 `--model` 取值一致）。
pub fn modelSlug(model: Model) []const u8 {
    return @tagName(model);
}

/// 接受功能 ID（十进制）或 slug。
pub fn findFeature(info: ModelInfo, selector: []const u8) ?Feature {
    if (selector.len == 0) return null;
    var all_digits = true;
    for (selector) |b| {
        if (b < '0' or b > '9') {
            all_digits = false;
            break;
        }
    }
    if (all_digits) {
        const id = std.fmt.parseUnsigned(u32, selector, 10) catch return null;
        for (info.features) |feature| {
            if (feature.id == id) return feature;
        }
        return null;
    }
    for (info.features) |feature| {
        if (std.mem.eql(u8, feature.slug, selector)) return feature;
    }
    return null;
}

/// 选择器解析为功能在机型表中的下标，供 `--feature` 去重。
pub fn featureIndex(info: ModelInfo, selector: []const u8) ?usize {
    const target = findFeature(info, selector) orelse return null;
    for (info.features, 0..) |feature, index| {
        if (feature.id == target.id) return index;
    }
    return null;
}

test "模型表与功能表" {
    try std.testing.expectEqual(@as(u32, 78400), modelInfo(.k1ii).word);
    try std.testing.expectEqual(@as(u32, 77970), modelInfo(.k1).word);
    try std.testing.expectEqual(@as(u32, 78420), modelInfo(.k3iii).word);
    try std.testing.expectEqual(@as(u32, 78550), modelInfo(.k3iiim).word);
    try std.testing.expectEqualStrings("K1II", modelInfo(.k1ii).file_prefix);
    try std.testing.expectEqualStrings("K3III", modelInfo(.k3iii).file_prefix);
    try std.testing.expectEqualStrings("K3IIIM", modelInfo(.k3iiim).file_prefix);
    try std.testing.expectEqualSlices(u32, &.{ 2, 11, 14, 17 }, &.{
        modelInfo(.k1).features[0].id, modelInfo(.k1).features[1].id,
        modelInfo(.k1).features[2].id, modelInfo(.k1).features[3].id,
    });
    try std.testing.expectEqualSlices(u32, &.{ 28, 31, 34, 37 }, &.{
        modelInfo(.k3iii).features[0].id, modelInfo(.k3iii).features[1].id,
        modelInfo(.k3iii).features[2].id, modelInfo(.k3iii).features[3].id,
    });
    try std.testing.expectEqualStrings("渐变 ND", modelInfo(.k3iii).features[0].name);
}

test "序列号白名单与边界" {
    try std.testing.expectEqualStrings("0012345", try normalizeSerial(" \t0012345\n"));
    try std.testing.expectEqualStrings("12345", try normalizeSerial("\u{85}\u{1c}12345\u{3000}"));
    try std.testing.expectEqualStrings("0", try normalizeSerial("0"));
    const twenty = "12345678901234567890";
    try std.testing.expectEqualStrings(twenty, try normalizeSerial(twenty));
    try std.testing.expectEqualStrings("0000000", try normalizeSerial("0000000"));
}

test "序列号拒绝表" {
    const bad = [_][]const u8{
        "",            " ",                     "\u{3000}",
        "１２３４５",
        "١٢٣٤٥",
        "12O45",       "12 345",                "-123",
        "../123",      "123456789012345678901", "123\x00",
        "\u{feff}123", "123\n456",              "12,345",
    };
    for (bad) |input| {
        try std.testing.expectError(error.InvalidSerial, normalizeSerial(input));
    }
    // 非法 UTF-8 一律拒绝。
    try std.testing.expectError(error.InvalidSerial, normalizeSerial("123\xff"));
    try std.testing.expectError(error.InvalidSerial, normalizeSerial("\xc3"));
}

test "功能选择接受 ID 与 slug，拒绝其他写法" {
    const info = modelInfo(.k1ii);
    try std.testing.expectEqual(@as(u32, 2), findFeature(info, "2").?.id);
    try std.testing.expectEqual(@as(u32, 17), findFeature(info, "astro-processing").?.id);
    try std.testing.expectEqual(@as(u32, 34), findFeature(modelInfo(.k3iii), "34").?.id);
    try std.testing.expect(findFeature(info, "28") == null);
    try std.testing.expect(findFeature(info, "999") == null);
    try std.testing.expect(findFeature(info, "Gradient-ND") == null);
    try std.testing.expect(findFeature(info, "") == null);
    try std.testing.expect(findFeature(info, "0x02") == null);
}
