package dev.albizia.jackfield.http

import dev.albizia.jackfield.boundedAdd
import dev.albizia.jackfield.store.EventDao
import kotlinx.coroutines.CancellationException
import org.json.JSONObject
import java.net.URL
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import javax.net.ssl.HttpsURLConnection
import kotlin.math.min
import kotlin.random.Random

class HttpRequest(val endpoint: String, val token: String, val eventId: String, val body: String) {
    override fun toString() = "HttpRequest(redacted)"
}
data class HttpOutcome(val status: Int?, val retryAfterMs: Long? = null)
fun interface HttpTransport { suspend fun send(request: HttpRequest): HttpOutcome }

/** No redirect, no raw response body, no secret-bearing transport errors. */
class HttpsTransport : HttpTransport {
    override suspend fun send(request: HttpRequest): HttpOutcome {
        val connection = URL(request.endpoint).openConnection() as HttpsURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.requestMethod = "POST"
            connection.connectTimeout = 15_000; connection.readTimeout = 15_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Authorization", "Bearer ${request.token}")
            connection.setRequestProperty("Idempotency-Key", request.eventId)
            val bytes = request.body.toByteArray(Charsets.UTF_8)
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            val status = connection.responseCode
            val header = connection.getHeaderField("Retry-After")
            val delay = header?.trim()?.toLongOrNull()?.takeIf { it > 0 }?.let { min(it, 900L) * 1000 }
                ?: try { header?.let { ZonedDateTime.parse(it, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() - System.currentTimeMillis() } } catch (_: Exception) { null }
            return HttpOutcome(status, delay)
        } finally { connection.disconnect() }
    }
}

/** Processes only one call's head; WorkManager serializes each call independently. */
class CallbackProcessor(
    private val dao: EventDao,
    private val configuration: () -> CallbackConfiguration?,
    private val transport: HttpTransport,
    private val clock: () -> Long = System::currentTimeMillis,
    private val jitter: () -> Double = { Random.nextDouble() },
) {
    suspend fun run(callId: String): Long? {
        dao.expireHttp(clock())
        // Bounded batches yield execution back to WorkManager on a large backlog.
        repeat(32) {
            val config = configuration() ?: return null
            if (dao.httpPaused()) return null
            val event = dao.head(callId) ?: return null
            val now = clock()
            if (now >= event.expiresAt) { dao.outcome(event.eventId, "expired", event.attempts, now); return@repeat }
            if (event.nextAttemptAt > now) return min(event.nextAttemptAt, event.expiresAt) - now
            val attempt = event.attempts + 1
            // Persist attempt before I/O. A process death safely repeats the same idempotency key.
            dao.outcome(event.eventId, "pending", attempt, now)
            val outcome = try {
                transport.send(HttpRequest(config.endpoint, config.token, event.eventId, JSONObject(mapOf("version" to 1, "event" to event.toWire())).toString()))
            } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { HttpOutcome(null) }
            val after = clock()
            when {
                after >= event.expiresAt -> dao.outcome(event.eventId, "expired", attempt, after)
                outcome.status != null && outcome.status in 200..299 -> dao.acknowledgeHttp(event.eventId)
                outcome.status == 401 || outcome.status == 403 -> {
                    // Ignore an obsolete rejection if credentials rotated during the request.
                    val paused = synchronized(ConfigurationLock) {
                        if (configuration()?.authFingerprint() == config.authFingerprint()) { dao.pauseForAuthentication(config.authFingerprint()); true } else false
                    }
                    if (paused) return null
                }
                outcome.status == null || outcome.status == 429 || outcome.status in 500..599 -> {
                    val base = outcome.retryAfterMs?.takeIf { it > 0 }?.coerceAtMost(900_000)
                        ?: (1000L shl min(attempt - 1, 10)).coerceAtMost(900_000)
                    val delay = (base + (base * 0.2 * jitter().coerceIn(0.0, 1.0)).toLong()).coerceAtMost(900_000)
                    val next = min(boundedAdd(after, delay), event.expiresAt)
                    dao.outcome(event.eventId, "pending", attempt, next)
                    return next - after
                }
                else -> dao.outcome(event.eventId, "terminal", attempt, after)
            }
        }
        return if (dao.head(callId) == null) null else 0
    }
}
