package com.fazio.musicstream.channels

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.Executor

/**
 * Detects real phone calls (cellular + third-party VoIP) without any
 * dangerous permission by observing [AudioManager] audio mode transitions.
 *
 *  - MODE_RINGTONE        -> incoming call ringing
 *  - MODE_IN_CALL         -> cellular call active (incoming/outgoing)
 *  - MODE_IN_COMMUNICATION -> VoIP call active (WhatsApp, Telegram, ecc.)
 *  - MODE_NORMAL          -> no call
 *
 * Emits:
 *  - {"status": "CALL_STARTED"} when entering any call mode
 *  - {"status": "CALL_ENDED"}   when back to MODE_NORMAL
 *
 * Both the [AudioManager.OnModeChangedListener] (API 29+) and a polling
 * fallback are used: some devices/OEMs do not reliably deliver mode callbacks,
 * especially while audio is routed through Android Auto / Bluetooth, so the
 * poll guarantees the transition is still detected.
 */
class PhoneStateDetector(context: Context) : EventChannel.StreamHandler {
    private val audioManager =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null
    private var lastMode: Int = AudioManager.MODE_NORMAL
    private var inCall: Boolean = false

    private var modeListener: AudioManager.OnModeChangedListener? = null
    private val pollRunnable = object : Runnable {
        override fun run() {
            handleModeChange(audioManager.mode)
            mainHandler.postDelayed(this, POLL_INTERVAL_MS)
        }
    }

    private fun isCallMode(mode: Int): Boolean = when (mode) {
        AudioManager.MODE_RINGTONE,
        AudioManager.MODE_IN_CALL,
        AudioManager.MODE_IN_COMMUNICATION -> true
        else -> false
    }

    @Synchronized
    private fun handleModeChange(mode: Int) {
        if (mode == lastMode) return
        val wasCall = inCall
        val isCall = isCallMode(mode)
        lastMode = mode
        inCall = isCall
        Log.i(TAG, "AudioManager mode -> $mode (call: $isCall)")
        if (!wasCall && isCall) {
            eventSink?.success(mapOf("status" to "CALL_STARTED"))
        } else if (wasCall && !isCall) {
            eventSink?.success(mapOf("status" to "CALL_ENDED"))
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        lastMode = audioManager.mode
        inCall = isCallMode(lastMode)
        Log.i(TAG, "onListen: initial mode=$lastMode (call: $inCall)")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            modeListener = AudioManager.OnModeChangedListener { mode ->
                mainHandler.post { handleModeChange(mode) }
            }
            audioManager.addOnModeChangedListener(
                Executor { it.run() },
                modeListener!!,
            )
        }

        // Always poll as a safety net, even when the listener is available.
        mainHandler.removeCallbacks(pollRunnable)
        mainHandler.post(pollRunnable)
    }

    override fun onCancel(arguments: Any?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            modeListener?.let { audioManager.removeOnModeChangedListener(it) }
            modeListener = null
        }
        mainHandler.removeCallbacks(pollRunnable)
        eventSink = null
        Log.i(TAG, "onCancel: phone state listener removed")
    }

    companion object {
        private const val TAG = "PhoneStateDetector"
        private const val POLL_INTERVAL_MS = 1000L
    }
}
