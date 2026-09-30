package dev.albizia.jackfield_example

import android.content.Intent
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dev.albizia.jackfield.push.JackfieldPushReceiver
import org.json.JSONObject

class JackfieldFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        super.onNewToken(token)
        TestBackendRegistration.updateToken(applicationContext, token)
        Log.i(TAG, "stage=fcm.token_refreshed")
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        Log.i(TAG, "stage=fcm.received keys=${message.data.keys.sorted().joinToString(",")}")
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
                    .put("reason", parsed.reason),
            )
            null -> Log.w(TAG, "stage=fcm.ignored reason=invalid_or_unsupported")
        }
    }

    private fun dispatch(action: String, payload: JSONObject) {
        sendBroadcast(
            Intent(this, JackfieldPushReceiver::class.java)
                .setAction(action)
                .putExtra("payload", payload.toString()),
        )
        Log.i(TAG, "stage=fcm.dispatched action=$action")
    }

    companion object {
        private const val TAG = "JackfieldExample"
    }
}
