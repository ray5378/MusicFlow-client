# v3.4.63 清除全部 6 个历史测试失败：全量测试首次零失败 总览

## v3.4.63（本轮）

独立任务：把长期挂账的 6 个历史失败测试逐个排查修复（不涉及新功能，只清技术债）。**修复后全量 +475 -0，本项目第一次全量测试 0 失败。**

### 一、player_backdrop ×2（`test/features/player/player_backdrop_test.dart` + `lib/features/player/widgets/player_backdrop.dart`）
- **根因 1（断言过期）**：`c961f1f`（对齐箭头音乐 MINI 悬浮胶囊）把 mini 圆角 16→24 且新增胶囊阴影（`0x14000000` blur 12 offset(0,4)），测试仍断言 16 与 `boxShadow isEmpty`。
- **根因 2（实现 bug）**：`_PlayerBackdropSpec.lerp` 在 progress=1.0 时 `BoxShadow.lerpList` 返回 `scale(0)` 的残影阴影（blur 0 但 alpha 仍在），落点 stage 语义应为无阴影 → 修复 lerp 边界（progress>=1 返回空列表）。
- **修复**：测试 4 处圆角断言 16→24、4 处阴影断言对齐新语义；实现 lerp 边界修正。

### 二、music_flow_app_shell ×2（`test/widgets/music_flow_app_shell/music_flow_app_shell_test.dart`）
- **根因 1（断言过期）**：`c961f1f` 把 compact 分支（`includeBottomSafeArea=false`）MiniPlayer slot 底部 padding 从 `xxs(4)` 改为 `sm(12)`，测试仍断言间距 4 → 2 处改 12。
- **根因 2（过期 key）**：`mini-player-progress` key 已随设计变更移除（底部进度条改为封面外圈进度环 + `mini-player-scrubber` 手势层），320dp 缩放测试引用过期 key → 改用 `mini-player-scrubber`（几何断言语义不变：左缘/底缘贴齐）。

### 三、music_flow_network_status_bar ×1（`music_flow_network_status_bar.dart` + 测试）
- **根因**：`1a5dce9`（DLNA 投屏方案）引入「启动后 30 秒静默恢复窗口」，用 `DateTime.now()`（真实时钟）判断；测试用 fake clock 推进时间、真实时钟才过几毫秒 → 永远处于静默窗口 → 网络恢复 toast 永不出现。
- **修复**：静默窗口改为**可注入参数** `startupSilentRecoveryWindow`（生产默认 30s，测试传 `Duration.zero`），不改变生产行为。

### 四、ssdp_discovery ×1（`test/core/dlna/ssdp_discovery_test.dart`，用户指示「用本地环境重做」）
- **根因**：本机双网卡——以太网（Intel I219-V）= 192.168.10.188 + `et_6_55tp`（**EasyTier VPN 隧道**）= 192.168.100.188。隧道接管系统默认路由/默认多播出接口，测试发送端用 `anyIPv4` 发多播时从隧道出去，而生产监听端（`_skipInterface` 按 `et_` 前缀过滤后）只 join 物理以太网组 → 跨网段收不到 NOTIFY（历史 flaky 根因）。
- **修复（测试侧，生产零改动）**：测试新增与生产 `_skipInterface` **完全一致**的过滤辅助函数（关键字表 + `et_`/`et-` 前缀 + 保留网段 IP），统一应用到 responder join / 显式注入地址 / NOTIFY 发送端三处；发送端显式绑定物理接口 IPv4 锁定出接口 + 4 轮重发容忍时序。**本机连跑 8/8 稳定通过**；CI（Linux 单网卡）链路本就固定，改动只是让测试模拟行为与生产规则对齐，无 CI 行为差异。

### 验证
- analyze 零 error；ssdp 本机连跑 8/8；**全量 +475 -0（首次全绿，6 个历史失败全部清零）**。
- 发版：commit 2965153 + tag v3.4.63 → CI 三流水线（Build Client / Test Suite / UI Guard）→ Release 三产物 uploader 均 `github-actions[bot]`，合规闭环。

---

# v3.4.62 Windows 右键菜单修复 + 搜索入口移入「库」导航 总览

## v3.4.62（本轮）

### 一、Windows 右键不弹菜单（用户反馈「安卓可长按,Windows 右键没弹窗」）
- **根因**：`MusicFlowPressable.onLongPress` 由 `InkWell.onLongPress` 消费，而 InkWell 的长按手势（`LongPressGestureRecognizer`）**只跟踪主按钮**（触摸/鼠标左键按住），鼠标右键按下根本不进入该手势 → 安卓长按弹菜单正常、Windows 右键完全无反应。
- **修复**（`lib/core/design/components/music_flow_pressable.dart`）：复用现有 raw `Listener.onPointerDown`，当 `event.buttons == kSecondaryButton` 时**按下立即触发 `onLongPress`**（桌面端「右键 = 长按菜单」语义），且不参与按压缩放反馈（与触屏长按视觉区分）。
- **回归测试**（`music_flow_pressable_test.dart` +2 例）：①鼠标右键（`startGesture` + `kSecondaryButton`）触发 `onLongPress` 且不触发 `onPressed`；②无 `onLongPress` 时右键无副作用。

### 二、搜索入口从首页右上角移入「库」分类导航第一位（用户要求）
- 需求：右上角搜索按钮移到分类导航首位，样式/颜色与库按钮一致，标注「探索」；最终顺序 **探索 喜欢 歌单 歌曲 艺术家 专辑**。
- **改动**（`lib/features/discover/pages/discover_page.dart`）：
  1. `CategoryNavBar._items` 首位插入 `('探索', AppIcons.search, const SearchPage())`——复用 `_CategoryNavItem`（accent 图标 26px + 下方 metadata 文字标注），样式颜色与其余库按钮完全一致，点击打开与搜索条同一个全屏 `SearchPage`。
  2. compact 标题行右侧 `home-header-search` 按钮与 `Spacer` 移除（搜索入口唯一化，避免重复）。
- **回归测试**（`discover_page_test.dart` 更新+新增）：分类入口断言 5→6 项含「探索」；「探索」点击打开全屏搜索页；「探索」位于「喜欢」左侧（第一位）。

### 验证
- analyze 零 error；全量 +469 -6 = 5 历史基线 + ssdp flaky x1，零新回归（新增 2 例右键测试全过）。
- 发版：commit 2ae4da7 + tag v3.4.62 → CI 三流水线全 success → Release 三产物（android.apk 46.6MB / windows-setup.exe 32.9MB / windows.zip 39.8MB）uploader 均 `github-actions[bot]`，draft=false，合规闭环。

---

# v3.4.61 播放卡片：竖条压缩到 2/3 + 播放时自动隐藏按钮 总览

## v3.4.61（本轮）

### 一、首页歌单封面「播放时竖条与播放按钮重叠 + 竖条过高」（用户截图反馈）
- **根因**：v3.4.58 引入 `_PlaylistCoverPlayButton` 与 v3.4.58 的 `NowPlayingCoverOverlay`（3 根跳动竖条）**都锚定封面右下角**：按钮用 `Positioned(right, bottom)`，竖条用 `Align(alignment: bottomRight)`，Android compact 屏按钮常驻 → 两控件完全重叠。同时竖条在 v3.4.58 改动后占封面高 20%~34%，比例仍偏厚。
- **修复**：
  1. `DiscoverPlaylistCard` 渲染逻辑加条件 `if (onPlay != null && !isNowPlaying)`：正在播放（`isNowPlaying=true`）时自动隐藏播放按钮 —— 已有竖条作为「正在播放」视觉指示，不需要叠按钮。
  2. `NowPlayingCoverOverlay` 竖条高度：20%~34% → **13%~23%**（整体压缩到现在的 2/3）；顶 doc comment 同步更新，避免视觉过厚与下方按钮争抢空间。
- **回归测试**（新文件 `test/features/discover/discover_playlist_card_test.dart`，3 例）：
  1. 非播放态：`_PlaylistCoverPlayButton` 渲染、`NowPlayingCoverOverlay` 不渲染；
  2. 播放态（核心修复）：`_PlaylistCoverPlayButton` **不渲染**、`NowPlayingCoverOverlay` 渲染；
  3. `onPlay=null` 不论 `isNowPlaying` 都不渲染按钮。

### 验证
- analyze 零 error；新回归测试 3/3 通过；discover/widgets/library/player 相关测试 +136 -5 = 5 历史基线，零新回归；全量 +467 -6 = 5 历史基线 + ssdp flaky x1，零新回归。
- 发版：commit eecfb6e + tag v3.4.61 → CI 三流水线全 success → Release 三产物（android.apk 44.4MB / windows-setup.exe 31.3MB / windows.zip 37.9MB）uploader 均 `github-actions[bot]`，draft=false，合规闭环。

---

# v3.4.60 平台推荐播放按钮 + 搜索按钮贴右缘 + Windows 任务栏图标排查 总览

## v3.4.60（本轮）

### 一、平台推荐歌单封面播放按钮补齐（用户反馈）
- **根因**：`PlatformRecommendSection`（平台推荐）的 `DiscoverPlaylistCard` 此前只有 `onPressed`（打开详情/导入），没传 `onPlay` → 封面右下角半透明播放按钮不渲染；`LocalPlatformRecommendSection`（本地随机）v3.4.58 已接，两区块不一致。
- **修复**：新增 `_playRecommendPlaylist`（已入库直接反查本地 id 播放；未入库先经 `/v1/online/:providerId/recommend/import` 幂等导入再 `playLocalPlaylistById` 整单播放），卡片接 `onPlay`（loading 时不显示）。

### 二、安卓首页搜索按钮位置（用户反馈「从源头查,一直没做好」）
- **根因链**：v3.4.50 用户反馈「搜索按钮贴最右边」→ 用 `Expanded` 把标题按钮撑满实现贴右；v3.4.51 用户反馈「标题按钮区域太长（绿色高亮区占满）」→ 改 `Flexible(loose)` 修区域，**代价是搜索按钮回到紧跟标题文字、不再贴右缘** → 位置问题复发。
- **修复**：标题按钮 `Flexible(loose)`（区域只包文字）+ **中间 `Spacer`** + 搜索按钮，两个诉求同时成立。
- **回归测试**：断言搜索按钮右缘距窗口右缘 == 标题按钮左缘距窗口左缘（对称页边距），未贴右则失败。

### 三、Windows 任务栏图标「还是旧图标」（排查结论：非代码问题）
- 代码链路全查：`Runner.rc` → `resources/app_icon.ico`（HEAD 与工作区 sha1 一致，红圆白音符 7 尺寸）→ `win32_window.cpp` `LoadIcon(IDI_APP_ICON)` → CMake 编译进 exe，无 CI 图标覆盖步骤。
- **产物级验证**：下载 v3.4.59 windows.zip，解析 exe PE 资源——内嵌 7 张 PNG 与仓库 `app_icon.ico` **sha1 全匹配**（MATCH: True）。产物图标是正确的。
- **结论**：用户侧任务栏旧图标 = Windows 图标缓存/旧进程残留。处理：完全退出应用（托盘退出）→ 重启资源管理器或注销/重启；任务栏固定图标取消固定再重新固定。

### 验证
- analyze 零 error；discover 相关测试全过（新增 2 例回归：搜索按钮贴右缘 / 平台推荐播放按钮）；全量 +465 -5 = 5 历史基线，零新回归。
- 发版：commit 64720fb + tag v3.4.60 → CI 三流水线全 success → Release 三产物（android.apk 44.4MB / windows-setup.exe 31.3MB / windows.zip 37.9MB）uploader 均 `github-actions[bot]`，draft=false，合规闭环。

---

# v3.4.59 随机模式队列居中修复 + 艺术家长按菜单 / v3.4.58 长按菜单+封面播放按钮 总览

## v3.4.59：随机模式长队列当前播放自动居中 + 艺术家长按菜单补齐（本轮）

### 一、队列居中 bug 修复（用户真实环境反馈）
- **现象**：Windows 桌面版随机模式（队列 100+ 首）下，当前播放的歌曲不在队列视口中间（永久停在顶部）。
- **根因**：`_AutoCenterQueueList`/`_AutoCenterCastList` 原用固定行高 56 粗估 offset（`index*56`），随机模式长队列实际行高 ~64，误差随 index 线性累积 → 粗估位置偏出可视区+cacheExtent → 目标行（GlobalKey）永不实例化 → `currentContext` 恒 null → 居中彻底失效。
- **修复**（`lib/features/player/widgets/play_queue_sheet.dart`）：比例法粗估 `maxScrollExtent * (index/last)`（误差仅来自行高不均、不随 index 累积）+ 多轮逼近（最多 4 轮，每轮 `ratio += 0.15` 向队尾推进），实例化后 `Scrollable.ensureVisible(alignment: 0.5)` 精确居中。普通队列与投屏队列（`_AutoCenterCastList`）同策略同步修。
- **回归测试**：120 首队列 + currentIndex=100，断言当前行实例化且位于视口中部 20%~80%；注意无限跳动竖条动画使 pumpAndSettle 永不稳定，用 5 次固定时长 pump。

### 二、艺术家长按菜单补齐（长按/右键菜单全类型覆盖）
- 新建 `lib/features/library/widgets/artist_options_sheet.dart`：`showArtistOptionsSheet` 三操作——「播放歌手热门歌曲」（getTopSongs + playEffectiveQueue origin=artist）、「收藏/取消收藏歌手」（setArtistStarred + invalidate starredProvider）、「添加到播放列表」。
- `MusicFlowArtistRow` 新增 `onLongPress`（透传 `MusicFlowPressable`）。
- 接线：收藏页艺术家 tab、艺术家库 `artist_list_page`、搜索页（专辑/艺术家/歌单三处）、歌单库 `playlist_search_page`。
- 至此**歌单/专辑/歌曲/艺术家四类列表项全类型支持长按菜单**。

### 验证
- analyze 零 error；相关测试 +21 全过；全量 +461 -7 = 5 历史基线 + ssdp flaky ×2，零新回归。
- 发版：tag v3.4.59 → CI 三流水线验证。

---

## v3.4.58：列表项长按/右键菜单 + 首页歌单封面半透明播放按钮 + 竖条底部平整化（72daf13）

### 一、列表项长按/右键菜单（喜欢/取消喜欢、播放等）
- 歌曲行：专辑详情页、歌曲列表、收藏页、播放队列、remote 三页面（专辑/艺术家/歌单）、搜索页均接入 `showSongOptionsSheet`（播放/收藏/加入队列等）。
- 歌单：首页 3 处本地歌单卡 + 搜索页 + 歌单库 + 收藏页接入 `showPlaylistOptionsSheet`。
- 专辑：搜索页 + 收藏页 + 专辑库接入 `showAlbumOptionsSheet`。
- 播放/收藏类数据操作在 sheet 内直接执行（关 sheet 后 Toast 反馈）；「添加到歌单」等返回 action 由调用方处理。

### 二、首页歌单封面半透明播放按钮
- `discover_media_widgets.dart` 新增 `_PlaylistCoverPlayButton`：Android（compact）常驻半透明显示，桌面（wide）平时隐藏、鼠标 hover 封面时才显示。

### 三、当前播放封面跳动竖条底部平整化（截图反馈）
- `now_playing_bars.dart`：竖条高度比例 `size*0.38~0.62` → `size*0.20~0.34`（只占封面底部一小块）；`Row(crossAxisAlignment: end)` + `SizedBox(height: maxBarHeight)` 实现底部贴齐、跳动从底部往上（网易云音柱条观感）。

### 验证与状态
- 全量 +461 -7（5 历史基线 + ssdp flaky），零新回归；CI Build Client / Test Suite / UI Guard 三流水线全 success。
- Release 三产物（android.apk 44.4MB / windows-setup.exe 31.3MB / windows.zip 37.9MB）uploader 均 `github-actions[bot]`，draft=false，合规闭环。

---

# v3.4.57 当前播放封面跳动竖条指示器（网易云风格）/ v3.4.56/55/54/53 总览

## v3.4.57：当前播放封面跳动竖条指示器

### 用户需求
> 当前播放的无论是歌单、音乐、专辑等等，在封面（包括首页、队列等等）加上半透明阴影遮罩，遮罩上 3 根白色随机跳动的竖直长方形（类似网易云「每日推荐」播放效果）；播放队列中封面较小则竖条放正中间。**竖条大小和位置要自适应封面大小。**

### 实现
- **`lib/widgets/now_playing_bars.dart`（新建）**：`NowPlayingCoverOverlay` 组件。所有尺寸按封面边长等比缩放 `k = (size/160).clamp(0.55, 3.0)`（竖条宽 6k / 间距 4.5k / 圆角 2k / 遮罩内边距 7k，竖条高度在封面 0.38~0.62 倍间跳动）；`_JumpingBars` 用 AnimationController(900ms repeat) + 3 根竖条独立相位 [0,1.7,3.6] / 速度 [1,1.35,0.82] / 幅度 [1,0.72,0.88]，双正弦叠加形成「不规则跳动」。大封面 `Alignment.bottomRight`，小封面（队列 48~56px）`Alignment.center`。
- **`lib/providers/queue_origin_provider.dart`（新建）**：`QueueOrigin`（kind + id）记录当前播放队列来源，`playEffectiveQueue` 统一写入，使歌单卡/专辑卡能识别「正在播放的是哪个」。
- **接入点**：歌曲行封面居中（`isCurrent`，替换旧 equalizer 角标）；首页歌单卡/专辑卡、收藏页、专辑列表、详情页大封面右下角（`isNowPlaying`）；remote 页面歌曲行 `isCurrent`。

### 测试
- 更新断言：`music_flow_song_row_test` / `play_queue_sheet_test` 从 `AppIcons.equalizer` → `find.byType(NowPlayingCoverOverlay)`。
- **无限动画 × pumpAndSettle 冲突**：repeat 动画使 `pumpAndSettle` 永久超时，`play_queue_sheet_test`（drag 后）与 `player_navigation_flow_test`（3 处页面切换）改用固定时长 pump。
- analyze 零 error；全量 +461 -6 = 5 个历史基线 + ssdp flaky，零新回归。

### 状态
- commit e030245 + tag v3.4.57 已推送，CI Build Client 后台跟踪中。

---

# v3.4.56/55/54/53 品牌图标统一替换（已发版）

## v3.4.53：用新红圆白音符 logo 替换主项目 + 客户端全平台 + HA 集成的全部品牌图标

### 用户原始需求
> "用这个 icon 替换所有原有的 logo.png / favicon.png / apple-touch-icon.png 等等的主项目和三端图标（包括主项目、客户端前后端、HA 卡片所有的包括 readme 等文档）"

提供的新图标：1920×1920 jpg，黑底 + 红色实心圆 + 白色音符，Apple-Music 风格纯红。

### 范围（4 个仓库，最终涉及 3 个）
| 仓库 | 是否涉及 | 实际改动 |
|---|---|---|
| MusicFlow-client（Flutter 客户端） | ✅ | 38 个文件：web 5 + Android 13（含 2 XML 背景白→黑） + iOS 22 AppIcon + iOS 3 LaunchImage + Windows ico + 新增 assets/icon/ 母版 + tools/generate_icons.py |
| MusicFlow 主项目（Hono + Vue3） | ✅ | `frontend/public/favicon.png`(96) + `apple-touch-icon.png`(180) + `logo.png`(2048) 共 3 个 |
| hass-musicflow（HA Python 集成） | ✅ | `logo.png`(512) + `brand/icon.png`(512) + `brand/logo.png`(512) + `custom_components/musicflow/brand/icon.png`(256) + `brand/logo.png`(512) 共 5 个 |
| hass-musicflow-card（HA 卡片 TS） | ❌ | 无品牌图标资产，README 无图引用 → 无需改 |
| hassio-addons | ❌ | 无图标资产 → 无需改 |

### 处理策略
- **透明底母版**（红圆+白音符自包含）：作为通用版——任何背景都清晰（白底 README、HA 浅色界面、Web favicon、HA brand 图标、客户端 Android legacy/foreground）。
- **黑底母版**：仅用于 iOS AppIcon（系统要求不透明 + 圆角裁切）+ iOS LaunchImage 启动图 + PWA maskable（必须不透明满幅）。
- 母版生成：源图红圆 bbox 动态定位 → 10% padding 方形裁切 → 双版（黑/透明）各 1024×1024 母版 → 平台尺寸由脚本缩放。
- 脚本：`tools/generate_icons.py`（PIL 单依赖，幂等可重跑，源图替换即可重生所有平台图标）。
- Android adaptive icon 背景：`@android:color/white` → `@android:color/black`（红圆配黑底，避免白底突兀）。
- `drawable/ic_notification.xml` 通知栏白色音符 vector **保留**（通知栏单色规范）。
- README 无图片引用（grep 全部命中零 logo 引用），文档无遗漏。

### 文件总数
- MusicFlow-client：38 改动 + 2 XML + `assets/icon/`(5 文件) + `tools/generate_icons.py` 1 个
- MusicFlow 主项目：3 改动
- hass-musicflow：5 改动

### 状态
- 待发版客户端 v3.4.53。
- 主项目与 hass-musicflow：本地 commit 完成（无功能变更、不 bump 版本号），tag 由用户决定（lockstep 惯例 vs 仅资产更新）。

---

# v3.4.52 加入库按钮溢出 + 入库成功自动刷新最近更新歌单（已发版）/ v3.4.51/50/49/48/47 总览

## v3.4.52：安卓加入库按钮窄屏溢出 + 客户端入库成功自动刷新最近更新

### 反馈/需求（用户两条）
1. **截图反馈**（320dp 安卓）：`RemotePlaylistPage` 的"播放全部"+"加入库"两个按钮 Row 直排，右侧"加入库"按钮文字被裁。同步要求：查看其他搜索/相关页面是否有同类问题；**做好后本地提交，不直接发版**。
2. **功能需求**：客户端接收到服务端歌单入库成功的信号时，应该自动刷新最近更新的歌单（入库完成的歌单在本地音乐库可用了，应立即出现在首页最近更新列表）。

### 一、加入库按钮窄屏溢出修复

#### 同类问题审计
- `MusicFlowMediaActions`（本地歌单/专辑/艺术家详情页在用）已经规范实现：窄屏（`constraints.maxWidth < 340` 或字号 ≥20）双按钮**垂直堆叠**，否则水平 `Row + Expanded`。
- `RemotePlaylistPage._Header` / `RemoteAlbumPage` 是同款"播放全部 + 加入库"双按钮模式但**没用**该组件，自行裸 Row 直排→窄屏溢出。已修复。
- `RemoteArtistPage` 只有单个"播放全部"按钮，单按钮不会被裁，不需改。
- `search_result_card.dart`（搜索结果列表行）的"播放 + 加入库"是 `MusicFlowIconButton`（固定尺寸），不是 `MusicFlowButton`（文字按钮），不受同类问题影响。

#### 根因
`MusicFlowButton` 内部已有 `LayoutBuilder + Flexible` 文字收缩支持（`music_flow_button.dart` 143-169 行），但**只在 outer 给 `boundedWidth` 时才生效**。当前两个按钮直接 Row 排，外层 `Expanded` 给的是 `unboundedWidth`，按钮文字不会收缩，最小宽度 `48 + icon(20) + xs(8) + 文字(40) + padding(40) ≈ 150+`，窄屏 192px 容不下 → 右侧按钮溢出。

#### 修复
复用 `MusicFlowMediaActions` 同源模式（不强行套用它，因为它绑定「播放+随机+secondaryActions」三段，硬塞"加入库"破坏语义）——两个 remote page 的 `_Header` 同套 LayoutBuilder 模式：窄屏 → Column 垂直堆叠；否则 → Row 各 Expanded 一半。视觉/行为完全对齐规范，但保留「播放全部+加入库」文字双主按钮形态（与截图视觉一致）。

### 二、入库成功自动刷新最近更新歌单

#### 实现
- `search_actions.dart` 的 `_watchImportTask` 新增 `onSuccess` 回调参数（仅在 `waitTask` 成功路径触发）。
- `importSearchPlaylist` 在提交成功后传入 `onSuccess: (_) { ref.invalidate(recentPlaylistsProvider); }`——吞掉 ref 失效异常以保护后台 Toast 流程不被破坏。
- 入库完成的歌单回到首页时已可见，无需手动刷新或等待下次轮询。

### 改动文件
- `lib/features/library/pages/remote_playlist_page.dart`（加入库按钮布局）
- `lib/features/library/pages/remote_album_page.dart`（加入库按钮布局）
- `lib/features/search/search_actions.dart`（`onSuccess` 回调 + `recentPlaylistsProvider` invalidate）
- `test/features/library/remote_pages_actions_layout_test.dart`（新增 3 例布局回归）
- `test/features/search/import_task_flow_test.dart`（新增 1 例 invalidate 回归，5 例合计）

### 验证
- library+search+discover 相关 **50 例全过**；analyze 本次改动文件无新告警。
- 测试 mock 教训：测试 `RemotePlaylistPage` / `RemoteAlbumPage` 时 stub `SubsonicApiClient` 必须连 `getRemoteStreamUrl` 一起 stub，否则 `buildRemoteSong` 抛 `MissingStubError` 让 FutureBuilder 走 error 分支显示"加载失败"，根本看不到 `_Header`——首次调试靠 DIAG dump widget tree 才暴露。

### 状态
- **已发版 v3.4.52（2026-09-01）**：push main(`1e53a89`) + tag `v3.4.52` → Build Client run `33464740371` **success**（Test Suite / UI Guard 观察型流水线同步跑）。
- Release 三产物全部合规：`MusicFlow-v3452-android.apk`(46.8MB) / `MusicFlow-v3452-windows-setup.exe`(33.0MB) / `MusicFlow-v3452-windows.zip`(39.8MB)，**uploader 均为 `github-actions[bot]`**，draft=false / prerelease=false，签名链合规。
- 待用户真实环境验证：320dp 窄屏「加入库」按钮完整显示、入库完成后首页最近更新自动出现。

## v3.4.51：MusicFlow 标题字号缩小 + 按钮区域收窄（截图反馈驱动）

### 三处反馈修复
1. **MusicFlow 标题字号太大**（用户圈起来的是目标大小）：Typography 从 `display`(26) → `headline`(19)，标题视觉更轻盈（不改全局 token，仅本调用点）。
2. **按钮区域太长**（绿色高亮区 = MusicFlowPressable Expanded 占满剩余宽度）：`Expanded` → `Flexible(fit: FlexFit.loose)`，按钮宽度按文字自然宽度收住，只包裹文字本身；文字过长仍单行省略。
3. **搜索图标偏下**：保留 `MusicFlowPressable` 默认 `minimumSize: Size.square(48)`（与搜索 IconButton 同高），Row `crossAxisAlignment.center` → 两者中心均 = 24px，视觉完美对齐——字号缩到 19 后错觉消失。

### 关键约束
- Typography token **不动**（display/headline/title 是全局规格），仅本调用点改用 `headline`。
- 触控目标不缩水：标题按钮 48×48、搜索按钮 48×48，无障碍标准保持。
- 文本过长仍单行省略（Flexible loose 给子级 `maxWidth` 上限，超出 ellipsis）。

### 验证
- discover_page_test 8 例 + discover/search/library 47 例全过；analyze 无新告警。
- 发版：tag v3.4.51 → CI 构建后台跟踪。

### Backlog（用户截图反馈 2）
- 高亮提示（点击行的绿色背景）改为带轻微阴影、不要颜色——本轮未重复提及，保留。

## v3.4.50：搜索按钮位置修正 + 入库结果反馈链路打通（截图反馈驱动）

### UI 修正（用户截图三处反馈）
1. **搜索按钮贴最右边**：标题行按钮此前 `Flexible`(loose) 导致紧跟 MusicFlow 文字而非贴右缘 → 改 `Expanded`，按钮贴行右边缘并与标题文字垂直居中。
2. **移除安卓首页整条搜索框**：compact+有标题时不再渲染 `_HomeSearchEntry`，移动端搜索入口收敛为标题行右侧按钮（与下方搜索条共用 `_openSearchPage` 同一入口）。

### 真正链路断点（查服务端源码发现，用户要求确保入库反馈链路打通）
- 后端 `GET /v1/tasks/:id` 返回 `{ success: true, task: { status, result, error, ... } }`——任务状态**嵌套在 `task` 字段下**。
- 客户端 `waitTask` 读的是**顶层** `state['status']` → 恒为 null，永远等不到 ok/error → 每次后台干等 5 分钟超时、误报「入库失败: 任务超时」。后端实际入库成功且带回 playlistId，只是客户端收不到。
- v3.4.48 只修了 UI 不卡死，完成通知链路是断的（当时测试 mock 用了错误的顶层结构，没暴露字段嵌套）。
- 修复：`waitTask` 读 `task` 嵌套（兼容顶层直出）；`startPlaylistImport` 处理 `alreadyRunning`（同歌单任务在跑时复用 taskId 继续监听，不再误报失败）。

### 验证与发版
- import_task_flow 3 例改真实嵌套结构 + 新增 alreadyRunning 复用用例；discover 断言 compact 无搜索框、点按钮开全屏 SearchPage；search/discover/library 47 例全过，analyze 无新告警。
- SPEC §5.3 补 task 嵌套契约 + alreadyRunning 复用（c1c0f86，docs-only 不打 tag）。
- 发版：tag v3.4.50 → CI 三流水线全 success，三产物（android.apk 44.6MB / windows-setup.exe 31.4MB / windows.zip 38.0MB）uploader 均为 `github-actions[bot]`，签名合规。
- 全量回归：见文末「v3.4.50 全量回归」段落。

## v3.4.49：安卓首页标题行右侧搜索按钮（aab7654）

- 需求：安卓首页 MusicFlow 标题栏同一行右侧加搜索按钮，点击打开全屏搜索页，功能/逻辑与 Windows 搜索一致。
- 实现：`_buildHomeHeader` compact 分支 Row 右侧加搜索 `MusicFlowIconButton`；抽 `_openSearchPage` 供标题按钮与下方搜索条共用入口（同一 `SearchPage` 全屏路由）。仅移动端 compact 生效，Windows 宽屏不受影响。
- 测试：新增 widget 测试（点按钮 → SearchPage 全屏压住首页）；discover+search 相关 22 例全过，analyze 无新告警。
- 发版：tag v3.4.49 → CI 三流水线全 success，三产物（android.apk 44.6MB / windows-setup.exe 31.4MB / windows.zip 38.0MB）uploader 均为 `github-actions[bot]`。
- 全量回归：+456 例，失败仅 5 个历史基线 + ssdp_discovery 偶发 flaky，零新回归；SPEC §5.4 补充多端搜索入口契约（fdf6fca）。

## v3.4.48：入库阻塞遮罩严重 bug 修复（d0b3a77）

### 根因
`importSearchPlaylist` 弹 `barrierDismissible: false` 全屏 loading 遮罩（截图中的灰阴影），且 `importPlaylist` 内部同步轮询任务（40×800ms）等待后端入库完成——大歌单（100 首）子进程入库耗时超过轮询窗口或请求挂住，UI 就永远卡在遮罩下。后端任务状态机（running/ok/error）本身正常，问题纯在前端同步等待设计。

### 新交互（触发即返回 + 后台 Toast）
- 入库 = 一次 POST 提交（秒回）→ 立即 Toast「《歌单名》入库任务已提交，完成后会通知你」→ **无任何阻塞遮罩**，用户可继续任何操作。
- 后台轮询任务（预算 5 分钟），完成 → 全局 Toast「入库完成，可在音乐库查看」；失败 → 错误 Toast。
- 完成/失败通知走 `ToastNotifier`（根导航器 Overlay），页面关闭后仍能收到。
- 歌曲/专辑入库同步补上完成后 Toast。

### 改动文件
- `lib/features/search/search_actions.dart`：重写三个入库函数，删阻塞 dialog 与页面跳转。
- `lib/data/repositories/search_repository.dart`：新增 `startPlaylistImport`（纯提交）；`waitTask` 公开化（默认预算 5 分钟）。
- `test/features/search/import_task_flow_test.dart`（新增 3 例）：提交即返回无遮罩 / 后台失败通知 / 提交被拒。
- SPEC §5.3 修订：入库交互契约（触发即返回、禁止阻塞遮罩、全局 Toast）。
- 全量回归：+455 例，失败仅 5 个历史基线（player_backdrop ×2 / app_shell ×2 / network_status_bar ×1）+ ssdp_discovery 偶发 flaky（单独重跑即过），零新回归。
- 发版：tag v3.4.48 → CI 三流水线全 success，三产物 uploader 均为 `github-actions[bot]`。

## 同类反模式全应用审计（v3.4.48 后）
- `barrierDismissible: false`：全库 0 处残留（唯一一处即本次修复的歌单入库遮罩）。
- 任务轮询 `/v1/tasks/:id`：仅 `SearchRepository.waitTask` 一处，已收敛为后台 fire-and-forget + 全局 Toast。
- 推荐歌单导入（discover 页）：单次同步幂等 POST（后端直接返回 playlistId），无轮询、无遮罩，仅卡片级 importing 标记——非卡死点。
- URL 歌单导入 / playlist-sync：客户端无入口。
- 结论：入库类操作已全部符合「触发即返回 + 后台 Toast」契约，无第二个卡死点。

## v3.4.47：搜索改版（方案 A，2a618da）

## 关键发现
拉取的最新源码里，搜索功能的主体代码（范围枚举、历史清理、浮层组件、首页搜索入口、对齐常量）**已存在于工作区但从未提交**（untracked/modified 状态）。本次把这些散落文件与新增修复一并整理提交。

## 落地内容（对照确认的 5 点）
| 确认点 | 实现 |
|---|---|
| 1. 方案A 浮层可打字 | 搜索页进入即浮出无遮罩下拉浮层，输入框保持可输入，点面板外收起 |
| 2. 范围不记忆 | 每次进入默认「所有」，页面级状态 |
| 3. 热门搜索本地兜底 | 收藏的艺术家 > 专辑 > 歌曲歌手，最多 10 个 chip，无收藏整块隐藏 |
| 4. 历史保存+自动清理 | 持久化；90 天过期、忽略大小写去重、上限 30 条；单删+清空 |
| 5. 「所有」分组堆叠 | 歌单 → 歌曲 → 专辑 → 艺术家；全网结果沿用聚合区块 |

## 实质修复（2 个真 bug）
1. **骨架屏无界高度崩溃**：`MusicFlowMediaListSkeleton` 内部是 ListView，被嵌进搜索结果外层列表时报 "Vertical viewport was given unbounded height"。改为 LayoutBuilder 自适应（有界沿用 ListView、无界用 Column），所有使用处行为不变。
2. **范围浮层全屏遮罩**：原实现 `Positioned.fill` + scrim 把热门/历史挡住且拦截点击，与确认示意图不符。改为无遮罩下拉 + TapRegion 收起。

## 测试
- 旧搜索页测试是改版前写的（断言已不存在的 UI），8 连挂 → 重写 6 例（默认态/方案A防抖/范围选择/热门历史/分组堆叠/点击行为）。
- 新增历史清理纯函数测试 4 例。
- 本地 analyze 0 问题，相关测试 17 例全过（含首页回归）。
- **全量套件回归**：+452 例，唯一失败 5 个与历史基线完全一致（player_backdrop ×2、music_flow_app_shell ×2、music_flow_network_status_bar ×1），零新回归。

## 产物
- MusicFlow-v3447-android.apk (44.6 MB)
- MusicFlow-v3447-windows-setup.exe (31.4 MB)
- MusicFlow-v3447-windows.zip (38.0 MB)

## SPEC 沉淀（e99133c）
- §4.3 修订：互斥展示废弃 → 同页分块（本地结果在前 + 分隔线 + 全网聚合）。
- 新增 §5.4 搜索交互契约：范围五档来源唯一（search_scope.dart）、方案A无遮罩下拉（**禁止改回全屏 scrim**）、范围不跨启动记忆、「所有」档 4 请求 + kSearchScopeStackOrder 堆叠、历史清理规则（90 天严格 isBefore / 去重 / 上限 30）、热门收藏兜底、10 例回归测试防线。
- docs-only 提交，未打新 tag（v3.4.47 代码已发版，纯文档无产物变化）。

## 后续
真实环境验证点：首页搜索框 → 浮层选范围/直接打字；搜索历史跨启动保留与自动清理；「所有」档分组顺序；侧栏「主页」与「随机歌曲」标题水平对齐。

## v3.4.50 全量回归（收口）
- `flutter test` 全量 **+458 例**：失败仅 5 个历史基线（player_backdrop ×2 / music_flow_app_shell ×2 / music_flow_network_status_bar ×1），与 v3.4.47/48/49 基线完全一致，**零新回归**（本轮新增的 alreadyRunning 复用用例、compact 无搜索框断言均在通过之列）。
- v3.4.50 闭环完成：UI 修正（搜索按钮贴右 + 去搜索框）→ 入库反馈链路修复（task 嵌套）→ 47 例相关回归 + 全量零新回归 → CI 三流水线 success → 产物签名合规 → SPEC §5.3 契约沉淀。
