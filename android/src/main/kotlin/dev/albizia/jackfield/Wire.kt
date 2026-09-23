package dev.albizia.jackfield

import android.database.sqlite.SQLiteFullException
import dev.albizia.jackfield.http.CallbackConfiguration
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.time.Instant
import java.time.format.DateTimeFormatterBuilder

/** Only this bounded category crosses channels; raw platform failures never do. */
class JackfieldFailure(val code: String) : RuntimeException(code)

internal object Wire {
    private val timestamp = DateTimeFormatterBuilder().appendInstant(3).toFormatter()
    fun time(value: Long): String = timestamp.format(Instant.ofEpochMilli(value))
    fun success(value: Any? = null) = mapOf("version" to 1, "status" to "success", "value" to value)
    fun code(error: Throwable) = when (error) {
        is JackfieldFailure -> error.code
        is SQLiteFullException -> "storageFull"
        is SecurityException -> "permissionDenied"
        else -> "platformFailure"
    }
    fun failure(error: Throwable) = mapOf("version" to 1, "status" to "failure", "error" to mapOf("code" to code(error)))
    fun objectMap(value: Any?, required: Set<String>, optional: Set<String> = emptySet()): Map<String, Any?> {
        if (value !is Map<*, *> || value.keys.any { it !is String } || !value.keys.containsAll(required) || value.keys.any { it !in required && it !in optional }) fail()
        @Suppress("UNCHECKED_CAST") return value as Map<String, Any?>
    }
    fun request(value: Any?, required: Set<String>, optional: Set<String> = emptySet()): Map<String, Any?> {
        val data = objectMap(value, required + "version", optional)
        if ((data["version"] !is Int && data["version"] !is Long) || (data["version"] as Number).toLong() != 1L) fail()
        return data
    }
    fun string(value: Any?): String = (value as? String)?.takeIf { it.isNotBlank() } ?: fail()
    fun bool(value: Any?): Boolean = value as? Boolean ?: fail()
    fun number(value: Any?): Long = when (value) { is Int -> value.toLong(); is Long -> value; else -> fail() }
    fun media(value: Any?) = string(value).also { if (it !in setOf("audio", "video")) fail() }
    fun reason(value: Any?) = string(value).also { if (it !in setOf("local", "remote", "rejected", "missed", "failed")) fail() }
    fun caller(value: Any?): Map<String, String> {
        val data = objectMap(value, setOf("id", "displayName"))
        return mapOf("id" to string(data["id"]), "displayName" to string(data["displayName"]))
    }
    fun configuration(value: Any?): CallbackConfiguration? {
        if (value == null) return null
        val data = objectMap(value, setOf("endpoint", "auth", "timeToLiveMs", "maxPendingEvents"))
        val auth = objectMap(data["auth"], setOf("type", "token"))
        val endpoint = string(data["endpoint"])
        val token = string(auth["token"])
        val uri = try { URI(endpoint) } catch (_: Exception) { fail() }
        val ttl = number(data["timeToLiveMs"])
        val limit = number(data["maxPendingEvents"])
        if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.rawUserInfo != null || uri.rawFragment != null || auth["type"] != "bearer" || token.any { it == '\r' || it == '\n' } || ttl <= 0 || limit <= 0 || limit > Int.MAX_VALUE) fail()
        return CallbackConfiguration(endpoint, token, ttl, limit.toInt())
    }
    fun jsonMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { fromJson(json.get(it)) }
    private fun fromJson(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> jsonMap(value)
        is JSONArray -> (0 until value.length()).map { fromJson(value.get(it)) }
        else -> value
    }
    fun fail(): Nothing = throw JackfieldFailure("protocolFailure")
}

internal fun boundedAdd(time: Long, duration: Long): Long = if (duration > 0 && time > Long.MAX_VALUE - duration) Long.MAX_VALUE else time + duration
