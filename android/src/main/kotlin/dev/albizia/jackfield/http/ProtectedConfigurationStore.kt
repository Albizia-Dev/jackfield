package dev.albizia.jackfield.http

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import dev.albizia.jackfield.Wire
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class CallbackConfiguration(val endpoint: String, val token: String, val timeToLiveMs: Long, val maxPendingEvents: Int) {
    override fun toString() = "CallbackConfiguration(redacted)"
}

interface ConfigurationStore {
    fun load(): CallbackConfiguration?
    fun save(value: CallbackConfiguration?)
}

// Serializes credential replacement with the post-request authentication check.
internal object ConfigurationLock

/** AES-GCM ciphertext in no-backup storage; the wrapping key never leaves AndroidKeyStore. */
class ProtectedConfigurationStore(private val file: File, private val key: () -> SecretKey) : ConfigurationStore {
    @Synchronized override fun load(): CallbackConfiguration? {
        val atomic = AtomicFile(file)
        if (!atomic.baseFile.exists()) return null
        val bytes = atomic.readFully()
        require(bytes.size > 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        val json = JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
        return Wire.configuration(Wire.jsonMap(json))
    }

    @Synchronized override fun save(value: CallbackConfiguration?) {
        val atomic = AtomicFile(file)
        if (value == null) { atomic.delete(); return }
        val json = JSONObject(mapOf("endpoint" to value.endpoint, "auth" to mapOf("type" to "bearer", "token" to value.token), "timeToLiveMs" to value.timeToLiveMs, "maxPendingEvents" to value.maxPendingEvents))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val bytes = cipher.iv + cipher.doFinal(json.toString().toByteArray(Charsets.UTF_8))
        val stream = atomic.startWrite()
        try { stream.write(bytes); atomic.finishWrite(stream) } catch (error: Exception) { atomic.failWrite(stream); throw error }
    }

    companion object {
        fun open(context: Context) = ProtectedConfigurationStore(context.noBackupFilesDir.resolve("jackfield-callbacks.enc")) {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val alias = "dev.albizia.jackfield.callbacks.v1"
            (store.getKey(alias, null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
            }.generateKey()
        }
    }
}
