plugins {
    alias(libs.plugins.android.application)
}

// region: constants

val applicationPackage = "br.com.jayson.fastestscan"

// Android 16. The build needs this platform and these build tools of the Android
// SDK. flake.nix gives the same versions: `androidVersions`.
val androidCompileSdk = 36
val androidBuildTools = "36.1.0"

// The NDK that `zig build android` links against. Gradle uses it only to strip the
// debug data from the native libraries.
val androidNdk = "29.0.14206865"

// Android 8.0: the lowest version of the camera library. `zig build android` links
// the native library for the same version: `android_default_api` in build.zig.
val androidMinSdk = 26

// The native libraries of `zig build android -Dandroid-ndk=...`, one directory for each ABI.
val nativeLibraries = rootProject.layout.projectDirectory.dir("../zig-out/android/jniLibs")

// build.zig.zon has the only version number of the repository.
val manifestVersion: String = Regex("""\.version\s*=\s*"([^"]+)"""")
    .find(rootProject.layout.projectDirectory.file("../build.zig.zon").asFile.readText())
    ?.groupValues
    ?.get(1)
    ?: error("build.zig.zon has no version")

// One number for the version 1.2.3: 10203.
val versionParts = manifestVersion.substringBefore('-').split('.').map(String::toInt)
val versionNumber = versionParts[0] * 10_000 + versionParts[1] * 100 + versionParts[2]

// endregion: constants

android {
    namespace = applicationPackage
    compileSdk = androidCompileSdk
    buildToolsVersion = androidBuildTools
    ndkVersion = androidNdk

    defaultConfig {
        applicationId = applicationPackage
        minSdk = androidMinSdk
        targetSdk = androidCompileSdk
        versionCode = versionNumber
        versionName = manifestVersion
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            // A phone, and the emulator of a desktop: the ABIs of `zig build android`.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.directories.add(nativeLibraries.asFile.path)
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
}

dependencies {
    implementation(libs.androidx.activity)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.video)
    implementation(libs.androidx.camera.view)

    // The tests that run on a phone or an emulator: app/src/androidTest.
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
