package dev.albizia.jackfield

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import dev.albizia.jackfield.http.CallbackScheduler
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CallbackSchedulerTest {
    @Test fun `scheduled calls have separate unique chains and same call cannot execute concurrently`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        WorkManagerTestInitHelper.initializeTestWorkManager(context, Configuration.Builder().setExecutor(SynchronousExecutor()).build())
        try {
            CallbackScheduler.enqueue(context, "A", 900_000)
            CallbackScheduler.enqueue(context, "A", 0)
            CallbackScheduler.enqueue(context, "B", 0)
            val manager = WorkManager.getInstance(context)
            val a = manager.getWorkInfosForUniqueWork("jackfield.callback.A").get()
            val b = manager.getWorkInfosForUniqueWork("jackfield.callback.B").get()
            assertEquals(setOf(WorkInfo.State.ENQUEUED, WorkInfo.State.BLOCKED), a.map { it.state }.toSet())
            assertEquals(WorkInfo.State.ENQUEUED, b.single().state)
        } finally { WorkManagerTestInitHelper.closeWorkDatabase() }
    }
}
