# MusicFlow 客户端重构开发计划（DEV_PLAN）

> 版本：v2（2026-08-22）｜ 决策：**推倒重来**。原 `lib/`（Echo fork 改造）整体冻结不再修改；
> 新客户端在 `app/` 目录从零实现，对标「箭头音乐」Android + Windows 双端，直连 MusicFlow 主项目后端。

---

## 一、需求与基准

### 1.1 目标产物

| 平台 | 产物 | 基准截图/录屏 |
|------|------|---------------|
| Android | APK（`flutter build apk`） | `/root/opencode/photo/ui.jpg`、`安卓1.mp4`、`安卓2.mp4` |
| Windows | 可执行（`flutter build windows`） | `/root/opencode/photo/windowsui.png`、`windows.mp4` |

### 1.2 对标要点（从截图/录屏提取）

**移动端首页（ui.jpg / 安卓2.mp4）**
- 顶栏：应用名「MusicFlow」+ 搜索 + 设置
- 分类入口行：艺术家 / 专辑 / 歌曲 / 歌单 / 喜爱（图标+文字，横向）
- 「随机歌曲」区：标题+刷新按钮；列表项 = 封面 + 标题 + 歌手 + 音质行（`Lossless • 138kbps • FLAC • 28.44M • 03:55`）+ 红心
- 「最近更新的歌单」区：横滑卡片（封面 + 名称 + `歌曲数: N`）
- 底部迷你播放条：封面圆角 + 标题/歌词两行 + 播放暂停 + 下一首

**Windows 首页（windowsui.png）**
- 左侧栏：首页 / 艺术家 / 专辑 / 歌曲 / 歌单 / 喜爱（图标+文字，选中高亮）
- 内容区：分类条 + 随机歌曲 **多列网格** + 歌单卡片行
- 底部播放条：左侧封面+曲名+歌手｜中间 随机/上一首/**播放(大按钮)**/下一首/队列｜右侧 收藏、音量、**输出设备（切换播放器）** 等
- 进度条带时间 `00:44 / 04:32`

**全屏播放器（安卓1.mp4）**
- 黑胶唱片 + 歌词；底部控制：随机/循环、上一首、播放暂停、下一首、队列；右侧工具：红心、音量、切换播放器等

### 1.3 特色功能（必须保留强化）：切换播放器

- 迷你条与全屏均有入口；弹出面板列出 **本机** 与已发现 DLNA 设备（名称、可用/离线状态、✓ 当前目标）
- 切换即生效：控件（播放/暂停/seek/上一首/下一首/音量）立即作用于所选播放器
- 反馈三要素：①面板内 ✓ 高亮当前项 ②入口按钮图标变色（投屏=信号塔色）+语义携带设备名 ③切换成功 toast（`正在投屏到「xxx」`/`已切换为本机播放`），失败 toast 报错
- 投屏时切歌 = 将本地队列相邻曲目重新 SetAVTransportURI 并同步队列游标（UI 跟随投屏曲目）
- 迷你条/全屏显示的进度与播放态来自**当前目标**（本机 just_audio 或设备 SOAP 轮询）

### 1.4 硬性原则

1. **主项目只读**：一切以 `/root/opencode/MusicFlow` 后端为准；确需改后端必须先征得 ray 同意。
2. 认证走 OpenSubsonic：`u` + `t`(md5(password+salt)) + `s` 或 `apiKey`；公共参数 `v=1.16.1&c=MusicFlow&f=json`。
3. 所有搜索使用主项目聚合搜索端点（见下表），本地过滤仅作辅助 Tab。
4. UI 字体/间距只用设计令牌，禁止散落魔法数。
5. 新代码零告警：`flutter analyze` 无 error/warning；`flutter test` 全绿。

---

## 二、技术栈与目录

```
app/
├── pubspec.yaml            # http / just_audio / shared_preferences / cached_network_image / xml
├── lib/
│   ├── main.dart           # 入口 + 全局 Provider 注入
│   ├── app.dart            # MaterialApp、主题、路由表(命名路由)
│   ├── core/
│   │   ├── theme.dart      # 颜色 + 字体规格令牌(见 §四)
│   │   └── format.dart     # 时长/大小/音质行格式化
│   ├── data/
│   │   ├── models.dart     # Song/Album/Artist/Playlist/AggregateItem(fromJson 容错浮点)
│   │   ├── auth_store.dart # 服务器地址+账号持久化(shared_preferences)
│   │   └── api_client.dart # SubsonicAuth + REST 封装(下表全部端点)
│   ├── player/
│   │   ├── player_service.dart   # just_audio 队列/模式/位置流 + scrobble
│   │   └── dlna_service.dart     # SSDP 发现 + SOAP 控制 + 2s 状态轮询
│   ├── widgets/
│   │   ├── song_tile.dart  # 首页随机歌曲行(含音质行/红心)
│   │   ├── playlist_card.dart
│   │   ├── cover.dart      # getCoverArt 图片(带鉴权参数)统一组件
│   │   └── player_bar.dart # 迷你条(mobile)/宽条(desktop) + 切换播放器面板
│   └── pages/
│       ├── login.dart  home.dart  library_list.dart  detail_pages.dart
│       ├── search.dart  full_player.dart  settings.dart
```

---

## 三、接口映射（全部已对照主项目源码核实）

### 3.1 Subsonic 兼容（`GET /rest/*`，鉴权 query 由拦截器统一注入）

| 端点 | 关键参数 | 用途 |
|------|----------|------|
| `/rest/ping` | – | 连通/握手（返回 openSubsonic/type/serverVersion） |
| `/rest/getLicense` | – | 登录校验 |
| `/rest/getRandomSongs` | size | 首页随机歌曲 |
| `/rest/search3` | query, artistCount, albumCount, songCount | 本地库搜索 |
| `/rest/getAlbumList2` | type=newest…, size, offset | 专辑墙备用 |
| `/rest/getAlbum` | id | 专辑详情(含曲目) |
| `/rest/getArtists` / `/rest/getArtist` | id | 歌手索引/详情 |
| `/rest/getStarred2` | – | 喜爱页 |
| `/rest/star` / `unstar` | id / albumId / artistId | 收藏开关 |
| `/rest/getPlaylists` / `getPlaylist` | id | 歌单 |
| `/rest/createPlaylist` `updatePlaylist` `deletePlaylist` | – | 歌单管理(v2) |
| `/rest/stream` | id, maxBitRate?, format? | 本机播放 |
| `/rest/download` | id | 下载原始文件 |
| `/rest/getCoverArt` | id, size | 封面 |
| `/rest/scrobble` | id, submission | 上报播放 |
| `/rest/getLyricsBySongId` | id | 歌词(v2) |

### 3.2 主项目自有（前缀 `/rest/api/v1/*`，同套鉴权）

| 端点 | 参数 | 用途 |
|------|------|------|
| `GET /songs` `GET /albums` `GET /artists` | page, pageSize(≤200), query, sort | 服务端分页列表 |
| `GET /playlists` | page, pageSize(≤100), query, local, favorite, sort | 歌单分页 |
| `GET /playlists/:id/tracks` | page, pageSize(≤200) | 歌单曲目分页 |
| `POST /song-search/aggregate/search` | body `{q}` → `{items:[{id,source,name,artist,album,duration,cover,suffix,providerId,…}]}` | **聚合搜歌** |
| `POST /album-search/aggregate/search` | 同上(album 字段) | **聚合搜专辑** |
| `POST /artist-search/aggregate/search` | 同上(artist 字段) | **聚合搜艺术家** |
| `GET /recommend/home-cards` | – | 固定推荐歌单卡片(v2) |
| `GET /genres` | – | 风格(v2) |
| `GET /rest/stream-remote` | provider, source, id, title?, artist?, album?, duration?, cover? | 在线歌曲直接播放 |

> 分页响应形如 `{items:[...], total:n}`；数值字段可能为浮点，fromJson 必须容错。

---

## 四、字体规格（对齐箭头音乐，全局唯一来源 core/theme.dart）

| Token | px | 用途 |
|-------|----|------|
| display | 26 w700 | 应用名/超大标题 |
| headline | 19 w700 | 区块标题（随机歌曲等） |
| title | 15 w600 | 条目标题、侧栏项 |
| body | 13 w400 | 正文、搜索框 |
| label | 12 w600 | 分类入口文字、按钮 |
| meta | 11 w500 | 音质行、时间戳 |

---

## 五、里程碑与验收

- **M1 骨架可登录**：登录页→ping/getLicense 校验→存档；空首页壳；analyze 0 告警。
- **M2 浏览+播放闭环**：首页(分类/随机/最近歌单)、四个列表页(分页)、专辑/歌手/歌单详情、点歌即播、迷你条+全屏、收藏、scrobble。
- **M3 聚合搜索+Windows 布局**：搜索页三 Tab 聚合结果可直接播(stream-remote)；≥840px 切侧栏+网格+宽播放条。
- **M4 切换播放器(DLNA)**：SSDP 扫描→面板选择→控制反馈→投屏切歌游标同步；断线自动回本机。
- **交付门槛**：`flutter analyze` 0 error/warning；`flutter test` 全绿；`flutter build apk --debug` 成功（CI 出 release APK 另配 workflow）；Windows 构建需 Windows 环境（CI workflow 一并给出）。

## 六、负面清单

1. 禁止修改 `/root/opencode/MusicFlow` 任何文件。
2. 禁止引入文档未列的第三方包。
3. 禁止在 build() 内发请求；列表必须服务端分页。
4. 禁止把鉴权信息写进日志。
5. 旧 `lib/`、`test/` 保持只读冻结，新代码不得 import 旧路径。

---

## 七、实施状态（2026-08-22）

| 里程碑 | 状态 | 说明 |
|--------|------|------|
| M1 骨架可登录 | ✅ | 登录页 + ping 校验 + 凭据持久化；冒烟测试覆盖 |
| M2 浏览+播放闭环 | ✅ | 首页(分类/随机/最近歌单)、五个列表页(服务端分页)、三类详情、收藏、scrobble、迷你条+全屏黑胶 |
| M3 聚合搜索+Windows 布局 | ✅ | 三 Tab 聚合搜索(stream-remote 直播)+本地辅助；≥840px 侧栏+网格+宽播放条 |
| M4 切换播放器(DLNA) | ✅(代码) | SSDP 发现+SOAP 控制+2s 轮询+三重反馈+投屏切歌；真机联调待验证 |

**质量门槛达成情况**
- `flutter analyze`：**No issues found!**
- `flutter test`：**11 个测试全绿**（令牌/格式化/URL/SOAP/模型容错/登录冒烟）
- `flutter build apk --release`：本机无 Android SDK → 由 CI（`.github/workflows/build-app.yml`）出包
- Windows 构建：CI windows-latest 产出便携 zip

**依赖清单（全部已授权）**：http / just_audio / just_audio_windows / shared_preferences /
cached_network_image / xml / crypto

**旧代码冻结**：仓库根 `lib/`、`test/` 不再修改；新实现全部位于 `app/`。
