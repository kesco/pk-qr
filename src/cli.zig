// SPDX-License-Identifier: GPL-3.0-or-later
//! 参数解析：单一命令、无子命令。契约见 docs/design.md 第 8 节。

const std = @import("std");
const pentax = @import("pentax.zig");
const terminal = @import("terminal.zig");

pub const Format = enum { png, svg, text };

pub const Config = struct {
    serial: []const u8 = "",
    model: pentax.Model = .k1ii,
    out_dir: []const u8 = ".",
    format: Format = .png,
    scale: u8 = 12,
    border: u8 = 4,
    json: bool = false,
    force: bool = false,
    dry_run: bool = false,
    color: terminal.ColorMode = .auto,
    invert: bool = false,
    /// 按机型功能表顺序记录是否选中；全 false 表示未指定，等同全部。
    features: [4]bool = @splat(false),
};

pub const Action = enum { run, help, version };

pub const Parsed = struct {
    action: Action = .run,
    config: Config = .{},
};

pub const ParseError = error{
    UnknownOption,
    MissingValue,
    InvalidValue,
    MissingSerial,
    UnknownModel,
    UnknownFeature,
    ConflictingFlags,
};

const Option = enum { serial, model, out, format, scale, border, feature, color };

const option_names = [_]struct { name: []const u8, option: Option }{
    .{ .name = "--serial", .option = .serial },
    .{ .name = "-s", .option = .serial },
    .{ .name = "--model", .option = .model },
    .{ .name = "-m", .option = .model },
    .{ .name = "--out", .option = .out },
    .{ .name = "-o", .option = .out },
    .{ .name = "--format", .option = .format },
    .{ .name = "-f", .option = .format },
    .{ .name = "--scale", .option = .scale },
    .{ .name = "--border", .option = .border },
    .{ .name = "--feature", .option = .feature },
    .{ .name = "--color", .option = .color },
};

fn lookupOption(name: []const u8) ?Option {
    for (option_names) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.option;
    }
    return null;
}

fn parseUnsignedInRange(value: []const u8, min: u8, max: u8) ParseError!u8 {
    const parsed = std.fmt.parseUnsigned(u8, value, 10) catch return error.InvalidValue;
    if (parsed < min or parsed > max) return error.InvalidValue;
    return parsed;
}

fn parseModel(value: []const u8) ParseError!pentax.Model {
    if (std.mem.eql(u8, value, "k1")) return .k1;
    if (std.mem.eql(u8, value, "k1ii")) return .k1ii;
    if (std.mem.eql(u8, value, "k3iii")) return .k3iii;
    if (std.mem.eql(u8, value, "k3iiim")) return .k3iiim;
    return error.UnknownModel;
}

fn parseFormat(value: []const u8) ParseError!Format {
    if (std.mem.eql(u8, value, "png")) return .png;
    if (std.mem.eql(u8, value, "svg")) return .svg;
    if (std.mem.eql(u8, value, "text")) return .text;
    return error.InvalidValue;
}

fn parseColor(value: []const u8) ParseError!terminal.ColorMode {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "never")) return .never;
    return error.InvalidValue;
}

fn takeValue(args: []const [:0]const u8, index: *usize, inline_value: ?[]const u8) ParseError![]const u8 {
    if (inline_value) |value| return value;
    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;
    return args[index.*];
}

pub fn parse(args: []const [:0]const u8) ParseError!Parsed {
    var parsed: Parsed = .{};
    var config = &parsed.config;
    var selectors: [4][]const u8 = @splat("");
    var selector_count: usize = 0;
    var serial_seen = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            parsed.action = .help;
            return parsed;
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            parsed.action = .version;
            return parsed;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            config.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force")) {
            config.force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            config.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--invert")) {
            config.invert = true;
            continue;
        }

        var name: []const u8 = arg;
        var inline_value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            if (std.mem.startsWith(u8, arg, "--")) {
                name = arg[0..eq];
                inline_value = arg[eq + 1 ..];
            }
        }

        const option = lookupOption(name) orelse return error.UnknownOption;
        switch (option) {
            .serial => {
                config.serial = try takeValue(args, &index, inline_value);
                serial_seen = true;
            },
            .model => config.model = try parseModel(try takeValue(args, &index, inline_value)),
            .out => config.out_dir = try takeValue(args, &index, inline_value),
            .format => config.format = try parseFormat(try takeValue(args, &index, inline_value)),
            .scale => config.scale = try parseUnsignedInRange(try takeValue(args, &index, inline_value), 1, 64),
            .border => config.border = try parseUnsignedInRange(try takeValue(args, &index, inline_value), 0, 16),
            .color => config.color = try parseColor(try takeValue(args, &index, inline_value)),
            .feature => {
                if (selector_count == selectors.len) return error.InvalidValue;
                selectors[selector_count] = try takeValue(args, &index, inline_value);
                selector_count += 1;
            },
        }
    }

    if (!serial_seen) return error.MissingSerial;
    if (config.json and config.format == .text) return error.ConflictingFlags;

    if (selector_count > 0) {
        const info = pentax.modelInfo(config.model);
        for (selectors[0..selector_count]) |selector| {
            const feature_index = pentax.featureIndex(info, selector) orelse return error.UnknownFeature;
            config.features[feature_index] = true;
        }
    }

    return parsed;
}

// --------------------------------------------------------------------- 测试

const test_args = [_][:0]const u8{
    "pk-qr", "--serial", "1234567",
};

/// 测试里传入完整 argv（含程序名），这里剥掉第一个元素。
fn runParse(args: []const [:0]const u8) ParseError!Parsed {
    return parse(args[1..]);
}

test "最小可用参数" {
    const parsed = try runParse(&test_args);
    try std.testing.expectEqual(Action.run, parsed.action);
    try std.testing.expectEqualStrings("1234567", parsed.config.serial);
    try std.testing.expectEqual(pentax.Model.k1ii, parsed.config.model);
    try std.testing.expectEqual(Format.png, parsed.config.format);
    try std.testing.expectEqual(@as(u8, 12), parsed.config.scale);
    try std.testing.expectEqual(@as(u8, 4), parsed.config.border);
    for (parsed.config.features) |selected| try std.testing.expect(!selected);
}

test "内联值与模型、格式、功能选择" {
    const args = [_][:0]const u8{
        "pk-qr",                 "-s",           "0012345",    "--model=k3iii", "--format=svg",
        "--feature=gradient-nd", "--feature=37", "--scale=16", "--border",      "2",
        "--json",                "--force",      "--dry-run",
    };
    const parsed = try runParse(&args);
    try std.testing.expectEqualStrings("0012345", parsed.config.serial);
    try std.testing.expectEqual(pentax.Model.k3iii, parsed.config.model);
    try std.testing.expectEqual(Format.svg, parsed.config.format);
    try std.testing.expectEqual(@as(u8, 16), parsed.config.scale);
    try std.testing.expectEqual(@as(u8, 2), parsed.config.border);
    try std.testing.expect(parsed.config.json);
    try std.testing.expect(parsed.config.force);
    try std.testing.expect(parsed.config.dry_run);
    try std.testing.expectEqualSlices(bool, &.{ true, false, false, true }, &parsed.config.features);
}

test "Monochrome 解析与 K-3 III 功能 ID" {
    const args = [_][:0]const u8{ "pk-qr", "-s", "1234567", "-m", "k3iiim", "--feature", "28" };
    const parsed = try runParse(&args);
    try std.testing.expectEqual(pentax.Model.k3iiim, parsed.config.model);
    try std.testing.expectEqualSlices(bool, &.{ true, false, false, false }, &parsed.config.features);
}

test "帮助与版本立即返回" {
    const help_args = [_][:0]const u8{ "pk-qr", "--help", "--serial", "1" };
    try std.testing.expectEqual(Action.help, (try runParse(&help_args)).action);
    const version_args = [_][:0]const u8{ "pk-qr", "-V" };
    try std.testing.expectEqual(Action.version, (try runParse(&version_args)).action);
}

test "参数错误分类" {
    const missing_serial = [_][:0]const u8{ "pk-qr", "--model", "k1" };
    try std.testing.expectError(error.MissingSerial, runParse(&missing_serial));

    const unknown_option = [_][:0]const u8{ "pk-qr", "--serial", "1", "--nope" };
    try std.testing.expectError(error.UnknownOption, runParse(&unknown_option));

    const missing_value = [_][:0]const u8{ "pk-qr", "--serial" };
    try std.testing.expectError(error.MissingValue, runParse(&missing_value));

    const bad_model = [_][:0]const u8{ "pk-qr", "-s", "1", "-m", "k5" };
    try std.testing.expectError(error.UnknownModel, runParse(&bad_model));

    const bad_scale = [_][:0]const u8{ "pk-qr", "-s", "1", "--scale", "0" };
    try std.testing.expectError(error.InvalidValue, runParse(&bad_scale));

    const bad_border = [_][:0]const u8{ "pk-qr", "-s", "1", "--border", "17" };
    try std.testing.expectError(error.InvalidValue, runParse(&bad_border));

    const bad_format = [_][:0]const u8{ "pk-qr", "-s", "1", "-f", "gif" };
    try std.testing.expectError(error.InvalidValue, runParse(&bad_format));

    const bad_feature = [_][:0]const u8{ "pk-qr", "-s", "1", "--feature", "nope" };
    try std.testing.expectError(error.UnknownFeature, runParse(&bad_feature));

    const wrong_model_feature = [_][:0]const u8{ "pk-qr", "-s", "1", "-m", "k1", "--feature", "28" };
    try std.testing.expectError(error.UnknownFeature, runParse(&wrong_model_feature));

    const conflict = [_][:0]const u8{ "pk-qr", "-s", "1", "-f", "text", "--json" };
    try std.testing.expectError(error.ConflictingFlags, runParse(&conflict));

    const too_many_features = [_][:0]const u8{
        "pk-qr",     "-s",        "1",
        "--feature", "2",         "--feature",
        "11",        "--feature", "14",
        "--feature", "17",        "--feature",
        "2",
    };
    try std.testing.expectError(error.InvalidValue, runParse(&too_many_features));
}
