plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // 本地单测用真实 org.json 实现（android.jar 里的桩默认全部抛异常）。
    // 仅作用于 test 编译/运行，不打进 APK，官方推荐做法。
    testImplementation("org.json:json:20240303")
}

android {
    namespace = "com.vm.core"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        testInstrumentationRunner = "com.vm.core.ImageImportInstrumentation"
    }

    buildFeatures {
        aidl = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}
