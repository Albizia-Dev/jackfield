package dev.albizia.jackfield.store

import androidx.room.*
import dev.albizia.jackfield.JackfieldFailure

/** The single admission boundary; duplicate/stale writes never touch snapshots. */
@Dao
abstract class EventDao {
    @Query("SELECT * FROM calls WHERE callId = :id") abstract fun call(id: String): CallEntity?
    @Query("SELECT * FROM calls") abstract fun calls(): List<CallEntity>
    @Upsert abstract fun saveCall(call: CallEntity)
    @Query("SELECT * FROM events WHERE eventId = :id") abstract fun event(id: String): EventEntity?
    @Insert abstract fun insert(event: EventEntity)
    @Query("SELECT * FROM events WHERE flutterAcknowledged = 0 ORDER BY callId, sequence") abstract fun pendingFlutter(): List<EventEntity>
    @Query("SELECT * FROM events WHERE httpState = 'pending' ORDER BY callId, sequence") abstract fun pendingHttp(): List<EventEntity>
    @Query("SELECT count(*) FROM events WHERE httpState = 'pending'") abstract fun httpCount(): Int
    @Query("UPDATE events SET httpState = 'expired' WHERE httpState = 'pending' AND expiresAt <= :now") abstract fun expireHttp(now: Long)
    @Query("SELECT count(*) FROM events WHERE flutterAcknowledged = 0") abstract fun flutterCount(): Int
    @Query("UPDATE events SET flutterAcknowledged = 1 WHERE eventId IN (:ids)") abstract fun acknowledgeFlutter(ids: List<String>)
    @Query("UPDATE events SET httpState = 'delivered' WHERE eventId = :id") abstract fun acknowledgeHttp(id: String)
    @Query("UPDATE events SET httpState = :state, attempts = :attempts, nextAttemptAt = :next WHERE eventId = :id") abstract fun outcome(id: String, state: String, attempts: Int, next: Long)
    @Query("SELECT * FROM events e WHERE httpState = 'pending' AND nextAttemptAt <= :now AND NOT EXISTS (SELECT 1 FROM events previous WHERE previous.callId = e.callId AND previous.sequence < e.sequence AND previous.httpState = 'pending') ORDER BY callId, sequence")
    abstract fun ready(now: Long): List<EventEntity>
    @Query("SELECT * FROM events WHERE callId = :id AND httpState = 'pending' ORDER BY sequence LIMIT 1") abstract fun head(id: String): EventEntity?
    @Query("SELECT DISTINCT callId FROM events WHERE httpState = 'pending'") abstract fun pendingCallIds(): List<String>
    @Query("SELECT * FROM adapter_state WHERE id = 1") abstract fun state(): AdapterState?
    @Upsert abstract fun saveState(state: AdapterState)
    @Query("SELECT * FROM push_tokens ORDER BY provider, value") abstract fun tokens(): List<PushTokenEntity>
    @Insert(onConflict = OnConflictStrategy.IGNORE) abstract fun addToken(token: PushTokenEntity)
    @Delete abstract fun removeToken(token: PushTokenEntity)

    fun httpPaused(): Boolean = state()?.httpPaused ?: false
    @Transaction open fun setHttpPaused(paused: Boolean) {
        val current = state() ?: AdapterState()
        saveState(current.copy(httpPaused = paused, rejectedAuthFingerprint = if (paused) current.rejectedAuthFingerprint else null))
    }
    @Transaction open fun pauseForAuthentication(fingerprint: String) { saveState((state() ?: AdapterState()).copy(httpPaused = true, rejectedAuthFingerprint = fingerprint)) }
    @Transaction open fun resumeIfCredentialsChanged(fingerprint: String): Boolean {
        val current = state() ?: return false
        if (!current.httpPaused || current.rejectedAuthFingerprint == null || current.rejectedAuthFingerprint == fingerprint) return false
        saveState(current.copy(httpPaused = false, rejectedAuthFingerprint = null))
        return true
    }
    @Transaction open fun recordError(code: String?) { saveState((state() ?: AdapterState()).copy(lastError = code)) }

    @Transaction open fun persist(snapshot: CallEntity, event: EventEntity?, limit: Int): String {
        if (event != null) {
            if (event(event.eventId) != null) return "duplicate"
            val previous = call(event.callId)
            if (previous != null && event.sequence <= previous.sequence) return "staleSequence"
            if (snapshot.callId != event.callId || snapshot.sequence != event.sequence || event.sequence < 0) throw JackfieldFailure("protocolFailure")
            expireHttp(event.occurredAt)
            if (event.httpState == "pending" && httpCount() >= limit) throw JackfieldFailure("storageFull")
            insert(event)
        }
        saveCall(snapshot)
        return "appended"
    }
}
