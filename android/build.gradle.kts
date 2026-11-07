import com.android.build.gradle.LibraryExtension
import com.android.build.gradle.AppExtension
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Suppress premature Flutter deprecation warning for third-party plugins applying KGP
try {
    val loggerFactory = org.slf4j.LoggerFactory.getILoggerFactory()
    val getOutputEventListenerMethod = loggerFactory.javaClass.getMethod("getOutputEventListener")
    val defaultListener = getOutputEventListenerMethod.invoke(loggerFactory)
    val listenerClass = Class.forName("org.gradle.internal.logging.events.OutputEventListener")
    val setOutputEventListenerMethod = loggerFactory.javaClass.getMethod("setOutputEventListener", listenerClass)
    val proxy = java.lang.reflect.Proxy.newProxyInstance(
        listenerClass.classLoader,
        arrayOf(listenerClass)
    ) { _, method, args ->
        if (method.name == "onOutput" && args != null && args.isNotEmpty()) {
            val event = args[0]
            val message = try {
                event.javaClass.getMethod("getMessage").invoke(event)?.toString() ?: ""
            } catch (_: Throwable) { "" }
            if (message.contains("Your app uses the following plugins that apply Kotlin Gradle Plugin") ||
                message.contains("Future versions of Flutter will fail to build if your app uses plugins that apply KGP") ||
                message.contains("Please check the changelogs of these plugins and upgrade") ||
                message.contains("If you are a plugin author, please migrate your plugin") ||
                message.contains("applies the Kotlin Gradle Plugin, which will cause build failures") ||
                message.contains("Please migrate your app to Built-in Kotlin")
            ) {
                return@newProxyInstance null
            }
            method.invoke(defaultListener, *args)
        } else {
            null
        }
    }
    setOutputEventListenerMethod.invoke(loggerFactory, proxy)
} catch (_: Throwable) {
    // Graceful fallback
}

allprojects {
    repositories {
        google()
        mavenCentral()
        // IronSource / LevelPlay SDK artifacts (required by gma_mediation_ironsource).
        maven {
            url = uri("https://android-sdk.is.com/")
        }
    }
}

val newBuildDir: Directory = 
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

// AGP 9 enforces AAR metadata checks against the app's compileSdk (36).
// Several Flutter plugins still hardcode an older compileSdk, so raise them
// all. This must be registered before any project is evaluated (and before
// Flutter's plugin handler registers its own afterEvaluate callbacks).
subprojects {
    afterEvaluate {
        extensions.findByType(LibraryExtension::class.java)?.let { androidExtension ->
            val current = androidExtension.compileSdk
            if (current == null || current < 36) {
                androidExtension.compileSdk = 36
            }
        }
    }
}

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

subprojects {
    configurations.all {
        resolutionStrategy {
            force("androidx.glance:glance:1.1.1")
            force("androidx.glance:glance-appwidget:1.1.1")
            force("androidx.glance:glance-appwidget-proto:1.1.1")
            force("androidx.glance:glance-appwidget-external-protobuf:1.1.1")
        }
    }
    tasks.withType<KotlinCompile> {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
