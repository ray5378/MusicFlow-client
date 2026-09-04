import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @app_title.
  ///
  /// In zh, this message translates to:
  /// **'MusicFlow'**
  String get app_title;

  /// No description provided for @settings_language.
  ///
  /// In zh, this message translates to:
  /// **'界面语言'**
  String get settings_language;

  /// No description provided for @settings_language_caption.
  ///
  /// In zh, this message translates to:
  /// **'切换应用界面使用的语言'**
  String get settings_language_caption;

  /// No description provided for @language_follow_system.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get language_follow_system;

  /// No description provided for @language_follow_system_desc.
  ///
  /// In zh, this message translates to:
  /// **'自动匹配设备语言，不支持时回退中文'**
  String get language_follow_system_desc;

  /// No description provided for @language_zh.
  ///
  /// In zh, this message translates to:
  /// **'中文'**
  String get language_zh;

  /// No description provided for @language_zh_desc.
  ///
  /// In zh, this message translates to:
  /// **'始终使用简体中文'**
  String get language_zh_desc;

  /// No description provided for @language_en.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get language_en;

  /// No description provided for @language_en_desc.
  ///
  /// In zh, this message translates to:
  /// **'始终使用英文界面'**
  String get language_en_desc;

  /// No description provided for @widgets_retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get widgets_retry;

  /// No description provided for @widgets_settings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get widgets_settings;

  /// No description provided for @widgets_artists.
  ///
  /// In zh, this message translates to:
  /// **'艺术家'**
  String get widgets_artists;

  /// No description provided for @widgets_albums.
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get widgets_albums;

  /// No description provided for @widgets_songs.
  ///
  /// In zh, this message translates to:
  /// **'歌曲'**
  String get widgets_songs;

  /// No description provided for @widgets_playlists.
  ///
  /// In zh, this message translates to:
  /// **'歌单'**
  String get widgets_playlists;

  /// No description provided for @widgets_favorites.
  ///
  /// In zh, this message translates to:
  /// **'喜欢'**
  String get widgets_favorites;

  /// No description provided for @widgets_connection_ok.
  ///
  /// In zh, this message translates to:
  /// **'连接正常'**
  String get widgets_connection_ok;

  /// No description provided for @widgets_connection_failed.
  ///
  /// In zh, this message translates to:
  /// **'连接失败'**
  String get widgets_connection_failed;

  /// No description provided for @widgets_connection_pending.
  ///
  /// In zh, this message translates to:
  /// **'等待检测'**
  String get widgets_connection_pending;

  /// No description provided for @widgets_connection_disconnected.
  ///
  /// In zh, this message translates to:
  /// **'未连接'**
  String get widgets_connection_disconnected;

  /// No description provided for @widgets_drawer_library_unselected.
  ///
  /// In zh, this message translates to:
  /// **'未选择'**
  String get widgets_drawer_library_unselected;

  /// No description provided for @widgets_drawer_no_active_route.
  ///
  /// In zh, this message translates to:
  /// **'没有活动线路'**
  String get widgets_drawer_no_active_route;

  /// No description provided for @widgets_drawer_library_empty_title.
  ///
  /// In zh, this message translates to:
  /// **'还没有音乐库'**
  String get widgets_drawer_library_empty_title;

  /// No description provided for @widgets_drawer_library_empty_desc.
  ///
  /// In zh, this message translates to:
  /// **'添加一个 Navidrome、Subsonic 或 OpenSubsonic 音乐库后即可开始聆听。'**
  String get widgets_drawer_library_empty_desc;

  /// No description provided for @widgets_drawer_add_library.
  ///
  /// In zh, this message translates to:
  /// **'添加音乐库'**
  String get widgets_drawer_add_library;

  /// No description provided for @widgets_drawer_server_unconfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置服务器地址'**
  String get widgets_drawer_server_unconfigured;

  /// No description provided for @widgets_drawer_add_new_library.
  ///
  /// In zh, this message translates to:
  /// **'添加新音乐库'**
  String get widgets_drawer_add_new_library;

  /// No description provided for @widgets_drawer_add_new_library_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'连接另一台服务器或另一个账户'**
  String get widgets_drawer_add_new_library_subtitle;

  /// No description provided for @widgets_drawer_library_error_title.
  ///
  /// In zh, this message translates to:
  /// **'无法读取音乐库'**
  String get widgets_drawer_library_error_title;

  /// No description provided for @widgets_drawer_library_error_desc.
  ///
  /// In zh, this message translates to:
  /// **'音乐库列表暂时不可用。重试不会影响当前正在播放的内容。'**
  String get widgets_drawer_library_error_desc;

  /// No description provided for @widgets_cover_art_album.
  ///
  /// In zh, this message translates to:
  /// **'专辑封面'**
  String get widgets_cover_art_album;

  /// No description provided for @widgets_cover_art_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'封面加载失败，自动重试中'**
  String get widgets_cover_art_load_failed;

  /// 封面加载失败的语义标签（含自定义无障碍标签）
  ///
  /// In zh, this message translates to:
  /// **'{label}，封面加载失败'**
  String widgets_cover_art_load_failed_with_label(String label);

  /// No description provided for @widgets_cover_art_loading.
  ///
  /// In zh, this message translates to:
  /// **'封面加载中'**
  String get widgets_cover_art_loading;

  /// No description provided for @widgets_cover_art_none.
  ///
  /// In zh, this message translates to:
  /// **'暂无封面'**
  String get widgets_cover_art_none;

  /// No description provided for @widgets_home.
  ///
  /// In zh, this message translates to:
  /// **'主页'**
  String get widgets_home;

  /// No description provided for @widgets_music_flow.
  ///
  /// In zh, this message translates to:
  /// **'音乐流'**
  String get widgets_music_flow;

  /// No description provided for @widgets_music.
  ///
  /// In zh, this message translates to:
  /// **'音乐'**
  String get widgets_music;

  /// No description provided for @widgets_i_like.
  ///
  /// In zh, this message translates to:
  /// **'我喜欢'**
  String get widgets_i_like;

  /// No description provided for @widgets_play.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get widgets_play;

  /// No description provided for @widgets_shuffle.
  ///
  /// In zh, this message translates to:
  /// **'随机播放'**
  String get widgets_shuffle;

  /// No description provided for @widgets_route_selection_title.
  ///
  /// In zh, this message translates to:
  /// **'切换线路'**
  String get widgets_route_selection_title;

  /// No description provided for @widgets_route_redetect_latency.
  ///
  /// In zh, this message translates to:
  /// **'重新检测延迟'**
  String get widgets_route_redetect_latency;

  /// No description provided for @widgets_route_error_title.
  ///
  /// In zh, this message translates to:
  /// **'无法读取线路'**
  String get widgets_route_error_title;

  /// No description provided for @widgets_route_error_desc.
  ///
  /// In zh, this message translates to:
  /// **'线路信息暂时不可用。请重试，或稍后打开音乐库设置检查地址。'**
  String get widgets_route_error_desc;

  /// No description provided for @widgets_route_no_route_title.
  ///
  /// In zh, this message translates to:
  /// **'没有可用线路'**
  String get widgets_route_no_route_title;

  /// No description provided for @widgets_route_no_route_desc.
  ///
  /// In zh, this message translates to:
  /// **'请先在音乐库设置中添加至少一个服务器地址。'**
  String get widgets_route_no_route_desc;

  /// No description provided for @widgets_route_auto_enabled.
  ///
  /// In zh, this message translates to:
  /// **'当前已开启'**
  String get widgets_route_auto_enabled;

  /// 自动模式已开启提示（含当前线路名称）
  ///
  /// In zh, this message translates to:
  /// **'当前已开启 · {label}'**
  String widgets_route_auto_enabled_label(String label);

  /// No description provided for @widgets_route_auto_select.
  ///
  /// In zh, this message translates to:
  /// **'自动选择'**
  String get widgets_route_auto_select;

  /// No description provided for @widgets_route_auto_select_desc.
  ///
  /// In zh, this message translates to:
  /// **'根据可用性和延迟选择线路'**
  String get widgets_route_auto_select_desc;

  /// No description provided for @widgets_route_latency_unknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get widgets_route_latency_unknown;

  /// 延迟数值标签
  ///
  /// In zh, this message translates to:
  /// **'延迟 {value}'**
  String widgets_route_latency_label(String value);

  /// No description provided for @widgets_song_selected.
  ///
  /// In zh, this message translates to:
  /// **'已选择'**
  String get widgets_song_selected;

  /// 歌曲行更多操作按钮的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{title}，更多操作'**
  String widgets_song_more_semantics(String title);

  /// 取消选择某首歌曲的操作标签
  ///
  /// In zh, this message translates to:
  /// **'取消选择 {title}'**
  String widgets_song_deselect(String title);

  /// 选择某首歌曲的操作标签
  ///
  /// In zh, this message translates to:
  /// **'选择 {title}'**
  String widgets_song_select(String title);

  /// No description provided for @widgets_song_favorite.
  ///
  /// In zh, this message translates to:
  /// **'已收藏'**
  String get widgets_song_favorite;

  /// No description provided for @widgets_song_preview.
  ///
  /// In zh, this message translates to:
  /// **'试听'**
  String get widgets_song_preview;

  /// 歌曲封面的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{title} 封面'**
  String widgets_song_cover_semantics(String title);

  /// No description provided for @widgets_song_now_playing.
  ///
  /// In zh, this message translates to:
  /// **'正在播放'**
  String get widgets_song_now_playing;

  /// No description provided for @widgets_window_minimize.
  ///
  /// In zh, this message translates to:
  /// **'最小化'**
  String get widgets_window_minimize;

  /// No description provided for @widgets_window_maximize_restore.
  ///
  /// In zh, this message translates to:
  /// **'最大化/还原'**
  String get widgets_window_maximize_restore;

  /// No description provided for @widgets_window_close.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get widgets_window_close;

  /// No description provided for @widgets_drawer_frame_semantics.
  ///
  /// In zh, this message translates to:
  /// **'应用菜单'**
  String get widgets_drawer_frame_semantics;

  /// 抽屉身份头部（账户/音乐库/线路状态）的语义标签
  ///
  /// In zh, this message translates to:
  /// **'当前账户 {username}，音乐库 {libraryName}，{status}，{address}'**
  String widgets_drawer_identity_semantics(
    String username,
    String libraryName,
    String status,
    String address,
  );

  /// No description provided for @widgets_drawer_back_app_menu.
  ///
  /// In zh, this message translates to:
  /// **'返回应用功能菜单'**
  String get widgets_drawer_back_app_menu;

  /// No description provided for @widgets_drawer_view_libraries.
  ///
  /// In zh, this message translates to:
  /// **'查看音乐库'**
  String get widgets_drawer_view_libraries;

  /// No description provided for @widgets_drawer_current_library.
  ///
  /// In zh, this message translates to:
  /// **'当前音乐库'**
  String get widgets_drawer_current_library;

  /// 编辑某个音乐库的操作标签
  ///
  /// In zh, this message translates to:
  /// **'编辑 {title}'**
  String widgets_drawer_edit_library(String title);

  /// No description provided for @widgets_network_cannot_reach_server.
  ///
  /// In zh, this message translates to:
  /// **'连接不到服务器'**
  String get widgets_network_cannot_reach_server;

  /// No description provided for @widgets_network_recovered.
  ///
  /// In zh, this message translates to:
  /// **'网络已恢复'**
  String get widgets_network_recovered;

  /// No description provided for @widgets_network_weak_title.
  ///
  /// In zh, this message translates to:
  /// **'网络不稳定'**
  String get widgets_network_weak_title;

  /// No description provided for @widgets_network_weak_desc.
  ///
  /// In zh, this message translates to:
  /// **'正在重试可用线路，已加载内容和离线歌曲仍可使用'**
  String get widgets_network_weak_desc;

  /// No description provided for @widgets_network_offline_title.
  ///
  /// In zh, this message translates to:
  /// **'当前离线'**
  String get widgets_network_offline_title;

  /// No description provided for @widgets_network_offline_desc.
  ///
  /// In zh, this message translates to:
  /// **'已加载内容和离线歌曲仍可使用，在线操作将在联网后恢复'**
  String get widgets_network_offline_desc;

  /// No description provided for @widgets_nav_main.
  ///
  /// In zh, this message translates to:
  /// **'主导航'**
  String get widgets_nav_main;

  /// No description provided for @widgets_nav_main_collapsed.
  ///
  /// In zh, this message translates to:
  /// **'主导航（已收起）'**
  String get widgets_nav_main_collapsed;

  /// No description provided for @widgets_nav_expand_sidebar.
  ///
  /// In zh, this message translates to:
  /// **'展开侧边栏'**
  String get widgets_nav_expand_sidebar;

  /// No description provided for @widgets_nav_collapse_sidebar.
  ///
  /// In zh, this message translates to:
  /// **'收起侧边栏'**
  String get widgets_nav_collapse_sidebar;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
