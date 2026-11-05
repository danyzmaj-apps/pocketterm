// The PocketTerm protocol core for Android: pure Kotlin/JVM, no Android APIs, so it
// builds and tests on any JVM (`./gradlew :core:test`).
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    api(libs.kotlinx.coroutines.core)
    api(libs.kotlinx.serialization.json)
    api(libs.okhttp)

    testImplementation(libs.kotlin.test)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
}

tasks.test {
    // The frozen cross-language vectors and the repo root (for the opt-in interop test).
    val repoRoot = rootProject.projectDir.resolve("../../..").canonicalFile
    systemProperty("pocketterm.repoRoot", repoRoot.path)
    environment("POCKETTERM_INTEROP", System.getenv("POCKETTERM_INTEROP") ?: "")
    inputs.file(repoRoot.resolve("tool/vectors/vectors.json"))
    testLogging {
        events("failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
