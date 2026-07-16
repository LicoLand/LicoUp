import java.util.Locale
import java.util.Properties
import java.nio.charset.StandardCharsets

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningValues = mapOf(
    "storeFile" to System.getenv("LICO_ANDROID_KEYSTORE_PATH"),
    "storePassword" to System.getenv("LICO_ANDROID_KEYSTORE_PASSWORD"),
    "keyAlias" to System.getenv("LICO_ANDROID_KEY_ALIAS"),
    "keyPassword" to System.getenv("LICO_ANDROID_KEY_PASSWORD")
)
val releaseSigningFieldsReady = releaseSigningValues.values.all { !it.isNullOrBlank() }
val releaseStoreFile = releaseSigningValues["storeFile"]?.let(::File)
val releaseSigningReady = releaseSigningFieldsReady && releaseStoreFile?.isAbsolute == true

android {
    namespace = "com.liko.arc"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = System.getenv("LICO_ANDROID_NDK_VERSION")
        ?.takeIf { it.isNotBlank() }
        ?: "30.0.14904198"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir(layout.buildDirectory.dir("generated/secureMeshJniLibs"))
        }
    }

    packaging {
        jniLibs {
            keepDebugSymbols.clear()
            excludes += listOf(
                "lib/armeabi-v7a/**",
                "lib/x86_64/**"
            )
        }
    }

    defaultConfig {
        applicationId = "com.liko.arc"
        manifestPlaceholders["mainActivityClass"] = "com.liko.arc.MainActivity"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = releaseStoreFile!!.canonicalFile
                storePassword = releaseSigningValues.getValue("storePassword")
                keyAlias = releaseSigningValues.getValue("keyAlias")
                keyPassword = releaseSigningValues.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        getByName("debug") {
            manifestPlaceholders["mainActivityClass"] = "com.liko.arc.DebugMainActivity"
        }
        release {
            signingConfig = if (releaseSigningReady) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }
}

tasks.configureEach {
    val isReleasePackagingTask = name.matches(Regex("(?:assemble|bundle|package).*Release$"))
    if (isReleasePackagingTask) {
        doFirst {
            require(releaseSigningFieldsReady) {
                "Android release signing is required. Provide LICO_ANDROID_KEYSTORE_PATH, " +
                    "LICO_ANDROID_KEYSTORE_PASSWORD, LICO_ANDROID_KEY_ALIAS, and " +
                    "LICO_ANDROID_KEY_PASSWORD through the protected CI release environment."
            }
            require(releaseStoreFile!!.isAbsolute) {
                "Android release keystore path must be absolute."
            }
            require(releaseStoreFile.isFile) {
                "Android release keystore file is missing."
            }
        }
    }
}

val verifyReleaseAcceptanceIsolation by tasks.registering {
    group = "verification"
    description =
        "Proves the release manifest and Kotlin classes exclude the debug acceptance ingress."
    dependsOn("processReleaseMainManifest", "compileReleaseKotlin")

    doLast {
        val forbidden = listOf(
            "ReleaseAcceptanceReceiver",
            "ReleaseAcceptanceChannel",
            "SecureMeshAndroidReleaseAcceptanceCoordinator",
            "ReleaseAcceptanceDebugContract",
            "com.liko.arc.RELEASE_ACCEPTANCE",
            "secure_mesh.android.releaseAcceptance.authorize",
        )
        val intermediates = layout.buildDirectory.dir("intermediates").get().asFile
        val releaseManifests = intermediates.walkTopDown()
            .filter { file ->
                file.isFile &&
                    file.name == "AndroidManifest.xml" &&
                    file.invariantSeparatorsPath.contains("/release/")
            }
            .toList()
        require(releaseManifests.isNotEmpty()) {
            "Merged release manifest was not produced."
        }
        releaseManifests.forEach { manifest ->
            val text = manifest.readText(Charsets.UTF_8)
            require(text.contains("android:allowBackup=\"false\"")) {
                "Merged release manifest must disable Android Auto Backup."
            }
            require(text.contains("android:dataExtractionRules=\"@xml/backup_rules\"")) {
                "Merged release manifest must bind fail-closed data extraction rules."
            }
            require(text.contains("android:fullBackupContent=\"@xml/backup_rules_legacy\"")) {
                "Merged release manifest must bind legacy full-backup exclusions."
            }
            forbidden.forEach { token ->
                require(!text.contains(token)) {
                    "Merged release manifest contains debug-only acceptance token: $token"
                }
            }
        }

        val releaseClasses = layout.buildDirectory.dir("tmp/kotlin-classes/release").get().asFile
        require(releaseClasses.isDirectory) {
            "Compiled release Kotlin classes were not produced."
        }
        releaseClasses.walkTopDown()
            .filter { it.isFile && it.extension == "class" }
            .forEach { classFile ->
                val text = String(classFile.readBytes(), StandardCharsets.ISO_8859_1)
                forbidden.forEach { token ->
                    require(!text.contains(token)) {
                        "Compiled release classes contain debug-only acceptance token: $token"
                    }
                }
            }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
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
