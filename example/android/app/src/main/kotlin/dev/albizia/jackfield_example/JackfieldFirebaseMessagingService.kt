package dev.albizia.jackfield_example

import android.content.Intent
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dev.albizia.jackfield.push.JackfieldPushReceiver
import org.json.JSONObject

class JackfieldFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        super.onNewToken(token)
        TestBackendRegistration.updateToken(applicationContext, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        when (val parsed = JackfieldFirebaseMessage.parse(message.data)) {
            is JackfieldFirebaseMessage.Incoming -> dispatch(
                JackfieldPushReceiver.ACTION_INCOMING,
                JSONObject()
                    .put("version", 1)
                    .put("callId", parsed.callId)
                    .put(
                        "caller",
                        JSONObject()
                            .put("id", parsed.callerId)
                            .put("displayName", parsed.callerName),
                    )
                    .put("media", parsed.media),
            )
            is JackfieldFirebaseMessage.End -> dispatch(
                JackfieldPushReceiver.ACTION_END,
                JSONObject()
                    .put("version", 1)
                    .put("callId", parsed.callId)
                    .put("reason", "remote"),
            )
            null -> Unit
        }
    }

    private fun dispatch(action: String, payload: JSONObject) {
        sendBroadcast(
            Intent(action)
                .setPackage(packageName)
                .putExtra("payload", payload.toString()),
        )
    }
}
