package net.geraldhofbauer.chattr

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity!) — local_auth's BiometricPrompt
// needs a FragmentActivity. With a plain FlutterActivity every authenticate()
// call throws immediately, so all biometric-gated data access silently failed
// on Android (empty chat list, undecryptable messages).
class MainActivity : FlutterFragmentActivity() {
    private val channel = "chattr/screen_security"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Toggle FLAG_SECURE: blocks screenshots, screen recording
                    // and hides app content in the recent-apps preview.
                    "setSecure" -> {
                        val secure = call.arguments as? Boolean ?: false
                        runOnUiThread {
                            if (secure) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
