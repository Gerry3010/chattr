import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Release signing credentials live in android/key.properties (gitignored).
// On CI without it (e.g. a debug/PR build), we fall back to debug signing.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "net.geraldhofbauer.chattr"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    // Suppress warnings about deprecated Java versions from dependencies
    tasks.withType<JavaCompile> {
        options.compilerArgs.add("-Xlint:-options")
    }

    defaultConfig {
        applicationId = "net.geraldhofbauer.chattr"
        // A **suffix** for test rigs: `-PchattrAppIdSuffix=.probe` installs the
        // app BESIDE the real one instead of overwriting it. Overwriting would
        // not be a blemish here but data loss — the local database is the only
        // readable copy of read messages. A suffix rather than a whole id, so
        // the rest of the build stays as it is.
        // TRAP: the google-services plugin does NOT strip it — a release
        // build fails with "No matching client found for package name
        // '…chattr.<suffix>'" (staging call test, 2026-10-03). For a test
        // build, add a copy of the client entry with the suffixed package to
        // google-services.json LOCALLY and restore it afterwards; push won't
        // work in that build. See lib/main_camera_probe.dart.
        applicationIdSuffix = project.findProperty("chattrAppIdSuffix") as String?
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
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use the upload key when key.properties is present (local/CI release
            // builds); otherwise fall back to debug so `flutter run --release`
            // and unsigned CI builds still work.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // ShortcutManagerCompat / ShortcutInfoCompat / Person for the share-sheet
    // Direct Share row (ShareSuggestionsChannel.kt). It arrives transitively via
    // the Flutter embedding, but only as an `implementation` dependency there —
    // so it is on the runtime classpath and NOT the compile one. Declared
    // explicitly rather than relying on that leaking through.
    implementation("androidx.core:core-ktx:1.13.1")
}
