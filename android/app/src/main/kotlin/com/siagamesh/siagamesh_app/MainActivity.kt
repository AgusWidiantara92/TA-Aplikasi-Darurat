package com.siagamesh.siagamesh_app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.siagamesh.app/device_settings"
    private val PERMISSION_REQUEST_CODE = 1001
    private val PREFS_NAME = "siagamesh_permission_prefs"
    private val KEY_REQUESTED = "has_requested_permissions"
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPrerequisites" -> {
                    result.success(checkPrerequisites())
                }
                "requestPermissions" -> {
                    requestAppPermissions(result)
                }
                "isBluetoothEnabled" -> {
                    result.success(isBluetoothEnabled())
                }
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(true)
                }
                "openBluetoothSettings" -> {
                    openBluetoothSettings()
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun getRequiredPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+ (API 31+) uses BLUETOOTH_SCAN, BLUETOOTH_ADVERTISE, BLUETOOTH_CONNECT
            // neverForLocation is specified in Manifest, so Location is NOT required.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                arrayOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.NEARBY_WIFI_DEVICES
                )
            } else {
                arrayOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT
                )
            }
        } else {
            // Android 11 and lower: location permission required for BLE discovery
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION
            )
        }
    }

    private fun checkPrerequisites(): Map<String, Any> {
        val required = getRequiredPermissions()
        val missingPermissions = mutableListOf<String>()

        for (perm in required) {
            if (ContextCompat.checkSelfPermission(this, perm) != PackageManager.PERMISSION_GRANTED) {
                missingPermissions.add(perm)
            }
        }

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val hasRequestedBefore = prefs.getBoolean(KEY_REQUESTED, false)

        var permanentlyDenied = false
        if (hasRequestedBefore && missingPermissions.isNotEmpty()) {
            val anyRationale = missingPermissions.any {
                ActivityCompat.shouldShowRequestPermissionRationale(this, it)
            }
            if (!anyRationale) {
                permanentlyDenied = true
            }
        }

        val permissionsGranted = missingPermissions.isEmpty()
        val btEnabled = isBluetoothEnabled()

        return mapOf(
            "permissionsGranted" to permissionsGranted,
            "missingPermissions" to missingPermissions,
            "permanentlyDenied" to permanentlyDenied,
            "bluetoothEnabled" to btEnabled,
            "androidVersion" to Build.VERSION.SDK_INT
        )
    }

    private fun isBluetoothEnabled(): Boolean {
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
        return adapter?.isEnabled == true
    }

    private fun requestAppPermissions(result: MethodChannel.Result) {
        val required = getRequiredPermissions()
        val missing = required.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }.toTypedArray()

        if (missing.isEmpty()) {
            result.success(true)
            return
        }

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putBoolean(KEY_REQUESTED, true).apply()

        pendingPermissionResult = result
        ActivityCompat.requestPermissions(this, missing, PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            val allGranted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            pendingPermissionResult?.success(allGranted)
            pendingPermissionResult = null
        }
    }

    private fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(intent)
    }

    private fun openBluetoothSettings() {
        val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(intent)
    }
}
