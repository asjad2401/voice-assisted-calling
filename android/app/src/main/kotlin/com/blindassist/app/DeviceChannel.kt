package com.blindassist.app

import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.telephony.SmsManager
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

/**
 * Small device utilities used by the Flutter side: sine-wave beeps (for the
 * object-finder "Geiger counter" and turn guidance), sending SMS for SOS
 * alerts (works without internet), and keeping the screen on while walking.
 */
class DeviceChannel(private val activity: Activity, messenger: BinaryMessenger) {

    private val audioExecutor = Executors.newSingleThreadExecutor()

    init {
        MethodChannel(messenger, "vision_assist/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "beep" -> {
                    val freq = call.argument<Int>("freq") ?: 880
                    val ms = call.argument<Int>("ms") ?: 80
                    val vol = (call.argument<Double>("vol") ?: 0.6).toFloat()
                    audioExecutor.execute { playTone(freq, ms, vol) }
                    result.success(null)
                }
                "sendSms" -> {
                    val number = call.argument<String>("number")
                    val text = call.argument<String>("text")
                    if (number.isNullOrBlank() || text.isNullOrBlank()) {
                        result.error("bad_args", "number and text required", null)
                    } else if (activity.checkSelfPermission(android.Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
                        result.error("no_permission", "SEND_SMS not granted", null)
                    } else {
                        try {
                            sendSms(number, text)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("sms_failed", e.message, null)
                        }
                    }
                }
                "keepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    activity.runOnUiThread {
                        if (on) activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun sendSms(number: String, text: String) {
        val sms: SmsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
        val parts = sms.divideMessage(text)
        if (parts.size > 1) sms.sendMultipartTextMessage(number, null, parts, null, null)
        else sms.sendTextMessage(number, null, text, null, null)
    }

    private fun playTone(freq: Int, ms: Int, volume: Float) {
        val sampleRate = 22050
        val n = (sampleRate * ms / 1000).coerceAtLeast(64)
        val samples = ShortArray(n)
        val fade = min(n / 4, sampleRate / 200) // ~5 ms fade to avoid clicks
        for (i in 0 until n) {
            var amp = 1.0
            if (i < fade) amp = i / fade.toDouble()
            if (i > n - fade) amp = (n - i) / fade.toDouble()
            samples[i] = (sin(2.0 * PI * freq * i / sampleRate) * amp * Short.MAX_VALUE * volume).toInt().toShort()
        }
        try {
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(n * 2)
                .build()
            track.write(samples, 0, n)
            track.play()
            Thread.sleep(ms.toLong() + 20)
            track.release()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
