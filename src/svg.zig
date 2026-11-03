// SPDX-License-Identifier: GPL-3.0-or-later
//! SVG 写出器：单个 path，白底黑模块，尺寸与 PNG 一致。

const std = @import("std");
const qr = @import("qr.zig");
const png = @import("png.zig");

pub fn write(writer: *std.Io.Writer, matrix: *const qr.Matrix, opts: png.Options) !void {
    const dim = png.imageSize(opts);
    const border_px = @as(usize, opts.border) * opts.scale;
    const scale = @as(usize, opts.scale);

    try writer.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d}" viewBox="0 0 {d} {d}" shape-rendering="crispEdges">
        \\<rect width="100%" height="100%" fill="#fff"/>
        \\<path fill="#000" d="
    , .{ dim, dim, dim, dim });

    for (0..qr.size) |y| {
        for (0..qr.size) |x| {
            if (!matrix.modules[y][x]) continue;
            const px = border_px + x * scale;
            const py = border_px + y * scale;
            try writer.print("M{d} {d}h{d}v{d}h-{d}z", .{ px, py, scale, scale, scale });
        }
    }

    try writer.writeAll("\"/>\n</svg>\n");
}

test "SVG 尺寸与矩形数量" {
    const pentax = @import("pentax.zig");
    const payload = pentax.payload(pentax.modelInfo(.k1ii), pentax.features[1], "12345");
    const matrix = qr.encode(&payload);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, &matrix, .{ .scale = 4, .border = 1 });
    const svg_text = try out.toOwnedSlice();
    defer std.testing.allocator.free(svg_text);

    // (37 + 2*1) * 4 = 156
    try std.testing.expect(std.mem.indexOf(u8, svg_text, "width=\"156\" height=\"156\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, svg_text, "<?xml"));
    try std.testing.expect(std.mem.endsWith(u8, svg_text, "</svg>\n"));
    // 每个暗模块输出一个矩形：路径数据里 M 的数量等于暗模块数。
    var dark: usize = 0;
    for (0..qr.size) |y| {
        for (0..qr.size) |x| dark += @intFromBool(matrix.modules[y][x]);
    }
    var count: usize = 0;
    for (svg_text) |byte| {
        if (byte == 'M') count += 1;
    }
    try std.testing.expectEqual(dark, count);
}
