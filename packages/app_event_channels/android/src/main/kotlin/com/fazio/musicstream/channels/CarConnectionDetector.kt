package com.fazio.musicstream.channels

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.Executors

/**
 * Detects whether the phone is projecting to an Android Auto head unit.
 *
 * This mirrors the behaviour of the official `androidx.car.app.connection.CarConnection`
 * API without pulling the whole Car App Library dependency: it queries the content
 * provider exported by the car host and listens for updates.
 *
 * Emits:
 *  - {"status": "CAR_CONNECTED", "type": 1|2}    when a head unit is connected
 *  - {"status": "CAR_DISCONNECTED", "type": 0}   when no head unit is connected
 *
 * Connection types:
 *  - 0 CONNECTION_TYPE_NOT_CONNECTED
 *  - 1 CONNECTION_TYPE_NATIVE (Android Automotive OS)
 *  - 2 CONNECTION_TYPE_PROJECTION (Android Auto)
 */
class CarConnectionDetector(context: Context) : EventChannel.StreamHandler {

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    private var eventSink: EventChannel.EventSink? = null
    private var lastType: Int = CONNECTION_TYPE_NOT_CONNECTED
    private var hasEmittedInitial: Boolean = false

    private val queryRunnable = Runnable { queryConnectionType() }

    private val connectionObserver = object : ContentObserver(mainHandler) {
        override fun onChange(selfChange: Boolean) {
            executor.execute(queryRunnable)
        }
    }

    private val connectionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            executor.execute(queryRunnable)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        lastType = CONNECTION_TYPE_NOT_CONNECTED
        hasEmittedInitial = false
        Log.i(TAG, "onListen: registering car connection observers")

        try {
            appContext.contentResolver.registerContentObserver(
                CONTENT_URI,
                true,
                connectionObserver,
            )
        } catch (e: Exception) {
            Log.w(TAG, "ContentObserver registration failed: ${e.message}")
        }

        try {
            val filter = IntentFilter(ACTION_CAR_CONNECTION_UPDATED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(
                    connectionReceiver,
                    filter,
                    Context.RECEIVER_EXPORTED,
                )
            } else {
                appContext.registerReceiver(connectionReceiver, filter)
            }
        } catch (e: Exception) {
            Log.w(TAG, "BroadcastReceiver registration failed: ${e.message}")
        }

        executor.execute(queryRunnable)
    }

    override fun onCancel(arguments: Any?) {
        try {
            appContext.contentResolver.unregisterContentObserver(connectionObserver)
        } catch (_: Exception) {
            // Ignore: observer may not have been registered.
        }
        try {
            appContext.unregisterReceiver(connectionReceiver)
        } catch (_: Exception) {
            // Ignore: receiver may not have been registered.
        }
        eventSink = null
    }

    private fun queryConnectionType() {
        val type = try {
            val cursor = appContext.contentResolver.query(
                CONTENT_URI,
                arrayOf(CAR_CONNECTION_STATE),
                null,
                null,
                null,
            )
            cursor?.use { c ->
                val idx = c.getColumnIndex(CAR_CONNECTION_STATE)
                if (idx >= 0 && c.moveToFirst()) {
                    c.getInt(idx)
                } else {
                    CONNECTION_TYPE_NOT_CONNECTED
                }
            } ?: CONNECTION_TYPE_NOT_CONNECTED
        } catch (e: Exception) {
            Log.w(TAG, "Car connection query failed: ${e.message}")
            CONNECTION_TYPE_NOT_CONNECTED
        }

        mainHandler.post {
            val sink = eventSink ?: return@post
            Log.i(TAG, "queryConnectionType -> $type")
            if (hasEmittedInitial && type == lastType) return@post
            hasEmittedInitial = true
            lastType = type
            sink.success(
                mapOf(
                    "status" to if (type == CONNECTION_TYPE_NOT_CONNECTED) {
                        "CAR_DISCONNECTED"
                    } else {
                        "CAR_CONNECTED"
                    },
                    "type" to type,
                ),
            )
        }
    }

    companion object {
        private const val TAG = "CarConnectionDetector"
        private const val CAR_CONNECTION_AUTHORITY = "androidx.car.app.connection"
        private const val CAR_CONNECTION_STATE = "CarConnectionState"
        private const val ACTION_CAR_CONNECTION_UPDATED =
            "androidx.car.app.connection.action.CAR_CONNECTION_UPDATED"
        private const val CONNECTION_TYPE_NOT_CONNECTED = 0
        private val CONTENT_URI: Uri =
            Uri.Builder().scheme("content").authority(CAR_CONNECTION_AUTHORITY).build()
    }
}
