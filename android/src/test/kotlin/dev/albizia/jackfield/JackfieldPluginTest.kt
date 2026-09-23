package dev.albizia.jackfield

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Test
import kotlin.test.assertEquals

class JackfieldPluginTest {
    @Test
    fun `unsupported command returns canonical failure without an engine`() {
        var reply: Any? = null
        val result = object : MethodChannel.Result {
            override fun success(value: Any?) { reply = value }
            override fun error(code: String, message: String?, details: Any?) { reply = code }
            override fun notImplemented() { reply = "notImplemented" }
        }
        JackfieldPlugin().onMethodCall(MethodCall("unknownCommand", mapOf("version" to 1)), result)
        assertEquals(mapOf("version" to 1, "status" to "failure", "error" to mapOf("code" to "unsupported")), reply)
    }
}
