import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/library/metadata_cache_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/features/player/widgets/song_options_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/features/discover/widgets/discover_media_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/hoverable_horizontal_scroll.dart';


/// 随机歌曲模块:标题旁刷新按钮 + 右侧播放按钮;每轮 20 首,
/// 一轮内不重复,播完自动换下一轮。
class RandomSongsSection extends ConsumerStatefulWidget {
  const RandomSongsSection({super.key});

  @override
  ConsumerState<RandomSongsSection> createState() => _RandomSongsSectionState();
}

// 随机歌曲区块有本地状态(轮次 token/滚动控制器/自动重试等),在
// SliverList.builder 的惰性布局里需要保持存活,避免滑出视口后状态丢失。
class _RandomSongsSectionState extends ConsumerState<RandomSongsSection>
    with AutomaticKeepAliveClientMixin {
  /// 首页随机歌曲本地缓存的有效期(TTL):超过该时长即便本地有缓存,
  /// 也会后台拉取一次最新结果,避免「换了一批 / 歌单更新后首页仍显示旧歌」。
  /// 30 分钟内视为新鲜,直接使用本地缓存秒开。
  static const Duration _randomCacheTtl = Duration(minutes: 30);

  bool _autoContinue = false;
  int _roundToken = 0;
  StreamSubscription<int>? _randomSongsSubscription;

  /// 自动重试定时器与计数:首载失败(无缓存)时自动补拉,有界重试,
  /// 成功加载或区块真正无数据时停止,避免瞬时网络问题把区块永久隐藏。
  Timer? _autoRetryTimer;
  int _autoRetryCount = 0;
  static const int _maxAutoRetry = 3;
  static const Duration _autoRetryDelay = Duration(seconds: 3);

  /// 最近一次可展示的歌曲(本地缓存或远程结果)。打开首页时先用它秒出内容,
  /// 同时后台拉取远程最新结果,避免每次都阻塞在远程请求与后端惰性刷新上。
  List<Song>? _lastKnownSongs;

  @override
  bool get wantKeepAlive => true;

  /// 本轮随机歌曲的 id 集合:用于判断当前播放队列是否仍是随机轮次,
  /// 避免歌单更新推送把随机歌曲误追加到用户手动切换的其他歌单。
  Set<String> _roundSongIds = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadCachedSongs());
    // 监听随机歌曲歌单「变更推送」:主项目插件维护刷新歌单后主动发信号,
    // 客户端收到后按需重拉,**不再轮询**,避免打开页面等待后端惰性重建。
    _randomSongsSubscription = randomSongsChangedStream().listen((_) {
      if (!mounted) return;
      Logger.infoWithTag('DISCOVER', 'random songs changed, refreshing');
      // 歌单更新:正在播放随机轮次时**追加**到队列末尾(不替换、不中断),
      // 否则仅刷新展示。
      unawaited(_handleRandomSongsChanged());
    });
    // 活跃库就绪后若还没有内容(无缓存 + 首次冷启动),补一次缓存读取/后台拉取。
    // 说明:initState 里不能用 ref.listen(riverpod 2.6.1 只允许在 build 内调用,
    // 且随机歌曲区块本身由 SliverList 惰性构建,debugDoingBuild 为 false)。
    // 改用 ref.listenManual(专为 initState 设计),widget 卸载时自动释放订阅。
    ref.listenManual<MusicLibrary?>(
      activeLibraryProvider,
      (prev, next) {
        if (next == null) return;
        if (prev != null && prev.id == next.id) return;
        if (_lastKnownSongs != null) return;
        unawaited(_loadCachedSongs());
      },
    );
    // 监听投屏队列自然播完:DLNA 设备整轮播放完毕后自动加载下一轮随机歌曲续播。
    ref.listenManual<CastPeerState>(
      castPeerControllerProvider,
      (prev, next) {
        if (!_autoContinue) return;
        if (next.endOfQueueCount > (prev?.endOfQueueCount ?? -1)) {
          Logger.infoWithTag(
            'DISCOVER',
            'cast queue ended, loading next round',
          );
          unawaited(_loadNextRound());
        }
      },
    );
    // 自愈兜底:随机歌曲首载若因「地址探测/线路的瞬时失败」被置为 failed 且本机又
    // 无缓存时,区块会整块隐藏。这里监听 failed 信号自动补拉一次(有界重试),
    // 避免整块永久隐藏,造成「Windows 一直提示网络异常 / 随机歌曲不显示」的表象。
    ref.listenManual<bool>(randomSongsLoadFailedProvider, (prev, next) {
      if (!mounted) return;
      if (!next) return;
      _scheduleAutoRetry();
    });
  }

  /// 先读本地缓存的随机歌曲,让区块立即有内容可展示,不等远程。
  /// 冷启动时活跃库可能尚未从 drift 就绪(libraryId 为 null),
  /// 回退到最近使用的库 ID 读取缓存,避免首屏一直空等网络/探测。
  /// 若本地也没有缓存,后台拉取一次填充(仅首次,不阻塞展示)。
  Future<void> _loadCachedSongs() async {
    try {
      final cache = ref.read(metadataCacheRepositoryProvider);
      var libraryId = ref.read(activeLibraryProvider)?.id;
      if (libraryId == null || libraryId.isEmpty) {
        libraryId = await cache.getLastLibraryId();
      }
      if (libraryId == null || libraryId.isEmpty) return;
      // 带写入时间的缓存:即使命中,也据此判断是否已超过 TTL,需要后台刷新。
      final cachedMeta = await cache.getRandomSongsWithMeta(libraryId);
      if (!mounted) return;
      if (cachedMeta != null && cachedMeta.songs.isNotEmpty) {
        // 远程数据已就绪时不再用旧缓存覆盖,避免「新内容 → 旧缓存」的闪回。
        if (_lastKnownSongs == null) {
          _resetAutoRetry();
          setState(() => _lastKnownSongs = cachedMeta.songs);
        }
        // 库指纹失效 + TTL:缓存按库 id 分区,库切换天然用各自缓存;
        // 超过有效期即便有缓存也后台拉最新,保证首页不会一直显示过期旧歌。
        final age = DateTime.now().difference(cachedMeta.cachedAt);
        if (age > _randomCacheTtl) {
          Logger.infoWithTag(
            'DISCOVER',
            'random songs cache stale (age=${age.inMinutes}m), '
            'refreshing in background',
          );
          unawaited(_fetchLatestForDisplay());
        }
        return;
      }
      // 无缓存:首次打开后台拉取一次,供首屏使用。
      unawaited(_fetchLatestForDisplay());
    } catch (e) {
      Logger.warnWithTag('DISCOVER', 'random songs cache read failed', e);
      // 缓存读取异常也不阻断首屏:回退到网络拉取一次。
      // 这是「Windows 冷启动拉不到随机歌曲」的关键兜底——此前缓存坏数据
      // 抛异常后被直接吞掉,后续从未触发 _fetchLatestForDisplay。
      if (mounted) unawaited(_fetchLatestForDisplay());
    }
  }

  /// 后台拉取最新随机歌曲并更新展示(不阻塞 UI,失败静默)。
  Future<void> _fetchLatestForDisplay() async {
    try {
      final songs = await ref.refresh(randomSongsProvider.future);
      if (!mounted) return;
      if (songs.isNotEmpty) {
        _resetAutoRetry();
        setState(() => _lastKnownSongs = songs);
      }
    } catch (e) {
      Logger.warnWithTag('DISCOVER', 'fetch latest random songs failed', e);
    }
  }

  /// 自动补拉调度:仅当「区块尚无内容」且未超上限时,延迟一段时间后重拉。
  /// 成功拿到内容后由 [_resetAutoRetry] 重置计数;无内容时最多重试
  /// [_maxAutoRetry] 次,避免在真正离线(无服务器)时无限空转。
  void _scheduleAutoRetry() {
    if (_autoRetryTimer != null) return;
    if (_lastKnownSongs != null) return;
    if (_autoRetryCount >= _maxAutoRetry) return;
    _autoRetryTimer = Timer(_autoRetryDelay, () {
      _autoRetryTimer = null;
      if (!mounted) return;
      if (_lastKnownSongs != null) return;
      _autoRetryCount++;
      Logger.infoWithTag(
        'DISCOVER',
        'auto-retry random songs (#$_autoRetryCount/$_maxAutoRetry)',
      );
      unawaited(_loadCachedSongs());
    });
  }

  /// 成功拿到可展示内容后重置自动重试计数,让后续瞬时失败仍有机会自愈。
  void _resetAutoRetry() {
    _autoRetryCount = 0;
  }

  Future<void> _playRound() async {
    final token = ++_roundToken;
    // 直接播放主页当前已展示的随机歌曲,不再重新随机刷新,保证「播的就是看到的」;
    // 仅当区块尚无内容时才回退到拉取一批。
    var songs = _lastKnownSongs;
    if (songs == null || songs.isEmpty) {
      try {
        songs = await ref.refresh(randomSongsProvider.future);
      } catch (_) {
        songs = null;
      }
    }
    if (!mounted || token != _roundToken) return;
    if (songs == null || songs.isEmpty) return;
    _autoContinue = true;
    _roundSongIds = songs.map((s) => s.id).toSet();
    setState(() => _lastKnownSongs = songs);
    await playEffectiveQueue(ref, songs);
  }

  /// 队列播完(下一轮)时拉取新一批随机歌曲并**追加**到队尾继续播,而非整批替换。
  ///
  /// - 保留已播的旧轮次歌曲在队首(可往前切回),新一批从追加点无缝接上;
  /// - 新一批与旧内容按 id 去重,避免刚播完的歌立即又出现;
  /// - 本机链路用合并队列 + 从新批首首续播;投屏/DLNA 链路由其内部换批续播。
  Future<void> _loadNextRound() async {
    final token = ++_roundToken;
    final songs = await ref.refresh(randomSongsProvider.future);
    if (!mounted || token != _roundToken || !_autoContinue) return;
    if (songs.isEmpty) return;
    // 先读当前已展示/已播的历史批,再更新展示,否则 _lastKnownSongs 已被新批覆盖、
    // fresh 永远为空,无法实现「追加」。
    final current = _lastKnownSongs ?? const <Song>[];
    final currentIds = current.map((s) => s.id).toSet();
    final fresh = songs.where((s) => !currentIds.contains(s.id)).toList();
    if (fresh.isEmpty) return;
    _roundSongIds = songs.map((s) => s.id).toSet();
    setState(() => _lastKnownSongs = songs);
    final merged = <Song>[...current, ...fresh];
    await playEffectiveQueue(ref, merged, startIndex: current.length);
  }

  /// 随机歌曲歌单更新后的处理:
  /// - 刷新区块展示;
  /// - 若当前正在播放本轮随机歌曲(自动续播中且队列仍是随机轮次),
  ///   把新歌**追加**到播放队列末尾,而非替换队列 —— 保证播放不中断、
  ///   当前轮播完后能无缝接上最新一批。
  Future<void> _handleRandomSongsChanged() async {
    List<Song> songs;
    try {
      songs = await ref.refresh(randomSongsProvider.future);
    } catch (_) {
      return;
    }
    if (!mounted || songs.isEmpty) return;
    setState(() => _lastKnownSongs = songs);
    if (!_autoContinue || _roundSongIds.isEmpty) return;
    // 仅当当前播放队列仍是本轮随机歌曲时才追加,避免污染用户切到的其他歌单。
    final cast = ref.read(castPeerControllerProvider);
    final fresh = <Song>[];
    if (cast.activePeer != null) {
      final queuedIds = <String>{
        for (final it in cast.castQueue)
          if (it['songId'] is String) it['songId'] as String,
      };
      if (queuedIds.isEmpty ||
          !queuedIds.any(_roundSongIds.contains)) {
        return;
      }
      for (final s in songs) {
        if (!queuedIds.contains(s.id)) fresh.add(s);
      }
      if (fresh.isEmpty) return;
      await ref
          .read(castPeerControllerProvider.notifier)
          .enqueueSongs(fresh);
    } else if (ref.read(dlnaCastProvider).isCasting) {
      // 链路 B（局域网 DLNA 直投）：追加到直投队列末尾。
      final queuedIds = <String>{
        for (final t in ref.read(dlnaCastProvider).queue) t.songId,
      };
      if (queuedIds.isEmpty || !queuedIds.any(_roundSongIds.contains)) return;
      for (final s in songs) {
        if (!queuedIds.contains(s.id)) fresh.add(s);
      }
      if (fresh.isEmpty) return;
      await ref.read(dlnaCastProvider.notifier).enqueueSongs(fresh);
    } else {
      final queue = ref.read(playerProvider).queue;
      if (queue.isEmpty || !queue.any((s) => _roundSongIds.contains(s.id))) {
        return;
      }
      final queuedIds = queue.map((s) => s.id).toSet();
      for (final s in songs) {
        if (!queuedIds.contains(s.id)) fresh.add(s);
      }
      if (fresh.isEmpty) return;
      ref.read(playerProvider.notifier).addAllToQueue(fresh);
    }
    Logger.infoWithTag('DISCOVER', 'appended ${fresh.length} new random songs');
  }

  void _refresh() {
    _autoContinue = false;
    _roundSongIds = <String>{};
    _roundToken++;
    unawaited(_fetchLatestForDisplay());
  }

  /// 歌曲横滑网格(每列 3 行),供数据态与缓存占位态共用,布局完全一致。
/// 使用有界高度 + ListView.builder 实现**真懒加载**:只对可视列惰性构建,
/// 不再一次性创建全部 20 首歌曲的 widget,降低大歌单的内存占用。
/// 注意:外层 sliver 给的是无界高度,横向 ListView 必须有界高度,
/// 否则(同样的问题)会导致水平 viewport 高度异常、随机歌曲重叠无法操作,
/// 并拖垮下方歌单区块的布局。
  Widget _buildSongsContent(List<Song> songs) {
    // 宽度撑开:保证底部「歌手 · 时长」信息行只占一行(过窄会折成两行)。
    final itemWidth =
        (MediaQuery.sizeOf(context).width * 0.72).clamp(260.0, 360.0);
    if (songs.isEmpty) return const SizedBox.shrink();

    // 当前播放歌曲 id:识别正在播放的歌曲行（封面叠加跳动竖条）。
    final currentSongId = ref.watch(playerProvider.select((s) => s.currentSong?.id));

    final columnCount = (songs.length + 2) ~/ 3;
    // 每列最多 3 行。行高与封面等高(56):信息区 3 行(歌名/歌手/标签)
    // 正好塞进 56 高,行距 10px(参考稿,当前 5px 的 2 倍),再留少量余量兜底。
    const double tileRowMinHeight = 56;
    const double rowGap = 10;
    final columnHeight = tileRowMinHeight * 3 + rowGap * 2 + 10; // = 198

    return ClipRect(
      child: SizedBox(
        height: columnHeight,
        child: HoverableHorizontalScroll(
          builder: (context, controller) => ListView.builder(
            controller: controller,
            scrollDirection: Axis.horizontal,
            // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
            cacheExtent: 0,
            padding: EdgeInsets.zero,
            itemCount: columnCount,
            itemBuilder: (context, col) {
              final firstRow = col * 3;
              final rowsInColumn = (songs.length - firstRow).clamp(0, 3);
              return Padding(
                padding: EdgeInsets.only(right: context.musicFlowSpacing.sm),
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (var row = 0; row < rowsInColumn; row++) ...[
                      // Flexible 让每行共享整块高度,行内内容更高(如大字号)时由
                      // ClipRect 裁剪而**不触发 RenderFlex 溢出异常**——保持「紧凑
                      // 三行带」观感的同时,兼容 200% 字号这类极端缩放场景。
                      Flexible(
                        child: ClipRect(
                          child: SizedBox(
                            width: itemWidth,
                            child: DiscoverSongTile(
                              song: songs[firstRow + row],
                              isCurrent:
                                  currentSongId != null &&
                                  currentSongId ==
                                      songs[firstRow + row].id,
                              onPressed: () {
                                playEffectiveQueue(
                                  ref,
                                  songs,
                                  startIndex: firstRow + row,
                                );
                              },
                              onOpenActions: () => showSongOptionsSheet(
                                context: context,
                                song: songs[firstRow + row],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (row + 1 < rowsInColumn) const SizedBox(height: rowGap),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _randomSongsSubscription?.cancel();
    _autoRetryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final loc = AppLocalizations.of(context);
    final loadFailed = ref.watch(randomSongsLoadFailedProvider);
    final knownSongs = _lastKnownSongs;
    final hasContent = knownSongs != null && knownSongs.isNotEmpty;

    // 一轮(20 首)播完自动换下一轮
    ref.listen<PlayerState>(playerProvider, (prev, next) {
      if (!_autoContinue) return;
      final queue = next.queue;
      if (queue.isEmpty) return;
      if (next.processingState == ProcessingState.completed &&
          next.currentIndex == queue.length - 1) {
        unawaited(_loadNextRound());
      }
    });

    // 打开页面不触发远程请求:先秒出本地缓存,只有播放/手动刷新/收到歌单变更
    // 推送时才按需拉取,避免「打开客户端 → 后端惰性重建 → 长时间等待」。
    // 数据驱动解耦:服务端暂无随机歌曲数据且本机也无缓存时,整块隐藏,不展示
    // 「网络异常/不可用」的错误提示(该失败通常是慢探测/地址未就绪的瞬时态,
    // ensureActiveAddressProvider 会自愈)。有缓存/有数据 → 正常展示;加载中 →
    // 骨架屏;仅当「无数据且加载态」之外的内容都没有缓存时才回落骨架。
    if (!hasContent && loadFailed) {
      return const SizedBox.shrink();
    }
    final Widget content;
    if (hasContent) {
      content = _buildSongsContent(knownSongs);
    } else {
      content = const _RandomSongsLoading();
    }

    // 播放「按钮盒」右缘距窗口右边缘 10px 视觉间隔,随窗口宽度自适应:
    // 内容区右缘本身距窗口 `pageHorizPadding - 5` px。Padding 只能让盒在
    // 内容区内靠右(盒右缘距窗口 ≥ pageHorizPadding-5=11px),要精确贴到 10px
    // 需在内容区基础上再右移 (pageHorizPadding-5) - 10 px(可正可负,取 clamp
    // 下限 0 避免窄窗口下向左挤);用 Transform 平移(不参与布局,不挤压其它
    // 元素),避免把整个 header 行拖宽。图标在 48 盒内 22px 居中(右缘距盒右缘
    // 13px),故图标右缘距窗口 = 10 + 13 = 23px,测试按「盒右缘」断言。
    final contentRightGap = context.musicFlowPageHorizontalPadding - 5;
    final playRightShift = (contentRightGap - 10)
        .clamp(0.0, double.infinity)
        .toDouble();

    // 去掉外框(原 surface 背景 + 描边):参考箭头音乐,随机歌曲区块直接融入
    // 页面底色,不再用卡片包裹。保留 key 供测试定位。
    return Padding(
      key: const Key('discover-random-mix'),
      // 区块不加横向内边距：标题/封面与歌单封面统一从页级边距起，垂直对齐。
      padding: EdgeInsets.symmetric(
        horizontal: 0,
        vertical: context.musicFlowSpacing.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          MusicFlowSectionHeader.compact(
            title: loc.discover_random_songs,
            // 刷新按钮挨着模块标题,播放按钮由 Spacer 推到最右。
            trailingFollowsTitle: true,
            trailing: Row(
              children: <Widget>[
                MusicFlowIconButton(
                  icon: AppIcons.refresh,
                  label: loc.discover_shuffle_song_label,
                  onPressed: _refresh,
                ),
                const Spacer(),
                // 播放按钮右侧留白(盒右缘距窗口右边缘 10px,见上方
                // playRightShift 换算)。用 Transform 平移而非 Padding:
                // Padding 的最小右缘是内容区右缘(11px),贴不到 10px;
                // Transform 不参与布局,不会挤压刷新按钮/标题。
                Transform.translate(
                  offset: Offset(playRightShift, 0),
                  child: MusicFlowIconButton(
                    icon: AppIcons.play,
                    label: loc.discover_play_random_songs,
                    onPressed: _playRound,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: context.musicFlowSpacing.xxs),
          content,
        ],
      ),
    );
  }
}

/// 随机歌曲加载态:横滑 + 每列 3 行骨架,与数据态布局(横滑列、每列 3 行)
/// 完全一致,避免「刚打开是 5 行、刷新后跳成 3 行」的高度跳变。
class _RandomSongsLoading extends StatelessWidget {
  const _RandomSongsLoading();

  @override
  Widget build(BuildContext context) {
    // 宽度撑开:保证底部「歌手 · 时长」信息行只占一行(过窄会折成两行)。
    final itemWidth =
        (MediaQuery.sizeOf(context).width * 0.72).clamp(260.0, 360.0);
    // 高度与数据态 _buildSongsContent 保持一致,避免「加载态→数据态」跳变。
    const double skeletonColumnHeight = 198;
    return ClipRect(
      child: SizedBox(
        height: skeletonColumnHeight,
        child: HoverableHorizontalScroll(
          builder: (context, controller) => SingleChildScrollView(
            controller: controller,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (var col = 0; col < 3; col++)
                  Padding(
                    padding: EdgeInsets.only(right: context.musicFlowSpacing.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (var row = 0; row < 3; row++) ...[
                          SizedBox(
                            width: itemWidth,
                            child: const _RandomSongTileSkeleton(),
                          ),
                          if (row < 2) const SizedBox(height: 10),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单行歌曲骨架(封面 + 两行文字),与 DiscoverSongTile 高度对齐。
class _RandomSongTileSkeleton extends StatelessWidget {
  const _RandomSongTileSkeleton();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: EdgeInsets.zero,
          child: Row(
            children: <Widget>[
              const MusicFlowSkeleton(width: 56, height: 56),
              SizedBox(width: context.musicFlowSpacing.sm),
              const Expanded(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  MusicFlowSkeleton.line(height: 16),
                  SizedBox(height: 8),
                  MusicFlowSkeleton.line(width: 112, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
