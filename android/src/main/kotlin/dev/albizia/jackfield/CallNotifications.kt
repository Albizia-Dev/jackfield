package dev.albizia.jackfield

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
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
        val person = Person.Builder().setName(call.callerName).setImportant(true).build()
        val incoming = call.state == "ringing"
        val decline = action(call.callId, if (incoming) "reject" else "end")
        val style = if (incoming) NotificationCompat.CallStyle.forIncomingCall(person, decline, action(call.callId, "answer"))
            else NotificationCompat.CallStyle.forOngoingCall(person, decline)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle(call.callerName)
            .setContentText(if (incoming) "Incoming call" else if (call.state == "connecting") "Connecting" else "Call in progress")
            .setCategory(NotificationCompat.CATEGORY_CALL).setOngoing(true).setStyle(style)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        manager.notify(tag(call.callId), 1, notification)
    }
    fun end(callId: String) { manager.cancel(tag(callId), 1) }
    private fun action(callId: String, action: String): PendingIntent {
        val intent = Intent(context, JackfieldActionReceiver::class.java).apply {
            this.action = action
            data = Uri.Builder().scheme("jackfield").authority("action").appendPath(callId).appendPath(action).build()
            putExtra("callId", callId)
        }
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private fun tag(id: String) = "jackfield:$id"
    companion object { const val CHANNEL = "jackfield.calls.v1" }
}
