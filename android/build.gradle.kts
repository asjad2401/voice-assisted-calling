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
}
// Some plugins (e.g. tflite_flutter) pin Java to 11 while Kotlin defaults to 17,
// which Gradle rejects. Align each plugin's Kotlin target with its Java target.
subprojects {
    if (name == "app") return@subprojects
    afterEvaluate {
        val android = extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            ?: return@afterEvaluate
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            val javaTarget = android.compileOptions.targetCompatibility.toString()
            compilerOptions.jvmTarget.set(
                org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(javaTarget)
            )
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
