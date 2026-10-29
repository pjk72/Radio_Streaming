package com.fazio.musicstream.channels

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/**
 * Registers the app-specific EventChannels on every FlutterEngine.
 *
 * This cannot live in MainActivity only: when Android Auto starts playback
 * without the phone UI being open, audio_service creates and owns the
 * FlutterEngine, so MainActivity.configureFlutterEngine is never called.
 * Because this is a Flutter plugin it is auto-registered on that engine too.
 */
class AppEventChannelsPlugin : FlutterPlugin {
    private var phoneStateChannel: EventChannel? = null
    private var carConnectionChannel: EventChannel? = null
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
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        phoneStateDetector?.onCancel(null)
        carConnectionDetector?.onCancel(null)
        phoneStateChannel?.setStreamHandler(null)
        carConnectionChannel?.setStreamHandler(null)
        phoneStateChannel = null
        carConnectionChannel = null
        phoneStateDetector = null
        carConnectionDetector = null
    }

    companion object {
        const val PHONE_STATE_CHANNEL = "com.antigravity.radio/phone_state"
        const val CAR_CONNECTION_CHANNEL = "com.antigravity.radio/car_connection"
    }
}
