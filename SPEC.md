# MusicFlow-client 技术契约规范（SPEC）

> 本文件是 MusicFlow-client 仓库内 **AI 协作者必须遵守的技术契约**。任何改动（新功能 / 修 bug / 重构）都必须先对照本规范划定边界。

> 版本：v1（2026-08-21）｜ 维护：ray（仓库 owner）｜ AI 改动本文档需经 ray 确认

---

## 一、技术栈与工程约束

### 1.1 技术栈

| 层 | 选型 | 备注 |
|----|------|------|
| 语言 | Dart (SDK ^3.10.8) | 严格类型 |
| UI 框架 | Flutter | 一套代码覆盖 Android + Windows（首发），后续扩展鸿蒙/iOS |
| 状态管理 | Riverpod (flutter_riverpod) | Provider 模式，代码生成 |
| 网络 | Dio + WebSocket | 自定义 Fallback 拦截器，自动多线路切换 |
| 音频播放 | just_audio + audio_service + just_audio_background | 后台播放 + 系统通知栏控制 |
| 本地数据库 | Drift (SQLite) | 服务器配置、设备信息、播放历史 |
| 本地配置 | SharedPreferences | 主题、音质、DLNA 设置 |
| 路由 | GoRouter | StatefulShellRoute 分页导航 |
| 模型 | Freezed + json_serializable | 不可变数据类 + JSON 序列化 |
| 图片缓存 | cached_network_image | 封面/歌词封面 |
| DLNA | dart:io (RawDatagramSocket + HttpServer) | **零外部依赖**，纯 Dart 实现 SSDP + SOAP + 本地 HTTP 中继 |

### 1.2 基础库（已由 Echo 提供）

| 库 | 版本 | 用途 |
|----|------|------|
| flutter_riverpod | ^2.6.1 | 状态管理 |
| dio | ^5.7.0 | HTTP 客户端 |
| just_audio | ^0.9.42 | 音频播放 |
| audio_service | ^0.18.17 | 后台播放服务 |
| drift | ^2.22.1 | SQLite ORM |
| go_router | ^14.8.1 | 路由 |
| cached_network_image | ^3.4.1 | 图片缓存 |
| freezed_annotation | ^2.4.4 | 不可变模型 |
| json_annotation | ^4.9.0 | JSON 序列化 |

### 1.3 对齐原则（最高优先级）

- **客户端必须对齐主项目 `/root/opencode/MusicFlow`**：接口参数、数据结构、行为表现均以主项目为准。
- **主项目是只读的，禁止修改**。任何情况下不得改动主项目的代码/文档。
- **唯一例外**：若某功能不修改主项目就无法实现，必须**先向开发者（ray）说明原因并询问，得到明确确认后**才可以动主项目；未获确认前只能在客户端侧变通实现。

### 1.4 硬性工程约束

- **依赖管理**：严禁引入未授权的新第三方库。DLNA 模块必须用 `dart:io` 原生实现（RawDatagramSocket + HttpServer），不引入 `upnp`、`ssdp` 等第三方包。
- **命名规范**：
  - 文件/目录：全小写 + 下划线（`ssdp_discovery.dart`、`soap_control.dart`）
  - 类/接口/枚举：大驼峰（`SsdpDiscovery`、`DlnaDevice`）
  - 函数/变量：小驼峰（`discoverDevices`、`castSession`）
  - 常量：全大写 + 下划线（`SSDP_ADDR`、`SSDP_PORT`）
- **代码位置**：所有代码在 `lib/` 下。核心层 `lib/core/`，数据层 `lib/data/`，功能模块 `lib/features/`，DLNA 模块 `lib/core/dlna/`。
- **语言**：UI 文本和代码注释统一使用**中文**。

### 1.5 内存红线

- 新增任何常驻 `Map`/`Set`/数组缓存，**必须**带上限（FIFO/LRU）或清理机制（TTL）。
- SSDP 设备列表：最多缓存 100 台设备，超时 10 分钟未发现标记离线。
- SOAP 调用超时：单次 8 秒，累计 3 次失败标记设备不可用。
- 本地 HTTP 中继：单个连接最多持续 6 小时，过期自动断开。

---

## 二、项目架构

### 2.1 目录结构

```
lib/
├── core/                     # 常量、主题、工具、网络、DLNA
│   ├── constants/            # API 常量、SSDP 常量
│   ├── dlna/                 # DLNA 模块（SSDP/SOAP/中继/设备管理）
│   ├── design/               # 设计系统（Echo Design）
│   ├── network/              # 网络层（FallbackInterceptor、AddressPool）
│   ├── platform/             # 平台适配
│   ├── services/             # 核心服务（日志、错误处理）
│   ├── theme/                # 主题定义
│   └── utils/                # 工具函数
├── data/
│   ├── models/               # 数据模型（Freezed）
│   ├── repositories/         # 数据仓库（API + DB）
│   └── sources/              # 数据源
│       ├── database/         # Drift 数据库
│       ├── lyrics/           # 歌词源
│       ├── remote/           # 远程 API 客户端
│       └── subsonic_api_client.dart  # Subsonic API 核心
├── features/
│   ├── auth/                 # 登录/多服务器管理
│   ├── discover/             # 首页发现
│   ├── explore/              # 探索
│   ├── library/              # 曲库（歌曲/专辑/歌手/歌单）
│   ├── offline/              # 离线下载
│   ├── player/               # 播放器（全屏/迷你/队列）
│   └── settings/             # 设置（主题/音质/DLNA）
├── providers/                # Riverpod Providers
├── widgets/                  # 共享组件
├── app.dart                  # MaterialApp + GoRouter
└── main.dart                 # 入口
```

### 2.2 数据流

```
用户操作 → Feature Widget → Provider → Repository → API Client / DB
                                    ↓
                              Audio Service (播放)
                                    ↓
                              DLNA Manager (投屏)
```

### 2.3 与 MusicFlow 服务端通信

客户端通过 **Subsonic API** 与 MusicFlow 服务端通信（`/rest/` 路由前缀）。

**认证方式**（二选一）：
1. **Token/Salt**：`MD5(password + salt)` 作为 `t` 和 `s` 查询参数
2. **API Key**：`apiKey` 查询参数（OpenSubsonic 兼容）

**核心 API 端点**：

| 端点 | 用途 |
|------|------|
| `GET /rest/ping` | 服务器连通性检测 |
| `GET /rest/getMusicFolders` | 获取音乐库列表 |
| `GET /rest/getAlbumList` | 专辑列表（最近/最常/随机） |
| `GET /rest/getArtist` | 歌手详情 |
| `GET /rest/getAlbum` | 专辑详情 |
| `GET /rest/getSongsByGenre` | 按风格获取歌曲 |
| `GET /rest/search2` | 搜索（歌曲/专辑/歌手） |
| `GET /rest/getPlaylists` | 歌单列表 |
| `GET /rest/getPlaylist` | 歌单详情 |
| `GET /rest/getStarred` | 收藏歌曲 |
| `POST /rest/star` | 收藏 |
| `POST /rest/unstar` | 取消收藏 |
| `GET /rest/stream` | 播放流（支持 token 参数免鉴权） |
| `GET /rest/getCoverArt` | 封面图片 |
| `GET /rest/getLyrics` | 歌词 |
| `POST /rest/scrobble` | 播放记录 |

**补充 API（MusicFlow 自有）**：

| 端点 | 用途 |
|------|------|
| `GET /v1/recommend/home-cards` | 首页推荐卡片 |
| `GET /v1/daily-recommend` | 每日推荐 |
| `GET /v1/genres` | 风格列表 |

---

## 三、DLNA 投屏模块（核心新增）

### 3.1 模块结构

```
lib/core/dlna/
├── ssdp_discovery.dart       # SSDP 多播设备发现
├── device_description.dart   # 设备描述 XML 解析
├── soap_control.dart         # SOAP AVTransport/RenderingControl 控制
├── local_relay.dart          # 本地 HTTP 中继（流代理）
├── dlna_manager.dart         # 统一管理（发现+控制+中继）
├── dlna_models.dart          # 设备/会话/状态数据模型
└── dlna_repository.dart      # 设备持久化（Drift）
```

### 3.2 SSDP 设备发现

- 发送 `M-SEARCH * HTTP/1.1` 到 `239.255.255.250:1900`
- 解析 `LOCATION` 响应头，获取设备描述 URL
- 抓取 `description.xml`，提取 `friendlyName`、`UDN`、`AVTransport` 控制 URL
- 支持 `NOTIFY` 被动监听（设备上下线实时通知）
- 设备超时 10 分钟未收到 SSDP 消息 → 标记离线

### 3.3 SOAP 控制

**AVTransport 服务**：
- `Stop` → 停止播放（容错，设备可能已停止）
- `SetAVTransportURI` → 设置流地址 + DIDL-Lite 元数据
- `Play` → 开始播放
- `Pause` → 暂停
- `Seek` → 跳转进度（REL_TIME 格式 HH:MM:SS）
- `GetTransportInfo` → 获取播放状态
- `GetPositionInfo` → 获取当前进度/时长
- `SetNextAVTransportURI` → 预加载下一首（无缝切歌，设备支持时使用）

**RenderingControl 服务**：
- `SetVolume` → 设置音量（0-100）
- `GetVolume` → 获取音量
- `SetMute` → 静音开关
- `GetMute` → 获取静音状态

**错误处理**：
- SOAP 调用超时 8 秒
- 单个设备连续 3 次 SOAP 失败 → 标记不可用
- 所有 SOAP 错误只记日志，不阻断主流程

### 3.4 本地 HTTP 中继

**原理**：
```
MusicFlow 服务端 ──(带鉴权)──▶ 客户端 App ──(本地 HTTP)──▶ DLNA 设备
```

- 客户端在本地 LAN 启动 `HttpServer`（默认端口 46401）
- 设备收到的流地址格式：`http://<客户端局域网IP>:46401/stream?token=<sessionToken>`
- 客户端收到请求后，从 MusicFlow 服务端拉流（带 API Key 或 Token），转发给设备
- 支持 Range 请求（设备 seek 时需要）
- 单个流会话最多持续 6 小时

### 3.5 设备状态轮询

- 投屏时每 2 秒轮询一次 `GetTransportInfo` + `GetPositionInfo`
- 更新播放状态（播放/暂停/停止）和进度条
- 设备离线（SOAP 调用失败）→ 自动断开投屏，恢复本地播放

### 3.6 本机 ↔ 设备切换

- 用户可在播放器切换输出设备（本机 / DLNA 设备）
- 投屏时暂停本地播放，切回时恢复
- 投屏状态持久化（设备 ID + 会话 token）

---

## 四、UI 设计规范

### 4.1 设计方向

参考**箭头音乐（Amcfy）** 的布局风格：
- 现代化、简洁、有质感
- 黑胶唱片播放器风格
- 暗/亮双主题

### 4.2 布局适配

| 屏幕宽度 | 布局 |
|----------|------|
| < 600dp | 单列 + 底部导航 + 底部播放条 |
| 600-839dp | 双列 + 底部导航 + 底部播放条 |
| ≥ 840dp | 左侧导航栏 + 底部播放条（桌面模式） |

### 4.3 核心页面

1. **登录页**：多服务器管理，填地址/账号/密码，连接检测
2. **首页**：最近添加 / 每日推荐 / 快捷入口
3. **曲库页**：歌曲 / 专辑 / 歌手 / 风格 / 歌单 / 收藏
4. **搜索页**：本地 + 在线搜索
5. **播放页**：黑胶唱片 + 歌词 + 控制按钮 + 队列
6. **设置页**：主题 / 音质 / DLNA / 关于

### 4.4 播放器设计

- **迷你播放器**：底部条，封面缩略图 + 标题/歌手 + 播放/暂停 + 下一首
- **全屏播放器**：黑胶唱片动画 + 歌词滚动 + 进度条 + 控制按钮 + 音量
- **队列管理**：可拖拽排序，支持播放模式切换

---

## 五、测试规范

### 5.1 单元测试

| 模块 | 测试文件 | 重点 |
|------|----------|------|
| SSDP | `test/dlna/ssdp_discovery_test.dart` | M-SEARCH 构造、响应解析、超时处理 |
| SOAP | `test/dlna/soap_control_test.dart` | 信封构造、XML 转义、错误码处理 |
| 中继 | `test/dlna/local_relay_test.dart` | 会话创建、Range 请求、过期清理 |
| API | `test/data/subsonic_api_test.dart` | 认证参数注入、响应解析 |
| 队列 | `test/providers/queue_test.dart` | 播放队列、切歌逻辑、播放模式 |

### 5.2 集成测试

- 连接 MusicFlow 实例（本地或远程）
- 登录 → 浏览曲库 → 搜索 → 播放 → 收藏
- DLNA 扫描 → 投屏 → 暂停/切歌/音量 → 切回本机

### 5.3 构建门槛

- `flutter analyze` 0 错误
- `flutter test` 全绿
- `flutter build apk` 成功（Android）
- `flutter build windows` 成功（Windows，需 Windows 环境）

---

## 六、负面清单

> AI 在动手前逐条默读；交付时逐条确认「未违反」。

1. **禁止**引入未授权的新第三方库。DLNA 模块必须用 `dart:io` 原生实现。
2. **禁止**修改 Echo 已有的 Subsonic API 兼容逻辑（保持与 Navidrome 的兼容性）。
3. **禁止**在 DLNA 模块中使用 `Future.delayed` 或 `Timer` 做轮询——必须用 `Stream.periodic` 或 `Timer.periodic` 并在取消时 dispose。
4. **禁止**在本地 HTTP 中继中暴露任何鉴权信息（API Key / Token 不得出现在设备收到的 URL 中）。
5. **禁止**在 UI 中硬编码颜色/字体大小——必须使用 `Theme.of(context)` 或 `EchoDesign` 常量。
6. **禁止**一次加载全表后在前端过滤——所有列表必须分页或使用 SQL 级别过滤。
7. **禁止**在 Widget `build()` 中发起网络请求或数据库查询。
8. **禁止**在 catch 块中吞异常——必须打日志含上下文。
9. **禁止**删除/修改 Echo 已有的测试文件——只新增。
10. **禁止**私自提交 / push / 打 tag（提交与发布流程由 ray 控制）。

---

## 七、交付清单

每次交付必须包含：

1. **代码**：通过 `flutter analyze` + `flutter test`
2. **提交说明**：列出本次涉及文件 + 上下游影响面
3. **截图**：UI 改动需附截图（Android / Windows）
4. **测试报告**：新增/修改功能的测试覆盖情况

---

## 附：开发工作流

```bash
# 安装依赖
flutter pub get

# 代码生成（修改 Freezed/Drift/Riverpod 后必须运行）
dart run build_runner build --delete-conflicting-outputs

# 分析
flutter analyze

# 测试
flutter test

# 构建
flutter build apk      # Android
flutter build windows  # Windows
```
