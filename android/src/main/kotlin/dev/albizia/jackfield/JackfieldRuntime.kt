package dev.albizia.jackfield

import android.content.Context
import dev.albizia.jackfield.http.*
import dev.albizia.jackfield.store.JackfieldDatabase
import kotlinx.coroutines.*
import java.util.UUID

/** Process lifetime is deliberately independent of any Flutter engine. */
internal class JackfieldRuntime private constructor(context: Context) {
    private val appContext = context.applicationContext
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val database = JackfieldDatabase.open(context)
    private val configuration = ProtectedConfigurationStore.open(context)
    private val presentation = TelecomPresentation(context, scope)
    val controller = CallController(database, presentation, configuration, { id, delay -> CallbackScheduler.enqueue(context, id, delay) })
    val callbacks = CallbackProcessor(database.events(), configuration::load, HttpsTransport())
    init {
        presentation.controller = controller
        presentation.answer = { callId ->
            val snapshot = answer(callId)
            withTimeoutOrNull(4600) {
                while (true) {
                    val state = controller.snapshot(callId) ?: return@withTimeoutOrNull false
                    val receipt = state.receipts().firstOrNull { it["actionId"] == snapshot.actionId }
                    if (receipt != null) return@withTimeoutOrNull receipt["succeeded"] == true
                    if (state.state in setOf("ended", "failed")) return@withTimeoutOrNull false
                    delay(40)
                }
                @Suppress("UNREACHABLE_CODE") false
            } ?: false
        }
        try { CallbackScheduler.registerRecovery(context) }
        catch (error: Exception) { controller.recordError(error) }
        scope.launch { try { recover() } catch (error: Exception) { controller.recordError(error) } }
    }
    suspend fun answer(callId: String): dev.albizia.jackfield.store.CallEntity {
        val current = controller.snapshot(callId)
        if (current?.state == "connecting" && current.actionId != null) return current
        val snapshot = controller.requestAnswer(callId, UUID.randomUUID().toString())
        scope.launch {
            delay(((snapshot.actionDeadline ?: 0) - System.currentTimeMillis() + 1).coerceAtLeast(1))
            try { controller.expireActions() } catch (error: Exception) { controller.recordError(error) }
        }
        return snapshot
    }
    suspend fun recover() {
        database.events().expireHttp(System.currentTimeMillis())
        controller.expireActions()
        if (configuration.load() != null && !database.events().httpPaused()) {
            database.events().pendingCallIds().forEach { CallbackScheduler.enqueue(appContext, it, 0) }
        }
    }
    companion object {
        @Volatile private var instance: JackfieldRuntime? = null
        fun get(context: Context): JackfieldRuntime = instance ?: synchronized(this) {
            instance ?: JackfieldRuntime(context.applicationContext).also { instance = it }
        }
    }
}
