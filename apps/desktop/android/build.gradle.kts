allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

subprojects {
    configurations.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == "androidx.test" && requested.name == "runner") {
                useVersion("1.3.0")
                because("Flutter integration_test declares 1.2+; pin the verified runner so Android tests remain reproducible offline.")
            }
        }
    }
    buildscript.configurations.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == "com.android.tools.build" && requested.name == "gradle") {
                useVersion("8.11.1")
                because("Keep Flutter plugin Android builds on the app's verified AGP version.")
            }
            if (requested.group == "org.jetbrains.kotlin" && requested.name == "kotlin-gradle-plugin") {
                useVersion("2.2.20")
                because("Keep Flutter plugin Android builds on the app's verified Kotlin version.")
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
