# MusicFlow Client

<p align="center">
  <img src="web/icons/Icon-512.png" alt="MusicFlow Logo" width="180" />
</p>

基于 Flutter 的 **MusicFlow 主项目全量客户端**（首发 **Windows + Android**），消费主项目后端（`ray5378/MusicFlow`，Node/TS 后端 + Vue 前端）三套接口面：**原生 API**（`/rest/api/v1/*`）、**OpenSubsonic**（`/rest/*`）、**WebSocket**（`/ws`）。

播放目标分为两类：
- **后端投屏（链路 A，切换播放器）**：DLNA / AirPlay / 群组 经主项目 `/rest/api/v1/peers*` 统一控制面，由后端推流，客户端只做控制面。
- **局域网 DLNA 直投（链路 B）**：客户端**自行 SSDP 发现 + SOAP 控制**局域网 DLNA 设备，采用双档位——**A 档·直传**（把服务端直连流 URL 交给设备，设备作为 DMR 自拉流，客户端看门狗自动续播）+ **B 档·CDS 清单**（设备支持 ContentDirectory 时接收服务端 DIDL-Lite 整队列容器自播）。不再走本地中继/推流。

## 项目定位

- 客户端是 **MusicFlow 主项目后端的全量客户端**，接口参数、数据契约、行为表现一律以主项目为准（`docs/API.md` + `SPEC.md`）。
- 交互体验对标**网易云音乐 / QQ 音乐**：迷你播放条 → 全屏播放器（黑胶唱片）→ 队列面板 → 切换播放器，操作手感、层级动效、卡片/列表呈现参考主流音乐 App。
- **首页（发现页）为基准**：展示内容与交互逻辑已被确认为正确，作为标杆保留，只做性能与 bug 修复，不改版。

## 功能特性

### 多音乐库与智能线路切换

- 支持管理多个音乐库，每个音乐库可配置多条服务器地址
- 启动时按优先级探测可达地址，自动选择当前可用线路
- 运行中连接异常时自动 fallback，高优先级线路恢复后可自动回切
- 支持手动锁定线路、延迟测速与拖拽调整地址优先级

### 播放与「切换播放器」 + 局域网直投

- 本机（`local:<uid>`）：just_audio 本地播放 + 后台播放 + 系统通知栏控制
- 后端投屏（链路 A，切换播放器）：DLNA / 群组 / AirPlay 经主项目 `/rest/api/v1/peers*` 统一控制面，由后端推流
- **局域网 DLNA 直投（链路 B，双档位）**：
  - **A 档·直传**：客户端把**服务端直连流 URL** 交给 DLNA 设备，设备自拉流；客户端作为 Control Point 每 2s 轮询 `GetPositionInfo` 展示进度 + 遥控，以「近曲末 / 墙钟兜底 / 设备自然停播」三种判定在看门狗里**主动把下一首直链推给设备**，实现自动续播
  - **B 档·CDS 清单**：设备支持 ContentDirectory 时，服务端 `GET /castPlaylist` 提供 DIDL-Lite 整队列容器，设备整队列自播，杀掉客户端也能续播完
  - 已砍掉本地中继 / HttpServer 推流，回归标准 DLNA「Control Point + DMR 自拉流」分工
- 迷你播放条 + 全屏播放器（黑胶唱片 + 歌词 + 队列 + 播放模式）
- 播放模式：`order / one / all / shuffle`；投屏中加歌 / 点歌 / 队列编辑 / 拖拽排序
- 平滑进度：远端状态 2s 轮询 + 250ms tick 本地插值，进度条无跳变（直投时以 `GetPositionInfo` + 墙钟兜底合成）

### 曲库、搜索与在线音乐

- 歌曲 / 专辑 / 歌手 / 歌单 / 收藏浏览，全部走**服务端分页 + 窗口化虚拟滚动**（与主项目前端 `useInfiniteList` 同构）
- 本地 + 在线**聚合搜索**（多平台源，条目带 provider 标识）
- 在线歌曲**直接播放**（代理流，免入库）；投屏远端需先入库拿到真实 `songId`
- 在线歌单 / 推荐导入入库，异步任务轮询（`/rest/api/v1/tasks/:id`）

### 歌词与封面增强

- 多源歌词：服务端（OpenSubsonic / Subsonic）、LRCLIB、网易云、自定义 API
- 多源封面：服务端、Fanart.tv、MusicBrainz、自定义 API
- 同步歌词逐行高亮、点击歌词跳转
- 根据封面提取主色生成播放器背景氛围，并缓存歌词与资源

### 下载与离线

- 支持歌曲、专辑、歌单的本地下载与下载管理
- 支持离线下载与缓存管理，播放统计 / 收藏统计 / 缓存统计

### 跨平台，以 Windows + Android 为先

- Flutter 一套代码覆盖 Android、Windows（首发），后续扩展 iOS / 鸿蒙 / Web
- Windows 渲染性能为硬性契约：高成本特效降级、进度更新节流、音频统一走 media_kit 后端

## 设计：对标网易云音乐

- **主题色**：网易云品牌红（`#EC4141` 区间）为强调色，暗 / 亮双主题，暗色底 + 品牌红强调
- **黑胶唱片**：播放器 / 迷你条 / 列表封面统一使用黑胶唱片视觉语言（圆盘 + 封面 + 旋转动效）
- **卡片与列表**：圆角卡片 + hover 上浮；封面 1:1 网格；当前播放曲目整行品牌红高亮
- **无障碍优先**：主要触控目标 ≥48dp，支持系统明暗模式、动态字体与减少动效

## 技术栈

| 层级 | 技术方案 |
|------|----------|
| 语言 / UI | Dart `^3.10.8` + Flutter |
| 状态管理 | flutter_riverpod + riverpod_annotation |
| 网络 | dio + 自定义 FallbackInterceptor / AddressPool 多线路 |
| 音频 | just_audio + audio_service + just_audio_background |
| 桌面音频 | just_audio_media_kit + media_kit_libs_windows_audio（Windows 唯一后端） |
| 本地存储 | drift + sqlite3 + sqlite3_flutter_libs |
| 本地配置 | shared_preferences |
| 路由 | go_router（StatefulShellRoute 分页导航） |
| 模型 | freezed + json_serializable |
| 图片 | cached_network_image + palette_generator |
| API 协议 | MusicFlow 原生 API + OpenSubsonic + WebSocket |

## 快速开始

```bash
# 安装依赖
flutter pub get

# 运行代码生成（修改 Freezed / Drift / Riverpod 后必须运行）
dart run build_runner build --delete-conflicting-outputs

# 运行应用
flutter run

# 分析 / 测试
flutter analyze
flutter test
```

> **构建约束**：禁止在本地机器执行 `flutter build`（apk / windows 等）。Android APK 与 Windows 便携包一律由 **GitHub Actions CI** 构建（push `main` 或手动 `workflow_dispatch`），产物发布为滚动 Release：`MusicFlow-{run_number}-android.apk` + `MusicFlow-{run_number}-windows.zip`。

## 项目结构

```text
lib/
├── core/                     # 常量、主题、网络基础设施、平台服务、工具类
├── data/                     # 数据模型、仓库、数据源（API / 本地存储）
├── features/                 # 功能模块（认证、发现、曲库、搜索、播放器、设置）
├── providers/                # Riverpod 状态管理
├── widgets/                  # 共享组件（App 外壳、封面、歌曲行等）
├── main.dart                 # 入口
└── app.dart                  # MaterialApp.router 与路由装配

android/  ios/  windows/  linux/  web/   # 各平台壳工程
test/                            # 单元 / 组件 / 页面测试
```

## 文档

- [技术契约规范（SPEC）](SPEC.md)：客户端必须遵守的技术契约（接口对齐、内存红线、Windows 渲染约束、负面清单）
- 主项目：[ray5378/MusicFlow](https://github.com/ray5378/MusicFlow)（Node/TS 后端 + Vue 前端，插件化架构，OpenSubsonic 兼容）

## 许可证

本项目基于 [MIT](LICENSE) 许可证开源。
