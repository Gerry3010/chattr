// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

package net.geraldhofbauer.chattr

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps a call alive while the app is in the background.
 *
 * Without it Android takes the call away the moment the user leaves the app:
 * the microphone is a while-in-use permission (app op RECORD_AUDIO "foreground"),
 * and since Android 15 "AudioHardening" also mutes background playback and
 * ignores the app's audio-focus request. Measured on the Galaxy (2026-10-05):
 * the call did not drop, it went deaf and dumb in both directions — reported
 * from a Pixel as "der Anruf bricht ab". iOS keeps it through its audio session.
 *
 * A foreground service of type phoneCall|microphone is what Android sets aside
 * for exactly this: with it the app keeps both while the call lasts, and the
 * user sees an ongoing-call notification that leads back to it. Started by the
 * call controller when a call is under way (always from the foreground, as the
 * microphone type requires), stopped when it ends.
 *
 * flutter_callkit_incoming has a similar service, but starts it only for calls
 * taken in the system UI and only with the phoneCall type — not for a call
 * dialled or answered inside the app, which is most of them.
 */
class CallForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HANG_UP) {
            // Flutter ends the call; its controller then stops this service.
            Handler(Looper.getMainLooper()).post { channel?.invokeMethod("hangUp", null) }
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Chattr"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val hangUp = intent?.getStringExtra(EXTRA_HANG_UP) ?: "Auflegen"
        val types = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        } else 0
        ServiceCompat.startForeground(
            this, NOTIFICATION_ID, buildNotification(title, text, hangUp), types,
        )
        // A killed process must not resurrect a call that no longer exists.
        return START_NOT_STICKY
    }

    private fun buildNotification(title: String, text: String, hangUpLabel: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(CHANNEL_ID) == null
        ) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, title, NotificationManager.IMPORTANCE_LOW)
                    .apply { setShowBadge(false) }
            )
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        val tap = open?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        // Ending the call must not require opening the app — the plugin's own
        // notification had a button, and with it hidden this one takes over.
        val hangUp = PendingIntent.getService(
            this, 1,
            Intent(this, CallForegroundService::class.java).setAction(ACTION_HANG_UP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_chattr)
            .setContentTitle(title)
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(tap)
            .addAction(0, hangUpLabel, hangUp)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "chattr_call_ongoing"
        private const val NOTIFICATION_ID = 4711
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_HANG_UP = "hangUp"
        private const val ACTION_HANG_UP = "net.geraldhofbauer.chattr.CALL_HANG_UP"

        /** The channel of the engine that runs the call, for the hang-up button. */
        private var channel: MethodChannel? = null

        fun register(context: Context, messenger: BinaryMessenger) {
            val methods = MethodChannel(messenger, "chattr/call_service")
            channel = methods
            methods.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(context, CallForegroundService::class.java)
                            .putExtra(EXTRA_TITLE, call.argument<String>("title"))
                            .putExtra(EXTRA_TEXT, call.argument<String>("text"))
                            .putExtra(EXTRA_HANG_UP, call.argument<String>("hangUp"))
                        try {
                            androidx.core.content.ContextCompat.startForegroundService(context, intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // Not allowed right now (e.g. started from the
                            // background): the call goes on, only without the
                            // keep-alive — never take the call down for it.
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        context.stopService(Intent(context, CallForegroundService::class.java))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
