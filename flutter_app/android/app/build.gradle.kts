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

    defaultConfig {
        applicationId = "in.drishtiai.netra_ai_mobile"
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

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}
