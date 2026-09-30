package dev.albizia.jackfield

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import dev.albizia.jackfield.store.CallEntity

/** Owns the mandatory CallStyle foreground notification on Android 14+. */
internal class JackfieldCallService : Service() {
    private val active = linkedMapOf<String, Notification>()
    private var ringingCallId: String? = null
    private var ringtone: Ringtone? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var audioFocus: AudioFocusRequest? = null
    private var priorAudioMode = AudioManager.MODE_NORMAL

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callId = intent?.getStringExtra(EXTRA_CALL_ID) ?: return START_NOT_STICKY
        when (intent.action) {
            ACTION_SHOW -> {
                val notification = CallNotifications.build(
                    this,
                    callId,
                    intent.getStringExtra(EXTRA_CALLER_NAME).orEmpty(),
                    intent.getStringExtra(EXTRA_STATE).orEmpty(),
                )
                active[callId] = notification
                promote(callId, notification)
                if (intent.getStringExtra(EXTRA_STATE) == "ringing") startRinging(callId)
                else stopRinging(callId)
            }
            ACTION_ACTIVATE -> {
                stopRinging(callId)
                activateCallAudio()
            }
            ACTION_END -> {
                stopRinging(callId)
                active.remove(callId)
                getSystemService(android.app.NotificationManager::class.java)
                    .cancel(CallNotifications.notificationId(callId))
                val replacement = active.entries.lastOrNull()
                if (replacement == null) {
                    releaseCallAudio()
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                } else {
                    promote(replacement.key, replacement.value)
                }
            }
        }
        return if (active.isEmpty()) START_NOT_STICKY else START_REDELIVER_INTENT
    }

    override fun onDestroy() {
        stopRinging(null)
        releaseCallAudio()
        super.onDestroy()
    }

    private fun startRinging(callId: String) {
        if (ringingCallId == callId && ringtone?.isPlaying == true) return
        stopRinging(null)
        ringingCallId = callId
        val power = getSystemService(PowerManager::class.java)
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "jackfield:incoming-call").apply {
            setReferenceCounted(false)
            acquire(120_000)
        }
        ringtone = RingtoneManager.getRingtone(this, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE))?.apply {
            audioAttributes = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isLooping = true
            play()
        }
    }

    private fun stopRinging(callId: String?) {
        if (callId != null && ringingCallId != callId) return
        ringtone?.stop()
        ringtone = null
        ringingCallId = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun activateCallAudio() {
        val audio = getSystemService(AudioManager::class.java)
        priorAudioMode = audio.mode
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .build(),
                )
                .setAcceptsDelayedFocusGain(false)
                .setOnAudioFocusChangeListener { }
                .build()
                .also(audio::requestAudioFocus)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        }
    }

    private fun releaseCallAudio() {
        val audio = getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocus?.let(audio::abandonAudioFocusRequest)
        } else {
            @Suppress("DEPRECATION") audio.abandonAudioFocus(null)
        }
        audioFocus = null
        audio.mode = priorAudioMode
    }

    private fun promote(callId: String, notification: Notification) {
        val id = CallNotifications.notificationId(callId)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
        } else {
            startForeground(id, notification)
        }
    }

    companion object {
        private const val ACTION_SHOW = "dev.albizia.jackfield.SHOW_CALL"
        private const val ACTION_END = "dev.albizia.jackfield.END_CALL"
        private const val ACTION_ACTIVATE = "dev.albizia.jackfield.ACTIVATE_CALL"
        private const val EXTRA_CALL_ID = "callId"
        private const val EXTRA_CALLER_NAME = "callerName"
        private const val EXTRA_STATE = "state"

        fun showIntent(context: Context, call: CallEntity) = Intent(context, JackfieldCallService::class.java).apply {
            action = ACTION_SHOW
            putExtra(EXTRA_CALL_ID, call.callId)
            putExtra(EXTRA_CALLER_NAME, call.callerName)
            putExtra(EXTRA_STATE, call.state)
        }

        fun endIntent(context: Context, callId: String) = Intent(context, JackfieldCallService::class.java).apply {
            action = ACTION_END
            putExtra(EXTRA_CALL_ID, callId)
        }

        fun activateIntent(context: Context, callId: String) = Intent(context, JackfieldCallService::class.java).apply {
            action = ACTION_ACTIVATE
            putExtra(EXTRA_CALL_ID, callId)
        }
    }
}
