# Ignore warnings and continue building (standard for many Flutter plugins)
-ignorewarnings
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes EnclosingMethod
-keepattributes InnerClasses
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.audioservice.AudioService { *; }
-keep class com.ryanheise.audioservice.AudioServiceActivity { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class * extends com.ryanheise.audioservice.AudioHandler { *; }
-keep class * extends com.ryanheise.audioservice.AudioService { *; }
-keep class * extends com.ryanheise.audioservice.AudioServiceActivity { *; }

# Suppress warnings for Play Core (fixes R8 build error)
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

# Suppress other common warnings in Flutter apps
-dontwarn io.flutter.plugins.**
-dontwarn com.google.android.gms.**
-dontwarn androidx.**

# Audioplayers rules
-keep class xyz.luan.audioplayers.** { *; }
-keep class luan.xyz.audioplayers.** { *; }

# AdMob rules
-keep class com.google.android.gms.ads.** { *; }

# Connectivity Plus rules
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# Models used in background isolates
-keep class com.fazio.musicstream.** { *; }
-keep class com.fazio.musicstream.models.** { *; }
