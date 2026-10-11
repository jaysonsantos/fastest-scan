//! The settings of the program. Each setting is a long flag. Some settings also
//! read an environment variable as their default.

const std = @import("std");
const fastscan = @import("fastscan");

// region: names and defaults

pub const env = struct {
    pub const ffmpeg = "FASTEST_SCAN_FFMPEG";
    pub const ffprobe = "FASTEST_SCAN_FFPROBE";
    pub const hwaccel = "FASTEST_SCAN_HWACCEL";
    pub const jobs = "FASTEST_SCAN_JOBS";
    pub const cache_dir = "FASTEST_SCAN_CACHE_DIR";
    pub const debug_dir = "FASTEST_SCAN_DEBUG_DIR";
};

pub const defaults = struct {
    pub const output = "out.pdf";
    pub const ffmpeg = "ffmpeg";
    pub const ffprobe = "ffprobe";
    pub const dpi = fastscan.jpeg.Options.default_dpi;
    pub const quality = fastscan.jpeg.Options.default_quality;
    /// 0 means: one job for each two CPU cores. One software decoder uses two to three cores.
    pub const jobs = 0;
    /// The short side of the frames of the analysis pass, in pixels.
    pub const analysis_height = 540;
    /// The number of other frames that repair the reference frame of a spread.
    pub const fusion_frames = 6;
};

const limits = struct {
    const min_quality = 1;
    const max_quality = 100;
    const min_dpi = 50;
    const max_dpi = 1200;
    const min_analysis_height = 180;
    const max_analysis_height = 2160;
    const max_fusion_frames = 12;
};

// endregion: names and defaults

pub const Config = struct {
    input: []const u8 = "",
    output: []const u8 = defaults.output,
    layout: fastscan.detect.LayoutMode = .auto,
    dpi: u16 = defaults.dpi,
    quality: u8 = defaults.quality,
    jobs: u32 = defaults.jobs,
    analysis_height: u32 = defaults.analysis_height,
    /// 0 turns the repair with other frames off.
    fusion_frames: u8 = defaults.fusion_frames,
    /// Correct the curl of the pages. Off by default: see decision 0012.
    curl: bool = false,
    /// Which fingers that hold the page in all frames get the colour of the
    /// paper: see decision 0014.
    fingers: fastscan.finger.Paint = .all,
    ffmpeg: []const u8 = defaults.ffmpeg,
    ffprobe: []const u8 = defaults.ffprobe,
    hwaccel: ?[]const u8 = null,
    /// Process only the part of the video from this time, in seconds.
    from_seconds: ?f64 = null,
    /// Process only the part of the video up to this time, in seconds.
    to_seconds: ?f64 = null,
    cache_dir: ?[]const u8 = null,
    debug_dir: ?[]const u8 = null,
    /// With `debug_dir`: write the page of each frame before the fusion too.
    debug_layers: bool = false,
    verbose: bool = false,
};

pub const Action = union(enum) {
    run: Config,
    help,
    version,
};

pub const ParseError = error{
    MissingInput,
    MissingValue,
    UnknownFlag,
    InvalidValue,
    ExtraArgument,
};

// region: flag table

const Flag = enum {
    output,
    layout,
    dpi,
    quality,
    jobs,
    analysis_height,
    fusion_frames,
    curl,
    fingers,
    ffmpeg,
    ffprobe,
    hwaccel,
    from,
    to,
    cache_dir,
    debug_dir,
    debug_layers,
    verbose,
    help,
    version,
};

const Spec = struct {
    flag: Flag,
    long: []const u8,
    short: ?u8 = null,
    /// The name of the value in the help text. Null for a flag without a value.
    value: ?[]const u8 = null,
    env_name: ?[]const u8 = null,
    help: []const u8,
};

const specs = [_]Spec{
    .{ .flag = .output, .long = "output", .short = 'o', .value = "FILE", .help = "The PDF to write. Default: " ++ defaults.output },
    .{ .flag = .layout, .long = "layout", .value = "auto|single|spread", .help = "One page or two pages side by side in the video. Default: auto" },
    .{ .flag = .dpi, .long = "dpi", .value = "N", .help = "Pixels per inch of the pages. It sets the paper size in the PDF. Default: 300" },
    .{ .flag = .quality, .long = "quality", .short = 'q', .value = "1..100", .help = "JPEG quality of the pages. Default: 85" },
    .{ .flag = .jobs, .long = "jobs", .short = 'j', .value = "N", .env_name = env.jobs, .help = "Parallel decoders. Default: half of the CPU cores" },
    .{ .flag = .analysis_height, .long = "analysis-height", .value = "PIXELS", .help = "Short side of the frames of the first pass. Default: 540" },
    .{ .flag = .fusion_frames, .long = "fusion-frames", .value = "0..12", .help = "Other frames that repair glare and covered parts of a page. Up to 3 views from near come in addition. 0 turns the repair off. Default: 6" },
    .{ .flag = .curl, .long = "curl", .help = "Correct the curl of the pages of a thick book (experimental)" },
    .{ .flag = .fingers, .long = "fingers", .value = "all|blank|keep", .help = "A finger that holds the page in all frames: all = paint over it, blank = only when the paper around it is blank, keep = leave it. Default: all" },
    .{ .flag = .ffmpeg, .long = "ffmpeg", .value = "PROGRAM", .env_name = env.ffmpeg, .help = "The ffmpeg program. Default: " ++ defaults.ffmpeg },
    .{ .flag = .ffprobe, .long = "ffprobe", .value = "PROGRAM", .env_name = env.ffprobe, .help = "The ffprobe program. Default: " ++ defaults.ffprobe },
    .{ .flag = .hwaccel, .long = "hwaccel", .value = "NAME", .env_name = env.hwaccel, .help = "Hardware decoder for ffmpeg, for example vaapi" },
    .{ .flag = .from, .long = "from", .value = "SECONDS", .help = "Start at this time of the video" },
    .{ .flag = .to, .long = "to", .value = "SECONDS", .help = "Stop at this time of the video" },
    .{ .flag = .cache_dir, .long = "cache-dir", .value = "DIR", .env_name = env.cache_dir, .help = "Keep decoded frames here and use them again on the next run" },
    .{ .flag = .debug_dir, .long = "debug-dir", .value = "DIR", .env_name = env.debug_dir, .help = "Write pictures and tables of the intermediate steps here" },
    .{ .flag = .debug_layers, .long = "debug-layers", .help = "With --debug-dir: write the page of each frame before the repair too (many files)" },
    .{ .flag = .verbose, .long = "verbose", .short = 'v', .help = "Print the progress and the timing of each step" },
    .{ .flag = .help, .long = "help", .short = 'h', .help = "Print this text" },
    .{ .flag = .version, .long = "version", .help = "Print the version" },
};

fn findLong(name: []const u8) ?Spec {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.long, name)) return spec;
    }
    return null;
}

fn findShort(letter: u8) ?Spec {
    for (specs) |spec| {
        if (spec.short == letter) return spec;
    }
    return null;
}

// endregion: flag table

// region: parser

/// Where the parser looks up an environment variable. The tests give a fixed table.
pub const Environment = struct {
    context: ?*const anyopaque,
    getFn: *const fn (context: ?*const anyopaque, name: []const u8) ?[]const u8,

    pub fn get(self: Environment, name: []const u8) ?[]const u8 {
        return self.getFn(self.context, name);
    }

    pub const empty: Environment = .{
        .context = null,
        .getFn = struct {
            fn get(_: ?*const anyopaque, _: []const u8) ?[]const u8 {
                return null;
            }
        }.get,
    };
};

/// Parse the arguments after the program name. A flag wins over its environment variable.
pub fn parse(arguments: []const []const u8, environment: Environment) ParseError!Action {
    var config: Config = .{};
    for (specs) |spec| {
        const name = spec.env_name orelse continue;
        const value = environment.get(name) orelse continue;
        if (value.len == 0) continue;
        try apply(&config, spec.flag, value);
    }

    var input: ?[]const u8 = null;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        var spec: Spec = undefined;
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, argument, "--")) {
            const body = argument[2..];
            const equals = std.mem.indexOfScalar(u8, body, '=');
            const name = if (equals) |position| body[0..position] else body;
            if (equals) |position| inline_value = body[position + 1 ..];
            spec = findLong(name) orelse return error.UnknownFlag;
        } else if (argument.len == 2 and argument[0] == '-') {
            spec = findShort(argument[1]) orelse return error.UnknownFlag;
        } else if (argument.len > 1 and argument[0] == '-') {
            return error.UnknownFlag;
        } else {
            if (input != null) return error.ExtraArgument;
            input = argument;
            continue;
        }

        switch (spec.flag) {
            .help => return .help,
            .version => return .version,
            else => {},
        }
        if (spec.value == null) {
            if (inline_value != null) return error.InvalidValue;
            try apply(&config, spec.flag, "");
            continue;
        }
        const value = inline_value orelse blk: {
            index += 1;
            if (index >= arguments.len) return error.MissingValue;
            break :blk arguments[index];
        };
        try apply(&config, spec.flag, value);
    }

    config.input = input orelse return error.MissingInput;
    return .{ .run = config };
}

fn apply(config: *Config, flag: Flag, value: []const u8) ParseError!void {
    switch (flag) {
        .output => config.output = value,
        .layout => config.layout = std.meta.stringToEnum(fastscan.detect.LayoutMode, value) orelse return error.InvalidValue,
        .dpi => config.dpi = try parseInt(u16, value, limits.min_dpi, limits.max_dpi),
        .quality => config.quality = try parseInt(u8, value, limits.min_quality, limits.max_quality),
        .jobs => config.jobs = try parseInt(u32, value, 0, std.math.maxInt(u16)),
        .analysis_height => config.analysis_height = try parseInt(u32, value, limits.min_analysis_height, limits.max_analysis_height),
        .fusion_frames => config.fusion_frames = try parseInt(u8, value, 0, limits.max_fusion_frames),
        .curl => config.curl = true,
        .fingers => config.fingers = try parseFingers(value),
        .ffmpeg => config.ffmpeg = value,
        .ffprobe => config.ffprobe = value,
        .hwaccel => config.hwaccel = value,
        .from => config.from_seconds = try parseSeconds(value),
        .to => config.to_seconds = try parseSeconds(value),
        .cache_dir => config.cache_dir = value,
        .debug_dir => config.debug_dir = value,
        .debug_layers => config.debug_layers = true,
        .verbose => config.verbose = true,
        .help, .version => unreachable,
    }
}

fn parseInt(comptime T: type, text: []const u8, min: T, max: T) ParseError!T {
    const value = std.fmt.parseInt(T, text, 10) catch return error.InvalidValue;
    if (value < min or value > max) return error.InvalidValue;
    return value;
}

/// The words of `--fingers` and what they mean.
const finger_words = [_]struct { word: []const u8, paint: fastscan.finger.Paint }{
    .{ .word = "all", .paint = .all },
    .{ .word = "blank", .paint = .blank_paper },
    .{ .word = "keep", .paint = .none },
};

fn parseFingers(text: []const u8) ParseError!fastscan.finger.Paint {
    for (finger_words) |entry| {
        if (std.mem.eql(u8, text, entry.word)) return entry.paint;
    }
    return error.InvalidValue;
}

fn parseSeconds(text: []const u8) ParseError!f64 {
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidValue;
    if (!(value >= 0)) return error.InvalidValue;
    return value;
}

// endregion: parser

// region: help

pub const usage_line = "usage: fastest-scan <video> [-o out.pdf] [options]";

/// The help text: one line per flag, built from the flag table.
pub const help_text = blk: {
    @setEvalBranchQuota(20_000);
    var text: []const u8 = usage_line ++ "\n\n" ++
        "Make a PDF from a video of the pages of a book or a document.\n\noptions:\n";
    for (specs) |spec| {
        var names: []const u8 = "  ";
        if (spec.short) |letter| {
            names = names ++ "-" ++ [_]u8{letter} ++ ", ";
        } else {
            names = names ++ "    ";
        }
        names = names ++ "--" ++ spec.long;
        if (spec.value) |value| names = names ++ " " ++ value;
        text = text ++ names ++ "\n        " ++ spec.help;
        if (spec.env_name) |name| text = text ++ " (environment: " ++ name ++ ")";
        text = text ++ "\n";
    }
    break :blk text;
};

// endregion: help

// region: tests

const testing = std.testing;

test "the input, the output, and numeric flags" {
    const action = try parse(&.{ "in.mp4", "-o", "book.pdf", "--quality=70", "--dpi", "200", "-j", "4" }, Environment.empty);
    const config = action.run;
    try testing.expectEqualStrings("in.mp4", config.input);
    try testing.expectEqualStrings("book.pdf", config.output);
    try testing.expectEqual(@as(u8, 70), config.quality);
    try testing.expectEqual(@as(u16, 200), config.dpi);
    try testing.expectEqual(@as(u32, 4), config.jobs);
    try testing.expectEqual(fastscan.detect.LayoutMode.auto, config.layout);
}

test "defaults come from the default config" {
    const config = (try parse(&.{"in.mp4"}, Environment.empty)).run;
    try testing.expectEqualStrings(defaults.output, config.output);
    try testing.expectEqualStrings(defaults.ffmpeg, config.ffmpeg);
    try testing.expect(config.hwaccel == null);
    try testing.expect(!config.verbose);
}

test "a flag wins over its environment variable" {
    const table = struct {
        fn get(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, env.ffmpeg)) return "/usr/bin/ffmpeg";
            if (std.mem.eql(u8, name, env.hwaccel)) return "vaapi";
            return null;
        }
    };
    const environment: Environment = .{ .context = null, .getFn = table.get };
    const from_env = (try parse(&.{"in.mp4"}, environment)).run;
    try testing.expectEqualStrings("/usr/bin/ffmpeg", from_env.ffmpeg);
    try testing.expectEqualStrings("vaapi", from_env.hwaccel.?);

    const from_flag = (try parse(&.{ "in.mp4", "--ffmpeg", "my-ffmpeg" }, environment)).run;
    try testing.expectEqualStrings("my-ffmpeg", from_flag.ffmpeg);
}

test "layout and time range" {
    const config = (try parse(&.{ "in.mp4", "--layout", "spread", "--from", "2.5", "--to=10" }, Environment.empty)).run;
    try testing.expectEqual(fastscan.detect.LayoutMode.spread, config.layout);
    try testing.expectEqual(@as(f64, 2.5), config.from_seconds.?);
    try testing.expectEqual(@as(f64, 10), config.to_seconds.?);
}

test "the number of fusion frames" {
    try testing.expectEqual(@as(u8, defaults.fusion_frames), (try parse(&.{"in.mp4"}, Environment.empty)).run.fusion_frames);
    try testing.expectEqual(@as(u8, 0), (try parse(&.{ "in.mp4", "--fusion-frames", "0" }, Environment.empty)).run.fusion_frames);
    try testing.expectError(error.InvalidValue, parse(&.{ "in.mp4", "--fusion-frames", "99" }, Environment.empty));
}

test "flags without a value" {
    const config = (try parse(&.{ "in.mp4", "--curl", "-v" }, Environment.empty)).run;
    try testing.expect(config.curl);
    try testing.expect(config.verbose);
    try testing.expect(!(try parse(&.{"in.mp4"}, Environment.empty)).run.curl);
}

test "which fingers get the paint" {
    try testing.expectEqual(fastscan.finger.Paint.all, (try parse(&.{"in.mp4"}, Environment.empty)).run.fingers);
    try testing.expectEqual(fastscan.finger.Paint.blank_paper, (try parse(&.{ "in.mp4", "--fingers", "blank" }, Environment.empty)).run.fingers);
    try testing.expectEqual(fastscan.finger.Paint.none, (try parse(&.{ "in.mp4", "--fingers", "keep" }, Environment.empty)).run.fingers);
    try testing.expectError(error.InvalidValue, parse(&.{ "in.mp4", "--fingers", "some" }, Environment.empty));
}

test "errors" {
    try testing.expectError(error.MissingInput, parse(&.{ "-o", "x.pdf" }, Environment.empty));
    try testing.expectError(error.MissingValue, parse(&.{ "in.mp4", "-o" }, Environment.empty));
    try testing.expectError(error.UnknownFlag, parse(&.{ "in.mp4", "--nope" }, Environment.empty));
    try testing.expectError(error.InvalidValue, parse(&.{ "in.mp4", "--quality", "0" }, Environment.empty));
    try testing.expectError(error.InvalidValue, parse(&.{ "in.mp4", "--layout", "triple" }, Environment.empty));
    try testing.expectError(error.ExtraArgument, parse(&.{ "a.mp4", "b.mp4" }, Environment.empty));
}

test "help and version" {
    try testing.expect((try parse(&.{"--help"}, Environment.empty)) == .help);
    try testing.expect((try parse(&.{ "in.mp4", "--version" }, Environment.empty)) == .version);
    try testing.expect(std.mem.indexOf(u8, help_text, "--cache-dir DIR") != null);
    try testing.expect(std.mem.indexOf(u8, help_text, env.ffmpeg) != null);
}

// endregion: tests
