package dev.albizia.jackfield.store

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import dev.albizia.jackfield.Wire
import org.json.JSONArray

@Entity(tableName = "calls")
data class CallEntity(
    @PrimaryKey val callId: String,
    val state: String,
    val media: String,
    val callerId: String,
    val callerName: String,
    val sequence: Long = 0,
    val actionId: String? = null,
    val actionDeadline: Long? = null,
    val actionReceipts: String = "[]",
) {
    fun receipts(): List<Map<String, Any?>> = JSONArray(actionReceipts).let { array ->
        (0 until array.length()).map { Wire.jsonMap(array.getJSONObject(it)) }
    }
    fun toWire(): Map<String, Any?> = mapOf(
        "callId" to callId, "state" to state, "media" to media,
        "caller" to mapOf("id" to callerId, "displayName" to callerName),
        "actionId" to actionId, "actionDeadline" to actionDeadline?.let(Wire::time),
        "actionReceipts" to receipts(),
    )
}

@Entity(tableName = "events", indices = [Index(value = ["callId", "sequence"], unique = true), Index(value = ["httpState"])])
data class EventEntity(
    @PrimaryKey val eventId: String,
    val callId: String,
    val sequence: Long,
    val occurredAt: Long,
    val type: String,
    val actionId: String? = null,
    val deadline: Long? = null,
    val reason: String? = null,
    val flutterAcknowledged: Boolean = false,
    val httpState: String = "pending",
    val attempts: Int = 0,
    val nextAttemptAt: Long = occurredAt,
    val expiresAt: Long,
) {
    fun toWire(): Map<String, Any?> = buildMap {
        put("version", 1); put("type", type); put("callId", callId); put("eventId", eventId)
        put("sequence", sequence); put("occurredAt", Wire.time(occurredAt))
        if (type == "answer_requested") { put("actionId", actionId); put("deadline", deadline?.let(Wire::time)) }
        else put("reason", reason)
    }
}

@Entity(tableName = "adapter_state")
data class AdapterState(@PrimaryKey val id: Int = 1, val httpPaused: Boolean = false, val lastError: String? = null, val rejectedAuthFingerprint: String? = null)

@Entity(tableName = "push_tokens", primaryKeys = ["provider", "value"])
data class PushTokenEntity(val provider: String, val value: String)
