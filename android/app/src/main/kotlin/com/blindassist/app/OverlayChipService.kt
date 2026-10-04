package com.blindassist.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView

/**
 * Keeps a round Life Lense chip floating in the top-right corner over other
 * apps, so the app is always one tap away. The chip is hidden while Life
 * Lense itself is on screen. Needs the "Display over other apps" permission;
 * runs as a foreground service so Android does not remove it.
 */
class OverlayChipService : Service() {

    companion object {
        private const val CHANNEL_ID = "overlay_chip"
        private const val NOTIFICATION_ID = 7301
        private const val CHIP_DP = 44

        private var instance: OverlayChipService? = null
        private var appVisible = false

        fun canShow(context: Context) = Settings.canDrawOverlays(context)

        fun start(context: Context) {
            if (!canShow(context)) return
            try {
                context.startForegroundService(Intent(context, OverlayChipService::class.java))
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        /** Called by MainActivity as it comes to the front or leaves it. */
        fun setAppVisible(visible: Boolean) {
            appVisible = visible
            instance?.updateVisibility()
        }
    }

    private var chip: View? = null
    private val windowManager by lazy { getSystemService(WINDOW_SERVICE) as WindowManager }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        if (!canShow(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (chip == null) addChip()
        updateVisibility()
        return START_STICKY
    }

    override fun onDestroy() {
        chip?.let { runCatching { windowManager.removeView(it) } }
        chip = null
        if (instance == this) instance = null
        super.onDestroy()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun statusBarHeight(): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val top = runCatching {
                windowManager.currentWindowMetrics.windowInsets
                    .getInsets(WindowInsets.Type.statusBars() or WindowInsets.Type.displayCutout()).top
            }.getOrDefault(0)
            if (top > 0) return top
        }
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else dp(24)
    }

    private fun addChip() {
        val size = dp(CHIP_DP)
        val view = FrameLayout(this).apply {
            background = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(Color.parseColor("#14336B"), Color.parseColor("#081530"))
            ).apply {
                // Quarter circle hugging the screen corner: only the inner
                // (bottom-left) corner is rounded, so the square touch area
                // reaches right into the corner a finger can find by feel.
                val r = size.toFloat()
                cornerRadii = floatArrayOf(0f, 0f, 0f, 0f, 0f, 0f, r, r)
                setStroke(dp(2), Color.parseColor("#FFB300"))
            }
            elevation = dp(8).toFloat()
            contentDescription = getString(R.string.overlay_chip_description)
            isClickable = true
            isFocusable = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            setOnClickListener {
                it.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                openApp()
            }
            addView(
                ImageView(this@OverlayChipService).apply {
                    setImageResource(R.drawable.ic_launcher_foreground)
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                    // Nudge the eye toward the corner so it sits inside the
                    // quarter circle rather than on its curved edge.
                    translationX = dp(4).toFloat()
                    translationY = -dp(4).toFloat()
                },
                FrameLayout.LayoutParams(size, size)
            )
        }
        val params = WindowManager.LayoutParams(
            size, size,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            // Flush with the right edge and directly under the status bar:
            // overlays sit below the status bar, which would swallow taps.
            gravity = Gravity.TOP or Gravity.END
            x = 0
            y = statusBarHeight()
            // Position from the true screen edge rather than inside the insets.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) fitInsetsTypes = 0
        }
        try {
            windowManager.addView(view, params)
            chip = view
        } catch (e: Exception) {
            e.printStackTrace()
            stopSelf()
        }
    }

    private fun updateVisibility() {
        chip?.visibility = if (appVisible) View.GONE else View.VISIBLE
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        startActivity(intent)
    }

    private fun startInForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.overlay_chip_channel),
                    NotificationManager.IMPORTANCE_MIN
                ).apply { setShowBadge(false) }
            )
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(getString(R.string.overlay_chip_notification))
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}
