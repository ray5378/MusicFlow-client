# MusicFlow Client 开发任务清单（优化/架构）

基于对项目整体审计（状态/缓存/网络/UI/跨平台）产出的改进方案。按优先级推进，每项完成后更新状态。

> 审计结论（快览）：项目历经多轮迭代已高度打磨，绝大多数常见反模式（播放状态序列化卡顿、缓存兜底语义、预缓存错位、DLNA 并发、平台字体/路径）均被主动规避。剩余问题以**结构性 / 长期维护性**为主，加个别边缘隐患。未见硬编码凭据泄露。

---

## T1【已完成】播放器核心拆分 + 随机/预缓存/序列化/历史单测 — 优先级 高

**背景**：`lib/providers/player_provider.dart`（3633 行单体）同时承担音频状态机、队列/随机切换、会话持久化、预缓存下一首、可用性探测、DLNA 编排。职责过载导致该高管改动区域几乎无单测、无 CI 保护；改一处牵动全局，回归面大。

**目标**：把**纯 Dart、不依赖 Flutter 插件的核心逻辑**抽成独立类并补单测，锁定「随机预缓存下一首 == 实际切歌 next 下一首」与队列序列化等高风险一致性语义；不触碰 audio_service / DLNA / RLNA 桥接（保行为不变）。

**完成项**（✅）：
1. `lib/core/player/shuffle_queue_indexer.dart`：`ShuffleQueueIndexer` 统一「随机一轮不重复 / 预缓存一致性 / 强制下一首 / 顺序回绕」；`player` 委托之（删私有 `_shuffleRoundPlayedIds`/`_precomputedUpcomingIndex`，保留 `_random` 供 shuffleRandomStart）。顺带修正 `allowRoundReset=false` 真正不清标记。
2. `lib/core/player/playback_payload.dart`：`PlaybackPayloadEncoder`（队列序列化缓存：id 序列未变即复用，避免每 tick 全量 toJson 整队）+ 顶层 `normalizeSeekPosition`；`player` 的 `_serializedQueuePayload`/`_buildPlaybackSessionPayload` 委托之（删 `_cachedQueueIds`/`_cachedQueuePayload`）。
3. `lib/providers/player/shuffle_history.dart`：`ShuffleHistory` 收拢 back/forward 导航栈的 push/去重/失效解析/回退；`player` 的 next/previous/_afterPlay 委托之（删散落的栈操作 helper）。
4. 新增单测并纳入 `.github/workflows/offline-cache-guard.yml` 门禁：`shuffle_queue_indexer_test.dart`(13)、`playback_payload_test.dart`(11)、`shuffle_history_test.dart`(8)。

**完成标准（已达成）**：上述用例全绿；`flutter analyze` 无 error；播放器行为（含 DLNA/投屏）待人工回归确认。

---

## T2【已完成】离线缓存 daemon 快速切歌丢缓存 — 优先级 中

**位置**：`lib/providers/offline_cache_daemon.dart`
**问题**：`onSongStartedOnline` 的 `if (_busy) return;` 在连续快速切歌时直接丢弃新触发，最近播放的少数歌可能未入缓存（历史上「歌曲没增加」的残余口子）。
**修复**：改为**单槽位待缓存**——串行执行期间收到新请求只保留**最新**一份 `_PendingCacheJob`，当前任务结束（`_runJob` 后同步取走）立即续跑最新任务；仍串行、不抢占主线程。
**注**：该类强依赖 Riverpod `Ref` + Dio + path_provider，单测成本高，未加自动化用例；核心逻辑简短清晰，靠 analyze + 运行时回归保障。

---

## T3【已完成】DLNA 区域静默 catch 日志化 — 优先级 低-中

**位置**：`ssdp_discovery.dart`、`cast_peer_provider.dart`、`dlna_manager.dart` 等大量 `catch (_) {}`
**问题**：网络抖动的合理容错，但可能掩盖真实失败，投屏/发现问题难排查。
**方案**：统一改为告警级日志并带错误对象，保持不中断行为。

**完成项**（✅）：DLNA 链路所有静默 catch 统一升级为 `Logger.debugWithTag` 并带错误对象，保持不中断容错语义：
1. `core/dlna/soap_control.dart`：Stop / SetNextAVTransportURI / GetTransportInfo / GetPositionInfo / GetVolume / GetMute 等。
2. `core/dlna/ssdp_discovery.dart`：broadcast/joinMulticast/定向广播/全局广播/单播扫描发送、接口与 IP 探测、监听 joinMulticast。
3. `core/dlna/dlna_manager.dart`：pause / resume / seek / setVolume / toggleMute / 轮询读音量静音。
4. `providers/dlna_provider.dart`：Wi-Fi 多播锁 / WakeLock 获取释放、后台投屏权限与电池优化豁免。
5. `providers/cast_peer_provider.dart`：stopCasting、sleep-timer 删除/查询、_pushQueueAndPlay、play-mode 同步、removeQueueItem、clearCastQueue、loadPeers、心跳、pollOnce、_post。
（纯控制流/防御性跳过如 `int.parse` 容错、`_toAbsolute` 解析兜底保留不日志化，避免噪音。）

**完成标准（已达成）**：`flutter analyze` 无 error，行为不变（仅补日志）。

---

## T4【已完成】Release 附带 APK / Windows 预编译产物 — 优先级 中

**背景**：纯 tag 驱动 CI 目前只发源码（源码 Release）。对用户真正有价值的是 APK 与 Windows 安装包。
**方案**：在 `build-android.yml` / 新增 Windows 打包 job 里构建 `app-release.apk` 与 Windows zip，随 tag Release 上传（用 `--build-name/--build-number`）。

**完成项**（✅，审计时已实现，无需改动）：
- `build-android.yml` 由版本 tag (v*) 触发：`resolve-version` 解析版本并注入、`build-android` 产 `MusicFlow-<tag>-android.apk`（arm64-only + 签名）、`build-windows` 产 `-windows-setup.exe`（Inno Setup 安装版，单文件；绿色版 zip 已于 2026-09-10 取消发布）、`publish-versioned` 下载双端产物随 Release 发布。
- Release 附带的正是预编译 APK / Windows 安装包，非源码；`--build-name/--build-number` 保证应用内「检查更新」版本与本次 tag 一致。

---

## T5【已完成】providers/ 单目录 32 个 provider 分域整理 — 优先级 低

**方案**：按域（player / library / network / offline / …）分子目录整理，纯结构调整，不改行为，提升可维护性。

**完成项**（✅）：`lib/providers/` 下单目录的 provider 按域拆到 `auth / api / library / player / offline / cast / media / ui` 8 个子目录：
1. 一键脚本 `tool/refactor_providers.dart`（一次性）：移动文件（git 识别为 rename）+ 精确重写项目内全部指向被移动文件的 import 为 `package:musicflow_client/providers/<域>/<basename>.dart` 规范路径，含确定性纠错 pass（根治历史 pass 产生的 缺 `providers/` 前缀 / `player/player/` 双重前缀）。
2. 全部 import 统一转 package 风格，根除「文件移入更深子目录后相对路径深度错配」。

**完成标准（已达成）**：`flutter analyze` 无 error（仅存量风格 warning/info）；离线缓存专项测试 8/8、player 核心单测 31/31 全绿，行为不变。

---

## 已验证的既有优化（不作为待办，仅记录，避免重复改）

- 播放会话持久化：队列 id 变动才重建 payload + 5s 节流 + 关闭仍落盘（`_serializedQueuePayload`）
- 进度 tick 节流（≥250ms 前进才更新 state.position）
- 迷你播放器按字段 `select` 监听避免整条高地重建
- min_player / cast / DLNA 串行化与看门狗续播
- 远端优先 + 缓存兜底（写缓存失败不反噬、双败才提示）
- 随机预缓存复用真实下一首索引（已在 T1 固化 + 单测）
- joinServerUrl 防双斜杠、封面 salt/token 会话内复用