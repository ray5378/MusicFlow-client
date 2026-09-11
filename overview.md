# 本轮改动总览（2026-09-12 · 桌面歌词播放模式图标对齐 MINI + 实时刷新）

> v4.3.51（tag `v4.3.51`，仅客户端；后端无改动）

## 一句话

桌面歌词浮窗的「播放模式」按钮在顺序播放(order)下错画列表循环箭头（与 MINI 播放条不一致），
且点击切换后图标不实时更新。两处同根：本机链路的模式推导与监听都绕开了四态权威值
`PlayerState.playbackMode`。

## 根因

1. **图标画错**：`deriveDesktopLyricMode(shuffleEnabled, loopMode)` 二元组信息有损——
   order 与 all 底层同为 (LoopMode.off, shuffle=false)，全被压成 `'repeatAll'`；
   原生层 kModeOrder=3 → remix 有序列表图形的分支永远走不到（仅投屏链路的
   `castPlayModeToLyricMode` 正确透传 order）。
2. **点击不刷新**：歌词控制器监听的是 shuffleEnabled + loopMode 两个派生字段。
   `order ↔ all` 切换时两者皆不变（off/false → off/false），无监听触发 → `_push()`
   不跑 → 歌词窗停在旧图标。此前未暴露正是因为两态图标本来就一样；第 1 项修好后显形。

## 修复

- `deriveDesktopLyricMode` 改吃 `PlaybackMode` 四态权威值（与 MINI 播放条同源）：
  order→'order' / all→'repeatAll' / one→'repeatOne' / shuffle→'shuffle'。
- 歌词控制器两个派生字段监听合并为一个 `playbackMode` 监听（点哪里切模式都实时回推）。
- 原生层零改动（flutter_window.cpp 的 mode→int 解析与 remix 字形早已就绪）。

## 验证

| 项 | 结果 |
|---|---|
| `status_lyrics_provider_test` | 11 / 11（新增 order 四态用例 + 原生枚举契约锁 4 值） |
| `flutter test` 全量 | 669 / 669 |
| l10n 守卫 / handoff 契约扫描 | 双绿 |
| 真机（本机 debug） | 顺序播放图标与 MINI 一致；点击循环切换实时更新 |

---

# 本轮改动总览（2026-09-12 · 恢复卡死根修 + 启动新鲜度竞速：v4.3.49 之后依旧恢复旧队列）

> v4.3.50（tag `v4.3.50`，与主仓 v2.3.34 lockstep）

## 一句话

v4.3.49 真机复测仍恢复「我的好兄弟 (Live)」：真正根因不是写卡死，而是**恢复流程卡死** ——
`_restorePlaybackSession` 里 `await playSong(autoPlay:false)` 仍会对当前曲 setUrl 加载，
死链下该 await 永久不返回 → `_isRestoringPlaybackSession` 长期为 true → **之后所有会话落盘
在入口被跳过** → 本地文件整体陈旧 → 每次重启都恢复同一首旧歌。本轮：恢复不再等加载（fire-and-forget）+
恢复标志改 20s 租约 + 启动时与服务端队列做**新鲜度竞速**（新者胜，败方回填）。

## 根因（v4.3.49 修复为何无效）

- 证据：v4.3.49 在跑（exe 4.3.49.508），会话文件 mtime 仍停在 9-11 16:42；02:20 重启恢复旧文件并
  经 _watchLocalQueue 把 412 首旧队列传给服务端；02:35 用户重播歌单，服务端行已更新为 3215 首，
  **本地文件依旧一动不动** → 落盘被「恢复卡死」压制，与写路径无关。
- `playSong(autoPlay:false)` 不是「只设状态」：它会走完整加载链（setUrl）。恢复出的那首是死链 →
  just_audio 对打不开的流无限缓冲 → await 不返回 → 恢复流程挂在 `await playSong(...)`。
- v4.3.49 的落盘租约只防「写入卡死」，防不了「恢复卡死」。

## 实现（三件套）

1. **恢复不等加载**：`playSong` 增加 `initialPosition` 参数（state.position 直显 + 挂 pendingSeek，
   源就绪后由既有管线 seek）；恢复路径 `unawaited(playSong(...))`，加载/重试交给播放器看门狗。
2. **恢复租约**：`bool _isRestoringPlaybackSession` → `int? _restoreStartedAtMs`（20s 上限），
   超时强制放行落盘（纯时间戳，无 Timer，不碰 fakeAsync 不变量）。
3. **启动新鲜度竞速（需主仓 v2.3.34）**：启动恢复前拉 `GET /rest/api/v1/peers/:id/queue`（5s 预算），
   服务端快照新增 `updatedAt` 字段；服务端比本地会话文件新 → 用服务端队列恢复（queueItemToSong
   做 mime→suffix 还原）+ 本地文件回填；本地新/快照不可用 → 原行为（恢复本地 + 推服务端）。
   测试环境（FLUTTER_TEST）短路快照拉取，避免 Timer 撞 flutter_test 不变量。

## 效果

- 死链恢复不再卡死启动，落盘恢复流动，本地会话文件持续保鲜。
- 本地旧文件不再反杀服务端新队列（真机场景：本地 412 首旧会话 vs 服务端 3215 首歌单队列 →
  恢复歌单队列并把本地回填成同一份）。
- 跨端场景顺带覆盖：手机播完、电脑再开，电脑启动时自动采用服务端较新队列。

## 验证

| 项 | 结果 |
|---|---|
| `dart analyze`（改动文件） | 0 error（仅历史 info） |
| `flutter test`（全量） | 663 / 663 通过 + 新增 5 用例 |
| `peer_queue_item_test.dart`（新增） | 5 / 5（mime↔suffix 往返、兜底） |
| 主仓 `tsc --noEmit` | 0 error |
| 主仓 `vitest localPreProbe` | 6 / 6（含新增 updatedAt 断言） |

---

# 本轮改动总览（2026-09-12 凌晨 · 播放会话落盘停摆修复：不再每次都恢复成同一首旧歌）

> v4.3.49（tag `v4.3.49`）

## 一句话

Windows 客户端「每次打开都是旧的播放队列（我的好兄弟）」：会话文件
`playback_session_v1.json` 停在 9-11 16:42 再没更新过 —— 落盘被一个**永久卡死的布尔标志位**
静默跳过。现在改成时间戳租约，卡死 15s 后自动放行；恢复后立即把队列镜像给服务端。

## 用户需求

1. 本机播放队列要能留存，关闭再打开还在。
2. 启动后回传服务端，告诉服务端「这是本次需要恢复的播放队列」。
3. 恢复时**以歌单为主**（保留歌单上下文）。

## 根因（改动前）

证据：`%APPDATA%\MusicFlow\MusicFlow\storage_v2\` 下 `playback_session_v1.json` mtime 停在
9-11 16:42，而同目录 `playlists.json`（01:28）、`player_volume.json`（01:36）都正常 →
不是磁盘/权限问题，是这个 key 的写入**根本没被触发**。会话内容 `queueLen=412 currentIndex=336`
正是「我的好兄弟 (Live) / 高进、小沈阳」。

`_persistPlaybackSession()` 靠 `finally` 复位 `bool _isPersistingPlaybackSession`。Windows 上
`tmp.rename()` 覆盖已存在文件时若被杀软/索引服务占用会**阻塞等待而非抛错** → await 永不返回 →
`finally` 不执行 → 标志位**永久 true** → 此后所有会话落盘被静默跳过。`JsonFileStore._doWrite`
还吞掉异常（设计如此），所以连日志都没有。

推理闭合：①恢复是成功的（显示的就是会话第 336 首）→ `_isRestoringPlaybackSession` 已复位；
②退出时 `persistPlaybackStateNow()` 先 `await _persistPlaybackSession()` 再写 volume，而 volume
01:36 更新了 → 说明它是**快速 return 命中守卫**，不是挂起。

## 实现

- `bool _isPersistingPlaybackSession` → `int? _persistingSinceMs` **租约**（15s）：过期即强制
  放行并 `Logger.warn` 留证。纯时间戳比较，**不创建任何 Timer**。
  - 不用 `Future.timeout()`：它在 flutter_test 的 fakeAsync 下是 FakeTimer，写入走真实 IO
    不会在 fake 时钟内完成 → Timer 永远 pending → 撞上框架断言
    「A Timer is still pending even after the widget tree was disposed」（实测 widget_test 因此红）。
- 音量写入从会话 try 里**独立**出来：原实现会话一失败音量就不落盘（退出后音量回 100%）。
- 新增 `syncLocalQueueNow()`：会话恢复后立即把队列镜像给服务端（恢复路径不走常规播放入口，
  服务端可能还留着上次进程的旧队列）。**未注册时不主动触发注册** —— `_registerSelf()` 会拉起
  心跳 Timer，会把 widget_test 的 Timer 不变量再次打挂。
- 歌单上下文 `queueOrigin`（如 `playlist:pl-random-songs`）**本来就落盘且恢复时回填**，无需新增。

## 验证

- `flutter analyze lib/` 0 error；**663 测试全绿**（含 widget_test，回归过一次已修）；
  5 守卫（interaction / workflow yaml / gpu / handoff chain / handoff e2e）+ l10n 门禁通过。

## 发版

- tag `v4.3.49`。配套服务端 **v2.3.33**（主仓 e30d444，播放优选对齐：探测与实际出流一致，
  消除 8.3% 白跳 + web→local 优选补上源有效性探测）。
- 真机待验：升级后播几首 → 退出 → 重开，队列应停在退出前那首，而不是「我的好兄弟」。

---

# 上一轮（2026-09-12 凌晨 · 预探测时效性修复：随机模式死链不再落地）

> v4.3.48（tag `v4.3.48`，commit 5ee0b4c）

## 一句话

修掉「随机模式遇到死链不会提前跳过」：探测结论 TTL 只有 45s，而单曲通常播 3~5 分钟，
切歌时判定早已过期 → 沿服务端洗牌序列的跳过一次都没生效，只能落地报错后靠兜底跳。
现在单曲临近结束（剩余 ≤60s）会补探一次窗口，且过期判定不再挡住重探。

## 用户需求

1. 随机（shuffle）播放遇到「无可用音源」的歌要自动跳过，不要落地卡一下才跳。
2. 服务端侧要先确认没问题（真机取证）。
3. 顺带：明明同曲多源组里有可播行却被判死（组级换源救援，服务端）。
4. 顺带：Web 前端本机随机也改由服务端洗牌序列驱动。

## 根因（改动前）

真机取证（服务端 v2.3.29 + 客户端 v4.3.47，94 首新歌单）：

- 服务端**完全正常**：序列跟随正确（67[序列第 0 位] → 87[第 1 位]）、预探测在跑
  （`preProbe ready=2 scanned=3`）、四态判定与独立复探一致、死链率 4/25≈16%。
- 客户端三个缺陷叠加：
  1. `_probeUpcoming()` **只在切歌瞬间调一次**，探接下来 3 首；
  2. `probeCacheTtlMs = 45s` < 单曲时长 → 切歌时判定已过期，`_isKnownUnplayable` 恒 false；
  3. 候选收集用 `!_probeCache.containsKey(id)` —— **过期条目也算「已探」**，挡住重探，
     而过期条目的清理只在读取时发生 → 死循环。

## 实现（client 侧，B+C 最小彻底修）

- `_maybeProbeNearEnd()`：由进度流驱动，剩余 ≤60s 时补探一次（同一首 60s 节流）。
- `_probeNeedsRefresh()`：未缓存 **或已过期** 都要重探（替换原 `containsKey` 判据）。
- part/mixin 跨文件需在 `PlayerNotifier` 基类补抽象声明（老坑，已补 3 个）。

## 验证

- `flutter analyze lib/providers/player/` 0 error；**663 测试全绿**；
  5 守卫（interaction / workflow yaml / gpu / handoff chain / handoff e2e）+ l10n 门禁通过。

## 发版

- commit `5ee0b4c` / tag `v4.3.48` / CI（Build Client + Test Suite + UI Guard + server-contract
  等 10 个 workflow）全 success；Release author/uploader 均 github-actions[bot]。
- 产物：MusicFlow-v4348-android.apk 46.2MB + MusicFlow-v4348-windows-setup.exe 31.8MB。
- 配套服务端 **v2.3.31**（主仓 a57e679，同日发；v2.3.30 已被 v2.3.31 取代 —— 组级救援的
  缓存写反了，见主仓提交说明）。
- 真机待验：升级后在随机模式下放新歌单，看死链是否被**提前跳过**（不再落地报错）。

---

# 上一轮改动总览（2026-09-11 深夜 · 播放端临时 ID 隔离 + 本机队列上报）

> v4.3.46（tag `v4.3.46`，commit a791cb0）

## 一句话

对齐服务端 v2.3.28 的「播放端临时 ID 隔离」：同账号多端（多标签页 / 多客户端）
各自持有独立服务端队列，互不覆盖；本机播放从此把队列/游标/播放模式上报到服务端，
服务端预探测的四态判定第一次能驱动本机链路的向前扫描。

## 用户需求

1. 不同播放端要能区分 —— 播放时用临时 ID 区分，临时 ID 只在服务端存在（不进任何界面/响应）。
2. 服务端播放队列「6 小时未变动 + 该端离线 6 小时」自动清理，重启也要清扫。
3. 客户端重连服务器时自动注册。
4. Web 多标签页 / 客户端本机都只看到自身的播放器条目。

## 根因（改动前）

- 服务端 `registerLocal` 硬编码 `peerId = local:<userId>`，一账号一坑，后连端覆盖先连端。
- Flutter 本机播放完全不上报队列（只有投屏分支上报），服务端 `local:cdf…` 恒 items=0。
- 「心跳 10 分钟超时清队」对不发心跳的本机链路 = 必然误清（实测队列被清空）。

## 实现（client 侧）

- `LocalStorage.getClientId()`：`app-<6hex>` 安装级持久 ID；**best-effort** ——
  取不到就跳过该请求头，绝不阻断请求（SharedPreferences 在单测环境无 binding 的教训）。
- Dio 拦截器全量请求带 `x-mf-client-id`；服务端据此隔离，响应永不回显该 ID。
- `registerAndHeartbeat` 拆出 `_registerSelf`；心跳发现未注册成功即**自动补注册**
  （顺带修复了启动竞态 401 后永不重试的老问题）。
- 新增 `_watchLocalQueue` / `_syncLocalQueue`：队列变 → `queue/play` + `play-mode`；
  游标变 → `queue/index`；投屏中不上报；空队列不主动擦（留给 6h 回收）。

## 验证

- `flutter analyze` 无 error；**654 测试全绿**；5 守卫 + l10n 门禁通过。
- 服务端隔离实例冒烟 12 项全过：双端队列互不覆盖、响应不含临时 ID、
  各端只见自己那条、7h 陈旧队列被回收、心跳在线端被保留。

## 发版

- commit `a791cb0` / tag `v4.3.46` / CI（Build Client + Test Suite + UI Guard）全 success。
- 产物：android.apk 46.2MB + windows-setup.exe 31.8MB，author/uploader 均 github-actions[bot]。
- 配套服务端 v2.3.28（主仓 59e8c8c，同日发）。

---

# 上一轮改动总览（2026-09-11 夜 · 三条链路共用服务端预探测）

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
