package com.siagamesh.siagamesh_app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.siagamesh.app/device_settings"
    private val PERMISSION_REQUEST_CODE = 1001
    private val PREFS_NAME = "siagamesh_permission_prefs"
    private val KEY_PREFIX_PERM_DENIED = "perm_denied_permanent_"
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
                "isLocationEnabled" -> {
                    result.success(isLocationServiceEnabled())
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
            // Android 11 and lower: location permissions required for BLE discovery
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            )
        }
    }

    private fun checkPrerequisites(): Map<String, Any> {
        val required = getRequiredPermissions()
        val missingPermissions = mutableListOf<String>()
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        for (perm in required) {
            val granted = ContextCompat.checkSelfPermission(this, perm) == PackageManager.PERMISSION_GRANTED
            if (granted) {
                // Bersihkan flag penolakan permanen jika izin ternyata sudah diberikan
                if (prefs.contains(KEY_PREFIX_PERM_DENIED + perm)) {
                    prefs.edit().remove(KEY_PREFIX_PERM_DENIED + perm).apply()
                }
            } else {
                missingPermissions.add(perm)
            }
        }

        // Penolakan permanen hanya dinyatakan benar jika:
        // 1. Izin pernah diminta melalui dialog sistem sebelumnya, DAN
        // 2. Sistem mencatat bahwa pengguna memilih "Don't ask again" pada saat hasil diterima, DAN
        // 3. shouldShowRequestPermissionRationale bernilai false.
        // Jangan menganggap rationale == false saat izin belum pernah diminta sebagai penolakan permanen!
        var permanentlyDenied = false
        if (missingPermissions.isNotEmpty()) {
            for (perm in missingPermissions) {
                val markedPermanent = prefs.getBoolean(KEY_PREFIX_PERM_DENIED + perm, false)
                val rationale = ActivityCompat.shouldShowRequestPermissionRationale(this, perm)
                if (markedPermanent && !rationale) {
                    permanentlyDenied = true
                    break
                }
            }
        }

        val permissionsGranted = missingPermissions.isEmpty()
        val btEnabled = isBluetoothEnabled()
        val locEnabled = isLocationServiceEnabled()
        val gmsInfo = isGooglePlayServicesAvailable()

        return mapOf(
            "permissionsGranted" to permissionsGranted,
            "missingPermissions" to missingPermissions,
            "permanentlyDenied" to permanentlyDenied,
            "bluetoothEnabled" to btEnabled,
            "locationEnabled" to locEnabled,
            "googlePlayServicesAvailable" to (gmsInfo["available"] as? Boolean ?: true),
            "googlePlayServicesStatusCode" to (gmsInfo["statusCode"] as? Int ?: 0),
            "androidVersion" to Build.VERSION.SDK_INT
        )
    }

    private fun isBluetoothEnabled(): Boolean {
        return try {
            val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val adapter = bluetoothManager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
            adapter?.isEnabled == true
        } catch (e: Exception) {
            false
        }
    }

    private fun isLocationServiceEnabled(): Boolean {
        return try {
            val locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            locationManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true ||
            locationManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true
        } catch (e: Exception) {
            false
        }
    }

    private fun isGooglePlayServicesAvailable(): Map<String, Any> {
        return try {
            val googleApiAvailability = GoogleApiAvailability.getInstance()
            val resultCode = googleApiAvailability.isGooglePlayServicesAvailable(this)
            val isAvailable = (resultCode == ConnectionResult.SUCCESS)
            mapOf(
                "available" to isAvailable,
                "statusCode" to resultCode,
                "errorMessage" to (if (isAvailable) "" else googleApiAvailability.getErrorString(resultCode))
            )
        } catch (e: Exception) {
            mapOf(
                "available" to true,
                "statusCode" to 0,
                "errorMessage" to ""
            )
        }
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

        // Jika ada request sebelumnya yang masih menggantung, batalkan dengan aman
        pendingPermissionResult?.let {
            try {
                it.success(false)
            } catch (_: Exception) {}
        }
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
            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val editor = prefs.edit()

            for (i in permissions.indices) {
                val perm = permissions[i]
                val granted = i < grantResults.size && grantResults[i] == PackageManager.PERMISSION_GRANTED
                if (granted) {
                    editor.remove(KEY_PREFIX_PERM_DENIED + perm)
                } else {
                    // Jika ditolak DAN shouldShowRequestPermissionRationale bernilai false saat ini,
                    // berarti pengguna memilih "Don't ask again" (ditolak permanen)
                    val rationale = ActivityCompat.shouldShowRequestPermissionRationale(this, perm)
                    if (!rationale) {
                        editor.putBoolean(KEY_PREFIX_PERM_DENIED + perm, true)
                    } else {
                        editor.remove(KEY_PREFIX_PERM_DENIED + perm)
                    }
                }
            }
            editor.apply()

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
