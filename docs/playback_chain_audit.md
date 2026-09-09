# 播放链路预探测与自动切换审计报告

> 范围：客户端本机播放 / 客户端直投 DLNA / 服务端投 DLNA / Web 前端播放。
> 关注点：本地 / WebDAV / 网络插件源失效时，各链路的预探测、自动换源、全失效后跳下一首兜底。
> 结论先行：**四条链路的「全失效 → 跳下一首」兜底都已实现，不会卡死**；但存在 2 个真实缺口（P1）。

## 一、四链路总览矩阵

| 链路 | 播放 URL | 投/播前预探测 | 失败感知方式 | 全失效兜底 | 连续失败停止阈值 |
| --- | --- | --- | --- | --- | --- |
| 客户端本机 | `/rest/stream`（本地/WebDAV）、`/rest/stream-remote`（插件） | ✅ upcoming 3 首批量 probe（**当前首不探**，靠 error 即时感知） | just_audio error 事件，即时 | 转码重试 → 记死歌 → `next()` | 5（player_provider.dart:179） |
| 客户端直投 DLNA | `/rest/dlna/stream/:token`（客户端换一次性 token，强制 http） | ❌ **无**（`_playCurrentTrack` 直接投） | 2s 轮询 TransportState，曲中异常 stall×2 才判定 | 跳下一首 | 8（dlna_manager.dart:65） |
| 服务端投 DLNA | `/rest/dlna/stream/:token`（服务端签发） | ✅ **投前 `ensurePlayableStream`**（Range bytes=0-20000，12s 超时） | GENA 事件 + 轮询 + stalled 重播 | probe 失败移出队列跳下一首 | 3（QueueController.ts:356） |
| Web 前端 | `/rest/stream`（Howl html5:true） | ✅ upcoming 3 首 probe + 远程歌 Range 格式探测 | onloaderror/onplayerror 即时 | 跳下一曲 | 5（player.ts:199） |

## 二、服务端统一兜底层（四条链路共用）

所有播放端点都走服务端代理，**无裸返原始直链的口子**。兜底分三层：

1. **源优选切换** `resolvePreferredSong`（rest/index.ts:1408）：
   - 同组有 local/webdav 且开「播放优选」→ 切本地无损源；
   - 主源 local/webdav 失效（`probeLocalSourceOk` 失败，记忆 5 分钟）→ 切同组 web 源。
2. **拉流时换源** `serveWebSongStream`（rest/index.ts:1229）：web 原链 fetch 403/404/5xx → `findFallbackStream`（同 provider 内按 manifest `sourcePreference` 排序 + 导入门禁过滤）→ 命中则回写 `songs.url` 永久生效。
3. **播放前探测** `ensurePlayableStream`（streamFallback.ts:239）：probe() Range 12s 超时 → 失败走 findFallbackStream → 命中回写 DB。

转码与 Range：`decideTranscode` 命中时 ffmpeg 实时转码（并发上限 4）；`/rest/stream`、`/rest/dlna/stream` 均透传 Range 头给 WebDAV。DLNA 音箱不支持格式（ogg/opus/webm/octet-stream）由 `serveDlnaWebStream`（rest/index.ts:1515）实时转 192k mp3，格式探测缓存 5 分钟。

## 三、逐链路流程（关键失败点标注 ★）

### 1. 客户端本机播放
```
playSong(player_provider.dart:660)
 ├─ 离线缓存命中 → 直接播本地文件(:800)
 ├─ 本机曲: _buildStreamUrlOrThrow(:164) → /rest/stream
 ├─ 在线曲: _resolvePreviewSongForPlayback(:1541) → resolveSongUrl 遍历多 source 候选
 │          (gd_music_api_client.dart:228-280，客户端侧有一轮源候选回退)
 ├─ _probeUpcoming(player_playback_helpers.dart:83) → POST /rest/api/v1/stream/probe
 │          向后探 3 首，deadSongs 标记提前跳过（当前首不探）
 ├─ setUrl 起播(:924/:1477) ★
 ├─ 失败 catch(:1006) → _playWithTranscoding 换 MP3/320 重试(:1061)
 │        → 仍失败 _handlePlaybackError(:1292) 记死歌 + next()  ✅跳下一首
 └─ 三道看门狗(player_position_polling.dart:123/277/250)
          0秒卡死重载 / 停滞跳歌 / Windows 末段判完成
线路级：FallbackInterceptor(fallback_interceptor.dart:80) 连续失败切 AddressPool 下一服务器地址
```

### 2. 客户端直投 DLNA（链路A）
```
设备发现 ssdp_discovery.dart(:67/:358) ★多网卡/IOCP
 → DlnaManager.startCast(:288) → _probeDevice 能力探测(:450)
 → 每曲 _playCurrentTrack(:374) → POST /v1/dlna/stream-url 换 token
   (subsonic_api_client.dart:260) ★服务端不可达→回退带鉴权 /rest/stream 直链
 → 强制 http 重写 cast_http.dart:65 ★无 http 地址→禁止投流
 → SoapControl stop→setAvTransportUri→play(soap_control.dart:396-408) ★设备不回连/卡 TRANSITIONING
 → 2s 轮询 _pollStatus(dlna_manager.dart:676-924)
 → 曲末三路触发: nearEnd+startedOver / wallDone 墙钟兜底 / deviceEnded+positionStuck
   → _advanceAfterCompletion(:956) 客户端逐曲 SetAVTransportURI 续播
 → 曲中异常 stall×2 → _handleCastPlaybackError(:1027) 跳下一首 ✅；连跳 8 停
★ 核心缺口：投前无 ensurePlayableStream 预探测（链路B 有），
   失效曲要等设备播不出+stall×2 才跳，一首废曲浪费 10-30s
```

### 3. 服务端投 DLNA（链路B）
```
客户端「切换播放器」选 DLNA peer → POST /peers/:id/queue/play(api/index.ts:2811)
 → QueueController.playCurrent(QueueController.ts:338-390)
 → ensurePlayableStream(:353→streamFallback.ts:239) 投前预探测+换源 ✅
   失败→移出队列跳下一首 ✅；连跳 ≥3 停
 → getEffectiveBaseUrl(control.ts:104) ★0.0.0.0/公网域名→设备拉不到
 → createCastSession(:444) 签发 /rest/dlna/stream/:token（6h，逐曲重换）
 → castToDevice(:551): Stop→SetAVTransportURI→waitForCanPlay→Play ★705 transport locked
 → 设备回连 /dlna/stream/:token(rest/index.ts:1740) → resolvePreferredSong+
   serveDlnaWebStream 拉流时仍换源兜底 ✅
 → GENA/轮询感知曲末 → QueueController 推下一首（deviceQueues 持久化 :809）
```

### 4. Web 前端播放
```
player.ts: getStreamUrl(:361) → /rest/stream?id=&token=（远程歌 /rest/stream-remote）
 → Howl(html5:true) 播放(:495)
 → probeUpcoming(:608) upcoming 3 首 probe；远程歌 probeRemoteFormat(:436) Range 探格式
 → onloaderror/onplayerror → localHandlePlaybackError(:511/:528)
   fail streak < 5 → localNext() 跳下一曲 ✅；达 5 停(:533-539)
 → deadSongs(:604) 预探测失败提前跳过
Web 投 DLNA: startCast(:1047) → POST /peers/dlna:<id>/queue/play（走服务端投链路B）
```

## 四、缺口清单（按严重度）

### P1-1：换源缓存无 TTL 且命中不重探 —— 失效链会被缓存「锁死」
`streamFallback.ts` 的 `playableCache`（FIFO 5000）与 `fallbackCache`（FIFO 2000）**均无 TTL**，且命中即返回（:243-247、:102-106 实测确认）。插件源 URL 是临时签名（网易约 20 分钟过期）：

- 换源成功 → 新链写入 fallbackCache → 新链过期后，`ensurePlayableStream` / `findFallbackStream` 命中缓存**直接返回这条已过期的链，不再重探**；
- 结果：这首歌在缓存淘汰前**反复失败**——probe 端点误报「可播」，实际拉流 fetch 失败 → findFallbackStream → 缓存又返回同一条失效链 → 再失败；
- 四条链路全部受影响（probe 端点、服务端投预探测、拉流兜底都走这层缓存）；
- 最终兜底仍是跳下一首（不会卡死），但**库里明明有可播源也救不回来**，直到 FIFO 淘汰（2000/5000 首）或服务重启。

**修复方向**：缓存条目加 TTL（如 10 分钟，对齐网易 20 分钟过期的安全余量）；或 fetch 失败时把该 songId 从两缓存中删除再走 findFallbackStream（失败即逐出，成本最低）。

### P1-2：客户端直投 DLNA 无投前预探测 —— 与链路B 不对齐
链路B 投前 `ensurePlayableStream`，链路A 直接投。失效曲在链路A 上要等设备端播不出 + stall×2（每轮 2s）才跳，每首废曲浪费 10-30s，还消耗 failStreak（上限 8，遇到一批失效曲可能提前停播）。

**修复方向**（二选一，改动都小）：
- 服务端：`POST /v1/dlna/stream-url`（api/index.ts:2337）签发 token 前先 `ensurePlayableStream(songId)`，失效直接返回错误，客户端换下一曲——**推荐**，一处改动四端受益；
- 客户端：`_playCurrentTrack` 投前调已有 `/rest/api/v1/stream/probe` 批量探测。

### P2（一致性/体验）
1. **停止阈值不统一**：本机 5 / 直投 8 / 服务端投 3 / Web 5。全源失效（如服务下线）时各端停得快慢不一；建议统一并给用户明确提示「连续 N 首不可播已停止」。
2. **无单源 unhealthy 持久化标记**：失效源每次播放都要现场探测（内存缓存缓解，但重启即失忆）；插件级有 `plugin_health`，歌曲级没有。可选做失效计数落库 + 冷却期。
3. **直投 token 无鉴权**（6h TTL，仅绑 songId）：内网场景可接受，公网暴露 DLNA 端口时是安全面。

### P3（设计如此，非缺陷）
- 本机当前首不经预探测：error 事件即时，成本可接受。
- 客户端无「一首歌多源」模型：多源回退完全由服务端透明完成，客户端只持单一端点——架构边界清晰，不建议客户端再加源模型。
- 设备端 next 仅作无缝预载（SetNextAVTransportURI），权威队列推进仍在客户端/服务端——正确设计。

## 五、「全部源失效 → 自动播下一首」结论

**四条链路都已实现且不会卡死**：

| 链路 | 兜底动作 | 卡死风险 |
| --- | --- | --- |
| 本机 | error → 转码重试 → 记死歌 → next()，连跳 5 停 | 无（看门狗三重兜底） |
| 直投 DLNA | stall×2 → 跳，连跳 8 停 | 无（但感知慢 10-30s/首） |
| 服务端投 | probe 失败移出队列跳，连跳 3 停 | 无（预探测先行，最快） |
| Web | probe upcoming + onloaderror 跳，连跳 5 停 | 无 |

唯一值得做的是把「跳下一首」在直投链路补上**投前预探测**（P1-2），把兜底从「事后发现」提前到「事前过滤」——服务端改一处即可。

## 六、改造落地记录（P1-1 / P1-2 已修）

### P1-1：失效源缓存无 TTL → 改为「拉流实测失败即逐出」

- `streamFallback.ts` 新增 `evictStreamFallbackCache(songId)`：一次删除 `fallbackCache` + `playableCache`。
- `rest/index.ts` `serveWebSongStream`：upstream 403/404/5xx 走换源后仍失败，且该结果来自缓存命中
  （`fb.source === ""` 是 fallbackCache 命中标记）→ 逐出双缓存后**再真实重搜一次**，仍失败才透传失败响应。
- 效果：网易等 ~20 分钟过期的插件直链不再被锁死到 FIFO 淘汰或服务重启，下次播放立刻重新探测/换源。

### P1-2：客户端直投 DLNA 无投前预探测 → 服务端 409 + 客户端双层拦截

- **服务端（一处改动，四端受益）**：`POST /api/v1/dlna/stream-url` 签发 token 前先预检，全类型覆盖：
  - web 行：有本地缓存文件即放行；否则 `ensurePlayableStream`（Range 探测 + 多源换源，命中回写 DB）；
  - local/webdav 行：`probeLocalSourceOk`（本地 `existsSync` 零成本 / WebDAV HEAD 带 5 分钟失败记忆）；
    主源不可用但**组内有 web 备选时放行**（流播时 `resolvePreferredSong` 会自动切，预检不越权替它决定）。
  - 验不过 → **409 `errors.song.noPlayableSource`**（i18n 中英双语已加）。
- **客户端**：
  - `subsonic_api_client.getDlnaCastStreamUrl`：409 → `DlnaSongUnplayableException`（其他错误原样抛出）。
  - `dlna_manager._playCurrentTrack`：新增 `probeSong` 钩子（`/rest/api/v1/stream/probe`）+ 捕获
    `DlnaSongUnplayableException`，二者都触发「按播放模式推进下一曲」；**单次激活内绕圈上限 = 队列长度**，
    圈满停下交看门狗/用户，整队全死源时 `startCast` 不会无限 await 挂死 UI。
  - 死源感知从「设备播不出 + stall×2（10-30s/首）」提前到「换 token 前一次 HTTP 往返」。

### 连带清理：客户端/前端死歌机制移除

客户端 `player_provider` 的 `_deadSongs` / `_probeCache` / `_markSongDead` / `_failStreak`、
Web 前端 `player.ts` 的 `deadSongs` / `localFailStreak` 全部移除——预探测标记的是**歌曲**而非源，
坏源可被服务端换源救回后仍会被永久跳过，属于误杀；现在统一由服务端「换源 → 仍无源 → 409」裁决。
服务端 `QueueController` 的 `skipCounters` 停播阈值同样移除：不可播的逐曲移除、队列自然排空，不再中途停播。

### 守卫（防回归）

- 客户端 `test/core/dlna/dlna_chain_guard_test.dart`（12 条）：内置迷你模拟 DLNA 设备，覆盖
  死源跳过、整队全死源不挂死、绕圈上限、正常起播、probe 异常不误杀。
- 后端 `backend/tests/routes/dlnaStreamUrlGuard.test.ts`（5 条）：409 语义、local 缺失有 web 备选放行、
  local 缺失无备选 409、web 有缓存文件放行、local 文件存在放行。
- CI：两仓各加 `.github/workflows/playback-chain-guard.yml`（阻塞型，push/PR 触发）。
