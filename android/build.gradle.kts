allprojects {
    val unityAvatarLibraryDir =
        rootProject.file("../unity/masso_avatar/Builds/Android/unityLibrary")
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://artifact.bytedance.com/repository/Volcengine/")
        }
        if (unityAvatarLibraryDir.exists()) {
            flatDir {
                dirs(unityAvatarLibraryDir.resolve("libs"))
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
