package com.fazio.musicstream

import android.app.PictureInPictureParams
import android.content.ContentValues
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.util.Rational
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "com.antigravity.radio/pip"
    private val MEDIA_CHANNEL = "com.antigravity.radio/media_scanner"
    private var methodChannel: MethodChannel? = null
    private var mediaChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register Native Ad Factory
        io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin.registerNativeAdFactory(
            flutterEngine,
            "smallAdFactory",
            NativeAdFactorySmall(this)
        )

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "enterPip") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val aspectRatio = Rational(16, 9)
                    val params = PictureInPictureParams.Builder()
                        .setAspectRatio(aspectRatio)
                        .build()
                    enterPictureInPictureMode(params)
                    result.success(null)
                } else {
                    result.error("UNAVAILABLE", "PiP not supported on this device version", null)
                }
            } else {
                result.notImplemented()
            }
        }

        mediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
        mediaChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "scanFile" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        val mimeType = when {
                            path.endsWith(".mp3", ignoreCase = true) -> "audio/mp4"
                            path.endsWith(".mp3", ignoreCase = true) -> "audio/mpeg"
                            path.endsWith(".aac", ignoreCase = true) -> "audio/aac"
                            path.endsWith(".webm", ignoreCase = true) -> "audio/webm"
                            path.endsWith(".opus", ignoreCase = true) -> "audio/opus"
                            path.endsWith(".flac", ignoreCase = true) -> "audio/flac"
                            path.endsWith(".wav", ignoreCase = true) -> "audio/wav"
                            path.endsWith(".ogg", ignoreCase = true) -> "audio/ogg"
                            else -> null
                        }
                        MediaScannerConnection.scanFile(
                            this,
                            arrayOf(path),
                            if (mimeType != null) arrayOf(mimeType) else null
                        ) { _, _ -> }
                        result.success(true)
                    } else {
                        result.error("INVALID_PATH", "Path cannot be null", null)
                    }
                }
                "convertToMP3" -> {
                    val inputPath = call.argument<String>("inputPath")
                    val fileName = call.argument<String>("fileName")
                    val subFolder = call.argument<String>("subFolder") ?: "MusicStream"
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val album = call.argument<String>("album") ?: ""
                    val year = call.argument<String>("year") ?: ""
                    val bitrate = call.argument<Int>("bitrate") ?: 192
                    val id3Header = call.argument<ByteArray>("id3Header")
                    val id3Footer = call.argument<ByteArray>("id3Footer")

                    if (inputPath != null && fileName != null) {
                        Thread {
                            try {
                                val ext = if (fileName.endsWith(".mp3", ignoreCase = true)) ".mp3" else ".m4a"
                                val cacheFile = File(cacheDir, "audio_export_${System.currentTimeMillis()}$ext")

                                val transcodeOk = AudioTranscoder.transcodeToAudio(
                                    context = this,
                                    inputPath = inputPath,
                                    outputPath = cacheFile.absolutePath,
                                    bitrateKbps = bitrate
                                )

                                if (!transcodeOk || !cacheFile.exists() || cacheFile.length() < 1024) {
                                    cacheFile.delete()
                                    runOnUiThread { result.success(null) }
                                    return@Thread
                                }

                                // 2. Copy from cache to public Downloads via MediaStore (Android 10+) or direct (Android 9-)
                                val finalPath: String? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                    insertMP3ViaMediaStore(
                                        srcFile = cacheFile,
                                        fileName = fileName,
                                        subFolder = subFolder,
                                        title = title,
                                        artist = artist,
                                        album = album,
                                        year = year
                                    )
                                } else {
                                    copyToLegacyDownloads(cacheFile, fileName, subFolder)
                                }

                                cacheFile.delete()

                                runOnUiThread { result.success(finalPath) }
                            } catch (e: Exception) {
                                Log.e("MainActivity", "convertToMP3 failed: ${e.message}", e)
                                runOnUiThread { result.success(null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "inputPath and fileName are required", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        methodChannel?.invokeMethod("pipModeChanged", isInPictureInPictureMode)
    }

    /**
     * Android 10+ (API 29+): Insert the MP3 file into MediaStore Audio/Downloads collection.
     * Returns the final file path visible to other apps (e.g., /storage/emulated/0/Music/MusicStream/...).
     */
    private fun insertMP3ViaMediaStore(
        srcFile: File,
        fileName: String,
        subFolder: String,
        title: String,
        artist: String,
        album: String,
        year: String
    ): String? {
        return try {
            val resolver = contentResolver
            val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            }

            val isMp3 = fileName.endsWith(".mp3", ignoreCase = true)
            val isM4a = fileName.endsWith(".m4a", ignoreCase = true) || fileName.endsWith(".mp4", ignoreCase = true)
            val safeFileName = if (isMp3 || isM4a) fileName else "$fileName.m4a"
            val mimeType = if (isMp3) "audio/mpeg" else "audio/mp4"

            val values = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, safeFileName)
                if (title.isNotEmpty()) {
                    put(MediaStore.Audio.Media.TITLE, title)
                } else {
                    put(MediaStore.Audio.Media.TITLE, safeFileName.removeSuffix(".mp3").removeSuffix(".m4a"))
                }
                if (artist.isNotEmpty()) {
                    put(MediaStore.Audio.Media.ARTIST, artist)
                }
                if (album.isNotEmpty()) {
                    put(MediaStore.Audio.Media.ALBUM, album)
                }
                if (year.isNotEmpty()) {
                    val yearInt = year.toIntOrNull()
                    if (yearInt != null) {
                        put(MediaStore.Audio.Media.YEAR, yearInt)
                    }
                }
                put(MediaStore.Audio.Media.MIME_TYPE, mimeType)
                put(MediaStore.Audio.Media.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$subFolder")
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }

            val uri = resolver.insert(collection, values) ?: return null

            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(srcFile).use { inp -> inp.copyTo(out, bufferSize = 65536) }
            }

            values.clear()
            values.put(MediaStore.Audio.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)

            // Resolve real path if available
            val realPath = resolver.query(uri, arrayOf(MediaStore.Audio.Media.DATA), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)
                    if (idx >= 0) cursor.getString(idx) else uri.toString()
                } else uri.toString()
            } ?: uri.toString()

            if (realPath.startsWith("/")) {
                MediaScannerConnection.scanFile(
                    this, arrayOf(realPath), arrayOf("audio/mpeg")
                ) { _, _ -> }
            }

            realPath
        } catch (e: Exception) {
            Log.e("MainActivity", "insertMP3ViaMediaStore failed: ${e.message}", e)
            null
        }
    }

    /**
     * Android 9 and below: copy directly to /storage/emulated/0/Download/subFolder/
     */
    private fun copyToLegacyDownloads(srcFile: File, fileName: String, subFolder: String): String? {
        return try {
            val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val targetDir = File(downloadsDir, subFolder)
            targetDir.mkdirs()

            val safeFileName = if (fileName.endsWith(".mp3", ignoreCase = true)) fileName else "$fileName.mp3"
            val destFile = File(targetDir, safeFileName)

            FileInputStream(srcFile).use { inp ->
                destFile.outputStream().use { out -> inp.copyTo(out, bufferSize = 65536) }
            }

            MediaScannerConnection.scanFile(
                this, arrayOf(destFile.absolutePath), arrayOf("audio/mpeg")
            ) { _, _ -> }

            destFile.absolutePath
        } catch (e: Exception) {
            Log.e("MainActivity", "copyToLegacyDownloads failed: ${e.message}", e)
            null
        }
    }
}
