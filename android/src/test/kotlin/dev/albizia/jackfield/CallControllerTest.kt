package dev.albizia.jackfield

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import dev.albizia.jackfield.store.*
import dev.albizia.jackfield.http.*
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CallControllerTest {
    private lateinit var db: JackfieldDatabase
    private lateinit var controller: CallController
    private val shown = mutableListOf<String>()
    private val ended = mutableListOf<String>()
    private val emitted = mutableListOf<Map<String, Any?>>()
    private var now = 1000L
    private var eventNumber = 0
    private var scheduleFailure = false
    private val configuration = MemoryConfiguration()
    @Before fun open() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), JackfieldDatabase::class.java).allowMainThreadQueries().build()
        controller = CallController(db, object : CallPresentation {
            override val mechanism = "systemNotification"
            override fun permissions() = mapOf("notifications" to "granted")
            override suspend fun show(call: CallEntity, incoming: Boolean) { shown.add(call.callId) }
            override suspend fun update(call: CallEntity) {}
            override suspend fun activate(call: CallEntity) {}
            override suspend fun end(callId: String) { ended.add(callId) }
        }, configuration, { _, _ -> if (scheduleFailure) throw IllegalStateException("secret") }, { now }, { "event-${++eventNumber}" })
        controller.eventListener = { wire ->
            // Removing the Room commit or emitting before it makes this assertion fail.
            assertEquals(wire["eventId"], db.events().pendingFlutter().last().eventId)
            assertEquals("connecting", db.events().call("call-1")!!.state)
            emitted.add(wire)
        }
    }
    @After fun close() { db.close() }

    @Test fun `answer commits snapshot and event before emission and completion never acknowledges delivery`() = runTest {
        controller.initialize(callbacks)
        controller.reportIncoming(incoming)
        controller.requestAnswer("call-1", "action-1", 6000)
        assertEquals("answer_requested", emitted.single()["type"])
        assertEquals(1L, emitted.single()["sequence"])
        controller.completeAction("action-1", true)
        assertEquals("active", db.events().call("call-1")!!.state)
        assertEquals(1, db.events().pendingFlutter().size)
        assertEquals(1, db.events().pendingHttp().size)
        controller.completeAction("action-1", false)
        assertEquals(true, (db.events().call("call-1")!!.toWire()["actionReceipts"] as List<*>).let { (it.single() as Map<*, *>)["succeeded"] })
        controller.acknowledgeEvents(listOf("event-1"))
        assertEquals(1, db.events().pendingHttp().size)
    }

    @Test fun `HTTP scheduler failure never suppresses committed Flutter event or call action`() = runTest {
        controller.initialize(callbacks)
        controller.reportIncoming(incoming)
        scheduleFailure = true
        val snapshot = controller.requestAnswer("call-1", "action-1", 6000)
        assertEquals("connecting", snapshot.state)
        assertEquals("event-1", emitted.single()["eventId"])
        assertEquals(1, db.events().pendingHttp().size)
        assertEquals(mapOf("code" to "platformFailure"), controller.diagnostics()["lastError"])
    }

    @Test fun `late completion persists failed action receipt before returning safe error`() = runTest {
        controller.reportIncoming(incoming)
        controller.requestAnswer("call-1", "action-1", 6000)
        now = 6001
        assertEquals("deadlineExceeded", assertFailsWith<JackfieldFailure> { controller.completeAction("action-1", true) }.code)
        assertEquals("failed", db.events().call("call-1")!!.state)
        assertEquals("deadlineExceeded", assertFailsWith<JackfieldFailure> { controller.completeAction("action-1", true) }.code)
        assertEquals(listOf("call-1"), ended)
    }

    @Test fun `already expired answer never publishes a connecting snapshot`() = runTest {
        controller.eventListener = null
        controller.reportIncoming(incoming)
        now = 6001
        assertEquals("deadlineExceeded", assertFailsWith<JackfieldFailure> { controller.requestAnswer("call-1", "action-1", 6000) }.code)
        assertEquals("failed", db.events().call("call-1")!!.state)
        assertEquals(false, db.events().call("call-1")!!.receipts().single()["succeeded"])
        assertEquals(1, db.events().pendingFlutter().size)
    }

    @Test fun `explicit credential replacement recovers unreadable protected configuration`() = runTest {
        configuration.readFailure = true
        controller.initialize(callbacks)
        assertEquals(callbacks, configuration.load())
        assertFalse(db.events().httpPaused())
    }

    @Test fun `server end removes presentation even when bounded outbox rejects new event`() = runTest {
        controller.initialize(callbacks.copy(maxPendingEvents = 1))
        controller.reportIncoming(incoming)
        controller.requestAnswer("call-1", "action-1", 6000)
        controller.eventListener = null
        assertEquals("storageFull", assertFailsWith<JackfieldFailure> { controller.endCall("call-1", "remote") }.code)
        assertTrue(ended.contains("call-1"))
        assertEquals(1, db.events().pendingFlutter().size)
    }

    @Test fun `replay survives listener replacement and acknowledge is delivery only`() = runTest {
        controller.reportIncoming(incoming)
        controller.requestAnswer("call-1", "action-1", 6000)
        emitted.clear()
        controller.replay()
        assertEquals("event-1", emitted.single()["eventId"])
        controller.acknowledgeEvents(listOf("event-1"))
        emitted.clear()
        controller.replay()
        assertTrue(emitted.isEmpty())
        assertEquals("connecting", db.events().call("call-1")!!.state)
    }

    @Test fun `only rotated credentials resume authentication pause`() = runTest {
        controller.initialize(callbacks)
        db.events().setHttpPaused(true)
        controller.initialize(callbacks)
        assertTrue(db.events().httpPaused())
        controller.initialize(callbacks.copy(token = "rotated"))
        assertFalse(db.events().httpPaused())
    }

    @Test fun `rotation saved before crash resumes paused callbacks on next initialize`() = runTest {
        controller.initialize(callbacks)
        controller.reportIncoming(incoming)
        controller.requestAnswer("call-1", "action-1", 6000)
        CallbackProcessor(db.events(), configuration::load, HttpTransport { HttpOutcome(401) }, { now }).run("call-1")
        assertTrue(db.events().httpPaused())
        controller.initialize(callbacks)
        assertTrue(db.events().httpPaused())
        val rotated = callbacks.copy(token = "rotated")
        configuration.save(rotated) // Durable file write completed; process died before Room unpause.
        val restarted = CallController(db, object : CallPresentation {
            override val mechanism = "systemNotification"
            override fun permissions() = mapOf("notifications" to "granted")
            override suspend fun show(call: CallEntity, incoming: Boolean) {}
            override suspend fun update(call: CallEntity) {}
            override suspend fun activate(call: CallEntity) {}
            override suspend fun end(callId: String) {}
        }, configuration, { _, _ -> })
        restarted.initialize(rotated)
        assertFalse(db.events().httpPaused())
    }

    @Test fun `legacy pause gets rejected fingerprint before a crashing credential save`() = runTest {
        controller.initialize(callbacks)
        db.events().setHttpPaused(true) // v1 row has no rejected fingerprint.
        val rotated = callbacks.copy(token = "rotated")
        configuration.crashAfterSave = true
        assertFailsWith<IllegalStateException> { controller.initialize(rotated) }
        controller.initialize(rotated)
        assertFalse(db.events().httpPaused())
    }

    @Test fun `channel backend validates commands and returns full canonical snapshots`() = runTest {
        val backend = AndroidChannelBackend(controller)
        assertEquals(mapOf("version" to 1, "status" to "success", "value" to null), backend.handle("initialize", mapOf("version" to 1)))
        val reply = backend.handle("reportIncomingCall", incoming)
        val snapshot = reply["value"] as Map<*, *>
        assertEquals("ringing", snapshot["state"])
        assertEquals(emptyList<Any>(), snapshot["actionReceipts"])
        assertEquals("systemNotification", backend.handle("capabilities", mapOf("version" to 1))["mechanism"])
        val invalid = backend.handle("endCall", mapOf("version" to 1, "callId" to "call-1", "reason" to "secret"))
        assertEquals(mapOf("code" to "protocolFailure"), invalid["error"])
        assertEquals("ringing", db.events().call("call-1")!!.state)
    }
}

internal val incoming = mapOf<String, Any?>("version" to 1, "callId" to "call-1", "caller" to mapOf("id" to "peer-1", "displayName" to "Caller"), "media" to "audio")
internal val callbacks = CallbackConfiguration("https://example.test/callback", "secret", 86_400_000, 1000)
internal class MemoryConfiguration : ConfigurationStore {
    private var config: CallbackConfiguration? = null
    var readFailure = false
    var crashAfterSave = false
    override fun load(): CallbackConfiguration? { if (readFailure) throw IllegalStateException("secret"); return config }
    override fun save(value: CallbackConfiguration?) {
        config = value; readFailure = false
        if (crashAfterSave) { crashAfterSave = false; throw IllegalStateException("simulated process death") }
    }
}
