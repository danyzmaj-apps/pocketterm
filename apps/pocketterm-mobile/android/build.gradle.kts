// Plugins are declared once here (versions in gradle/libs.versions.toml) and applied per module.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
    // Applied by app/build.gradle.kts only when app/google-services.json exists.
    alias(libs.plugins.google.services) apply false
}
