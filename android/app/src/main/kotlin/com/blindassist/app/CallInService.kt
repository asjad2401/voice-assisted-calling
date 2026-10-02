package com.blindassist.app

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.InCallService
import android.util.Log

/**
 * The OS binds this service once this app is registered as a calling account / default dialer.
 * Handles live telecom calls, forces audio routing to Speakerphone, and maintains MainActivity in foreground.
 */
class CallInService : InCallService() {

    companion object {
        private const val TAG = "CallInService"
        var currentCall: Call? = null
            private set
        var instance: CallInService? = null
            private set

        fun hangUpCurrentCall() {
            val call = currentCall ?: return
            try {
                if (call.state == Call.STATE_RINGING) {
                    call.reject(false, null)
                } else {
                    call.disconnect()
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        fun enableSpeakerphone(context: Context) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    instance?.setAudioRoute(CallAudioState.ROUTE_SPEAKER)
                }
                val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                if (audioManager != null) {
                    audioManager.mode = AudioManager.MODE_IN_CALL
                    audioManager.isSpeakerphoneOn = true
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        if (instance == this) instance = null
        super.onDestroy()
    }

    private fun bringMainActivityToFront() {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            startActivity(intent)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private val callCallback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) {
            when (state) {
                Call.STATE_RINGING -> {
                    val number = call.details?.handle?.schemeSpecificPart
                    val callerName = call.details?.callerDisplayName
                    Log.d(TAG, "Ringing: $number, name: $callerName")
                    bringMainActivityToFront()
                    CallEventBridge.emit(
                        mapOf(
                            "type" to "incoming",
                            "number" to number,
                            "callerName" to callerName
                        )
                    )
                }
                Call.STATE_DIALING, Call.STATE_CONNECTING -> {
                    val number = call.details?.handle?.schemeSpecificPart
                    val callerName = call.details?.callerDisplayName
                    Log.d(TAG, "Dialing: $number, name: $callerName")
                    bringMainActivityToFront()
                    CallEventBridge.emit(
                        mapOf(
                            "type" to "dialing",
                            "number" to number,
                            "callerName" to callerName
                        )
                    )
                }
                Call.STATE_ACTIVE -> {
                    Log.d(TAG, "Call active -> Enforcing Speakerphone")
                    enableSpeakerphone(this@CallInService)
                    bringMainActivityToFront()
                    CallEventBridge.emit(mapOf("type" to "answered"))
                }
                Call.STATE_DISCONNECTED -> {
                    Log.d(TAG, "Call disconnected")
                    CallEventBridge.emit(mapOf("type" to "ended"))
                }
            }
        }
    }

    override fun onCallAdded(call: Call) {
        currentCall = call
        call.registerCallback(callCallback)
        bringMainActivityToFront()

        if (call.state == Call.STATE_RINGING) {
            val number = call.details?.handle?.schemeSpecificPart
            val callerName = call.details?.callerDisplayName
            Log.d(TAG, "onCallAdded ringing: $number")
            CallEventBridge.emit(
                mapOf(
                    "type" to "incoming",
                    "number" to number,
                    "callerName" to callerName
                )
            )
        } else if (call.state == Call.STATE_DIALING || call.state == Call.STATE_CONNECTING) {
            val number = call.details?.handle?.schemeSpecificPart
            val callerName = call.details?.callerDisplayName
            CallEventBridge.emit(
                mapOf(
                    "type" to "dialing",
                    "number" to number,
                    "callerName" to callerName
                )
            )
        } else if (call.state == Call.STATE_ACTIVE) {
            enableSpeakerphone(this)
            CallEventBridge.emit(mapOf("type" to "answered"))
        }
    }

    override fun onCallRemoved(call: Call) {
        call.unregisterCallback(callCallback)
        if (currentCall == call) currentCall = null
        CallEventBridge.emit(mapOf("type" to "ended"))
    }

    fun answer() {
        currentCall?.answer(0 /* VideoProfile.STATE_AUDIO_ONLY */)
        enableSpeakerphone(this)
    }

    fun reject() {
        hangUpCurrentCall()
    }
}
