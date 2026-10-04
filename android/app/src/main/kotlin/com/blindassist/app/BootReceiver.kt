package com.blindassist.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Brings the floating Life Lense chip back after the phone restarts. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            OverlayChipService.start(context)
        }
    }
}
