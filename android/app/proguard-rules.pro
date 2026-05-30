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

# AdMob rules
-keep class com.google.android.gms.ads.** { *; }
-keep class com.google.android.gms.internal.ads.** { *; }

# Connectivity Plus rules
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# On Audio Query rules
-keep class com.lucasjosino.on_audio_query.** { *; }

# Workmanager rules
-keep class com.beefe.ssworkmanager.** { *; }

# Specific App Kotlin Classes
# Instead of keeping the whole package (which prevents obfuscation), we keep entry points
-keep class com.fazio.musicstream.MainActivity { *; }
-keep class com.fazio.musicstream.HomeWidgetProvider { *; }
-keep class com.fazio.musicstream.NativeAdFactorySmall { *; }
-keep class com.fazio.musicstream.BackgroundWorker { *; }

# Keep data models if they are used for JSON serialization in background
-keep class com.fazio.musicstream.models.** { *; }

# ──────────────────────────────────────────────────────────────────────────────
# Firebase – Required for RecognitionApiService (Remote Config + Firestore)
# ──────────────────────────────────────────────────────────────────────────────

# Firebase Core
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.internal.firebase** { *; }
-dontwarn com.google.firebase.**

# Firebase Remote Config
-keep class com.google.firebase.remoteconfig.** { *; }
-keep class com.google.firebase.remoteconfig.internal.** { *; }

# Cloud Firestore
-keep class com.google.firebase.firestore.** { *; }
-keep class com.google.firebase.firestore.internal.** { *; }
-keep class io.grpc.** { *; }
-dontwarn io.grpc.**

# Firebase Auth (required by Firestore)
-keep class com.google.firebase.auth.** { *; }

# Firebase Installations
-keep class com.google.firebase.installations.** { *; }

# Firebase Analytics (used for heartbeat)
-keep class com.google.firebase.analytics.** { *; }

# ──────────────────────────────────────────────────────────────────────────────
# OkHttp / Okio – Used by Firebase SDKs and http package
# ──────────────────────────────────────────────────────────────────────────────
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }
-dontwarn okhttp3.**
-keep class okio.** { *; }
-dontwarn okio.**

# ──────────────────────────────────────────────────────────────────────────────
# Kotlin Coroutines / Serialization – Used by Firebase internally
# ──────────────────────────────────────────────────────────────────────────────
-keep class kotlinx.coroutines.** { *; }
-dontwarn kotlinx.coroutines.**
-keep class kotlin.** { *; }
-dontwarn kotlin.**

# ──────────────────────────────────────────────────────────────────────────────
# Gson / JSON parsing (used for Remote Config key parsing in RecognitionApiService)
# ──────────────────────────────────────────────────────────────────────────────
-keep class com.google.gson.** { *; }
-keepattributes *Annotation*
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
