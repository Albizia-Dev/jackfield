package dev.albizia.jackfield.push

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import dev.albizia.jackfield.JackfieldRuntime
import dev.albizia.jackfield.Wire
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Provider-neutral entrypoint. The host authenticates and normalizes provider payloads first. */
class JackfieldPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val runtime = try {
            JackfieldRuntime.get(context)
        } catch (error: Exception) {
            Log.e(TAG, "stage=push.runtime_failed action=${intent.action}", error)
            pending.finish()
            return
        }
        runtime.scope.launch {
            try {
                val payload = Wire.jsonMap(JSONObject(intent.getStringExtra("payload") ?: Wire.fail()))
                when (intent.action) {
                    ACTION_INCOMING -> {
                        Log.i(TAG, "stage=push.incoming callId=${payload["callId"]}")
                        runtime.controller.reportIncoming(payload)
                    }
                    ACTION_END -> {
                        val data = Wire.request(payload, setOf("callId", "reason"))
                        val callId = Wire.string(data["callId"])
                        val reason = Wire.reason(data["reason"])
                        Log.i(TAG, "stage=push.end callId=$callId reason=$reason")
                        runtime.controller.endCall(callId, reason)
                    }
                    else -> Wire.fail()
                }
            } catch (error: Exception) {
                Log.e(TAG, "stage=push.failed action=${intent.action}", error)
                runtime.controller.recordError(error)
            }
            finally { pending.finish() }
        }
    }
    companion object {
        private const val TAG = "JackfieldCallFlow"
        const val ACTION_INCOMING = "dev.albizia.jackfield.INCOMING"
        const val ACTION_END = "dev.albizia.jackfield.END"
        /** Invoke from a provider service without creating a Flutter engine. Returns wire v1. */
        suspend fun reportIncomingCall(context: Context, payload: Map<String, Any?>): Map<String, Any?> = withContext(Dispatchers.IO) {
            try { Wire.success(JackfieldRuntime.get(context).controller.reportIncoming(payload).toWire()) }
            catch (error: Exception) { Wire.failure(error) }
        }
        /** Persist an explicitly added or removed provider token; no provider SDK is bundled. */
        suspend fun updatePushToken(context: Context, provider: String, value: String, removed: Boolean = false): Map<String, Any?> = withContext(Dispatchers.IO) {
            try { JackfieldRuntime.get(context).controller.updatePushToken(provider, value, removed); Wire.success() }
            catch (error: Exception) { Wire.failure(error) }
        }
    }
}

class JackfieldActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val runtime = try {
            JackfieldRuntime.get(context)
        } catch (error: Exception) {
            Log.e(TAG, "stage=action.runtime_failed action=${intent.action}", error)
            pending.finish()
            return
        }
        runtime.scope.launch {
            try {
                val id = Wire.string(intent.getStringExtra("callId"))
                Log.i(TAG, "stage=action.received action=${intent.action} callId=$id")
                when (intent.action) {
                    "answer" -> runtime.answer(id)
                    "reject" -> runtime.controller.endCall(id, "rejected")
                    "end" -> runtime.controller.endCall(id, "local")
                    else -> Wire.fail()
                }
            } catch (error: Exception) {
                Log.e(TAG, "stage=action.failed action=${intent.action}", error)
                runtime.controller.recordError(error)
            }
            finally { pending.finish() }
        }
    }

    private companion object {
        const val TAG = "JackfieldCallFlow"
    }
}
