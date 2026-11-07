# Ignore warnings and continue building (standard for many Flutter plugins)
-ignorewarnings
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# Audio Service rules
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.audioservice.AudioService { *; }
-keep class com.ryanheise.audioservice.AudioServiceActivity { *; }
-keep class * extends com.ryanheise.audioservice.AudioHandler { *; }
-keep class * extends com.ryanheise.audioservice.AudioService { *; }
-keep class * extends com.ryanheise.audioservice.AudioServiceActivity { *; }

# AndroidX Media rules (Required for MediaStyle notifications)
-keep class androidx.media.** { *; }
-keep class androidx.mediarouter.** { *; }

# Flutter rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# Suppress warnings for Play Core and Flutter
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn io.flutter.plugins.**
-dontwarn com.google.android.gms.**
-dontwarn androidx.**

# Audioplayers rules
-keep class xyz.luan.audioplayers.** { *; }
-keep class luan.xyz.audioplayers.** { *; }

# AdMob mediation adapters are instantiated by reflection from the adapter class
# name returned by the server (e.g. IronSource). Without these rules R8 renames
# them and mediation silently fails in release builds.
-keep class com.google.ads.mediation.** { *; }
-dontwarn com.google.ads.mediation.**

# IronSource / LevelPlay SDK (gma_mediation_ironsource)
-keep class com.ironsource.** { *; }
-dontwarn com.ironsource.**
-keep class com.unity3d.ironsourceads.** { *; }
-dontwarn com.unity3d.ironsourceads.**
-keep class com.unity3d.ads.** { *; }
-dontwarn com.unity3d.ads.**
-keep class com.unity3d.mediation.** { *; }
-dontwarn com.unity3d.mediation.**

# Connectivity Plus rules
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# On Audio Query rules
-keep class com.lucasjosino.on_audio_query.** { *; }

# Workmanager rules
-keep class com.beefe.ssworkmanager.** { *; }

# Specific App Kotlin Classes
# AppEventChannelsPlugin is registered through a direct reference in
# GeneratedPluginRegistrant, and NativeAdFactorySmall is directly instantiated
# by MainActivity. Neither requires name-based lookup, so R8 can safely process them.
# MainActivity is a manifest component; AGP already keeps its component entry
# point. Its members are referenced directly or through normal Android overrides.
-keep class com.fazio.musicstream.HomeWidgetProvider { *; }

# ──────────────────────────────────────────────────────────────────────────────
# Firebase
# ──────────────────────────────────────────────────────────────────────────────
# Firebase SDKs and their Flutter plugins contribute their own consumer rules.
# Do not keep the entire Firebase implementation; Dart code reaches it through
# generated plugin bindings, while Android manifest components are kept by AGP.
-dontwarn com.google.firebase.**
-dontwarn io.grpc.**

# ──────────────────────────────────────────────────────────────────────────────
# OkHttp / Okio – Used by Firebase SDKs and http package
# ──────────────────────────────────────────────────────────────────────────────
-dontwarn okhttp3.**
-dontwarn okio.**

# ──────────────────────────────────────────────────────────────────────────────
# Kotlin Coroutines / Serialization – Used by Firebase internally
# ──────────────────────────────────────────────────────────────────────────────
-dontwarn kotlinx.coroutines.**
-dontwarn kotlin.**

# ──────────────────────────────────────────────────────────────────────────────
# Gson: keep explicitly named JSON fields where application models use them.
# ──────────────────────────────────────────────────────────────────────────────
-keepattributes *Annotation*
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
