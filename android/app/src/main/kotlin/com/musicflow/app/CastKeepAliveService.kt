package com.musicflow.app

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager

/// DLNA 投屏后台保活服务。
///
/// 作用：直投整个播放队列期间，只持有 PARTIAL 唤醒锁，保证熄屏/Doze 下 CPU 常醒，
/// 2s 状态轮询定时器持续触发，从而「曲目放完 → 自动推下一首」在后台也能准点完成。
/// 进程的「前台态 + 常驻音乐通知」已由 audio_service 的媒体播放前台服务承担
/// （直投期间媒体会话保持前台），本服务不再自建前台通知，避免和播放通知重复。
/// 本服务本身不做播放，仅承担唤醒锁保活；播放/续播逻辑仍在 Dart 侧。
class CastKeepAliveService : Service() {

    companion object {
        private const val WAKE_LOCK_TAG = "musicflow:cast_service"
        private var wakeLock: PowerManager.WakeLock? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        acquireKeepAlive()
        // 抗冻结心跳已改为「按曲末时刻一次性预约」模型：具体曲目/时刻由 Dart 侧在
        // 每首歌开始时算好并通过 armCastHeartbeat 预约。本服务负责持有唤醒锁，
        // 保证 Dart 轮询与曲末唤醒都能落地；停止时 cancel 心跳。
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