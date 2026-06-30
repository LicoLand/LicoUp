import java.util.Locale
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.flutter_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "30.0.14904198"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    packaging {
        jniLibs {
            keepDebugSymbols += listOf("**/*.so")
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir(layout.buildDirectory.dir("generated/secureMeshJniLibs"))
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.flutter_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

val secureMeshAndroidTarget = "aarch64-linux-android"
val secureMeshAndroidAbi = "arm64-v8a"
val secureMeshNativeLibrary = "liblico_client_native.so"
val repoRoot = rootProject.projectDir.resolve("../../..").canonicalFile
val secureMeshNativeTargetRoot =
    repoRoot.resolve("build/crates/lico-client-native/android-target")
val secureMeshGeneratedJniRoot =
    layout.buildDirectory.dir("generated/secureMeshJniLibs")
val secureMeshGeneratedLibrary =
    secureMeshGeneratedJniRoot.map {
        it.file("$secureMeshAndroidAbi/$secureMeshNativeLibrary")
    }

fun androidSdkDir(): File {
    val envSdk = System.getenv("ANDROID_HOME")
        ?: System.getenv("ANDROID_SDK_ROOT")
    if (!envSdk.isNullOrBlank()) {
        return File(envSdk)
    }
    val properties = Properties()
    val localProperties = rootProject.projectDir.resolve("local.properties")
    if (localProperties.exists()) {
        localProperties.inputStream().use(properties::load)
    }
    val sdkDir = properties.getProperty("sdk.dir")
    require(!sdkDir.isNullOrBlank()) {
        "Android SDK path is required in ANDROID_HOME, ANDROID_SDK_ROOT, or android/local.properties."
    }
    return File(sdkDir)
}

fun androidHostTag(): String {
    val osName = System.getProperty("os.name").lowercase(Locale.US)
    return when {
        osName.contains("mac") -> "darwin-x86_64"
        osName.contains("linux") -> "linux-x86_64"
        osName.contains("windows") -> "windows-x86_64"
        else -> error("Unsupported Android NDK host platform: $osName")
    }
}

fun ndkTool(name: String): File {
    val sdkDir = androidSdkDir()
    val ndkDir = sdkDir.resolve("ndk/${android.ndkVersion}")
    val tool = ndkDir.resolve("toolchains/llvm/prebuilt/${androidHostTag()}/bin/$name")
    require(tool.isFile) {
        "Android NDK tool is missing: ${tool.path}. Install NDK ${android.ndkVersion}."
    }
    return tool
}

val buildSecureMeshAndroidNative by tasks.registering {
    group = "build"
    description = "Builds the Rust Secure Mesh native runtime for Android arm64."
    inputs.file(repoRoot.resolve("crates/lico-client-native/Cargo.toml"))
    inputs.dir(repoRoot.resolve("crates/lico-client-native/src"))
    outputs.file(secureMeshGeneratedLibrary)

    doLast {
        val rustTargetInstalled = providers.exec {
            commandLine("rustup", "target", "list", "--installed")
        }.standardOutput.asText.get().lineSequence().any {
            it.trim() == secureMeshAndroidTarget
        }
        require(rustTargetInstalled) {
            "Rust target $secureMeshAndroidTarget is required. Run: rustup target add $secureMeshAndroidTarget"
        }

        val clang = ndkTool("aarch64-linux-android21-clang")
        val llvmAr = ndkTool("llvm-ar")
        exec {
            workingDir = repoRoot
            commandLine(
                "cargo",
                "build",
                "--manifest-path",
                repoRoot.resolve("crates/lico-client-native/Cargo.toml").path,
                "--target",
                secureMeshAndroidTarget,
                "--release",
                "--lib"
            )
            environment("CARGO_TARGET_DIR", secureMeshNativeTargetRoot.path)
            environment("CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER", clang.path)
            environment("AR_aarch64_linux_android", llvmAr.path)
            environment("CC_aarch64_linux_android", clang.path)
        }

        val builtLibrary = secureMeshNativeTargetRoot
            .resolve("$secureMeshAndroidTarget/release/$secureMeshNativeLibrary")
        require(builtLibrary.isFile) {
            "Rust Secure Mesh Android library was not produced: ${builtLibrary.path}"
        }
        copy {
            from(builtLibrary)
            into(secureMeshGeneratedJniRoot.get().dir(secureMeshAndroidAbi))
        }
    }
}

tasks.configureEach {
    if (name.matches(Regex("merge.*JniLibFolders"))
        || name.matches(Regex("merge.*NativeLibs"))
        || name.matches(Regex("strip.*DebugSymbols"))
    ) {
        dependsOn(buildSecureMeshAndroidNative)
    }
}
