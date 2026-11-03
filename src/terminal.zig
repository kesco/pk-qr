// SPDX-License-Identifier: GPL-3.0-or-later
//! 终端渲染：彩色模式用半块字符（一个字符格 = 上下两个模块），
//! 无色模式用 `██`/空格（一个模块两个字符宽），细节见 docs/design.md 第 7 节。

const std = @import("std");
const qr = @import("qr.zig");

pub const ColorMode = enum { auto, always, never };

pub const Options = struct {
    border: u8 = 4,
    color: bool = true,
    /// 仅无色模式生效：适配浅色终端。
    invert: bool = false,
};

fn paddedSize(border: u8) usize {
    return qr.size + @as(usize, border) * 2;
}

fn moduleAt(matrix: *const qr.Matrix, border: usize, x: usize, y: usize) bool {
    if (x < border or y < border) return false;
    const mx = x - border;
    const my = y - border;
    if (mx >= qr.size or my >= qr.size) return false;
    return matrix.modules[my][mx];
}

pub fn write(writer: *std.Io.Writer, matrix: *const qr.Matrix, opts: Options) !void {
    if (opts.color) {
        try writeHalfBlocks(writer, matrix, opts.border);
    } else {
        try writeBlocks(writer, matrix, opts.border, opts.invert);
    }
}

fn writeHalfBlocks(writer: *std.Io.Writer, matrix: *const qr.Matrix, border: u8) !void {
    const padded = paddedSize(border);
    const border_px = @as(usize, border);

    var y: usize = 0;
    while (y < padded) : (y += 2) {
        var state_fg_dark: ?bool = null;
        var state_bg_dark: ?bool = null;
        var x: usize = 0;
        while (x < padded) : (x += 1) {
            const top = moduleAt(matrix, border_px, x, y);
            const bottom = if (y + 1 < padded) moduleAt(matrix, border_px, x, y + 1) else false;
            if (state_fg_dark != top or state_bg_dark != bottom) {
                try writer.print("\x1b[{s};{s}m", .{
                    if (top) "30" else "37",
                    if (bottom) "40" else "47",
                });
                state_fg_dark = top;
                state_bg_dark = bottom;
            }
            try writer.writeAll("\u{2580}");
        }
        try writer.writeAll("\x1b[0m\n");
    }
}

fn writeBlocks(writer: *std.Io.Writer, matrix: *const qr.Matrix, border: u8, invert: bool) !void {
    const padded = paddedSize(border);
    const border_px = @as(usize, border);

    for (0..padded) |y| {
        for (0..padded) |x| {
            const dark = moduleAt(matrix, border_px, x, y) != invert;
            try writer.writeAll(if (dark) "\u{2588}\u{2588}" else "  ");
        }
        try writer.writeAll("\n");
    }
}

// --------------------------------------------------------------------- 测试

fn render(gpa: std.mem.Allocator, matrix: *const qr.Matrix, opts: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try write(&out.writer, matrix, opts);
    return out.toOwnedSlice();
}

fn testMatrix() qr.Matrix {
    const pentax = @import("pentax.zig");
    const payload = pentax.payload(pentax.modelInfo(.k1ii), pentax.features[0], "1234567");
    return qr.encode(&payload);
}

test "半块模式是 45 列 23 行" {
    const gpa = std.testing.allocator;
    const matrix = testMatrix();
    const text = try render(gpa, &matrix, .{ .color = true });
    defer gpa.free(text);

    var lines: usize = 0;
    var columns: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (!std.mem.endsWith(u8, line, "\x1b[0m")) return error.MissingReset;
        lines += 1;
        var glyphs: usize = 0;
        var view = std.unicode.Utf8View.init(line) catch return error.InvalidUtf8;
        var cp_it = view.iterator();
        while (cp_it.nextCodepoint()) |cp| {
            if (cp == 0x2580) glyphs += 1;
        }
        if (columns == 0) columns = glyphs;
        try std.testing.expectEqual(columns, glyphs);
    }
    try std.testing.expectEqual(@as(usize, 23), lines);
    try std.testing.expectEqual(@as(usize, 45), columns);
}

test "无色模式是 45 行 90 列且不残留转义" {
    const gpa = std.testing.allocator;
    const matrix = testMatrix();
    const text = try render(gpa, &matrix, .{ .color = false });
    defer gpa.free(text);

    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        const columns = try std.unicode.utf8CountCodepoints(line);
        try std.testing.expectEqual(@as(usize, 90), columns);
    }
    try std.testing.expectEqual(@as(usize, 45), lines);
}

test "invert 只影响无色模式且确实翻转" {
    const gpa = std.testing.allocator;
    const matrix = testMatrix();
    const normal = try render(gpa, &matrix, .{ .color = false, .invert = false });
    defer gpa.free(normal);
    const inverted = try render(gpa, &matrix, .{ .color = false, .invert = true });
    defer gpa.free(inverted);
    try std.testing.expect(!std.mem.eql(u8, normal, inverted));

    const colored = try render(gpa, &matrix, .{ .color = true, .invert = true });
    defer gpa.free(colored);
    const plain = try render(gpa, &matrix, .{ .color = true, .invert = false });
    defer gpa.free(plain);
    try std.testing.expectEqualSlices(u8, plain, colored);
}

test "静区在彩色模式下是白色背景" {
    const gpa = std.testing.allocator;
    const matrix = testMatrix();
    const text = try render(gpa, &matrix, .{ .color = true });
    defer gpa.free(text);
    // 第一行第一个字符格：上、下均为静区 → 前景白(37)、背景白(47)。
    try std.testing.expect(std.mem.startsWith(u8, text, "\x1b[37;47m"));
}
