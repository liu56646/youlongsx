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
            // libqemu_exec.so 实际是 QEMU 的可执行体（PIE），不是共享库。
            // AGP 默认会对 jniLibs 里的 .so 跑 NDK 的 llvm-strip，
            // 对可执行体做 strip 有破坏风险，这里显式保留符号。
            keepDebugSymbols += "**/libqemu_exec.so"
        }
    }
}
