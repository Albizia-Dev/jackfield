package dev.albizia.jackfield

import android.Manifest
import android.app.Application
import android.app.NotificationManager
import android.os.ParcelUuid
import android.telecom.DisconnectCause
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallEndpointCompat
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import kotlin.test.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class TelecomPresentationTest {
    @Test fun `failed system disconnect retains control so server end can retry`() = runTest {
        val context = ApplicationProvider.getApplicationContext<Application>()
        var disconnects = 0
        val controls = mutableMapOf<String, CallControlScope>("call-1" to object : CallControlScope {
            override val coroutineContext = this@runTest.coroutineContext
            override fun getCallId() = ParcelUuid.fromString("00000000-0000-0000-0000-000000000001")
            override suspend fun setActive() = CallControlResult.Success()
            override suspend fun setInactive() = CallControlResult.Success()
            override suspend fun answer(callType: Int) = CallControlResult.Success()
            override suspend fun requestEndpointChange(endpoint: CallEndpointCompat) = CallControlResult.Success()
            override suspend fun disconnect(disconnectCause: DisconnectCause): CallControlResult {
                disconnects++
                return if (disconnects == 1) CallControlResult.Error(1) else CallControlResult.Success()
            }
            override val currentCallEndpoint: Flow<CallEndpointCompat> = emptyFlow()
            override val availableEndpoints: Flow<List<CallEndpointCompat>> = emptyFlow()
            override val isMuted: Flow<Boolean> = emptyFlow()
        })
        val presentation = TelecomPresentation(context, this, controls)
        assertFailsWith<JackfieldFailure> { presentation.end("call-1") }
        presentation.end("call-1")
        assertEquals(2, disconnects)
        assertTrue(controls.isEmpty())
    }

    @Test fun `capabilities use notification fallback without own calls permission and unavailable when blocked`() = runTest {
        val context = ApplicationProvider.getApplicationContext<Application>()
        Shadows.shadowOf(context).denyPermissions(Manifest.permission.MANAGE_OWN_CALLS)
        val manager = Shadows.shadowOf(context.getSystemService(NotificationManager::class.java))
        manager.setNotificationsEnabled(true)
        val presentation = TelecomPresentation(context, this)
        assertEquals("systemNotification", presentation.mechanism)
        manager.setNotificationsEnabled(false)
        assertEquals("unavailable", presentation.mechanism)
        assertEquals("denied", presentation.permissions()["notifications"])
        assertFailsWith<JackfieldFailure> { presentation.show(call(state = "ringing"), true) }
    }
}
