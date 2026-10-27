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
