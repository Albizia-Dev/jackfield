package dev.albizia.jackfield

import kotlinx.coroutines.CancellationException

/** Pure channel routing; storage/presentation work runs on the plugin's IO scope. */
internal class AndroidChannelBackend(private val controller: CallController) {
    suspend fun handle(method: String, arguments: Any?): Map<String, Any?> {
        try {
            return when (method) {
                "initialize" -> {
                    val data = Wire.request(arguments, emptySet(), setOf("callbacks"))
                    controller.initialize(Wire.configuration(data["callbacks"]))
                    Wire.success()
                }
                "capabilities" -> { Wire.request(arguments, emptySet()); controller.capabilities() }
                "diagnostics" -> { Wire.request(arguments, emptySet()); controller.diagnostics() }
                "pushTokens" -> { Wire.request(arguments, emptySet()); Wire.success(controller.pushTokens()) }
                "reportIncomingCall" -> Wire.success(controller.reportIncoming(Wire.request(arguments, setOf("callId", "caller", "media"))).toWire())
                "startOutgoingCall" -> Wire.success(controller.startOutgoing(Wire.request(arguments, setOf("callId", "callee", "media"))).toWire())
                "updateCall" -> Wire.success(controller.updateCall(Wire.request(arguments, setOf("callId"), setOf("caller", "media"))).toWire())
                "endCall" -> {
                    val data = Wire.request(arguments, setOf("callId", "reason"))
                    Wire.success(controller.endCall(Wire.string(data["callId"]), Wire.reason(data["reason"])).toWire())
                }
                "completeAction" -> {
                    val data = Wire.request(arguments, setOf("actionId", "succeeded"))
                    controller.completeAction(Wire.string(data["actionId"]), Wire.bool(data["succeeded"]))
                    Wire.success()
                }
                "acknowledgeEvents" -> {
                    val data = Wire.request(arguments, setOf("eventIds"))
                    val ids = data["eventIds"] as? List<*> ?: Wire.fail()
                    controller.acknowledgeEvents(ids.map(Wire::string))
                    Wire.success()
                }
                else -> Wire.failure(JackfieldFailure("unsupported"))
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            controller.recordError(error)
            if (method in queries) throw JackfieldFailure(Wire.code(error))
            return Wire.failure(error)
        }
    }
    companion object {
        val queries = setOf("capabilities", "diagnostics")
        val methods = queries + setOf("initialize", "pushTokens", "reportIncomingCall", "startOutgoingCall", "updateCall", "endCall", "completeAction", "acknowledgeEvents")
    }
}
