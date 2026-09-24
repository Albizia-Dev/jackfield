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
            ),
        )

        assertEquals(
            JackfieldFirebaseMessage.Incoming(
                callId = "call-1",
                callerId = "person-1",
                callerName = "Alice",
                media = "audio",
            ),
            message,
        )
    }

    @Test
    fun `remote end data is normalized for Jackfield`() {
        assertEquals(
            JackfieldFirebaseMessage.End("call-1"),
            JackfieldFirebaseMessage.parse(
                mapOf(
                    "version" to "1",
                    "type" to "end",
                    "callId" to "call-1",
                    "reason" to "remote",
                ),
            ),
        )
    }

    @Test
    fun `malformed or unsupported data is ignored`() {
        assertNull(JackfieldFirebaseMessage.parse(mapOf("type" to "incoming")))
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
