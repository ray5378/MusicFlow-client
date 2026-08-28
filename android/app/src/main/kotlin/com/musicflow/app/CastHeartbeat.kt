package com.musicflow.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * 直投后台「抗冻结心跳」。
 *
 * 背景：Dart 侧 2s 状态轮询依赖进程存活。国产 ROM / 鸿蒙后台管控把应用整体冻结时，
 * Dart 的 Timer 会停摆（实测整段冻结 19 分钟，歌早已放完、续播迟迟未补给）——单纯
 * 前台服务 + PARTIAL 唤醒锁挡不住这种「进程冻结」。这里用系统级 AlarmManager 定期
 * 唤醒进程：即便被冻结，也会在系统维护窗口被拉起，让 Dart 轮询填补错过帧，曲末看门狗
 * 随即能按墙钟检测到「设备放完」并主动推下一首。心跳只在投屏保活服务存活期间存在。
 *
 * 用 allowWhileIdle 类闹钟：Doze/冻结下仍会按维护窗口触发。优先精确版保证及时性：
 * Android 12+ 的 setExactAndAllowWhileIdle 需要 SCHEDULE_EXACT_ALARM 权限，未授予时
 * 会抛 SecurityException，此时只能退到非精确版 setAndAllowWhileIdle——它在国产 ROM /
 * 鸿蒙的深度冻结里会被合并到很长（可超 10+ 分钟）的维护窗口，等于「心跳不响、续播遥遥无期」。
 * 所以：这里显式按 canScheduleExactAlarms() 决定走哪条路径（精确优先），同时投屏启动时
 * 会主动请求 SCHEDULE_EXACT_ALARM（见 MainActivity/startCastKeepAliveService），
 * 把「精确闹钟」真正要下来，让心跳在冻结期间也能按 45s 准点唤醒进程补播。
 */
object CastHeartbeat {

    /** 心跳间隔。足够密以兜住冻结时段，又不至于频繁打扰 Doze 维护窗口。 */
    const val DEFAULT_INTERVAL_MS = 45_000L

    private const val REQ_CODE = 0x5A01
    private const val ACTION_HEARTBEAT = "com.musicflow.app.action.CAST_HEARTBEAT"

    /** 投屏期间被冻结后，由系统把进程唤醒执行续订，形成持续的心跳链。 */
    class Receiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_HEARTBEAT) return
            schedule(context)
            // 进程一旦被唤醒，Dart 侧已有的 2s 轮询 timer 会补齐错过帧并立即跑一帧，
            // 曲末看门狗因此能在冻结解除后准点续播。无需在此直接驱动 Dart。
        }
    }

    /** 向系统预约下一跳心跳；服务每次 onCreate / 每次被唤醒续订，幂等。 */
    fun schedule(
        context: Context,
        intervalMs: Long = DEFAULT_INTERVAL_MS,
    ) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val triggerAt = System.currentTimeMillis() + intervalMs
        val pi = pendingIntent(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            // Android 12+ 先显式询问是否已授予精确闹钟权限（未授予时 setExact* 会抛
            // SecurityException），以此决定路径；授予则精确版准点唤醒，未授予则退非精确版。
            val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                am.canScheduleExactAlarms()
            if (canExact) {
                try {
                    // 精确版 allowWhileIdle：Doze / 冻结下仍按触发时间拉起进程（API 31+ 需权限）。
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
                    return
                } catch (_: SecurityException) {
                    // 权限判定与实际授予存在竞态：即便 canScheduleExactAlarms() 为真，
                    // 仍可能抛 SecurityException，这时退到非精确版兜底。
                }
            }
            // 未授予 SCHEDULE_EXACT_ALARM：退到非精确版 allowWhileIdle，尽力在维护窗口触发。
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
        } else {
            // API < 23 无 Doze，直接精确触发。
            am.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pi)
        }
    }

    /** 服务销毁时取消心跳，避免后台长时间占资源被系统判违规。 */
    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent(context))
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, Receiver::class.java).setAction(ACTION_HEARTBEAT)
        return PendingIntent.getBroadcast(
            context,
            REQ_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}