package com.example.unisson

import android.webkit.CookieManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "unisson/cookies")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Returns the exact cookie header a WebView would send
                    // for [url] ("a=1; b=2; ..."). Shared store across all
                    // WebViews in the app, HttpOnly cookies included.
                    "getCookies" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("INVALID_ARGUMENT", "url is required", null)
                        } else {
                            val cookies = CookieManager.getInstance().getCookie(url) ?: ""
                            result.success(cookies)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
