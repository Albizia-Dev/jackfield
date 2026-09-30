package dev.albizia.jackfield_example

import android.os.Bundle
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
            TestBackendRegistration.updateToken(applicationContext, token)
        }
    }
}
