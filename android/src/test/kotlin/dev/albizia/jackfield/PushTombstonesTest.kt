package dev.albizia.jackfield

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.albizia.jackfield.push.PushTombstones
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PushTombstonesTest {
    @Test fun `terminal push survives recreation and expires after retention`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("tombstone-test-${UUID.randomUUID()}", Context.MODE_PRIVATE)
        var now = 10_000L
        PushTombstones(preferences) { now }.mark("call-1")

        assertTrue(PushTombstones(preferences) { now }.contains("call-1"))
        assertFalse(PushTombstones(preferences) { now }.contains("call-2"))

        now += 24 * 60 * 60 * 1000L + 1
        assertFalse(PushTombstones(preferences) { now }.contains("call-1"))
    }
}
