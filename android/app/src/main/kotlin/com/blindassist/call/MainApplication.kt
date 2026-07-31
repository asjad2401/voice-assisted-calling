package com.blindassist.call

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

class MainApplication : Application() {

    companion object {
        const val BACKGROUND_ENGINE_ID = "blind_call_bg_engine"
        var backgroundFlutterEngine: FlutterEngine? = null
            private set
    }

    override fun onCreate() {
        super.onCreate()
        // Pre-warm Flutter engine for background incoming call reliability using Android v2 embedding
        try {
            val engine = FlutterEngine(this)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
            FlutterEngineCache.getInstance().put(BACKGROUND_ENGINE_ID, engine)
            backgroundFlutterEngine = engine
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
