package dev.albizia.jackfield

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.util.Log
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import dev.albizia.jackfield.push.JackfieldActionReceiver

class JackfieldIncomingCallActivity : Activity() {
    private val callId: String
        get() = intent.getStringExtra(EXTRA_CALL_ID).orEmpty()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "stage=incoming_ui.created callId=$callId")
        configureLockScreen()
        renderCall()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        renderCall()
    }

    private fun configureLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            window.statusBarColor = ACTIVE_START
            window.navigationBarColor = ACTIVE_END
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = 0
        }

        private fun renderCall() {
        if (callId.isBlank()) {
            finish()
            return
        }

        val callerName = intent.getStringExtra(EXTRA_CALLER_NAME).orEmpty()
            val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
                setPadding(dp(24), dp(20), dp(24), dp(24))
                background = GradientDrawable(
                    GradientDrawable.Orientation.TOP_BOTTOM,
                    intArrayOf(ACTIVE_START, ACTIVE_END),
                )
        }
            content.addView(buildTopBar())

            val center = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
            }
            center.addView(buildAvatar())
            center.addView(TextView(this).apply {
                text = callerName.ifBlank { "Неизвестный абонент" }
                textSize = 28f
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
                maxLines = 2
                setPadding(0, dp(28), 0, dp(8))
            })
            center.addView(TextView(this).apply {
                text = "Входящий звонок"
                textSize = 20f
                setTextColor(0xCCFFFFFF.toInt())
                gravity = Gravity.CENTER
            })
            content.addView(
                center,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    0,
                    1f,
                ),
            )

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
        }
            actions.addView(buildAction(
                icon = android.R.drawable.sym_action_call,
                label = "Отклонить",
                color = REJECT_COLOR,
                rotation = 45f,
                onClick = ::rejectCall,
            ), actionLayoutParams())
            actions.addView(buildAction(
                icon = android.R.drawable.sym_action_call,
                label = "Ответить",
                color = ACCEPT_COLOR,
                onClick = ::answerCall,
            ), actionLayoutParams())
            content.addView(actions, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ))
        setContentView(content)
    }

        private fun buildTopBar(): View = FrameLayout(this).apply {
            val collapse = ImageButton(context).apply {
                setImageResource(android.R.drawable.arrow_down_float)
                imageTintList = android.content.res.ColorStateList.valueOf(Color.WHITE)
                background = null
                contentDescription = "Свернуть"
                setOnClickListener { finish() }
            }
            addView(collapse, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.START or Gravity.TOP))
        }

        private fun buildAvatar(): View = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(AVATAR_COLOR)
            }
            addView(ImageView(context).apply {
                setImageResource(android.R.drawable.ic_menu_myplaces)
                setColorFilter(0xCCFFFFFF.toInt())
                scaleType = ImageView.ScaleType.CENTER_INSIDE
                setPadding(dp(30), dp(30), dp(30), dp(30))
            }, FrameLayout.LayoutParams(dp(112), dp(112), Gravity.CENTER))
            layoutParams = LinearLayout.LayoutParams(dp(112), dp(112))
        }

        private fun buildAction(
            icon: Int,
            label: String,
            color: Int,
            rotation: Float = 0f,
            onClick: () -> Unit,
        ): View = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER

            val button = FrameLayout(context).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(color)
                }
                isClickable = true
                isFocusable = true
                contentDescription = label
                setOnClickListener { onClick() }
                addView(ImageView(context).apply {
                    setImageResource(icon)
                    setColorFilter(Color.WHITE)
                    this.rotation = rotation
                    scaleType = ImageView.ScaleType.CENTER_INSIDE
                }, FrameLayout.LayoutParams(dp(30), dp(30), Gravity.CENTER))
            }
            addView(button, LinearLayout.LayoutParams(dp(72), dp(72)))
            addView(TextView(context).apply {
                text = label
                textSize = 14f
                setTextColor(0xE6FFFFFF.toInt())
                gravity = Gravity.CENTER
                setPadding(0, dp(10), 0, 0)
            })
        }

        private fun actionLayoutParams() = LinearLayout.LayoutParams(0, dp(104), 1f)

        private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private fun answerCall() {
        Log.i(TAG, "stage=incoming_ui.answer_tapped callId=$callId")
        startActivity(Intent(this, JackfieldAnswerActivity::class.java).apply {
            data = callUri("answer")
            putExtra(EXTRA_CALL_ID, callId)
            putExtra(EXTRA_ACTION, "answer")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        })
        finish()
    }

    private fun rejectCall() {
        sendBroadcast(Intent(this, JackfieldActionReceiver::class.java).apply {
            action = "reject"
            data = callUri("reject")
            putExtra(EXTRA_CALL_ID, callId)
        })
        finish()
    }

    private fun callUri(action: String) = Uri.Builder()
        .scheme("jackfield")
        .authority(action)
        .appendPath(callId)
        .build()

    private companion object {
        const val TAG = "JackfieldCallFlow"
        const val EXTRA_CALL_ID = "callId"
        const val EXTRA_CALLER_NAME = "callerName"
        const val EXTRA_ACTION = "action"
        const val ACTIVE_START = 0xFF005941.toInt()
        const val ACTIVE_END = 0xFF002E22.toInt()
        const val AVATAR_COLOR = 0x3DFFFFFF
        const val REJECT_COLOR = 0xFFFF5252.toInt()
        const val ACCEPT_COLOR = 0xFF69F0AE.toInt()
    }
}