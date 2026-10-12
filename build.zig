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

    // region: Java and Android

    // The JNI layer of the Android app, for the Java machine of this computer. A
    // test on a desktop loads it: scripts/test-jni.sh.
    const java_home = b.option([]const u8, "java-home", "The directory of a JDK, for the step `jni`");
    const jni_step = b.step("jni", "Build the JNI library for the Java machine of this computer (needs -Djava-home)");
    if (java_home) |home| {
        const jni_lib = addJniLibrary(b, target, optimize, build_options);
        jni_lib.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ home, "include" }) });
        // jni.h includes jni_md.h, which is in a directory with the name of the system.
        jni_lib.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ home, "include", @tagName(target.result.os.tag) }) });
        jni_step.dependOn(&b.addInstallArtifact(jni_lib, .{}).step);
    } else {
        jni_step.dependOn(&b.addFail("the step `jni` needs -Djava-home=<the directory of a JDK>").step);
    }

    // The library for Android. Zig has no C library for Android, so:
    // - with no NDK, the step builds only the static libraries. They prove that the
    //   code compiles for the targets; a build with the NDK can link them.
    // - with -Dandroid-ndk, the step also links the JNI libraries of the app
    //   against the C library of the NDK, into zig-out/android/jniLibs/<ABI>/.
    const android_ndk = b.option([]const u8, "android-ndk", "The directory of the Android NDK, for the JNI libraries of the step `android`");
    const android_api = b.option(u32, "android-api", "The lowest Android API level of the JNI libraries. Default: 26") orelse android_default_api;
    const android_step = b.step("android", "Build the library for Android (the JNI libraries need -Dandroid-ndk)");
    for (android_abis) |abi| {
        const android_target = b.resolveTargetQuery(.{
            .cpu_arch = abi.arch,
            .os_tag = .linux,
            .abi = .android,
            .android_api_level = android_api,
        });
        const android_module = b.createModule(.{
            .root_source_file = b.path("src/lib/c_api.zig"),
            .target = android_target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        });
        android_module.addOptions("build_options", build_options);
        const android_static = b.addLibrary(.{ .name = "fastscan", .linkage = .static, .root_module = android_module });
        android_step.dependOn(&b.addInstallArtifact(android_static, .{
            .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{ "android", "static", abi.name }) } },
        }).step);

        const ndk = android_ndk orelse continue;
        const sysroot = b.pathJoin(&.{ ndk, "toolchains", "llvm", "prebuilt", android_ndk_host, "sysroot", "usr" });
        const crt_dir = b.pathJoin(&.{ sysroot, "lib", abi.triple, b.fmt("{d}", .{android_api}) });
        // The file that tells Zig where the C library of the target is.
        const libc_file = b.addWriteFiles().add(b.fmt("android-{s}-libc.txt", .{abi.name}), b.fmt(
            \\include_dir={s}
            \\sys_include_dir={s}
            \\crt_dir={s}
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\cc_dir={s}
            \\darwin_sdk_dir=
            \\
        , .{
            b.pathJoin(&.{ sysroot, "include" }),
            b.pathJoin(&.{ sysroot, "include", abi.triple }),
            crt_dir,
            crt_dir,
        }));
        const android_jni = addJniLibrary(b, android_target, optimize, build_options);
        android_jni.setLibCFile(libc_file);
        // Devices with memory pages of 16 KiB need this alignment (Android 15 and later).
        android_jni.link_z_max_page_size = android_page_bytes;
        android_step.dependOn(&b.addInstallArtifact(android_jni, .{
            .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{ "android", "jniLibs", abi.name }) } },
        }).step);
    }

    // endregion: Java and Android
}

const AndroidAbi = struct {
    /// The name of the directory of the ABI in an Android app.
    name: []const u8,
    arch: std.Target.Cpu.Arch,
    /// The name of the directory of the ABI in the NDK.
    triple: []const u8,
};

/// A phone, and the emulator of a desktop.
const android_abis = [_]AndroidAbi{
    .{ .name = "arm64-v8a", .arch = .aarch64, .triple = "aarch64-linux-android" },
    .{ .name = "x86_64", .arch = .x86_64, .triple = "x86_64-linux-android" },
};

/// Android 8.0. The app needs it for the camera library.
const android_default_api = 26;
const android_page_bytes = 16 * 1024;
/// The directory of the NDK tools for the system that runs the build.
const android_ndk_host = "linux-x86_64";

/// The library `fastscan_jni`: the C interface of the library and the JNI layer of
/// the app in one shared library. The caller adds the directory of `jni.h`.
fn addJniLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    build_options: *std.Build.Step.Options,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("src/lib/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    module.addOptions("build_options", build_options);
    module.addCSourceFile(.{
        .file = b.path("android/app/src/main/cpp/fastscan_jni.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    module.addIncludePath(b.path("include"));
    return b.addLibrary(.{ .name = "fastscan_jni", .linkage = .dynamic, .root_module = module });
}
