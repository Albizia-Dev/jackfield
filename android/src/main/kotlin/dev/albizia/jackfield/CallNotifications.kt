package dev.albizia.jackfield

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import dev.albizia.jackfield.push.JackfieldActionReceiver
import dev.albizia.jackfield.store.CallEntity

internal class CallNotifications(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)
    init {
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Incoming and active internet calls"
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                enableVibration(false)
                setSound(null, null)
            },
        )
    }
    fun permitted() = NotificationManagerCompat.from(context).areNotificationsEnabled() && manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
    fun fullScreenPermitted() = Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE || manager.canUseFullScreenIntent()
    fun show(call: CallEntity) {
        ContextCompat.startForegroundService(context, JackfieldCallService.showIntent(context, call))
    }
    fun activate(callId: String) {
        ContextCompat.startForegroundService(context, JackfieldCallService.activateIntent(context, callId))
    }
    fun end(callId: String) {
        manager.cancel(notificationId(callId))
        try { context.startService(JackfieldCallService.endIntent(context, callId)) } catch (_: IllegalStateException) { /* Nothing remains to stop. */ }
    }
    companion object {
        const val CHANNEL = "jackfield.calls.v3"
        fun notificationId(callId: String) = (callId.hashCode() and Int.MAX_VALUE).coerceAtLeast(1)
        fun build(context: Context, call: CallEntity) = build(context, call.callId, call.callerName, call.state)
        fun build(context: Context, callId: String, callerName: String, state: String): android.app.Notification {
            val person = Person.Builder().setName(callerName).setImportant(true).build()
            val incoming = state == "ringing"
            val decline = action(context, callId, if (incoming) "reject" else "end")
            val style = if (incoming) NotificationCompat.CallStyle.forIncomingCall(person, decline, action(context, callId, "answer"))
                else NotificationCompat.CallStyle.forOngoingCall(person, decline)
            return NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.sym_call_incoming)
                .setContentTitle(callerName)
                .setContentText(if (incoming) "Incoming call" else if (state == "connecting") "Connecting" else "Call in progress")
                .setCategory(NotificationCompat.CATEGORY_CALL).setOngoing(true).setStyle(style)
                .setContentIntent(fullScreen(context, callId, callerName))
                .setFullScreenIntent(if (incoming) fullScreen(context, callId, callerName) else null, true)
                .setSound(null)
                .setVibrate(null)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC).setPriority(NotificationCompat.PRIORITY_MAX)
                .build()
        }
        private fun fullScreen(context: Context, callId: String, callerName: String): PendingIntent {
            val intent = Intent(context, JackfieldIncomingCallActivity::class.java).apply {
                data = Uri.Builder().scheme("jackfield").authority("incoming").appendPath(callId).build()
                putExtra("callId", callId)
                putExtra("callerName", callerName)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            return PendingIntent.getActivity(
                context,
                notificationId(callId),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        private fun action(context: Context, callId: String, action: String): PendingIntent {
            val intent = Intent(context, JackfieldActionReceiver::class.java).apply {
                this.action = action
                data = Uri.Builder().scheme("jackfield").authority("action").appendPath(callId).appendPath(action).build()
                putExtra("callId", callId)
            }
            return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
    }
}
