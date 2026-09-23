package dev.albizia.jackfield

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import dev.albizia.jackfield.store.*
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class EventDaoTest {
    private lateinit var db: JackfieldDatabase
    @Before fun open() { db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), JackfieldDatabase::class.java).allowMainThreadQueries().build() }
    @After fun close() { db.close() }

    @Test fun `snapshot and event admission is atomic and receipts are independent`() {
        val dao = db.events()
        dao.persist(call(sequence = 1), event(), 10)
        dao.acknowledgeHttp("event-1")
        assertEquals(listOf("event-1"), dao.pendingFlutter().map { it.eventId })
        assertTrue(dao.pendingHttp().isEmpty())
        assertEquals(1L, dao.call("call-1")!!.sequence)
        dao.acknowledgeFlutter(listOf("event-1"))
        assertTrue(dao.pendingFlutter().isEmpty())
        assertEquals("duplicate", dao.persist(call(state = "failed", sequence = 1), event(), 10))
        assertEquals("connecting", dao.call("call-1")!!.state)
    }

    @Test fun `overflow and stale sequence never mutate snapshot or reserve event id`() {
        val dao = db.events()
        dao.persist(call(sequence = 2), event(sequence = 2), 1)
        assertFailsWith<JackfieldFailure> { dao.persist(call(state = "ended", sequence = 3), event("event-3", 3), 1) }
        assertEquals("connecting", dao.call("call-1")!!.state)
        assertEquals("staleSequence", dao.persist(call(state = "ended", sequence = 1), event("late", 1), 10))
        dao.acknowledgeHttp("event-1")
        assertEquals("appended", dao.persist(call(state = "ended", sequence = 3), event("late", 3), 1))
    }

    @Test fun `one delayed call does not block another but keeps its own order`() {
        val dao = db.events()
        dao.persist(call(sequence = 1), event().copy(nextAttemptAt = 2000), 10)
        dao.persist(call(sequence = 2), event("event-2", 2), 10)
        dao.persist(call(id = "call-B", sequence = 1), event("event-B", 1, "call-B"), 10)
        assertEquals(listOf("event-B"), dao.ready(1000).map { it.eventId })
        assertEquals(listOf("event-1", "event-B"), dao.ready(2000).map { it.eventId })
    }

    @Test fun `database reopen preserves receipts watermark action history and auth pause`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val path = context.noBackupFilesDir.resolve("restart-test.db").absolutePath
        val first = Room.databaseBuilder(context, JackfieldDatabase::class.java, path).allowMainThreadQueries().build()
        val receipts = "[{\"actionId\":\"action-1\",\"succeeded\":true}]"
        first.events().persist(call(sequence = 1).copy(actionReceipts = receipts), event(), 10)
        first.events().acknowledgeFlutter(listOf("event-1"))
        first.events().setHttpPaused(true)
        first.close()
        val second = Room.databaseBuilder(context, JackfieldDatabase::class.java, path).allowMainThreadQueries().build()
        try {
            assertTrue(second.events().pendingFlutter().isEmpty())
            assertEquals(1, second.events().pendingHttp().size)
            assertEquals(receipts, second.events().call("call-1")!!.actionReceipts)
            assertTrue(second.events().httpPaused())
            assertEquals("duplicate", second.events().persist(call(sequence = 1), event(), 10))
        } finally { second.close(); context.deleteDatabase(path) }
    }
}

internal fun call(id: String = "call-1", state: String = "connecting", sequence: Long = 0) =
    CallEntity(id, state, "audio", "peer-1", "Caller", sequence = sequence)

internal fun event(id: String = "event-1", sequence: Long = 1, callId: String = "call-1") =
    EventEntity(id, callId, sequence, 1000, "answer_requested", actionId = "action-1", deadline = 6000, expiresAt = 86_401_000)
