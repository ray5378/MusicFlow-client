# 更新日志 (Changelog)

本文件记录各版本的主要变更。版本号遵循语义化版本，仅在打 `vX.Y.Z` tag 时由 CI 构建并发布（产物：Android APK / Windows 安装包）。

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
