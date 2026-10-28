import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "cc.omox.fxxkpush"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cc.omox.fxxkpush"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // instrumentation 测试（androidTest/）跑在真机/模拟器上
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // 只打 arm64-v8a —— 目标机型（用户手机）是 arm64。
        // Flutter 引擎每个 ABI 一份，debug 构建实测：
        //   arm64-v8a 51.7MB + x86_64 38.3MB + armeabi-v7a 31.7MB = 121.7MB
        // release 构建同样会带上三份，APK 直接膨胀到 54MB。
        // 砍掉后 release 约 20MB。
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // 签名：本地/CI 有 android/key.properties 就用它，没有就退回 debug key。
    // key.properties 不进 git（见 .gitignore），签名材料在 GitHub Secrets 里。
    val keystoreProperties = Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    val hasReleaseKeystore = keystoreProperties.containsKey("storeFile") &&
        file(keystoreProperties.getProperty("storeFile")).exists()

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 不开 R8/minify：Flutter 引擎引用了 Play Core 的延迟组件类
            // （PlayStoreDeferredComponentManager），我们没这个依赖，
            // R8 会因 "Missing class" 直接失败。APK 体积本来就不大
            // （Flutter 空壳 ~7MB），不值得为此引依赖或被 R8 卡住。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 原生侧 WebSocket（前台服务持有长连）
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // instrumentation 测试
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
}
