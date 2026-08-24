#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
播放停滞/卡死 专项模拟测试。

忠实复刻 lib/providers/player_provider.dart 中 _startPositionPolling 的
状态机(每 500ms 一 tick)。用"世界驱动"喂入真实 processingState /
sourcePlayerPos / playing 快照,观察看门狗是否在各类卡死情形下发出恢复
动作(重载/跳过/完成),用于暴露"永远无法自愈"的用例,并验证修复。

阈值(与 Dart 常量一致):
  STARTUP_SKIP     = 12  (~6s) 0秒卡死           → 重载当前曲目
  STAGNANT_SKIP    = 10  (~5s) 中途停滞           → 跳到下一首
  STAGNANT_NEAREND = 6   (~3s) 末段停滞           → 视为播完

运行: python3 tool/stall_simulation.py
"""
from __future__ import annotations
from dataclasses import dataclass
from enum import Enum

STARTUP_SKIP = 12
STAGNANT_SKIP = 10
STAGNANT_NEAREND = 6


class Proc(str, Enum):
    idle = "idle"
    loading = "loading"
    buffering = "buffering"
    ready = "ready"
    completed = "completed"


class Action(str, Enum):
    NONE = "none"
    SYNC = "sync"
    ADV_SYNTH = "adv_synth"
    RELOAD = "reload"
    SKIP = "skip"
    COMPLETE = "complete"


@dataclass
class Snap:
    playing: bool
    proc: Proc
    pos: int


class Watchdog:
    """逐行对照 Dart 的位置轮询判定。"""

    def __init__(self, *, suppress_synth_reload: bool):
        self.suppress_synth = suppress_synth_reload
        self.expecting_autoplay = False
        self.last = 0
        self.startup_ticks = 0
        self.stagnant_ticks = 0
        self.ui_pos = 0            # state.position
        self.synth_active = False
        self.using_lock = False
        self.duration_ms = 0

    def step(self, playing, proc, pos):
        src = pos
        ready_playing = playing and proc == Proc.ready

        if self.suppress_synth and self.using_lock:
            synthetic_carrying = (
                self.synth_active and ready_playing and src <= 50
            )
        else:
            synthetic_carrying = False

        delta = abs(src - self.last)

        # ---- 0 秒卡死计数 ----
        at_start = (src <= 1500) or (self.ui_pos <= 1500)
        no_progress = (
            delta <= 150 or proc in (Proc.loading, Proc.buffering)
        )
        wants_playing = playing or self.expecting_autoplay
        if (
            wants_playing and at_start and no_progress
            and not synthetic_carrying
        ):
            self.startup_ticks += 1
        else:
            self.startup_ticks = 0

        if src > 1500:
            self.expecting_autoplay = False

        # ---- 只读停滞计数(仅就绪播放) ----
        if not ready_playing or delta > 150:
            self.stagnant_ticks = 0
        else:
            self.stagnant_ticks += 1

        self.last = src

        if self.startup_ticks >= STARTUP_SKIP:
            self.startup_ticks = 0
            return Action.RELOAD

        # ---- 位置同步 ----
        player_pos = src
        drift = abs(player_pos - self.ui_pos)
        keep_synth = (
            self.synth_active and self.using_lock
            and ready_playing and src <= 50
        )
        preserve_synth = (
            self.synth_active and self.using_lock
            and self.ui_pos > 250
            and (not ready_playing or player_pos + 5000 < self.ui_pos)
        )
        if drift >= 250 and not keep_synth and not preserve_synth:
            if self.synth_active and ready_playing and src > 0 and drift <= 3000:
                self.synth_active = False
            self.ui_pos = player_pos
            return Action.SYNC

        use_synth = (
            self.using_lock and ready_playing and src <= 50
            and self.duration_ms > 0 and self.stagnant_ticks >= 6
        )

        # ---- 末段停滞 → 完成 ----
        if (
            ready_playing and not use_synth
            and self.duration_ms > 3000
            and self.ui_pos < self.duration_ms
            and self.duration_ms - self.ui_pos <= 1500
            and self.stagnant_ticks >= STAGNANT_NEAREND
        ):
            self.stagnant_ticks = 0
            return Action.COMPLETE

        # ---- 中途停滞 → 跳下一首 ----
        if (
            ready_playing and not use_synth
            and self.stagnant_ticks >= STAGNANT_SKIP
        ):
            self.stagnant_ticks = 0
            return Action.SKIP

        if not use_synth:
            return Action.NONE

        next_pos = min(self.ui_pos + 500, self.duration_ms)
        if next_pos <= self.ui_pos:
            return Action.NONE
        self.synth_active = True
        self.ui_pos = next_pos
        return Action.ADV_SYNTH

    def on_reload(self):
        # 重载同曲:回到起点、重新期望自动播放,合成兜底关闭。
        self.ui_pos = 0
        self.last = 0
        self.startup_ticks = 0
        self.stagnant_ticks = 0
        self.expecting_autoplay = True
        self.synth_active = False


class World:
    """场景的底层真实行为。返回 (playing, proc, src_pos)。"""

    def __init__(self):
        self.started = False   # 底层是否已成功进入“在播”

    def on_reload(self, watch):
        """默认:重载不改变底层行为(用于永久卡死的场景,验证看门狗持续重试)。"""
        pass


class W_NormalDriver(World):
    """正常播放:位置每 tick +500,直至接近 duration。"""
    def __init__(self, duration_ms=180000):
        self.pos = 0
        self.duration_ms = duration_ms
    def next(self, _w):
        self.pos = min(self.pos + 500, self.duration_ms)
        return Snap(True, Proc.ready, self.pos)


class W_TransientLoadHang(World):
    """首次源加载挂起:前 8 tick 一直 loading(play 未执行),此后仍挂;
       一遇到看门狗重载,立即成功进入 ready 并持续播放(transient)。"""
    def __init__(self):
        super().__init__()
        self.hang_until_loaded = True
    def next(self, w):
        if self.started:
            # 已恢复:正常播放推进
            p = getattr(self, "_pos", 0) + 500
            self._pos = p
            return Snap(True, Proc.ready, p)
        # 仍在挂起:loading,playing=False(pos=0)
        return Snap(False, Proc.loading, 0)
    def on_reload(self, w):
        # 重载成功:转 ready 播放
        self.started = True
        self._pos = 0
        w.on_reload()


class W_StuckZeroReady(World):
    """ready 播放但 pos 恒 0(playing=True)。看门狗应触发跳过/重载。"""
    def next(self, w):
        return Snap(True, Proc.ready, 0)


class W_LockCacheIOS(World):
    """锁缓存流:真实 pos 恒 0,但音频在播(playing=True)。应靠合成推进,
       不应被重载/跳过打断。"""
    def next(self, w):
        return Snap(True, Proc.ready, 0)
    def on_reload(self, w):
        w.on_reload()


class W_NearEndStuck(World):
    """末段停滞:停在 duration-700ms 不再前推。看门狗应判完成。"""
    def __init__(self, duration_ms=12000):
        super().__init__()
        self.duration_ms = duration_ms
        self.pos = 0
    def next(self, w):
        self.pos = min(self.pos + 500, self.duration_ms - 700)
        return Snap(True, Proc.ready, self.pos)


class W_BufferThenRecover(World):
    """缓冲 N tick 后自然恢复播放(验证长缓冲不被误杀)。"""
    def __init__(self, buffer_ticks):
        super().__init__()
        self.buffer_ticks = buffer_ticks
        self.pos = 0
    def next(self, w):
        if self.buffer_ticks > 0:
            self.buffer_ticks -= 1
            return Snap(True, Proc.buffering, 0)
        self.pos += 500
        return Snap(True, Proc.ready, self.pos)


class W_BufferNever(World):
    """缓冲永不结束(playing=True, buffering, pos 0)。应触发重载恢复/重试。"""
    def next(self, w):
        return Snap(True, Proc.buffering, 0)


class W_MidSongStuck(World):
    """中途停滞:播到歌曲中段(val)后位置不再前推(非锁流)。
       对应原始 bug「播到 3:17 卡死、全长 3:18」;看门狗应跳下一首。"""
    def __init__(self, duration_ms=198000, stuck_at_ms=197000):
        super().__init__()
        self.duration_ms = duration_ms
        self.stuck_at_ms = stuck_at_ms
        self.pos = 0
    def next(self, w):
        if self.pos < self.stuck_at_ms:
            self.pos = min(self.pos + 500, self.stuck_at_ms)
        return Snap(True, Proc.ready, self.pos)


class W_StartJitter(World):
    """起点位置抖动(0/400 交替),但实际开始播放→不应误判卡死。"""
    def __init__(self):
        super().__init__()
        self.n = 0
    def next(self, w):
        self.n += 1
        if self.n % 2 == 1:
            return Snap(True, Proc.ready, 0)
        return Snap(True, Proc.ready, 400)


def run(world, *, duration_ms=0, using_lock=False, suppress_synth=False,
        max_ticks=80):
    wd = Watchdog(suppress_synth_reload=suppress_synth)
    wd.using_lock = using_lock
    wd.duration_ms = duration_ms
    wd.expecting_autoplay = True  # 播放意图(与 Dart 一致,playSong 时置位)

    had_reload = False
    had_skip = False
    had_complete = False
    advanced_ui = False
    recovery_via_reload = False
    actions = []
    for _ in range(max_ticks):
        snap = world.next(wd)
        res = wd.step(snap.playing, snap.proc, snap.pos)
        actions.append(res)
        if res == Action.SKIP:
            had_skip = True
            break
        if res == Action.COMPLETE:
            had_complete = True
            break
        if res == Action.RELOAD:
            had_reload = True
            world.on_reload(wd)
            continue  # 继续模拟,确认重载后的确能进入播放推进
        if res in (Action.ADV_SYNTH, Action.SYNC):
            if wd.ui_pos > 0:
                advanced_ui = True
            if had_reload:
                # 重载后首次出现真实/合成进度 → 确认自愈
                had_reload = False  # 已计入;避免把后续正常播放误判为二次重载
                recovery_via_reload = True
                break
    return {
        "reload": recovery_via_reload or had_reload,
        "skip": had_skip, "complete": had_complete,
        "ui_adv": advanced_ui, "final_ui": wd.ui_pos, "actions": actions,
    }


def verdict(label, r, ok):
    tag = "OK " if ok else "FAIL"
    print(f"  [{tag}] {label}: reload={r['reload']} skip={r['skip']} "
          f"complete={r['complete']} ui_adv={r['ui_adv']} "
          f"final_ui={r['final_ui']}ms")


def main():
    print("=" * 70)
    print("播放停滞/卡死 专项模拟测试  (tick=500ms)")
    print("=" * 70)

    # 1. 正常播放
    r = run(W_NormalDriver(), max_ticks=40)
    verdict("场景1 正常播放(应无任何恢复,位置持续前进)",
            r, not (r["reload"] or r["skip"] or r["complete"]) and r["ui_adv"])

    # 2. 源加载挂起(transient:首次挂起,重载后成功)
    r = run(W_TransientLoadHang(), suppress_synth=True)
    verdict("场景2 源加载挂起(transient,意图标记→重载后恢复)",
            r, r["reload"] and r["ui_adv"])

    # 3. ready 播放但位置恒 0 (playing=True)
    r = run(W_StuckZeroReady(), suppress_synth=True)
    verdict("场景3 ready播放但位置恒0(应先触发跳过/重载)",
            r, r["skip"] or r["reload"])

    # 4. 锁缓存流 iOS 奇观(位置恒0但在播,依赖合成进度)
    r = run(W_LockCacheIOS(), duration_ms=180000, using_lock=True, suppress_synth=False)
    verdict("场景4a 锁缓存在播,修复前(合成推进但会被重载打断)",
            r, not (r["reload"] or r["skip"]))
    r = run(W_LockCacheIOS(), duration_ms=180000, using_lock=True, suppress_synth=True)
    verdict("场景4b 锁缓存在播,修复后(合成推进,不被打断)",
            r, r["ui_adv"] and not (r["reload"] or r["skip"]))

    # 5. 末段停滞(应判完成,不永久卡住)
    r = run(W_NearEndStuck(duration_ms=12000), duration_ms=12000)
    verdict("场景5 末段停滞(应判完成)",
            r, r["complete"])

    # 6. 长时间缓冲:在阈值内恢复 → 不应被误杀
    r = run(W_BufferThenRecover(buffer_ticks=8), max_ticks=40)
    verdict("场景6a 缓冲8tick后恢复(不误判)",
            r, not (r["reload"] or r["skip"]) and r["ui_adv"])

    # 6b. 缓冲永不结束 → 看门狗应重载自愈/重试
    r = run(W_BufferNever(), suppress_synth=True)
    verdict("场景6b 缓冲永不结束(应触发重载恢复)",
            r, r["reload"] or r["skip"])

    # 7. 起点位置抖动但实际在播 → 不应误判卡死
    r = run(W_StartJitter(), max_ticks=40)
    verdict("场景7 起点位置抖动(不误判卡死)",
            r, not (r["reload"] or r["skip"]) and r["ui_adv"])

    # 8a. 逼近末尾卡死(3:17/3:18) → 应判完成兜底
    r = run(W_MidSongStuck(duration_ms=198000, stuck_at_ms=197000),
            duration_ms=198000, max_ticks=410)
    verdict("场景8a 末尾1秒卡死(3:17/3:18,应判完成)",
            r, r["complete"])

    # 8b. 真正中途卡死(停在 60s/180s) → 应跳下一首
    r = run(W_MidSongStuck(duration_ms=180000, stuck_at_ms=90000),
            duration_ms=180000, max_ticks=200)
    verdict("场景8b 中途卡死(60s/180s,应跳下一首)",
            r, r["skip"])

    print("=" * 70)


if __name__ == "__main__":
    main()