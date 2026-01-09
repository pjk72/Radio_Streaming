import com.android.build.gradle.LibraryExtension
import com.android.build.gradle.AppExtension

allprojects {
    repositories {
        google()
        mavenCentral()
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
    project.evaluationDependsOn(":app")
}

subprojects {
    plugins.withId("com.android.library") {
        configure<LibraryExtension> {
            if (namespace == null) {
                namespace = when (project.name) {
                    "on_audio_query_android" -> "com.lucasjosino.on_audio_query"
                    else -> "com.lucasjosino.${project.name.replace("-", "_")}"
                }
            }
        }
    }
    plugins.withId("com.android.application") {
        configure<AppExtension> {
            if (namespace == null) {
                namespace = "com.fazio.musicstream"
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
