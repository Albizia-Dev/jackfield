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
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import dev.albizia.jackfield.store.CallEntity

/** Owns the mandatory CallStyle foreground notification on Android 14+. */
internal class JackfieldCallService : Service() {
    private val active = linkedMapOf<String, Notification>()
    private val ringingCallIds = linkedSetOf<String>()
    private var ringtonePlayer: MediaPlayer? = null
    private var audioFocusRequest: AudioFocusRequest? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callId = intent?.getStringExtra(EXTRA_CALL_ID) ?: return START_NOT_STICKY
        when (intent.action) {
            ACTION_SHOW -> {
                val state = intent.getStringExtra(EXTRA_STATE).orEmpty()
                if (state == "ringing") ringingCallIds.add(callId) else ringingCallIds.remove(callId)
                val notification = CallNotifications.build(
                    this,
                    callId,
                    intent.getStringExtra(EXTRA_CALLER_NAME).orEmpty(),
                    state,
                )
                active[callId] = notification
                promote(callId, notification)
                updateRingtone()
            }
            ACTION_END -> {
                ringingCallIds.remove(callId)
                updateRingtone()
                active.remove(callId)
                getSystemService(android.app.NotificationManager::class.java)
                    .cancel(CallNotifications.notificationId(callId))
                val replacement = active.entries.lastOrNull()
                if (replacement == null) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                } else {
                    promote(replacement.key, replacement.value)
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        ringingCallIds.clear()
        stopRingtone()
        super.onDestroy()
    }

    private fun updateRingtone() {
        if (ringingCallIds.isEmpty()) {
            Log.i("Jackfield", "ringtone.stop")
            stopRingtone()
        } else {
            Log.i("Jackfield", "ringtone.request activeCalls=${ringingCallIds.size}")
            startRingtone()
        }
    }

    private fun startRingtone() {
        if (ringtonePlayer != null) return
        val uri = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: return
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val audioManager = getSystemService(AudioManager::class.java)
        val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener { change ->
                Log.i("Jackfield", "ringtone.audio_focus_change change=$change")
                if (change == AudioManager.AUDIOFOCUS_LOSS) {
                    stopRingtone()
                }
            }
            .build()
        val focusResult = try {
            audioManager.requestAudioFocus(focusRequest)
        } catch (error: Exception) {
            Log.w("Jackfield", "ringtone.audio_focus_failed", error)
            return
        }
        if (focusResult != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            Log.w("Jackfield", "ringtone.audio_focus_denied result=$focusResult")
        }

        val player = MediaPlayer()
        try {
            player.setAudioAttributes(attributes)
            player.isLooping = true
            player.setDataSource(this, uri)
            player.setOnPreparedListener { prepared ->
                if (ringingCallIds.isNotEmpty()) {
                    prepared.start()
                    Log.i("Jackfield", "ringtone.started isPlaying=${prepared.isPlaying}")
                } else {
                    stopRingtone()
                }
            }
            player.setOnErrorListener { _, _, _ ->
                Log.e("Jackfield", "ringtone.media_player_error")
                stopRingtone()
                true
            }
            ringtonePlayer = player
            audioFocusRequest = focusRequest
            player.prepareAsync()
        } catch (error: Exception) {
            player.release()
            if (focusResult == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                audioManager.abandonAudioFocusRequest(focusRequest)
            }
            Log.w("Jackfield", "ringtone.start_failed", error)
        }
    }

    private fun stopRingtone() {
        val player = ringtonePlayer
        ringtonePlayer = null
        if (player != null) {
            try {
                if (player.isPlaying) player.stop()
            } catch (_: IllegalStateException) {
                // The player may still be preparing or may already have failed.
            } finally {
                player.release()
            }
        }
        audioFocusRequest?.let { request ->
            getSystemService(AudioManager::class.java).abandonAudioFocusRequest(request)
        }
        audioFocusRequest = null
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
    }
}
