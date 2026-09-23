package dev.albizia.jackfield.http

import android.content.Context
import androidx.work.*
import dev.albizia.jackfield.JackfieldRuntime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/** A unique chain per call prevents cross-call head-of-line blocking. */
class CallbackWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val callId = inputData.getString("callId") ?: return@withContext Result.failure()
        val runtime = JackfieldRuntime.get(applicationContext)
        try {
            runtime.callbacks.run(callId)?.let { CallbackScheduler.enqueue(applicationContext, callId, it) }
            Result.success()
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { runtime.controller.recordError(error); Result.retry() }
    }
}

/** Repairs the transaction-to-scheduler crash window and expires actions after process death. */
class RecoveryWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val runtime = JackfieldRuntime.get(applicationContext)
        try { runtime.recover(); Result.success() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { runtime.controller.recordError(error); Result.retry() }
    }
}

internal object CallbackScheduler {
    fun enqueue(context: Context, callId: String, delay: Long) {
        val request = OneTimeWorkRequestBuilder<CallbackWorker>()
            .setInputData(workDataOf("callId" to callId))
            .setInitialDelay(delay.coerceAtLeast(0), TimeUnit.MILLISECONDS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork("jackfield.callback.$callId", ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }
    fun registerRecovery(context: Context) {
        WorkManager.getInstance(context).enqueueUniquePeriodicWork("jackfield.recovery", ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<RecoveryWorker>(15, TimeUnit.MINUTES).build())
    }
}
