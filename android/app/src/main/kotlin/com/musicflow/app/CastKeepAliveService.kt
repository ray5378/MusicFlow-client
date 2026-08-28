package com.musicflow.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/// DLNA 投屏后台保活前台服务。
///
/// 作用：直投整个播放队列期间，把本进程置为「前台」态并持有 PARTIAL 唤醒锁。
///   - 前台态可让系统不因后台/内存压力直接杀死投屏进程；
///   - 唤醒锁保证熄屏/Doze 下 CPU 常醒，2s 状态轮询定时器持续触发，
///     从而「曲目放完 → 自动推下一首」在后台也能准点完成。
/// 本服务本身不做播放，仅承担保活与常驻通知；播放/续播逻辑仍在 Dart 侧。
class CastKeepAliveService : Service() {

    companion object {
        private const val CHANNEL_ID = "musicflow_cast_keepalive"
        private const val NOTIF_ID = 0x4D43 // "MC"：稳定常量，投屏通知 id
        private const val WAKE_LOCK_TAG = "musicflow:cast_service"
        private var wakeLock: PowerManager.WakeLock? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForegroundCompat()
        acquireKeepAlive()
        // 抗冻结心跳已改为「按曲末时刻一次性预约」模型：具体曲目/时刻由 Dart 侧在
        // 每首歌开始时算好并通过 armCastHeartbeat 预约。服务起停负责持有进程前台态 +
        // 唤醒锁，保证 Dart 轮询与曲末唤醒都能落地；停止时 cancel 心跳。
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY：系统偶尔回收后会自动重建，确保投屏期间保活尽量不中断。
        // 一次性的曲末心跳由 Dart 每次监督预约，服务重建不影响其有效性。
        return START_STICKY
    }

    override fun onDestroy() {
        CastHeartbeat.cancel(this)
        releaseKeepAlive()
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "投屏后台运行",
            NotificationManager.IMPORTANCE_MIN
        ).apply { setShowBadge(false) }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        // 点击通知回到播放器界面。
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("MusicFlow 正在投屏")
            .setContentText("后台持续运行，播放完自动切到下一首")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun acquireKeepAlive() {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            WAKE_LOCK_TAG
        ).also {
            if (!it.isHeld) it.acquire()
        }
    }

    private fun releaseKeepAlive() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }
}