package dev.albizia.jackfield_example

object JackfieldFirebaseMessage {
    sealed interface Parsed

    data class Incoming(
        val callId: String,
        val callerId: String,
        val callerName: String,
        val media: String,
    ) : Parsed

    data class End(val callId: String, val reason: String) : Parsed

    fun parse(data: Map<String, String>): Parsed? {
        if (data["version"] != "1") return null
        val callId = data["callId"].orEmpty()
        if (callId.isBlank()) return null
        return when (data["type"]) {
            "incoming" -> {
                val callerId = data["callerId"].orEmpty()
                val callerName = data["callerName"].orEmpty()
                val media = data["media"].orEmpty()
                if (callerId.isBlank() || callerName.isBlank() || media !in setOf("audio", "video")) {
                    null
                } else {
                    Incoming(callId, callerId, callerName, media)
                }
            }
            "end" -> data["reason"]?.takeIf {
                it in setOf("local", "remote", "rejected", "missed", "failed")
            }?.let { End(callId, it) }
            else -> null
        }
    }
}
