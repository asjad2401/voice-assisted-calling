package com.blindassist.app

import android.app.Application

/**
 * Application entry point.
 *
 * The earlier call-assistant build pre-warmed a second FlutterEngine here, but
 * MainActivity never attached to it, so Dart's main() ran twice (a headless
 * copy that also spoke and grabbed the microphone). Call events are buffered
 * by [CallEventBridge] and the InCallService brings MainActivity to the front
 * instead, so no extra engine is needed.
 */
class MainApplication : Application()
