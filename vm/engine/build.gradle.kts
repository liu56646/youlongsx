plugins {
    id("com.android.library")
}

android {
    namespace = "com.vm.enginelib"
    compileSdk = 35
    ndkVersion = "28.2.13676358"

    defaultConfig {
        minSdk = 28
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            // 注：libqemu_exec.so 是 QEMU 的可执行体（PIE），不是共享库。
            // 曾经加过 keepDebugSymbols += "**/libqemu_exec.so" 以防 AGP 的
            // llvm-strip 破坏它，但一直没在真机验证过（只是让 APK 变大几十 MB）。
            // 现改为实测：能跑就不保留符号（见 docs/方案B排障交接.md §8）。
        }
    }
}
