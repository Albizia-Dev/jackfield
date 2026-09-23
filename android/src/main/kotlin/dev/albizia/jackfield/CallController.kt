package dev.albizia.jackfield

import dev.albizia.jackfield.http.CallbackConfiguration
import dev.albizia.jackfield.http.ConfigurationStore
import dev.albizia.jackfield.http.ConfigurationLock
import dev.albizia.jackfield.store.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import java.util.UUID

interface CallPresentation {
    val mechanism: String
    fun permissions(): Map<String, String>
    suspend fun show(call: CallEntity, incoming: Boolean)
    suspend fun update(call: CallEntity)
    suspend fun activate(call: CallEntity)
    suspend fun end(callId: String)
}

/** Native owner shared by Flutter, Telecom, push and background workers. All callers use IO. */
class CallController(
    private val database: JackfieldDatabase,
    private val presentation: CallPresentation,
    private val configuration: ConfigurationStore,
    private val schedule: (String, Long) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val eventId: () -> String = { UUID.randomUUID().toString() },
) {
    private val mutex = Mutex()
    private val dao get() = database.events()
    @Volatile var eventListener: ((Map<String, Any?>) -> Unit)? = null
    @Volatile var tokenListener: ((Map<String, Any?>) -> Unit)? = null

    suspend fun initialize(callbacks: CallbackConfiguration?) = mutex.withLock {
        synchronized(ConfigurationLock) {
            // An explicit replacement can recover unreadable ciphertext without reading its old token.
            val previous = try { configuration.load() } catch (error: Exception) { recordError(error); null }
            // Upgrade a v1 pause before the file write, so a crash still leaves a comparison baseline.
            if (callbacks != null && dao.httpPaused() && dao.state()?.rejectedAuthFingerprint == null) {
                dao.pauseForAuthentication(previous?.authFingerprint() ?: "unreadable")
            }
            configuration.save(callbacks)
            if (callbacks != null) dao.resumeIfCredentialsChanged(callbacks.authFingerprint())
        }
        if (callbacks != null) dao.pendingCallIds().forEach { schedule(it, 0) }
    }

    suspend fun reportIncoming(arguments: Map<String, Any?>): CallEntity = start(arguments, true)
    suspend fun startOutgoing(arguments: Map<String, Any?>): CallEntity = start(arguments, false)
    private suspend fun start(arguments: Map<String, Any?>, incoming: Boolean): CallEntity = mutex.withLock {
        val partyField = if (incoming) "caller" else "callee"
        val data = Wire.request(arguments, setOf("callId", partyField, "media"))
        val id = Wire.string(data["callId"])
        val party = Wire.caller(data[partyField])
        val media = Wire.media(data["media"])
        dao.call(id)?.let { return@withLock it }
        val call = CallEntity(id, if (incoming) "ringing" else "connecting", media, party.getValue("id"), party.getValue("displayName"))
        dao.persist(call, null, 0)
        try { presentation.show(call, incoming) }
        catch (error: Exception) { dao.saveCall(call.copy(state = "failed")); throw error }
        call
    }

    suspend fun updateCall(arguments: Map<String, Any?>): CallEntity = mutex.withLock {
        val data = Wire.request(arguments, setOf("callId"), setOf("caller", "media"))
        val current = requireCall(Wire.string(data["callId"]))
        if (current.state in setOf("ended", "failed")) throw JackfieldFailure("invalidState")
        val party = if (data.containsKey("caller")) Wire.caller(data["caller"]) else null
        val next = current.copy(callerId = party?.get("id") ?: current.callerId, callerName = party?.get("displayName") ?: current.callerName, media = if (data.containsKey("media")) Wire.media(data["media"]) else current.media)
        dao.saveCall(next)
        presentation.update(next)
        next
    }

    suspend fun requestAnswer(callId: String, actionId: String = UUID.randomUUID().toString(), deadline: Long = boundedAdd(clock(), 4500)): CallEntity = mutex.withLock {
        Wire.string(actionId)
        val current = requireCall(callId)
        current.receipts().firstOrNull { it["actionId"] == actionId }?.let { receipt ->
            val error = receipt["error"] as? Map<*, *>
            if (error != null) throw JackfieldFailure(error["code"] as String)
            return@withLock current
        }
        if (current.actionId == actionId) return@withLock current
        if (current.state != "ringing") throw JackfieldFailure("invalidState")
        val now = clock()
        val expired = now > deadline
        val receipts = if (expired) JSONArray(current.receipts() + mapOf("actionId" to actionId, "succeeded" to false, "error" to mapOf("code" to "deadlineExceeded"))).toString() else current.actionReceipts
        val next = current.copy(state = if (expired) "failed" else "connecting", actionId = actionId, actionDeadline = deadline, sequence = current.sequence + 1, actionReceipts = receipts)
        val config = configuration.load()
        val event = EventEntity(eventId(), callId, next.sequence, now, "answer_requested", actionId = actionId, deadline = deadline,
            expiresAt = boundedAdd(now, config?.timeToLiveMs ?: 86_400_000), httpState = if (config == null) "disabled" else "pending")
        admit(next, event, config)
        if (expired) { presentation.end(callId); throw JackfieldFailure("deadlineExceeded") }
        presentation.update(next)
        next
    }

    suspend fun completeAction(actionId: String, succeeded: Boolean) = mutex.withLock {
        val current = dao.calls().firstOrNull { it.actionId == actionId || it.receipts().any { receipt -> receipt["actionId"] == actionId } }
            ?: throw JackfieldFailure("invalidState")
        current.receipts().firstOrNull { it["actionId"] == actionId }?.let { receipt ->
            @Suppress("UNCHECKED_CAST") val error = receipt["error"] as? Map<String, Any?>
            if (error != null) throw JackfieldFailure(error["code"] as String)
            return@withLock
        }
        if (current.state != "connecting" || current.actionId != actionId || current.actionDeadline == null) throw JackfieldFailure("invalidState")
        var error: String? = if (clock() > current.actionDeadline) "deadlineExceeded" else null
        var success = succeeded && error == null
        if (success) {
            try { presentation.activate(current) } catch (failure: Exception) { success = false; error = Wire.code(failure) }
        }
        val receipt = buildMap<String, Any?> { put("actionId", actionId); put("succeeded", success); if (error != null) put("error", mapOf("code" to error)) }
        val next = current.copy(state = if (success) "active" else "failed", actionReceipts = JSONArray(current.receipts() + receipt).toString())
        dao.saveCall(next)
        if (success) presentation.update(next) else presentation.end(current.callId)
        if (error != null) throw JackfieldFailure(error)
    }

    suspend fun endCall(callId: String, reason: String): CallEntity = mutex.withLock {
        Wire.reason(reason)
        val current = requireCall(callId)
        try {
            if (current.state in setOf("ended", "failed")) return@withLock current
            val next = current.copy(state = "ended", sequence = current.sequence + 1)
            val config = configuration.load()
            val now = clock()
            admit(next, EventEntity(eventId(), callId, next.sequence, now, "ended", reason = reason,
                expiresAt = boundedAdd(now, config?.timeToLiveMs ?: 86_400_000), httpState = if (config == null) "disabled" else "pending"), config)
            next
        } finally {
            // Server reconciliation must close OS UI even when journal admission fails.
            presentation.end(callId)
        }
    }

    private fun admit(snapshot: CallEntity, event: EventEntity, config: CallbackConfiguration?) {
        val result = dao.persist(snapshot, event, config?.maxPendingEvents ?: 1000)
        if (result != "appended") throw JackfieldFailure("invalidState")
        publish(event)
        if (config != null) {
            try { schedule(snapshot.callId, 0) } catch (error: Exception) { recordError(error) }
        }
    }
    private fun publish(event: EventEntity) {
        try { eventListener?.invoke(event.toWire()) } catch (_: Exception) { dao.recordError("platformFailure") }
    }
    suspend fun replay() = mutex.withLock { dao.pendingFlutter().forEach(::publish) }
    suspend fun acknowledgeEvents(ids: List<String>) = mutex.withLock { ids.forEach(Wire::string); dao.acknowledgeFlutter(ids) }
    suspend fun expireActions() {
        val expired = mutex.withLock { dao.calls().filter { it.state == "connecting" && it.actionDeadline != null && clock() > it.actionDeadline }.mapNotNull { it.actionId } }
        expired.forEach { try { completeAction(it, false) } catch (failure: JackfieldFailure) { if (failure.code != "deadlineExceeded") throw failure } }
    }
    fun snapshot(callId: String): CallEntity? = dao.call(callId)
    fun recordError(error: Throwable) { try { dao.recordError(Wire.code(error)) } catch (_: Exception) { /* Storage may itself be unavailable. */ } }
    private fun requireCall(id: String) = dao.call(Wire.string(id)) ?: throw JackfieldFailure("invalidState")
    fun capabilities(): Map<String, Any?> {
        val mechanism = presentation.mechanism
        return mapOf("version" to 1, "platform" to "android", "mechanism" to mechanism,
            "features" to listOf("durableEvents", "httpCallbacks", "pushTokens") + if (mechanism == "unavailable") emptyList() else listOf("incoming", "outgoing", "answer", "reject", "end"),
            "reason" to if (mechanism == "unavailable") "Call presentation permission is unavailable" else null)
    }
    fun diagnostics(): Map<String, Any?> = mapOf("version" to 1, "mechanism" to presentation.mechanism, "permissions" to presentation.permissions(),
        "pendingFlutterEvents" to dao.flutterCount(), "pendingHttpEvents" to dao.httpCount(), "httpPausedForAuthentication" to dao.httpPaused(),
        "lastError" to dao.state()?.lastError?.let { mapOf("code" to it) })
    fun pushTokens(): Map<String, Any?> = mapOf("tokens" to dao.tokens().map { mapOf("provider" to it.provider, "value" to it.value) })
    suspend fun updatePushToken(provider: String, value: String, removed: Boolean) = mutex.withLock {
        val token = PushTokenEntity(Wire.string(provider), Wire.string(value))
        if (removed) dao.removeToken(token) else dao.addToken(token)
        tokenListener?.invoke(mapOf("version" to 1, "token" to mapOf("provider" to provider, "value" to value), "removed" to removed))
    }
}
