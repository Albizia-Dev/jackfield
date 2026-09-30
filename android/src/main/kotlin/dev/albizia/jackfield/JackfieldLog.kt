package dev.albizia.jackfield

import android.util.Log

/** Privacy-safe native lifecycle logging; never include provider payloads or tokens. */
internal object JackfieldLog {
    private const val TAG = "Jackfield"

    fun info(stage: String, callId: String? = null, detail: String? = null) {
        write(Log.INFO, stage, callId, detail, null)
    }

    fun warn(stage: String, callId: String? = null, detail: String? = null, error: Throwable? = null) {
        write(Log.WARN, stage, callId, detail, error)
    }

    fun error(stage: String, callId: String? = null, error: Throwable) {
        write(Log.ERROR, stage, callId, null, error)
    }

    private fun write(priority: Int, stage: String, callId: String?, detail: String?, error: Throwable?) {
        val message = buildString {
            append("stage=").append(stage)
            if (!callId.isNullOrBlank()) append(" call=").append(Integer.toHexString(callId.hashCode()))
            if (!detail.isNullOrBlank()) append(' ').append(detail)
        }
        try {
            Log.println(priority, TAG, message)
            if (error != null) Log.println(priority, TAG, Log.getStackTraceString(error))
        } catch (_: RuntimeException) {
            // android.jar stubs throw in local JVM tests.
        }
    }
}
