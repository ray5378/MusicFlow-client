package com.musicflow.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceFragmentActivity() {
    companion object {
        private const val APP_LIFECYCLE_CHANNEL = "com.musicflow.app/app_lifecycle"
        private const val DLNA_CHANNEL = "com.musicflow.app/dlna"
        private const val NEARBY_PERMISSION_REQ = 31001

        private var multicastLock: WifiManager.MulticastLock? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_LIFECYCLE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "moveTaskToBack" -> {
                    try {
                        val moved = moveTaskToBack(true)
                        if (!moved) {
                            val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                                addCategory(Intent.CATEGORY_HOME)
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(homeIntent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("MOVE_TO_BACKGROUND_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 链路 B：DLNA 本地投屏原生能力（MulticastLock + Android 13+ 附近设备权限）
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DLNA_CHANNEL
        ).setMethodCallHandler(_dlnaHandler)
    }

    private fun _dlnaHandler(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquireMulticastLock" -> {
                try {
                    val wifiManager = getApplicationContext()
                        .getSystemService(WIFI_SERVICE) as WifiManager
                    val lock = multicastLock ?: wifiManager.createMulticastLock("musicflow_dlna").also {
                        multicastLock = it
                    }
                    if (!lock.isHeld) lock.acquire()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ACQUIRE_MULTICAST_FAILED", e.message, null)
                }
            }
            "releaseMulticastLock" -> {
                try {
                    if (multicastLock?.isHeld == true) multicastLock?.release()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("RELEASE_MULTICAST_FAILED", e.message, null)
                }
            }
            "hasNearbyWifiDevicesPermission" -> {
                result.success(_hasNearbyPermission())
            }
            "requestNearbyWifiDevicesPermission" -> {
                if (_hasNearbyPermission()) {
                    result.success(true)
                } else {
                    ActivityCompat.requestPermissions(
                        this,
                        arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES),
                        NEARBY_PERMISSION_REQ
                    )
                    // 结果通过 pending result 回传
                    pendingNearbyResult = result
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun _hasNearbyPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.NEARBY_WIFI_DEVICES
        ) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NEARBY_PERMISSION_REQ) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            pendingNearbyResult?.success(granted)
            pendingNearbyResult = null
        }
    }

    private var pendingNearbyResult: MethodChannel.Result? = null
}
