package dev.albizia.jackfield

import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.albizia.jackfield.http.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import javax.crypto.KeyGenerator
import kotlin.test.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidBoundaryTest {
    @Test fun `protected configuration survives reopen without plaintext on disk`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val file = context.noBackupFilesDir.resolve("secure-test")
        try {
            val first = ProtectedConfigurationStore(file) { key }
            first.save(callbacks)
            assertFalse(file.readBytes().decodeToString().contains("secret"))
            assertEquals(callbacks, ProtectedConfigurationStore(file) { key }.load())
            first.save(null)
            assertNull(first.load())
        } finally { file.delete() }
    }

    @Test fun `unsafe callback endpoints credentials and malformed protocol fail safely`() {
        for (endpoint in listOf("http://example.test", "https://user:pass@example.test", "https://example.test/#fragment")) {
            assertEquals("protocolFailure", assertFailsWith<JackfieldFailure> {
                Wire.configuration(mapOf("endpoint" to endpoint, "auth" to mapOf("type" to "bearer", "token" to "secret"), "timeToLiveMs" to 1000, "maxPendingEvents" to 2))
            }.code)
        }
        assertFailsWith<JackfieldFailure> { Wire.request(mapOf("version" to 1.0), emptySet()) }
        assertFailsWith<JackfieldFailure> { Wire.request(mapOf("version" to 1, "unknown" to "secret"), emptySet()) }
        assertEquals(mapOf("version" to 1, "status" to "failure", "error" to mapOf("code" to "platformFailure")), Wire.failure(IllegalStateException("secret")))
    }

    @Test fun `notification fallback posts actionable call style and removes exact call`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val notifications = CallNotifications(context)
        notifications.show(call(state = "ringing"))
        val manager = context.getSystemService(NotificationManager::class.java)
        val shown = manager.activeNotifications.single()
        assertEquals("call", shown.notification.category)
        assertEquals(2, shown.notification.actions.size)
        assertEquals("android.app.Notification\$CallStyle", shown.notification.extras.getString("android.template"))
        notifications.end("call-1")
        assertTrue(manager.activeNotifications.isEmpty())
    }
}
