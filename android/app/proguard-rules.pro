# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-keepclassmembers class okhttp3.** { *; }
-keepclasseswithmembers class * {
    @okhttp3.* <methods>;
}

# Kotlin 协程
-dontwarn kotlinx.coroutines.**

# Play Core 延迟组件（Flutter 引擎引用，但本项目未引入该依赖）
-dontwarn com.google.android.play.core.**
