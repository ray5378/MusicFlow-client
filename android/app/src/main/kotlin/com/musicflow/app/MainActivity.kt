package com.musicflow.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
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
        private var wakeLock: PowerManager.WakeLock? = null
        // 直投后台续播保活：CLOSE_WAKE_TIMEOUT 为 0 表示常驻，
        // 视觉维持 FULL 走 mediaPlayback 前台服务，CPU 用 PARTIAL 保持 timer 触发。
        private const val CAST_WAKE_LOCK_TAG = "musicflow:dlna_cast"
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
        // 用 lambda 显式委托给 _dlnaHandler，避免裸方法名被当作调用表达式（Kotlin 编译报错）
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DLNA_CHANNEL
        ).setMethodCallHandler { call, result ->
            _dlnaHandler(call, result)
        }
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
            // 直投期间持有 PARTIAL WakeLock：CPU 常醒，保证后台 2s 轮询 timer
            // 持续触发 → 曲末看门狗能主动推下一首（屏幕熄灭/Doze 下 timer 弹挂）。
            "acquireWakeLock" -> {
                try {
                    val pm = getApplicationContext()
                        .getSystemService(POWER_SERVICE) as PowerManager
                    val lock = wakeLock ?: pm.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        CAST_WAKE_LOCK_TAG
                    ).also { wakeLock = it }
                    // 不开启引用计数：由 Dart 侧 _wakeLockRefs 统一计数，
                    // 原生侧仅以 isHeld 幂等防重叠，避免双计数导致过早释放。
                    if (!lock.isHeld) lock.acquire()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ACQUIRE_WAKE_LOCK_FAILED", e.message, null)
                }
            }
            "releaseWakeLock" -> {
                try {
                    if (wakeLock?.isHeld == true) wakeLock?.release()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("RELEASE_WAKE_LOCK_FAILED", e.message, null)
                }
            }
            // 直投期间启动/停止「投屏保活」前台服务：进程置前台态 + 唤醒锁，
            // 保证后台曲末看门狗持续运行。幂等：重复启动无害，停止以显式调用为准。
            "startCastService" -> {
                try {
                    ContextCompat.startForegroundService(
                        this,
                        Intent(this, CastKeepAliveService::class.java)
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.error("START_CAST_SERVICE_FAILED", e.message, null)
                }
            }
            "stopCastService" -> {
                try {
                    val started = stopService(
                        Intent(this, CastKeepAliveService::class.java)
                    )
                    result.success(started)
                } catch (e: Exception) {
                    result.error("STOP_CAST_SERVICE_FAILED", e.message, null)
            }
            }
            // 电池优化豁免：国产 ROM 后台冻结常导致投屏轮询 timer 停摆，即使前台服务
            // + 唤醒锁也难幸免。主动请求让应用列入「不优化」白名单，保证切后台/锁屏仍轮询。
            "isIgnoringBatteryOptimization" -> {
                result.success(_isIgnoringBatteryOptimization())
            }
            "requestIgnoreBatteryOptimization" -> {
                if (_isIgnoringBatteryOptimization()) {
                    result.success(true)
                } else {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName")
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("REQUEST_IGNORE_BATTERY_FAILED", e.message, null)
                    }
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

    private fun _isIgnoringBatteryOptimization(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
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
