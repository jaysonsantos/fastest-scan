{
  description = "fastest-scan: turn a phone video of a book or a document into a PDF";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      # The parts of the Android SDK for the app in android/. The app names the same
      # versions: `androidCompileSdk` and `androidBuildTools` in android/app/build.gradle.kts.
      androidVersions = {
        platform = "36";
        buildTools = "36.1.0";
        ndk = "29.0.14206865";
      };
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          packages = [
            # src/ and build.zig. The default `zig` of nixpkgs is one release older.
            pkgs.zig_0_17
            # the language server for Zig 0.17; `zls` of nixpkgs supports 0.16 only
            pkgs.zigscient
            # the CLI starts ffmpeg and ffprobe to decode the video
            pkgs.ffmpeg
            # scripts/bench.sh: page images from the PDF, OCR confidence, image statistics
            pkgs.poppler-utils
            pkgs.tesseract
            pkgs.imagemagick
            # scripts/test-jni.sh: jni.h, javac, and a Java machine for the test of the JNI layer
            pkgs.jdk21_headless
            # the changelog and the version bump (scripts/release.sh)
            pkgs.git-cliff
            # linters, run together by `prek run --all-files` (.pre-commit-config.yaml)
            pkgs.prek
            pkgs.ziglint
            pkgs.taplo
            pkgs.shellcheck
            pkgs.shfmt
            # clang-format, for the C header, the JNI layer, and the C test
            pkgs.clang-tools
            pkgs.nixfmt
            pkgs.typos
            pkgs.actionlint
            pkgs.editorconfig-checker
            pkgs.gitleaks
          ];
        in
        {
          default = pkgs.mkShell { inherit packages; };

          # The tools for the Android app: `scripts/build-android.sh` and docs/android.md.
          #
          # The Android SDK has a licence of Google that each user must accept, and it
          # is not free software. So this shell does not open with the usual command.
          # A person who accepts the licence says so with two variables:
          #
          #   NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ACCEPT_ANDROID_SDK_LICENSE=1 \
          #     nix develop --impure .#android
          android =
            let
              sdk =
                (pkgs.androidenv.composeAndroidPackages {
                  platformVersions = [ androidVersions.platform ];
                  buildToolsVersions = [ androidVersions.buildTools ];
                  includeNDK = true;
                  ndkVersions = [ androidVersions.ndk ];
                  # Zig builds the native library: the app needs no CMake.
                  includeCmake = false;
                  # An emulator with an x86_64 system image, to run the app on a desktop.
                  includeEmulator = true;
                  includeSystemImages = true;
                  systemImageTypes = [ "default" ];
                  abiVersions = [ "x86_64" ];
                }).androidsdk;
              androidHome = "${sdk}/libexec/android-sdk";
            in
            pkgs.mkShell {
              packages = packages ++ [
                # android/: the build of the app. Gradle needs a full JDK.
                pkgs.gradle_9
                pkgs.jdk21
                sdk
              ];
              ANDROID_HOME = androidHome;
              # `zig build android -Dandroid-ndk=...` links the native library against this NDK.
              ANDROID_NDK_HOME = "${androidHome}/ndk/${androidVersions.ndk}";
              # Gradle takes aapt2 from this SDK. The aapt2 that Gradle downloads does not start on NixOS.
              GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidHome}/build-tools/${androidVersions.buildTools}/aapt2";
            };
        }
      );
    };
}
