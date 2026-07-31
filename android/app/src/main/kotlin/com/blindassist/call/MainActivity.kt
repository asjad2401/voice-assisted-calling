package com.blindassist.call

import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.TelecomManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val methodChannelName = "blind_call_assistant/call"
    private val eventChannelName = "blind_call_assistant/call_events"
    private val roleRequestCode = 4201

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        configureWindowFlags()
    }

    private fun configureWindowFlags() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(CallEventBridge)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "placeCall" -> {
                        val number = call.argument<String>("number")
                        placeCall(number)
                        result.success(null)
                    }
                    "answerCall" -> {
                        CallInService.currentCall?.answer(0 /* VideoProfile.STATE_AUDIO_ONLY */)
                        CallInService.enableSpeakerphone(this)
                        result.success(null)
                    }
                    "rejectCall", "hangUp", "endCall" -> {
                        CallInService.hangUpCurrentCall()
                        result.success(null)
                    }
                    "enableSpeakerphone" -> {
                        enableSpeakerMode()
                        result.success(null)
                    }
                    "isDefaultDialer" -> {
                        val isDefault = checkIsDefaultDialer()
                        result.success(isDefault)
                    }
                    "requestPhoneAccountSetup" -> {
                        requestDialerRole()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun enableSpeakerMode() {
        try {
            CallInService.enableSpeakerphone(this)
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (audioManager != null) {
                audioManager.mode = AudioManager.MODE_IN_CALL
                audioManager.isSpeakerphoneOn = true
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    fun bringToFront() {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            startActivity(intent)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /**
     * Places an outgoing call purely through TelecomManager background framework.
     * Continuously re-asserts our Call Assistant full-screen UI active and in foreground 100% of the time,
     * preventing any system phone app activity from obscuring our interface.
     */
    private fun placeCall(number: String?) {
        if (number.isNullOrBlank()) return
        val uri = Uri.parse("tel:$number")
        enableSpeakerMode()

        try {
            val telecomManager = getSystemService(TelecomManager::class.java)
            if (telecomManager != null && checkSelfPermission(android.Manifest.permission.CALL_PHONE) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                val extras = Bundle()
                extras.putBoolean(TelecomManager.EXTRA_START_CALL_WITH_SPEAKERPHONE, true)
                telecomManager.placeCall(uri, extras)

                val mainHandler = Handler(Looper.getMainLooper())
                mainHandler.postDelayed({ bringToFront() }, 150)
                mainHandler.postDelayed({ bringToFront() }, 400)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun checkIsDefaultDialer(): Boolean {
        return try {
            val telecomManager = getSystemService(TelecomManager::class.java)
            val defaultPackage = telecomManager?.defaultDialerPackage
            if (packageName == defaultPackage) return true

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val roleManager = getSystemService(RoleManager::class.java)
                return roleManager != null && roleManager.isRoleHeld(RoleManager.ROLE_DIALER)
            }
            false
        } catch (e: Exception) {
            false
        }
    }

    private fun requestDialerRole() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val roleManager = getSystemService(RoleManager::class.java)
                if (roleManager != null && roleManager.isRoleAvailable(RoleManager.ROLE_DIALER)) {
                    val intent = roleManager.createRequestRoleIntent(RoleManager.ROLE_DIALER)
                    startActivityForResult(intent, roleRequestCode)
                    return
                }
            }
            // Pre-Android 10 & legacy fallback
            val intent = Intent(TelecomManager.ACTION_CHANGE_DEFAULT_DIALER)
            intent.putExtra(TelecomManager.EXTRA_CHANGE_DEFAULT_DIALER_PACKAGE_NAME, packageName)
            startActivityForResult(intent, roleRequestCode)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
