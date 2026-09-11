# 本轮改动总览（2026-09-11 夜 · 三条链路共用服务端预探测）

## 一句话

让**服务端预探测**成为 Web / 投屏(DLNA) / 本机客户端三条链路共用的"提前找可播源"大脑：
服务端为**本机队列**也开始预扫描，三端都读同一套四态判定（`playable/unplayable/transient/unknown`），
**只在 `unplayable` 时预跳**；洗牌模式下 `enqueue` 路径也会物化洗牌序并向前扫描（修复 scanned=0）。

## 用户需求

原目标「三条链路都吃到服务端预探测」此前未达成：投屏链路仅 order/all 生效、shuffle 失效；
Web 与本机客户端"未接入、服务端不跳"。要求：队列变化触发向前扫描，死源被标记且不可播，
三条链路都消费同一结果，客户端跳过死源、自动播可播源。

## 根因

1. **洗牌不扫描**：`peekUpcomingPositions` 的 shuffle 分支依赖 `shuffleOrder`；
   只有 `setQueue`(playFrom) 会物化洗牌序，`enqueue` / `setPlayMode` 不物化 →
   调度时洗牌序为空 → 向前扫描 0 个位置。**是路径差异，不是播放模式差异**。
2. **本机链路缺失**：`PreProbeScheduler` 只被 `QueueController`（投屏）订阅；
   本机队列走 `PeerManager`，无人调度、快照无 `preProbe` 字段。
3. **多订阅互相覆盖**：调度器只有单个 `onChange` 回调，两个消费者会互相顶掉。
4. **判定语义单一**：`/v1/stream/probe` 只回 `ok` 布尔，客户端无法区分
   「网络抖动(transient)」与「确实无源(unplayable)」，存在误杀风险。

## 实现

- 后端 `preProbeScheduler`：单回调 → 多监听者 (`addOnChange`)，投屏与本机可共存订阅。
- 后端 `QueueController`：`setPlayMode/enqueue/removeAt/reorder` 调度前先按需物化洗牌序
  (reorder 因长度不变改为 `rebuildShuffle({keepCurrent:true})`)。
- 后端 `PeerManager`：本机队列也接入调度器 (`scheduleLocalPreProbe`)，快照附带 `preProbe`。
- 后端 `/v1/stream/probe`：新增四态 `verdict`（`getCachedPlayability` 同源判据）；
  保留 `ok` 字段向后兼容。客户端**只应在 `unplayable` 时预跳**。
- 客户端 `ProbeCacheEntry` 增 `verdict`；`isProbeEntryUnplayable` 优先看 verdict；
  `probeSong` 钩子解析 verdict；新增四态护栏测试。

## 验证

- backend：`npm run build`(tsc) 通过；`npm test` **846/846** 全绿（新增 `localPreProbe.test.ts` 5 例）。
- frontend：`npm run build`(vue-tsc+vite) 通过；i18n 守卫通过。
- client：`flutter analyze` 无新增问题；`playback_mode_test.dart` **11/11**；
  5 个阻断型守卫（interaction_feedback / workflow_yaml / gpu_guard_scan /
  handoff_chain_scan / handoff_e2e_scan）全绿；l10n 守卫通过。

## 发版

- client commit `621d2bc` → 首轮 tag `v4.3.44`（l10n 守卫报红：调试日志含硬编码中文）
- client commit（本次）→ tag **`v4.3.45`**：修 l10n 守卫（调试日志改英文）
- 主仓库配套 tag **`v2.3.27`**（修 i18n 守卫同类问题）

---

# 本轮改动总览（2026-09-10 晚 · 联调版已启动）

## 一句话

修掉「客户端右边一列黄色英文」的根因，并把桌面歌词的「切换播放器」图标搬到音量右侧、
弹窗改到歌词窗自己身上；全部守卫 + 全量测试 + Windows 构建通过，联调客户端已重启。

---

## 1. 右侧一列黄色英文 —— 已定位并修复

### 根因

那不是文字，是 **Flutter debug 的 `ErrorWidget`**（红屏/黄字告警的可视形态）
被画进了一个极窄的槽位，所以看起来像"一列竖排英文"。

出问题的组件：`PlayerSwitcherPopover`（PC 端点迷你播放条「切换播放器」弹出的那个小窗）。

它经 `showPlayerSwitcherPopover` 用 `OverlayEntry` 插进**根 Overlay**，
而**根 Overlay 只给子级无界（loose）约束**。原实现用的是
「`Stack` + `Positioned.fill` 遮罩 + `Positioned` 弹窗」，内部还含 `Expanded` ——
在无界约束下布局失败 → framework 用 ErrorWidget 顶替 → 就是那一列黄字。

### 修法

改成**不依赖紧约束**的定尺布局：`MediaQuery.sizeOf` 自取尺寸 →
`SizedBox` 铺满（整窗即点击关闭热区）→ `Align(bottomRight)` + `Padding` 锚定弹窗本体。
行为与视觉完全不变，点击外部关闭照旧。

### 回归防线

新增 `test/features/player/player_switcher_popover_test.dart`（3 例）。

关键点：**必须把组件放进"裸 Overlay"（真实 OverlayEntry）才测得出这个 bug** ——
用 `MaterialApp` + `Scaffold` 会带上紧约束，bug 会被掩盖。

---

## 2. 桌面歌词「切换播放器」按你的要求重做

| 要求 | 落地 |
|---|---|
| 基站图标放在音量的右边 | `kOffSwitch=35` < `kOffVolume=87`（偏移越小越靠右），**紧挨音量** |
| 弹窗不在主窗口弹 | 旧 `switch_player` 事件**已删除**；改由原生在歌词窗**上方**展开自己的面板 |
| 弹窗里内容和 MINI 弹窗一样 | 新 `composeDesktopLyricSwitchList()` 组装：本机 / 停止投屏 / 各远端设备（带当前播放曲） |
| 鼠标移出去自动收回 | 沿用既有悬停路径（`UpdateHoverState` → `SetPopup(None)`） |
| 再次点击按钮自动收回 | 点击 = 在 `Switch` / `None` 之间 toggle |

新增协议：按钮首次展开发 `switch_player_open`（Dart 拉最新设备列表推回原生）、
行点击发 `switch_pick:<idx>`。

---

## 3. 途中挖出的一个真实构建事故（重要）

`flutter build windows --debug` 报：

```
desktop_lyric.cpp(307): error C2672: "std::max": 未找到匹配的重载函数
```

原因：`std::max(S(...), rc.right - S(...))` 里 `S()` 返回 `int`，
而 `RECT::left/right` 是 `LONG`（x64 = `long long`）—— **两个不同类型**，模板推导失败。

**最要命的是本地语法守卫查不出来**：`tool/check_native_syntax.sh` 用的 `cl /Zs`
只做语法检查、**不实例化模板**，所以它报"通过"，只有真正 build 才炸。
已改 `std::min<int>` / `std::max<int>` 显式指定类型，并把这条件写进流程约定：
**发版前本地必须真跑一次 `flutter build windows --debug`**。

---

## 4. 验证结果（全绿）

| 项目 | 结果 |
|---|---|
| `flutter analyze`（全仓） | **0 error** |
| `flutter test`（全量） | **630 / 630 通过，0 失败** |
| `flutter build windows --debug` | **√ Built MusicFlow.exe** |
| `desktop_lyric_guard.dart` | OK（且已做变异验证，能真拦住按钮位置/协议回退） |
| `check_interaction_feedback.dart` | OK |
| `gpu_guard_scan.dart` | OK |
| `check_native_syntax.sh` | OK |

## 5. 联调客户端已启动

进程 PID **16436**，窗口标题 `MusicFlowLyric`，启动时间 20:56:41。
可直接测：迷你条「切换播放器」小窗（确认右侧黄字消失）+ 桌面歌词基站图标位置与弹窗。

---

## 待你确认后再发版

改动涉及 `lib/`、`windows/runner/`（**功能代码**），按约定**需要发版**。
等你真机确认效果后打下一个 tag 即可。
