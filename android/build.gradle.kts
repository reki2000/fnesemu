allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// some plugins are still compiled against an older API than the one required
// by their dependencies (flutter_plugin_android_lifecycle needs 36), and some
// pin an old NDK whose linker leaves the native libraries without the 16 KB
// page alignment (mp_audio_stream pins r21)
subprojects {
    // after the evaluation of the plugin, which sets its own compileSdk
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library")) {
            val app = project(":app")
                .extensions.getByType<com.android.build.gradle.AppExtension>()
            extensions.configure<com.android.build.gradle.LibraryExtension> {
                compileSdk = 36
                // the NDK of the app, which also needs the minSdk of the app
                ndkVersion = app.ndkVersion
                defaultConfig.minSdk = app.defaultConfig.minSdk
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
