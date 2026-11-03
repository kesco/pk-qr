// SPDX-License-Identifier: GPL-3.0-or-later
//! 测试入口：只在这里引用各模块，保证它们的 test 块被编译执行。

const std = @import("std");
const pentax = @import("pentax.zig");
const vectors = @import("vectors.zig");

test {
    _ = @import("pentax.zig");
    _ = @import("qr.zig");
    _ = @import("png.zig");
    _ = @import("svg.zig");
    _ = @import("terminal.zig");
    _ = @import("cli.zig");
}

test "48 条参考向量逐条复算" {
    // 12 组（机型, 序列号）× 4 项功能 = 48 条 payload。
    try std.testing.expectEqual(@as(usize, 12), vectors.all.len);

    var checked: usize = 0;
    var seen_k1 = false;
    var seen_k3 = false;
    for (vectors.all) |vector| {
        const model = std.meta.stringToEnum(pentax.Model, vector.model) orelse
            return error.UnknownModelInVectors;
        const info = pentax.modelInfo(model);
        const serial = try pentax.normalizeSerial(vector.serial);
        try std.testing.expectEqualStrings(vector.serial, serial);

        for (info.features, 0..) |feature, index| {
            const got = pentax.payload(info, feature, serial);
            try std.testing.expectEqualStrings(vector.payloads[index], &got);
            checked += 1;
        }
        if (model == .k1) seen_k1 = true;
        if (model == .k3iii) seen_k3 = true;
    }
    try std.testing.expectEqual(@as(usize, 48), checked);
    try std.testing.expect(seen_k1 and seen_k3);
}

test "同序列号的 K-1 与 K-1 II 结果不同" {
    const serial = "1234567";
    const k1 = pentax.modelInfo(.k1);
    const k1ii = pentax.modelInfo(.k1ii);
    for (k1.features, 0..) |feature, index| {
        const a = pentax.payload(k1, feature, serial);
        const b = pentax.payload(k1ii, k1ii.features[index], serial);
        try std.testing.expect(!std.mem.eql(u8, &a, &b));
        try std.testing.expectEqual(feature.id, k1ii.features[index].id);
    }
}
