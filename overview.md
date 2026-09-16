# 本轮改动总览（2026-09-13 · 以 GitHub 主线最新源码发 v5.0.0 大版本）

## v5.0.5（tag `v5.0.5` · 播放器圆形快捷区 + 拖拽流转队列）

> 配套服务端 **v3.0.22+**（新增 `POST /v1/peers/:peerId/queue/transfer-from`）。

### 用户需求（核心理念：音乐可以随时在不同播放器之间流转）
- 连接成功后，mini 播放器**上方**自动出现一排**圆形**播放端：圆内是该端当前在播的封面，
  下方短名过长可截断；没在播时显示设备图标（手机 / 显示器 / 音箱 / 群组）。
- 也可**长按 mini 播放器的封面**（触屏与鼠标同一套手势）唤出；松手/拖完立即收起，
  闲置数秒也自动收起。
- **按住某个圆拖到另一个圆**即完成一次流转 —— 拖动方向就是「源 → 目标」。
- **本机不额外占一个圆**：它就是 mini 播放器那张封面本身，既是节点又是长按开关。
- 收录范围：全部**在线**端（DLNA / AirPlay / Sendspin / 群组 / 同账号其它客户端实例）。
- 本质：把「流转播放」里既有的推 / 拉播放列表换成拖拽手势，并放开到**任意两端**。

### 实现
- **服务端（主仓 v3.0.22）**：新增流转端点，服务端内部从源端取队列再按既有分派写给目标端，
  **请求体不收 items**（队列实体本就在服务端）—— 客户端零上传，几千首也是一次请求。
- `peer.dart`：`PeerNowPlaying` 补 `coverArt`。
- `cast_peer_provider.dart`：`fetchPeerNowPlaying` 补封面（设备侧优先、队列当前项兜底，
  与标题**各自独立**回落，唯一门控是「在播」）；新增 `transferQueue(from, to)` 三条路由：
  本机→远端 `pushLocalToPeer` / 远端→本机 `pullPeerToLocal` /
  远端→远端 新端点（成功后给源端发 stop，与 `pullPeerToLocal` 的搬移语义一致）。
- 新增 `player_quick_ring.dart`：快捷区组件 + `quickRingPeersProvider`（autoDispose，
  收起即释放、不常驻轮询）+ 拖拽源/落点（`Draggable` + `DragTarget`）+
  落点高亮 + 闲置自动收起。
- `mini_player.dart`：封面挂长按唤出（收起态）并兼作本机节点（展开态：拖出=推、拖入=拉）；
  `MiniPlayerView` 改为 `ConsumerStatefulWidget`；Stack 加 `clipBehavior: Clip.none`
  以在 mini 条**上方**浮出快捷区。

### CI 守卫
- `test/providers/cast_transfer_queue_test.dart`（4 用例）接入 blocking 门禁，
  锁三条路由 + 「同端短路」「不得上传 items」。
- 变异验证 2/2 捕获（远端→远端改回直接失败 / 去掉同端短路）。

## v5.0.4（tag `v5.0.4` · 命令影子：音量 / 播放态被滞后上报顶回）

> 与 HA 卡片 **v2.4.2**、Web 前端 **v3.0.21** 是同一根因、同一套修法。

### 用户需求
- 遥控远端客户端时拖动音量会跳回：20 → 50 → 30，结果停在 50。
- 并排查「同一根因还命中哪些字段」。

### 根因（一个模式，不止一个字段）
客户端实例的**音量 / 静音 / 播放态**与 `position` 一样，都是**周期性上报**的采样
（实测约 4s 一次）。本端下发命令后，在下一个上报到达前，轮询读到的仍是**旧值**，
于是把用户刚设的值顶回去：

- **音量**：拖到 50 后回传的仍是上一拍的 20/50，再拖到 30 时被顶回 50。
- **播放态**：点了暂停后，陈旧上报的 `state` 仍是 `PLAYING` 且 `position` 还在前进，
  会触发 `_tick` 里「position 前进 → 判在播」的自愈，把 `PAUSED` **强制改回 `PLAYING`**
  （表现为「点了暂停没反应，自己又播起来」）。

### 修法：命令影子（统一判据 `_isStaleSample`）
- 采样时刻（`reportedAt`）早于命令下发时刻、且仍在 **8s 保护窗口**内 → 该字段沿用本地值。
- `_applyVolumeShadow`：保护 `volume` / `muted`（`setVolume` / `setMuted` 打点）。
- `_applyTransportShadow`：保护 `state` / `active`（`toggle` / `pause` 打点），
  并在窗口内**停用 `advancing` 自愈**。
- 上报追上命令后自动恢复采纳服务端值；窗口超时也恢复（不会永久掩盖真实状态）。
- **边界**：判据依赖 `reportedAt`，而该字段只有客户端实例的 `/status` 才有 →
  DLNA / AirPlay / Sendspin / 群组恒 false，行为完全不变。

### 排查结论（同一根因还命中什么）
- **会中招**：`position`、`volume`、`muted`、`state`（播放/暂停）—— 都是客户端本地状态，
  只能靠周期上报得知。
- **不会中招**：队列 `items` / `currentIndex` / `playMode` —— 这些是**服务端权威**，
  命令直达服务端后立即生效，轮询读到的就是新值。

### CI 守卫
- `test/providers/cast_remote_progress_guard_test.dart` 扩充到 **8 用例**
  （新增音量 3 例 + 播放态 1 例）。
- 变异验证 4/4 捕获：回退外推 / 去掉 seek 打点 / 去掉音量影子 / 去掉播放态影子。

## v5.0.3（tag `v5.0.3` · 遥控远端客户端时进度/歌词回退）

> 配套服务端 v3.0.19+。与 HA 卡片 **v2.4.1** 是同一个 bug、同一套修法。

### 用户需求
- 客户端遥控**另一台客户端**（安卓 / Windows）时，进度条与歌词「一直后退约 2 秒」。

### 根因
- 客户端实例的 `position` 是**周期性上报的采样**（实测约 4s 一次），采样时刻由
  `GET /peers/:id/status` 的 `reportedAt` 给出。本端 2s 轮询，却在 `_tick` 里
  `smoothPositionSeconds: next.positionSeconds` 直接把采样值当「此刻」写入 ——
  每两轮就把本地已在推进的时钟（250/500ms tick）**拽回**旧值。
  回退幅度 = 一个上报周期（约 2~4s），不是固定 2 秒。
- 顺带同源问题：`seek()` 后立刻 `pollOnce()`，而远端要等下一个上报周期才回新位置，
  期间读到的是 seek 之前的采样 → 刚拖好的进度条被拽回（再过两秒又跳回去）。

### 修法
- `PeerStatus` 增补 `reportedAtMs`（解析 `reportedAt`）。
  注意：**不能用 `updatedAt` 代替** —— 对 local 而言那是「队列行写入时刻」，
  2026-09-16 实测与真实采样时刻相差 **53 秒**。
- 新增 `_projectPolledPosition()`：`采样值 + (现在 − reportedAt)` 外推到此刻；
  暂停不外推；`reportedAt` 缺失 / 年龄 ≤0 / >30s（时钟异常）→ 原样。
- 新增 `_seekIssuedAtMs`：6s 窗口内丢弃「采样早于本次 seek」的上报。
- **边界**：只有客户端实例的 status 带 `reportedAt`（设备型 peer 走实时查询、无此字段）
  → DLNA / AirPlay / Sendspin / 群组行为完全不变。

### CI 守卫
- 新增 `test/providers/cast_remote_progress_guard_test.dart`（4 用例），接入
  `playback-chain-guard.yml`（blocking）。两条均做变异验证（回退外推 / 去掉 seek 打点 → 转红）。
- 测试踩坑：peerId 经 `Uri.encodeComponent` 后 `:` 变 `%3A`，按精确路径 stub 会对不上，
  改用「按 `/status`、`/queue` 后缀分流」的通吃 stub。

## v5.0.2（tag `v5.0.2` · 客户端互控链路修复 + CI 守卫）

> 配套服务端 **v3.0.19+**（`/rest/scrobble` 起同时接受 GET 与 POST）。

### 用户需求
- 「流转播放」推流到**另一台客户端**（安卓 / Windows）不能用，接回本机却正常。
- 「流转播放」里别的客户端那一行的**播放状态接不上**（恒显示「未在播放」）。
- 播放记录上报失败（日志 `Failed to scrobble (404)`，播放历史里查不到记录）。

### 根因
- `pushLocalToPeer` 开头 `if (peer.isLocal) return false;` 一刀切 —— 本意是排除「推给自己」，
  实际把**另一台客户端**也挡在门外。推送链路（主通道 `/v1/play` + 兜底 `/queue/play`）
  与 DLNA 完全共用，服务端对 local 目标已实现，无需特判。改为 `peer.isLocal && peer.self`
  （与同文件 `switchTo` 同一判据）。
- `fetchPeerNowPlaying` 只读 `/queue` 的 `currentMedia`，而该字段服务端**只对
  dlna / airplay / sendspin 填充**，`local` 恒 undefined。补队列当前项
  `items[currentIndex]` 兜底（与 Web 前端 `peerPlayingTitle` 同源），`currentMedia` 仍优先。
- `scrobble` 用 POST，而 `/rest/scrobble` 是 Subsonic 规范的 **GET** 端点 → 404。改 GET
  （服务端 v3.0.19 起同时接受 POST，兼容已安装的旧版客户端）。

### CI 守卫（防回归）
- 新增 `test/contract/client_link_guard_test.dart`（7 用例），接入
  `.github/workflows/playback-chain-guard.yml`（**blocking**，push main / PR 即跑）。
- 三条契约的共同点是**静默失效**（UI 不报错、功能悄悄没了），本地手测难复现，故钉死。
- 三条均做**变异验证**：把修复分别改回 bug 形态，对应用例确实失败 —— 不是空转断言。

### 验证
- `flutter test test/contract/client_link_guard_test.dart` **7/7 绿**；变异验证 3/3 捕获。
- 真机实测（安卓模拟器 + Windows debug）：客户端间推流、now-playing、状态显示均正常。

## v5.0.1（tag `v5.0.1`，commit `1ea4ae3` · 播放器统一化收尾：清理 Web 播放器标签）

> 配套服务端 **v3.0.18**。

### 用户需求
- 客户端同步清理「Web 播放器」概念：本机实例不再单列为 Web 播放器，统一标「客户端」。
- 与服务端 v3.0.18 一起发正式版本号。

### 实现
- `peer.dart`：去掉 web 分支，非 self 本机实例一律标「客户端」；删除 `peer_web` i18n 键并重新生成 l10n。
- `random_songs_push_provider.dart`：WS 重连仅在「有活跃库」时排程，避免无凭据空转定时器（修复 `main_scaffold_navigation_test` 遗留 pending timer）。
- `cast_peer_provider.dart`：`switchTo` 仅对 `peer.isLocal && peer.self` 回本机（清空 activePeer）。
- 新增 `peer_remote_control_provider.dart`（本端被 Web/HA 遥控）；`test_player_notifier.dart` 桩对齐 `clearQueue({bool keepCurrent})`。

### 验证
- 5 个 dart 守卫 + `node tool/check-l10n.mjs --gate-cjk` 全绿。
- `flutter test` **689 全绿**（修复两例：switchTo 本机语义、WS 重连定时器泄漏）。
- CI Build Client / Test Suite / UI Guard：进行中（tag 触发，产物 android.apk + windows-setup.exe）。

### 发版
- `git tag v5.0.1` → `git push origin main` + `git push origin v5.0.1`。

> v5.0.0（tag `v5.0.0`，纯发版：采用 origin/main `ffc7c4b`；本地未提交改动已丢弃）

## 一句话

用户要求用 GitHub 主线（比本地新 1 个提交）的最新源码打 **v5.0.0** 发版。本地有未提交 WIP
（playback-chain-guard.yml 修改 + 2 个未跟踪测试文件 + .trae/），按用户决定**全部丢弃**，
以主线 `ffc7c4b`（`feat(renderer): 切换器接入 sendspin peer(遥控模式)`）为权威源码。

## 用户需求

1. 用主线最新源码发版（本地落后，主线更新）。
2. 版本号 **v5.0.0**（从 v4.3.53 大版本跃迁，用户指定）。
3. 本地未提交改动丢弃，不带入发版。

## 发版流程（无功能代码改动，纯取主线 + tag）

- 丢弃本地：`git checkout -- .github/workflows/playback-chain-guard.yml` + `git clean -fd`
  （清掉未跟踪测试文件与 .trae/，及 android/.kotlin 构建缓存）。
- 同步主线：`git merge --ff-only origin/main` → HEAD = `ffc7c4b`，工作树干净。
- tag 可用性：REST API 双重校验 `refs/tags/v5.0.0` 与 `releases/tags/v5.0.0` 均 404（无 hijack）。
- 发版前守卫：5 个 dart 守卫（interaction_feedback / workflow_yaml / gpu_guard_scan /
  handoff_chain_scan / handoff_e2e_scan）+ `node tool/check-l10n.mjs --gate-cjk` **全绿**
  （exit=0；未本地跑全量 `flutter test`，由 CI Test Suite 覆盖）。
- 打 tag：`git tag -a v5.0.0 -m "..."`（annotated，指向 ffc7c4b）；`git push origin v5.0.0`。
- pubspec 维持 `0.0.0+0` 假版本号，CI 用 `--build-name` 从 tag 覆盖（纯 tag 触发，未改 pubspec）。

## 验证

| 项 | 结果 |
|---|---|
| CI Build Client | **success** |
| CI Test Suite | **success** |
| CI UI Guard | **success** |
| 其余观察型守卫（GPU / Desktop Lyric / Offline Cache / Cover Display / Transcode / Playback Chain Guard） | 全部 success |
| Release draft / prerelease | False / False |
| Release author / 全部 uploader | 均 `github-actions[bot]` |

## 发版产物

- tag `v5.0.0` / commit `ffc7c4b` / CI 全 success。
- `MusicFlow-v500-android.apk` **46.24 MB**（uploader github-actions[bot]）
- `MusicFlow-v500-windows-setup.exe` **31.80 MB**（uploader github-actions[bot]）
- 说明：`windows.zip` 自 v4.3.42 起已取消，本版**仅两产物**，缺 zip 属预期。

---

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

修掉「客户端右边一列黄色英文」的根因，并把桌面歌词的「流转播放」图标搬到音量右侧、
弹窗改到歌词窗自己身上；全部守卫 + 全量测试 + Windows 构建通过，联调客户端已重启。

---

## 1. 右侧一列黄色英文 —— 已定位并修复

### 根因

那不是文字，是 **Flutter debug 的 `ErrorWidget`**（红屏/黄字告警的可视形态）
被画进了一个极窄的槽位，所以看起来像"一列竖排英文"。

出问题的组件：`PlayerSwitcherPopover`（PC 端点迷你播放条「流转播放」弹出的那个小窗）。

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

## 2. 桌面歌词「流转播放」按你的要求重做

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
可直接测：迷你条「流转播放」小窗（确认右侧黄字消失）+ 桌面歌词基站图标位置与弹窗。

---

## 待你确认后再发版

改动涉及 `lib/`、`windows/runner/`（**功能代码**），按约定**需要发版**。
等你真机确认效果后打下一个 tag 即可。
