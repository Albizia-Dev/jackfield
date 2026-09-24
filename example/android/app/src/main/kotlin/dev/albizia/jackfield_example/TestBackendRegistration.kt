package dev.albizia.jackfield_example

import android.content.Context
import android.util.Log
import dev.albizia.jackfield.push.JackfieldPushReceiver
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import kotlinx.coroutines.runBlocking
import org.json.JSONObject

object TestBackendRegistration {
    private const val TAG = "JackfieldTestBackend"
    private val executor = Executors.newSingleThreadExecutor()

    fun updateToken(context: Context, token: String) {
        if (token.isBlank()) return
        executor.execute {
            runBlocking {
                JackfieldPushReceiver.updatePushToken(context, "fcm", token)
            }
            registerWithBackend(token)
        }
    }

    private fun registerWithBackend(token: String) {
        val baseUrl = BuildConfig.JACKFIELD_TEST_BACKEND_URL.trimEnd('/')
        val apiToken = BuildConfig.JACKFIELD_TEST_API_TOKEN
        if (baseUrl.isBlank() || apiToken.isBlank()) return
        val connection = (URL("$baseUrl/devices/test").openConnection() as HttpURLConnection).apply {
            requestMethod = "PUT"
            connectTimeout = 5_000
            readTimeout = 5_000
            doOutput = true
            setRequestProperty("Authorization", "Bearer $apiToken")
            setRequestProperty("Content-Type", "application/json")
        }
        try {
            connection.outputStream.bufferedWriter(Charsets.UTF_8).use {
                it.write(JSONObject().put("fcmToken", token).toString())
            }
            if (connection.responseCode != HttpURLConnection.HTTP_NO_CONTENT) {
                Log.w(TAG, "Device registration failed with HTTP ${connection.responseCode}")
            }
        } catch (error: Exception) {
            Log.w(TAG, "Device registration failed", error)
        } finally {
            connection.disconnect()
        }
    }
}
