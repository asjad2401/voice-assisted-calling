package com.blindassist.call

import io.flutter.plugin.common.EventChannel

/**
 * Static relay bridge between Android native InCallService and Flutter EventChannel.
 * Retains incoming call events and buffers recent state changes so Flutter never misses
 * call ringing/active/ended notifications.
 */
object CallEventBridge : EventChannel.StreamHandler {

    private var sink: EventChannel.EventSink? = null
    private val pendingEvents = mutableListOf<Map<String, Any?>>()

    fun emit(event: Map<String, Any?>) {
        val currentSink = sink
        if (currentSink != null) {
            try {
                currentSink.success(event)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        } else {
            synchronized(pendingEvents) {
                pendingEvents.add(event)
                // Limit buffer size
                if (pendingEvents.size > 10) {
                    pendingEvents.removeAt(0)
                }
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (events != null) {
            synchronized(pendingEvents) {
                for (event in pendingEvents) {
                    events.success(event)
                }
                pendingEvents.clear()
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}
