plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.vm.app"
    compileSdk = 35
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "com.vm.app"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        // 镜像下载地址，二选一：
        //   -PguestImageBaseUrl=https://host/vm  → 按 <base>/<tag>.zip 取，天然支持多版本（推荐）
        //   -PguestImageUrl=https://host/x.zip   → 单个完整地址，只对默认版本生效
        buildConfigField(
            "String", "GUEST_IMAGE_BASE_URL",
            "\"${(project.findProperty("guestImageBaseUrl") as String?).orEmpty()}\""
        )
        buildConfigField(
            "String", "GUEST_IMAGE_URL",
            "\"${(project.findProperty("guestImageUrl") as String?).orEmpty()}\""
        )

        ndk {
            // 目前只交叉编译了 arm64 的 QEMU，因此只出这一个 ABI
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    buildFeatures {
        viewBinding = true
        buildConfig = true
    }

    packaging {
        jniLibs {
            // 必须解压到 nativeLibraryDir，原生引擎才有执行权限（Android 10+ W^X 限制）
            useLegacyPackaging = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(project(":core-vm"))
    implementation(project(":engine-api"))
    implementation(project(":engine"))

    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.recyclerview:recyclerview:1.3.2")
    implementation("com.google.android.material:material:1.12.0")
}
