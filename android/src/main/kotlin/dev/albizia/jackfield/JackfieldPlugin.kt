package dev.albizia.jackfield

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicLong

/** Wire v1 bridge. Engine detach never acknowledges or deletes durable records. */
class JackfieldPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var events: EventChannel? = null
    private var tokens: EventChannel? = null
    private var context: Context? = null
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val eventGeneration = AtomicLong()
    private val tokenGeneration = AtomicLong()
    @Volatile private var runtime: JackfieldRuntime? = null
    @Volatile private var eventListener: ((Map<String, Any?>) -> Unit)? = null
    @Volatile private var tokenListener: ((Map<String, Any?>) -> Unit)? = null
    private val main by lazy { Handler(Looper.getMainLooper()) }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        channel = MethodChannel(binding.binaryMessenger, "jackfield").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "jackfield/events").also { it.setStreamHandler(stream(false)) }
        tokens = EventChannel(binding.binaryMessenger, "jackfield/push_token_updates").also { it.setStreamHandler(stream(true)) }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in AndroidChannelBackend.methods) { result.success(Wire.failure(JackfieldFailure("unsupported"))); return }
        val app = context
        if (app == null) {
            if (call.method in AndroidChannelBackend.queries) result.error("platformFailure", null, null)
            else result.success(Wire.failure(JackfieldFailure("temporarilyUnavailable")))
            return
        }
        scope.launch {
            try {
                val value = AndroidChannelBackend(getRuntime(app).controller).handle(call.method, call.arguments)
                withContext(Dispatchers.Main) { result.success(value) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                withContext(Dispatchers.Main) {
                    if (call.method in AndroidChannelBackend.queries) result.error(Wire.code(error), null, null)
                    else result.success(Wire.failure(error))
                }
            }
        }
    }
    private fun getRuntime(app: Context) = JackfieldRuntime.get(app).also { runtime = it }
    private fun stream(push: Boolean) = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
            val generation = if (push) tokenGeneration else eventGeneration
            val ticket = generation.incrementAndGet()
            val app = context ?: return sink.error("platformFailure", null, null)
            try { Wire.request(arguments, emptySet()) } catch (_: Exception) { sink.error("protocolFailure", null, null); return }
            scope.launch {
                try {
                    val controller = getRuntime(app).controller
                    val listener: (Map<String, Any?>) -> Unit = { payload ->
                        main.post { if (generation.get() == ticket) sink.success(payload) }
                    }
                    if (generation.get() != ticket) return@launch
                    if (push) { tokenListener = listener; controller.tokenListener = listener }
                    else { eventListener = listener; controller.eventListener = listener; controller.replay() }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { main.post { if (generation.get() == ticket) sink.error("platformFailure", null, null) } }
            }
        }
        override fun onCancel(arguments: Any?) { clearListener(push) }
    }
    private fun clearListener(push: Boolean) {
        if (push) {
            tokenGeneration.incrementAndGet()
            runtime?.controller?.let { if (it.tokenListener === tokenListener) it.tokenListener = null }
            tokenListener = null
        } else {
            eventGeneration.incrementAndGet()
            runtime?.controller?.let { if (it.eventListener === eventListener) it.eventListener = null }
            eventListener = null
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        clearListener(false); clearListener(true)
        channel?.setMethodCallHandler(null); events?.setStreamHandler(null); tokens?.setStreamHandler(null)
        context = null
        scope.cancel()
    }
}
