# 离线缓存链路 CI 防护

## Context（背景）

用户希望为**离线缓存整条链路**加一道 GitHub CI 门禁，防止后续改动把它搞坏。当前仓库虽有 CI（`test-suite.yml` 是非阻塞观察流水线、另有 build-android / ui-guard 等），但**离线缓存没有任何专项单测，也没有针对它的门禁**。本次新增一个有真实测试做抓手的**阻塞式**门禁，专门守护离线缓存链路。

覆盖重点（历次会话修过的真 bug，需防回归）：
- 封面缓存 counting 恒为 0 + 新歌缓存被连带阻塞（`_CacheEntry` owners 曾在 const [] 上 addAll 抛 `UnsupportedError`）。
- 首页「随机歌曲」点播放必须直接用主页当前展示批次，不重新 `refresh`（_playRound）。

## 改动方案

### 1. 给 OfflineCacheManager 加最小侵入的根目录注入
文件：`lib/core/offline/offline_cache_manager.dart`

- 构造改为 `OfflineCacheManager({Directory? rootForTest})`，保存 `final Directory? _rootForTest;`（不加 `@visibleForTesting`，避免新增 meta 依赖；仅作可选地注入用）。
- `init()` 第 172 行改为：`final support = _rootForTest ?? await getApplicationSupportDirectory();`，其余不变。
- 生产路径不带参时行为完全不变；测试只需传入一个空临时目录，`dart:io Directory` 在测试宿主原生可用，无需 method channel。

### 2. 新增离线缓存单元测试
文件：`test/core/offline/offline_cache_manager_test.dart`（新建）

- 全部用普通 `test()`（真实异步），`setUp` 用 `Directory.systemTemp.createTemp`，`tearDown` 递归删除。
- 处理 1 秒 debounce：辅助函数 `settleIndexFlush()` = `Future.delayed(Duration(milliseconds: 1300))`，每个变更缓存的用例在最后写入后、断言前调用一次，保证 `index.json` 落盘、定时器不残留。
- 用例覆盖：
  1. `putSong`/`hasSong`/`cachedSongs`(meta 回填、size)/`countByKind[song]`/`songFile.exists`
  2. `putCover(owners:['s1','s2'])` → `hasCover` true 且 `countByKind[cover] != 0`（防 owners 不可变列表 bug 回归）
  3. `putLyrics`/`lyricsCached`/`lyrics` 内容
  4. `putPlaylistCover`/`hasPlaylistCover`
  5. `evictSong`：删歌+歌词+仅归属该歌的封面；**共享封面保留**
  6. `setMaxBytes` 超容量 LRU 轮转
  7. 持久化：同根目录重新 `new + init` 后条目仍在
  8. `cachedSongs` 按 lastAccess 新→旧排序

### 3. 新增「点播放随机歌曲直接用当前展示批次」守卫测试
文件：`test/features/discover/discover_page_test.dart`（复用现有 `_RecordingPlayerNotifier`、`_pumpDiscover`）

- 注入 `songs`(3 首)，override `randomSongsProvider`，用计数器 `randomLoads` 记录拉取次数。
- 点击「播放随机歌曲」后断言：
  - `player.queues.last` 的 id 序列 == 注入 `songs`（播的就是看到的）；
  - `randomLoads` **仍为 1**（即未 `refresh` 换批；比只断言队列更精确）。

### 4. 新增阻塞式门禁 workflow
文件：`.github/workflows/offline-cache-guard.yml`（新建）

- `on`: push main + pull_request main + workflow_dispatch；`permissions: contents: read`
- job `offline-cache-guard`，ubuntu-latest，timeout 20min
- steps：checkout@v4 → `subosito/flutter-action@v2`(3.38.10, stable, cache:true，与 test-suite 一致) → `flutter pub get` → `flutter analyze --no-fatal-infos --no-fatal-warnings` → `flutter test test/core/offline test/features/discover/discover_page_test.dart`
- **不加 continue-on-error**（真门禁），命名沿用仓库 guard 系列风格。

### 不纳入本次范围
Player 随机预缓存复用（`PlayerNotifier._precomputedUpcomingIndex`）因依赖深（mock Dio/just_audio/audio_service），成本明显高于收益且偏离离线缓存防护目标，本次不纳入，可后续单独立项。

## 验证方式（本地）

```powershell
flutter pub get
flutter test test/core/offline                 # 新增离线缓存单测，应全绿
flutter test test/features/discover/discover_page_test.dart   # 守卫用例通过且原有用例不回归
flutter analyze --no-fatal-infos --no-fatal-warnings          # 无 error
```

CI 门禁即上述命令的「无 continue-on-error」版本；本地全绿后再推送，PR/推送触发该 workflow 验证。

## 风险与注意
- 变更缓存的测试务必调用 `settleIndexFlush()`，避免 `index.json` 未落盘导致持久化断言 flaky、或 pending timer 报错。
- `tearDown` 必须递归删除临时目录，避免 CI runner 残留。
- owners 回归防护以 public 可观测行为（`hasCover` true + `countByKind[cover]>0` + `evictSong` 只清归属封面）为锚，足够捕获旧 bug 复发。
- 不污染既有观察流水线，不改动 `test-suite.yml` / `build-android.yml` 的 needs 链。