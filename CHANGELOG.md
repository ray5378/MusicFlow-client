# 更新日志 (Changelog)

本文件记录各版本的主要变更。版本号遵循语义化版本，仅在打 `vX.Y.Z` tag 时由 CI 构建并发布（产物：Android APK / Windows 安装包）。

## [5.0.31] - 2026-09-23

### 修复 —— Android 本机拖动/点击进度条仍「从头播放」（服务端能力判定被登录快照判死）

- **现场**（v5.0.30 已装，Android 真机）：拖动/点击进度条后进度条停在目标位置，**声音依旧从头播放**。
  手机端 `[SEEKDBG]` 是铁证 —— 修复代码**跑到了**，却判「不重拉」：

  ```
  [EFFECTIVE-SEEK] seek 52614ms → local player (no cast peer)   ← 确实走的本机通道
  [SEEKDBG] seek route reload=false origin=- flag=false         ← 却判定「不重拉」→ 裸 player.seek()
            ctx=https://…:35378/rest/stream id=08e9b652… format=- maxBitRate=- timeOffset=-
  ```

- **根因（本轮真凶）**：`shouldUseServerTimeOffsetSeek()` 第一句就是
  `if (serverPipelinedHttp) return true;`，所以 `flag=false` **只能**来自
  `_serverPipelinedHttp()` 返回了 false（日志里 `ctxSong`/`ctx` 都有值，已排除被
  `_clearStreamContext()` 清掉）。而该函数末尾串了一道**版本门控**
  ——`serverPipesAllHttpStreams()` 要求 `serverVersion ≥ 3.0.47`（管道化 P2-1 上线版本）。
  致命点在于：**`serverType`/`serverVersion` 是登录时写一次、此后从不刷新的静态快照**。
  服务端升级到管道化版本之后，老库里记的仍是登录当年的旧号 → 判定恒 false →
  `_seekByReloadStream` 永远为假 → **拖动重拉永久关闭**。服务端侧实测
  `/rest/ping` 实报 `serverVersion=4.0.14 / type=MusicFlow`，完全正常。

- **为什么只有 Android 暴露**：这是一条**两端同为 FALSE** 的判定。Windows 之所以「正常」，
  是因为它跑 media_kit/libmpv，libmpv 自身能处理 HTTP 流的 seek；Android（just_audio →
  ExoPlayer）对实时管道流只能回到第 0 字节 —— 这就是「进度条对、声音从头」的来源。

- **修法**：
  1. **退役版本门控**（`serverPipesAllHttpStreams`）：只看服务端类型前缀，不再看版本快照。
     误判代价极不对称 —— 把真·管道化服务端判成「非管道化」= 拖动彻底失效；把老服务端判成
     「管道化」= 多一次带 `timeOffset` 的重拉（标准 Subsonic 参数，老服务端同样接受）。
  2. **放宽 `isServerStreamUrl`**：原先硬性要求签名三件套 `u`/`t`/`s`，只覆盖「用户名+密码
     登录」一条鉴权路径。改为认「歌曲标识（`id`/`provider`）**或** 任一鉴权痕迹
     （`u`/`t`/`s`/`apiKey`）」，同时覆盖 API Key 鉴权与老库缺 `password` 两种形态。
  3. **诊断日志**：`[SEEKDBG] seek route` 增加 `pipe=` 与 `libType=/libVer=`，把判定依据连同
     **库里的登录快照**一起打出 —— 一旦它落后于 `/rest/ping` 实报版本，一眼可辨。

- **回归守卫**：改写 `test/providers/player/seek_reload_routing_test.dart` 与
  `test/providers/transcoded_stream_seek_test.dart`，把两处事故形态钉死 ——
  「版本快照落后（3.0.46 / null / dev）仍必须按管道化处理」、「API Key 鉴权的流地址
  必须被认作本服务端流」。

## [5.0.32] - 2026-09-23

### 新增 —— 「编辑音乐库」页面补全 用户名 / 密码 / API Key 三个可修改配置项

- **现场**：登录后进入「编辑音乐库」只有「名称」一个输入框，用户名、密码、API Key 既看不到也无法修改，
  只能删库重新登录才能换凭据。
- **根因**：`edit_library_page.dart` 早已建好 `_usernameController`/`_passwordController`/`_apiKeyController`
  并在打开时把库里的凭据填进输入框，但页面只渲染了「名称」字段，**保存逻辑也只回写 `name`** ——
  三个认证字段既没显示也没落库。模型 `MusicLibrary`、持久化 `updateLibrary`、登录流程本身都支持这三个字段，
  缺的只是「页面渲染」与「保存逻辑」两段。
- **修法**：
  1. 在「基本信息」下方新增「认证信息」分组，渲染 **用户名 / API Key / 密码** 三个输入框
     （密码与 Key 默认掩码，图标与登录页一致）。
  2. 校验沿用登录页规则：用户名必填；**填写 API Key 时优先用 API Key 认证**，否则用 用户名+密码。
     保存时按填写自动判定 `authType` 一并写回。
  3. 保存后立即 `ref.invalidate(librariesProvider / activeLibraryProvider)` —— API client 实时读取库，
     当前会话立刻切换到新凭据，无需重启或重新登录。

## [5.0.30] - 2026-09-23

### 修复 —— 本机点击/拖动进度条一律「从头播放」（seek 路由改按音源事实判定）

- **现场**（Android 本机播放，任意音源均复现）：点击/拖动进度条后进度条显示正确停在目标位置，但**声音始终
  从头播放同一首歌**。服务端已排除：240 实测同一首曲（webdav 源 flac 244s）`timeOffset=0` 交付流解码
  244.1s、`timeOffset=90` 解码 **154.1s**（正好少 90s），且服务端从未收到"无偏移的二次拉流"；客户端
  `[SEEKDBG]` 显示 seek 实际走的是裸 `player.seek()`（`seek execute`），根本没进重拉分支。
- **根因**：走「重拉服务端流」还是「源内 seek」原先只看可变字段 `_seekByReloadStream`（由服务端能力判定
  写入）。它会在若干路径上被清成 `false` —— 例如起流时先 `_clearStreamContext()`，随后本次加载被判作废
  而提前 `return`（`setUrl` 已执行、播放器确实在放新源，但 `_currentStreamUrl` 保持 null、标记保持
  false）；preview 起流更是显式写 `false`。一旦它为假，seek 静默退化成「把同一个无效动作重复一遍」，
  而且**不会自我纠正**：just_audio 在 seek 之后会**立刻**把 position 报成目标值（实测 driftMs 稳定
  200~230ms），于是「漂移 > 2s 才升级重拉」的兜底永远不触发 —— position 在这个场景里会撒谎，不能当作
  「seek 成功」的证据。
- **修法（换判定依据，不加时间窗）**：新增纯函数 `resolveSeekReloadPlan()`，按**音源地址事实**判定，三种
  来源按可信度排序：
  1. `context`：流上下文完整且标记可重拉（原路径，行为不劣化）；
  2. `context_lost`：上下文丢失/不可信时，改用**播放器当前真实加载的地址**（`player.audioSource`
     → `UriAudioSource.uri`）—— 事故主因的兜底，地址是事实而非记账；
  3. `context_plain`：上下文在但标记不可重拉（历史 preview 路径）而地址仍是本服务端流
     （`/rest/stream-remote` 与 `/rest/stream` 一样吃 `timeOffset`）→ 顺手修掉试听链路的拖动。

  归属判定 `isServerStreamUrl()`：http(s) + 路径落在 `/rest/stream`(或 `-remote`) + 带 Subsonic 签名
  三件套（`u`/`t`/`s`）。外部 CDN 直链与离线缓存 `file://` 都不满足 → 仍走源内 seek（它们无法靠改写
  URL 让服务端重新出流）。重拉地址由 `buildTimeOffsetStreamUrl()` 在基准地址上**改写 `timeOffset`**，
  其余参数（含签名、`format`/`maxBitRate`）原样保留。
- **顺带修掉的两个隐患**：
  - preview 起流不再硬编码 `seekByReloadStream: false`，改为按地址事实判定；
  - 服务端能力判定放宽为**前缀匹配**（`MusicFlow` / `musicflow` / `musicflow-web` 都算本服务端）并容错
    `v4.0.14`、`MusicFlow 4.0.14` 这类自报版本串 —— 等值判定一旦不匹配就会把「全管道化」判死，进而把
    拖动退化成源内 seek。
- **明确不做的事**：不再用 `drift` 漂移判断 seek 是否成功（实测不可信）；对**非管道化**服务端（明确识别出
  的 Navidrome / 老版本）保持既有 `format`/`maxBitRate` 判定与源内 seek，避免把本可字节 seek 的直传流
  退化成重拉。
- **守卫测试**：新增 `test/providers/player/seek_reload_routing_test.dart` 共 15 例，含事故回归
  「上下文丢失 + 标记为 false 时仍必须重拉」、preview 链路、外部直链 / 离线文件不重拉、其他服务端不重拉、
  归零 seek 不带 `timeOffset`、type 与版本串容错等。
- **验证**：`flutter analyze` 0 error；`flutter test` **765 全绿**。**服务端无改动**。

### 构建信息
- Android: `MusicFlow-v5030-android.apk`
- Windows: `MusicFlow-v5030-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [5.0.29] - 2026-09-23

### 修复 —— 本机播放「总时长被实时流拽回 0 再爬升」+ 拖动/点击都从头播放

- **根因（一个 bug，两副面孔）**：服务端实时管道流起播时，`durationStream` 会先把时长报成 1s、2s…再一路爬到真实时长；原逻辑「流能提供时长就优先用流的时长」直接采纳了这个渐进值：
  - **Windows**：总时长先显示正确值 → 被拽回 0 → 逐秒爬回真值（观感抖动）；
  - **Android**：更严重 —— `normalizeSeekPosition` 按这个偏小的时长**截断 seek 目标**，拖到 3 分钟被裁成几秒，听感就是「点击/拖拽都从头开始播放同一首歌」。
- **修法**：新增纯函数 `authoritativeDuration()` —— 歌曲元数据时长已知时以**元数据为权威**，实时流上报值一律让位（元数据缺失才退回流时长，保留「流时长更准确」的原意）。三处落地：
  1. `durationStream` 监听：元数据已知时不再覆盖 `state.duration`；与元数据偏差 >3s 时留一条诊断日志（每首一次，不刷屏）；
  2. `_normalizeSeekPosition`：一律按权威时长 clamp（第二道保险 —— 即使 `state.duration` 被别的路径污染，也不会把拖动目标误裁成几秒）；
  3. `_logicalPlayerPosition`：进度映射的 `maximum` 同样取权威时长。
- **守卫测试**：`test/core/player/playback_payload_test.dart` 新增 `group('authoritativeDuration…')` 共 4 例；其中「seek 目标不被渐进上报的小时长截断」先断言修复前的错误行为（180s → 2s），再断言修复后保持 180s，把契约钉死。
- **验证**：`flutter analyze` 0 error；`flutter test` **750 全绿**。服务端 `timeOffset` 已实测有效（`maxBitRate=128&format=mp3`：275.98s → 185.99s；原音质 flac 管道：54.2MB → 37.7MB），本次**无服务端改动**。

### 构建信息
- Android: `MusicFlow-v5029-android.apk`
- Windows: `MusicFlow-v5029-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [5.0.28] - 2026-09-22

### 测试 —— 拖拽 seek 目标整秒契约守卫（**无功能变更**）

- 新增守卫 `test/providers/cast_remote_progress_guard_test.dart` 的 `group('seek 目标精度（最小粒度 1 秒）')`
  共 3 例：①捕获**真正下发**的 `/seek` 请求体，断言 `seconds` 是 `int`，且与 `Duration.inSeconds`
  同语义（`31178ms → 31`，截断而非四舍五入）；②多采样点（0 / 178 / 999 / 31178 / 62000 / 87033 /
  108999 / 3599400 ms）满足 **25ms 帧栅格不变式**且截断代价 <1 秒；③乐观值与下发值**同源**
  （否则远端回报后进度条会回跳）。
- 归属：该文件由**阻塞式** `playback-chain-guard.yml` 直接执行，即真门禁，无需新增 workflow。
- **本版无功能变更**：客户端此前就下发 `Duration.inSeconds`（整秒，1000 / 25 = 40 恒为帧栅格整数倍），
  这正是「服务端同一个 seek 接口，HA 卡片与网页一拖就挂、客户端一直正常」的原因。本版把这条约定
  钉死，防止以后有人改成带小数的秒 —— 那种回归**远端哑掉、本机 UI 毫无异常**，极难发现。
- 配套服务端 **v4.0.12**／HA 卡片 **v2.4.8**／HA 集成 **v2.0.5**（同一批次对齐发布）。

### 构建信息
- Android: `MusicFlow-v5028-android.apk`
- Windows: `MusicFlow-v5028-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [5.0.27] - 2026-09-22

### 修复 —— 链路 A 换歌清 seek 标记

- 换歌（游标变）清 `_seekIssuedAtMs`／`_seekAckAtMs`／`_seekTargetSeconds`：旧标记属于上一首，新歌开头正常 0 采样被屏蔽会冻住进度（卡片同款清理已同步）
- 10s 超时只清目标值：issued/ack 靠 reportedAt 自限，超时清会误伤滞后采样判定

### 构建信息
- Android: `MusicFlow-v5027-android.apk`
- Windows: `MusicFlow-v5027-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [5.0.26] - 2026-09-22

### 调试日志补全（遥控＋本机播放关键链路）

- 镜像跟随：广播 DIFF 行（total/index/mode＋本机对照）＋三处可听变更留痕（follow/adopt/cursor 目标 songId）
- seek 路由行：本次 seek 走 linkB 直投／linkA 远端 peer／本机
- 本机：seek/next/prev/play/pause 五入口留痕（含静默早退分支）
- 零行为变更；配套服务端 **v4.0.11**

### 构建信息
- Android: `MusicFlow-v5026-android.apk`
- Windows: `MusicFlow-v5026-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [5.0.25] - 2026-09-22

### 修复 —— 遥控 seek 后本机莫名出声 + 间隙 0 回退

- **加载废弃即作废 autoplay 意图**：镜像跟随 `playSong(autoPlay:true)` 后加载被废弃，`_expectingAutoplay` 烂在 true，6s 后启动卡死看门狗 reload 当前曲 → 手机莫名从头出声（240 联调实锤，DLNA 遥控正常、本机也响）。修法：最新加载被废弃即清意图，有更新加载在途则不动；用户暂停/源推进清除路径不变。
- **重投间隙 TRANSITIONING-0 屏蔽**：seek ack 后设备起播前轮询读数是"还没开始"不是"回到开头"，ack 后 10s 内非播放态≈0 采样屏蔽、保持乐观值；落位/换歌/超时解除。
- 配套服务端 **v4.0.9**（重投风暴串行化）。

### 构建信息
- Android: `MusicFlow-v5025-android.apk`
- Windows: `MusicFlow-v5025-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [5.0.24] - 2026-09-22

### 修复 —— 遥控服务端 DLNA 拖进度条仍偶发「竞态胜利拽回开头」

- **元凶**:`seek()` 在 REST 响应返回后仍立刻 `pollOnce()` 拉一次状态。这次拉取在
  ack **之后**发起,因果屏障(fetchStale)按定义挡不住它;而设备型 peer 此刻仍在
  重锚,立即查询读到瞬态 `position=0` → 刚拖好的进度条被拽回开头。v5.0.23 的
  因果判定本身没错,漏的是这条「立即拉取」(HA 卡片从不 immediate-fetch,所以
  卡片一直正常)。
- **修法(对齐 HA 卡片)**:seek 后不再立即拉状态,交给周期轮询确认,确认前平滑
  进度按乐观值自然推进;`_seekIssuedAtMs` 改为**下发前**打点(响应后才置会漏掉
  「下发与响应之间」的采样)。

### 修复 —— 并发轮询乱序回写(R1,对齐卡片 vSeq 防乱序令牌)

- 命令点(toggle/pause/next/prev/播放模式/队列操作等)频繁 `unawaited(pollOnce)`
  与 2s 周期轮询并发,两个 `_tick` 的响应可乱序落地:**旧响应后到,把新状态
  (position/曲目/播放态)整个覆盖回去**,表现为「操作后 UI 跳回旧值再恢复」。
- `_tick` 启动自增 `_tickSeq`,响应落地时序号不匹配即作废,只允许最新一轮回写。

### 修复 —— tick 在途期间切换 peer,旧响应仍回写(R2)

- 原守卫只在 `_tick` **发起前**检查控制目标;status 拉取超时可达 6s,await 之后
  无复检,旧 peer 的响应会落到新控制目标上(切设备瞬间显示错乱)。
- status await 后与队列补拉后各补一次「令牌 + 控制目标」复检,过期作废。

## [5.0.23] - 2026-09-22

### 修复 —— 遥控 DLNA(链路 B 直投)seek「能往回跳不能往前跳」

- **根因**:客户端直投通道的 seek 一直发 **SOAP REL_TIME** 给设备,而设备拉的是
  服务端实时管道流(chunked,不可字节 seek):往后跳落在设备已缓冲区间内看似生效,
  往前跳设备拿不到数据 → 重头拉流(整首歌重头播)。HA 卡片走服务端
  `POST /peers/:id/seek`(reseekByRecast)所以一直正常。
- **修法(MA play_index(seek_position) 语义)**:`DlnaManager.seek` 改为**带
  timeOffset 重建流**——重新取流 URL 拼 `timeOffset=N` → Stop → SetAVTransportURI →
  Play;墙钟锚点同步改到目标秒;复用曲末互斥守卫防误判切歌。无队列信息时回退 SOAP Seek。

### 对齐 —— seek 陈旧位置判定去掉固定 6s 窗(链路 A,与 HA 卡片 v2.4.6 同款)

- 原判定:seek 后 6 秒内的上报一律按窗口规则处理——是近似,不是因果。
- 新判定(MA 位置模型):①**因果**——服务端 seek 为同步语义(响应返回=锚点已落位),
  凡「seek 响应之前发起」的状态轮询一律丢弃,设备型 peer 无时间戳也精确覆盖;
  ②**采样**——带 reportedAt 的客户端实例按「采样时刻早于 seek 下发」判定
  (时钟偏差 >120s 视为不可信,只按①)。无窗口、无魔法数字。

## [5.0.22] - 2026-09-22

### 修复 —— 本机(local)播放拖动进度条「拖到哪都从头开始」

- **根因**:服务端实时管道流**不可字节 seek**,而 `_seekWithFallback` 在漂移超标时的
  兜底只是**把同一个无效动作再执行一次**(`player.seek()`),从不升级为代码里已存在的
  `_reloadStreamForSeek()`。抓包证据:本机播放点击进度条 → 服务端 **0 次 seek、
  0 次 `/rest/stream` 重拉**,只有起播那一次(且不带 `timeOffset`)。
- **修法**:漂移 > 2000ms 且当前源是可重建 URL 的服务端流 → 一律升级为带 `timeOffset`
  的重拉,即 MA 语义的「seek = 用新起点重建一条流」,而不是在旧流里挪指针。
- **能力判定 fail-open**:`_serverPipelinedHttp()` 依赖 `library.serverType/serverVersion`,
  这两个字段**只在密码登录时写入一次**,升级上来的库或复用旧会话进入时为 `null` →
  误判 `false` → 拖动彻底失效。现在仅当明确识别出非 MusicFlow(Navidrome 等)才返回
  `false`,字段缺失按「全管道化」处理 —— 误判 `true` 的代价只是一次重拉(服务端若忽略
  `timeOffset`,由漂移兜底接住),误判 `false` 的代价是功能全废。

### 配套
- 服务端 **v4.0.6+**(本次服务端侧同步按 Music Assistant 语义重做了 sendspin / DLNA
  的跳转链路,详见服务端 `docs/PLAYBACK_SEEK_MA_REWORK.md`)。

## [5.0.21] - 2026-09-21

### 改进

- **DLNA seek 诊断日志**：`seekTo` 最容易被忽略的失败路径是**静默早退**（没有当前设备、
  或 `avTransportUrl` 尚未就绪时直接 `return`），调用方只会看到「拖了没反应」而没有任何
  日志。现在该路径显式打出（含设备友好名），并补「下发 SOAP Seek」与「成功 …ms」两条，
  用于区分三种情况：命令没发出去 / 发出去了但设备没动 / 设备动了但位置上报不对。

## [5.0.20] - 2026-09-21

### 修复 —— 离线缓存 flaky 测试（与产品行为无关，修 CI 信任度）

- **根因**：3 例失败同源 —— 后台 debounce 落盘 Timer 在 tearDown 删临时目录后才触发，`_atomicPromote` 抛 `PathNotFound`，`unawaited` 异步异常被记到当时正在跑的用例头上（满负载 Timer 迟到即现形）。与 seek 改动无关（stash 双向对照）。
- **修法双保险**：新增 `dispose()` 取消 Timer（＋`_disposed` 守卫）；`_flushIndex` 遇根目录消失静默跳过＋全体 try/catch（后台落盘永不抛，生产退出瞬间同样受益）。
- 测试侧 tearDown 改确定性 `dispose`，不再依赖 1.3s 墙钟等待；新增回归用例（dispose 后删目录再等过窗口不抛）。

### 构建信息
- Android: `MusicFlow-v5020-android.apk`
- Windows: `MusicFlow-v5020-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [5.0.19] - 2026-09-21

### 修复 —— 拖动/点击进度条问题逐一修复

- **拖一下就跳歌/停播**：reload 成功后补 `play()`，新源首包未到被拒即走失败跳歌。改为温和恢复（只记日志，真失败由停滞/0 秒卡死看门狗接力）。
- **拖动后回到开头、再犯跳歌**：新源从余数（<1s）起步，0 秒卡死看门狗误判卡在起点而重载整首。新增 15s 落位宽限（source 前进过 1500ms 提前解除）；近末尾完成同窗抑制（拖到尾段不再被切歌）。
- **拖动卡顿/转码槽打满**：同逻辑段微调先源内 seek，被拒再升级全量重拉（`_reloadStreamForSeek` 抽取复用），拖动连发不再每次 setUrl。
- **定位偏小一帧**：`onChangeEnd` 取 scrubber 同步终值，不用异步落盘的 `_dragValue`。
- tap-cancel 语义锁定为取消（滚动误触不成跳播）；换音质/元数据翻转/回退基准经核实无害，不改。

### 配套说明
- 建议与服务端 **v4.0.2** 同步升级；预览流与离线播放不受本次改动影响。

### 构建信息
- Android: `MusicFlow-v5019-android.apk`
- Windows: `MusicFlow-v5019-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [5.0.18] - 2026-09-21

### 修复
- 直投 DLNA 设备的传输状态**读失败不再误判「放完」**：`SoapControl.getTransportInfo` 失败时返回的 `UNKNOWN` 此前与真 `STOPPED` 走同一条判定分支，配合「时长未知即豁免曲末校验」的放宽，**一次 SOAP 读失败就会在时长未知的曲目上演成「放完了 → 推下一首」**（曲中段误切）。现在 15s 宽限窗口内沿用最近一次成功读数，超出窗口仍读不到才认输
- `_restartPlaybackClock` 一并把状态记忆复位为 `PLAYING`：与同处合成的「新曲刚开播」`_currentStatus` 保持一致，否则上一曲末尾的 `STOPPED` 会被新曲的首次读失败沿用成「设备已停」，而 `prevState` 是合成的 `PLAYING` —— 两者矛盾会直接推走新曲

### 配套说明
- 15s 窗口与服务端 `dlna/control.ts` 的 `TRANSPORT_STATE_CACHE_MS` 同口径；建议与服务端 **v4.0.1** 同步升级
- 预览流与离线播放不受本次改动影响

### 构建信息
- Android: `MusicFlow-v5018-android.apk`
- Windows: `MusicFlow-v5018-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [5.0.17] - 2026-09-21

### 新功能
- P2-3：seek 判定改为**按服务端管道化能力切换** —— `shouldUseServerTimeOffsetSeek` 新增 `serverPipelinedHttp` 开关，命中时无条件走 timeOffset 重拉（服务端 P2-1 起全通道实时流，即使格式一致也不再字节 seek，旧结论作废）

### 修复
- 修客户端 6 条 CI 编译红灯：`_serverPipelinedHttp()` 原写在 `mixin PlayerSeekInternals on PlayerNotifier` 内，`PlayerNotifier` 基类与另一个 mixin 都访问不到（Dart：mixin 成员只对混入它的类可见），下沉到 `PlayerNotifier` 基类后恢复

### 其他
- CI Flutter 版本统一到 **3.47.5**：原 `3.38.10` × 4 处 / `3.47.1` × 12 处分裂，`server-contract.yml` 还曾是浮动的 `channel: stable`（已钉死）。消除旧 Dart SDK 解析同一份 `pubspec.lock` 造成的依赖降级（characters / intl / matcher）

### 配套说明
- 管道化门槛 `kPipelineMinServerVersion = 3.0.47`：仅 MusicFlow 且版本 ≥ 门槛判 true；Navidrome / 老版本 / 未知版本一律保守 false，行为与此前一致
- 预览流（`false` 硬编码）与离线播放不受本次改动影响

### 构建信息
- Android: `MusicFlow-v5017-android.apk`
- Windows: `MusicFlow-v5017-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [4.3.43] - 2026-09-11

### 新功能
- 本机播放补齐第四种播放模式 `order`（顺序播），与 Web / 服务端对齐为 4 态：`order` / `all` / `one` / `shuffle`
- 本机在线播放改为**以服务端预探测判定为预跳过依据**：起播前先跳过服务端已判无源（短 TTL）的歌；本机只在真正播放失败时才兜底跳过

### 配套说明
- 需配合**服务端 v2.3.25** 的队列预探测功能；服务端未升级时，本机仍走原有本地兜底逻辑
- 无效源不写库、不做死歌名单，换源可救回的歌不会被永久拉黑
- Web 端的「预探测已暂停」右上角持久轻提示由服务端 v2.3.25 提供

### 构建信息
- 提交: `8d74a8323f612e28bf579a25f287bfa5fa895898`
- Android: `MusicFlow-v4343-android.apk`
- Windows: `MusicFlow-v4343-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）
