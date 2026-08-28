package com.musicflow.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * 直投后台「浮动静态心跳」。
 *
 * 相比固定间隔(如 45s)心跳，改成 **每首歌分配一次的一次性闹钟**：由 Dart 侧在
 * 每首歌开始播放时，根据该曲剩余时长算出「结束前几秒」的绝对时刻，通过平台通道
 * 调 [arm] 预约一个一次性唤醒。到点把冻结的进程拉起一次，让 Dart 的曲末看门狗跑一帧：
 *   - 若已切到新歌 → 看门狗自然忽略（不重复推），并按新歌重新 arm 下一跳；
 *   - 若仍是同一首且到了结束时刻 → 看门狗立即触发 advance 推下一首。
 * 因此 receiver 只负责「唤醒」，判断与续订全部交给 Dart 侧，这里不再自续订。
 *
 * 正常播放几乎零打扰：每首歌只在结尾前几秒醒一次；歌曲时长未知（设备 RawHTTP
 * 时长回报 0）时，由 Dart 回退到固定间隔兜底。
 *
 * 用 allowWhileIdle 类闹钟：Doze / 冻结下仍会尽量按维护窗口触发。Android 12+ 的
 * setExactAndAllowWhileIdle 需要 SCHEDULE_EXACT_ALARM，未授予会抛 SecurityException，
 * 这时退到非精确版（深度冻结里会被合并到很久的维护窗口）。因此投屏启动时 Dart 会
 * 主动请求 SCHEDULE_EXACT_ALARM（见 startCastKeepAliveService 的 _requestBackgroundCastPerms），
 * 把「精确闹钟」真正要下来，让曲末唤醒在冻结期间也能基本准点。
 *
 * 承载全链路诊断日志：直接打 system logcat（tag `MusicFlowHB`），并通过 [onEvent]
 * 逆向上报给 Dart（最终进入 app 内可查看的 HEARTBEAT 日志），便于定位
 * 「算错时长 / 没 set 上 / 选择精确还是非精确 / 是否被系统拉起」。
 */
object CastHeartbeat {

    private const val LOG_TAG = "MusicFlowHB"

    /** 曲末前提前唤醒的余量（秒）。设备拉流/缓冲有偏差，留一点余量防漏切。 */
    const val LEAD_SECONDS = 3

    /** 歌曲时长未知时的兜底心跳间隔（毫秒）：交给 Dart 用 arm 预约。 */
    const val FALLBACK_INTERVAL_MS = 45_000L

    private const val REQ_CODE = 0x5A01
    private const val ACTION_HEARTBEAT = "com.musicflow.app.action.CAST_HEARTBEAT"

    /**
     * 原生事件上报给 Dart（逆向通道由 MainActivity 注入）。
     * event 取值：arm.exact / arm.inexact / cancel / woken。
     */
    var onEvent: ((String, Long?) -> Unit)? = null

    private fun emit(event: String, arg: Long? = null) {
        try { onEvent?.invoke(event, arg) } catch (_: Throwable) {}
    }

    /** 冻结期间由系统拉起进程，Dart 侧的 2s 轮询 timer 自动恢复并跑一帧。 */
    class Receiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_HEARTBEAT) return
            val now = System.currentTimeMillis()
            // 相对上次预约的迟到量由 Dart 侧比对（woken.arg vs lastArmTrigger）计算并落日志。
            Log.i(LOG_TAG, "woken at=$now")
            emit("woken", now)
        }
    }

    /**
     * 预约一次在 [triggerAtMs]（绝对时间，毫秒）触发的一次性唤醒。
     * 免抖动：已过期时刻会推到至少 1s 后；同一 PendingIntent 反复 set 会覆盖旧预约，
     * 因此 Dart 侧随播放进度（含 seek）更新预约是安全的。
     */
    fun arm(context: Context, triggerAtMs: Long) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val now = System.currentTimeMillis()
        // 保留请求时刻：便于记录「请求触发 - 实际触发」的偏差(过期预约会被推到 now+1s)。
        val requested = triggerAtMs
        val trigger = if (triggerAtMs <= now) now + 1_000L else triggerAtMs
        val pi = pendingIntent(context)
        var exact = false
        var reason = "api<23"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                am.canScheduleExactAlarms()
            if (canExact) {
                try {
                    // 精确版 allowWhileIdle：冻结下也能按接近触发时间拉起（API 31+ 需权限）。
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                    exact = true
                    reason = "exact granted (canScheduleExactAlarms=true)"
                } catch (e: SecurityException) {
                    // 权限判定与实际授予存在竞态：退非精确版兜底，并记录原因以便排查「为什么不精确」。
                    Log.w(LOG_TAG, "setExactAndAllowWhileIdle SecurityException=$e -> fallback inexact")
                    reason = "exact SecurityException=${e.message}"
                }
            } else {
                reason = "no SCHEDULE_EXACT_ALARM (sdk>=31 canScheduleExactAlarms=false)"
            }
            if (!exact) {
                // 未授予 SCHEDULE_EXACT_ALARM：退非精确版 allowWhileIdle，尽力在维护窗口触发。
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
            }
        } else {
            // API < 23 无 Doze，直接精确触发。
            am.setExact(AlarmManager.RTC_WAKEUP, trigger, pi)
            exact = true
        }
        val e = if (exact) "arm.exact" else "arm.inexact"
        // 全量诊断：请求时刻 vs 实际触发时刻 + 距当前毫秒数 + 精确/非精确选择原因。
        Log.i(
            LOG_TAG,
            "$e requested=$requested trigger=$trigger now=$now inMs=${trigger - now} driftFromNow=${trigger - requested} reason=$reason"
        )
        emit(e, trigger)
    }

    /** 取消已预约的一次性心跳（服务销毁 / 停止投屏时调用）。 */
    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent(context))
        Log.i(LOG_TAG, "cancel at=${System.currentTimeMillis()}")
        emit("cancel")
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