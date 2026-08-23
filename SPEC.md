# MusicFlow-client 技术契约规范（SPEC）

> 本文件是 MusicFlow-client 仓库内 **AI 协作者必须遵守的技术契约**。任何改动（新功能 / 修 bug / 重构）都必须先对照本规范划定边界。
>
> 版本：v3（2026-08-23，全量重写）｜ 维护：ray（仓库 owner）｜ AI 改动本文档需经 ray 确认
>
> **v3 重写要点**：
> - **全量对齐主项目后端**：客户端是 MusicFlow 主项目（`ray5378/MusicFlow`，Node/TS 后端 + Vue 前端）的全量客户端，接口面、数据契约、行为表现一律以主项目为准。
> - **DLNA 由后端推送**：客户端**绝不自行 SSDP/SOAP/推流**。投屏/切播放器走主项目 `/rest/api/v1/peers*` 统一控制面，由后端 `QueueController` 向 DLNA/AirPlay/群组设备投流。**「控制后端 DLNA 播放」是当前未完成功能，v3 给出完整契约与完成项清单（§3）。**
> - **交互对标网易云 / QQ 音乐**：播放器主流程交互体验（迷你条 → 全屏 → 队列 → 切换播放器）参考主流音乐 App（§7.1）；首页（发现页）内容与交互保持现有实现为基准。
> - **Windows 渲染性能成为硬性契约**：新增「§八 Windows 桌面端渲染性能约束」，把特效降级、高频重建、音频后端选型、发布前性能验收写死，治理 Windows 卡顿与渲染差。
> - **修复旧版硬伤**：API 端点体系统一（删除三套并存）、DLNA 存档区清理、测试清单按仓库实际重列、基础库依赖表按 pubspec 实测修正、目录结构按现状更新。

---

## 一、定位、技术栈与工程约束

### 1.1 定位

- 本仓库是 **MusicFlow 主项目后端的全量客户端**（Flutter），首发 **Windows + Android**，后续扩展 iOS/鸿蒙/Web。
- 客户端消费主项目三套接口面：**原生 API**（`/rest/api/v1/*`）、**OpenSubsonic**（`/rest/*`）、**WebSocket**（`/ws`）。
- 播放目标统一抽象为 **peer**（本机 `local:<uid>` / DLNA `dlna:<id>` / 群组 `group:<id>` / AirPlay `airplay:<id>`）。投屏（DLNA/AirPlay/群组）一律由**后端推流**，客户端只做控制面。
- **首页（发现页）是基准**：现有 Android / Windows 首页展示的内容与交互逻辑已被确认为正确，**作为基准保留，不得擅自改版**（见 §7.3）。

### 1.2 技术栈（按 pubspec 实测）

| 层 | 选型 | 版本/备注 |
|----|------|----------|
| 语言 | Dart | SDK `^3.10.8`，严格类型 |
| UI 框架 | Flutter | 一套代码覆盖 Android + Windows（首发） |
| 状态管理 | flutter_riverpod + riverpod_annotation | Provider 模式，代码生成 |
| 网络 | dio（自定义 FallbackInterceptor/AddressPool 多线路） | 原生 API + OpenSubsonic 双客户端 |
| 音频 | just_audio + audio_service + just_audio_background | 后台播放 + 通知栏控制 |
| 桌面音频 | **just_audio_media_kit + media_kit_libs_windows_audio** | **Windows 唯一后端**（见 §8.4；`just_audio_windows` 需验证去留） |
| 本地存储 | drift + sqlite3 + sqlite3_flutter_libs | 服务器配置/设备/历史 |
| 本地配置 | shared_preferences | 主题、音质等 |
| 路由 | go_router | StatefulShellRoute 分页导航 |
| 模型 | freezed（^3.1.0）+ json_serializable | 不可变数据类 |
| 图片 | cached_network_image + palette_generator | 封面/配色 |
| 工具 | crypto / uuid / path / path_provider / share_plus / package_info_plus / url_launcher / connectivity_plus / permission_handler | |
| 列表增强 | scrollable_positioned_list（队列滚动定位）、animations | |
| 遗留待清理 | azlistview / lpinyin / marquee | v2 已移除 A-Z 索引且 marquee 无使用，**确认无用后从依赖移除** |

> **依赖纪律**：任何新增/删除依赖必须向 ray 报备并获确认（§10 负面清单 #1）。`freezed_annotation`/`freezed` 以 `^3.1.0` 为准（旧 SPEC 的 `^2.4.4` 已过时）。

### 1.3 对齐原则（最高优先级）

- **客户端必须对齐主项目**：接口参数、数据结构、行为表现均以主项目为准；主项目前端 `stores/player.ts`（peer/队列/投屏状态机）、`composables/useInfiniteList.ts`（列表窗口化）是行为基准。
- **主项目只读，禁止修改**。主项目参考源码可克隆为本地只读工作副本（如 `/workspace/_MusicFlow-main`），**该目录严禁提交/入库**（交付前 `git status` 核对，见 §10 #10）。
- **唯一例外**：某功能不修改主项目无法实现时，必须先向 ray 说明原因并获明确确认，未确认前只能在客户端变通。

### 1.4 硬性工程约束

- **依赖管理**：严禁引入未授权的新第三方库、严禁升级现有依赖版本。缺能力 → 先说明理由，等确认。
- **命名规范**：文件/目录全小写+下划线（`cast_peer_provider.dart`）；类/接口/枚举大驼峰（`CastPeerController`）；函数/变量小驼峰；常量全大写+下划线（`SSDP_ADDR`）。**DLNA 相关命名保留存档区原样，不再扩展。**
- **代码位置**：核心 `lib/core/`，数据 `lib/data/`，功能 `lib/features/`，Provider `lib/providers/`，共享 `lib/widgets/`。**DLNA 客户端模块 `lib/core/dlna/*`、`lib/providers/dlna_provider.dart` 已停用，仅存档，禁止在业务路径引用。**
- **语言**：UI 文本与代码注释统一中文。

### 1.5 内存红线

- 任何常驻 `Map`/`Set`/数组缓存**必须**带上限（FIFO/LRU）或清理机制（TTL/定期驱逐），禁止只增不删。
- 列表窗口化缓存：浏览过的旧块超窗即置空（见 §4.2）。
- 投屏状态轮询：每个远端 peer 的轮询定时器在切回本机/退出时必须 `dispose`，禁止泄漏（见 §3.3）。
- 封面/歌词缓存：按 LRU 或固定槽位上限。

### 1.6 构建约束（CI-only + 性能门槛）

**禁止在本地机器构建 APK 或 Windows 可执行文件**，一律走 GitHub Actions：

- 触发：push `main` 或 `workflow_dispatch`。
- Android：`ubuntu-latest` 签名 APK → `latest` 滚动 Release。
- Windows：`windows-latest` + `flutter build windows --release` → 便携 zip → 同一 Release。
- 产物：`MusicFlow-{run_number}-android.apk` + `MusicFlow-{run_number}-windows.zip`。
- 本地允许：`flutter pub get` / `flutter analyze` / `flutter test` / `dart run build_runner`；**禁止本地 `flutter build`**。
- **发布前 Windows 性能验收门槛**：见 §8.5（不达标视为未完成）。

---

## 二、与后端对接契约

> 契约以主项目 `docs/API.md` + `SPEC.md` 为准；下文摘录客户端必须遵守的部分。

### 2.1 接口面

| 面 | 前缀 | 用途 | 备注 |
|----|------|------|------|
| 原生 API | `/rest/api/v1/*` | 登录、曲库、播放/队列/peers、搜索、推荐、任务 | 客户端主要面 |
| OpenSubsonic | `/rest/*` | 兼容面（getAlbumList2/search3/stream/getCoverArt/getLyrics/scrobble…） | 兜底/老端点 |
| WebSocket | `/ws?token=` | 服务端推送播放状态、队列、设备/组变化 | 可选增强，见 §3.3 |

基址：`http://<host>:<port>`（主项目默认 46400；多服务器可配）。

### 2.2 鉴权链

登录：`POST /rest/api/v1/auth/login`，body `{ username, password }` → `{ token }`。

请求鉴权（任选其一，客户端用 Bearer JWT + token 参数兜底）：

| 方式 | 头/参数 | 适用 |
|------|---------|------|
| Bearer JWT | `Authorization: Bearer <token>` | 登录后 24h 有效，客户端主用 |
| Bearer API Key | `Authorization: Bearer <apiKey>` | 常驻客户端 |
| OpenSubsonic u/t/s | `?u=&t=&s=`（`t=md5(密码+盐)`） | Subsonic 兼容 |
| token 参数 | `?token=<jwt|apiKey>` | 流媒体 URL / WS |

> 鉴权链顺序（后端固定）：`X-API-Key → Bearer(JWT→API key) → X-ND-Authorization → OpenSubsonic 参数 → token 参数`。

### 2.3 响应与错误格式

- 业务 API：`{ "success": true, ...data }` 或 `{ "success": false, "code": <BusinessErrorCode>, "error": "中文可读信息" }`。
- 错误码枚举（`utils/errors.ts`）：`INVALID_PARAM` / `NOT_FOUND` / `CONFLICT` / `BUSY` / `FORBIDDEN` / `UPSTREAM_ERROR` / `INTERNAL`。
- 列表/包裹语义：`peers` → `{ "peers": [] }`；`groups` → `{ "groups": [] }`。
- OpenSubsonic：`{ "subsonic-response": { status:"ok"|"failed", version, type:"MusicFlow", ...payload } }`；失败错误码 40/50/70/10。
- **客户端禁止自定义第三种错误/响应格式**；解析任何响应都需容错（字段缺失回落默认值）。

### 2.4 状态机契约（对齐主项目）

**播放器状态**（`PlaybackState`）：

```
IDLE ⇄ PLAYING ⇄ PAUSED ⇄ BUFFERING
（BUFFERING 由 DLNA TRANSITIONING 映射；后端 PlaybackTracker 负责瞬态屏蔽）
```

- `GET /peers/:peerId/status` 中 `state` 为**设备原始 SOAP 状态**：`STOPPED / PLAYING / PAUSED_PLAYBACK / TRANSITIONING`（客户端按此映射 `active`/`playing`）。

**队列播放模式**：`order | one | all | shuffle`（仅这 4 值）。

**任务状态**：`running → ok|error`（异步导入/同步等，客户端轮询 `GET /rest/api/v1/tasks/:id`）。

**产品语义（对齐主项目）**：`stop` = 只停当前曲、队列保留；「关闭投屏」= 停止 + 清空队列。

---

## 三、播放架构与「切换播放器 / 后端 DLNA 控制」（重点）

### 3.1 播放架构：本机 vs 远端 peer（对齐前端 `player.ts`）

客户端维护两个独立状态机，由 `currentPeerId` 决定 UI 显示/控制目标：

- **本机（`local:<uid>`）**：`player_provider` + just_audio 本地播放；队列元数据经 `POST /peers/register` + `/queue/play`、`/queue/index` 同步给后端（后端只存元数据，不播）。
- **远端（`dlna:<id>` / `group:<id>` / `airplay:<id>`）**：后端 `QueueController` 向设备投流（`Stop → SetAVTransportURI(/rest/dlna/stream/:token) → waitForCanPlay → Play`）；客户端只做控制 + 状态轮询（`cast_peer_provider`）。

```
用户操作 → 当前 peer 目标 → CastPeerController（远端）/ PlayerController（本机）
                                     ↓
                          后端 /rest/api/v1/peers*（后端推流 + 队列自治）
```

### 3.2 peers 完整 API 契约（客户端唯一投屏面）

> 路径均省略 `/rest/api` 前缀。`peerId` 需 `encodeURIComponent`。权限见 §3.5。

| 用途 | 方法/路径 | 请求 | 响应/说明 |
|------|-----------|------|-----------|
| 播放器列表 | `GET /peers` | – | `{peers:[{peerId,kind,name,available,lastActiveAt,queue:{items,currentIndex,playMode,isActive,ended}}]}`；排序：本机→DLNA/AirPlay→群组 |
| 注册本机 | `POST /peers/register` | `{name?}` | `{peer}`；客户端启动/登录后必须调用，否则本机 peer 不存活 |
| 保活 | `POST /peers/:peerId/heartbeat` | – | 周期性（≤1min）调用；后端 10min 无心跳清队列并置不可用 |
| 状态 | `GET /peers/:peerId/status` | – | `{state,position,duration,volume,muted,media,updatedAt}` |
| 队列快照 | `GET /peers/:peerId/queue?offset&size` | – | `{...snapshot, items(分页), total, currentMedia}`；`currentIndex` 为绝对下标 |
| 推队列并播 | `POST /peers/:peerId/queue/play` | `{items:[QueueItem], startIndex?}` | 远端=后端投流；本机=仅持久化队列，客户端自行起播 |
| 追加队列 | `POST /peers/:peerId/queue/enqueue` | `{items}` | 不打断当前播放 |
| 跳播点歌 | `POST /peers/:peerId/queue/jump` | `{index}` | 随机模式下也尊重 index（随机只作用于后续自动续播） |
| 播放模式 | `POST /peers/:peerId/play-mode` | `{mode: order|one|all|shuffle}` | 4 值内切换 |
| 上报当前序号 | `POST /peers/:peerId/queue/index` | `{index}` | **仅本机 peer**；本机切歌时回写后端 |
| 队列去激活 | `POST /peers/:peerId/queue/deactivate` | – | 停止投屏但保留队列（供恢复） |
| 清队列 | `DELETE /peers/:peerId/queue` | – | |
| 删单条 | `DELETE /peers/:peerId/queue/:index` | – | 删当前项则自动播下一首 |
| 重排 | `POST /peers/:peerId/queue/reorder` | `{from,to}` | 拖拽排序 |
| 播放 | `POST /peers/:peerId/play` | – | 远端=恢复/起播；本机=no-op（客户端自治） |
| 暂停 | `POST /peers/:peerId/pause` | – | |
| 停止 | `POST /peers/:peerId/stop` | – | 只停当前曲，队列保留 |
| 下一首 | `POST /peers/:peerId/next` | – | |
| 上一首 | `POST /peers/:peerId/prev` | – | |
| 跳转 | `POST /peers/:peerId/seek` | `{seconds}`（兼容 `position`） | |
| 音量 | `POST /peers/:peerId/volume` | `{volume: 0-100}` | |
| 播报 | `POST /peers/:peerId/announce` | `{url, volume?, blocking?}` | 可选（TTS 场景），默认非阻塞 |

**QueueItem 形状（`songToQueueItem`，与主项目前端一致）**：

```json
{ "songId": "<song.id>", "title": "<title>", "artist": "<artist>",
  "album": "<album>", "albumId": "<albumId>", "mime": "audio/mpeg",
  "coverArt": "<coverArt|al-<albumId>>", "duration": <秒> }
```

> **DLNA 设备专属端点**（`/v1/dlna/*`）存在但客户端**不作为主路径**；仅保留 `POST /rest/api/v1/dlna/scan`（面板「扫描设备」触发，见 §3.5）。

### 3.3 状态轮询与平滑进度（对齐前端）

- **轮询节奏**：远端 peer 每 **2s** 轮询 `GET /peers/:peerId/status` + `GET /peers/:peerId/queue`；队列快照用于回写 `currentIndex`，让 UI 曲目/歌词跟随设备。
- **平滑进度**：主项目前端用 **250ms tick** 在两次 2s 轮询间本地插值推进进度条，轮询结果修正漂移。客户端已实现同款插值（250/500ms tick + 轮询回写修正，`cast_peer_provider._advanceSmooth`）。
- 轮询期间对远端 peer 执行控制命令后应立即 `pollOnce()` 刷新，避免 UI 滞后。
- 定时器生命周期：`dispose`/`backToLocal`/退出时全部取消（§1.5 内存红线）。
- **WS 增强（可选）**：订阅 `/ws?token=` 播放状态/队列/设备事件，REST 轮询降为兜底（主项目前端已用 WS）。

### 3.4 权限模型

- **admin**：可见/可控全部 peer（本机 + DLNA + 群组 + AirPlay）。
- **普通用户**：仅可见/可控 `local:<uid>`（后端强制），其他 peer 一律 403。客户端面板自然呈现（普通账号只有本机一项，属预期）。

### 3.5 后端 DLNA 控制：完成项 vs 待办（本功能「一直没做完」的差距清单）

> 依据：`lib/providers/cast_peer_provider.dart` 现状 vs 主项目 `stores/player.ts` + 后端 `/rest/api/v1/peers*` 契约。**v3 将下面「待办」列为必须补齐项**，逐项对应 §3.2 契约。

**已完成（现状，保持）**：

- [x] 面板列表 `GET /peers`（含 kind/available/queue 摘要展示）
- [x] **切到远端 = 纯 UI 控制目标切换**（对齐前端 `switchPeer`）：只改控制目标，**不推本地队列、不自动投屏**；选中远端后启动 2s 轮询（自适应退避：失败翻倍至 15s，成功回落 2s）拉取其队列，UI 镜像设备当前播放。此后点歌/专辑/歌单经 `playQueueOnPeer`/`playSongOnPeer` 命令**后端**在设备播放 —— 客户端此时是后端的**远程遥控器**。离开本机时保存本地状态快照并暂停本机（移动端避免双音频，§3.1），回本机 `backToLocal` 恢复快照（远端继续播放）。
- [x] 播放/暂停/上一首/下一首/seek/音量/静音 经 `POST /:peerId/{play|pause|next|prev|seek|volume|mute}`（本机走 just_audio）
- [x] 2s 轮询 `/status` + `/queue` 并回写 `currentIndex`（后端权威队列镜像到本地，迷你条/歌词/相邻关系跟随设备）
- [x] **平滑进度**：250ms（桌面 500ms）tick 插值 + 轮询回写修正（§3.3）
- [x] 迷你条「切换播放器」入口 + 面板（含 `POST /rest/api/v1/dlna/scan` 扫描）
- [x] 反馈三要素：面板 ✓ 高亮 / 入口投屏态变色+设备名 / 切换成功&失败 toast
- [x] **注册与保活**：登录后 `POST /peers/register` + 每 30s `POST /peers/:peerId/heartbeat`
- [x] **回本机语义对齐**：`backToLocal`（仅切换控制目标，远端继续播放）vs `stopCasting`（`stop`+`queue/deactivate` 停止设备）
- [x] **播放模式同步**：`POST /:peerId/play-mode` 下发 + 轮询回读；`cyclePlayMode` 循环切换（order→one→all→shuffle）
- [x] **投屏中加歌/点歌**：`queue/enqueue`（加歌）/ `queue/jump`（跳播点歌）/ `playQueueOnPeer`（整队）/ `playSongOnPeer`（单曲）
- [x] **队列编辑**：`DELETE /queue/:index`（删单条）+ `queue/reorder`（拖拽排序）
- [x] **离线/被移除处理**：连续 3 次轮询失败置 `offline`，切回/移除时停止定时器（§1.5 内存红线）
- [x] **群组/AirPlay 差异化**：面板按 kind 区分图标/标签（群组/离线）
- [x] **投屏失败/设备忙**：`queue/play` 失败返回 false，保持本机，不残留投屏态

**待办**：

- [ ] （当前 §3.5 已全部对齐完成；若主项目 `stores/player.ts` 行为变化，以主项目为基准回校）

---

## 四、曲库与长列表加载（对齐前端 `useInfiniteList`）

### 4.1 服务端分页契约（全库强制）

- 曲库列表统一走原生分页：`GET /rest/api/v1/{songs|albums|artists|playlists}`，参数 `page` / `pageSize`(≤200) / `query`；歌单曲目 `GET /rest/api/v1/playlists/:id/tracks`。响应 `{ total, page, pageSize, items }`。
- **禁止一次全表拉取后前端过滤**。例外：收藏页等无分页端点的场景（`getStarred2`）允许一次拉取 + 虚拟化渲染。
- 本地搜索 = 把关键词透传 `query`（服务端过滤），不做全量前端过滤。
- 排序仅提供后端支持的档位（歌曲：标题 A-Z / `recentAdded` 等）。

### 4.2 窗口化虚拟滚动（与主项目前端同构）

- 渲染层只构建视口内（含 `cacheExtent`）的行；数据层 `WindowedPaginatedList<T>`（全长稀疏槽位缓存 + 按块预取 + 窗口外剪枝）+ UI `WindowedListView<T>`（列表/网格双形态）。
- **参数对齐前端 `useInfiniteList`**：`chunk`（每块页大小）、`keepRows`（窗口保留行数）、`prefetchBlocks`（预取块数）、`concurrency`（并发请求数）。若与前端行为不一致，以前端为准。
- 视口渐进式加载：builder 触达行号即推进预取窗口（`ensureRange`，帧末调度避免同帧 notify）；未到达槽位渲染骨架占位。
- 常驻缓存带上限/剪枝；旧块超窗置空（§1.5）。

### 4.3 聚合/插件搜索与本地列表互斥

- 聚合搜索走 §五 的 entity-search 端点，与本地曲库列表互斥展示（不同 tab/入口），不得混在一个列表。

---

## 五、搜索与在线音乐

### 5.1 聚合搜索（对齐主项目）

- `POST /rest/api/v1/{song|album|artist|playlist}-search/aggregate/search`，body `{ q, sources? }` → `{ total, providers, items }`；条目带 `providerId / providerName / platformLabel`。
- 单插件搜索：`POST /rest/api/v1/{...}-search/:providerId/search`（可选）。
- 在线歌单搜索：`POST /rest/api/v1/playlist-search/aggregate/search`。

### 5.2 在线直接播放（免入库）

- 搜索结果可直播：本机走 `/rest/stream-remote?provider&source&id&...`（代理流，带 `token` 参数）；**投屏到远端必须先入库拿真实 DB `songId`**（对齐主项目：`song-search/:pid/import` → 任务轮询 → 用 fingerprint 精确映射再 `queue/play`）。

### 5.3 入库导入与任务轮询

- 导入：`POST /rest/api/v1/song-search/:pid/import`，body `{ songs:[{source,id,name,artist,album,duration,cover}] }` → 立即返回 `{ taskId }`（异步）。
- 任务轮询：`GET /rest/api/v1/tasks/:id`（对齐主项目 `waitAsyncTask`，间隔 ~800ms）；完成返回 `{ result: { success, imported:[{fingerprint,id}], ids } }`。

---

## 六、首页推荐与每日推荐

- 首页卡片：`GET /rest/api/v1/recommend/home-cards`；每日推荐：`GET /rest/api/v1/daily-recommend`；本地推荐：`GET /rest/api/v1/recommend/local`；推荐导入：`POST /rest/api/v1/online/:providerId/recommend/import` / `recommend/sync-all`。
- **首页展示内容与交互以现有 Android/Windows 实现为基准，不得改版**（§1.1 / §7.3）。

---

## 七、UI 与页面

### 7.1 设计方向

- **交互体验对标网易云音乐 / QQ 音乐**（用户明确要求）：播放器主流程（迷你播放条 → 全屏播放器 → 队列面板 → 播放器切换）的操作手感、层级动效、卡片/列表呈现方式参考主流音乐 App，做到「所见即所得、可盲操」。
  - **网易云**：黑胶唱片全屏播放器 + 滚动歌词 + 左右滑动手势（上一首/下一首）、迷你条常驻底部 + 封面旋转。
  - **QQ 音乐**：首页信息流式卡片 + 横向滑动区块、播放页下滑收起、列表页点歌即播 + 播放态高亮。
  - **落地清单**（以下交互为必做，其余以现有实现为准）：
    1. 迷你播放条：常驻底部，封面缩略图 + 标题/歌手 + 播放/暂停 + 队列 + 投屏（切换播放器）入口；手机端定版两键（§7.4）。
    2. 全屏播放器：黑胶唱片动画 + 歌词滚动跟随 + 拖动进度 + 音量；支持下滑/返回收起；投屏态显示设备名。
    3. 队列面板：从底部弹出，当前曲高亮 + 播放模式切换 + 拖拽排序 + 点歌即播；投屏态经后端队列 API 操作（§3.5）。
    4. 播放器切换页：设备列表（本机/DLNA/群组/AirPlay）+ 当前播放设备高亮 + 设备状态摘要（§3.2）。
    5. 列表页点歌即播 + 当前曲整行高亮 + 封面旋转动效（桌面 hover 播放按钮，手机点击即播）。
    6. 全局操作反馈：toast / 播放入口 loading / 投屏成功与失败提示（§3.5 反馈三要素）。
- **整体样式对标网易云音乐**（用户明确要求，覆盖全局视觉基调）：
  - **主题色**：以网易云品牌红为强调色（参考 `#EC4141` / `#C20C0C` 区间，落地到 `EchoDesign` 色板）；暗/亮双主题，暗色底 + 品牌红强调。
  - **默认强调色切换（必改）**：现 `EchoColors.echoAccent = #3B8258`（绿）不符合网易云基调，须将默认强调色改为网易云红（建议 `#EC4141`），亮暗主题同源；旧绿仅保留为可选「主题色」之一（设置页可切换），不得作为默认。
  - **黑胶唱片元素**：播放器/迷你条/列表封面统一使用黑胶唱片视觉语言（圆盘 + 封面 + 旋转动效），作为全局品牌符号。
  - **卡片与列表**：圆角卡片 + 细腻 hover 上浮；封面 1:1 网格；歌单/专辑卡「标题 + 数量副标 + 悬浮播放按钮」；当前播放曲目整行品牌红高亮。
  - **留白与字重**：大标题粗体（700）、正文常规；区块间留白克制；避免花哨渐变/重投影（与 §8 Windows 性能约束兼容，视觉达标 + 渲染达标两者兼得）。
  - 设计系统沿用 `EchoDesign` 常量；**禁止在 UI 硬编码颜色/字号**（§10 #5）。

### 7.2 布局适配

| 屏幕宽度 | 布局 |
|----------|------|
| < 600dp | 单列 + 迷你播放条 |
| 600–839dp | 中屏：紧凑导航轨 + 迷你播放条 |
| ≥ 840dp | **Windows 布局**：左侧栏（音乐流 + 曲库入口：艺术家/专辑/歌曲/歌单/喜爱）+ 内容区 + 宽播放条（进度/音量/投屏态） |

### 7.3 核心页面

1. **登录页**：多服务器管理，地址/账号/密码，连接检测。
2. **首页（发现）**：最近添加 / 每日推荐 / 快捷入口等。**展示内容与交互逻辑以现有实现为基准，作为标杆保留；只允许修复性能与 bug，不允许改版。**
3. **曲库页**：歌曲 / 专辑 / 歌手 / 风格 / 歌单 / 收藏（全部走 §四 窗口化加载）。
4. **搜索页**：本地 + 在线聚合搜索（§五）。
5. **播放页**：黑胶唱片 + 歌词 + 控制 + 队列。
6. **播放器切换页**：`/peers` 面板（§3.2/§3.5）。
7. **设置页**：主题 / 音质 / 服务器 / 关于。

### 7.4 播放器设计

- **迷你播放器**：底部条（对标网易云/QQ）；封面缩略图 + 标题/歌手 + 播放/暂停 + 队列 + 投屏（切换播放器）。手机端迷你条定版两键（不放上一首/下一首，切歌在全屏/队列面板）。
- **全屏播放器**：黑胶唱片动画 + 歌词滚动 + 进度条 + 控制 + 音量；支持下滑/返回收起；支持投屏态显示（设备名）。交互对标网易云（左右滑切歌、歌词跟随）。
- **队列面板**：可拖拽排序、播放模式切换、当前曲高亮、点歌即播；投屏态下经 `queue/jump`/`queue/reorder`/`queue/:index` 操作后端队列（§3.5）。

---

## 八、Windows 桌面端渲染性能约束（重点新增）

> 背景：Windows 无 Impeller，走 Skia；高成本特效（大 blur 阴影、旋转渐变、整页过渡、BackdropFilter）与高频重建是卡顿/渲染差主因。**以下为硬性约束，违反视为未完成。**

### 8.1 高成本特效与降级

- **黑胶唱片**（`vinyl_record_cover.dart`）：`Transform.rotate` + `BoxShadow(blurRadius:20)` + 径向渐变，播放时每帧全量重绘。
  - 约束：`BoxShadow` 大 blur 在 Windows **必须降级**（缩小 blur / 用描边代替 / 关闭阴影）；
  - 动画在**窗口失焦/最小化/非全屏播放器时暂停**；`MediaQuery.disableAnimations` 或 `reduceMotion` 开启时完全静态；
  - 旋转区域包裹 `RepaintBoundary`。
- **播放器背景**（`player_backdrop.dart` `_ensureBackdropContrast`）：build 内 22 次二分 × 2 目标的对比度计算。
  - 约束：**禁止在 build/布局阶段做高开销计算**；改为缓存（同封面色缓存）、预计算到 isolate，或固定对比度方案。
- **页面过渡**（`echo_page_route.dart`）：全页面 Fade+Slide（300ms）+ 全屏 Hero。
  - 约束：Windows 上关闭 Slide 位移或改为 Fade-only / 缩短时长；避免大面积 `ClipRRect` + 阴影 + 动画叠加。
- **BackdropFilter / ImageFilter.blur**：全局禁止（已在代码中移除的保持移除），新增必须说明理由并获 ray 确认。

### 8.2 高频重建与帧预算

- **播放进度**（`player_scrubber.dart`）：播放中 `positionStream` → Provider → Widget 高频重建。
  - 约束：进度更新**节流 ≥250ms**（与投屏 tick 对齐）；进度条 slider 区域 `RepaintBoundary` 隔离，避免整页重建。
- **build() 纪律**：禁止在 `build` 中发起网络/DB/高开销计算（§10 #7）；复杂子组件用 `const` / `RepaintBoundary` 隔离。
- 投屏进度插值 tick（250ms）与本地进度更新不得在页面 `build` 内驱动全局重建。

### 8.3 图片与解码

- 封面请求一律带 `size` 预算（对齐主项目 `coverUrl(id, 300)` 思路），禁止请求超尺寸原图；
- 全屏背景图解码后按显示尺寸缩放，禁止大图直接上屏；解码缓存带上限（§1.5）。

### 8.4 音频后端选型（Windows）

- **唯一后端 = `just_audio_media_kit`（media_kit/libmpv）+ `media_kit_libs_windows_audio`**（现状即此）；`just_audio_windows` 若无明确用途，**需验证后移除**（避免双后端竞态）。
- 验证项（发布前必须）：libmpv 音频输出延迟参数、切歌输入延迟、`just_audio_background`（beta）与 media_kit 在 Windows 的兼容性；`audio_service` 桌面端适配。
- 本机播放与投屏互斥：投屏后本机暂停并停流（§3.1），避免双实例抢音频设备。

### 8.5 发布前 Windows 性能验收门槛（CI 产物发布前必过）

| 指标 | 门槛 |
|------|------|
| 首页/曲库滚动 | 帧率稳定 ≥45fps（profile 构建，滚动 5s 无掉帧卡顿） |
| 页面切换 | 点击导航 → 页面可交互 ≤300ms（transition 期间无白屏/闪烁） |
| 播放器操作 | 播放/暂停/切歌/拖动进度，UI 响应 ≤200ms（不因进度重建卡顿） |
| 长列表（万级曲库） | 滚动流畅，内存平稳（窗口剪枝生效，无持续上涨） |
| 投屏控制 | 状态轮询与进度插值不引发 UI 卡顿；切回本机无残留定时器 |

验收方式：Windows 机器 `flutter build windows --profile` 实测（本地调试允许 profile 构建；发布产物仍走 CI release）。未附验收数据视为未完成。

---

## 九、测试规范

### 9.1 单元测试（按仓库实际文件清单）

| 模块 | 测试文件 | 重点 |
|------|----------|------|
| 投屏控制 | `test/providers/cast_peer_provider_test.dart` | peers 列表/切换/轮询/回本机/待办项（§3.5） |
| 播放队列 | `test/providers/player_provider_test.dart` | 队列、切歌、播放模式、投屏互斥 |
| 数据源 | `test/data/sources/subsonic_api_client_test.dart` | 鉴权注入、响应解析、错误处理 |
| 数据源 | `test/data/sources/music_repository_test.dart` | 分页解析、窗口化切片 |
| 模型 | `test/data/models/*_test.dart` | Freezed 序列化、`songToQueueItem` 形状 |
| 工具 | `test/utils/*_test.dart` | 时间/字符串/列表工具 |
| 列表 | `test/features/library/windowed_*_test.dart` | 窗口化预取/剪枝 |

> 旧 SPEC 所列 `test/dlna/*`、`test/data/subsonic_api_test.dart`、`test/providers/queue_test.dart` 与仓库不符，已按实际替换。**新增/修改逻辑必须附测试。**

### 9.2 集成测试

- 连接真实 MusicFlow 实例：登录 → 浏览曲库 → 搜索 → 播放 → 收藏；
- 投屏链路：`/peers` 列表 → `dlna/scan` → 切到 DLNA → 播放/暂停/切歌/音量/播放模式 → 点歌/加歌 → 切回本机；
- 权限：普通账号面板仅本机一项。

### 9.3 构建门槛

- `flutter analyze` 0 错误；`flutter test` 全绿；
- APK / Windows 可执行文件只在 CI 构建（§1.6）；Windows 性能验收（§8.5）达标。

---

## 十、负面清单（优先级最高）

> AI 动手前逐条默读；交付时逐条确认「未违反」。本清单优先级高于任何口头需求——冲突时先问。

1. **禁止**引入未授权新依赖或升级依赖版本；移除依赖（azlistview/lpinyin/marquee/just_audio_windows 等）需 ray 确认。
2. **禁止**修改主项目（`/workspace/_MusicFlow-main` 等参考副本）任何文件；主项目只读。
3. **禁止**重构未指明的模块（换框架、大规模抽公共层）；重构必须由 ray 显式下达。
4. **禁止**客户端自行实现 SSDP/SOAP/推流/HTTP 中继；投屏一律走后端 `peers*` API。`lib/core/dlna/*` 仅存档，禁止业务引用。
5. **禁止**在 UI 硬编码颜色/字号——必须用 `Theme.of(context)` / `EchoDesign` 常量。
6. **禁止**一次加载全表后前端过滤——所有列表走 §四 窗口化/分页。
7. **禁止**在 Widget `build()` 中发起网络/DB/高开销计算（含播放器背景对比度二分）。
8. **禁止**在 catch 块吞异常——必须打日志含上下文。
9. **禁止**删除/修改已有测试文件——只新增（行为契约变更时先向 ray 报备再更新）。
10. **禁止**私自提交 / push / 打 tag；**禁止把 `/workspace/_MusicFlow-main` 或构建产物提交入库**（交付前 `git status` 核对）。
11. **禁止**任何列表绕过 §4.2 窗口化加载（新增列表必须接 `WindowedPaginatedList` + `WindowedListView`）。
12. **禁止**在 Windows 引入/保留导致卡顿的高成本特效（§8.1）与未节流的高频重建（§8.2）。
13. **禁止**在本地机器执行 `flutter build`（apk/windows 等）；构建产物只由 CI 产出。
14. **禁止**为旧版 DLNA 模块编写/维护轮询（`Future.delayed`/`Timer` 单发递归轮询）——新代码统一用 `Timer.periodic`/`Stream.periodic` 且 dispose。

---

## 十一、AI 自检清单（交付前逐项勾选）

```
□ 1. 负面清单（§十）14 条逐条确认未违反
□ 2. 仅修改任务指定文件；未波及无关代码；未把 /workspace/_MusicFlow-main 入库（git status 核对）
□ 3. flutter analyze 0 错误
□ 4. 新增/修改逻辑的测试已编写并通过；相关回归全绿
□ 5. 未引入新依赖、未升级依赖版本
□ 6. 新增常驻 Map/Set/缓存/定时器均带上限或清理机制（含投屏轮询 dispose）
□ 7. 所有 catch 均打日志含上下文，无吞异常
□ 8. 未改变既有行为契约（路径/返回结构/错误码/success 语义）
□ 9. 未改首页（发现页）的展示内容与交互逻辑（§1.1/§7.3 基准）
□ 10. Windows 渲染约束（§八）已落实：特效降级 / 进度节流 / 音频单后端
□ 11. 未提交 / 未 push / 未打 tag（除非 ray 明确要求）
□ 12. 新代码使用统一错误处理与日志规范，未裸造错误体/裸 console
```

---

## 附：开发工作流

```bash
# 安装依赖
flutter pub get

# 代码生成（修改 Freezed/Drift/Riverpod 后必须运行）
dart run build_runner build --delete-conflicting-outputs

# 分析 / 测试
flutter analyze
flutter test

# 构建：禁止本地执行！必须通过 GitHub Actions CI 构建。
# 触发方式：push 到 main 分支 或手动 workflow_dispatch。
# Windows 性能验收：本地 profile 构建实测（§8.5），发布产物仍走 CI release。
```
