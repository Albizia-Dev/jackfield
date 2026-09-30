package dev.albizia.jackfield

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.lang.ref.WeakReference

/** Minimal native incoming-call surface that works before Flutter is running. */
class JackfieldIncomingCallActivity : Activity() {
    private var callId: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        JackfieldLog.info("fullscreen.created", intent.getStringExtra(EXTRA_CALL_ID), "locked=${keyguardManager.isKeyguardLocked}")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        bind(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        JackfieldLog.info("fullscreen.new_intent", intent.getStringExtra(EXTRA_CALL_ID))
        bind(intent)
    }

    override fun onStart() {
        super.onStart()
        synchronized(ACTIVE_LOCK) { active = WeakReference(this) }
    }

    override fun onDestroy() {
        synchronized(ACTIVE_LOCK) {
            if (active?.get() === this) active = null
        }
        super.onDestroy()
    }

    private fun bind(intent: Intent) {
        callId = intent.getStringExtra(EXTRA_CALL_ID).orEmpty()
        if (callId.isBlank()) {
            JackfieldLog.warn("fullscreen.invalid_call")
            finishAndRemoveTask()
            return
        }
        val caller = intent.getStringExtra(EXTRA_CALLER_NAME).orEmpty().ifBlank { "Incoming call" }
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                setPadding(dp(28), dp(48), dp(28), dp(48))
                setBackgroundColor(Color.rgb(17, 20, 25))
                addView(TextView(context).apply {
                    text = "Incoming call"
                    textSize = 18f
                    setTextColor(Color.LTGRAY)
                    gravity = Gravity.CENTER
                }, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                addView(TextView(context).apply {
                    text = caller
                    textSize = 32f
                    setTextColor(Color.WHITE)
                    gravity = Gravity.CENTER
                    setPadding(0, dp(20), 0, dp(56))
                }, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                addView(
                    LinearLayout(context).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER
                        addView(actionButton("Decline", Color.rgb(180, 35, 45)) { perform("reject") })
                        addView(actionButton("Answer", Color.rgb(35, 145, 75)) { perform("answer") })
                    },
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                )
            },
        )
    }

    private fun actionButton(label: String, color: Int, action: () -> Unit) = Button(this).apply {
        text = label
        textSize = 18f
        setTextColor(Color.WHITE)
        setBackgroundColor(color)
        setOnClickListener { action() }
        layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
            val gap = (12 * resources.displayMetrics.density).toInt()
            setMargins(gap, 0, gap, 0)
        }
    }

    private fun perform(action: String) {
        JackfieldLog.info("fullscreen.action", callId, "action=$action")
        sendBroadcast(Intent(this, dev.albizia.jackfield.push.JackfieldActionReceiver::class.java).apply {
            this.action = action
            putExtra(EXTRA_CALL_ID, callId)
        })
        finishAndRemoveTask()
    }

    companion object {
        const val EXTRA_CALL_ID = "callId"
        const val EXTRA_CALLER_NAME = "callerName"
        private val ACTIVE_LOCK = Any()
        private var active: WeakReference<JackfieldIncomingCallActivity>? = null

        internal fun finishCall(callId: String) {
            val activity = synchronized(ACTIVE_LOCK) { active?.get() } ?: return
            if (activity.callId != callId || activity.isFinishing || activity.isDestroyed) return
            activity.runOnUiThread {
                if (activity.callId == callId && !activity.isFinishing && !activity.isDestroyed) {
                    JackfieldLog.info("fullscreen.remote_finish", callId)
                    activity.finishAndRemoveTask()
                }
            }
        }
    }

    private val keyguardManager
        get() = getSystemService(android.app.KeyguardManager::class.java)
}
