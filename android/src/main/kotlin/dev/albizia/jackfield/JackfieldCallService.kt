package dev.albizia.jackfield

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import dev.albizia.jackfield.store.CallEntity

/** Owns the mandatory CallStyle foreground notification on Android 14+. */
internal class JackfieldCallService : Service() {
    private val active = linkedMapOf<String, Notification>()
    private var ringingCallId: String? = null
    private var ringtone: Ringtone? = null
    private var legacyRingtone: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var audioFocus: AudioFocusRequest? = null
    private var priorAudioMode = AudioManager.MODE_NORMAL

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callId = intent?.getStringExtra(EXTRA_CALL_ID) ?: run {
            JackfieldLog.warn("service.invalid_intent")
            return START_NOT_STICKY
        }
        JackfieldLog.info("service.command", callId, "action=${intent.action}")
        when (intent.action) {
            ACTION_SHOW -> {
                val firstPresentation = !active.containsKey(callId)
                val callerName = intent.getStringExtra(EXTRA_CALLER_NAME).orEmpty()
                val state = intent.getStringExtra(EXTRA_STATE).orEmpty()
                val notification = CallNotifications.build(
                    this,
                    callId,
                    callerName,
                    state,
                )
                active[callId] = notification
                promote(callId, notification)
                if (state == "ringing") {
                    startRinging(callId)
                    if (firstPresentation) CallNotifications(this).launchFullScreen(callId, callerName)
                } else {
                    stopRinging(callId)
                }
            }
            ACTION_ACTIVATE -> {
                stopRinging(callId)
                activateCallAudio()
                JackfieldLog.info("service.call_audio_active", callId)
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
                    JackfieldLog.info("service.stopped", callId)
                } else {
                    promote(replacement.key, replacement.value)
                }
            }
        }
        return if (active.isEmpty()) START_NOT_STICKY else START_REDELIVER_INTENT
    }

    override fun onDestroy() {
        JackfieldLog.info("service.destroy")
        stopRinging(null)
        releaseCallAudio()
        super.onDestroy()
    }

    private fun startRinging(callId: String) {
        if (ringingCallId == callId && ringtone?.isPlaying == true) {
            JackfieldLog.info("ringtone.already_playing", callId)
            return
        }
        stopRinging(null)
        ringingCallId = callId
        val power = getSystemService(PowerManager::class.java)
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "jackfield:incoming-call").apply {
            setReferenceCounted(false)
            acquire(120_000)
        }
        JackfieldLog.info("wakelock.acquired", callId, "timeout_ms=120000")
        val attributes = AudioAttributes.Builder()
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .build()
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ringtone = RingtoneManager.getRingtone(this, uri)?.apply {
                audioAttributes = attributes
                isLooping = true
                play()
            }
            JackfieldLog.info("ringtone.started", callId, "engine=ringtone looping=true playing=${ringtone?.isPlaying == true}")
        } else {
            legacyRingtone = try {
                MediaPlayer().apply {
                    setAudioAttributes(attributes)
                    setDataSource(this@JackfieldCallService, uri)
                    isLooping = true
                    prepare()
                    start()
                }
            } catch (error: Exception) {
                JackfieldLog.error("ringtone.start_failed", callId, error)
                null
            }
            JackfieldLog.info("ringtone.started", callId, "engine=media_player looping=true playing=${legacyRingtone?.isPlaying == true}")
        }
        vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Vibrator::class.java)
        }
        vibrator?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 1000, 500, 1000), 0))
        JackfieldLog.info("vibration.started", callId, "available=${vibrator?.hasVibrator() == true}")
    }

    private fun stopRinging(callId: String?) {
        if (callId != null && ringingCallId != callId) return
        val stoppedCallId = ringingCallId
        ringtone?.stop()
        ringtone = null
        legacyRingtone?.release()
        legacyRingtone = null
        vibrator?.cancel()
        vibrator = null
        ringingCallId = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        if (stoppedCallId != null) JackfieldLog.info("ringing.stopped", stoppedCallId)
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
                .also {
                    val result = audio.requestAudioFocus(it)
                    JackfieldLog.info("audio.focus_requested", detail = "result=$result sdk=${Build.VERSION.SDK_INT}")
                }
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
        JackfieldLog.info("audio.released", detail = "restored_mode=$priorAudioMode")
    }

    private fun promote(callId: String, notification: Notification) {
        val id = CallNotifications.notificationId(callId)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
        } else {
            startForeground(id, notification)
        }
        JackfieldLog.info("notification.foreground", callId, "notification_id=$id")
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
