package dev.albizia.jackfield.push

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.albizia.jackfield.JackfieldRuntime
import dev.albizia.jackfield.JackfieldLog
import dev.albizia.jackfield.Wire
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Provider-neutral entrypoint. The host authenticates and normalizes provider payloads first. */
class JackfieldPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        JackfieldLog.info("push.received", detail = "action=${intent.action}")
        val runtime = try { JackfieldRuntime.get(context) } catch (error: Exception) {
            JackfieldLog.error("push.runtime_failed", error = error)
            pending.finish()
            return
        }
        runtime.scope.launch {
            try {
                val payload = Wire.jsonMap(JSONObject(intent.getStringExtra("payload") ?: Wire.fail()))
                when (intent.action) {
                    ACTION_INCOMING -> {
                        val call = runtime.controller.reportIncoming(payload)
                        JackfieldLog.info("push.incoming_presented", call.callId)
                    }
                    ACTION_END -> {
                        val data = Wire.request(payload, setOf("callId", "reason"))
                        val callId = Wire.string(data["callId"])
                        val reason = Wire.reason(data["reason"])
                        runtime.controller.endCall(callId, reason)
                        JackfieldLog.info("push.end_applied", callId, "reason=$reason")
                    }
                    else -> Wire.fail()
                }
            } catch (error: Exception) {
                JackfieldLog.error("push.processing_failed", error = error)
                runtime.controller.recordError(error)
            }
            finally { pending.finish() }
        }
    }
    companion object {
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
        val runtime = try { JackfieldRuntime.get(context) } catch (_: Exception) { pending.finish(); return }
        runtime.scope.launch {
            try {
                val id = Wire.string(intent.getStringExtra("callId"))
                JackfieldLog.info("action.received", id, "action=${intent.action}")
                when (intent.action) {
                    "answer" -> {
                        runtime.answer(id, 30_000)
                        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
                            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                            launch.putExtra("jackfieldCallId", id)
                            context.startActivity(launch)
                        }
                        JackfieldLog.info("action.answer_completed", id)
                    }
                    "reject" -> {
                        runtime.controller.endCall(id, "rejected")
                        JackfieldLog.info("action.reject_completed", id)
                    }
                    "end" -> {
                        runtime.controller.endCall(id, "local")
                        JackfieldLog.info("action.end_completed", id)
                    }
                    else -> Wire.fail()
                }
            } catch (error: Exception) {
                JackfieldLog.error("action.failed", error = error)
                runtime.controller.recordError(error)
            }
            finally { pending.finish() }
        }
    }
}
