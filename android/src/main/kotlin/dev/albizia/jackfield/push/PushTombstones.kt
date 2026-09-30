package dev.albizia.jackfield.push

import android.content.Context
import android.content.SharedPreferences

/** Durable guard against an end push being delivered before its incoming push. */
internal class PushTombstones(
    private val preferences: SharedPreferences,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    constructor(context: Context) : this(
        context.applicationContext.getSharedPreferences("jackfield.push_tombstones", Context.MODE_PRIVATE),
    )

    fun mark(callId: String) {
        val now = clock()
        val edit = preferences.edit().putLong(callId, now)
        preferences.all.forEach { (id, value) ->
            val endedAt = value as? Long
            if (endedAt == null || now - endedAt > RETENTION_MS) edit.remove(id)
        }
        // End-before-incoming ordering must survive process death before returning.
        edit.commit()
    }

    fun contains(callId: String): Boolean {
        if (!preferences.contains(callId)) return false
        val endedAt = preferences.getLong(callId, Long.MIN_VALUE)
        val age = clock() - endedAt
        if (endedAt != Long.MIN_VALUE && age <= RETENTION_MS) return true
        preferences.edit().remove(callId).apply()
        return false
    }

    private companion object {
        const val RETENTION_MS = 24 * 60 * 60 * 1000L
    }
}
