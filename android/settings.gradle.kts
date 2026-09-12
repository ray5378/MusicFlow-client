pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // Gradle 遇仓库 5xx(如 Aliyun 偶发 502)不会跨仓库回退(视为硬失败)，
        // 而 CI(海外 runner) 直连 google()/mavenCentral() 畅通，故 CI 下可靠源优先，
        // 避免发版被镜像 5xx 阻断；本地(国内)仍 Aliyun 优先，规避直连 TLS 墙。
        if (System.getenv("CI") != null) {
            google()
            mavenCentral()
        }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        if (System.getenv("CI") == null) {
            google()
            mavenCentral()
        }
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        if (System.getenv("CI") != null) {
            google()
            mavenCentral()
        }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        // Flutter 引擎 AAR(io.flutter:x86_64_debug 等) 镜像；PREFER_SETTINGS 下须显式声明
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
        if (System.getenv("CI") == null) {
            google()
            mavenCentral()
        }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
