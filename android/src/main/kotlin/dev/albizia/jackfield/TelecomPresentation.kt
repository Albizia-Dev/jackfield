package dev.albizia.jackfield

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.telecom.DisconnectCause
import androidx.core.content.ContextCompat
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallsManager
import dev.albizia.jackfield.store.CallEntity
import kotlinx.coroutines.*
import java.util.concurrent.ConcurrentHashMap

/** Core-Telecom sessions plus the mandatory CallStyle notification, with explicit fallback. */
internal class TelecomPresentation(
    private val context: Context,
    private val scope: CoroutineScope,
    private val controls: MutableMap<String, CallControlScope> = ConcurrentHashMap(),
) : CallPresentation {
    private val notifications = CallNotifications(context)
    private val waitingForAnswer = ConcurrentHashMap.newKeySet<String>()
    private var manager: CallsManager? = null
    @Volatile private var fallback = false
    lateinit var controller: CallController
    var answer: suspend (String) -> Boolean = { false }
    init {
        if (ownCallsPermission()) try {
            manager = CallsManager(context).also { it.registerAppWithTelecom(CallsManager.CAPABILITY_SUPPORTS_VIDEO_CALLING) }
            JackfieldLog.info("telecom.registered")
        } catch (error: Exception) {
            fallback = true
            JackfieldLog.warn("telecom.registration_failed", error = error)
        }
    }
    private fun ownCallsPermission() = ContextCompat.checkSelfPermission(context, Manifest.permission.MANAGE_OWN_CALLS) == PackageManager.PERMISSION_GRANTED
    override val mechanism: String get() = when {
        !notifications.permitted() -> "unavailable"
        manager != null && !fallback && ownCallsPermission() -> "nativeCallUi"
        else -> "systemNotification"
    }
    override fun permissions() = mapOf(
        "manageOwnCalls" to if (ownCallsPermission()) "granted" else "denied",
        "notifications" to if (notifications.permitted()) "granted" else "denied",
        "fullScreenIntent" to if (notifications.fullScreenPermitted()) "granted" else "denied",
    )

    override suspend fun show(call: CallEntity, incoming: Boolean) {
        if (!notifications.permitted()) throw JackfieldFailure("permissionDenied")
        JackfieldLog.info("presentation.show", call.callId, "incoming=$incoming mechanism=$mechanism")
        val telecom = manager
        if (telecom != null && !fallback && ownCallsPermission()) {
            val registered = CompletableDeferred<Boolean>()
            val job = scope.launch {
                var added = false
                try {
                    telecom.addCall(
                        CallAttributesCompat(call.callerName, Uri.fromParts("sip", call.callerId, null),
                            if (incoming) CallAttributesCompat.DIRECTION_INCOMING else CallAttributesCompat.DIRECTION_OUTGOING,
                            if (call.media == "video") CallAttributesCompat.CALL_TYPE_VIDEO_CALL else CallAttributesCompat.CALL_TYPE_AUDIO_CALL,
                            callCapabilities = 0),
                        onAnswer = {
                            waitingForAnswer.add(call.callId)
                            try { if (!answer(call.callId)) throw JackfieldFailure("temporarilyUnavailable") }
                            finally { waitingForAnswer.remove(call.callId) }
                        },
                        onDisconnect = { cause ->
                            controls.remove(call.callId)
                            controller.endCall(call.callId, if (cause.code == DisconnectCause.REJECTED) "rejected" else "local")
                        },
                        // v1 has no hold/mute events. Never acknowledge a media change the host cannot observe.
                        onSetActive = { if (controller.snapshot(call.callId)?.state != "active") throw JackfieldFailure("unsupported") },
                        onSetInactive = { throw JackfieldFailure("unsupported") },
                    ) {
                        controls[call.callId] = this
                        added = true
                        notifications.show(call)
                        JackfieldLog.info("telecom.call_added", call.callId)
                        registered.complete(true)
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) {
                    JackfieldLog.error("telecom.call_failed", call.callId, failure)
                    registered.complete(false)
                    if (added) {
                        controls.remove(call.callId)
                        controller.recordError(failure)
                        try { controller.endCall(call.callId, "failed") } catch (error: Exception) { controller.recordError(error) }
                    }
                } finally { controls.remove(call.callId) }
            }
            if (withTimeoutOrNull(6000) { registered.await() } == true) return
            job.cancel()
            fallback = true
            JackfieldLog.warn("telecom.timeout_fallback", call.callId)
        }
        notifications.show(call)
        JackfieldLog.info("presentation.notification_fallback", call.callId)
    }
    override suspend fun update(call: CallEntity) { notifications.show(call) }
    override suspend fun activate(call: CallEntity) {
        if (waitingForAnswer.contains(call.callId)) return
        controls[call.callId]?.let { control ->
            val result = if (call.actionId == null) control.setActive()
                else control.answer(if (call.media == "video") CallAttributesCompat.CALL_TYPE_VIDEO_CALL else CallAttributesCompat.CALL_TYPE_AUDIO_CALL)
            if (result !is CallControlResult.Success) throw JackfieldFailure("temporarilyUnavailable")
        }
        notifications.activate(call.callId)
        JackfieldLog.info("presentation.activated", call.callId)
    }
    override suspend fun end(callId: String) {
        JackfieldLog.info("presentation.end", callId)
        notifications.end(callId)
        controls[callId]?.let { control ->
            try {
                if (control.disconnect(DisconnectCause(DisconnectCause.LOCAL)) !is CallControlResult.Success) throw JackfieldFailure("temporarilyUnavailable")
            } finally {
                // addCall completes after either result and removes this session's control.
                controls.remove(callId, control)
            }
        }
    }
}
