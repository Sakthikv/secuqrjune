package io.flutter.plugins.deviceinfoexample.example


import android.os.Build
import android.os.Bundle
import android.os.StrictMode
import io.flutter.embedding.android.FlutterActivity


package com.example.yourapp

import android.hardware.camera2.*
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var cameraDevice: CameraDevice
    private lateinit var captureSession: CameraCaptureSession
    private val channel = "com.example.yourapp/camera_stabilization"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            if (call.method == "enableStabilization") {
                enableVideoStabilization()
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun enableVideoStabilization() {
        val targets = listOf(/* Your preview surface here */)
        val captureRequestBuilder = cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)

        // Set stabilization mode
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            captureRequestBuilder.set(
                    CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE,
                    CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_ON
            )
        }

        captureSession.setRepeatingRequest(captureRequestBuilder.build(), null, null)
    }
}
class MainActivity: FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Ensures correct use of Activity Context to obtain the WindowManager
            StrictMode.setVmPolicy(StrictMode.VmPolicy.Builder()
                    .detectIncorrectContextUse()
                    .penaltyLog()
                    .penaltyDeath()
                    .build())
        }
        super.onCreate(savedInstanceState)
    }
}