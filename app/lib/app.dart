import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/theme.dart';
import 'data/api_client.dart';
import 'data/auth_store.dart';
import 'data/models.dart';
import 'pages/detail_pages.dart';
import 'pages/full_player.dart';
import 'pages/home.dart';
import 'pages/library_list.dart';
import 'pages/login.dart';
import 'pages/search.dart';
import 'pages/settings.dart';
import 'player/dlna_service.dart';
import 'player/player_service.dart';
import 'widgets/player_bar.dart';

/// 应用根：初始化登录态，未登录进登录页。
class MusicFlowApp extends StatefulWidget {
  const MusicFlowApp({super.key});

  @override
  State<MusicFlowApp> createState() => _MusicFlowAppState();
}

class _MusicFlowAppState extends State<MusicFlowApp> {
  AuthStore? store;
  ApiClient? api;
  PlayerService? player;
  ThemeMode themeMode = ThemeMode.system;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final s = AuthStore(prefs);
    await s.load();
    ApiClient? client;
    if (s.loggedIn) {
      final c = ApiClient(s);
      try {
        await c.ping();
        client = c;
      } catch (_) {
        await s.clear();
      }
    }
    if (!mounted) return;
    setState(() {
      store = s;
      api = client;
      if (client != null) player = PlayerService(client, DlnaService());
      ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ready || store == null) {
      return const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator())));
    }
    final s = store!;
    return MaterialApp(
      title: 'MusicFlow',
      theme: AppTypography(Brightness.light).theme(),
      darkTheme: AppTypography(Brightness.dark).theme(),
      themeMode: themeMode,
      home: (api == null || player == null)
          ? LoginPage(store: s, onLoggedIn: _afterLogin)
          : Shell(
              api: api!,
              player: player!,
              store: s,
              onLogout: () => setState(() {
                api = null;
                player = null;
                unawaited(s.clear());
              }),
              themeMode: themeMode,
              onThemeMode: (m) => setState(() => themeMode = m),
            ),
    );
  }

  void _afterLogin(AuthStore s) {
    final c = ApiClient(s);
    setState(() {
      api = c;
      player = PlayerService(c, DlnaService());
    });
  }
}

/// 主框架：宽屏左侧栏 + 内容 + 底部播放条；窄屏内容 + 迷你条。
class Shell extends StatelessWidget {
  const Shell({
    super.key,
    required this.api,
    required this.player,
    required this.store,
    required this.onLogout,
    required this.themeMode,
    required this.onThemeMode,
  });

  final ApiClient api;
  final PlayerService player;
  final AuthStore store;
  final VoidCallback onLogout;
  final ThemeMode themeMode;
  final void Function(ThemeMode) onThemeMode;

  void _playQueue(List<Song> songs, int startIndex) =>
      unawaited(player.playQueue(songs, startIndex: startIndex).catchError((_) {}));

  void _playRemote(RemoteSong song) =>
      unawaited(player.playRemote(song).catchError((_) {}));

  Future<void> _openLibrary(BuildContext context, HomeTarget t) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LibraryListPage(api: api, target: t, onPlayQueue: _playQueue),
    ));
  }

  Widget _routePage(String? name, Object? arguments, BuildContext context) {
    // 侧栏快捷入口：'#songs' 等映射到曲库列表。
    switch (name) {
      case '/search':
        return SearchPage(api: api, onPlayQueue: _playQueue, onPlayRemote: _playRemote);
      case '/settings':
        return SettingsPage(
          store: store,
          onLogout: () {
            onLogout();
            unawaited(store.clear());
          },
          themeMode: themeMode,
          onThemeMode: onThemeMode,
        );
      case '/player':
        return FullPlayerPage(api: api, player: player);
      case '/album':
        return AlbumDetailPage(api: api, albumId: '$arguments', onPlayQueue: _playQueue);
      case '/artist':
        return ArtistDetailPage(
          api: api,
          artistId: '$arguments',
          onOpenAlbum: (id) => unawaited(
            Navigator.of(context).pushNamed('/album', arguments: id),
          ),
        );
      case '/playlist':
        return PlaylistDetailPage(api: api, playlistId: '$arguments', onPlayQueue: _playQueue);
      case '#songs':
      case '#albums':
      case '#artists':
      case '#playlists':
      case '#favorite':
        final target = switch (name) {
          '#albums' => HomeTarget.albums,
          '#artists' => HomeTarget.artists,
          '#playlists' => HomeTarget.playlists,
          '#favorite' => HomeTarget.favorite,
          _ => HomeTarget.songs,
        };
        return LibraryListPage(api: api, target: target, onPlayQueue: _playQueue);
      default:
        return HomePage(
          api: api,
          onPlayQueue: _playQueue,
          onOpen: (t) => unawaited(_openLibrary(context, t)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;

    final rootNav = Navigator(
      initialRoute: '/',
      onGenerateRoute: (settings) {
        Widget page;
        try {
          page = _routePage(settings.name, settings.arguments, context);
        } catch (_) {
          page = HomePage(
            api: api,
            onPlayQueue: _playQueue,
            onOpen: (t) => unawaited(_openLibrary(context, t)),
          );
        }
        return MaterialPageRoute<void>(builder: (_) => page, settings: settings);
      },
    );

    if (!wide) {
      return Scaffold(body: rootNav, bottomNavigationBar: PlayerBar(api: api, player: player));
    }

    return Scaffold(
      body: Row(children: [_Sidebar(onSelect: (name) => unawaited(_openSidebar(context, name))), Expanded(child: rootNav)]),
      bottomNavigationBar: PlayerBar(api: api, player: player),
    );
  }

  /// 侧栏导航：先回到根（清掉推入的详情页），再按需打开列表页或路由页。
  Future<void> _openSidebar(BuildContext context, String name) async {
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    if (name == '/') return;
    await Future<void>.delayed(Duration.zero);
    if (!context.mounted) return;
    if (name.startsWith('#')) {
      final t = switch (name) {
        '#albums' => HomeTarget.albums,
        '#artists' => HomeTarget.artists,
        '#playlists' => HomeTarget.playlists,
        '#favorite' => HomeTarget.favorite,
        _ => HomeTarget.songs,
      };
      await _openLibrary(context, t);
      return;
    }
    await nav.pushNamed(name);
  }
}

/// 宽屏左侧导航（对齐箭头音乐 Windows 布局）。
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.onSelect});

  final void Function(String routeName) onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    Widget item(String label, IconData icon, String route) => ListTile(
          leading: Icon(icon),
          title: Text(label, style: tt.titleMedium),
          selected: route == '/',
          selectedColor: cs.primary,
          onTap: () => onSelect(route),
        );

    return Container(
      width: 220,
      color: cs.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text('MusicFlow', style: tt.displaySmall),
            ),
            item('首页', Icons.home_outlined, '/'),
            item('歌曲', Icons.music_note_outlined, '#songs'),
            item('专辑', Icons.album_outlined, '#albums'),
            item('艺术家', Icons.mic_none, '#artists'),
            item('歌单', Icons.queue_music_outlined, '#playlists'),
            item('喜爱', Icons.favorite_border, '#favorite'),
            const Spacer(),
            item('设置', Icons.settings_outlined, '/settings'),
          ],
        ),
      ),
    );
  }
}
