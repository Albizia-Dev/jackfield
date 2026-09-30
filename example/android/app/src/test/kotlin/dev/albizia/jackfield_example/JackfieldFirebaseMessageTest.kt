package dev.albizia.jackfield_example

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class JackfieldFirebaseMessageTest {
    @Test
    fun `incoming data is normalized for Jackfield`() {
        val message = JackfieldFirebaseMessage.parse(
            mapOf(
                "version" to "1",
                "type" to "incoming",
                "callId" to "call-1",
                "callerId" to "person-1",
                "callerName" to "Alice",
                "media" to "audio",
                "expiresAt" to "2026-09-30T04:00:45Z",
            ),
        )

        assertEquals(
            JackfieldFirebaseMessage.Incoming(
                callId = "call-1",
                callerId = "person-1",
                callerName = "Alice",
                media = "audio",
                expiresAt = "2026-09-30T04:00:45Z",
            ),
            message,
        )
    }

    @Test
    fun `remote end data is normalized for Jackfield`() {
        assertEquals(
            JackfieldFirebaseMessage.End("call-1", "remote"),
            JackfieldFirebaseMessage.parse(
                mapOf(
                    "version" to "1",
                    "type" to "end",
                    "callId" to "call-1",
                    "reason" to "remote",
                ),
            ),
        )
        assertEquals(
            JackfieldFirebaseMessage.End("call-1", "rejected"),
            JackfieldFirebaseMessage.parse(
                mapOf("version" to "1", "type" to "end", "callId" to "call-1", "reason" to "rejected"),
            ),
        )
    }

    @Test
    fun `malformed or unsupported data is ignored`() {
        assertNull(JackfieldFirebaseMessage.parse(mapOf("type" to "incoming")))
        assertNull(
            JackfieldFirebaseMessage.parse(
                mapOf(
                    "version" to "1", "type" to "incoming", "callId" to "call-1",
                    "callerId" to "person-1", "callerName" to "Alice", "media" to "audio",
                ),
            ),
        )
        assertNull(
            JackfieldFirebaseMessage.parse(
                mapOf(
                    "version" to "2",
                    "type" to "incoming",
                    "callId" to "call-1",
                    "callerId" to "person-1",
                    "callerName" to "Alice",
                    "media" to "audio",
                ),
            ),
        )
    }
}
