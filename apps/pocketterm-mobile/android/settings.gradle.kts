pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "pocketterm-android"

// Pure Kotlin/JVM protocol core (no Android APIs): `./gradlew :core:test`.
include(":core")
// The phone app: Compose UI and the Android services.
include(":app")
