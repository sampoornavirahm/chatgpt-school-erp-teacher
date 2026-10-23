package com.iqnaut.teachers_app

import com.google.firebase.appdistribution.FirebaseAppDistribution
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var checkingForUatUpdate = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "school_erp/app_distribution")
            .setMethodCallHandler { call, result ->
                if (call.method != "checkForUpdate") {
                    result.success(false)
                    return@setMethodCallHandler
                }
                if (checkingForUatUpdate) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                checkingForUatUpdate = true
                FirebaseAppDistribution.getInstance()
                    .updateIfNewReleaseAvailable()
                    .addOnCompleteListener {
                        checkingForUatUpdate = false
                        result.success(true)
                    }
            }
    }
}
