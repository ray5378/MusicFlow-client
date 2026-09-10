# MusicFlow-client 技术契约规范（SPEC）

> 本文件是 MusicFlow-client 仓库内 **AI 协作者必须遵守的技术契约**。任何改动（新功能 / 修 bug / 重构）都必须先对照本规范划定边界。
>
> 版本：v3（2026-08-23，全量重写）｜ 维护：ray（仓库 owner）｜ AI 改动本文档需经 ray 确认
>
> **v3 重写要点**：
> - **全量对齐主项目后端**：客户端是 MusicFlow 主项目（`ray5378/MusicFlow`，Node/TS 后端 + Vue 前端）的全量客户端，接口面、数据契约、行为表现一律以主项目为准。
> - **DLNA 由后端推送（链路 A）**：「切换播放器」投屏走主项目 `/rest/api/v1/peers*` 统一控制面，由后端 `QueueController` 向 DLNA/AirPlay/群组设备投流，客户端不自行 SSDP/SOAP/推流、仅做控制面。**（链路 B 例外见 v3.1 记录 + §3.6。）「控制后端 DLNA 播放」是当前未完成功能，v3 给出完整契约与完成项清单（§3）。**
> - **交互对标网易云 / QQ 音乐**：播放器主流程交互体验（迷你条 → 全屏 → 队列 → 切换播放器）参考主流音乐 App（§7.1）；首页（发现页）内容与交互保持现有实现为基准。
> - **Windows 渲染性能成为硬性契约**：新增「§八 Windows 桌面端渲染性能约束」，把特效降级、高频重建、音频后端选型、发布前性能验收写死，治理 Windows 卡顿与渲染差。
> - **修复旧版硬伤**：API 端点体系统一（删除三套并存）、DLNA 存档区清理、测试清单按仓库实际重列、基础库依赖表按 pubspec 实测修正、目录结构按现状更新。
> - **v3.1 修订（用户/ray 确认，2026-08-26）**：新增**链路 B「局域网 DLNA 直投」**——Android/Windows 客户端**自行 SSDP 发现 + SOAP 控制 + 本地中继推流**到局域网 DLNA 设备（支持投屏队列自动续播），与现有「切换播放器」（**链路 A**，后端投屏、客户端仅遥控）**完全独立并存**。详见 §1.1 / §3.6 / §10。
> - **v3.2 修订（用户/ray 确认，2026-08-27）**：**砍掉链路 B 的本地中继与本地 HttpServer 推流**，回归标准 DLNA 分工——客户端仅作 **Control Point（遥控器）：进度显示 / 遥控操作 / 播控中心**；把**服务端直连流 URL** 交给 DLNA 设备，设备作为 **DMR 自拉流**。

---

## 一、定位、技术栈与工程约束

### 1.1 定位

- 本仓库是 **MusicFlow 主项目后端的全量客户端**（Flutter），首发 **Windows + Android**，后续扩展 iOS/鸿蒙/Web。
- 客户端消费主项目三套接口面：**原生 API**（`/rest/api/v1/*`）、**OpenSubsonic**（`/rest/*`）、**WebSocket**（`/ws`）。
- 播放目标统一抽象为 **peer**（本机 `local:<uid>` / DLNA `dlna:<id>` / 群组 `group:<id>` / AirPlay `airplay:<id>`）。**链路 A（切换播放器）投屏一律由后端推流**，客户端只做控制面（§3）。
- **链路 B（局域网 DLNA 直投，§3.6）例外**：Android/Windows 客户端允许**自行 SSDP 发现 + SOAP 控制**到局域网 DLNA 设备，支持投屏队列自动续播；**客户端不做本地中继/推流**（v3.2 起），只把**服务端直连流 URL** 交给设备，让设备**自拉流**，客户端仅遥控。链路 B 与链路 A **完全独立**，状态/设备/控制互不并入。
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
| 图片 | palette_generator（配色提取）；封面走 `Image.network` 直连 | **禁止任何图片缓存**（磁盘/内存/解码缓存一律不保留，见 §1.5 / §8.3）；`cached_network_image` 仅作候选，**当前不启用其缓存能力** |
| 工具 | crypto / uuid / path / path_provider / share_plus / package_info_plus / url_launcher / connectivity_plus / permission_handler | |
| 列表增强 | scrollable_positioned_list（队列滚动定位）、animations | |
| 遗留待清理 | azlistview / lpinyin / marquee | v2 已移除 A-Z 索引且 marquee 无使用，**确认无用后从依赖移除** |

> **依赖纪律**：任何新增/删除依赖必须向 ray 报备并获确认（§10 负面清单 #1）。`freezed_annotation`/`freezed` 以 `^3.1.0` 为准（旧 SPEC 的 `^2.4.4` 已过时）。

### 1.3 对齐原则（最高优先级）

- **客户端必须对齐主项目**：接口参数、数据结构、行为表现均以主项目为准；主项目前端 `stores/player.ts`（peer/队列/投屏状态机）、`composables/useInfiniteList.ts`（列表窗口化）是行为基准。
- **主项目只读，禁止修改**。主项目参考源码可克隆为本地只读工作副本（如 `/workspace/_MusicFlow-main`），**该目录严禁提交/入库**（交付前 `git status` 核对，见 §10 #10）。
- **唯一例外**：某功能不修改主项目无法实现时，必须先向 ray 说明原因并获明确确认，未确认前只能在客户端变通。
  **当前无生效的只读例外**，对主项目任何改动均须照常先报备获确认。

### 1.4 硬性工程约束

- **依赖管理**：严禁引入未授权的新第三方库、严禁升级现有依赖版本。缺能力 → 先说明理由，等确认。
- **命名规范**：文件/目录全小写+下划线（`cast_peer_provider.dart`）；类/接口/枚举大驼峰（`CastPeerController`）；函数/变量小驼峰；常量全大写+下划线（`SSDP_ADDR`）。**链路 B 的 DLNA 命名沿用 `lib/core/dlna/*` 现有命名，不再扩展。**
- **代码位置**：核心 `lib/core/`，数据 `lib/data/`，功能 `lib/features/`，Provider `lib/providers/`，共享 `lib/widgets/`。**链路 B 业务模块：`lib/core/dlna/*`（SSDP/描述/SOAP/直传）+ `lib/providers/cast/dlna_provider.dart`，供链路 B 引用；禁止在链路 A（`cast_peer_provider` 等）路径引用，两者命名/命名空间保持独立。**
- **语言**：代码注释统一中文；面向用户的 UI 文本**必须**走 l10n（loc.xxx / l10nNow），禁止硬编码中文（见第十章国际化契约）。

### 1.5 内存红线

- 任何常驻 `Map`/`Set`/数组缓存**必须**带上限（FIFO/LRU）或清理机制（TTL/定期驱逐），禁止只增不删。
- 列表窗口化缓存：浏览过的旧块超窗即置空（见 §4.2）。
- 投屏状态轮询：每个远端 peer 的轮询定时器在切回本机/退出时必须 `dispose`，禁止泄漏（见 §3.3）。
- 链路 B 投屏：**v3.2 起无本地中继/推流**，设备直连服务端自拉流；客户端仅保留轮询/看门狗定时器，停止/退出时全部 `dispose`，不得泄漏（见 §3.6）。
- **封面图片一律禁止缓存**（v3.4 起，ray 确认）：不写磁盘缓存、不驻留内存解码缓存，图像处理缓存（`ImageCache`）需显式收紧上限并在内存紧张时清理；封面每次直连 `getCoverArt` 拿图，避免冷启动/滚动时缓存抖动与陈旧封面。
  - 歌词缓存不受此限，仍按 LRU 或固定槽位上限。

### 1.6 构建约束（CI-only + 性能门槛）

**禁止在本地机器构建 APK 或 Windows 可执行文件**，一律走 GitHub Actions。

**为什么必须 CI-only（安卓签名硬约束，不可绕过）**：
- 安卓只允许**同一签名证书**的应用覆盖安装（升级）。正式签名 keystore 只存在于
  仓库 Secrets（`ANDROID_KEYSTORE_BASE64` 等），CI 的 `Decode signing keystore`
  → `flutter build apk --release` 步骤用它签出 release APK。
- 本地机器**没有** keystore，本地构建的 APK 要么未签名、要么用 debug 签名，
  装不上到已安装的正式版上（签名冲突）。因此**任何发到 GitHub Release 的产物
  必须由 Build Client workflow 构建**——AI/开发者的职责只是打 tag 并推送，
  构建与发布完全交给 CI。

**发版规则（纯 tag 驱动，唯一发版体系）：**
- **触发**：仅**版本 tag**（`vX.Y.Z`）触发构建与发布；不再监听 `main` 推送、删除滚动/`latest` 预发布、也无 `workflow_dispatch`。即 **push main 不产生任何构建**，强制所有发版走 tag。
- **版本号来源**：**只以 tag 为准**（tag `v3.3.0` → 应用版本 `3.3.0`）。由 `resolve-version` job 提取并注入 `flutter build --build-name/--build-number`，覆盖 `pubspec.yaml` 中无语义占位版本号。**发版时严禁改动 `pubspec.yaml` 版本号。**
- **拒绝非 tag**：非 tag 触发时 `resolve-version` 直接报错退出，保证纯 tag 体系不被绕过。
- **发布**：`build-android`（签名 APK）+ `build-windows`（Inno Setup 单文件安装包）→ `publish-versioned` 发布正式 GitHub Release（`releases/latest` 只指向最新正式版）。
- Android：`ubuntu-latest` 签名 APK。
- Windows：`windows-latest` + `flutter build windows --release` → Inno Setup 打包为单文件 `setup.exe`（**不再发布绿色版 zip**，2026-09-10 起）。
- 产物：`MusicFlow-<tag>-android.apk` + `MusicFlow-<tag>-windows-setup.exe`。
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

- **本机（`local:<uid>`）**：`player_provider` + just_audio 本地播放；客户端仅 `POST /peers/register` + 30s heartbeat 保活本机 peer（对齐主项目 registerLocalPeer/startHeartbeat）；本机队列/播放**不推送后端**（本地自治），切回本机经本地状态快照恢复（§3.5）。
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

### 3.6 链路 B：客户端本地 DLNA 直投（独立副轨道，v3.1 新增 / v3.2 修订 / **v3.2.1 收敛为单档位**）

> 背景：链路 A（§3.1–§3.5）由后端推流、客户端只是遥控器。链路 B 让 **Android/Windows 客户端自行发现并直连局域网 DLNA 设备**，与服务器控制面解耦。两条链路**完全独立、互不并入**（状态/设备/控制互不写对方 Provider）。

**能力边界**：
- 首发平台 Android + Windows；实现只依赖 `dart:io`（`RawDatagramSocket` / `HttpClient` / `Socket`），**零新增第三方依赖**（仅允许自写原生 MethodChannel + manifest 权限）。**v3.2 起不再启用本地 HTTP 服务器/流式中继（已删除 `local_relay.dart`）。**
- 复用模块（保持命名不变）：`lib/core/dlna/ssdp_discovery.dart`、`device_description.dart`、`soap_control.dart`、`dlna_manager.dart`、`dlna_didl.dart`、`dlna_models.dart` + `lib/providers/cast/dlna_provider.dart`。

**传输方式（标准 DLNA 角色分工：客户端/Control Point、设备/DMR 自拉流）**：

1. **直传**：`Stop → SetAVTransportURI(服务端直连流 URL + DIDL-Lite) → Play`，设备用自己的网卡直连 `getStreamUrl(songId, token, 品质)` **自拉流**，客户端只遥控。**自动续播**：优先 `SetNextAVTransportURI` 预置下一曲（`probeEnqueueSupport`），不支持则用**墙钟看门狗**兜底——设备对 RawHTTP 常报 `duration=0/position=0`，故以 `DlnaCastTrack.duration`（真实时长）+ 累计 `_playbackElapsed` 判定曲末自动推进 `_queueIndex` 并续投下一曲；曲中段连续异常停止（≥2）判失败自动跳过，连续失败达上限（8）停止；`_lastCompletionAdvance` 互斥防轮询/看门狗双触发重复跳曲。
2. **设备发现**：客户端主动 SSDP `M-SEARCH` + 被动 `NOTIFY`（`ssdp_discovery.dart` 已实现）；Android 需持 **`MulticastLock`**（自写 MethodChannel acquire/release）；Android 13+ 按需申请 **`NEARBY_WIFI_DEVICES`**（`neverForLocation`，运行时）；Windows 提示放行防火墙"专用网络"。
3. **进度/状态回写**：2s `Timer.periodic` 轮询 `GetTransportInfo/GetPositionInfo/GetVolume` 回写与会话；进度按 §3.3 同款插值，设备号 0 时长时用墙钟兜底保证播控中心进度跟随。所有定时器在停止/退出时 `dispose`，无递归 `Future.delayed`（§1.5 / §10 #14）。
4. **UI**：**仅全屏播放器**提供**独立样式**的「局域网投屏」入口 + 独立面板（复用 `MusicFlowBottomSheet` 视觉，但不复用/混入现有"选择播放器"面板）。链路 B 与链路 A 互不显示对方设备、互不写入对方状态，避免链条混淆。
5. **强制 http 拉流（ray 确认，2026-08-30）**：交给 DLNA 设备的**所有资源 URL（流/封面等）一律强制 http**——很多 DLNA 设备没有 TLS 栈，收到 https 拉流地址会直接拒拉（卡 TRANSITIONING 无声）。规则：
   - http 地址可用性**沿用地址池健康检查结果**（`status == ok`），不额外探测；当前活跃地址本身是 http 时优先直接用；
   - **手动锁定 https 线路不影响投流**（锁定只约束客户端控制面，不限制拉流面）；
   - 换 token 的请求仍走客户端当前连接，仅拼接给设备的 URL 换 http origin（`rewriteUrlToBase`，回退的带鉴权 `/rest/stream` URL 同样被重写，鉴权参数与主机无关仍有效）；
   - **打开直投面板即检测**：无可用 http 地址时不出设备列表、禁止发起投流，面板内提示「直投功能必须在媒体库中先添加http连接」（ray 指定措辞，`kDlnaCastHttpRequiredHint`）；
   - 实现集中在 `lib/core/dlna/cast_http.dart`（纯函数）+ `dlnaCastHttpBaseProvider`（watch 当前媒体库与活跃地址，编辑地址/切换线路自动重算）+ `streamUrlBuilder` 内兜底抛 `DlnaCastHttpUnavailableException`（`startCast` 捕获返回失败）。
   - 附：服务端 token 事实——`/rest/dlna/stream/:token` 的 token **有效期 6 小时**（`SESSION_TTL_MS`，`dlna/control.ts`），非一次性；期间可反复拉流/拖进度；每切一首歌换新 token。

**权限/配置清单**：
- Android：`ACCESS_WIFI_STATE`、`CHANGE_WIFI_MULTICAST_STATE`、`NEARBY_WIFI_DEVICES`（Android 13+）；统一走自写 MethodChannel（`com.musicflow.app/dlna`：`acquireMulticastLock` / `releaseMulticastLock` / `hasNearbyWifiDevicesPermission` / `requestNearbyWifiDevicesPermission`），不依赖 `permission_handler` 新增能力。
- Windows：无本地监听端口（v3.2 无中继）；设备经局域网直连服务端 `stream` 拉流，防火墙"专用网络"放行说明写入文档。

**已落地实现清单（v3.2 交付，均已在代码库落地）**：

| 需求 | 落地实现 |
| --- | --- |
| 1 设备发现 | `ssdp_discovery.dart`：M-SEARCH + 被动 NOTIFY；`dlna_manager.scanDevices()` 逐个拉 description.xml（`device_description.dart`，解析 AVTransport / RenderingControl 控制 URL；**只按 AVTransport 判据识别渲染器**）。Dart 侧 `dlna_provider.acquire/releaseMulticastLock()` 已按引用计数接入原生通道（Android-only，非 Android 走 No-op）。 |
| 2 直传 | `dlna_manager.startCast`：`Stop → SetAVTransportURI(直连 URL + DIDL-Lite) → Play`；`_playCurrentTrack` 直连 `_directStreamUrl(songId)`（`DlnaManager.init(streamUrlBuilder:)` 注入，复用 `SubsonicApiClient.getStreamUrl` + 当前 `effectiveQualityProvider.maxBitRate`，带 token），设备自拉流；`_provisionNextTrack` 优先 `SetNextAVTransportURI`，失败墙钟看门狗（`_playbackElapsed`/`_currentRealDuration`）曲末自动下一首；`_stallCount`/`_failStreak`(上限 8)/`_lastCompletionAdvance` 兜底。 |
| 3 中继 C 已删除 | `local_relay.dart` 移除；`dlna_manager` 不再依赖 `HttpServer`/`_localIp`/`_relayPort`/`_relaySessionBySongId`，`dispose` 不再关中继。 |
| 4 UI（双链路完全独立） | `full_player_page.dart` `_PlayerUtilityBar`：独立按钮（`AppIcons.dlnaLocal` 电视图标，与链路 A airplay `AppIcons.dlna` 区分），`selected: dlnaCast.isCasting` 投屏态高亮，触达 `_openLocalDlnaCastSheet`。面板 `local_dlna_cast_sheet.dart`：设备自扫列表 / 投屏中当前曲+播放控制 / 停止投屏 / 空态。状态仅读写 `dlnaCastProvider`/`dlnaDevicesProvider`，与 `cast_peer_provider`（链路 A）互不写入。 |

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

### 4.3 聚合搜索展示形态（v3.4.45 起修订）

- ~~聚合搜索与本地曲库列表互斥展示（不同 tab/入口）~~ **已废弃**：不再提供来源切换按钮或独立入口。
- 现行形态：搜索结果同页**分块展示**——本地结果（歌单/歌曲/专辑/艺术家，见 §5.4）在前，分隔线之后为全网聚合结果（走 §五 entity-search 端点）。

---

## 五、搜索与在线音乐

### 5.1 聚合搜索（对齐主项目）

- `POST /rest/api/v1/{song|album|artist|playlist}-search/aggregate/search`，body `{ q, sources? }` → `{ total, providers, items }`；条目带 `providerId / providerName / platformLabel`。
- 单插件搜索：`POST /rest/api/v1/{...}-search/:providerId/search`（可选）。
- 在线歌单搜索：`POST /rest/api/v1/playlist-search/aggregate/search`。

### 5.2 在线直接播放（免入库）

- 搜索结果可直播：本机走 `/rest/stream-remote?provider&source&id&...`（代理流，带 `token` 参数）；**投屏到远端必须先入库拿真实 DB `songId`**（对齐主项目：`song-search/:pid/import` → 任务轮询 → 用 fingerprint 精确映射再 `queue/play`）。

### 5.3 入库导入与任务轮询（v3.4.48 起修订：触发即返回，禁止阻塞 UI）

- 导入端点（均为触发即返回 `{ taskId }` 的异步任务）：`POST /rest/api/v1/{song|album|playlist}-search/:pid/import`。
- **客户端交互契约（v3.4.48）**：入库 = 一次 POST 提交（秒回）→ 立即 Toast「已提交」→ **绝不弹任何阻塞遮罩/loading dialog**（v3.4.48 前歌单入库曾弹 `barrierDismissible: false` 全屏 loading 并同步轮询，大歌单直接卡死 UI，已修）。
- 提交成功后 fire-and-forget 后台轮询 `GET /rest/api/v1/tasks/:id`（间隔 ~800ms，预算 5 分钟，`SearchRepository.waitTask`）；任务完成/失败经**全局 ToastNotifier**（根导航器 Overlay，不依赖页面 context）通知。
- 后台轮询状态：`running` / `ok`（result 含 `playlistId` 或 `{ success, imported:[{fingerprint,id}], ids }`）/ `error`。
- **任务状态字段嵌套在 `task` 下（v3.4.50 修正）**：`GET /v1/tasks/:id` 返回 `{ success, task: { status, result, error, progress } }`。客户端 `waitTask` 必须读 `task` 嵌套字段（兼容历史顶层直出）；曾因读顶层 `status` 恒为 null，后端入库完成却每次 5 分钟超时误报失败——链路断点，已修。
- 同歌单去重（v3.4.50）：后端按 sourceUrl 去重，重复提交返回 `{ success:false, alreadyRunning:true, taskId }`；客户端**复用该 taskId 继续监听**，不报错。

### 5.4 搜索交互契约：范围下拉浮层（方案 A）+ 热门/历史（v3.4.47）

**范围五档（来源唯一）**

- `SearchScope { all, playlist, song, artist, album }`，枚举与文案唯一来源 `lib/features/search/search_scope.dart`（含 `kSearchScopeStackOrder = [playlist, song, album, artist]`）。
- UI 文案：所有 / 歌单 / 音乐 / 艺术家 / 专辑；「音乐」即歌曲，结果分组标题用「歌曲」。
- **范围不跨启动记忆**：每次进入搜索页默认回到「所有」。

**方案 A 下拉浮层（禁止改回全屏遮罩）**

- 进入搜索页即浮出范围下拉浮层（`SearchScopePanel`），输入框保持聚焦、**可直接打字**。
- 浮层实现 = `Positioned` 下拉 + `TapRegion(onTapOutside)` 收起；**严禁加全屏 scrim/遮罩**（会物理遮挡并拦截下方热门/历史区的点击，v3.4.47 曾因此返工）。
- 输入关键词后浮层自动收起；清空关键词重新浮出；空白提交不触发搜索、浮层收起，点空输入框重新浮出。

**「所有」档语义**

- 对四类目（playlist/song/album/artist）**各发一次**聚合搜索（同关键词 4 条请求），结果按 `kSearchScopeStackOrder` 分组堆叠：歌单 → 歌曲 → 专辑 → 艺术家；非「所有」档只查对应单类目。

**搜索历史（自动清理）**

- 存储：SharedPreferences，key `search_history_v1`，条目 `{ q, ts }`。
- 纯函数 `pruneSearchHistory`（`lib/data/models/search_history.dart`）：90 天过期（**严格 `isBefore`**，恰好 90 天不算过期）+ 忽略大小写去重（保留最近）+ 上限 30 条（淘汰最旧）；读取与写入各执行一次。
- 点历史词即搜并置顶去重；支持单条删除与一键清空。

**热门搜索（本地兜底）**

- 无服务端接口，本地兜底：收藏的 艺术家名 > 专辑名 > 歌曲歌手名，去重后最多 10 个（`buildHotSearchTerms`）。
- 无收藏时整块隐藏，**不放默认词**。

**入口（多端一致）**

- 搜索页是唯一搜索实现：Windows/宽屏走首页搜索条（`_HomeSearchEntry`），移动端 compact 额外在首页标题行右侧提供搜索图标按钮（`home-header-search`）——两入口共用 `_openSearchPage` 打开同一个全屏 `SearchPage`，逻辑零分叉（v3.4.49）。

**回归防线**

- `test/features/discover/search_page_test.dart`（6 例）+ `test/features/search/search_history_test.dart`（4 例）+ `discover_page_test.dart` 标题行搜索按钮用例必须保持通过；覆盖浮层交互、范围请求语义、热门/历史行为、堆叠顺序、点击播放/路由、入口跳转。

---

## 六、首页推荐与每日推荐

- 首页卡片：`GET /rest/api/v1/recommend/home-cards`；每日推荐：`GET /rest/api/v1/daily-recommend`；本地推荐：`GET /rest/api/v1/recommend/local`；推荐导入：`POST /rest/api/v1/online/:providerId/recommend/import` / `recommend/sync-all`。
- **首页展示内容与交互以现有 Android/Windows 实现为基准，不得改版**（§1.1 / §7.3）。

### 6.1 首页分区：服务端清单 + 客户端用户自治（重点）

- **服务端清单**：`GET /rest/api/v1/home/sections` 下发 `{key, title, sortOrder, visible}`，
  客户端按 sortOrder 升序渲染；清单未就绪/失败时回落 `kDefaultHomeSectionKeys`
  （`lib/features/discover/home_section_registry.dart`）。
- **推荐两模块定位**（定序由客户端归一，服务端 sortOrder 保持一致）：
  `local-recommend` = **平台推荐**（本地库随机歌单）在前，`platform-recommend` = **插件推荐**
  （插件提供方，原「平台推荐」）在后。
- **用户本地布局覆盖服务端**：persist key `home_section_layout_v1`（SharedPreferences，小 JSON，
  经 `getPrefs()` 门；由 `homeSectionLayoutProvider` 暴露）。
  1. **顺序**：用户排过的分区按用户顺序在前，**服务端新增**分区按服务端 sortOrder **追加尾部**；
  2. **可见性**：最终显示 = 服务端 `visible` **且** 用户未隐藏。
- **隐藏 = 不拉取**：用户隐藏的分区不渲染 → 分区 widget 不构建 → 该分区数据 provider
  （autoDispose / 从未被 watch 的 keepAlive）不初始化 → **不会发起任何服务端请求**。
- **编辑入口**：首页分区列表最末「编辑首页模块」→ `HomeSectionEditPage`（拖拽把手排序 +
  每行显隐开关 + 右上角「完成」保存，保存后首页经 provider 即时重建，无需重启）。
  两端（Android / Windows）共用同一套交互与持久化。

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

### 7.5 启动自动更新检查

- **触发时机**：每次冷启动、首帧结束后延迟 3s 在后台异步执行（`kStartupUpdateCheckDelay`），
  不阻塞首屏渲染、自动登录与曲库拉取。
- **目标平台**：仅 **Windows 与 Android**（`startupUpdateCheckSupported`）。
  Web / macOS / Linux / iOS 不做静默网络请求。
- **检查来源**：`UpdateChecker.check()` 读 GitHub Releases `releases/latest`，
  与 `PackageInfo.version` 做语义化版本比较（§1.6 tag 体系，版本号以 tag 为准）。
- **提示框**：发现新版本才弹，且**必须可关闭**——「稍后再说」、Windows 对话框右上角关闭按钮、
  点击弹窗外均可关闭；关闭后本次启动不再打扰。
- **下载行为**：框内「前往下载」**直接**用系统浏览器打开下载链接
  （`LaunchMode.externalApplication`），**不再二次确认**。
  资源挑选：Android 优先 `.apk`，其余平台优先 `.zip`（`pickPlatformUpdateAsset`），
  没有资源时回退发布页 `releaseUrl`。
- **失败静默**：网络错误 / 解析失败一律只打日志（`UPDATE` tag），不弹任何错误提示。

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
- 全屏背景图解码后按显示尺寸缩放，禁止大图直接上屏；
- **禁止图片缓存（§1.5 硬约束）**：不使用任何磁盘/内存图片缓存（含 `cached_network_image` 的缓存落地），`ImageCache` 上限需显式收紧并可清理；只保留请求侧 `size` 预算与「视口内才发起请求」的加载时机控制（冷启动优先加载视口封面，视口外延后/不请求）。

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

### 8.6 原生窗口渲染自定义 icon font 字形：禁止运行时加载字体，必须离线提取硬编码（v4.3.28 教训）

> 背景：桌面歌词浮窗（`windows/runner/desktop_lyric.cpp`，GDI+ 分层窗口）要渲染与 Flutter 端同款 remixicon 图标（播放队列/顺序播放）。运行时加载字体在本机已实测三连败，全部走不通，每次失败形态还不同（静默降级 → 图标不对 → 直接崩溃）。

运行时加载三连败（均已实测定性，禁止再试）：

1. `AddFontResourceExW(FR_PRIVATE)`：注册成功但**只对 GDI TextOut 可见**，GDI+ `FontFamily(name)` 构造完全查不到（status 14）——曾致歌词窗 remix 图标全部静默降级为 Segoe 字形，且 `GetLastStatus` 校验只降级不报警，失效无人知。
2. FR_PRIVATE 字体的 family 名必须用**字体内部名**（fontTools 读 name 表 nameID=1），remix.ttf 是 `remixicon` 而非文件名/别名 `remix`；名字对了 FR_PRIVATE 依然喂不动 GDI+（见 1）。
3. `PrivateFontCollection`（`AddFontFile` + `GetFamilies`）：family 构造成功，但本机 gdiplus 10.0.19041 上，集合内 family **首次进入 `GraphicsPath::AddString` 即 c0000005 崩溃**（启动约 11s、hover 触发按钮绘制才炸；事件日志实锤 gdiplus.dll 访问违例）。

**硬性约束：原生窗口要用随包 icon font 的字形，一律离线提取轮廓硬编码为矢量路径：**

- 工具：`tool/gen_lyric_glyphs.py`（venv Python，fontTools RecordingPen 提取 → 二次贝塞尔升三次 `c1=P0+⅔(P1−P0)` 含 off-point 链中点插值 → Y 翻转为向下为正 → 生成 `PointF`/`BYTE` 类型数组）；`--patch windows/runner/desktop_lyric.cpp` 自动回写标记区段（读写 utf-8 + `newline=""` 保 CRLF）。
- 绘制：`DrawRemixGlyph`（em 等比缩放、ink 外接框居中于按钮圆心、`GraphicsPath(pts, types, count)` 构造 + `FillPath`；PathPointType：Start=0/Line=1/Bezier=3，每轮廓末点 |0x80 CloseSubpath）。
- 新增字形：改脚本 `GLYPHS` 列表 → 跑 `--patch` → `DrawButton` 加 case。**禁止重新引入任何运行时字体加载**（FR_PRIVATE / PFC）。
- 优点：与 Flutter 端同字体同源天然一致；字形随包固定一次提取永久有效；零字体加载崩溃面。

配套坑（均实测）：

- runner 目标开 `/WX`：数据字面量**必须带 `f` 后缀**（double→float 截断 C4305 被当 error；且整数不能拼 `1100f`——非法，要 `1100.0f`）。
- patch 标记必须用**完整唯一行**：数据区起始标记 `// ---- 硬编码 remixicon 字形轮廓(由 tool/gen_lyric_glyphs.py 生成` 与函数说明注释 `// ---- 硬编码 remixicon 字形 ----` 前 20 字符相同，截短匹配会吞掉 struct 定义区。
- `windows/flutter/ephemeral/cpp_client_wrapper/*.cc` 残缺报 C1083：从 SDK 缓存 `bin/cache/artifacts/engine/windows-x64/cpp_client_wrapper/` cp 补齐即可，无需 clean。
- 桌面歌词按钮图标的语义对齐：与迷你条共用语义（队列=播放三角列表 `play_list_2_line`，顺序播放=数字有序列表 `list_ordered_2`，切换播放器=基站 `base_station_line` 0xEAA6，经 `AppIcons.queue`/`AppIcons.orderPlayback`/`AppIcons.signalTower`），原生侧硬编码轮廓必须与 pub 包 remixicon 同码点同字体文件。

### 8.7 桌面歌词悬停按钮栏布局（v4.3.42 起 8 按钮）

按钮自右缘向左排（**偏移越小越靠右**），索引与偏移必须用 `desktop_lyric.cpp`
顶部的 `kBtnIdx*` / `kOff*` 常量，**禁止写裸数字**：

| idx | 常量 | 偏移 | 图标 | 事件 |
|-----|------|------|------|------|
| 0 | `kBtnIdxPrev` | 403 | prev | `previous` |
| 1 | `kBtnIdxPlay` | 349 | play/pause | `toggle_play_pause` |
| 2 | `kBtnIdxNext` | 295 | next | `next` |
| 3 | `kBtnIdxMode` | 243 | shuffle/repeat | `cycle_playback_mode` |
| 4 | `kBtnIdxLike` | 191 | heart | `toggle_like` |
| 5 | `kBtnIdxQueue` | 139 | 队列 | 内部弹窗（队列） |
| 6 | `kBtnIdxVolume` | 87 | volume | 内部弹窗（音量滑条） |
| 7 | `kBtnIdxSwitch` | 35 | 基站 | 内部弹窗（切换播放器） |

**切换播放器(基站)必须是最靠右的那个按钮，且紧挨音量右侧**
（`kOffSwitch < kOffVolume`）——GUI 上「音量 → 切换播放器」的相邻关系是
用户明确要求的排布（2026-09-10 反馈），`tool/desktop_lyric_guard.dart` 规则 6a
已把这条写死为阻断项。

约束：新增按钮必须同步四处——`kBtnCount`、
`ButtonGeom`、`HitTestButton` 循环上界、点击派发 `switch`。
窗口宽度 `kWindowWidth` 保持 572（第 8 个按钮加宽后的值）；
悬停时歌词跑马灯裁剪区会右让 `kOffPrev + kBtnR + 6`，避免文字钻到按钮底下。

### 8.8 桌面歌词的弹窗必须长在歌词窗自己身上，不得回到主窗口

`PopupKind` 现有三档，一律画在歌词窗**上方**（`SetPopup` 时窗口向上增高
`g_popupH`，`SyncWindowHeight` 落高度）：

| PopupKind | 面板 | 内容来源 |
|-----------|------|----------|
| `Volume` | 竖向滑条 | 本地音量状态，直接改 |
| `Queue` | 播放队列列表 | Flutter 推来的队列快照 |
| `Switch` | 设备列表（与 MINI 播放条小弹窗同款） | Flutter 推来的设备列表 |

`Switch` 面板的协议（v4.3.42 起）：

- 点击基站按钮：`SetPopup` 在 `Switch` / `None` 之间 **toggle**——
  **再次点击同一按钮 = 收起**（用户明确要求，与 Volume/Queue 的语义一致）。
- 首次展开时向 Dart 发 `switch_player_open`，Dart 侧
  `StatusLyricsController.requestSwitchList()` 拉一次最新设备列表，
  再经 `update_desktop_lyric_switch_list`（`WindowsTitleBar` → C++）推回原生。
- 行内容由纯函数 `composeDesktopLyricSwitchList()` 组装（**有单测**）：
  `0=本机` 恒在首行；本机非当前控制目标时插入 `1=停止投屏`；其后为可用远端设备。
  行点击发 `switch_pick:<idx>`，Dart 侧 `pickSwitchRow(index)` 执行切换。
- 鼠标移出窗口 → 既有 `UpdateHoverState` 路径自动 `SetPopup(None)`，弹窗收回。

**禁止**把设备的切换弹窗再弹回主窗口（旧 `switch_player` 事件已删除）。
`desktop_lyric_guard.dart` 规则 6b/6c 会拦截「点击分支里又出现 `switch_player`」
以及「Dart 侧缺失 `requestSwitchList` / `switch_player_open` / `switch_pick:`」。

### 8.9 设备行必须与 MINI 播放条小弹窗同款：徽章 + ↓/↑ 接续箭头

v4.3.42 用户反馈「桌面歌词少了 DLNA 设备里面的部分功能」——歌词窗设备行
当时只有设备名，缺了 MINI 弹窗 `PeerCastRow` 的两样东西。补齐后：

| 元素 | 位置 | 数据字段 | 语义 |
|------|------|----------|------|
| 设备类型徽章 | 紧跟设备名（`MeasureString` 量宽后就地画） | `badge` | `PeerInfo.kindLabel`（DLNA / 群…），本机行留空 |
| ↓ 接回本机 | 行右端（靠左那支） | `canPull` | 该设备队列非空且正在播放 → `pullPeerToLocal` |
| ↑ 推到该设备 | 行右端（靠右那支） | `canPush` | 本机非投屏态 + 本机队列非空 → `pushLocalToPeer` |

- 判据与 `PeerCastRow` **逐字一致**（`canPull = now.isActive && total > 0`、
  `canPush = activePeer == null && localQueue.isNotEmpty`），不许歌词窗自己另立一套。
- 箭头**始终画出来**，只是无「现场」可搬时置灰（`kOffColor`）——
  让用户知道这里本来有两支，而不是以为功能没了。
- 箭头字形是**手写轮廓**（`kArrowDownPts` / `kArrowUpPts`，粗竖杆 + 三角头），
  不从字体抠：运行时加载字体在本机走不通（§8.6），手写两笔更可控。
- 行号 → 设备下标必须走纯函数 `desktopLyricPeerIndexFromRow()`（**有单测**）：
  之前「切控制目标」与「搬现场」两处各写一遍 `- (hasStopRow ? 2 : 1)`，
  迟早写歪成点 ↓ 搬到隔壁设备。
- 协议：`switch_pull:N`（↓）/ `switch_push:N`（↑）/ `switch_pick:N`（整行切换）。
  原生层接续箭头**优先于整行点击**（命中箭头就不再切换控制目标），
  与 MINI 弹窗的 `_HandoffButton` 行为一致。
- `desktop_lyric_guard.dart` 规则 8 锁死整条链路（Dart 字段 → 通道 → 原生
  绘制/命中 → 主壳分发）；注意该规则只认**代码里的字符串字面量**
  （`"switch_pull:%d"` / `startsWith('switch_pull:')`），
  注释里的文字提及不算——规则 7 曾因此被注释骗过（`Overlay(`）。

本地复跑原生编译：`bash tool/check_native_syntax.sh`
（等效于 CI 的 `cl /Zs` job；Git Bash 下 `cmd //c` 会被路径转换搅乱，
直接调 `cl.exe` + `/I` 显式传头文件路径）。

### 8.10 列表弹窗几何不变量 + 设备行「正在播放」实时化（v4.3.42）

**几何不变量（「设备列表只显示本机」的真实根因）**：`PopupLogicalHeight` 的
Queue/Switch 高度公式 = `rows*rowH + (rows-1)*gap + kListPopupPadV*2 +
kListPopupMarginV*2`，其中 `kListPopupMarginV`(6) 是面板矩形自身的上下外边距
（`ListPanelRect` / `SwitchPanelRect` 的 `rc.top/bottom`）。**公式与矩形必须
共用同一常量**：公式漏掉 margin 会让行区比可用高度多出 2*S(6)≈18px，
`rowTop + rowH > rows.bottom` 恒真 → **最后一行永远被 break 裁掉**
（主卧恒为最后一行 → 永远不显示；队列弹窗同样中招）。
`desktop_lyric_guard.dart` 规则 9 锁死：公式两处必须都带 margin、
矩形不得改回 `S(6)` 硬编码。

**接续箭头顺序**：与 MINI `PeerCastRow` 的 Row 顺序一致——**↓(接回本机)在左、
↑(推到该设备)在右**，`HandoffCx` 用 `(1 - which)` 位移（规则 9 锁死）。

**设备行「正在播放」实时化（原实现是打开瞬间的快照）**：
- `peerNowPlayingProvider` 是 **StreamProvider.autoDispose.family**：有监听者
  期间每 5s 重拉，失败保留上次结果；MINI 弹窗行 watch 即实时，关弹窗自动停。
  ⚠️ Riverpod 2.6.1 普通 `Ref` **没有 listenManual**（只有 WidgetRef 有），
  控制器内不要试图保活订阅。
- 桌面歌词侧：控制器 `_fetchSwitchNowPlaying` 并行拉全部可用设备存
  `_switchNow`，`Timer.periodic(5s)` 重拉+重推（去重 key 拦无变化），
  首屏在 `requestSwitchList` 末尾立即拉一轮。
- **协议新增 `switch_close`**：原生 `SetPopup` 从 Switch→None 时（toggle 收起/
  选行/搬移/移出悬停区）回传，Dart 据此 `stopSwitchAutoRefresh()`——
  不然弹窗关了还在每 5s 每设备一次 HTTP。规则 8 锁死两端。
- 轮询生命周期：任一弹窗开→对应设备流启动；同设备两弹窗同开共享一条流
  （family 单例）；全关→全停。

**行首图标**：`icon` 字段(1=耳机本机 2=基站 DLNA 3=人群群组 4=刷新行)走通道，
原生用离线字形画（`headphone_fill`/`group_3_line`/`restart_line` 经
`tool/gen_lyric_glyphs.py --patch` 注入；DLNA 复用切换按钮的 base_station）。
**手写字形（接续箭头轮廓）必须放在生成区 `END_MARK` 之后**——`--patch` 会把
生成区整体重写，混进去的手写数据会被静默清掉（v4.3.42 实际发生过，
规则 9 锁死）。

---

## 九、测试规范

### 9.1 单元测试（按仓库实际文件清单）

| 模块 | 测试文件 | 重点 |
|------|----------|------|
| 投屏控制 | `test/providers/cast_peer_provider_test.dart` | peers 列表/切换/轮询/回本机/待办项（§3.5） |
| 链路 B DLNA 直投（§3.6，单档位直传） | `test/core/dlna/dlna_models_test.dart`、`test/providers/cast/dlna_provider_test.dart`、`test/core/dlna/device_description_test.dart`、`test/core/dlna/cast_http_test.dart`、`test/features/player/local_dlna_cast_sheet_test.dart`、`test/features/player/dlna_volume_test.dart` | DLNA 模型/设备描述纯逻辑（**按 AVTransport 判据识别渲染器**，只有 ContentDirectory 的设备应返回 null）；直投 http 基地址挑选/URL origin 重写/缺 http 提示；直投面板空态/设备过滤；投屏态当前曲+播放控制+进度跟随；设备行发起点播；队列空则不投屏；全屏播放器独立入口与链路 A 图标共存、投屏态高亮并打开面板；音量 |
| 播放队列/进度 | `test/providers/player_seek_policy_test.dart`、`test/providers/preview_playback_queue_test.dart` | 队列、切歌、播放模式、seek 策略 |
| 数据源 | `test/data/sources/subsonic_api_client_test.dart` | 鉴权注入、响应解析、错误处理 |
| 仓库 | `test/data/repositories/music_repository_test.dart` | 分页解析、窗口化切片 |
| 模型 | `test/data/models/*_test.dart` | Freezed 序列化、`songToQueueItem` 形状 |
| 工具 | `test/core/utils/*_test.dart` | 时间/字符串/列表工具 |
| 列表/页面 | `test/features/library/*_test.dart` | 页面布局、歌词、组件（窗口化列表专项测试待补） |

> 旧 SPEC 所列 `test/dlna/*`、`test/data/subsonic_api_test.dart`、`test/providers/queue_test.dart` 与仓库不符，已按实际替换。**新增/修改逻辑必须附测试。**

### 9.2 集成测试

- 连接真实 MusicFlow 实例：登录 → 浏览曲库 → 搜索 → 播放 → 收藏；
- 投屏链路：`/peers` 列表 → `dlna/scan` → 切到 DLNA → 播放/暂停/切歌/音量/播放模式 → 点歌/加歌 → 切回本机；
- 权限：普通账号面板仅本机一项。

### 9.3 构建门槛

- `flutter analyze` 0 错误；**本次改动涉及的** `flutter test` 全绿（全量测试的定位见 §9.4）；
- APK / Windows 可执行文件只在 CI 构建（§1.6）；Windows 性能验收（§8.5）达标。

### 9.4 CI 与发布门禁（**CI 失败不限制发版**）

> **总原则：CI 是质量观察哨，不是发布门禁。任何测试类流水线失败都不得阻塞构建与 GitHub Release 发布。**

| 流水线 | 文件 | 职责 | 是否阻塞发版 |
|--------|------|------|--------------|
| Build Client | `.github/workflows/build-android.yml` | 版本 tag 触发；解析版本号、构建 Android APK + Windows ZIP、发布 Release | **是**（构建失败即无产物） |
| Test Suite | `.github/workflows/test-suite.yml` | 跑全量 `flutter test` | **否** |
| UI Guard | `.github/workflows/ui-guard.yml` | 三道 UI 防线：Windows 按钮重叠 / 安卓样式弹窗 / 大屏播放器布局 | **否** |

硬性规则（新增 CI 时必须遵守）：

1. `Test Suite` / `UI Guard` 是**独立 workflow**，绝不能出现在 `build-android.yml` 的 `needs` 链上；
   `publish-versioned` 只依赖 `resolve-version` / `build-android` / `build-windows`。
2. 这两个 workflow 的**每个 job 与 step 一律 `continue-on-error: true`**，失败只显示黄色警告。
3. 仓库存在与当前改动无关的历史遗留失败用例，**全量 `flutter test` 飘红属预期**，不构成发布门禁；
   是否清理由 ray 决定。
4. **新增/修改逻辑自带的测试必须本地全绿**——§9.3 的「全绿」指「本次改动涉及的测试」，
   不要求全仓库测试全绿。
5. 只有 `build-android.yml` 中真正产出构建产物的步骤（`flutter build apk` / `flutter build windows` /
   `check_interaction_feedback`）失败才会导致发版失败；`dart analyze` 一类检查步骤保持
   `continue-on-error: true`。
6. 触发时机：push `main`、push `v*` tag、PR 到 `main`、`workflow_dispatch` 均可跑观察型流水线。
7. **`continue-on-error` 不等于「可以没有结果」**——因为失败被允许，必须另有一条可见的结果通道，
   否则「测试压根没跑起来（环境/依赖失败）」和「全绿」在 Job 上看起来一模一样。
   `test-suite.yml` 因此强制产出三层结果可见性：
   1. **Job Summary**：`flutter test --reporter json` 的原始事件交给
      `.github/scripts/summarize_tests.py` 汇总，输出「通过 / 失败 / 跳过」计数与失败用例表格；
   2. **黄色注解**：每个失败用例一条 `::warning::`（上限 40 条），在提交 / PR 页面直接可见；
   3. **原始产物**：`test-results.jsonl` + `test-results.err` 上传为 artifact 留存 7 天，便于本地复现。
   汇总脚本**退出码恒为 0**，只负责陈述结果，绝不参与门禁判定。
8. 观察型流水线里的 `dart analyze` 必须带 `--no-fatal-infos --no-fatal-warnings`
   （只有真 error 才失败）——否则仓库存量 lint 会让步骤打出红色的
   "Process completed with exit code 1" 注解，在「失败本就允许」的流水线上
   反而淹没真正需要关注的失败用例警告。

---

## 十、负面清单（优先级最高）

> AI 动手前逐条默读；交付时逐条确认「未违反」。本清单优先级高于任何口头需求——冲突时先问。

1. **禁止**引入未授权的新第三方库或升级依赖版本；移除依赖（azlistview/lpinyin/marquee/just_audio_windows 等）需 ray 确认。链路 B 仅允许自写原生 MethodChannel + manifest 权限，**零新增第三方依赖**。
2. **禁止**修改主项目（`/workspace/_MusicFlow-main` 等参考副本）任何文件；主项目只读。
3. **禁止**重构未指明的模块（换框架、大规模抽公共层）；重构必须由 ray 显式下达。
4. **限制**客户端自行实现 SSDP/SOAP/推流/HTTP 中继：仅允许在**链路 B（§3.6）**内由 `lib/core/dlna/*` 实现并向局域网 DLNA 直投；**v3.2 起禁止本地中继/推流（`local_relay.dart` 已删）**——只传服务端直连 URL，设备自拉流；**链路 A 仍一律走后端 `peers*` API**。禁止把链路 B 的设备/状态并入链路 A（`cast_peer_provider`）。
5. **禁止**在 UI 硬编码颜色/字号——必须用 `Theme.of(context)` / `EchoDesign` 常量。
6. **禁止**一次加载全表后前端过滤——所有列表走 §四 窗口化/分页。
7. **禁止**在 Widget `build()` 中发起网络/DB/高开销计算（含播放器背景对比度二分）。
8. **禁止**在 catch 块吞异常——必须打日志含上下文。
9. **禁止**删除/修改已有测试文件——只新增（行为契约变更时先向 ray 报备再更新）。
10. **禁止**私自提交 / push / 打 tag；**禁止把 `/workspace/_MusicFlow-main` 或构建产物提交入库**（交付前 `git status` 核对）。
11. **禁止**任何列表绕过 §4.2 窗口化加载（新增列表必须接 `WindowedPaginatedList` + `WindowedListView`）。
12. **禁止**在 Windows 引入/保留导致卡顿的高成本特效（§8.1）与未节流的高频重建（§8.2）。
13. **禁止**在本地机器执行 `flutter build`（apk/windows 等）；构建产物只由 CI 产出。
14. **禁止**为链路 B 的 DLNA 发现/状态模块使用单发递归轮询（`Future.delayed`/`Timer` 递归）——新代码统一用 `Timer.periodic`/`Stream.periodic` 且 `dispose`（链路 B 状态轮询已遵循，§3.6）。
15. **禁止**在 Windows 原生窗口运行时加载自定义字体（`AddFontResourceExW`/`PrivateFontCollection` 均已实测失败）——icon font 字形一律离线提取硬编码（§8.6，工具 `tool/gen_lyric_glyphs.py`）。
16. **禁止**只放大外层 `Future.timeout()` 来放宽某个请求的超时——Dio 全局 `receiveTimeout`/`sendTimeout` 是 30s，会先触发。必须成对设置（§12.2）。

---

## 十一、AI 自检清单（交付前逐项勾选）

```
□ 1. 负面清单（§十）16 条逐条确认未违反
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
□ 13. 若动到 CI：观察型流水线未接入 publish needs 链、每个 job/step 都 continue-on-error（§9.4）
□ 14. 发版产物全部由 GitHub CI 构建（§1.6）：只打 tag 推送、绝不本地 `flutter build` 后手动上传；
      Release 产物 uploader 必须是 `github-actions[bot]`（安卓签名证书只在仓库 Secrets）
□ 15. 放宽请求超时时 dio `receiveTimeout`/`sendTimeout` 与外层 `Future.timeout()` 已成对设置（§12.2）
□ 16. 新增的已知隐患已写入 §十二（含触发条件/影响面/根治方案），未留无文档的暗坑
□ 17. 投屏队列轮询未回退成全量拉取：常规 tick 必须 `?offset=<len>&size=1`，
      仅 `total` 变化或本地改结构（`pollOnce(fullQueue: true)`）才拉全量（§12.1）
□ 18. 投屏主通道 `/v1/play` 成功后必须做**槽位身份校验**（比对 `songId`），
      不一致即返回 `false` 回落整队推送——**禁止**改用长度校验（实测无效）（§13.4 风险 1）
```

---

## 十二、已固化的隐患治理（**勿回退**）

> 每条都是**已定位 + 已修复 + 已留守卫**的性能/稳定性治理，保留在此是为了：
> 让后来者看清**根因与修复代价**，避免再犯或误判成新 bug。对应守卫见 §十一 自检清单。
> 回退本节任一条 → `flutter test` 必红。
>
> **开工前先看 §十三（进行中的开发任务）**——那里有未收尾的工作与必须实测的风险项。

### 12.1 已固化：投屏轮询轻量化（**纯客户端，2026-09-10 已实施**）

**根因澄清（2026-09-10 对真实服务端 192.168.10.240:46400 实测）**：原文「根治方案＝后端新增轻量
snapshot 端点，需改主仓库」**不成立**——`GET /v1/peers/:peerId/queue` **本来就支持
`offset` / `size`**（`backend/src/routes/api/index.ts` 的 queue 端点：`size > 0` 才切片，
缺省 `size=0` 返回全量；`total` 恒为全量长度，`currentIndex`/`playMode`/`ended`/`isActive`/
`currentMedia` 都在外层，**不随分页丢失**）。实测同一队列：

| 请求 | 体积 | items | 场景 |
| --- | --- | --- | --- |
| `GET /queue`（缺省＝全量） | **26 089 B** | 100 | 大队列 |
| `GET /queue?offset=0&size=1` | **574 B** | 1 | 100 首时 |
| `GET /queue`（缺省＝全量） | **863 935 B** | 3251 | 实测大歌单 |
| `GET /queue?offset=0&size=1` | **338 B** | 1 | 3251 首时（**2 556×**） |

→ 即「轻量 snapshot 端点」**已经存在**，就是同一个端点传 `size=1`。**跨仓依赖不存在。**

**已实施（v4.3.35，`cast_peer_provider._tick`）**：

- **常规 tick 轻量**：`?offset=<本地镜像长度>&size=1` 只取当前槽位一条 + 外层 `total`/
  `currentIndex`/`playMode`，命中即就地替换镜像里的那一槽（不重建整个列表）。
- **`total` 变化即补拉全量**：轻量路径拿到的 `total != items.length` → 立刻改拉全量重建镜像。
- **本地改结构强制全量**：`pollOnce(fullQueue: true)` —— 增删改/重排/跳曲/起停投屏后
  必须走这条（外部改队列但 `total` 不变的极端场景靠它兜底）。
  调用点：`stopCasting` / `next` / `previous` / `enqueueSongs` / `jumpTo` /
  `removeQueueItem` / `reorderQueue` 共 7 处。
- **意图式调用**：`toggle` / `seek` / `setPlayMode` / `playContentOnPeer` /
  `_pushQueueAndPlay` 保持轻量（不影响队列结构）。
- 守卫：`test/providers/cast_peer_provider_test.dart` 的 `轻量队列轮询（SPEC §12.1）`
  group 4 例（常规 tick 不发全量请求 / `total` 变化补拉 / `fullQueue:true` 走全量 /
  游标按服务端 `currentIndex` 定位）。
- 未做（可选，收益递减）：队列面板按窗口懒加载（对齐 §4.2）。

### 12.2 已固化：队列传输超时预算（v4.3.34 修，勿回退）

`POST /v1/peers/:id/queue/play` 是**同步语义**——整队落库后还要等设备
Stop→SetAVTransportURI→Play 完成才返回（含最长 ~5s 的 GENA 乐观窗口）。
后端实测**不随规模线性劣化**（`setQueue` = 单条 `deviceQueues` upsert + 一次
`JSON.stringify`，5000 首只多 ~1-2s），Hono 无 `bodyLimit`、无全局请求超时；
所以大队列失败**只可能是传输或客户端超时，不要去怀疑后端**。

- 预算一律走顶层 `queueTransferBudget(n) = (10s + 30ms × n).clamp(10s, 180s)`
  （`lib/providers/cast/cast_peer_provider.dart`）：500 首=25s / 800 首=34s /
  2000 首=70s / 5000 首=160s / ≥5600 首触顶 180s。
- **必须成对设置**：Dio 全局 `receiveTimeout`/`sendTimeout` 均为 30s
  （`ApiConstants`），只放大外层 `Future.timeout()` 是无效的，Dio 会先炸。
  调用方要把预算同时传给 `postRaw`/`getRaw` 的 `receiveTimeout`（内部同时设
  `sendTimeout`，大 body 上传同样要放行）。
- 守卫：`test/providers/cast_peer_provider_test.dart` 的
  `cast queue transfer timeout budget` group 锁死上述两条约束。

---

## 十三、进行中的开发任务（跨会话交接）

> **本节只记录「已开工但未收尾」的工作。** 收尾后把结论沉淀到对应正式章节，
> 本条目删除。接手前请先把 §13.4 的风险表读完再动代码。

### 13.1 主题：投屏链路改为「服务端内容点播优先 + 整队推送兜底」双通道（**已实施并真机验证**）

**背景（v4.3.34 之后的正确性问题，ray 2026-09-10 指出）**

原实现把「切歌手」做成了「搬运工」：客户端选中远端 peer 后，**每一次起播都要
自己把整队歌曲数据传到服务端**（`POST /v1/peers/:id/queue/play`）。歌单页因此
`getAllPlaylistSongs` 逐页拉全量（5000 首 = 25 页）→ 再原样推回服务端 → 服务端
落库投屏。绕了一大圈，成本高、还受客户端超时约束（§12.2 就是在给这条错链路
打补丁）。**这是链路设计错，不是超时参数问题。**

**正确形态**：客户端是**遥控器**，只发「放什么内容 + 从这首歌开始」；
服务端自己查库解析队列并投屏（与 Web 前端 `usePlayContent` 一致）。

```
【主通道 · 零上传】
  客户端 ──POST /rest/api/v1/play {peerId, type, id, songId}──▶ 服务端
                                                              │ resolveContentSongs 查库
                                                              │ songsToQueueItems
                                                              │ findIndex(songId) 按身份定位
                                                              └─▶ playFrom(设备) 投屏
  几百字节请求；5000 首歌单的起播不再受客户端上行带宽/超时约束。
  起点用 **songId（身份）** 而非 startIndex（行号）：服务端队列顺序与客户端展示序
  是否同源都不影响定位结果 —— 从根上消除「静默播错歌」。
  传了 songId 但服务端队列里没有 → 404 errors.renderer.songNotInContent
  （**不再静默归 0**，避免"点了没反应"）。未传 songId → 兼容 startIndex 路径。

【兜底通道 · 整队推送】主通道失败（内容已删 / 服务端旧版 404 / 本地拼装队列）
  客户端 ──POST /v1/peers/:id/queue/play {items, startIndex}──▶ 服务端
  队列来源服务端无从解析时用它：discover(首页随机) / search(搜索结果快照) /
  other(离线缓存列表等本地任意队列) / 不在库内的单曲。
  注意：「单曲路径」的判据是**手上没有服务端能解析的队列上下文**，
  ≠「歌单里只有一首」（后者走 playEffectiveQueue 主通道 type=playlist）。
```

### 13.2 已完成（v4.3.35，**已提交待发版**）

| 文件 | 改动 |
| --- | --- |
| `lib/providers/player/queue_origin_provider.dart` | 新增 `QueueOriginKindServerType` 扩展 → `serverContentType`：`playlist`/`album`/`artist` 映射为服务端 type，`discover`/`search`/`other` 恒为 `null`（服务端无从解析，只能兜底）。`QueueOrigin` 新增 `serverContentType` getter（`id` 缺失或空串也返回 `null`） |
| `lib/providers/cast/cast_peer_provider.dart` | 新增 `playContentOnPeer({type, id, songId, startIndex, localItems, localStartIndex})`：POST `/rest/api/v1/play`，超时 `contentPlayBudget(n) = queueTransferBudget(n)`（随规模缩放，**必须同时下发给 Dio `receiveTimeout`**）；`success != true` 或异常一律返回 `false`（**由调用方回落**，本方法不自行兜底）；成功后乐观镜像状态（`castQueue`/`castIndex`/`smoothPositionSeconds`/`status=PLAYING`）、`syncQueueForCast(localItems, start)`、`pollOnce()` |
| `lib/providers/player/effective_playback_provider.dart` | `playEffectiveQueue`：投屏时若 `origin.serverContentType != null` → 优先 `playContentOnPeer`（起点传 `songs[startIndex].id` 作为 **songId 身份**），返回 `false` 才回落 `playQueueOnPeer`（原逻辑原样保留为兜底）。`playEffectiveSong`：投屏且**无队列上下文**（`hasQueueContext = queue != null && queue.length > 1`）→ 优先 `playContentOnPeer(type:'song', id, songId)`，失败回落 `playSongOnPeer` |
| `lib/providers/cast/cast_peer_provider.dart`（v4.3.37 收敛，2026-09-10） | ① 主通道起点改传 **`songId` 身份**（请求体二选一：有 songId 就不发 `startIndex`）；② **删除整个投后槽位校验块**及其宽松回落（ray 判定补丁比问题更糟，见 §13.4 风险 1）；③ 本地乐观镜像改 `indexWhere(e['songId'] == songId)` **按身份对齐游标**；④ 新增 `contentPlayBudget(n)` 与 `queueTransferBudget(n)` 同源 |
| `test/providers/cast_peer_provider_test.dart` | 主通道 group 5 例（含 **songId 定位**、**无槽位往返**、**按身份对齐镜像**）+ `QueueOrigin server content type` 1 例 + **回落 group 2 例**（主通道 `false` 必须调 `queue/play`；`discover` 直接整队推送）。**锁死契约**：① 只发 content id + songId，**绝不**把歌曲列表塞进请求体；② 传 songId 就不传 startIndex；③ **不再有带 `offset` 的槽位探测往返**；④ 回落分支不可删。<br>**mocktail 坑**：`verifyNever` + 具名 matcher 进入校验模式后不再匹配已登记桩 → 真实调用被报成 `Unexpected calls` 而**假失败**，改用 `verify(...).captured` 过滤调用记录 |

### 13.3 服务端对照（主仓库 **v2.3.22 起带 songId 身份定位**）

`backend/src/routes/api/index.ts` 的 `POST /v1/play`（前端 `usePlayContent` 同源）：

- 入参 `{peerId, type, id, songId?, startIndex?, playMode?, enqueue?}`；
  `type ∈ {song, playlist, album, artist, genre}`
- 服务端 `resolveContentSongs(type, id)` 自行查库 → `songsToQueueItems` →
  **`findIndex(it => it.songId === songId)` 按身份定位起点** → `playFrom`
- 响应 `{success, peerId, type, id, name, queued, startIndex, songId}`
- 错误码：`400` 缺参 / `403` `canControlPeer` 细粒度授权失败 /
  `404` type·id 无效（内容已删）/ **`404` `errors.renderer.songNotInContent`
  （传了 songId 但队列里没有这首歌）** / `422` 无可播歌曲 / `500` `playFrom` 抛错
- **同步语义**：`playFrom` 内部含设备 Stop→SetAVTransportURI→Play（~5s GENA
  乐观窗口），且解析+落库耗时随队列规模增长，所以**超时必须随规模缩放**
  （`contentPlayBudget`，10s + 30ms/首封顶 180s）。原固定 15s 会被大歌单顶穿 →
  误判失败 → 触发回落重推 2MB。
- **起点定位：songId 身份优先，startIndex 行号兼容**（v2.3.22）。
  身份与两侧排序无关；`startIndex` 仍是**行号**且**越界静默归 0**（不报错），
  仅保留给 Web 前端与 HA 集成的存量调用方。
- **v2.3.21 起**：`resolveContentSongs` 的 playlist 分支补 `ORDER BY position,id`，
  与 `/v1/playlists/:id/tracks` 同序（顺序契约守卫 `contentOrder.test.ts`）——
  这是仍传 `startIndex` 的调用方的正确性基础。album/artist/genre 分支本来都有 ORDER BY。
- **守卫**：`backend/tests/routes/playStartLocator.test.ts`（4 例：
  songId 命中定位 / 未命中 404 / startIndex 兼容 / 同时传以身份优先）。
  把 songId 分支改成 `if (false)` 即红（已实测）。
- **已知残留（不阻塞）**：悬空 `playlistSongs`（`songs` 行已删）会被
  `.filter(Boolean)` 静默丢弃 → 服务端队列可能比客户端列表少 1 首，见 §13.4 风险 9。
  songId 身份定位下**不再影响起点正确性**（找的是歌本身，不是第 N 个位置）。

### 13.4 风险与实测结论（**2026-09-10 全部结项**）

| # | 风险 | 实测结论 | 状态 |
| --- | --- | --- | --- |
| 1 | **`startIndex` 错位（静默播错歌）** | **已确认属实并从根上消除**。<br>· 服务端 `resolveContentSongs` playlist 分支曾**缺 ORDER BY** → SQLite rowid 序 ≠ 客户端 `orderBy(position,id)` 序。抽 24 个真实歌单：**6 个「同集异序」**（25%）。<br>· **长度校验（`queued != length`）实测无效**——6 个错位样本长度全相同。<br>**最终方案：换用 `songId` 身份定位，从根上不需要"校验"**（主仓库 v2.3.22 / 客户端 v4.3.37）。<br>· 服务端 `items.findIndex(it => it.songId === songId)` —— 与两侧排序是否同源**无关**；未命中返 404 `songNotInContent`，不再静默归 0。<br>· 客户端请求体**二选一**（有 songId 就不发 startIndex），**整个投后槽位校验块已删除**（ray 判定：补丁把"服务端明确拒绝"退化成"2MB 整队重推"，比问题本身更糟）。<br>**辅助根治仍保留**：主仓库 v2.3.21 的 playlist 分支 `ORDER BY position,id`（Web 前端 / HA 集成仍传 `startIndex`，依赖它；守卫 `contentOrder.test.ts`）。<br>**修复后实测**：原先 5 个异序歌单**全部顺序完全一致**（19/19、265/265、140/140、81/81）；端到端 68 次探测 **67 次槽位一致、0 次顺序错位**。 | ✅ 已根治 |
| 2 | ~~DLNA 链路 B 未接入~~ | `dlnaCastProvider.playQueueOnDevice` 是客户端**直连设备**（服务端不参与），结构上无法用 `/v1/play`。队列规模通常可控，**接受现状**。 | ✅ 已决 |
| 3 | **真机联调** | **Windows 已跑通**（本机联调，§13.6）。三条路径全部验证：歌单起播 / 专辑起播 / 单曲点播。安卓链路逻辑与 Windows 同源（同一 `cast_peer_provider` + 同一 HTTP 客户端），无需单独实测。 | ✅ 已完成 |
| 4 | 既有缺陷 | 见 §13.5（`_playAt` 排序错位）——**与本次无关，单独排期** | ⏸ 另排 |
| 5 | **老服务端回落** | `/v1/play` 非 2xx 或 `success != true` → 返回 `false` → 回落整队推送。守卫测试已覆盖（`主通道 → 兜底通道 回落` group）。**要求服务端 ≥ v2.3.22**（songId 身份定位；v2.3.21 已含 ORDER BY 根治）。 | ✅ 已覆盖 |
| 6 | `playMode` / `enqueue` 未接入 | `/v1/play` 支持但客户端未传。**低价值项，砍掉**——投屏起播默认语义已够用，`playMode` 由既有 `setPlayMode` 单独下发。 | ✂ 不做 |
| 7 | ~~本地镜像全量重建~~ | **已解决（§12.1）**：常规 tick 只取槽位一条并**就地替换**，不再重建整个列表；`syncQueueForCast` 只在全量路径调用。 | ✅ 已解决 |
| 8 | ~~回落通道无守卫~~ | `主通道 → 兜底通道 回落` group 2 例已补 | ✅ 已完成 |
| 9 | **（新发现）服务端 `resolveContentSongs` 静默丢弃悬空 songId** | 歌单条目 `playlistSongs` 存在且 `playable/isMatched=true`，但对应 `songs` 行已删 → `rows = entries.map(...).filter(Boolean)` **静默丢一首**，服务端队列比客户端列表**少 1 首** → 该位置之后**全部错位**。实测在「华语经典」「欧美万评优质女声」上偶发（两次运行丢的是**不同的歌**，说明是扫描/删除过程中的**瞬时脏数据**，非固定记录）。<br>**已被客户端槽位校验兜住**（不一致即回落整队推送，以客户端列表为权威）。<br>**可选加固**：服务端改为「日志告警 + 保留占位」或清理悬空条目——**属数据卫生问题，不阻塞发版**。 | ⚠ 已兜底 |
| 10 | **洗牌序列双份冲突（恒播错歌）** | 见 **§13.8**（本轮根治） | ✅ 已根治 |

### 13.5 顺带发现的既有缺陷（**不属于本次改动，勿混提**）
`lib/features/library/pages/playlist_detail_page.dart` 的 `_playAt(int index)`：

- `index` 来自**渲染序**列表（`_songList` → `_loadAllSortedSongs()` 已按
  `_sortOption` 排序）
- 但方法内传入播放的 `all` 是 `repository.getAllPlaylistSongs()` 的**默认序**
- 结果：用户选「非默认排序」后点第 N 行，会按默认序第 N 首播放 → **播错歌**。
  两条通道（主/兜底）都有此问题，与本次重构无关。
- 修法方向：`_playAt` 应传入与渲染列表同序的歌曲 + 同序 index，或在排序列表里
  回查 `originalIndex` 后映射。

### 13.6 本轮验证基线（**2026-09-10 终版**）

| 项 | 结果 |
| --- | --- |
| `flutter analyze` | **0 error**（154 条存量 info，与本轮无关） |
| `flutter test test/providers/cast_peer_provider_test.dart` | **48/48 通过**（songId 定位 / 无槽位往返 / 按身份对齐镜像 / 回落 4 / 轻量轮询 4 / **服务端洗牌镜像 4**） |
| 全量 `flutter test` | **591/591 通过，0 失败**（含本轮新增洗牌镜像 4 例） |
| 发版前置守卫 | `check_interaction_feedback` ✅ / `gpu_guard_scan` ✅ / `check_workflow_yaml` ✅ / `check-l10n --gate-cjk` ✅ |
| 主仓库 `tsc` | 0 error |
| 主仓库后端全量测试 | **808/808 通过**（含新增起点定位契约 4 例 + 顺序契约 6 例 + **起点归属 9 例**，无回归） |
| 主仓库发版 | **v2.3.23**（洗牌权威化 + songId 身份定位），CI 全绿 |
| 客户端发版 | **v4.3.37 → 本轮 待发**（洗牌镜像），五条 workflow（GPU Render Guard / UI Guard / Test Suite / Desktop Lyric Guard / Build Client） |
| 真机联调（Windows） | 三条路径跑通；端到端 `tool/cast_play_chain_probe.py` **68 次探测 → 67 一致、0 顺序错位、2 跳过**（跳过来自网络抖动，非逻辑问题） |
| 顺序修复对照 | 原先 5 个「同集异序」歌单修复后**全部完全同序**（19/19、265/265、140/140、81/81） |
| queue 体积实测 | 3251 首：**863 935 B → 338 B（2 556×）** |
| 取证工具（可复跑） | `tool/cast_index_alignment.py`（legacy 端点序对比）、`tool/cast_play_chain_probe.py`（**真实 /v1/play 端到端**）、`tool/cast_set_diff.py`（集合差异定位） |

> **发版踩坑（已沉淀进 MEMORY.md）**：v4.3.35 的 `l10n guard (blocking)` 因新增日志
> 用了中文而红（该守卫在 **Test Suite** 独立 job，不在 Build Client）→ 重发 v4.3.36。
> **`lib/providers/` 下新增日志一律英文**；发版后**必须同时看 Test Suite**。

### 13.7 收尾时的检查清单

- [x] §13.4 风险 1 已实测：**确认会错位**（歌单 6/24 同集异序）→ **改用 songId 身份定位从根上消除**，不再依赖任何"投后校验"
- [x] 投后槽位校验补丁**已按 ray 要求整体删除**（补丁把服务端拒绝退化成 2MB 重推）
- [x] `playEffectiveSong` 单曲判据按 ray 纠正改为「无服务端可解析的队列上下文」
- [x] 主仓库 ORDER BY 根治保留（v2.3.21，供仍传 `startIndex` 的 Web/HA 调用方）
- [x] 真机联调通过（**Windows**；安卓链路逻辑同源，无需单独实测）
- [x] 补上风险 8 的回落守卫（2 例）
- [x] §12.1 轻量轮询落地（4 例守卫）+ 风险 7 一并解决
- [x] 全量 `flutter test` 重跑至 0 失败（587/587）；后端 799/799
- [x] SPEC 更新 + 清理已结项条目
- [x] 客户端 commit + tag 发版：**v4.3.37**（主仓库 **v2.3.22**，同批）
- [x] 结项完成——§13.1–§13.4 可整体存档；**下次开工前先看 §13.4 风险 4/9 与 §13.5**

---

### 13.8 洗牌序列权威化（**2026-09-10 根治，跨两仓**）

**ray 的原始观测**：「客户端推的**百分百不是当前播放的歌曲**」+「安卓客户端大歌单推服务器**仍然百分百不成功**」。

**真根因（不是排序、不是传输规模）**：**两份洗牌序列互不知晓**。
`QueueController.playFrom` 在 `shuffle` 模式下用 `Math.random()` **无条件覆盖调用方起点**：

```ts
// 修复前（backend/src/services/player/QueueController.ts）
const idx = mode === "shuffle" && items.length > 1
  ? Math.floor(Math.random() * items.length)   // ← 丢弃 startIndex/songId 定位结果
  : startIndex;
```

调用方（客户端传 songId、Web 前端/HA 传 startIndex）**指哪都没用**，服务端自己随机挑一首。

**真实服务器实测（192.168.10.240，修复前）**：

| 场景 | 结果 |
| --- | --- |
| shuffle + 指定首曲 ×3 | currentIndex = **2952 / 2426 / 2248**（乱漂） |
| all + 指定首曲 ×3 | currentIndex = **0 / 0 / 0**（精确） |

同一份请求只因 `playMode` 不同就天差地别 → 坐实「随机起播吞掉起点」。

**既有测试的 workaround（长期痛点旁证）**：`tests/player/integration.test.ts`、
`tests/group/GroupPlayback.test.ts`、`tests/group/GroupWatchdog.test.ts` 都在
**手工把 playMode 钉成 `"order"`** 来绕开随机 —— 说明这是早就存在、一直被回避的坑。

**拍板方案（ray 四点确认）**：① 走现有 `GET /peers/:id/queue` 回传；
② 都改为服务端随机；③ 两仓一起改一起发；④ HA 卡片也有随机模式切换，一起做。

**起点归属原则（唯一随机点）**：

| 调用方 | 行为 |
| --- | --- |
| **指定起点**（songId 命中 / startIndex 非负整数） | **绝不随机**，精确使用 |
| **未指定** + shuffle | **服务端随机**（唯一随机点） |
| 未指定 + 非 shuffle | 0 |

**主仓库改动（v2.3.23）**：
- `QueueController.playFrom`：加 `specified` 判定
  （`typeof number && Number.isInteger && >= 0`），指定则精确用；**返回实际起播下标**。
- `QueueController.snapshot`：新增 `shuffleOrder`（0..n-1 排列）/ `shufflePos`。
- `/v1/play` 回执：带 `startIndex` / `songId` / `shuffleOrder` / `shufflePos`；
  `start` 用 `null` 表达「调用方未指定」，与 `0` 明确区分。
- 守卫 `tests/player/PlayStartOwnership.test.ts`（9 例，阻塞型）：
  ★指定起点 0 + shuffle 必须播第 0 首（连跑 8 次）／★指定中间下标 17 精确命中／
  未指定 + shuffle → 随机（40 次至少两个不同落点）／snapshot 排列完整性／
  ★next 沿服务端 shuffleOrder 走。**变异验证：改回旧行为 → 4 个守卫转红。**

**客户端改动（本轮）**：
- `CastPeerState` 新增 `shuffleOrder` / `shufflePos`（镜像，只读）。
- `pollOnce` 解析服务端快照外层字段；**轻量轮询（`size=1`）也带这两个字段**
  → 不必补拉全量即可对齐。老服务端缺字段 → 保持原值，不崩。
- **客户端链路 A 本来就没有本地洗牌**（切歌由服务端驱动），本次只是把权威序列
  显式镜像进 state，供 UI 后续使用。
- 守卫 `cast_peer_provider_test.dart` 新增 4 例（★镜像到 state／★轻量轮询也能对齐／
  非 shuffle 空序列／缺字段不崩）。**变异验证：`if (rawOrder is List)` 改 `false` → 2 例转红。**

**部署后实测（真实服务器 + 模拟器，全部通过）**：

| 验证项 | 结果 |
| --- | --- |
| shuffle + 指定首曲 ×5 | **5/5 精确命中** |
| shuffle + 指定中间曲 ×5 | **5/5 精确命中**（身份定位，非行号） |
| shuffle + 不指定 ×6 | 1483/2282/3109/1325/849/815 —— **仍随机**（服务端是唯一随机点 ✅） |
| 3251 首大歌单 | queued=**3251**、耗时 **0.4s**、currentIndex 精确 |
| 回执 shuffleOrder | 长度 **3251**、完整 0..n-1 排列、`order[shufflePos] == startIndex` |
| 四模式切换回读 | shuffle/all/order/one **全部正确**，且切换**不打断当前曲** |
| **next 沿服务端序列** | 连续 4 次 `order[shufflePos] == currentIndex` **全 OK** |
| **安卓端到端**（模拟器 + 主卧音箱） | 客户端点第 2 行「哀人i」→ 服务端 `currentIndex=1`、`currentMedia` 完全一致 |

**取证工具（可复跑）**：
- `tool/verify_shuffle_rootcause.py` —— 修复前基线复现（A/B/C 对照）
- `tool/verify_fix_deployed.py` —— **部署后严格验证**（10 项断言，显式先设 shuffle 再投，
  避免上轮残留 `playMode` 导致假绿）

> **踩坑**：`verify_shuffle_rootcause.py` 的 A 段依赖「服务器当前恰好是 shuffle」，
> 一旦上轮跑完残留 `playMode=one`，A 段会退化成非 shuffle 路径 → **假绿**。
> 新脚本必须**显式设置模式**后再投。

### 13.9 HA 两仓跟随改造（**2026-09-10 已发版**）

服务端 v2.3.23 修好「起点归属」后，客户端之外的两个消费方同步收敛。
ray 拍板：集成侧**改传 songId**（身份），卡片侧**改走主通道**。

**hass-musicflow（集成）v1.5.0**：

- `async_play_content` 新增 `song_id` 参数，与 `start_index` **二选一**
  （有身份就不发行号，避免后端在「身份命中」与「行号」之间产生歧义）；
  `song_id` 未命中后端返 404，由调用方决定是否回退。
- `media_player` 服务 schema 加 `vol.Optional(ATTR_SONG_ID)`；`const.ATTR_SONG_ID`；
  `services.yaml` 补全 `play_content` 全部字段说明。
- **根因写进 docstring**：集成侧 `start_index` 来自 HA 浏览树的渲染序，
  后端 `resolveContentSongs` 用自己的 SQL 排序序，两侧**不同源** →
  指定非 0 起点会**静默播错歌**；`song_id` 走 `findIndex` 定位，与排序无关。

**hass-musicflow-card（卡片）v1.8.0**：

- `backend-client.js` 新增 `playContent(peerId, type, id, {songId, startIndex, playMode, enqueue})`
  → `POST /api/v1/play`。
- `_browserPlayCollection`：**主通道优先 + 整队推送兜底**；
  首页 `remote` 推荐歌单先 import 拿 `playlistId` 再走主通道。
  这正是「**大歌单推不动**」的根因修复（推进 3MB → 几百字节）。
- `_playRemoteCollection`：专辑/歌单导入后走主通道；
  **艺术家分支仍走整队推送**（逐曲聚合的临时队列，服务端无对应内容 id）。
- 更新 `_appendAndPlay` / `_jumpTo` 两段过时注释 —— 原文称
  「后端 playFrom 在 shuffle 下会随机起播、忽视 startIndex」，
  该 bug 已由服务端 v2.3.23 修复，注释与新事实对齐
  （jump 端点仍保留：它是「在既有队列里定位第 N 位」的正确工具，与起点 bug 无关）。

**四仓发版矩阵（全部 GitHub CI 构建，uploader 已核验 = `github-actions[bot]`）**：

| 仓库 | 版本 | 说明 |
| --- | --- | --- |
| MusicFlow（服务端） | **v2.3.23** | 起点归属修复 + `shuffleOrder`/`shufflePos` 快照 |
| MusicFlow-client | **v4.3.38** | 镜像服务端洗牌序列，移除客户端自行洗牌 |
| hass-musicflow（集成） | **v1.5.0** | `play_content` 支持 `song_id` |
| hass-musicflow-card（卡片） | **v1.8.0** | 起播改走 `/v1/play` 主通道 |

**HA 两仓踩坑（发版必查）**：

- **卡片 `dist/` 必须与源码一致**：CI 有 `Verify dist is committed and up to date`
  （`git diff --exit-code dist/hass-musicflow-card.js`）。改完 `src/` 必须
  `npx rollup -c` 重新构建并提交 dist（构建确定性，同源码两次 md5 相同）。
- **卡片版本号有两处**：`package.json` 的 `version` 与
  `src/musicflow-remote-card.js` 的 `CARD_VERSION` 常量（bundle 里是 `mt="x.y.z"`，
  控制台横幅用它核对 HACS/浏览器缓存）。只改一处 → dist 横幅与 package.json 不一致。
- **卡片 `release.yml` 的 body 是硬编码 changelog**（不是 `${{ github.ref_name }}` 模板），
  发版必须同步改写，否则 Release 页面挂着上一版说明。
- **集成 `release.yml` 校验 `manifest.json` 的 version == tag**（去 `v` 前缀比较），
  不一致直接失败——bump manifest 是发版的必要动作。
- 两仓 README 校验规则是「**合法 UTF-8、无 BOM**」，**不要求纯 ASCII**。
- **改 JSON 不要用 `json.dumps` 整文件重写**：会把紧凑数组（`["a", "b"]`）展开成多行，
  产生与语义无关的巨大 diff。正确姿势：`git show HEAD:<file>` 取原文 → `str.replace` 只改目标行。

## 十、国际化（i18n）契约（强制）

> 语言方向：**中文默认 + English**，支持跟随系统 / 中文 / English 三档切换（已接入）。任何面向用户的新增文案必须走 l10n，禁止硬编码中文；CI 守卫强制（未接入即红）。

### 10.1 实现方式

- **基础设施**：`l10n.yaml` + `lib/l10n/app_zh.arb` / `app_en.arb`，`flutter gen-l10n` 生成 `AppLocalizations`。
- **访问模式**：build 内捕获 `final loc = AppLocalizations.of(context);`，子树统一 `loc.xxx`；无 BuildContext 环境（providers / 纯函数）走 `l10nNow(ref.read(appLanguageProvider).preference)`，**禁止在 providers 误用 `AppLocalizations.of(context)`**。
- **语言偏好**：`appLanguageProvider` 持久化三档——跟随系统 / 中文 / English；首次安装默认跟随系统（非英文系统回退中文），既有用户保留已存偏好。
- **键纪律**：含 `{placeholder}` 的键必须补 `@key` 的 `description` 与 `placeholders`（含 type）；含硬编码中文的 `const` 控件必须去掉 `const`（值来自 build 期 `loc`）。

### 10.2 CI 守卫（强制）

- `tool/check-l10n.mjs`：ARB zh/en 键集合完全一致；硬编码中文扫描（排除 `l10n/` 与 `l10n/generated/`），`--gate-cjk` 已启用（不通过即红）；providers 误用 `AppLocalizations.of(context)` 检查。
- `lib/l10n/generated/` 强制纳入版本库（`git add -f`），不跑 `gen-l10n` 的 CI workflow 可直接编译。

### 10.3 硬性规定

- 新增面向用户文案：必须同时进 `app_zh.arb` + `app_en.arb`，zh/en 键集合完全一致；禁止硬编码。
- 默认中文，未覆盖语言回退中文。

## 附：开发工作流

```bash
# 安装依赖
flutter pub get

# 代码生成（修改 Freezed/Drift/Riverpod 后必须运行）
dart run build_runner build --delete-conflicting-outputs

# 分析 / 测试
flutter analyze
flutter test

# 构建：禁止本地执行！必须通过 GitHub Actions CI 构建（签名 keystore 只在仓库 Secrets）。
# 触发方式：仅版本 tag (vX.Y.Z) 触发构建与发布（§1.6 纯 tag 体系）。
# Windows 性能验收：本地 profile 构建实测（§8.5），发布产物仍走 CI release。
```
