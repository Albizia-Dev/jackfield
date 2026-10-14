package dev.albizia.jackfield

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import dev.albizia.jackfield.push.JackfieldActionReceiver

/** Opens the host app from a notification action, then delivers the call action. */
class JackfieldAnswerActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val callId = intent.getStringExtra(EXTRA_CALL_ID).orEmpty()
        val action = intent.getStringExtra(EXTRA_ACTION).orEmpty().ifBlank { ACTION_ANSWER }
        Log.i(TAG, "stage=answer_activity.started callId=$callId action=$action")
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        if (launchIntent != null) {
            launchIntent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
            startActivity(launchIntent)
        }

        sendBroadcast(
            Intent(this, JackfieldActionReceiver::class.java).apply {
                this.action = action
                putExtra(EXTRA_CALL_ID, callId)
            },
        )
        Log.i(TAG, "stage=answer_activity.broadcast_sent callId=$callId action=$action")
        finish()
    }

    private companion object {
        const val TAG = "JackfieldCallFlow"
        const val ACTION_ANSWER = "answer"
        const val EXTRA_CALL_ID = "callId"
        const val EXTRA_ACTION = "action"
    }
}