package dev.albizia.jackfield

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import dev.albizia.jackfield.push.JackfieldActionReceiver
import dev.albizia.jackfield.store.CallEntity

internal class CallNotifications(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)
    init { manager.createNotificationChannel(NotificationChannel(CHANNEL, "Calls", NotificationManager.IMPORTANCE_HIGH)) }
    fun permitted() = NotificationManagerCompat.from(context).areNotificationsEnabled() && manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
    fun show(call: CallEntity) {
        ContextCompat.startForegroundService(context, JackfieldCallService.showIntent(context, call))
    }
    fun end(callId: String) {
        manager.cancel(notificationId(callId))
        try { context.startService(JackfieldCallService.endIntent(context, callId)) } catch (_: IllegalStateException) { /* Nothing remains to stop. */ }
    }
    companion object {
        const val CHANNEL = "jackfield.calls.v1"
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
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()
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
