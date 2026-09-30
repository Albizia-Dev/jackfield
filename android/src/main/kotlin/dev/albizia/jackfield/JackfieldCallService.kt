package dev.albizia.jackfield

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import dev.albizia.jackfield.store.CallEntity

/** Owns the mandatory CallStyle foreground notification on Android 14+. */
internal class JackfieldCallService : Service() {
    private val active = linkedMapOf<String, Notification>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callId = intent?.getStringExtra(EXTRA_CALL_ID) ?: return START_NOT_STICKY
        when (intent.action) {
            ACTION_SHOW -> {
                val notification = CallNotifications.build(
                    this,
                    callId,
                    intent.getStringExtra(EXTRA_CALLER_NAME).orEmpty(),
                    intent.getStringExtra(EXTRA_STATE).orEmpty(),
                )
                active[callId] = notification
                promote(callId, notification)
            }
            ACTION_END -> {
                active.remove(callId)
                getSystemService(android.app.NotificationManager::class.java)
                    .cancel(CallNotifications.notificationId(callId))
                val replacement = active.entries.lastOrNull()
                if (replacement == null) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                } else {
                    promote(replacement.key, replacement.value)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun promote(callId: String, notification: Notification) {
        val id = CallNotifications.notificationId(callId)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
        } else {
            startForeground(id, notification)
        }
    }

    companion object {
        private const val ACTION_SHOW = "dev.albizia.jackfield.SHOW_CALL"
        private const val ACTION_END = "dev.albizia.jackfield.END_CALL"
        private const val EXTRA_CALL_ID = "callId"
        private const val EXTRA_CALLER_NAME = "callerName"
        private const val EXTRA_STATE = "state"

        fun showIntent(context: Context, call: CallEntity) = Intent(context, JackfieldCallService::class.java).apply {
            action = ACTION_SHOW
            putExtra(EXTRA_CALL_ID, call.callId)
            putExtra(EXTRA_CALLER_NAME, call.callerName)
            putExtra(EXTRA_STATE, call.state)
        }

        fun endIntent(context: Context, callId: String) = Intent(context, JackfieldCallService::class.java).apply {
            action = ACTION_END
            putExtra(EXTRA_CALL_ID, callId)
        }
    }
}
