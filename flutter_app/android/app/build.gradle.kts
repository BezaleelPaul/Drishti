import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: loaded from android/key.properties (gitignored).
// NEVER fall back to debug keys for release builds — a missing
// key.properties fails the release build loudly instead of producing
// a Play-rejectable, attacker-forgeable debug-signed APK.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "in.drishtiai.netra_ai_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "in.drishtiai.netra_ai_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = file(keystoreProperties["storeFile"] as String? ?: "")
                storePassword = keystoreProperties["storePassword"] as String?
            }
            // APK Signature Scheme coverage (verified on 2026-09-13 build:
            // v2 + v3 verify true with the dedicated release cert; v1 JAR
            // compat and v4 streaming requested — `flutter build apk` does
            // not emit the v4 .idsig sidecar, Play re-signs on upload).
            // v3 gives key rotation on Android 9+.
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
            enableV4Signing = true
        }
    }

    buildTypes {
        release {
            if (!keystorePropertiesFile.exists()) {
                throw GradleException(
                    "Release signing misconfigured: android/key.properties not found. " +
                        "Copy android/key.properties.template to android/key.properties, " +
                        "generate a dedicated release keystore (keytool), and rebuild. " +
                        "Refusing to sign a release build with debug keys."
                )
            }
            signingConfig = signingConfigs.getByName("release")
            // Release hardening: never debuggable, strip debug metadata.
            isDebuggable = false
            isJniDebuggable = false
        }
    }

    packaging {
        resources {
            // Drop Kotlin coroutines debug-probe metadata left by debug builds.
            excludes += "DebugProbesKt.bin"
        }
    }
}

flutter {
    source = "../.."
}
