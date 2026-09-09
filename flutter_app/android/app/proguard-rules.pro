# Flutter ProGuard Rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.example.deepseek_chat_app.** { *; }

# Hive & Storage Rules
-keep class com.github.davidmartos96.hive.** { *; }
-keepattributes *Annotation*
-keepattributes Signature
-dontwarn io.flutter.**
