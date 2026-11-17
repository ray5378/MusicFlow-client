package com.musicflow.app

import android.Manifest
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceFragmentActivity() {
    companion object {
        private const val APP_LIFECYCLE_CHANNEL = "com.musicflow.app/app_lifecycle"
        private const val DLNA_CHANNEL = "com.musicflow.app/dlna"
        // 内置更新：唤装（安装未知应用授权 + 拉起系统安装器）。
        private const val APK_INSTALL_CHANNEL = "com.musicflow.app/apk_install"
        // 内置更新：后台下载（系统 DownloadManager，通知栏进度，杀进程不断）。
        private const val APK_DOWNLOAD_CHANNEL = "com.musicflow.app/apk_download"
        // 平台信息：当前只有 Android API level（媒体通知布局按 30 分叉要用）。
        private const val PLATFORM_INFO_CHANNEL = "com.musicflow.app/platform_info"
        private const val NEARBY_PERMISSION_REQ = 31001

        private var multicastLock: WifiManager.MulticastLock? = null
        private var wakeLock: PowerManager.WakeLock? = null
        // 直投后台续播保活：CLOSE_WAKE_TIMEOUT 为 0 表示常驻，
        // 视觉维持 FULL 走 mediaPlayback 前台服务，CPU 用 PARTIAL 保持 timer 触发。
        private const val CAST_WAKE_LOCK_TAG = "musicflow:dlna_cast"

        // 投屏期间的 Wi-Fi 高性能锁。
        //
        // 为什么必须有它：PARTIAL WakeLock 只保证 **CPU** 不挂起，不保证 Wi-Fi 射频
        // 全速。熄屏后 Wi-Fi 进省电模式，内网请求的 RTT 会从个位数 ms 涨到秒级，
        // 客户端 6s 的状态轮询直接 TimeoutException —— 而通知栏的进度/歌词/歌名
        // 全部由这份轮询结果驱动，于是「退后台几秒后整块冻住，回前台立刻恢复」。
        // 这把锁让 Wi-Fi 在熄屏期间保持全速（两条链路共用）。
        private var wifiLock: WifiManager.WifiLock? = null
        private const val CAST_WIFI_LOCK_TAG = "musicflow:cast_wifi"

        // 与 android/app/src/main/res/xml/file_paths.xml 的 authority 必须一致
        // （清单里注册为 ${applicationId}.fileprovider）。
        private const val APK_FILE_PROVIDER_SUFFIX = ".fileprovider"
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
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

        // 链路 C：内置更新的「唤装」能力。
        // 为什么要自建通道：`permission_handler` 没有「安装未知应用」这一项 ——
        // 它不是普通运行时权限，而是 Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES
        // 对应的特殊应用访问权限，只能原生判/原生拉设置页。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APK_INSTALL_CHANNEL
        ).setMethodCallHandler { call, result ->
            _apkInstallHandler(call, result)
        }

        // 链路 D：内置更新的「后台下载」能力。
        // Dart 侧退到后台不保证存活，几十 MB 的包必须交给系统 DownloadManager：
        // 通知栏进度、杀进程不断、302 自动跟随、失败自动重试全由系统负责。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APK_DOWNLOAD_CHANNEL
        ).setMethodCallHandler { call, result ->
            _apkDownloadHandler(call, result)
        }

        // 链路 E：平台信息（API level）。
        // 为什么需要：媒体通知的布局在 Android 11（API 30）发生分叉 ——
        // 30 起由 SystemUI 用 MediaSession 元数据渲染，只有「标题 + 歌手」两行；
        // 30 以下走 audio_service 自建的 MediaStyle 通知，标题/歌手/subText 三行
        // 都会渲染。Dart 侧据此决定歌词写进副标题（30+）还是第三行（<30）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PLATFORM_INFO_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "androidSdkInt" -> result.success(Build.VERSION.SDK_INT)
                else -> result.notImplemented()
            }
        }
    }

    // ─────────────────────────── apk_install 通道 ───────────────────────────

    private fun _apkInstallHandler(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Android 8.0（API 26）以下没有这个开关，恒为 true。
            "canRequestPackageInstalls" -> {
                result.success(_canRequestPackageInstalls())
            }
            "openUnknownSourcesSettings" -> {
                result.success(_openUnknownSourcesSettings())
            }
            "installApk" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("APK_PATH_MISSING", "path argument is null or empty", null)
                    return
                }
                if (!_canRequestPackageInstalls()) {
                    result.error(
                        "INSTALL_PERMISSION_REQUIRED",
                        "REQUEST_INSTALL_PACKAGES not granted by user",
                        null
                    )
                    return
                }
                val file = File(path)
                if (!file.exists()) {
                    result.error("APK_NOT_FOUND", "apk file not found: $path", null)
                    return
                }
                try {
                    // 必须用 FileProvider 的 content:// —— Android 7.0 起直接把
                    // file:// 塞进 Intent 会抛 FileUriExposedException。
                    val uri: Uri = FileProvider.getUriForFile(
                        this,
                        "$packageName$APK_FILE_PROVIDER_SUFFIX",
                        file
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, APK_MIME_TYPE)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    // 只代表安装器界面被拉起；字节流由安装器异步读，
                    // 所以调用方绝不能在这一刻删文件。
                    result.success(true)
                } catch (e: Exception) {
                    result.error("INSTALL_APK_FAILED", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun _canRequestPackageInstalls(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    private fun _openUnknownSourcesSettings(): Boolean {
        // 先试「安装未知应用」专页；部分精简 ROM 没有这一页，退回应用详情页。
        val candidates = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            candidates.add(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
            )
        }
        candidates.add(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            )
        )
        for (intent in candidates) {
            try {
                startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (e: Exception) {
                // 试下一个候选页。
            }
        }
        return false
    }

    // ─────────────────────────── apk_download 通道 ──────────────────────────

    private fun _apkDownloadHandler(call: MethodCall, result: MethodChannel.Result) {
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as? DownloadManager
        if (dm == null) {
            if (call.method == "isAvailable") {
                result.success(false)
            } else {
                result.error("DOWNLOAD_MANAGER_UNAVAILABLE", "DownloadManager is null", null)
            }
            return
        }
        when (call.method) {
            "isAvailable" -> result.success(true)
            "enqueue" -> {
                val url = call.argument<String>("url")
                val fileName = call.argument<String>("fileName")
                val title = call.argument<String>("title")
                val description = call.argument<String>("description") ?: ""
                if (url.isNullOrBlank() || fileName.isNullOrBlank()) {
                    result.error("ENQUEUE_ARG_MISSING", "url/fileName required", null)
                    return
                }
                try {
                    // DownloadManager 遇到同名文件会自动加 `-1` 后缀，落盘名就对不上
                    // Dart 侧记下的 fileName 了 —— 所以必须先删掉同名旧文件。
                    val downloadsDir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                    if (downloadsDir == null) {
                        result.error(
                            "EXTERNAL_FILES_UNAVAILABLE",
                            "getExternalFilesDir returned null",
                            null
                        )
                        return
                    }
                    val target = File(downloadsDir, fileName)
                    if (target.exists()) target.delete()

                    val request = DownloadManager.Request(Uri.parse(url)).apply {
                        setTitle(title ?: fileName)
                        setDescription(description)
                        setMimeType(APK_MIME_TYPE)
                        setNotificationVisibility(
                            DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                        )
                        setDestinationInExternalFilesDir(
                            this@MainActivity,
                            Environment.DIRECTORY_DOWNLOADS,
                            fileName
                        )
                        // 手机流量下也允许继续（更新包几十 MB，用户点之前已经确认过）。
                        setAllowedOverMetered(true)
                        setAllowedOverRoaming(false)
                    }
                    result.success(dm.enqueue(request))
                } catch (e: Exception) {
                    result.error("ENQUEUE_FAILED", e.message, null)
                }
            }
            "query" -> {
                val id = call.argument<Number>("id")?.toLong()
                if (id == null) {
                    result.error("QUERY_ARG_MISSING", "id required", null)
                    return
                }
                try {
                    result.success(_queryDownload(dm, id))
                } catch (e: Exception) {
                    result.error("QUERY_FAILED", e.message, null)
                }
            }
            "cancel" -> {
                val id = call.argument<Number>("id")?.toLong()
                if (id == null) {
                    result.error("CANCEL_ARG_MISSING", "id required", null)
                    return
                }
                try {
                    result.success(dm.remove(id) > 0)
                } catch (e: Exception) {
                    result.error("CANCEL_FAILED", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun _queryDownload(dm: DownloadManager, id: Long): Map<String, Any?>? {
        val cursor = dm.query(DownloadManager.Query().setFilterById(id)) ?: return null
        try {
            if (!cursor.moveToFirst()) return null
            val statusIdx = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
            val status = if (statusIdx >= 0) cursor.getInt(statusIdx) else -1
            val totalIdx = cursor.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
            val total = if (totalIdx >= 0) cursor.getLong(totalIdx) else -1L
            val soFarIdx = cursor.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
            val soFar = if (soFarIdx >= 0) cursor.getLong(soFarIdx) else 0L
            val uriIdx = cursor.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI)
            val localUri = if (uriIdx >= 0) cursor.getString(uriIdx) else null
            val reasonIdx = cursor.getColumnIndex(DownloadManager.COLUMN_REASON)
            val reason = if (reasonIdx >= 0) cursor.getInt(reasonIdx) else 0

            return when (status) {
                DownloadManager.STATUS_PENDING -> mapOf(
                    "status" to "pending", "downloaded" to 0, "total" to total,
                    "localUri" to null, "reason" to 0
                )
                DownloadManager.STATUS_RUNNING -> mapOf(
                    "status" to "running", "downloaded" to soFar, "total" to total,
                    "localUri" to null, "reason" to 0
                )
                DownloadManager.STATUS_PAUSED -> mapOf(
                    "status" to "paused", "downloaded" to soFar, "total" to total,
                    "localUri" to null, "reason" to reason
                )
                DownloadManager.STATUS_SUCCESSFUL -> mapOf(
                    // 成功时 COLUMN_BYTES_DOWNLOADED_SO_FAR 在部分 ROM 上是 0，
                    // 直接用总大小当已下载，进度条才能走到 100%。
                    "status" to "successful",
                    "downloaded" to if (total > 0) total else soFar,
                    "total" to total,
                    "localUri" to localUri,
                    "reason" to 0
                )
                DownloadManager.STATUS_FAILED -> mapOf(
                    "status" to "failed", "downloaded" to soFar, "total" to total,
                    "localUri" to null, "reason" to reason
                )
                else -> mapOf(
                    "status" to "unknown", "downloaded" to soFar, "total" to total,
                    "localUri" to null, "reason" to reason
                )
            }
        } finally {
            cursor.close()
        }
    }

    // ───────────────────────────────── DLNA ────────────────────────────────

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
            // 投屏期间的 Wi-Fi 高性能锁：与上面的 PARTIAL WakeLock 配对使用。
            // WakeLock 保住 CPU（timer 能触发），这把锁保住 Wi-Fi（请求别超时），
            // 二者缺一都会表现为「退后台几秒后通知栏不再更新」。
            // 同样不开启原生引用计数（由 Dart 侧统一计数，isHeld 幂等防重叠）。
            "acquireWifiLock" -> {
                try {
                    val wifiManager = getApplicationContext()
                        .getSystemService(WIFI_SERVICE) as WifiManager
                    // 只用 FULL_HIGH_PERF，不切 LOW_LATENCY：后者是「前台低延迟」模式，
                    // 应用不在前台时系统会直接不认（投屏恰恰全是后台场景）。
                    // FULL_HIGH_PERF 自 API 29 起标记 deprecated，但各版本仍然被当作
                    // 「别让 Wi-Fi 射频睡下去」的权威锁，且不要求前台。
                    @Suppress("DEPRECATION")
                    val mode = WifiManager.WIFI_MODE_FULL_HIGH_PERF
                    val lock = wifiLock ?: wifiManager.createWifiLock(mode, CAST_WIFI_LOCK_TAG).also {
                        // 引用计数在 Dart 侧（DlnaKeepaliveController），原生侧关掉，
                        // 否则两边各计一次会导致过早释放。
                        it.setReferenceCounted(false)
                        wifiLock = it
                    }
                    if (!lock.isHeld) lock.acquire()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ACQUIRE_WIFI_LOCK_FAILED", e.message, null)
                }
            }
            "releaseWifiLock" -> {
                try {
                    if (wifiLock?.isHeld == true) wifiLock?.release()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("RELEASE_WIFI_LOCK_FAILED", e.message, null)
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
