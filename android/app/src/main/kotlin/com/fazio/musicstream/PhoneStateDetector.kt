package com.fazio.musicstream

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
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
 */
class PhoneStateDetector(context: Context) : EventChannel.StreamHandler {
    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null
    private var lastMode: Int = AudioManager.MODE_NORMAL

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

    private fun handleModeChange(mode: Int) {
        if (mode == lastMode) return
        val wasCall = isCallMode(lastMode)
        val isCall = isCallMode(mode)
        lastMode = mode
        if (!wasCall && isCall) {
            eventSink?.success(mapOf("status" to "CALL_STARTED"))
        } else if (wasCall && !isCall) {
            eventSink?.success(mapOf("status" to "CALL_ENDED"))
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        lastMode = audioManager.mode
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            modeListener = AudioManager.OnModeChangedListener { mode ->
                mainHandler.post { handleModeChange(mode) }
            }
            audioManager.addOnModeChangedListener(
                Executor { it.run() },
                modeListener!!,
            )
        } else {
            mainHandler.post(pollRunnable)
        }
    }

    override fun onCancel(arguments: Any?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            modeListener?.let { audioManager.removeOnModeChangedListener(it) }
            modeListener = null
        }
        mainHandler.removeCallbacks(pollRunnable)
        eventSink = null
    }

    companion object {
        private const val POLL_INTERVAL_MS = 1000L
    }
}
