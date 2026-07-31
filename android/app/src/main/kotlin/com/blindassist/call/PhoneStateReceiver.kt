package com.blindassist.call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager
import android.util.Log

/**
 * Secondary fallback BroadcastReceiver for telephony state events.
 * Guarantees incoming call detection across all Android OEMs (Samsung, Xiaomi, Pixel, etc.)
 * even if InCallService binding is delayed.
 */
class PhoneStateReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "PhoneStateReceiver"
        private var lastState = TelephonyManager.EXTRA_STATE_IDLE
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action == TelephonyManager.ACTION_PHONE_STATE_CHANGED) {
            val stateStr = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
            val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)

            Log.d(TAG, "Telephony state changed: $stateStr, number: $number")

            if (stateStr == lastState) return
            lastState = stateStr ?: TelephonyManager.EXTRA_STATE_IDLE

            when (stateStr) {
                TelephonyManager.EXTRA_STATE_RINGING -> {
                    CallEventBridge.emit(
                        mapOf(
                            "type" to "incoming",
                            "number" to number,
                            "callerName" to null
                        )
                    )
                }
                TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                    CallEventBridge.emit(mapOf("type" to "answered"))
                }
                TelephonyManager.EXTRA_STATE_IDLE -> {
                    CallEventBridge.emit(mapOf("type" to "ended"))
                }
            }
        }
    }
}
