package dev.albizia.jackfield

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import dev.albizia.jackfield.store.*
import dev.albizia.jackfield.http.*
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.json.JSONArray
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.*
import java.io.File
import java.time.Instant

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CallbackWorkerTest {
    private lateinit var db: JackfieldDatabase
    private var now = 1000L
    private var response = HttpOutcome(204)
    private val sent = mutableListOf<HttpRequest>()
    private lateinit var processor: CallbackProcessor
    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), JackfieldDatabase::class.java).allowMainThreadQueries().build()
        processor = CallbackProcessor(db.events(), { callbacks }, HttpTransport { request -> sent.add(request); response }, { now }, { 0.0 })
    }
    @After fun close() { db.close() }

    @Test fun `success sends canonical envelope and acknowledges HTTP only`() = runTest {
        db.events().persist(call(sequence = 1), event(), 10)
        processor.run("call-1")
        assertEquals("event-1", sent.single().eventId)
        assertEquals("secret", sent.single().token)
        val json = JSONObject(sent.single().body)
        assertEquals(1, json.getInt("version"))
        assertEquals("answer_requested", json.getJSONObject("event").getString("type"))
        assertFalse(sent.single().body.contains("secret"))
        assertFalse(sent.single().body.contains("Caller"))
        assertEquals(1, db.events().pendingFlutter().size)
        assertTrue(db.events().pendingHttp().isEmpty())
    }

    @Test fun `production callback body matches every canonical fixture field`() = runTest {
        val fixture = JSONObject(canonicalCallbackFixture().readText())
        val wire = fixture.getJSONObject("event")
        val occurredAt = Instant.parse(wire.getString("occurredAt")).toEpochMilli()
        now = occurredAt + 1_000
        val nativeEvent = EventEntity(
            eventId = wire.getString("eventId"), callId = wire.getString("callId"),
            sequence = wire.getLong("sequence"), occurredAt = occurredAt,
            type = wire.getString("type"), actionId = wire.getString("actionId"),
            deadline = Instant.parse(wire.getString("deadline")).toEpochMilli(),
            expiresAt = occurredAt + 86_400_000,
        )
        db.events().persist(call(sequence = nativeEvent.sequence), nativeEvent, 10)

        processor.run(nativeEvent.callId)

        val request = sent.single()
        assertEquals(wire.getString("eventId"), request.eventId)
        assertEquals(callbacks.endpoint, request.endpoint)
        assertEquals(callbacks.token, request.token)
        assertJsonEquals(fixture, JSONObject(request.body))
        assertFalse(request.body.contains(callbacks.token))
    }

    @Test fun `transient delay is durable and another call progresses`() = runTest {
        db.events().persist(call(sequence = 1), event(), 10)
        db.events().persist(call(sequence = 2), event("event-2", 2), 10)
        response = HttpOutcome(429, 120_000)
        assertEquals(120_000L, processor.run("call-1"))
        assertEquals(121_000L, db.events().pendingHttp().first().nextAttemptAt)
        assertEquals(1, db.events().pendingHttp().first().attempts)
        db.events().persist(call(id = "B", sequence = 1), event("event-B", 1, "B"), 10)
        response = HttpOutcome(200)
        processor.run("B")
        processor.run("call-1")
        assertEquals(listOf("event-1", "event-B"), sent.map { it.eventId })
    }

    @Test fun `authentication pauses globally without consuming receipts`() = runTest {
        db.events().persist(call(sequence = 1), event(), 10)
        response = HttpOutcome(401)
        processor.run("call-1")
        processor.run("call-1")
        assertTrue(db.events().httpPaused())
        assertEquals(1, sent.size)
        assertEquals(1, db.events().pendingFlutter().size)
        assertEquals(1, db.events().pendingHttp().size)
    }

    @Test fun `TTL expiration releases capacity even while authentication is paused`() = runTest {
        db.events().persist(call(sequence = 1), event().copy(expiresAt = 1000), 1)
        db.events().setHttpPaused(true)
        processor.run("call-1")
        assertTrue(db.events().pendingHttp().isEmpty())
        assertEquals(1, db.events().pendingFlutter().size)
        assertTrue(db.events().httpPaused())
        assertTrue(sent.isEmpty())
    }

    @Test fun `expired and permanent failures release HTTP queue but preserve Flutter replay`() = runTest {
        db.events().persist(call(sequence = 1), event().copy(expiresAt = 1000), 10)
        processor.run("call-1")
        assertTrue(sent.isEmpty())
        assertEquals("expired", db.events().event("event-1")!!.httpState)
        db.events().persist(call(sequence = 2), event("event-2", 2), 10)
        response = HttpOutcome(302)
        processor.run("call-1")
        assertEquals("terminal", db.events().event("event-2")!!.httpState)
        assertEquals(2, db.events().pendingFlutter().size)
        assertTrue(db.events().pendingHttp().isEmpty())
    }
}

private fun canonicalCallbackFixture(): File {
    var directory: File? = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
    while (directory != null) {
        val candidate = directory.resolve("test/fixtures/callback_answer_requested_v1.json")
        if (candidate.isFile) return candidate
        directory = directory.parentFile
    }
    error("Cannot locate canonical callback fixture from Gradle working directory")
}

private fun assertJsonEquals(expected: Any?, actual: Any?) {
    when (expected) {
        is JSONObject -> {
            assertTrue(actual is JSONObject)
            assertEquals(expected.keys().asSequence().toSet(), actual.keys().asSequence().toSet())
            for (key in expected.keys()) assertJsonEquals(expected.get(key), actual.get(key))
        }
        is JSONArray -> {
            assertTrue(actual is JSONArray)
            assertEquals(expected.length(), actual.length())
            for (index in 0 until expected.length()) assertJsonEquals(expected.get(index), actual.get(index))
        }
        is Number -> {
            assertTrue(actual is Number)
            assertEquals(expected.toString(), actual.toString())
        }
        else -> assertEquals(expected, actual)
    }
}
