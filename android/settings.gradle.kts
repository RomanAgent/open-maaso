pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("com.android.library") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    id("com.google.gms.google-services") version "4.5.0" apply false
}

include(":app")

val unityAvatarLibraryDir =
    file("../unity/masso_avatar/Builds/Android/unityLibrary")
val unityAvatarGradlePropertiesFile =
    file("../unity/masso_avatar/Builds/Android/gradle.properties")
val unityAvatarGradleProperties =
    java.util.Properties().apply {
        if (unityAvatarGradlePropertiesFile.exists()) {
            unityAvatarGradlePropertiesFile.inputStream().use { load(it) }
        }
    }
if (unityAvatarLibraryDir.exists()) {
    include(":unityLibrary")
    project(":unityLibrary").projectDir = unityAvatarLibraryDir
}

gradle.beforeProject {
    if (name == "unityLibrary") {
        unityAvatarGradleProperties.forEach { key, value ->
            extensions.extraProperties[key.toString()] = value.toString()
        }
    }
}
