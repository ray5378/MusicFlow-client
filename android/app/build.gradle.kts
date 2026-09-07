import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing values may come from ignored local properties or ECHO_* env vars.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun releaseSigningValue(propertyName: String, environmentName: String): String? {
    return System.getenv(environmentName)?.trim()?.takeIf { it.isNotEmpty() }
        ?: keystoreProperties.getProperty(propertyName)?.trim()?.takeIf { it.isNotEmpty() }
}

val configuredReleaseStoreFile = releaseSigningValue("storeFile", "ECHO_STORE_FILE")
    ?.let { project.file(it) }
val defaultReleaseStoreFile = project.file("Z:/echokey/keystore.jks")
val releaseStoreFile = configuredReleaseStoreFile
    ?.takeIf { it.isFile }
    ?: defaultReleaseStoreFile
val releaseStorePassword = releaseSigningValue("storePassword", "ECHO_STORE_PASSWORD")
val releaseKeyAlias = releaseSigningValue("keyAlias", "ECHO_KEY_ALIAS")
val releaseKeyPassword = releaseSigningValue("keyPassword", "ECHO_KEY_PASSWORD")
    ?: releaseStorePassword
val hasReleaseSigning = releaseStoreFile.isFile &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null

android {
    namespace = "com.musicflow.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.musicflow.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Never create or apply release signing unless the full credential set exists.
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
            }
        }
    }

    buildTypes {
        debug {
            // Flutter debug launches always use Android's system debug keystore.
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // 签名防线：release 构建缺凭据必须硬中断，绝不静默回退 debug 签名
                // （否则 CI secret 漏配时会产出无法覆盖安装的 debug 包且 job 显示绿色）。
                // 仅当本次请求的是 release 任务时中断，保证无 keystore 的机器仍能 flutter run --debug。
                val requestedTasks = gradle.startParameter.taskNames.joinToString(" ")
                if (requestedTasks.contains("Release", ignoreCase = true) ||
                    requestedTasks.contains("Bundle", ignoreCase = true)) {
                    throw GradleException(
                        "Release signing credentials are missing. " +
                            "Provide ECHO_STORE_FILE/ECHO_STORE_PASSWORD/ECHO_KEY_ALIAS/ECHO_KEY_PASSWORD " +
                            "(or android/key.properties), or run a debug build instead."
                    )
                }
                // 本地非 release 任务（如 IDE 同步、debug）保持可用，不中断配置阶段。
                signingConfig = signingConfigs.getByName("debug")
            }
            // 仅打包 arm64-v8a(ARMv8 及以上)原生库,显著减小安装包体积。
            // 注意:这里不再设 ndk.abiFilters —— 该过滤器与 CI 构建命令的
            // --split-per-abi 的 splits abi 过滤器冲突(Gradle 会直接报错),
            // ABI 过滤统一由 CI 的 --target-platform android-arm64 --split-per-abi 负责。
            // 防止 R8 压缩掉通知图标资源
            isShrinkResources = false
            isMinifyEnabled = false
        }
    }
}

flutter {
    source = "../.."
}
