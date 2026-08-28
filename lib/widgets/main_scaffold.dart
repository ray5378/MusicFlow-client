import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/design/components/music_flow_anchor.dart';
import '../core/design/music_flow_design.dart';
import '../core/network/connectivity_monitor.dart';
import '../core/utils/logger.dart';
import '../data/models/server_address.dart';
import '../features/library/pages/album_list_page.dart';
import '../features/library/pages/artist_list_page.dart';
import '../features/library/pages/playlist_search_page.dart';
import '../features/library/pages/song_list_page.dart';
import '../features/library/pages/starred_page.dart';
import '../features/player/widgets/mini_player.dart';
import '../providers/api_provider.dart';
import '../providers/cast_peer_provider.dart';
import '../providers/effective_playback_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/random_songs_push_provider.dart';
import '../providers/status_lyrics_provider.dart';
import 'app_drawer.dart';
import 'music_flow_app_shell/music_flow_app_shell.dart';
import 'music_flow_app_shell/music_flow_network_status_bar.dart';
import 'music_flow_app_shell/music_flow_shell_navigation.dart';
import 'windows_title_bar.dart';

// GlobalKey used to access Scaffold state (e.g. opening drawer).
final scaffoldKey = GlobalKey<ScaffoldState>();
FocusNode? _appDrawerTriggerFocus;

/// Opens the application drawer while retaining the keyboard focus origin.
///
/// Compact pages and the wide shell share this entry point so a drawer-owned
/// overlay can return focus to the exact menu control that launched it.
void openMusicFlowAppDrawer() {
  final currentFocus = FocusManager.instance.primaryFocus;
  if (currentFocus != null &&
      currentFocus.context != null &&
      currentFocus.canRequestFocus) {
    _appDrawerTriggerFocus = currentFocus;
  }
  scaffoldKey.currentState?.openDrawer();
}

/// Page headers own the drawer trigger only in the compact shell.
///
/// Medium and expanded layouts expose the same action from their persistent
/// navigation surface, so retaining the page-level button would create a
/// duplicate control and a confusing accessibility traversal order.
bool shouldShowPageDrawerTrigger(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return context.musicFlowBreakpoints.classify(width) == MusicFlowWindowClass.compact;
}

void _restoreMusicFlowAppDrawerFocus() {
  final triggerFocus = _appDrawerTriggerFocus;
  _appDrawerTriggerFocus = null;
  if (triggerFocus == null ||
      triggerFocus.context == null ||
      !triggerFocus.canRequestFocus) {
    return;
  }
  triggerFocus.requestFocus();
}

enum MusicFlowBackAction {
  closeDrawer,
  popRootNavigator,
  popBranchNavigator,
  switchToDiscover,
  moveAppToBackground,
}

@visibleForTesting
MusicFlowBackAction resolveMusicFlowBackAction({
  required bool drawerOpen,
  required bool rootCanPop,
  required bool branchCanPop,
  required int currentBranchIndex,
}) {
  if (drawerOpen) return MusicFlowBackAction.closeDrawer;
  if (rootCanPop) return MusicFlowBackAction.popRootNavigator;
  if (branchCanPop) return MusicFlowBackAction.popBranchNavigator;
  if (currentBranchIndex != discoverBranchIndex) {
    return MusicFlowBackAction.switchToDiscover;
  }
  return MusicFlowBackAction.moveAppToBackground;
}

/// Windows 桌面端侧栏入口文案为「主页」,其余平台沿用「音乐流」。
@visibleForTesting
List<MusicFlowShellDestination> musicFlowMainDestinations() {
  final isWindowsDesktop =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  return <MusicFlowShellDestination>[
    MusicFlowShellDestination(
      branchIndex: discoverBranchIndex,
      label: isWindowsDesktop ? '主页' : '音乐流',
      icon: AppIcons.home,
      selectedIcon: AppIcons.homeFilled,
    ),
  ];
}

class MainScaffold extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;
  final List<GlobalKey<NavigatorState>> branchNavigatorKeys;

  const MainScaffold({
    super.key,
    required this.navigationShell,
    required this.branchNavigatorKeys,
    this.drawerOverride,
    this.miniPlayerOverride,
    this.showMiniPlayerOverride,
    this.networkStatusOverride,
  });

  @visibleForTesting
  final Widget? drawerOverride;

  @visibleForTesting
  final Widget? miniPlayerOverride;

  @visibleForTesting
  final bool? showMiniPlayerOverride;

  @visibleForTesting
  final MusicFlowNetworkStatus? networkStatusOverride;

  @override
  ConsumerState<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends ConsumerState<MainScaffold> {
  static const _logTag = 'BACK';
  static const MethodChannel _appLifecycleChannel = MethodChannel(
    'com.musicflow.app/app_lifecycle',
  );
  static const BasicMessageChannel<String> _trayChannel =
      BasicMessageChannel<String>('com.musicflow.app/tray', StringCodec());
  int? _lastSyncedBranchIndex;
  StreamSubscription<NetworkType>? _networkTypeSubscription;
  Timer? _initialNetworkStateTimer;
  NetworkType? _observedNetworkType;

  @override
  void initState() {
    super.initState();
    _scheduleVisibleBranchSync();
    if (widget.networkStatusOverride == null) {
      _startNetworkObservation();
    }
    _initTrayListener();
    // 激活 Windows 托盘/任务栏歌词控制器(启动时恢复开关状态并监听歌词)。
    ref.read(statusLyricsControllerProvider);
    // 激活随机歌曲歌单「服务端推送」客户端:连接主项目 WebSocket,收到
    // random-songs-changed 信号时通知客户端按需重拉,替代客户端轮询。
    ref.read(randomSongsPushProvider);
  }

  void _initTrayListener() {
    _trayChannel.setMessageHandler((message) async {
      if (!mounted || message == null) return '';
      switch (message) {
        case 'toggle_play_pause':
          await toggleEffectivePlayback(ref);
          break;
        case 'previous':
          await ref.read(castPeerControllerProvider.notifier).previous();
          break;
        case 'next':
          await ref.read(castPeerControllerProvider.notifier).next();
          break;
        case 'toggle_status_lyrics':
          // 托盘菜单「显示状态栏歌词」:与客户端设置页开关共用同一个入口。
          await ref.read(statusLyricsControllerProvider).toggle();
          break;
      }
      return '';
    });
  }

  @override
  void didUpdateWidget(covariant MainScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleVisibleBranchSync();
    if (oldWidget.networkStatusOverride != widget.networkStatusOverride) {
      if (widget.networkStatusOverride == null) {
        _startNetworkObservation();
      } else {
        _stopNetworkObservation();
      }
    }
  }

  @override
  void dispose() {
    _stopNetworkObservation();
    super.dispose();
  }

  void _startNetworkObservation() {
    _stopNetworkObservation();
    final monitor = ref.read(connectivityMonitorProvider);
    _networkTypeSubscription = monitor.networkTypeStream.listen((networkType) {
      _initialNetworkStateTimer?.cancel();
      if (!mounted || _observedNetworkType == networkType) return;
      setState(() {
        _observedNetworkType = networkType;
      });
    });
    _initialNetworkStateTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _observedNetworkType != null) return;
      setState(() {
        _observedNetworkType = monitor.currentNetworkType;
      });
    });
  }

  void _stopNetworkObservation() {
    _initialNetworkStateTimer?.cancel();
    _initialNetworkStateTimer = null;
    _networkTypeSubscription?.cancel();
    _networkTypeSubscription = null;
    _observedNetworkType = null;
  }

  MusicFlowNetworkStatus _resolveNetworkStatus({
    required bool activeAddressIsHealthy,
  }) {
    final networkType = _observedNetworkType;
    if (networkType == null) return MusicFlowNetworkStatus.online;
    if (networkType == NetworkType.none) return MusicFlowNetworkStatus.offline;
    if (!activeAddressIsHealthy) return MusicFlowNetworkStatus.weak;
    return MusicFlowNetworkStatus.online;
  }

  void _scheduleVisibleBranchSync() {
    final currentIndex = widget.navigationShell.currentIndex;
    if (_lastSyncedBranchIndex == currentIndex) {
      return;
    }
    _lastSyncedBranchIndex = currentIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.navigationShell.currentIndex != currentIndex) return;
      _syncVisibleBranch(currentIndex);
    });
  }

  void _syncVisibleBranch(int branchIndex) {
    _lastSyncedBranchIndex = branchIndex;
    ref.read(currentVisibleBranchIndexProvider.notifier).state = branchIndex;
  }

  void _goToBranch(int branchIndex, {bool initialLocation = false}) {
    _syncVisibleBranch(branchIndex);
    // 点击侧栏「音乐流」等返回首页时,先把目标分支内指令式 push 的页面
    // (库列表、线路选择等)清空回根,确保是真正回到该分支首页,而非停留在子页。
    if (branchIndex >= 0 && branchIndex < widget.branchNavigatorKeys.length) {
      final branchNavigator = widget.branchNavigatorKeys[branchIndex].currentState;
      branchNavigator?.popUntil((route) => route.isFirst);
    }
    widget.navigationShell.goBranch(
      branchIndex,
      initialLocation: initialLocation,
    );
  }

  Future<void> _handleBackPressed() async {
    final index = widget.navigationShell.currentIndex;
    final branchCount = widget.branchNavigatorKeys.length;

    final scaffold = scaffoldKey.currentState;
    final rootNavigator = Navigator.of(context);
    NavigatorState? branchNavigator;
    if (index >= 0 && index < branchCount) {
      final navigatorKey = widget.branchNavigatorKeys[index];
      branchNavigator = navigatorKey.currentState;
    } else {
      Logger.warnWithTag(
        _logTag,
        'index $index out of range [0, $branchCount)',
      );
    }

    final action = resolveMusicFlowBackAction(
      drawerOpen: scaffold?.isDrawerOpen ?? false,
      rootCanPop: rootNavigator.canPop(),
      branchCanPop: branchNavigator?.canPop() ?? false,
      currentBranchIndex: index,
    );

    switch (action) {
      case MusicFlowBackAction.closeDrawer:
        Logger.infoWithTag(_logTag, 'drawer is open, closing drawer');
        scaffold?.closeDrawer();
      case MusicFlowBackAction.popRootNavigator:
        Logger.infoWithTag(_logTag, 'root navigator can pop, popping');
        rootNavigator.pop();
      case MusicFlowBackAction.popBranchNavigator:
        Logger.infoWithTag(_logTag, 'branch $index can pop, popping');
        branchNavigator?.pop();
      case MusicFlowBackAction.switchToDiscover:
        Logger.infoWithTag(
          _logTag,
          'non-home branch root reached (index=$index), switching to home tab',
        );
        _goToBranch(discoverBranchIndex);
      case MusicFlowBackAction.moveAppToBackground:
        Logger.infoWithTag(
          _logTag,
          'home branch root reached (index=0), move app to background',
        );
        await _moveAppToBackground();
    }
  }

  Future<void> _moveAppToBackground() async {
    try {
      await _appLifecycleChannel.invokeMethod<void>('moveTaskToBack');
      Logger.infoWithTag(_logTag, 'moveTaskToBack invoked');
    } on MissingPluginException {
      // Ignore on non-Android platforms where this channel is not implemented.
      Logger.warnWithTag(_logTag, 'moveTaskToBack channel missing');
    } on PlatformException {
      // Keep app state unchanged if moving to background fails.
      Logger.warnWithTag(_logTag, 'moveTaskToBack invoke failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleVisibleBranchSync();
    // 迷你播放器常驻显示(对齐主项目前端 player-bar 始终渲染):
    // 无歌曲时展示「未在播放」占位,而不是隐藏播放控件。
    final bool hasMiniPlayer = widget.showMiniPlayerOverride ?? true;
    final activeAddressIsHealthy = ref.watch(
      activeAddressProvider.select((address) {
        return address?.status == ServerAddressStatus.ok;
      }),
    );
    final networkStatus =
        widget.networkStatusOverride ??
        _resolveNetworkStatus(activeAddressIsHealthy: activeAddressIsHealthy);
    final currentBranchIndex = widget.navigationShell.currentIndex;
    final destinations = musicFlowMainDestinations();
    final currentBranchIsVisible = destinations.any(
      (destination) => destination.branchIndex == currentBranchIndex,
    );

    return BackButtonListener(
      onBackButtonPressed: () async {
        await _handleBackPressed();
        return true;
      },
      // 根级指针位置捕获:桌面端锚点弹窗据此定位到触发按钮附近。
      child: MusicFlowTapAnchorScope(
        // Windows 去掉自绘标题栏:侧边栏与内容区均从顶到底铺满。
        // 窗口控制按钮由 WindowsWindowChrome 覆盖在内容区右上角,
        // 其透明拖拽区保留了大屏下顶部长按拖动/双击最大化。
        child: Stack(
          key: const ValueKey<String>('main-scaffold-stack'),
          children: <Widget>[
            SizedBox.expand(
              child: MusicFlowAppShell(
                scaffoldKey: scaffoldKey,
                drawer:
                    widget.drawerOverride ??
                    AppDrawer(
                      onReturnFocus: _restoreMusicFlowAppDrawerFocus,
                      onOpenPage: _openPageInContentArea,
                    ),
                body: widget.navigationShell,
                destinations: destinations,
                selectedBranchIndex: currentBranchIsVisible
                    ? currentBranchIndex
                    : discoverBranchIndex,
                onDestinationSelected: (branchIndex) {
                  _goToBranch(
                    branchIndex,
                    initialLocation: branchIndex == currentBranchIndex,
                  );
                },
                miniPlayer: widget.miniPlayerOverride ?? const MiniPlayer(),
                showMiniPlayer: hasMiniPlayer,
                networkStatus: networkStatus,
                showNavigationBar: false,
                onOpenDrawer: openMusicFlowAppDrawer,
                // Windows 宽屏侧栏曲库快捷入口(对齐箭头音乐 windowsui)。
                libraryEntries: _libraryEntries(),
                onOpenPage: _openPageInContentArea,
              ),
            ),
            // Windows 无标题栏:顶部透明拖拽区 + 右上角窗口控制按钮。
            const WindowsWindowChrome(),
          ],
        ),
      ),
    );
  }

  /// 当前分支的内容区导航器。Windows 宽屏下侧栏/抽屉位于分支导航器
  /// 之外，直接 Navigator.of(context) 会推到根导航器导致全屏覆盖壳；
  /// 统一改由分支导航器打开，使侧栏保持可见、仅内容区切换。
  NavigatorState? _currentBranchNavigator() {
    final index = widget.navigationShell.currentIndex;
    if (index < 0 || index >= widget.branchNavigatorKeys.length) return null;
    return widget.branchNavigatorKeys[index].currentState;
  }

  /// 把页面推入内容区（分支导航器），对齐首页横排「库」条目的行为。
  Future<void> _openPageInContentArea(Widget page) async {
    final navigator = _currentBranchNavigator();
    if (navigator != null && navigator.mounted) {
      await navigator.push<void>(
        MusicFlowPageRoute<void>(
          context: navigator.context,
          builder: (_) => page,
        ),
      );
      return;
    }
    // 分支导航器尚未就绪时回退到根导航器（保持原行为）。
    await Navigator.of(context).push<void>(
      MusicFlowPageRoute<void>(context: context, builder: (_) => page),
    );
  }

  /// 侧栏「曲库」快捷入口(宽屏)。点击直接打开对应列表页,
  /// 页面内部为窗口化分页加载。对标主项目 web 端侧栏。
  ///
  /// 注意:必须是 State 的实例方法——它通过 [_openPageInContentArea]
  /// 把页面推到内容区分支导航器,而该方法依赖 State 的 widget 状态。
  List<MusicFlowSidebarLibraryEntry> _libraryEntries() {
    Future<void> open(Widget page) => _openPageInContentArea(page);

    return <MusicFlowSidebarLibraryEntry>[
      MusicFlowSidebarLibraryEntry(
        label: '歌单',
        icon: AppIcons.playlist,
        onTap: () => unawaited(open(const PlaylistSearchPage())),
      ),
      MusicFlowSidebarLibraryEntry(
        label: '音乐',
        icon: AppIcons.headphones,
        onTap: () => unawaited(open(const SongListPage())),
      ),
      MusicFlowSidebarLibraryEntry(
        label: '艺术家',
        icon: AppIcons.profile,
        onTap: () => unawaited(open(const ArtistListPage())),
      ),
      MusicFlowSidebarLibraryEntry(
        label: '专辑',
        icon: AppIcons.album,
        onTap: () => unawaited(open(const AlbumListPage())),
      ),
      MusicFlowSidebarLibraryEntry(
        label: '我喜欢',
        icon: AppIcons.heart,
        onTap: () => unawaited(open(const StarredPage())),
      ),
    ];
  }
}
