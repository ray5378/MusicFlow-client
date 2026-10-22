# 更新日志 (Changelog)

本文件记录各版本的主要变更。版本号遵循语义化版本，仅在打 `vX.Y.Z` tag 时由 CI 构建并发布（产物：Android APK / Windows 安装包）。

## [5.9.1] - 2026-10-22

### 修复

- **流转播放页自动滚动期间被系统取消会导致误流转**：自动滚动中手势被系统取消（来电、切换应用、父级识别器抢走手势）时，Flutter 先回调 `onDragEnd`、随后才把 `PointerCancelEvent` 派发到指针路由；旧收尾按指针坐标重判落点，把「取消」当成「落在指针下方的圆」，未松手也会发生一次流转。现在用全局指针路由在派发末尾识别取消，并在微任务窗口内以 `_dragFinishing` 认领该取消，重判路径直接放弃：取消后自动滚动立即停住、不流转、不关页。

### 测试

- 流转页新增四条覆盖率用例：① 自动滚动后松手落在回收站——按实际坐标销毁且只销毁一次；② 拖拽被系统取消——停止自动滚动、不流转、不关页；③ `PlayerTransferPage.open()` 经根导航器全屏打开、点空白关闭；④ `onDraggableCanceled` 直达的防御路径清理。两个流转页测试文件 `flutter test --concurrency=1` **43/43 通过**，`dart analyze` 无新增问题，该文件行覆盖率 **564/564 = 100%**。

### CI

- 新增**阻塞**守卫 `.github/workflows/transfer-guard.yml`：`tool/check-transfer-autoscroll.mjs`（R1–R8 静态契约锁：常量口径、全局坐标接线、逐帧判定、松手重判、旧落点让位、多指隔离、系统取消、行为用例齐全）+ `flutter test --concurrency=1 --coverage` 行为锁 + `tool/check-transfer-coverage.mjs`（本文件行覆盖 ≥97% 门禁）。此前该链路只有非阻塞的观察流水线，滚不动 / 落到旧目标 / 取消后误流转三类静默回归都拦不住。

## [5.9.0] - 2026-10-22

### 新增

- **流转播放页拖拽边缘自动滚动（与 HA 卡片同一口径）**：拖拽播放器圆进入列表视口上下 44px 隐形热区时持续滚动，速度在 140–1100px/s 之间随进入深度线性变化；离开热区立即停、滚到边界自然停、`maxScrollExtent<=0` 时不激活。回收站位于滚动区之外并显式排除：拖入回收站只触发销毁高亮，不触发滚动（分界互斥）。滚动期间拖拽幽灵全程跟手，落点高亮按指针当前坐标实时重算。
- **松手落点按指针实际坐标重判**：自动滚动会把别的圆送到指针下方，而 Flutter `DragTarget` 只在指针移动时才重做命中，`onAccept` 可能仍指向滚动前的旧目标。页面在 `onDragEnd` 用指针坐标重算落点（回收站优先 → 播放器圆整行），并以 `_autoScrolled` 抑制 DragTarget 的过时回调，杜绝「拖到 A 落到 B」；常规未滚动拖拽仍走原 `onAccept` 路径，行为不变。

### 修复

- **多指同时拖两个圆**：后起的拖拽会话被忽略，且 `onDragStarted/onDragUpdate/onDragEnd/onDragCanceled` 与 `_handleDrop/_handleDestroy` 全部按源 `peerId` 校验，先松手的一路不会拿错源去流转或销毁。
- **自动滚动后新旧落点同时高亮**：`DragTarget.candidates` 停留在滚动前的旧几何上，与按实际坐标算出的 `dragHovered` 会同时点亮两个圆；新增 `autoScrolling` 开关，滚动发生后旧候选不再参与高亮。

### 测试

- `player_transfer_page_cov_test.dart`：自动滚动专项从 6 例增至 7 例，「自动滚动后松手」改为按松手点整行矩形反推唯一期望目标并断言 `transfers.single`，新增「多指并发：第二路松手不得流转、第一路仍正常落一次」；未滚动拖拽 / 单击 / 群组 / 回收站销毁等既有用例全部保留。`flutter test --concurrency=1` 该文件 **27/27 通过**，`dart analyze` 无新增问题。
- 230 主机 Xvfb 真实窗口 + xdotool 真实指针复测：底部热区滚动、离开热区即停（仅幽灵位移）、顶部热区回滚到首行、松手按指针实际所在端完成流转，均通过。

## [5.8.13] - 2026-10-20

### 契约锁定

- **「默认输出编码全局统一为 FLAC（D1）」的 seek 判定契约锁定**：服务端已把默认输出编码统一为 FLAC（源为 mp3 / m4a / aac / ogg / opus / 未知时，未带 `format` 也一律出 FLAC）。客户端核对后确认**判定逻辑无需改动** —— `shouldUseServerTimeOffsetSeek()` 首行即 `if (serverPipelinedHttp) return true;`，而本服务端（MusicFlow 自报名）一律命中该早返回，因此「未带 format 但拿到 FLAC」天然走 `timeOffset` 重拉、不做流内字节 seek、不会从头播放；下方「格式/码率比对」分支只服务**明确识别出的外部服务端**（Navidrome 等的字节直传启发式），不劣化。本次以**契约注释 + 行为断言**把这条语义钉死：`transcoded_stream_seek.dart` / `player_stream_source.dart` / `audio_quality.dart` 三处补 D1 契约注释，并在 `transcoded_stream_seek_test.dart` 与 `seek_reload_routing_test.dart` 新增两组用例 —— 「未带 format + 未限码率 + 本服务端 → 判定为需 timeOffset（与源族无关）」与「重拉地址带 timeOffset、且不带 format（服务端仍按默认 FLAC 出流）」；loaded-source 兜底路径（上下文簿记丢失）同样重拉，不退化成字节 seek。
- **服务端「显式音质档位一律走显式转码」的语义同步**：服务端去掉 `decideTranscode` 的「可复用原始直传」快路径后，显式 `format=mp3` 与显式 `maxBitRate`（高品质 320 / 标准 192 / 流量节省 128）一律走显式转码，界面档位与实际输出一致。`audio_quality.dart` 的档位说明随之更新，并在 `transcoded_stream_seek_test.dart` 文件头补作用域说明（本文件用例以 `serverPipelinedHttp: false` 走比对分支，描述的是外部服务端语义；本服务端侧该改动不影响这些用例，两侧刻意分道）。
- 说明：本次为**契约注释 + 用例补强**，**运行时行为零变化**；`player_stream_source.dart` 的强制 mp3 名单仍**按源后缀**判断（命中者显式请求 `format=mp3`，显式 format 优先于默认 FLAC），两者不冲突、不重复转码。门禁：`dart analyze` 0 error；`flutter test --concurrency=1` 四个 seek 相关文件 52 passed。

## [5.8.12] - 2026-10-16

### 重构

- **ADR-2 阶段 3b：cast 域迁移 `NotifierProvider` + `cast_peer_provider` 结构级拆分（行为零变化）**：`CastPeerController` / `DlnaDevicesNotifier` / `DlnaCastNotifier` / `PeerRemoteControlNotifier` 四个 provider 由 `StateNotifierProvider` 迁移 `NotifierProvider`；原 1525 行单文件按职责拆为三段 `part`——发现 `cast_peer_discovery.dart` / 会话 `cast_peer_session.dart` / 队列 `cast_peer_queue.dart`，采用「抽象基类 `CastPeerControllerBase extends Notifier<CastPeerState>` + 三个 `on` 基类的 mixin + 具体类装配」结构，兼容既有 88 个 `extends CastPeerController` 的测试 fake 与门禁脚本的单文件文本锚定；`dispose()` 语义改由 `build()` 内 `ref.onDispose` 仿真（`_mounted` 守卫 + 定时器/心跳清理）。
- **ADR-2 阶段 3c：`playerProvider` 主迁移 `StateNotifierProvider`→`NotifierProvider`（行为零变化）**：riverpod 2.6 下 `NotifierProvider` 的 `ref.invalidate` 会**复用同一实例只重跑 `build()`**（不同于 `StateNotifierProvider` 的整体重建），故引入逐 run 生命周期设施——`_mounted` + `ref.onDispose` 仿真、`_runGeneration` 世代令牌判活（`_isRunCurrent`）、显式断流 `_playerSubscriptions`、`_tearingDown`/`_stateMirror` 规避拆卸期读 `state` 触发重入 `build`、`PlaybackSessionPersister` 逐 run 重建并标死旧协作者；`ref.listen(starredProvider)` 迁入 `build()`。4 处 `ref.invalidate(playerProvider)` 调用点（抽屉 / 编辑音乐库 / 设置）语义对齐，并新增 `player_invalidate_semantics_test` 与 b53a 专项用例锁定「invalidate 释放旧 run 资源、新 run 干净重建、在途恢复不写新 run state」。

### 修复

- **离线缓存孤儿回收（T07）**：`OfflineCacheManager.init()` 载入索引后，以索引为准扫描各 kind 目录，清掉「有文件无索引」的数据文件与 `.part` 中间产物（孤儿成因：索引损坏清空重建、写完文件 1s 去抖落盘前被杀、删条目后文件删除失败），并按 `safeName()` 对齐键名避免误删；索引正常时零副作用。新增 b53a 离线孤儿回收 5 例（含歌词目录与非法字符键）。
- **seek 落位魔法数抽命名常量并纳入回归（T08）**：`player_seek.dart` 的 220ms 稳定观察窗、120ms 重试收尾、2000ms 漂移容忍、15s 落位宽限窗抽为 `_kSeek*` 命名常量，行为不变；新增 b53a 常量回归 6 例钉死取值与阈值内外边界。

## [5.8.11] - 2026-10-14

### 优化

- **DLNA 直投状态轮询降频**：用户主动暂停/空闲期间，直投状态轮询由 2s 抽稀至 14s，长时投屏不再每 2s 空转打满网络与设备；恢复播放立即回到密集轮询。新增轮询守卫用例锁定降频/恢复行为。
- **投屏冷启动鉴权加固**：`/peers/register` 首发前先等服务端凭证就绪（消除启动竞态导致的必然 401）；凭证下发后仍被拒（真 401）才冷却抑制重试，「凭证就绪即重试」语义保留，Boot Latency Guard 适配首发等待。

### 重构

- **ADR-2 播放内核结构化拆分（行为零变化）**：巨型 `player_provider` 按职责逐步拆分为独立协作者库——① 投屏状态判定纯策略外提 `cast_peer_policy.dart`（阶段 2a，控制器改委托）；② 会话落盘/恢复抽 `player_session_persister.dart` + `PlaybackSessionPersisterHost` 窄接口（阶段 2b-1）；③ 位置轮询/三道看门狗驱动抽 `player_position_polling.dart`（阶段 2b-2，27 成员窄接口刻意不含 Ref，阈值常量随库迁移并保测试 import 兼容）；④ 音质/淡入淡出/定时停止三 provider 由 `StateNotifierProvider` 迁移 `NotifierProvider`（阶段 3a，mounted 语义经 onDispose 仿真）。`playerProvider` 主迁移经 invalidate 重建语义审查（同实例重跑 vs 整体重建）后判定延期至阶段 3b，阻塞项已在架构报告 [l19] 记录。全量回归 0 失败，新增 b51a/b52a 专项测试。

## [5.8.10] - 2026-10-14

### 修复

- **客户端测试套件全量归零：修两处异步资源泄漏 + 两处测试抗抖动硬化**：全量 `flutter test` 遗留失败逐一定位根因并修复——① **发现页首屏就绪等待的残留定时器**（`discover_page.dart`）：`Future.timeout(15s)` 的内部定时器在 `State.dispose` 时**不可撤销**，首屏分区请求悬挂时该 15s 定时器会残留到测试结束，触发 widget test 的「Timer is still pending」判定并连带拖红 `widget_test` 等用例；改为**可取消**的 `Timer` + `Completer` + `Future.any`，`dispose` 时 cancel 定时器并放行挂起的等待（续体随后按 `mounted==false` 早退）。② **离线缓存设置 Provider 的异步续体读已销毁容器**（`offline_cache_settings_provider.dart`）：`_load` / `setSize` / `disable` 各 `await` 之后补 `if (!mounted) return;`，避免「构造期发起的加载在容器 dispose 后仍续跑 → 读 provider 抛 already-disposed」型异步泄漏。③ **b29a 位置轮询看门狗用例**（`b29a_pospoll_cov_test.dart`）：把「固定 30×500ms 预算后读一个『应该已发生』的状态」改为该文件既有约定的 `waitUntil(条件, ticks: 3500)` 轮询——连续两轮 0 秒卡死需约 2×12 tick（各 6s），满负载下固定预算不够，原写法偶发假红。④ **b50h 封面饱和窗口用例**（`b50h_cover_pressure_test.dart`）：饱和窗口按**真实**墙钟计时（观测器内部用 `DateTime.now`），而 widget 测试的 `tester.pump` 只推进**假**时钟；原用例给 `Retry-After=1` 把窗口压成 1s 真实时长，全量满负载下从注入信号到建图(8 个封面)的真实耗时 >1s 即判过期、闸门放行 → 偶发假红（隔离跑因真实耗时极小而不复现）。改为不携带 `Retry-After`（回落缺省 30s TTL），消除「真实时钟 vs 假时钟」竞态，断言恒为确定性。修复后全量 `flutter test` **0 失败**。

## [5.8.9] - 2026-10-14

### 修复

- **流转播放接收端「总是从头播放」根因修复（Windows）**：Windows 客户端作为流转/推送的接收端时，无论队列来自哪里都从 0:00 起播而非落到源端进度（Android 正常）。根因是接收链路上两处「重载/重取」丢弃了流转起点：① **0 秒卡死看门狗重载保位**——Windows(media_kit) 慢起播期间常被 0 秒卡死看门狗误判为卡死并 reload 当前曲，而原先 reload **不传 initialPosition**；带 `timeOffset` 的首载流解码 timeline 自 0 起，重载遂落回 `timeOffset=0` 从头出声。现改为把当次 tick 换算出的逻辑进度交回（**仅存在流偏移时**保位，普通曲目卡死的重载语义不变）。② **大队列接管保留广播起点**——服务端 WS 摘要（>200 首清空 `items`）下接管时重新 `GET /queue` 拿到的快照已无服务端**一次性** `startPosition`（`localPlayFrom` 广播后即删，不落库），整队起播即从 0；现改为优先用广播快照带下来的起点、拉回快照仅作兜底。另补：**偏移首载落位宽限**——给带 `timeOffset` 的首载流与 `_reloadStreamForSeek` 对称地设 15s 落位宽限，避免慢起播被误判为卡死触发无谓 reload（重载又会落回从头）。新增 2 条用例锁定「拉回快照无起点时沿用广播起点起播」，并修正原 `_adoptRemoteQueue` 用例对服务端行为的错误假设。

## [5.8.8] - 2026-10-14

### 修复

- **封面背压消费（ADR-4）逐项复核修复（C1/C2/C3/C4/C5/C6/C7/C9；C8 复核后判定不改）**：对 v5.8.5 引入的背压消费及相关批次做代码复核并逐项落地：① 信号生效时长由固定 30s 改为**按服务端 `Retry-After` 决定**（合法秒数优先、且以 30s 为上限——只能缩短不能放大，缺失/非法才回落 30s），不再无条件压制封面加载；② 饱和窗口观察定时器由「每 500ms 轮询」改为**按信号剩余时长精确到期**（原实现在 `remainingMs==0` 边界会多等一个 500ms 周期）；③ 发现页屏外预取对「首屏各分区 future」的等待**加 15s 活性能兜底**（首屏请求悬挂不再无限期拖住屏外补齐）；④ `CoverPressureObserver.install()` **保留并委派既有 `HttpOverrides.current`** 且补 `findProxyFromEnvironment`（不再把别处已装的全局覆盖无声顶掉，姿势同 dart:io `_HttpOverridesScope`）；⑤ 手机迷你播放条流转按钮补 `iconSize: 20`（与同排播放/暂停一致）；⑥ 修正 `player_provider.dart` 中「服务端首字节等待默认 6s」的过时注释（现为 8s）；⑦ 饱和标记解析改**白名单**（仅 `1`/`true` 判饱和，`false` 等一律不饱和）；⑧ b50h 组 B 增 `debugNetworkImageHttpClientProvider` 的 `addTearDown` 兜底。经复核**不改**：**C8**（`waitUntil` 轮询耗尽改硬失败会让 b29a 8 个用例由绿转红——该助手本就是刻意的最尽力等待，真定时器负载下允许放弃，耗尽并非前置条件失败的可靠信号）、C10、S8 与服务端 S2（均为设计取舍/文档项，改动收益低于回归风险），理由见架构分析报告 [l10]。

## [5.8.7] - 2026-10-13

### 修复

- **遥控失灵根治：客户端 WS 增应用层心跳 + 半开连接看门狗 + 前台/网络恢复主动重连**：服务端容器重建/网络抖动会切断 `/ws` 长连接；若断开时 TCP 未收到 FIN（半开），`onDone`/`onError` 都不触发，客户端一直以为「还连着」，而 `_connect()` 里「同线路且通道非空 → 跳过」的短路又吞掉重连——于是本端 HTTP 心跳照常（服务端可见本端在线、能看到进度），**却永远收不到遥控指令**，表现为「看得见状态、按钮按不动」。本次：① 每 25s 发 `{"type":"ping"}`（服务端回 pong，保持有来有回并充当存活证据）；② 存活看门狗——超过 3 个心跳周期（75s）没收到**任意帧**即判半开，主动作废通道并立即重连；③ 前台恢复（最小化/熄屏/托盘回来）与网络恢复（断网重连/切网）时主动重连并复位退避；④ 强制重连前先清空 `_channel`，绕开「同线路且通道非空 → 跳过」的短路。指数退避 2s→30s 封顶不变。

## [5.8.6] - 2026-10-13

### 改进

- **发现页启动加速：屏外预取推迟到首屏就绪后**：发现页各模块数据均由「分区 widget 进入视口 + cacheExtent(400) 范围被构建 → watch provider」驱动（用户编辑后的模块顺序 = 加载顺序，隐藏模块零请求），但 batch44 引入的屏外预取在首帧后即按排版序 ×100ms 错开把**全部**屏外分区的 provider future read 触发——冷启动 ~500ms 内所有模块请求全发，与首屏抢连接池与带宽，拖慢启动显示。现预取触发时机改为「首屏（已构建分区）数据全部就绪后」：`_scheduleSectionPrefetch` 首帧后只 await 已进入构建范围的分区（itemBuilder 登记的 `_builtSectionKeys`，对其 read 幂等空转、不重复请求），屏外分区不进等待集合、绝不提前触发；首屏 future 全部完成（失败也放行，不阻塞）后才按排版序错开补齐——慢网络下等待更久、首屏永远优先，冷启动带宽全部让给首屏模块。分区内横向列表本就 `cacheExtent: 0`（只构建视口内项、封面随构建懒加载），本次补齐模块级视口驱动：不显示的位置不拉数据、不加载封面。
- **b44 视口加载测试重写**：新增「窄视口冷启动 + 首屏 2s 慢加载 → 屏外分区零发起，就绪后才按排版序补齐」用例，钉死「启动带宽全让首屏」语义；原「600ms 后补齐」用例改为「首屏即就绪（缓存秒出）时错开补齐」；高视口首帧即拉、幂等不重复、随机歌曲按需三例适配。共 5 例。

## [5.8.5] - 2026-10-13

### 改进

- **封面链路消费服务端背压信号（Retry-After）**：服务端封面渲染队列满时不回 503，而是排队出图后在成功响应头附 `X-MusicFlow-Cover-Saturated` / `Retry-After`（ADR-4），此前客户端读不到响应头、只能靠失败重试兜底（报告 §5.2 / [j2] 因此缓做）。现新增 `lib/core/network/cover_pressure_observer.dart`：经 `HttpOverrides.global` 透明包装 `HttpClient`（main.dart 在 runApp 前安装——`NetworkImage` 内部共享 client 为懒初始化 static，装晚了拦不到），**只 tap 封面 URL（path 以 /getCoverArt 结尾）的响应头**，其余流量零行为改变；`Image.network` 管线不动，既有封面测试的 `debugNetworkImageHttpClientProvider` 注入缝零改动。`CoverArtImage` 据此做两件事：① 饱和窗口内暂不占用并发槽位（骨架占位，信号 TTL 30s 过期后最坏 500ms 内重建放行），不再往已饱和的服务端渲染队列堆积；② 失败重试延时取 max(指数退避 1s/2s, Retry-After)，按服务端建议等待更礼貌。新增 `test/core/network/b50h_cover_pressure_test.dart` 16 例：头解析纯逻辑（大小写/非法值/TTL）、闸门饱和与恢复（widget）、本地 HttpServer loopback 端到端（真响应头→信号，非封面流量不记录）。同时修正 `cover_art_image.dart` 头注释中「NetworkImage 每次请求都 new HttpClient()」的过时描述（当前 Flutter 为共享 client）。

## [5.8.4] - 2026-10-13

### 改进

- **起播缓冲标定：镜像服务端新上界 8000**：服务端整曲缓冲的有界等待改为分档（总大小已知 8s / 未知 6s，v4.6.8）并对慢源做投影早退（观测 >=1.2s 且 >=256KB，推算整曲超上界即提前回退直通）。客户端看门狗镜像常量 `kServerStreamBufferHeadWaitMs` 6000->8000（= 服务端可能的最长合法等待）；「平台未接管音源(idle)」判死上界 10s 不动，契约余量 1500->2000ms；5s/10s 两档起播阈值与 30s loading 档均不动（实测首字节后 13~21MB/s 瞬间填满，非起播瓶颈）。b50g 跨仓契约组补等值钉死——服务端改常量不同步改这里即测试失败。
- **`AudioLoadConfiguration` 提取单一常量源**：该配置原先在 `lib/core/services/audio_handler_service.dart`（AudioService 初始化）与 `lib/providers/player/player_provider.dart`（桌面端降级路径）各复制粘贴一份 Android/iOS LoadControl 参数，「改一边忘一边」的漂移风险实打实存在。现合并为 `lib/core/player/audio_load_config.dart` 的 `kAudioLoadConfiguration`，两处共用；新增 `test/core/player/audio_load_config_test.dart` 两道守卫：① 标定值钉死（5s/10s 起播档 + 10min/15min 驻留窗 + Darwin 10min）；② 静态防漂移——两处原复制粘贴点不得再出现内联 `AndroidLoadControl(`，必须引用单一常量源。

## [5.8.3] - 2026-10-13

### 修复

- **续播/流转首曲双载（进度条在跑却没声音）**：`playSong(initialPosition)` 原先先按 `timeOffset=0` 起播（大文件走整曲缓冲，56MB WebDAV 要 3~4s），音源就绪后才经 pendingSeek 管线**整条重拉**到 `timeOffset=at`。大文件上被放大成反复重载（真机日志实证：同一首 45 秒内整曲缓冲 3 次），起播窗口内 UI 已显示恢复进度、音频却还没就位，表现为进度条在跑但没声音、切下一首才响。现首载流直接带 `timeOffset`（整秒），不足 1 秒的余数作为播放器 `initialPosition` 一并落位，位置偏移从起播第一帧起生效；`_applyPendingSeekIfNeeded` 新增双载守卫——待落位与当前流偏移一致时清残留，绝不再重拉。全程一次加载，群组流转（transfer-from）与本地会话恢复两条路径同时受益。

### 测试

- 新增 `b45_initial_load_timeoffset_test.dart`：首载 timeOffset/余数落位/单次加载/双载守卫/不退化/seek 仍重拉，共 4 例。

## [5.8.2] - 2026-10-13

### 安全（P1）· 媒体库凭据治理

- **Subsonic 凭据不再明文落库**：媒体库的 `password` / `apiKey` 此前直接以明文存在 drift(SQLite) 业务表里（与源码注释的声明相矛盾）。现改为**只进系统钥匙串**（`flutter_secure_storage`），drift 列同步清空；升级后首次读取媒体库时对历史遗留明文做**幂等迁移**（搬进钥匙串并清列），可重复执行、不丢数据。

### 修复

- **线路回退失败计数竞态**：`fallback_interceptor` 中被多请求共享的失败计数改为串行累加，消除并发自增造成的线路误判与状态互踩。
- **健康检查 `_check` 未串行**：连续健康探测改为串行执行（此前不 await 导致并发重入、结果互相覆盖）。
- **不可播音源逐曲跳过改为可见提示**：新增 `provider_playback_skipped_many` 文案（中英双语），逐曲移除不可播内容时提示「已自动跳过 N 首无法播放的歌曲」。

### 改进

- **封面并发与服务端对齐**：端侧封面请求闸门由 6 降为 **4**，与服务端 `COVER_RENDER_CONCURRENCY`(4) 对齐，不再把服务端渲染护栏打满；`CoverArtImage` 补 `gaplessPlayback: true`，切图不再闪空。
- **位置轮询在窗口不可见时降频**：应用窗口不可见时降低播放位置采样频率，省电省 CPU（恢复可见即回到正常频率）。
- **播放链路纯策略外提（ADR-2 阶段 1）**：看门狗与队列恢复的**判定**逐字搬为顶层纯函数（新增 `player_watchdog_policy.dart` / `player_queue_policy.dart`），宿主只负责读写字段；**行为等价**，使零成本确定性单测成为可能。
- **跨仓阈值契约显式化**：把「服务端整曲缓冲首字节等待 6s **严格小于** 客户端 idle 档判死 10s」写成命名常量 + 注释 + 双侧守卫用例，防止今后单侧调参导致「服务端仍在合法缓冲、客户端已抢先判死」。配套服务端 v4.6.6。

### 清理

- 删除死代码 `lib/core/services/storage_permission_service.dart`（全仓 0 引用）。
- 移除未使用依赖 `cached_network_image`（`flutter pub get` 连带移除 3 个传递包）；`permission_handler` 保留（仍被通知权限服务使用）。

### 测试

- 新增 6 个测试文件：`b50a`(凭据治理) / `b50b`(健康检查串行) / `b50c`(回退竞态) / `b50e`(轮询可见性降频) / `b50f`(不可播跳过提示) / `b50g`(看门狗·队列策略 + 跨仓契约)。
## [5.8.1] - 2026-10-12

### Windows 播放卡死修复（流加载三档看门狗）

- **问题**：Windows 端 libmpv 以 `network-timeout=0`（无限等网络）运行，反代/上游异常时底层 `setUrl` 永不回调，播放器永久停在 0:00（Android 端 ExoPlayer 自带重试所以正常）。
- **修复**：新增三档看门狗 —— 平台从未接管（idle）10s；平台已接管但位置 30s 未越过 1.5s（loading 零前进）30s；兜底 30min。超界清在途标记并走既有升级链（reload → 判死歌 → 跳下一首）。判别不依赖 `duration == 0`（libmpv 一打开就有总时长），并保证合法慢起播（实测 5~18s）不被误杀。

## [5.8.0] - 2026-10-11

### 歌曲信息显示保存路径/来源

- **歌曲信息弹窗**：歌曲右键（桌面）/ 长按（移动）菜单新增「歌曲信息」，展示标题/歌手/专辑/时长/码率·格式/年份/专辑艺人/作曲/风格/音轨，并新增一行真实来源——本地/WebDAV 歌曲显示实际保存路径（WebDAV 剥去内部源前缀），平台歌曲显示「平台名（插件名）」（如「网易云（go-music-dl）」）。
- **桌面端歌曲右键菜单**：歌曲列表支持鼠标右键打开操作菜单（此前仅长按/更多按钮），与移动端共用同一面板。
## [5.7.0] - 2026-10-08

### Android 断网自愈对齐桌面

- **Android 播放流超时适配**:内置播放器(ExoPlayer)网络超时由默认连接/读取各 8 秒放宽为连接 30 秒 / 读取 31 分钟,与服务端 30 分钟取流重试窗对齐——音乐源断网期间 Android 端不再提前掐断挂起请求,源恢复后同一请求无缝出流,断网自愈体验与桌面端一致。
## [5.6.0] - 2026-10-08

### 播放抗断网 + 首页加载优化

- **播放抗网络波动**:配合服务端整曲内存缓冲与自动重试窗,网络源歌曲播放中源短暂断开不再中断;起播失败自动等待重试,源恢复即自动续播(播放卡死/僵尸流问题根治)。
- **首页视口优先加载**:按首页排版顺序安排加载优先级——首屏内容首帧即拉,屏外分区错开补齐,打开首页更快看到重点内容。
- **封面只走内存缓存**:图片缓存固定 128MB 内存配额,不再写磁盘,更省存储。
- **大曲库加载提速**:全部歌曲页分页上限提升至 2000,十几万首曲库的请求次数从 661 降到 66。
## [5.5.0] - 2026-10-07

### 性能与体验优化:发现页秒开

- **发现页推荐数据本地缓存**:首页推荐卡/插件推荐/本地推荐三个区块冷启动直接显示上次内容,后台静默刷新,网络失败自动回落缓存——打开发现页不再白屏等网络。
- **离开发现页再回来不再重新加载**:各分区数据保留,仅切换音乐库时自动刷新。
- **最近歌单轻量化**:改为服务端分页拉取最近 50 个,传输量从全量(约 317KB)降至约 20KB,排序由服务端完成。
- **数据层**:新增推荐缓存表,自动迁移(v5→v6),既有数据无损升级。
## [5.4.0] - 2026-10-07

### 修复

**播放与投屏**

- 投屏命令下发失败不再「点了没反应也不报错」：播放/暂停、上下曲、音量/静音、播放模式、队列编辑（加歌/跳转/拖动/移除/清空）失败时明确记录告警并跳过乐观回写，界面以后端权威状态为准
- 投屏进度显示移除「合成进度」兜底链：进度不再出现合成推进带来的跳变，一律以设备回报与本地对齐为准（卡死/停滞/近末尾三道看门狗保留）
- 投屏 seek 的 SOAP 兜底分支移除（「有设备必有队列信息」不变量全路径成立，无现实触发场景）

**界面与交互**

- 侧边抽屉的焦点恢复回调真正接线：抽屉关闭/登出后焦点正确还给主界面（原回调只声明从未触发）
- 删除歌单确认弹窗：点遮罩、返回键等外部关闭一律视为「取消」，语义从二态改为三态更明确

**数据与服务**

- 服务端返回异常数据（响应不是 JSON 对象）时按数据错误优雅降级：状态检查、音乐夹列表、OpenSubsonic 扩展、投屏流地址等正常走失败/回退分支，不再把脏数据当程序错误上抛；真实的程序级错误（如字段类型不符）仍会显式暴露，便于定位
- 临时客户端 ID 读取失败时静默降级（best-effort 遥测头，不影响任何请求）

**内部改进（无行为变化）**

- DLNA 设备/投屏状态 copyWith 支持显式清空可空字段（省略=保持、显式 null=清空）
- 移除转码播放死守卫、恒假分支、二次兜底死代码等多处死代码（合计约 -180 行）
- 队列拖拽落位语义订正：现状符合 Flutter ReorderableListView 标准间隙下标写法，撤回此前 off-by-one 误诊

## [5.3.0] - 2026-10-07

### 修复

**收藏与账号**

- 服务端显式下发 `"starred": false` 时，艺人/专辑不再被误显示为「已收藏」（P0）
- Linux 桌面端「记住密码」生效（凭据存储平台白名单补 Linux，不再每次启动都要重登）

**播放与投屏**

- 离线且队列内全部无缓存时不再无限重试：连续失败 2 次后停止自动跳并落暂停态
- DLNA 投屏 seek 失败不再「设备静音卡死」：自动重投一次并外显失败状态
- DLNA 设备播放中途异常停止时能自动跳下一首（原兜底因状态写回顺序永不触发）
- 连点暂停/恢复不再向设备重复下发命令（本地状态乐观回写）
- 投屏 seek 失败与设备拒绝可区分：失败时不再乐观对齐进度条

**界面与交互**

- 聚合搜索错误态不再展示内部异常原文，改本地化文案（原文进日志）；「重试」真正生效
- 侧边抽屉资料库拉取失败后的「重试」按钮生效（原为死按钮）
- 远端专辑/歌单加载失败后的「重试」按钮生效
- 歌单详情排序拉取失败时重试入口不再被「歌单为空」空态遮蔽
- 睡眠定时器：手输分钟即时生效（原须再点其它控件）；窄视口下按钮行溢出修复
- 封面 Provider 设置页对脏数据 apiKey 不再整页崩溃
- 设置页：打开链接失败给出提示；更新检查/切换资料库失败提示改为稳定文案
- 歌单/专辑/艺人列表本地播放失败不再产生无反馈的未捕获异常

**解析与健壮性**

- LRC 歌词：无时间戳文本行排到结果末尾（原被顶到最前）；支持一位毫秒时间标签（如 `[00:01.5]`）
- 远端控制载荷畸形字段不再导致整条消息处理中断（13 处裸强转改判型）
- 网易云歌词源返回结构异常时安全降级并记日志，不再静默吞掉
- 服务器配置解析缺字段回落空串而非崩溃；推送 WebSocket 连接失败正确兜底；离线缓存提升失败不再外抛

## [5.2.1] - 2026-10-07

### 质量

- 测试规模扩充至 3828 例全绿，代码覆盖率提升至 98.94%（batch37-39 三轮补测）；
- 剩余未覆盖行经逐行核实均为死代码 / 平台盲区，测试工程收口；
- 全量缺陷台账整理完毕，下一版本转入真实缺陷修复。

## [5.2.0] - 2026-10-06

### 新增

**设置页补「添加新音乐库」入口**

- 设置 › 音乐库分区新增「添加新音乐库」入口，复用既有添加流程（/login?add=true）；
  此前仅侧边抽屉可进入，设置页缺少该入口

**新增设置项「默认控制当前客户端」**

- 设置 › 新增开关「默认控制当前客户端」（默认关闭）：开启后启动即默认控制本机
  客户端；关闭则保持既有行为，启动后自动选中正在播放中的播放器

- 开关状态本地持久化，启动自动选中在读取开关后决定是否提前短路

**Windows 窗口细黑边**

- Windows 客户端窗口四周描 1px 纯黑轮廓，使无系统标题栏的窗口边界更清晰

### 修复

- Windows 细黑边改前景绘制（原边框画在不透明内容层之下，实际不可见）

- 「默认控制当前客户端」偏好读取加异常兜底：读取失败按默认值处理，不再向上抛错

- 启动自动选中加组件存活校验：控制器已释放时不再访问其状态，消除异步竞态
## [5.1.8] - 2026-10-02

### 修复

**启动自动播放竞态(v5.1.7 回归)**

- 现象:关闭「打开时自动播放」,启动后本机仍可能强制出声,且播放/暂停按钮
  无法控制 —— v5.1.7 启动自动选中首次能在会话恢复中途切走控制目标,
  队列镜像停写后服务端留陈旧队列,回环广播被本端误采纳而 playQueue 起播;
  UI 处于遥控模式,transport 按钮控制的是远端,本机声音失控

- 队列广播仲裁:本端遥控远端期间,只采纳带「起播起点」的主动推送,其余
  (自回声/陈旧回声)一律忽略(peer_remote_control_provider)

- 队列镜像兜底守卫:_syncLocalQueue 在遥控期间一律不写(防抖定时器可能
  在 switchTo 落地后才触发)

- 启动自动选中等待会话恢复落定(最多 10s)再切控制目标,切前复验目标仍在播

**检测更新三项**

- 手动检查失败不再谎报「已是最新」:UpdateChecker.check 失败改为向上抛,

  设置页如实报错;启动检查仍有静默兜底,行为不变

- GitHub API 匿名限流(60 次/时/IP)兜底:失败时改抓 releases.atom(不受
  API 限流)解析最新版本

- 启动检查防重复守卫失效修复:改一次性 _ran 标志,主题/语言等依赖变化
  不再重复发起检查
## [5.1.7] - 2026-10-02

### 变更
- 启动自动选中优先级修正:本机有播放队列但不在播放中时,排在正在播放中的
  群组、独立播放器之后 —— 只自动切到真正 PLAYING 的端(以各端实时 /status
  的 state 判定,PeerInfo.queueActive 暂停时也为 true 区分不了在播);无在播
  端则保持本机
## [5.1.6] - 2026-10-02

### 变更（真机反馈 5 项）
- 音量面板去掉右上角关闭叉号：音量键本身是 toggle，再按即收起
- 播放端列表自动刷新：控制器每 10s 递增 peersRev 触发 targets 链重新拉取，
  播放端上线/下线无需重进页面即自动反映到播放控制块与切换器
- 移动端播放队列弹窗打开即最高高度（0.72 → 0.95），深浅主题一致，
  不再需要手动上滑展开
- 随机 / 单曲循环模式图标由 fill 换 line（shuffle_line / repeat_one_line），
  与列表循环 / 顺序播放图标风格统一（块 / mini / 全屏页同步生效）
- 启动并连接成功后自动选中正在播放中的播放器：多台同播按 本机 > 群组 >
  独立播放器 类别序（复用 peer_display_order 唯一实现）；仅在启动后首次
  拉到播放端列表时评估一次，不干预会话中途的手动选择
## [5.1.5] - 2026-10-02

### 变更
- 流转播放按钮图标换为无限 ∞（AppIcons.transferInfinity = Remix.infinity_line），
  覆盖首页播放控制块 / MINI 播放器（横排+竖排）/ 全屏播放页 / Windows 桌面歌词浮窗；
  桌面歌词原生层新增 kRemixInfinity 字形轮廓（gen_lyric_glyphs.py 重新提取），
  base_station 图标保留给设备弹窗的 DLNA 设备行
## [5.1.4] - 2026-10-02

### 修复
- 首页播放控制块红心实时回填：Song 重写了 ==(只比 id)，收藏态变化产生的
  新实例被 select(currentSong) 判「相等」导致块不重建；收藏态改 select 原始
  bool，点击即刻变红/取消即刻变空心
- 流转播放页改走根导航器：从首页块打开时统一盖住整个外壳（含 mini 播放器），
  与从 mini 打开的行为一致

### 新增
- 首页播放控制块控制条首列恢复播放队列按钮：与全屏播放页同口径打开队列窗口
  （移动端底部弹窗 / 桌面右侧非模态面板）


## [5.1.3] - 2026-10-02

### 修复
- 投屏态红心修复真正生效：v5.1.2 的收藏态校正因 starredProvider 为 autoDispose、
  ref.read 取值读完即被回收而永远落空。改为 playerProvider 持久监听并缓存，
  投屏镜像的初始红心显示与点击方向判定恢复正常


## [5.1.2] - 2026-10-02

### 首页「播放控制」块真机验收第二轮（8 项）

### 修复
- 去掉模块外框与圆角底色盒，内容与首页其他分区左对齐
- 移除播放队列按钮（队列面板入口随之移除，全屏页/桌面右栏不受影响）
- 点击封面打开全屏播放页（与 mini 播放器同款路由）
- 投屏态红心按权威收藏列表校正：初始显示与服务端真实状态一致，点击方向不再判反
- 音量面板只覆盖底部控制区，不再遮盖歌词与封面
- 去掉进度条显示，块高收缩 280/360 → 252/330

### 新增
- 切换器行首新增「流转播放」入口（与 mini 播放器同款，打开完整切换器面板）
- mini 播放器可在「编辑首页模块」中开关显示（默认显示，固定顶部，不可拖动）


## [5.1.1] - 2026-10-02

### 修复：首页「播放控制」块真机验收 9 项反馈

- **封面不再被拉伸裁切**：Now 区由拉伸对齐改居中对齐，封面恢复正方形
  （安卓 92dp / Windows 160dp），修「封面显示不全」。
- **「本机」chip 恒定显示**：不再依赖服务端列表返回 self 条目 —— self 条目
  离线也保留，缺失时前端合成兜底，Windows 端恢复控制本机的能力。
- **切换目标接真实播放状态**：切走时清掉上一目标的残留镜像；目标空闲
  （无活跃队列）时块内显示「未在播放」而不是残留假状态。
- **红心点赞实时生效**：投屏镜像重建当前曲时继承红心状态，不再被 2s
  轮询打回空心（跨端同步仍走 WS 推送）。
- **选中态与全屏播放页统一**：随机/单曲循环/收藏等选中只走 accent 前景色，
  去掉与旁边按钮不一致的底色块。
- **音量面板实底化**：由一行悬浮滑条改为覆盖整块的面板（大百分比 + 静音键 +
  滑条，关闭键右上角）。
- **曲名 - 歌手同行**：对齐迷你播放器观感，排版走全局 typography 令牌
  （title 15 / metadata 11），不再手写比例字号。
- **连接就绪自动刷新**：服务端地址/凭证就绪信号驱动 peers 重查，不再
  卡死在「暂无可控制设备」空态。
- **窄屏溢出兜底**：控制条 7 键在 <336dp 宽度下可横向滚动，不再溢出。

## [5.1.0] - 2026-10-02

### 功能：首页新增「播放控制」整体块（HA 卡片式遥控）

- **是什么**：首页新增一个可配置的「播放控制」分区 —— 把 HA 媒体卡片的操作形态
  做成一个**整体的块**，参与首页现有的分区排序体系（默认置顶且可见，用户可在
  编辑页里开关显隐、上下拖动；老用户的历史排序自动追加该分区并提升到首位）。
- **布局**：固定高度（Android/手机同宽 280dp；宽 ≥840 的窗口如 Windows 展开 360dp），
  内部自上而下三行 —— ① 设备切换器（横滚 chip，含「本机」）② Now 区（封面 + 曲名 +
  紧凑歌词视口，当前行固定第二槽自动跟随）③ 七键控制条（上一首/播放暂停/下一首/
  播放模式/队列/音量/收藏）+ 进度条。
- **链路全复用**：操控与显示全部走客户端现有链路（effective 播放门面 / cast_peer
  切换 / 现有歌词与队列组件），不引入第二套播放逻辑 —— 队列面板直接复用
  `PlayQueueSheet`（三态路由保持一致），音量走 `ThrottledVolumeSender` 拖动节流。
- **覆盖面板**：队列与音量两种面板覆盖整块展示，单一枚举互斥（开一个关另一个），
  点面板外任意处关闭；面板与告警条都叠在固定槽位上，**出现/消失不改变块高**。
- **告警条**：设备离线 / 不可达时在进度条槽位显示告警条（占槽不位移），点击可重试。
- **静音分路径**：投屏设备走真静音（`setMuted`）；本机播放降级为「置 0 + 记住原值」。
- **无障碍**：七键 / 滑条 / 进度条全部补齐 semanticLabel。
- 交互反馈统一走 `MusicFlowPressable` 按压缩放反馈（交互反馈合规守卫通过）。
- 顺带：启动编排守卫 Fix-1 的行为锁升级为运行时锁（`@visibleForTesting` 转发入口，不改行为）。

## [5.0.38] - 2026-10-02

### 性能：启动「打开到能用」去掉 6.9 秒串行空转（三处等待全部改事件驱动）

- **现象**：用户口径「每次启动客户端到实际可用要几秒」。网络侧实测并不慢 ——
  公网 HTTPS 首次建连 186ms、连接复用后每请求仅 ~3ms；内网 HTTP 首连 2ms。
  也就是说耗时**不在服务器，在客户端自己的启动编排**。
- **根因**：启动链上有三段「先睡一觉再问一次」的串行空转，最坏叠加 ≈6.9s：
  1. `fetchLocalQueueForRestore` 以 100ms 为步长轮询等本地 peerId 就绪，**上限 4 秒**；
  2. `_registerSelf` 在凭证尚未注入时必然 401，随后**固定盲等 900ms** 再重试一次；
  3. `ensureActiveAddressProvider` 空转等活跃地址**上限 2 秒**，且**每个首屏请求都要先过它**。
- **修法**（三处统一改为「事情办完立刻喊醒」，而不是定时去问）：
  1. `cast_peer_provider.dart` 新增 `_localPeerIdReady` Completer：`_registerSelf` 拿到 peerId 落地时
     即刻 complete，恢复流程挂在上面等（已注册则零等待同步返回），超时预算 1.5s 后放弃恢复、
     回退本地会话，不再死等。Completer 按需创建 + 已完成即重建，兼容 hot restart / 重注册周期。
  2. `api_provider.dart` 新增 `apiCredentialsReadyProvider`：活跃库已就绪返回已完成的 Future（零等待），
     未就绪返回挂起 Future、活跃库一发射即经 `onDispose` 放行旧等待方。`_registerSelf` 的 900ms
     盲等删除，改为凭证就绪**立即**重试（重试时重新取已注入凭证的 client），保留 2s 预算与单次重试上限。
  3. `address_pool.dart` 新增 `_activeAddressReady` 信号与 `waitForActiveAddress([timeout=300ms])`：
     `setAddresses` 恢复 / 探测选中任一路径激活地址即刻唤醒等待方。正常路径（活跃地址已恢复）**零等待**，
     异常路径最坏 300ms 后回退 best-effort 地址，由 FallbackInterceptor 兜底。
- **收益**：正常路径合计 **≈6.9s → ≈0ms**；异常路径有硬上限（1.5 + 2 + 0.3s），不会再无限等。
  注意这与「连接复用」是两件事：复用解决的是**每请求 190ms**，本次解决的是**启动期空转秒数**。

### 测试：覆盖率 batch17 / batch18（新增 63 例，全量 1289 例全绿）

- **batch17** `test/providers/player/player_provider_cov_test.dart`（新，35 例）：覆盖播放器**公开状态迁移**
  那一半 —— 投屏队列同步 / 四态播放模式与落盘 / 队列增删 / 外部收藏推送 / 收藏切换 / 元数据刷新。
  `player_provider.dart` 单文件 17.46% → **29.49%**。
- **batch18** `test/features/library/pages/edit_library_page_coverage_test.dart`（修通 28 例）：
  库编辑页 —— 加载态 / 目标库缺失占位 / 表单回填 / 地址增删改 / 三种地址状态文案 /
  地址重排语义 / 删除库后的退栈与活跃库切换。单文件 **9.27% → 96.34%**。
- 总覆盖率 **60.38% → 60.96%**（`lib/providers` 45.95% → 48.65%）；全量回归 **1289 例 All tests passed**。

### 文档：启动延迟实测数据与优化优先级固化

- `docs/startup-connect-latency.md` 新增 keep-alive 复用实测章节：内网首连 2ms / 复用 ~1ms，
  公网首连 186ms / 复用 **~3ms（60 倍）**；并给出优化优先级（连接复用 > 串行步并行化 >
  缓存兜底 > DNS 抖动用多地址竞速）。DNS 偶发抖动实测最高 5.18s，属运营商侧，不在客户端修复范围。

## [5.0.37] - 2026-09-26

### 对齐发布：本轮无客户端代码变更

- 本轮修复集中在服务端与 HA 卡片：**逐字(卡拉OK)歌词被逐时间戳重复展开**、**DLNA 设备在线判定抖动（正在播放却被判离线）**（两者均为服务端修复，客户端无需改动），以及 **HA 卡片进度不走 / 被托管成员未收敛到控组**（卡片修复）。
- 本版仅同步版本号，让客户端 CI（测试套件 / 各链路守卫 / Android 构建链）完整跑一遍，保持四仓版本号 lockstep 可追溯。产物与上一版**逐字节同源**。


## [5.0.36] - 2026-09-26

### 功能：流转播放带上当前进度（秒级对齐）

- **现象**：队列与当前曲可以流转到别的播放端，但目标端**从这首的 0 秒**开始出声。用户口径：「流转播放后出声的状态要是秒级对齐流转前的状态」。
- **根因**：三条流转路径都只搬「队列 + 当前曲游标」，**没有一处带位置** —— 服务端起播接口与队列快照里也都没有「起始位置」这个字段（服务端 v4.0.30 同步补齐）。
- **修法**（三条路径各自补齐，任何一条漏带，用户听到的就是「从头播」）：
  1. **本机 → 远端**：投屏前先取本机此刻的精确进度 —— 必须在 `switchTo` **之前**取，因为它会把本机暂停（接续搬移语义「搬完原边停止」），之后读到的进度就冻住了。该值随 `/v1/play`（主通道）或 `/queue/play`（兜底整队）的 body `position` 交给服务端。乐观进度条也落在该位置，不再从 0 爬起再被轮询拉回（观感是「跳了一下」）。
  2. **远端 → 本机**：先在**停设备之前**读源端 `/status` 的实时进度（停完读数就归零/掉线），再经 `playSong(initialPosition:)` **既有**的 pendingSeek 管线落位 —— 音源就绪即 seek，不必等加载完成再补一次。读不到就退化为从头接续（与改动前一致），不会更差。
  3. **远端 → 远端**：服务端自读源端进度并自行 seek，客户端**一个字节都不上传**（沿用既有零上传设计）。
- **跟随广播**：`peer_queue_changed` 快照新增的一次性 `startPosition` 会被本端跟随起播消费，三种分支都覆盖 —— 整队接管、摘要态拉全队接管、以及「同队同曲只是进度不同」（这一支原本会因游标未变而直接返回，必须单独 seek 落位）。另外，**带 `startPosition` 的快照不再被当作自回声跳过**：歌曲序列/游标/模式全一致时也会被判为有差异，否则流转过来的进度会被直接丢掉。
- **测试**：新增 `test/providers/cast_transfer_position_test.dart`（6 条契约：主通道 / 兜底整队 / 0 秒不下发 / 远端读数落位 / 读不到退化 / 0 秒读数），并做过变异验证（摘掉起点传递后 4 条转红）。

## [5.0.34] - 2026-09-25

### 功能：歌单「起播即补齐」(服务端自动匹配 + 本机队尾追加)

- **现象**：歌单里「曲库中未找到」的条目在客户端起播时被直接跳过，那首歌就永远播不到；客户端也没有对应入口 —— 此前只有 Web 前端手动点「批量匹配」才会重新尝试。
- **根因**：客户端的**本机播放不走**服务端的 `/v1/play`(它自己拉全量曲目、自己 `playQueue`)，服务端挂在 `/v1/play` 上的自动匹配对它完全无效；而`/v1/online/:providerId/match-playlist` 又要求调用方指定 providerId —— 本地歌单压根没有这个字段，无从下手。
- **修法**：
  1. 服务端 v4.0.26 新增 `POST /v1/playlist/:id/auto-match`：能力驱动挑选在线源(调用方无需 providerId)、只登记任务即返回、与 `/v1/play` 共用同一把每歌单锁和 24h 节流;
  2. 客户端起播成功后 **fire-and-forget** 触发它(24h 节流,窗口内不会被反复触发);
  3. 命中后把新入库的曲目**追加到本机队尾** —— 只增长队尾、不动 `currentIndex`,当前正在听的这一首与它之前的顺序完全不受影响,已经听到的部分不会因为补齐而错位;
  4. 补齐结果只发一条 Toast(与 Web 前端一致:**慢路径不起任何对话框**,不挡着正在听的人)。
- 投屏(选中远端 peer)不需要客户端做任何事:那条路径服务端 `/v1/play` 已经自行动过一次；补齐由服务端直接写设备队列。

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
