// SPDX-License-Identifier: GPL-3.0-or-later
//! 宾得功能二维码 CLI：解析参数、计算 payload/矩阵、输出 PNG/SVG/终端。
//! 契约见 docs/design.md；退出码：0 成功、2 用法、3 输入、4 I/O、5 已存在。

const std = @import("std");
const cli = @import("cli.zig");
const pentax = @import("pentax.zig");
const qr = @import("qr.zig");
const png = @import("png.zig");
const svg = @import("svg.zig");
const terminal = @import("terminal.zig");

pub const version = "0.1.0";

const Exit = struct {
    const ok: u8 = 0;
    const usage: u8 = 2;
    const input: u8 = 3;
    const io: u8 = 4;
    const exists: u8 = 5;
};

const help_text =
    \\pk-qr — 宾得功能二维码生成器
    \\
    \\用法：
    \\  pk-qr --serial <数字序列号> [选项]
    \\
    \\必需：
    \\  -s, --serial <str>      1-20 位 ASCII 数字，首尾空白会被去掉，前导零保留
    \\
    \\选项：
    \\  -m, --model <name>      k1 | k1ii | k3iii（默认 k1ii）
    \\  -o, --out <dir>         输出目录（默认 .，不自动创建）
    \\  -f, --format <fmt>      png | svg | text（默认 png；text 直接打印，不写文件）
    \\      --scale <1-64>      每模块像素边长，png/svg 用（默认 12）
    \\      --border <0-16>     静区模块数（默认 4）
    \\      --feature <id|slug> 只生成指定功能，可重复，默认全部 4 项
    \\      --color <mode>      auto | always | never（默认 auto，仅 text）
    \\      --invert            仅 text 无色模式：适配浅色终端
    \\      --json              以 JSON 输出到 stdout（与 -f text 互斥）
    \\      --force             允许覆盖已存在文件
    \\      --dry-run           只计算与打印，不写文件
    \\  -h, --help              显示本帮助
    \\  -V, --version           显示版本
    \\
    \\示例：
    \\  pk-qr -s 1234567
    \\  pk-qr -m k3iii -s 0012345 -o out --feature gradient-nd --scale 16
    \\  pk-qr -s 1234567 --feature star-autofocus -f text
    \\
;

const Rendered = struct {
    feature: pentax.Feature,
    /// 功能在机型表中的下标，用于文件名序号。
    index: usize,
    payload: pentax.Payload,
    matrix: qr.Matrix,
    path: []const u8 = "",
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("pk-qr: 内部错误: {t}\n", .{err});
        return Exit.io;
    };
}

fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const argv = init.minimal.args.toSlice(arena) catch {
        std.debug.print("pk-qr: 无法读取命令行参数\n", .{});
        return Exit.io;
    };

    const parsed = cli.parse(argv[1..]) catch |err| return cliFailure(err);

    switch (parsed.action) {
        .help => {
            try writeStdout(io, help_text);
            return Exit.ok;
        },
        .version => {
            try writeStdoutFmt(io, "pk-qr {s}\n", .{version});
            return Exit.ok;
        },
        .run => {},
    }

    const config = parsed.config;
    const info = pentax.modelInfo(config.model);
    const serial = pentax.normalizeSerial(config.serial) catch {
        std.debug.print("pk-qr: 序列号必须是 1-20 位 ASCII 数字（前导零保留）\n", .{});
        return Exit.input;
    };

    var chosen = config.features;
    var any_chosen = false;
    for (chosen) |selected| any_chosen = any_chosen or selected;
    if (!any_chosen) chosen = @splat(true);

    var codes: [4]Rendered = undefined;
    var blobs: [4][]u8 = undefined;
    var count: usize = 0;
    for (info.features, 0..) |feature, index| {
        if (!chosen[index]) continue;
        const payload = pentax.payload(info, feature, serial);
        codes[count] = .{
            .feature = feature,
            .index = index,
            .payload = payload,
            .matrix = qr.encode(&payload),
        };
        count += 1;
    }
    defer if (config.format != .text) {
        for (blobs[0..count]) |blob| gpa.free(blob);
    };

    if (config.format == .text) {
        var buffer: [8192]u8 = undefined;
        var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
        const writer = &file_writer.interface;
        const colored = resolveColor(init, config.color);
        for (codes[0..count]) |code| {
            try writer.print("{s} · {s} · 序列号 {s}\n\n", .{ info.name, code.feature.name, serial });
            try terminal.write(writer, &code.matrix, .{
                .border = config.border,
                .color = colored,
                .invert = config.invert,
            });
            try writer.writeAll("\n");
        }
        try writer.flush();
        return Exit.ok;
    }

    const extension: []const u8 = if (config.format == .png) "png" else "svg";
    for (codes[0..count], 0..) |*code, code_index| {
        const file_name = try std.fmt.allocPrint(arena, "{s}_{d:0>2}_{s}_{s}.{s}", .{
            info.file_prefix, code.index + 1, code.feature.slug, serial, extension,
        });
        code.path = if (std.mem.eql(u8, config.out_dir, "."))
            file_name
        else
            try std.fs.path.join(arena, &.{ config.out_dir, file_name });
        switch (config.format) {
            .png => blobs[code_index] = try png.encode(gpa, &code.matrix, .{
                .scale = config.scale,
                .border = config.border,
            }),
            .svg => {
                var out: std.Io.Writer.Allocating = .init(gpa);
                errdefer out.deinit();
                try svg.write(&out.writer, &code.matrix, .{
                    .scale = config.scale,
                    .border = config.border,
                });
                blobs[code_index] = try out.toOwnedSlice();
            },
            .text => unreachable,
        }
    }

    if (!config.dry_run and !config.force) {
        for (codes[0..count]) |code| {
            if (try fileExists(io, code.path)) {
                std.debug.print("pk-qr: 目标已存在: {s}（加 --force 覆盖）\n", .{code.path});
                return Exit.exists;
            }
        }
    }

    var written: usize = 0;
    if (!config.dry_run) {
        const dir = std.Io.Dir.cwd();
        for (codes[0..count], 0..) |code, code_index| {
            var atomic = dir.createFileAtomic(io, code.path, .{ .replace = config.force }) catch |err| {
                std.debug.print("pk-qr: 无法创建 {s}: {t}\n", .{ code.path, err });
                return Exit.io;
            };
            defer atomic.deinit(io);

            var buffer: [8192]u8 = undefined;
            var file_writer: std.Io.File.Writer = .init(atomic.file, io, &buffer);
            file_writer.interface.writeAll(blobs[code_index]) catch |err| {
                std.debug.print("pk-qr: 写入失败 {s}: {t}\n", .{ code.path, err });
                return Exit.io;
            };
            file_writer.interface.flush() catch |err| {
                std.debug.print("pk-qr: 写入失败 {s}: {t}\n", .{ code.path, err });
                return Exit.io;
            };

            if (config.force) {
                atomic.replace(io) catch |err| {
                    std.debug.print("pk-qr: 覆盖失败 {s}: {t}\n", .{ code.path, err });
                    return Exit.io;
                };
            } else {
                atomic.link(io) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        std.debug.print("pk-qr: 目标已存在: {s}（加 --force 覆盖）\n", .{code.path});
                        return Exit.exists;
                    },
                    else => {
                        std.debug.print("pk-qr: 写盘失败 {s}: {t}\n", .{ code.path, err });
                        return Exit.io;
                    },
                };
            }
            written += 1;
        }
    }

    if (config.json) {
        try writeJson(io, info, config, serial, codes[0..count], written);
    } else {
        try writeSummary(io, info, serial, codes[0..count], written, config.dry_run);
    }

    return Exit.ok;
}

fn cliFailure(err: cli.ParseError) u8 {
    const message = switch (err) {
        error.UnknownOption => "未知参数",
        error.MissingValue => "缺少参数值",
        error.InvalidValue => "参数取值无效",
        error.MissingSerial => "缺少 --serial",
        error.UnknownModel => "不支持的机型（k1 / k1ii / k3iii）",
        error.UnknownFeature => "该机型没有此功能（按 ID 或 slug 指定）",
        error.ConflictingFlags => "--json 与 -f text 不能同时使用",
    };
    std.debug.print("pk-qr: {s}；运行 pk-qr --help 查看用法\n", .{message});
    return switch (err) {
        error.UnknownModel, error.UnknownFeature => Exit.input,
        else => Exit.usage,
    };
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn resolveColor(init: std.process.Init, mode: terminal.ColorMode) bool {
    switch (mode) {
        .always => return true,
        .never => return false,
        .auto => {},
    }
    if (init.environ_map.get("CLICOLOR_FORCE")) |value| {
        if (value.len > 0 and !std.mem.eql(u8, value, "0")) return true;
    }
    if (init.environ_map.contains("NO_COLOR")) return false;
    return std.Io.File.stdout().isTty(init.io) catch false;
}

fn writeStdout(io: std.Io, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    try file_writer.interface.writeAll(text);
    try file_writer.interface.flush();
}

fn writeStdoutFmt(io: std.Io, comptime format: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    try file_writer.interface.print(format, args);
    try file_writer.interface.flush();
}

fn writeSummary(
    io: std.Io,
    info: pentax.ModelInfo,
    serial: []const u8,
    codes: []const Rendered,
    written: usize,
    dry_run: bool,
) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;

    try writer.print("{s} · 序列号 {s}{s}\n", .{
        info.name, serial,
        if (dry_run) "（dry-run，未写文件）" else "",
    });
    for (codes) |code| {
        try writer.print("{d:0>2} {s}\t{s}\t{s}\n", .{
            code.index + 1, code.feature.name, code.payload[0..], code.path,
        });
    }
    if (!dry_run) try writer.print("已写 {d} 个文件\n", .{written});
    try writer.flush();
}

fn writeJson(
    io: std.Io,
    info: pentax.ModelInfo,
    config: cli.Config,
    serial: []const u8,
    codes: []const Rendered,
    written: usize,
) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;

    try writer.print(
        "{{\"ok\":true,\"model\":\"{s}\",\"modelWord\":{d},\"serial\":\"{s}\",\"format\":\"{s}\",\"dryRun\":{s},\"written\":{d},\"codes\":[",
        .{
            pentax.modelSlug(config.model),
            info.word,
            serial,
            @tagName(config.format),
            if (config.dry_run) "true" else "false",
            written,
        },
    );
    for (codes, 0..) |code, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print(
            "{{\"id\":{d},\"name\":\"{s}\",\"slug\":\"{s}\",\"payload\":\"{s}\",\"path\":\"{s}\"}}",
            .{ code.feature.id, code.feature.name, code.feature.slug, code.payload[0..], code.path },
        );
    }
    try writer.writeAll("]}\n");
    try writer.flush();
}
