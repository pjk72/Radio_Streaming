package com.fazio.musicstream.channels

import android.app.NotificationManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the app-specific channels on every FlutterEngine.
 *
 * This cannot live in MainActivity only: when Android Auto starts playback
 * without the phone UI being open, audio_service creates and owns the
 * FlutterEngine, so MainActivity.configureFlutterEngine is never called.
 * Because this is a Flutter plugin it is auto-registered on that engine too.
 *
 * It also exposes a small method channel used to hide the media notification
 * while nothing is playing (see [hideMediaNotification]).
 */
class AppEventChannelsPlugin : FlutterPlugin {
    private var phoneStateChannel: EventChannel? = null
    private var carConnectionChannel: EventChannel? = null
    private var notificationChannel: MethodChannel? = null
    private var phoneStateDetector: PhoneStateDetector? = null
    private var carConnectionDetector: CarConnectionDetector? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        val messenger = binding.binaryMessenger

        phoneStateDetector = PhoneStateDetector(context)
        phoneStateChannel = EventChannel(messenger, PHONE_STATE_CHANNEL).also {
            it.setStreamHandler(phoneStateDetector)
        }

        carConnectionDetector = CarConnectionDetector(context)
        carConnectionChannel = EventChannel(messenger, CAR_CONNECTION_CHANNEL).also {
            it.setStreamHandler(carConnectionDetector)
        }

        notificationChannel = MethodChannel(messenger, NOTIFICATION_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                handleNotificationCall(context, call, result)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        phoneStateDetector?.onCancel(null)
        carConnectionDetector?.onCancel(null)
        phoneStateChannel?.setStreamHandler(null)
        carConnectionChannel?.setStreamHandler(null)
        notificationChannel?.setMethodCallHandler(null)
        phoneStateChannel = null
        carConnectionChannel = null
        notificationChannel = null
        phoneStateDetector = null
        carConnectionDetector = null
    }

    private fun handleNotificationCall(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "hide" -> {
                hideMediaNotification(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Removes the audio_service media notification from the shade.
     *
     * audio_service posts it with a fixed id (1124). When playback is paused
     * or stopped we first let audio_service leave the foreground state
     * (`androidStopForegroundOnPause: true`), otherwise Android would keep the
     * notification alive because it belongs to a foreground service. The small
     * delay makes sure the native `setState` (which may re-post the
     * notification to refresh its controls) has already been processed.
     *
     * When playback starts again audio_service calls `startForeground` again,
     * so the notification automatically reappears.
     */
    private fun hideMediaNotification(context: Context, attempt: Int = 0) {
        val appContext = context.applicationContext
        Handler(Looper.getMainLooper()).postDelayed({
            // Guard against a quick pause -> play: if playback restarted, keep
            // the notification visible. A few retries also cover the case in
            // which the paused state has not reached the native service yet.
            if (isMediaPlaying()) {
                if (attempt < HIDE_NOTIFICATION_MAX_ATTEMPTS) {
                    hideMediaNotification(appContext, attempt + 1)
                }
                return@postDelayed
            }
            try {
                val manager =
                    appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.cancel(MEDIA_NOTIFICATION_ID)
            } catch (e: Exception) {
                Log.w(TAG, "Unable to hide media notification", e)
            }
        }, HIDE_NOTIFICATION_DELAY_MS)
    }

    /**
     * Reads audio_service's current playing flag without a compile-time
     * dependency on it. audio_service is kept by the app's ProGuard rules, so
     * the field/method names are stable in release builds too.
     */
    private fun isMediaPlaying(): Boolean {
        return try {
            val clazz = Class.forName("com.ryanheise.audioservice.AudioService")
            val instanceField = clazz.getDeclaredField("instance")
            instanceField.isAccessible = true
            val service = instanceField.get(null) ?: return false
            clazz.getMethod("isPlaying").invoke(service) as? Boolean ?: false
        } catch (_: Throwable) {
            false
        }
    }

    companion object {
        const val PHONE_STATE_CHANNEL = "com.antigravity.radio/phone_state"
        const val CAR_CONNECTION_CHANNEL = "com.antigravity.radio/car_connection"
        const val NOTIFICATION_CHANNEL = "com.antigravity.radio/media_notification"

        // Fixed id used by audio_service for its media notification.
        private const val MEDIA_NOTIFICATION_ID = 1124
        private const val HIDE_NOTIFICATION_DELAY_MS = 200L
        private const val HIDE_NOTIFICATION_MAX_ATTEMPTS = 3
        private const val TAG = "AppEventChannelsPlugin"
    }
}
