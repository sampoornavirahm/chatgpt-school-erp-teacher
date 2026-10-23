plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.iqnaut.teachers_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    flavorDimensions += "releaseChannel"
    productFlavors {
        create("uat") { dimension = "releaseChannel" }
        create("production") { dimension = "releaseChannel" }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.iqnaut.teachers_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        val releaseStorePath = System.getenv("ANDROID_KEYSTORE_PATH")
        if (!releaseStorePath.isNullOrBlank()) {
            create("uatRelease") {
                storeFile = file(releaseStorePath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("uatRelease") ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Export the Firebase BoM to the app classpath for FlutterFire's versionless API artifacts.
    implementation(platform("com.google.firebase:firebase-bom:35.0.0"))
    implementation("com.google.firebase:firebase-appdistribution-api:16.0.0-beta20")
    add("uatImplementation", "com.google.firebase:firebase-appdistribution:16.0.0-beta20")
}
