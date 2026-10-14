import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Push (FCM) needs the Firebase project's google-services.json here (git-ignored;
// docs/BUILDING.md). Without it a debug build runs with push off (registerPush
// answers null, reminders stay local); a release build stops (below).
val firebase = file("google-services.json").exists()
if (firebase) apply(plugin = "com.google.gms.google-services")

// Release signing: android/key.properties (git-ignored; see key.properties.example).
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val canSignRelease = listOf("storeFile", "storePassword", "keyAlias", "keyPassword").all {
    !keyProperties.getProperty(it).isNullOrBlank()
}

android {
    namespace = "com.danyzmaj.dzep"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.danyzmaj.dzep"
        // 26: adaptive icons, notification channels, and the AES-GCM the push key needs.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (canSignRelease) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Never the debug key: without key.properties a release build stops (below).
            signingConfig = if (canSignRelease) signingConfigs.getByName("release") else null
        }
    }
}

// A release build without the upload key fails here, before any work, instead of
// producing an unsigned or debug-signed bundle. So does one without
// google-services.json, which would ship with push silently off; forks without a
// Firebase project opt out with -PallowNoPush.
gradle.taskGraph.whenReady {
    val release = allTasks.any { it.project == project && it.name.contains("Release") }
    if (release && !canSignRelease) {
        throw GradleException(
            "Release signing is not set up: copy android/key.properties.example to " +
                "android/key.properties and fill in the upload keystore (docs/RELEASING.md).",
        )
    }
    if (release && !firebase && !project.hasProperty("allowNoPush")) {
        throw GradleException(
            "android/app/google-services.json is missing, so this release would have no push " +
                "(docs/BUILDING.md). Add it, or build with -PallowNoPush to ship without push.",
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:35.0.0"))
    implementation("com.google.firebase:firebase-messaging")
    // The newest that compiles against Flutter's compileSdk (36); 1.19 wants 37.
    implementation("androidx.core:core-ktx:1.18.0")
    // RemoteViewsCompat: the Todos widget's list without a RemoteViewsService of our own.
    implementation("androidx.core:core-remoteviews:1.1.0")
}

flutter {
    source = "../.."
}
