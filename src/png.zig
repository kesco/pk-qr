// SPDX-License-Identifier: GPL-3.0-or-later
//! 1-bit 灰度 PNG 写出器：白底、静区、无时间戳，输出确定。
//! 分块与压缩细节见 docs/design.md 第 6 节。

const std = @import("std");
const qr = @import("qr.zig");

pub const Options = struct {
    /// 每个模块的像素边长。
    scale: u8 = 12,
    /// 静区宽度（模块数）。
    border: u8 = 4,
};

/// 输出边长（像素）：(37 + 2*border) * scale，默认 540。
pub fn imageSize(opts: Options) usize {
    return (qr.size + @as(usize, opts.border) * 2) * opts.scale;
}

fn moduleIndex(pixel: usize, opts: Options) ?usize {
    const border_px = @as(usize, opts.border) * opts.scale;
    if (pixel < border_px) return null;
    const index = (pixel - border_px) / opts.scale;
    if (index >= qr.size) return null;
    return index;
}

fn compressZlib(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    errdefer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&out.writer, &window, .zlib, .default);
    try compressor.writer.writeAll(input);
    try compressor.finish();
    return out.toOwnedSlice();
}

fn appendChunk(list: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: []const u8, data: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try list.appendSlice(gpa, &length);
    try list.appendSlice(gpa, kind);
    try list.appendSlice(gpa, data);

    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try list.appendSlice(gpa, &crc_bytes);
}

/// 生成完整 PNG 字节，调用方负责释放。
pub fn encode(gpa: std.mem.Allocator, matrix: *const qr.Matrix, opts: Options) ![]u8 {
    const dim = imageSize(opts);
    const row_bytes = (dim + 7) / 8;

    var raw = try std.ArrayList(u8).initCapacity(gpa, (row_bytes + 1) * dim);
    defer raw.deinit(gpa);

    for (0..dim) |py| {
        try raw.append(gpa, 0); // 过滤类型：None
        const row_start = raw.items.len;
        try raw.appendNTimes(gpa, 0xFF, row_bytes);
        if (dim % 8 != 0) {
            raw.items[row_start + row_bytes - 1] &= @as(u8, 0xFF) << @intCast(8 - dim % 8);
        }
        const my = moduleIndex(py, opts) orelse continue;
        for (0..dim) |px| {
            const mx = moduleIndex(px, opts) orelse continue;
            if (matrix.modules[my][mx]) {
                // 灰度 0 = 黑；暗模块清位。
                raw.items[row_start + px / 8] &= ~(@as(u8, 1) << @intCast(7 - px % 8));
            }
        }
    }

    const compressed = try compressZlib(gpa, raw.items);
    defer gpa.free(compressed);

    var png = try std.ArrayList(u8).initCapacity(gpa, compressed.len + 128);
    errdefer png.deinit(gpa);

    try png.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(dim), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(dim), .big);
    ihdr[8] = 1; // bit depth
    ihdr[9] = 0; // color type: 灰度
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try appendChunk(&png, gpa, "IHDR", &ihdr);
    try appendChunk(&png, gpa, "IDAT", compressed);
    try appendChunk(&png, gpa, "IEND", &.{});

    return png.toOwnedSlice(gpa);
}

// --------------------------------------------------------------------- 测试

fn inflate(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&reader, .zlib, &window);
    return decompressor.reader.allocRemaining(gpa, .unlimited);
}

/// 读取第 index 个分块的长度、类型与数据偏移。
const Chunk = struct { kind: [4]u8, data: []const u8 };

fn chunkAt(png: []const u8, index: usize) Chunk {
    var offset: usize = 8;
    var current: usize = 0;
    while (offset + 8 <= png.len) {
        const length = std.mem.readInt(u32, png[offset..][0..4], .big);
        const kind: [4]u8 = png[offset + 4 ..][0..4].*;
        const data = png[offset + 8 ..][0..length];
        if (current == index) return .{ .kind = kind, .data = data };
        offset += 12 + length;
        current += 1;
    }
    unreachable;
}

test "PNG 结构与 IHDR 字段" {
    const gpa = std.testing.allocator;
    const payload = @import("pentax.zig").payload(
        @import("pentax.zig").modelInfo(.k1ii),
        @import("pentax.zig").features[0],
        "0012345",
    );
    const matrix = qr.encode(&payload);
    const png = try encode(gpa, &matrix, .{});
    defer gpa.free(png);

    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A }, png[0..8]);

    const ihdr = chunkAt(png, 0);
    try std.testing.expectEqualSlices(u8, "IHDR", &ihdr.kind);
    try std.testing.expectEqual(@as(u32, 540), std.mem.readInt(u32, ihdr.data[0..4], .big));
    try std.testing.expectEqual(@as(u32, 540), std.mem.readInt(u32, ihdr.data[4..8], .big));
    try std.testing.expectEqual(@as(u8, 1), ihdr.data[8]);
    try std.testing.expectEqual(@as(u8, 0), ihdr.data[9]);

    const idat = chunkAt(png, 1);
    try std.testing.expectEqualSlices(u8, "IDAT", &idat.kind);
    const iend = chunkAt(png, 2);
    try std.testing.expectEqualSlices(u8, "IEND", &iend.kind);
    try std.testing.expectEqual(@as(usize, 0), iend.data.len);
}

test "扫描行数量、静区为白、模块位置正确" {
    const gpa = std.testing.allocator;
    const payload = @import("pentax.zig").payload(
        @import("pentax.zig").modelInfo(.k3iii),
        @import("pentax.zig").features[2],
        "12345678901234567890",
    );
    const matrix = qr.encode(&payload);
    const opts: Options = .{ .scale = 3, .border = 2 };
    const png = try encode(gpa, &matrix, opts);
    defer gpa.free(png);

    const dim = imageSize(opts);
    const row_bytes = (dim + 7) / 8;
    const idat = chunkAt(png, 1);
    const raw = try inflate(gpa, idat.data);
    defer gpa.free(raw);
    try std.testing.expectEqual((row_bytes + 1) * dim, raw.len);

    const sample = struct {
        fn isDark(raw_bytes: []const u8, row_bytes_: usize, x: usize, y: usize) bool {
            const row_start = y * (row_bytes_ + 1) + 1;
            return (raw_bytes[row_start + x / 8] >> @intCast(7 - x % 8)) & 1 == 0;
        }
    };

    // 静区（左上角与右下角）必须全白。
    try std.testing.expect(!sample.isDark(raw, row_bytes, 0, 0));
    try std.testing.expect(!sample.isDark(raw, row_bytes, dim - 1, dim - 1));

    // 左上定位图案在缩放后的像素位置上应全黑。
    const border_px = @as(usize, opts.border) * opts.scale;
    try std.testing.expect(sample.isDark(raw, row_bytes, border_px, border_px));
    try std.testing.expect(sample.isDark(raw, row_bytes, border_px + 1, border_px + 1));
    try std.testing.expect(!sample.isDark(raw, row_bytes, border_px + 3, border_px + 3));
    // (5,3) 的亮模块。
    try std.testing.expect(!sample.isDark(raw, row_bytes, border_px + 3 * 3 + 1, border_px + 5 * 3 + 1));
}

test "相同输入产出相同字节" {
    const gpa = std.testing.allocator;
    const payload = @import("pentax.zig").payload(
        @import("pentax.zig").modelInfo(.k1),
        @import("pentax.zig").features[3],
        "1234567",
    );
    const matrix = qr.encode(&payload);
    const a = try encode(gpa, &matrix, .{});
    defer gpa.free(a);
    const b = try encode(gpa, &matrix, .{});
    defer gpa.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}
