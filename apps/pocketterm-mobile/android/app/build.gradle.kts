import java.util.Properties

// The phone app: Jetpack Compose over the protocol core (:core). AGP 9 compiles Kotlin itself
// (built-in Kotlin), so only the Compose compiler and serialization plugins are applied.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Push (FCM) needs the Firebase project's google-services.json here (git-ignored;
// docs/BUILDING.md). Without it a debug build runs with push off (registerPush
// answers null, so the phone gets no pushes); a release build stops (below).
val firebase = file("google-services.json").exists()
if (firebase) apply(plugin = libs.plugins.google.services.get().pluginId)

// Release signing: android/key.properties (git-ignored; see key.properties.example).
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val canSignRelease = listOf("storeFile", "storePassword", "keyAlias", "keyPassword").all {
    !keyProperties.getProperty(it).isNullOrBlank()
}

// The end-to-end build (-PpockettermE2e=true; maestro/e2e/run.sh): a debug build whose scanner takes a
// pasted code, whose tips start seen and whose microphone hears a scripted speaker. Release builds never.
val e2e = providers.gradleProperty("pockettermE2e").map { it.toBoolean() }.getOrElse(false)

android {
    namespace = "com.danyzmaj.pocketterm"
    // 37: Compose 1.12, navigation 2.10 and the Markdown renderer are built against it. Compiling against it
    // changes nothing at run time; the app targets 36 (below).
    compileSdk = 37

    defaultConfig {
        applicationId = "com.danyzmaj.pocketterm"
        // 26: adaptive icons, notification channels, and the AES-GCM the channel keys need.
        minSdk = 26
        targetSdk = 36
        // Release scripts pass the store's numbers; the defaults are the last Flutter release's (0.1.7+22).
        versionCode = providers.gradleProperty("versionCode").map { it.toInt() }.getOrElse(22)
        versionName = providers.gradleProperty("versionName").getOrElse("0.1.7")
        buildConfigField("boolean", "FIREBASE", "$firebase")
    }

    signingConfigs {
        if (canSignRelease) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            buildConfigField("boolean", "E2E", "$e2e")
        }
        release {
            buildConfigField("boolean", "E2E", "false")
            // Never the debug key: without key.properties a release build stops (below).
            signingConfig = if (canSignRelease) signingConfigs.getByName("release") else null
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    lint {
        // The build's own version choices are pinned on purpose (compileSdk 36; see libs.versions.toml).
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion", "OldTargetApi")
        warningsAsErrors = false
        abortOnError = true
    }
}

kotlin {
    jvmToolchain(17)
}

// A release build without the upload key fails here, before any work, instead of
// producing an unsigned or debug-signed bundle. So does one without
// google-services.json, which would ship with push silently off; forks without a
// Firebase project opt out with -PallowNoPush=true.
gradle.taskGraph.whenReady {
    val release = allTasks.any { it.project == project && it.name.contains("Release") && !it.name.contains("UnitTest") && !it.name.startsWith("lint") }
    if (release && !canSignRelease) {
        throw GradleException(
            "Release signing is not set up: copy android/key.properties.example to " +
                "android/key.properties and fill in the upload keystore (docs/RELEASING.md).",
        )
    }
    val allowNoPush = project.findProperty("allowNoPush")?.toString().let { it != null && it != "false" }
    if (release && !firebase && !allowNoPush) {
        throw GradleException(
            "android/app/google-services.json is missing, so this release would have no push " +
                "(docs/BUILDING.md). Add it, or build with -PallowNoPush=true to ship without push.",
        )
    }
}

dependencies {
    implementation(project(":core"))
    implementation(libs.kotlinx.coroutines.android)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.activity.compose)
    implementation(libs.navigation.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.core.ktx)
    implementation(libs.core.splashscreen)

    implementation(libs.camera.camera2)
    implementation(libs.camera.lifecycle)
    implementation(libs.camera.view)
    implementation(libs.mlkit.barcode)

    implementation(libs.markdown.renderer.m3)

    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)

    testImplementation(libs.junit)
    testImplementation(libs.kotlin.test)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
}
