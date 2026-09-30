package dev.albizia.jackfield

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicLong

/** Wire v1 bridge. Engine detach never acknowledges or deletes durable records. */
class JackfieldPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener, PluginRegistry.ActivityResultListener {
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
    private var activityBinding: ActivityPluginBinding? = null
    private var permissionFlow: PermissionFlow? = null
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
        if (call.method == "requestPermissions") {
            requestPermissions(call.arguments, result)
            return
        }
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
                Log.e("Jackfield", "${call.method} failed", error)
                withContext(Dispatchers.Main) {
                    if (call.method in AndroidChannelBackend.queries) result.error(Wire.code(error), null, null)
                    else result.success(Wire.failure(error))
                }
            }
        }
    }

    private fun requestPermissions(arguments: Any?, result: MethodChannel.Result) {
        val app = context
        val activity = activityBinding?.activity
        if (app == null || activity == null) {
            result.success(Wire.failure(JackfieldFailure("temporarilyUnavailable")))
            return
        }
        if (permissionFlow != null) {
            result.success(Wire.failure(JackfieldFailure("temporarilyUnavailable")))
            return
        }
        val requested = try {
            val data = Wire.request(arguments, setOf("permissions"))
            val values = data["permissions"] as? List<*> ?: Wire.fail()
            values.map(Wire::string).toSet().also {
                if (it.size != values.size || it.any { name -> name !in PERMISSIONS }) Wire.fail()
            }
        } catch (error: Exception) {
            result.success(Wire.failure(error))
            return
        }
        val flow = PermissionFlow(requested, result)
        permissionFlow = flow
        val runtimePermissions = buildList {
            if ("microphone" in requested && !granted(app, Manifest.permission.RECORD_AUDIO)) {
                add(Manifest.permission.RECORD_AUDIO)
            }
            if ("notifications" in requested && Build.VERSION.SDK_INT >= 33 &&
                !granted(app, Manifest.permission.POST_NOTIFICATIONS)) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
            if ("bluetooth" in requested && Build.VERSION.SDK_INT >= 31 &&
                !granted(app, Manifest.permission.BLUETOOTH_CONNECT)) {
                add(Manifest.permission.BLUETOOTH_CONNECT)
            }
        }
        if (runtimePermissions.isEmpty()) continuePermissionFlow(activity, flow)
        else ActivityCompat.requestPermissions(activity, runtimePermissions.toTypedArray(), REQUEST_RUNTIME_PERMISSIONS)
    }

    private fun continuePermissionFlow(activity: Activity, flow: PermissionFlow) {
        if (permissionFlow !== flow) return
        if ("fullScreenIntent" in flow.requested && Build.VERSION.SDK_INT >= 34 && !fullScreenGranted(activity)) {
            val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                data = Uri.parse("package:${activity.packageName}")
            }
            try {
                flow.openedSettings = true
                activity.startActivityForResult(intent, REQUEST_FULL_SCREEN_INTENT)
                return
            } catch (error: Exception) {
                Log.w("Jackfield", "Full-screen intent settings unavailable", error)
            }
        }
        finishPermissionFlow(flow)
    }

    private fun finishPermissionFlow(flow: PermissionFlow) {
        if (permissionFlow !== flow) return
        val app = context
        permissionFlow = null
        if (app == null) {
            flow.result.success(Wire.failure(JackfieldFailure("temporarilyUnavailable")))
            return
        }
        val states = flow.requested.associateWith { name -> permissionState(app, name) }
        flow.result.success(Wire.success(mapOf("states" to states, "openedSettings" to flow.openedSettings)))
    }

    private fun permissionState(context: Context, name: String): String = when (name) {
        "microphone" -> state(granted(context, Manifest.permission.RECORD_AUDIO))
        "notifications" -> state(NotificationManagerCompat.from(context).areNotificationsEnabled())
        "bluetooth" -> state(Build.VERSION.SDK_INT < 31 || granted(context, Manifest.permission.BLUETOOTH_CONNECT))
        "fullScreenIntent" -> state(fullScreenGranted(context))
        else -> "unknown"
    }

    private fun fullScreenGranted(context: Context): Boolean = Build.VERSION.SDK_INT < 34 ||
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).canUseFullScreenIntent()

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun state(granted: Boolean) = if (granted) "granted" else "denied"

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_RUNTIME_PERMISSIONS) return false
        permissionFlow?.let { flow ->
            activityBinding?.activity?.let { continuePermissionFlow(it, flow) }
                ?: finishPermissionFlow(flow)
        }
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_FULL_SCREEN_INTENT) return false
        permissionFlow?.let(::finishPermissionFlow)
        return true
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

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        permissionFlow?.let(::finishPermissionFlow)
    }

    private data class PermissionFlow(
        val requested: Set<String>,
        val result: MethodChannel.Result,
        var openedSettings: Boolean = false,
    )

    private companion object {
        const val REQUEST_RUNTIME_PERMISSIONS = 0x4A43
        const val REQUEST_FULL_SCREEN_INTENT = 0x4A44
        val PERMISSIONS = setOf("microphone", "notifications", "bluetooth", "fullScreenIntent")
    }
}
