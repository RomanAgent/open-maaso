import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The offline edition never applies Google Services, even if a local Firebase
// configuration file happens to exist in a developer checkout.

val releaseSigningEnvironment = mapOf(
    "ANDROID_UPLOAD_KEYSTORE_PATH" to System.getenv("ANDROID_UPLOAD_KEYSTORE_PATH"),
    "ANDROID_UPLOAD_KEYSTORE_PASSWORD" to System.getenv("ANDROID_UPLOAD_KEYSTORE_PASSWORD"),
    "ANDROID_UPLOAD_KEY_ALIAS" to System.getenv("ANDROID_UPLOAD_KEY_ALIAS"),
    "ANDROID_UPLOAD_KEY_PASSWORD" to System.getenv("ANDROID_UPLOAD_KEY_PASSWORD"),
)
val providedReleaseSigningValues = releaseSigningEnvironment.filterValues {
    !it.isNullOrBlank()
}
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (releaseTaskRequested && providers.gradleProperty("skipIl2CppBuild").isPresent) {
    throw GradleException(
        "Android store releases forbid the Unity skipIl2CppBuild Gradle property.",
    )
}

if (providedReleaseSigningValues.isNotEmpty() &&
    providedReleaseSigningValues.size != releaseSigningEnvironment.size
) {
    val missing = releaseSigningEnvironment.filterValues { it.isNullOrBlank() }.keys.sorted()
    throw GradleException(
        "Incomplete Android release signing environment; missing: ${missing.joinToString(", ")}",
    )
}
if (releaseTaskRequested && providedReleaseSigningValues.size != releaseSigningEnvironment.size) {
    throw GradleException(
        "Android release builds require the dedicated Maaso upload keystore environment.",
    )
}

val releaseKeystorePath = releaseSigningEnvironment["ANDROID_UPLOAD_KEYSTORE_PATH"]
    ?.takeIf { it.isNotBlank() }
if (releaseKeystorePath != null && !file(releaseKeystorePath).isFile) {
    throw GradleException("ANDROID_UPLOAD_KEYSTORE_PATH must point to a regular file.")
}

android {
    namespace = "com.futurpals.maaso"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.openmaaso.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
            }
        }
    }

    signingConfigs {
        if (releaseKeystorePath != null) {
            create("release") {
                storeFile = file(releaseKeystorePath)
                storePassword = releaseSigningEnvironment.getValue(
                    "ANDROID_UPLOAD_KEYSTORE_PASSWORD",
                )
                keyAlias = releaseSigningEnvironment.getValue("ANDROID_UPLOAD_KEY_ALIAS")
                keyPassword = releaseSigningEnvironment.getValue("ANDROID_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            if (releaseKeystorePath != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.volcengine:VolcEngineRTC:3.60.103.1500")
    if (providers.gradleProperty("openMaasoEmbedUnity").orNull != "false") {
        implementation(project(":unityLibrary"))
    }
}
