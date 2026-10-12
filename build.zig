const std = @import("std");

/// The only version of the repository. `scripts/release.sh` writes it.
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);

    // region: library

    // The Zig interface of the library. The CLI and other Zig programs import it.
    const lib_module = b.addModule("fastscan", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.addOptions("build_options", build_options);

    // The C interface (include/fastscan.h), for a JNI layer or another language.
    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/lib/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_module.addOptions("build_options", build_options);

    const static_lib = b.addLibrary(.{
        .name = "fastscan",
        .linkage = .static,
        .root_module = c_api_module,
    });
    static_lib.installHeader(b.path("include/fastscan.h"), "fastscan.h");
    b.installArtifact(static_lib);

    const shared_lib = b.addLibrary(.{
        .name = "fastscan",
        .linkage = .dynamic,
        .root_module = c_api_module,
    });
    b.installArtifact(shared_lib);

    // endregion: library

    // region: command-line program

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fastscan", .module = lib_module },
        },
    });
    cli_module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{ .name = "fastest-scan", .root_module = cli_module });
    b.installArtifact(exe);

    const run_command = b.addRunArtifact(exe);
    run_command.step.dependOn(b.getInstallStep());
    // `zig build run -- video.mp4 -o out.pdf`
    run_command.addPassthruArgs();
    b.step("run", "Run the command-line program").dependOn(&run_command.step);

    // endregion: command-line program

    // region: tests and checks

    const test_step = b.step("test", "Run the unit tests of the library and the CLI, and the C program of tests/");
    for ([_]*std.Build.Module{ lib_module, c_api_module, cli_module }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // A C program that uses the static library through the header only.
    const c_test_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_test_module.addCSourceFile(.{
        .file = b.path("tests/c_api.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-Werror" },
    });
    c_test_module.addIncludePath(b.path("include"));
    c_test_module.linkLibrary(static_lib);
    const c_test = b.addExecutable(.{ .name = "fastscan-c-api-test", .root_module = c_test_module });
    const run_c_test = b.addRunArtifact(c_test);
    // The program prints one line on success: the build must not treat it as cached output only.
    run_c_test.expectExitCode(0);
    test_step.dependOn(&run_c_test.step);

    // Compile every target and install nothing. The linter hook and the editor use it.
    const check_step = b.step("check", "Compile the library, the CLI, and the tests");
    check_step.dependOn(&static_lib.step);
    check_step.dependOn(&exe.step);
    check_step.dependOn(&c_test.step);
    for ([_]*std.Build.Module{ lib_module, c_api_module, cli_module }) |module| {
        check_step.dependOn(&b.addTest(.{ .root_module = module }).step);
    }

    // endregion: tests and checks
}
