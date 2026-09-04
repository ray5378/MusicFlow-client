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

  /// No description provided for @settings_about.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get settings_about;

  /// No description provided for @settings_about_desc.
  ///
  /// In zh, this message translates to:
  /// **'MusicFlow · 基于 Subsonic API'**
  String get settings_about_desc;

  /// No description provided for @settings_about_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'基于 Subsonic API 的音乐客户端。'**
  String get settings_about_subtitle;

  /// No description provided for @settings_about_title.
  ///
  /// In zh, this message translates to:
  /// **'关于 MusicFlow'**
  String get settings_about_title;

  /// No description provided for @settings_api_key.
  ///
  /// In zh, this message translates to:
  /// **'API Key'**
  String get settings_api_key;

  /// No description provided for @settings_api_key_helper.
  ///
  /// In zh, this message translates to:
  /// **'选择“清空”会移除本机保存的 Key。'**
  String get settings_api_key_helper;

  /// No description provided for @settings_api_key_hint.
  ///
  /// In zh, this message translates to:
  /// **'输入 Fanart.tv API Key'**
  String get settings_api_key_hint;

  /// No description provided for @settings_audio_auto_switch.
  ///
  /// In zh, this message translates to:
  /// **'按网络自动切换'**
  String get settings_audio_auto_switch;

  /// No description provided for @settings_audio_auto_switch_off_desc.
  ///
  /// In zh, this message translates to:
  /// **'所有网络都使用同一音质。'**
  String get settings_audio_auto_switch_off_desc;

  /// No description provided for @settings_audio_auto_switch_on_desc.
  ///
  /// In zh, this message translates to:
  /// **'Wi-Fi 与移动数据分别保存音质。'**
  String get settings_audio_auto_switch_on_desc;

  /// No description provided for @settings_audio_current_strategy.
  ///
  /// In zh, this message translates to:
  /// **'当前播放策略'**
  String get settings_audio_current_strategy;

  /// No description provided for @settings_audio_desc_data_saver.
  ///
  /// In zh, this message translates to:
  /// **'减少流量消耗，适合信号波动时使用'**
  String get settings_audio_desc_data_saver;

  /// No description provided for @settings_audio_desc_high.
  ///
  /// In zh, this message translates to:
  /// **'高保真听感，适合稳定网络'**
  String get settings_audio_desc_high;

  /// No description provided for @settings_audio_desc_original.
  ///
  /// In zh, this message translates to:
  /// **'不限制码率，直接播放服务器原始文件'**
  String get settings_audio_desc_original;

  /// No description provided for @settings_audio_desc_standard.
  ///
  /// In zh, this message translates to:
  /// **'兼顾听感、启动速度与流量'**
  String get settings_audio_desc_standard;

  /// No description provided for @settings_audio_effective_quality.
  ///
  /// In zh, this message translates to:
  /// **'生效音质'**
  String get settings_audio_effective_quality;

  /// No description provided for @settings_audio_global_section.
  ///
  /// In zh, this message translates to:
  /// **'全局音质'**
  String get settings_audio_global_section;

  /// No description provided for @settings_audio_global_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'此选择将用于所有网络。'**
  String get settings_audio_global_section_desc;

  /// No description provided for @settings_audio_mobile_section.
  ///
  /// In zh, this message translates to:
  /// **'移动数据音质'**
  String get settings_audio_mobile_section;

  /// No description provided for @settings_audio_mobile_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'在流量消耗、启动速度与听感之间选择。'**
  String get settings_audio_mobile_section_desc;

  /// No description provided for @settings_audio_network.
  ///
  /// In zh, this message translates to:
  /// **'网络'**
  String get settings_audio_network;

  /// No description provided for @settings_audio_network_mobile.
  ///
  /// In zh, this message translates to:
  /// **'移动数据'**
  String get settings_audio_network_mobile;

  /// No description provided for @settings_audio_network_none.
  ///
  /// In zh, this message translates to:
  /// **'无网络'**
  String get settings_audio_network_none;

  /// No description provided for @settings_audio_network_strategy.
  ///
  /// In zh, this message translates to:
  /// **'网络策略'**
  String get settings_audio_network_strategy;

  /// No description provided for @settings_audio_network_strategy_desc.
  ///
  /// In zh, this message translates to:
  /// **'在 Wi-Fi 与移动数据之间自动使用不同码率。'**
  String get settings_audio_network_strategy_desc;

  /// No description provided for @settings_audio_network_wifi.
  ///
  /// In zh, this message translates to:
  /// **'Wi-Fi'**
  String get settings_audio_network_wifi;

  /// No description provided for @settings_audio_quality.
  ///
  /// In zh, this message translates to:
  /// **'音质设置'**
  String get settings_audio_quality;

  /// No description provided for @settings_audio_quality_desc.
  ///
  /// In zh, this message translates to:
  /// **'按网络选择播放码率'**
  String get settings_audio_quality_desc;

  /// 音质页状态行（标签与值）的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{label}，{value}'**
  String settings_audio_status_line(String label, String value);

  /// No description provided for @settings_audio_wifi_section.
  ///
  /// In zh, this message translates to:
  /// **'Wi-Fi 音质'**
  String get settings_audio_wifi_section;

  /// No description provided for @settings_audio_wifi_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'连接 Wi-Fi 时优先保证音乐完整度。'**
  String get settings_audio_wifi_section_desc;

  /// No description provided for @settings_autoplay.
  ///
  /// In zh, this message translates to:
  /// **'打开时自动播放'**
  String get settings_autoplay;

  /// No description provided for @settings_autoplay_desc.
  ///
  /// In zh, this message translates to:
  /// **'启动后恢复上次本机播放队列与进度，并自动续播。'**
  String get settings_autoplay_desc;

  /// No description provided for @settings_auth_password.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get settings_auth_password;

  /// No description provided for @settings_auth_type.
  ///
  /// In zh, this message translates to:
  /// **'认证方式'**
  String get settings_auth_type;

  /// No description provided for @settings_cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get settings_cancel;

  /// No description provided for @settings_check_update.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get settings_check_update;

  /// No description provided for @settings_check_update_checking_semantics.
  ///
  /// In zh, this message translates to:
  /// **'检查更新，正在连接 GitHub Releases'**
  String get settings_check_update_checking_semantics;

  /// No description provided for @settings_check_update_desc.
  ///
  /// In zh, this message translates to:
  /// **'从 GitHub Releases 检查最新版本'**
  String get settings_check_update_desc;

  /// No description provided for @settings_clear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get settings_clear;

  /// No description provided for @settings_configure.
  ///
  /// In zh, this message translates to:
  /// **'配置'**
  String get settings_configure;

  /// No description provided for @settings_configure_fanart.
  ///
  /// In zh, this message translates to:
  /// **'配置 Fanart.tv'**
  String get settings_configure_fanart;

  /// No description provided for @settings_configure_fanart_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'Fanart.tv 高清封面需要单独的 API Key。'**
  String get settings_configure_fanart_subtitle;

  /// No description provided for @settings_crossfade.
  ///
  /// In zh, this message translates to:
  /// **'切歌淡入淡出'**
  String get settings_crossfade;

  /// No description provided for @settings_crossfade_desc.
  ///
  /// In zh, this message translates to:
  /// **'设置相邻曲目之间的交叉衰减时长。'**
  String get settings_crossfade_desc;

  /// No description provided for @settings_crossfade_off.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get settings_crossfade_off;

  /// No description provided for @settings_crossfade_off_value.
  ///
  /// In zh, this message translates to:
  /// **'关闭交叉衰减'**
  String get settings_crossfade_off_value;

  /// 交叉衰减时长数值标签（秒）
  ///
  /// In zh, this message translates to:
  /// **'{seconds} 秒'**
  String settings_crossfade_seconds(String seconds);

  /// 带时长的交叉衰减选项描述
  ///
  /// In zh, this message translates to:
  /// **'用 {label} 平滑衔接相邻曲目'**
  String settings_crossfade_smooth(String label);

  /// No description provided for @settings_crossfade_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'选择相邻曲目同时播放的交叉衰减时长。'**
  String get settings_crossfade_subtitle;

  /// No description provided for @settings_cover_api_key_configured.
  ///
  /// In zh, this message translates to:
  /// **'API Key：已配置'**
  String get settings_cover_api_key_configured;

  /// No description provided for @settings_cover_api_key_unconfigured.
  ///
  /// In zh, this message translates to:
  /// **'API Key：未配置'**
  String get settings_cover_api_key_unconfigured;

  /// No description provided for @settings_cover_priority_desc.
  ///
  /// In zh, this message translates to:
  /// **'查找封面时会从上到下依次尝试。按住拖动图标可调整顺序。'**
  String get settings_cover_priority_desc;

  /// No description provided for @settings_cover_provider.
  ///
  /// In zh, this message translates to:
  /// **'封面提供商'**
  String get settings_cover_provider;

  /// No description provided for @settings_cover_provider_custom_desc.
  ///
  /// In zh, this message translates to:
  /// **'自定义 API 地址'**
  String get settings_cover_provider_custom_desc;

  /// No description provided for @settings_cover_provider_desc.
  ///
  /// In zh, this message translates to:
  /// **'调整获取顺序并配置 Fanart.tv'**
  String get settings_cover_provider_desc;

  /// No description provided for @settings_cover_provider_empty_desc.
  ///
  /// In zh, this message translates to:
  /// **'提供商配置为空，请稍后重试或检查应用数据。'**
  String get settings_cover_provider_empty_desc;

  /// No description provided for @settings_cover_provider_empty_title.
  ///
  /// In zh, this message translates to:
  /// **'没有可用的封面提供商'**
  String get settings_cover_provider_empty_title;

  /// No description provided for @settings_cover_provider_fanart_desc.
  ///
  /// In zh, this message translates to:
  /// **'Fanart.tv 高清封面（需要 API Key）'**
  String get settings_cover_provider_fanart_desc;

  /// No description provided for @settings_cover_provider_musicbrainz_desc.
  ///
  /// In zh, this message translates to:
  /// **'MusicBrainz Cover Art Archive'**
  String get settings_cover_provider_musicbrainz_desc;

  /// 封面提供商列表加载失败的描述（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'提供商顺序、启用状态和配置暂时不可用。\n{error}'**
  String settings_cover_provider_page_error_desc(String error);

  /// No description provided for @settings_cover_provider_page_error_title.
  ///
  /// In zh, this message translates to:
  /// **'无法读取封面提供商'**
  String get settings_cover_provider_page_error_title;

  /// No description provided for @settings_cover_provider_subsonic_desc.
  ///
  /// In zh, this message translates to:
  /// **'Subsonic 服务端封面'**
  String get settings_cover_provider_subsonic_desc;

  /// No description provided for @settings_current_connection.
  ///
  /// In zh, this message translates to:
  /// **'当前连接'**
  String get settings_current_connection;

  /// No description provided for @settings_current_version.
  ///
  /// In zh, this message translates to:
  /// **'当前版本'**
  String get settings_current_version;

  /// No description provided for @settings_desktop_lyrics.
  ///
  /// In zh, this message translates to:
  /// **'桌面歌词'**
  String get settings_desktop_lyrics;

  /// No description provided for @settings_desktop_lyrics_desc.
  ///
  /// In zh, this message translates to:
  /// **'开启后，桌面显示可拖动的歌词浮窗(置顶、不抢焦点)。'**
  String get settings_desktop_lyrics_desc;

  /// No description provided for @settings_diagnostics_section.
  ///
  /// In zh, this message translates to:
  /// **'诊断与更新'**
  String get settings_diagnostics_section;

  /// No description provided for @settings_diagnostics_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'查看本机诊断日志，或检查 GitHub Releases。'**
  String get settings_diagnostics_section_desc;

  /// No description provided for @settings_disable.
  ///
  /// In zh, this message translates to:
  /// **'停用'**
  String get settings_disable;

  /// No description provided for @settings_download.
  ///
  /// In zh, this message translates to:
  /// **'前往下载'**
  String get settings_download;

  /// No description provided for @settings_download_confirm_body.
  ///
  /// In zh, this message translates to:
  /// **'将跳转到浏览器开始下载。下载完成后请自行完成更新安装：Windows 请解压 zip 覆盖到安装目录，Android 请安装下载的 apk。'**
  String get settings_download_confirm_body;

  /// 歌词跟随停靠时长数值标签（秒）
  ///
  /// In zh, this message translates to:
  /// **'{seconds} 秒'**
  String settings_dwell_seconds(String seconds);

  /// No description provided for @settings_edit_library.
  ///
  /// In zh, this message translates to:
  /// **'编辑当前音乐库'**
  String get settings_edit_library;

  /// No description provided for @settings_edit_library_desc.
  ///
  /// In zh, this message translates to:
  /// **'管理服务器地址、认证方式与音乐库能力。'**
  String get settings_edit_library_desc;

  /// No description provided for @settings_edit_library_empty_desc.
  ///
  /// In zh, this message translates to:
  /// **'选择音乐库后可编辑服务器与认证信息。'**
  String get settings_edit_library_empty_desc;

  /// No description provided for @settings_enable.
  ///
  /// In zh, this message translates to:
  /// **'启用'**
  String get settings_enable;

  /// 信息行（标签与值）的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{label}，{value}'**
  String settings_info_line_semantics(String label, String value);

  /// No description provided for @settings_later.
  ///
  /// In zh, this message translates to:
  /// **'稍后再说'**
  String get settings_later;

  /// No description provided for @settings_latest_version.
  ///
  /// In zh, this message translates to:
  /// **'最新版本'**
  String get settings_latest_version;

  /// 已保存的音乐库数量描述
  ///
  /// In zh, this message translates to:
  /// **'已保存 {count} 个音乐库'**
  String settings_library_count_saved(int count);

  /// No description provided for @settings_library_empty.
  ///
  /// In zh, this message translates to:
  /// **'当前没有可切换的音乐库'**
  String get settings_library_empty;

  /// No description provided for @settings_library_label.
  ///
  /// In zh, this message translates to:
  /// **'音乐库'**
  String get settings_library_label;

  /// No description provided for @settings_library_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'音乐库列表读取失败，点击重试'**
  String get settings_library_load_failed;

  /// No description provided for @settings_library_loading.
  ///
  /// In zh, this message translates to:
  /// **'正在读取音乐库列表'**
  String get settings_library_loading;

  /// No description provided for @settings_library_section.
  ///
  /// In zh, this message translates to:
  /// **'音乐库与服务器'**
  String get settings_library_section;

  /// No description provided for @settings_library_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'查看当前连接，也可以切换或编辑已经保存的音乐库。'**
  String get settings_library_section_desc;

  /// No description provided for @settings_library_single.
  ///
  /// In zh, this message translates to:
  /// **'当前仅有一个音乐库'**
  String get settings_library_single;

  /// 切换音乐库失败的提示（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'切换音乐库失败: {error}'**
  String settings_library_switch_failed(String error);

  /// No description provided for @settings_library_switch_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'选择后会刷新当前音乐库的内容与播放状态。'**
  String get settings_library_switch_subtitle;

  /// 成功切换到某音乐库的提示（含库名）
  ///
  /// In zh, this message translates to:
  /// **'已切换到“{name}”'**
  String settings_library_switched(String name);

  /// No description provided for @settings_log_auto_refresh.
  ///
  /// In zh, this message translates to:
  /// **'自动刷新'**
  String get settings_log_auto_refresh;

  /// No description provided for @settings_log_clear_cache.
  ///
  /// In zh, this message translates to:
  /// **'清空缓存'**
  String get settings_log_clear_cache;

  /// No description provided for @settings_log_copy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get settings_log_copy;

  /// 复制日志成功提示（含行数）
  ///
  /// In zh, this message translates to:
  /// **'已复制 {count} 行日志'**
  String settings_log_copied(int count);

  /// No description provided for @settings_log_diagnostics.
  ///
  /// In zh, this message translates to:
  /// **'诊断日志'**
  String get settings_log_diagnostics;

  /// No description provided for @settings_log_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无日志'**
  String get settings_log_empty;

  /// No description provided for @settings_log_filter_hint.
  ///
  /// In zh, this message translates to:
  /// **'筛选关键字，如 DLNA-AUTO / SSDP / 触发续播'**
  String get settings_log_filter_hint;

  /// No description provided for @settings_log_no_content.
  ///
  /// In zh, this message translates to:
  /// **'当前没有可复制的日志'**
  String get settings_log_no_content;

  /// No description provided for @settings_log_status_live.
  ///
  /// In zh, this message translates to:
  /// **'实时刷新中'**
  String get settings_log_status_live;

  /// No description provided for @settings_log_status_paused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get settings_log_status_paused;

  /// 日志窗口的统计信息（总数、显示数、刷新状态）
  ///
  /// In zh, this message translates to:
  /// **'共 {total} 行｜显示 {shown} 行（{status}）'**
  String settings_log_summary(int total, int shown, String status);

  /// No description provided for @settings_logging.
  ///
  /// In zh, this message translates to:
  /// **'记录日志'**
  String get settings_logging;

  /// No description provided for @settings_logging_desc.
  ///
  /// In zh, this message translates to:
  /// **'默认关闭不抓取任何日志；开启后记录全部日志（最多 5000 条）。'**
  String get settings_logging_desc;

  /// No description provided for @settings_lyrics_dwell.
  ///
  /// In zh, this message translates to:
  /// **'歌词跟随停靠时长'**
  String get settings_lyrics_dwell;

  /// No description provided for @settings_lyrics_dwell_default.
  ///
  /// In zh, this message translates to:
  /// **'默认：停下 3 秒后恢复跟随'**
  String get settings_lyrics_dwell_default;

  /// No description provided for @settings_lyrics_dwell_desc.
  ///
  /// In zh, this message translates to:
  /// **'手动滚动歌词后，过多久恢复自动跟随当前歌词。'**
  String get settings_lyrics_dwell_desc;

  /// 指定时长后恢复跟随的选项描述
  ///
  /// In zh, this message translates to:
  /// **'停下 {duration} 后恢复跟随'**
  String settings_lyrics_dwell_resume(String duration);

  /// No description provided for @settings_lyrics_dwell_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'手动滚动并停下后，等待该时长再恢复「跟随当前歌词」自动滚动。'**
  String get settings_lyrics_dwell_subtitle;

  /// No description provided for @settings_lyrics_priority_desc.
  ///
  /// In zh, this message translates to:
  /// **'播放时会从上到下依次尝试。按住拖动图标可调整顺序。'**
  String get settings_lyrics_priority_desc;

  /// No description provided for @settings_lyrics_provider.
  ///
  /// In zh, this message translates to:
  /// **'歌词提供商'**
  String get settings_lyrics_provider;

  /// No description provided for @settings_lyrics_provider_custom_desc.
  ///
  /// In zh, this message translates to:
  /// **'自定义 API 地址'**
  String get settings_lyrics_provider_custom_desc;

  /// No description provided for @settings_lyrics_provider_desc.
  ///
  /// In zh, this message translates to:
  /// **'调整获取顺序与启用状态'**
  String get settings_lyrics_provider_desc;

  /// No description provided for @settings_lyrics_provider_empty_desc.
  ///
  /// In zh, this message translates to:
  /// **'提供商配置为空，请稍后重试或检查应用数据。'**
  String get settings_lyrics_provider_empty_desc;

  /// No description provided for @settings_lyrics_provider_empty_title.
  ///
  /// In zh, this message translates to:
  /// **'没有可用的歌词提供商'**
  String get settings_lyrics_provider_empty_title;

  /// No description provided for @settings_lyrics_provider_lrclib_desc.
  ///
  /// In zh, this message translates to:
  /// **'公共同步歌词 API'**
  String get settings_lyrics_provider_lrclib_desc;

  /// No description provided for @settings_lyrics_provider_netease_desc.
  ///
  /// In zh, this message translates to:
  /// **'网易云音乐歌词'**
  String get settings_lyrics_provider_netease_desc;

  /// 歌词提供商列表加载失败的描述（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'提供商顺序和启用状态暂时不可用。\n{error}'**
  String settings_lyrics_provider_page_error_desc(String error);

  /// No description provided for @settings_lyrics_provider_page_error_title.
  ///
  /// In zh, this message translates to:
  /// **'无法读取歌词提供商'**
  String get settings_lyrics_provider_page_error_title;

  /// No description provided for @settings_lyrics_provider_subsonic_desc.
  ///
  /// In zh, this message translates to:
  /// **'OpenSubsonic / Subsonic 内嵌歌词'**
  String get settings_lyrics_provider_subsonic_desc;

  /// No description provided for @settings_not_connected.
  ///
  /// In zh, this message translates to:
  /// **'未连接'**
  String get settings_not_connected;

  /// No description provided for @settings_not_selected.
  ///
  /// In zh, this message translates to:
  /// **'未选择'**
  String get settings_not_selected;

  /// No description provided for @settings_not_set.
  ///
  /// In zh, this message translates to:
  /// **'未设置'**
  String get settings_not_set;

  /// No description provided for @settings_playback_section.
  ///
  /// In zh, this message translates to:
  /// **'播放与外观'**
  String get settings_playback_section;

  /// No description provided for @settings_playback_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'这些选择会立即应用到当前设备。'**
  String get settings_playback_section_desc;

  /// No description provided for @settings_priority_order.
  ///
  /// In zh, this message translates to:
  /// **'优先顺序'**
  String get settings_priority_order;

  /// No description provided for @settings_project_home.
  ///
  /// In zh, this message translates to:
  /// **'项目主页'**
  String get settings_project_home;

  /// No description provided for @settings_provider_custom.
  ///
  /// In zh, this message translates to:
  /// **'自定义源'**
  String get settings_provider_custom;

  /// 提供商列表拖动排序手柄的语义标签（含名称）
  ///
  /// In zh, this message translates to:
  /// **'按住并拖动{title}，调整优先顺序'**
  String settings_provider_drag_semantics(String title);

  /// No description provided for @settings_provider_fanart.
  ///
  /// In zh, this message translates to:
  /// **'Fanart.tv'**
  String get settings_provider_fanart;

  /// No description provided for @settings_provider_lrclib.
  ///
  /// In zh, this message translates to:
  /// **'LRCLIB'**
  String get settings_provider_lrclib;

  /// No description provided for @settings_provider_musicbrainz.
  ///
  /// In zh, this message translates to:
  /// **'MusicBrainz'**
  String get settings_provider_musicbrainz;

  /// No description provided for @settings_provider_netease.
  ///
  /// In zh, this message translates to:
  /// **'网易云音乐'**
  String get settings_provider_netease;

  /// No description provided for @settings_provider_subsonic.
  ///
  /// In zh, this message translates to:
  /// **'服务端'**
  String get settings_provider_subsonic;

  /// 提供商开关的语义标签（启用/停用动作加名称）
  ///
  /// In zh, this message translates to:
  /// **'{action}{title}'**
  String settings_provider_toggle_semantics(String action, String title);

  /// No description provided for @settings_route_auto_fallback.
  ///
  /// In zh, this message translates to:
  /// **'线路自动回退'**
  String get settings_route_auto_fallback;

  /// No description provided for @settings_route_auto_fallback_desc.
  ///
  /// In zh, this message translates to:
  /// **'手动线路不可用时，自动切换到其他可用线路。'**
  String get settings_route_auto_fallback_desc;

  /// No description provided for @settings_save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get settings_save;

  /// No description provided for @settings_selected.
  ///
  /// In zh, this message translates to:
  /// **'已选择'**
  String get settings_selected;

  /// No description provided for @settings_server_address.
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get settings_server_address;

  /// No description provided for @settings_server_unconfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置服务器地址'**
  String get settings_server_unconfigured;

  /// No description provided for @settings_status_disabled.
  ///
  /// In zh, this message translates to:
  /// **'已停用'**
  String get settings_status_disabled;

  /// No description provided for @settings_status_enabled.
  ///
  /// In zh, this message translates to:
  /// **'已启用'**
  String get settings_status_enabled;

  /// No description provided for @settings_switch_library.
  ///
  /// In zh, this message translates to:
  /// **'切换音乐库'**
  String get settings_switch_library;

  /// No description provided for @settings_theme.
  ///
  /// In zh, this message translates to:
  /// **'主题设置'**
  String get settings_theme;

  /// No description provided for @settings_theme_accent.
  ///
  /// In zh, this message translates to:
  /// **'强调色'**
  String get settings_theme_accent;

  /// No description provided for @settings_theme_accent_desc.
  ///
  /// In zh, this message translates to:
  /// **'只用于主要操作、当前选择与键盘焦点。专辑颜色不会扩散到普通页面。'**
  String get settings_theme_accent_desc;

  /// No description provided for @settings_theme_apply.
  ///
  /// In zh, this message translates to:
  /// **'应用'**
  String get settings_theme_apply;

  /// No description provided for @settings_theme_appearance.
  ///
  /// In zh, this message translates to:
  /// **'外观模式'**
  String get settings_theme_appearance;

  /// No description provided for @settings_theme_appearance_desc.
  ///
  /// In zh, this message translates to:
  /// **'跟随设备，或固定使用浅色与深色界面。'**
  String get settings_theme_appearance_desc;

  /// No description provided for @settings_theme_brightness.
  ///
  /// In zh, this message translates to:
  /// **'明度'**
  String get settings_theme_brightness;

  /// 预设主题色按钮的语义标签（含色值）
  ///
  /// In zh, this message translates to:
  /// **'强调色 {hex}'**
  String settings_theme_color(String hex);

  /// No description provided for @settings_theme_color_picker_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'系统会在保存时校准对比度和色度。'**
  String get settings_theme_color_picker_subtitle;

  /// No description provided for @settings_theme_color_picker_title.
  ///
  /// In zh, this message translates to:
  /// **'调整强调色'**
  String get settings_theme_color_picker_title;

  /// 已选中的预设主题色按钮语义标签（含色值）
  ///
  /// In zh, this message translates to:
  /// **'强调色 {hex}，已选择'**
  String settings_theme_color_selected(String hex);

  /// No description provided for @settings_theme_current_accent.
  ///
  /// In zh, this message translates to:
  /// **'当前强调色'**
  String get settings_theme_current_accent;

  /// No description provided for @settings_theme_dark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get settings_theme_dark;

  /// No description provided for @settings_theme_dark_desc.
  ///
  /// In zh, this message translates to:
  /// **'使用低亮度的夜间试听空间'**
  String get settings_theme_dark_desc;

  /// No description provided for @settings_theme_desc.
  ///
  /// In zh, this message translates to:
  /// **'明暗模式与主题色'**
  String get settings_theme_desc;

  /// No description provided for @settings_theme_fine_tune.
  ///
  /// In zh, this message translates to:
  /// **'精细调整'**
  String get settings_theme_fine_tune;

  /// No description provided for @settings_theme_follow_system.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settings_theme_follow_system;

  /// No description provided for @settings_theme_follow_system_desc.
  ///
  /// In zh, this message translates to:
  /// **'自动匹配设备的外观设置'**
  String get settings_theme_follow_system_desc;

  /// No description provided for @settings_theme_hue.
  ///
  /// In zh, this message translates to:
  /// **'色相'**
  String get settings_theme_hue;

  /// No description provided for @settings_theme_light.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get settings_theme_light;

  /// No description provided for @settings_theme_light_desc.
  ///
  /// In zh, this message translates to:
  /// **'使用明亮、中性的试听空间'**
  String get settings_theme_light_desc;

  /// No description provided for @settings_theme_mode_dark.
  ///
  /// In zh, this message translates to:
  /// **'黑色'**
  String get settings_theme_mode_dark;

  /// No description provided for @settings_theme_mode_light.
  ///
  /// In zh, this message translates to:
  /// **'白色'**
  String get settings_theme_mode_light;

  /// No description provided for @settings_theme_mode_system.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settings_theme_mode_system;

  /// No description provided for @settings_theme_reset_default.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认主题'**
  String get settings_theme_reset_default;

  /// No description provided for @settings_theme_saturation.
  ///
  /// In zh, this message translates to:
  /// **'饱和度'**
  String get settings_theme_saturation;

  /// No description provided for @settings_title.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settings_title;

  /// No description provided for @settings_toggle_disabled.
  ///
  /// In zh, this message translates to:
  /// **'已关闭'**
  String get settings_toggle_disabled;

  /// No description provided for @settings_toggle_enabled.
  ///
  /// In zh, this message translates to:
  /// **'已开启'**
  String get settings_toggle_enabled;

  /// 带描述的开关行的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{title}，{state}，{description}'**
  String settings_toggle_semantics(
    String title,
    String state,
    String description,
  );

  /// 无描述的开关行的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{title}，{state}'**
  String settings_toggle_semantics_no_desc(String title, String state);

  /// No description provided for @settings_update_assets.
  ///
  /// In zh, this message translates to:
  /// **'下载文件'**
  String get settings_update_assets;

  /// No description provided for @settings_update_assets_desc.
  ///
  /// In zh, this message translates to:
  /// **'选择适合当前设备的安装文件。'**
  String get settings_update_assets_desc;

  /// 检查更新失败的提示（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'检查更新失败: {error}'**
  String settings_update_check_failed(String error);

  /// No description provided for @settings_update_found.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本'**
  String get settings_update_found;

  /// 发现新版本对话框标题（含最新版本号）
  ///
  /// In zh, this message translates to:
  /// **'发现新版本 {version}'**
  String settings_update_found_version(String version);

  /// 已是最新版本的提示（含当前版本号）
  ///
  /// In zh, this message translates to:
  /// **'当前已是最新版本 ({version})'**
  String settings_update_latest(String version);

  /// No description provided for @settings_update_notes.
  ///
  /// In zh, this message translates to:
  /// **'更新说明'**
  String get settings_update_notes;

  /// 更新安装包下载项名称（含版本号）
  ///
  /// In zh, this message translates to:
  /// **'更新包 {version}'**
  String settings_update_package(String version);

  /// No description provided for @settings_username.
  ///
  /// In zh, this message translates to:
  /// **'用户名'**
  String get settings_username;

  /// No description provided for @settings_view_logs.
  ///
  /// In zh, this message translates to:
  /// **'查看日志'**
  String get settings_view_logs;

  /// No description provided for @settings_view_logs_desc.
  ///
  /// In zh, this message translates to:
  /// **'应用内直接查看并复制诊断日志（可筛选 DLNA）'**
  String get settings_view_logs_desc;

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

  /// No description provided for @discover_category_nav.
  ///
  /// In zh, this message translates to:
  /// **'分类导航'**
  String get discover_category_nav;

  /// 媒体封面图片的语义标签（含名称）
  ///
  /// In zh, this message translates to:
  /// **'{name} 封面'**
  String discover_cover_semantics(String name);

  /// No description provided for @discover_error_desc_check_route.
  ///
  /// In zh, this message translates to:
  /// **'请检查网络或当前线路，然后重试。'**
  String get discover_error_desc_check_route;

  /// No description provided for @discover_error_desc_switch_route.
  ///
  /// In zh, this message translates to:
  /// **'请检查网络或切换线路后重试。'**
  String get discover_error_desc_switch_route;

  /// No description provided for @discover_explore.
  ///
  /// In zh, this message translates to:
  /// **'探索'**
  String get discover_explore;

  /// No description provided for @discover_for_you.
  ///
  /// In zh, this message translates to:
  /// **'为你推荐'**
  String get discover_for_you;

  /// No description provided for @discover_import_no_valid_id.
  ///
  /// In zh, this message translates to:
  /// **'歌单导入后未返回有效 id'**
  String get discover_import_no_valid_id;

  /// 导入推荐歌单失败的提示（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'导入歌单失败：{msg}'**
  String discover_import_playlist_failed(String msg);

  /// No description provided for @discover_local_random.
  ///
  /// In zh, this message translates to:
  /// **'本地随机'**
  String get discover_local_random;

  /// No description provided for @discover_local_random_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'本地随机加载失败'**
  String get discover_local_random_load_failed;

  /// No description provided for @discover_music_suffix.
  ///
  /// In zh, this message translates to:
  /// **'音乐'**
  String get discover_music_suffix;

  /// No description provided for @discover_network_failed_play_playlist.
  ///
  /// In zh, this message translates to:
  /// **'网络异常，无法播放歌单'**
  String get discover_network_failed_play_playlist;

  /// No description provided for @discover_no_library_selected.
  ///
  /// In zh, this message translates to:
  /// **'未选择音乐库'**
  String get discover_no_library_selected;

  /// No description provided for @discover_not_connected_library.
  ///
  /// In zh, this message translates to:
  /// **'未连接到音乐库'**
  String get discover_not_connected_library;

  /// No description provided for @discover_open_app_menu.
  ///
  /// In zh, this message translates to:
  /// **'打开应用菜单'**
  String get discover_open_app_menu;

  /// No description provided for @discover_platform_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'平台推荐加载失败'**
  String get discover_platform_load_failed;

  /// No description provided for @discover_platform_recommend.
  ///
  /// In zh, this message translates to:
  /// **'平台推荐'**
  String get discover_platform_recommend;

  /// No description provided for @discover_play_playlist.
  ///
  /// In zh, this message translates to:
  /// **'播放歌单'**
  String get discover_play_playlist;

  /// 播放歌单失败的提示（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'播放歌单失败：{msg}'**
  String discover_play_playlist_failed(String msg);

  /// No description provided for @discover_play_random_songs.
  ///
  /// In zh, this message translates to:
  /// **'播放随机歌曲'**
  String get discover_play_random_songs;

  /// No description provided for @discover_playlist_empty.
  ///
  /// In zh, this message translates to:
  /// **'歌单暂无可用歌曲'**
  String get discover_playlist_empty;

  /// No description provided for @discover_random_songs.
  ///
  /// In zh, this message translates to:
  /// **'随机歌曲'**
  String get discover_random_songs;

  /// 最近播放专辑卡片的语义标签（含专辑名）
  ///
  /// In zh, this message translates to:
  /// **'最近播放专辑 {name}'**
  String discover_recent_album_semantics(String name);

  /// No description provided for @discover_recent_playlists.
  ///
  /// In zh, this message translates to:
  /// **'最近更新的歌单'**
  String get discover_recent_playlists;

  /// No description provided for @discover_recent_playlists_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'最近更新歌单加载失败'**
  String get discover_recent_playlists_load_failed;

  /// 最近播放专辑卡片的歌曲数描述
  ///
  /// In zh, this message translates to:
  /// **'{count} 首歌曲'**
  String discover_recent_song_count(String count);

  /// No description provided for @discover_recently_played.
  ///
  /// In zh, this message translates to:
  /// **'最近听过'**
  String get discover_recently_played;

  /// No description provided for @discover_recommend_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'为你推荐加载失败'**
  String get discover_recommend_load_failed;

  /// No description provided for @discover_recommend_service_unavailable.
  ///
  /// In zh, this message translates to:
  /// **'推荐服务暂不可用，请检查平台推荐插件是否已启用'**
  String get discover_recommend_service_unavailable;

  /// No description provided for @discover_refresh_recent_playlists.
  ///
  /// In zh, this message translates to:
  /// **'刷新最近更新歌单'**
  String get discover_refresh_recent_playlists;

  /// No description provided for @discover_search.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get discover_search;

  /// No description provided for @discover_section_unavailable_playlist.
  ///
  /// In zh, this message translates to:
  /// **'歌单暂时不可用'**
  String get discover_section_unavailable_playlist;

  /// No description provided for @discover_shuffle_song_label.
  ///
  /// In zh, this message translates to:
  /// **'换一批随机歌曲'**
  String get discover_shuffle_song_label;

  /// 歌曲行更多操作按钮的语义标签（含歌名）
  ///
  /// In zh, this message translates to:
  /// **'{title} 操作'**
  String discover_song_actions_semantics(String title);

  /// 歌单卡片的歌曲数副标题（含数量）
  ///
  /// In zh, this message translates to:
  /// **'{count} 首'**
  String discover_track_count(String count);

  /// No description provided for @discover_unavailable_local_random.
  ///
  /// In zh, this message translates to:
  /// **'本地随机暂时不可用'**
  String get discover_unavailable_local_random;

  /// No description provided for @discover_unavailable_platform.
  ///
  /// In zh, this message translates to:
  /// **'平台推荐暂时不可用'**
  String get discover_unavailable_platform;

  /// No description provided for @discover_unavailable_recommend.
  ///
  /// In zh, this message translates to:
  /// **'为你推荐暂时不可用'**
  String get discover_unavailable_recommend;

  /// No description provided for @search_back.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get search_back;

  /// No description provided for @search_clear.
  ///
  /// In zh, this message translates to:
  /// **'清空搜索'**
  String get search_clear;

  /// No description provided for @search_clear_history.
  ///
  /// In zh, this message translates to:
  /// **'清空搜索历史'**
  String get search_clear_history;

  /// No description provided for @search_current_library.
  ///
  /// In zh, this message translates to:
  /// **'当前音乐库'**
  String get search_current_library;

  /// 删除某条搜索历史记录的按钮语义标签（含关键词）
  ///
  /// In zh, this message translates to:
  /// **'删除历史 {term}'**
  String search_delete_history(String term);

  /// 某范围搜索失败的提示（含范围名）
  ///
  /// In zh, this message translates to:
  /// **'{section}搜索失败,可下拉重试'**
  String search_group_search_failed(String section);

  /// No description provided for @search_history.
  ///
  /// In zh, this message translates to:
  /// **'搜索历史'**
  String get search_history;

  /// No description provided for @search_hint.
  ///
  /// In zh, this message translates to:
  /// **'搜索歌曲、歌单、艺术家、专辑'**
  String get search_hint;

  /// No description provided for @search_hot_search.
  ///
  /// In zh, this message translates to:
  /// **'热门搜索'**
  String get search_hot_search;

  /// 搜索结果条目数量标签
  ///
  /// In zh, this message translates to:
  /// **'{count} 项'**
  String search_items_count(int count);

  /// No description provided for @search_local_no_results.
  ///
  /// In zh, this message translates to:
  /// **'本地没有找到相关结果'**
  String get search_local_no_results;

  /// No description provided for @search_local_results.
  ///
  /// In zh, this message translates to:
  /// **'本地结果'**
  String get search_local_results;

  /// No description provided for @search_network_results.
  ///
  /// In zh, this message translates to:
  /// **'全网结果'**
  String get search_network_results;

  /// No description provided for @search_network_results_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'已启用插件的合并搜索,卡片带插件·平台标签'**
  String get search_network_results_subtitle;

  /// No description provided for @search_scope_overlay.
  ///
  /// In zh, this message translates to:
  /// **'搜索范围浮层'**
  String get search_scope_overlay;

  /// 搜索某个关键词的按钮语义标签（含关键词）
  ///
  /// In zh, this message translates to:
  /// **'搜索 {term}'**
  String search_search_term_semantics(String term);

  /// 结果列表的语义标签（含关键词）
  ///
  /// In zh, this message translates to:
  /// **'正在显示“{query}”的结果'**
  String search_showing_results(String query);

  /// 歌单卡片的歌曲数副标题（含数量）
  ///
  /// In zh, this message translates to:
  /// **'{count} 首'**
  String search_song_count(String count);

  /// No description provided for @discover_music_flow_title.
  ///
  /// In zh, this message translates to:
  /// **'音乐流'**
  String get discover_music_flow_title;

  /// No description provided for @discover_category_favorites.
  ///
  /// In zh, this message translates to:
  /// **'喜欢'**
  String get discover_category_favorites;

  /// No description provided for @discover_category_playlists.
  ///
  /// In zh, this message translates to:
  /// **'歌单'**
  String get discover_category_playlists;

  /// No description provided for @discover_category_songs.
  ///
  /// In zh, this message translates to:
  /// **'歌曲'**
  String get discover_category_songs;

  /// No description provided for @discover_category_artists.
  ///
  /// In zh, this message translates to:
  /// **'艺术家'**
  String get discover_category_artists;

  /// No description provided for @discover_category_albums.
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get discover_category_albums;

  /// action_collapse
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get action_collapse;

  /// action_show_all
  ///
  /// In zh, this message translates to:
  /// **'查看全部'**
  String get action_show_all;

  /// common_delete
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get common_delete;

  /// common_remove
  ///
  /// In zh, this message translates to:
  /// **'移除'**
  String get common_remove;

  /// common_save
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get common_save;

  /// library_add_address
  ///
  /// In zh, this message translates to:
  /// **'添加地址'**
  String get library_add_address;

  /// library_add_to_library
  ///
  /// In zh, this message translates to:
  /// **'添加到音乐库'**
  String get library_add_to_library;

  /// library_add_to_playlist
  ///
  /// In zh, this message translates to:
  /// **'添加到歌单'**
  String get library_add_to_playlist;

  /// library_add_to_queue
  ///
  /// In zh, this message translates to:
  /// **'添加到播放队列'**
  String get library_add_to_queue;

  /// No description provided for @library_added_to_playlist.
  ///
  /// In zh, this message translates to:
  /// **'已添加「{name}」到歌单「{playlist}」'**
  String library_added_to_playlist(String name, String playlist);

  /// No description provided for @library_added_to_queue.
  ///
  /// In zh, this message translates to:
  /// **'已添加 {count} 首到播放队列'**
  String library_added_to_queue(String count);

  /// library_address_subtitle
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get library_address_subtitle;

  /// library_album_actions
  ///
  /// In zh, this message translates to:
  /// **'专辑操作'**
  String get library_album_actions;

  /// No description provided for @library_album_count.
  ///
  /// In zh, this message translates to:
  /// **'{count} 张专辑'**
  String library_album_count(String count);

  /// No description provided for @library_album_count_semantics.
  ///
  /// In zh, this message translates to:
  /// **'{name}，{count} 首'**
  String library_album_count_semantics(String name, String count);

  /// No description provided for @library_album_cover.
  ///
  /// In zh, this message translates to:
  /// **'{name} 封面'**
  String library_album_cover(String name);

  /// library_album_load_failed
  ///
  /// In zh, this message translates to:
  /// **'专辑加载失败'**
  String get library_album_load_failed;

  /// library_album_load_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'请检查网络或服务器状态后重试。'**
  String get library_album_load_failed_desc;

  /// No description provided for @library_album_metadata_semantics.
  ///
  /// In zh, this message translates to:
  /// **'{name}，{metadata}'**
  String library_album_metadata_semantics(String name, String metadata);

  /// library_album_no_songs
  ///
  /// In zh, this message translates to:
  /// **'这张专辑没有歌曲'**
  String get library_album_no_songs;

  /// library_album_no_tracks
  ///
  /// In zh, this message translates to:
  /// **'暂无曲目'**
  String get library_album_no_tracks;

  /// library_album_not_found
  ///
  /// In zh, this message translates to:
  /// **'未找到该专辑'**
  String get library_album_not_found;

  /// library_album_not_found_desc
  ///
  /// In zh, this message translates to:
  /// **'该专辑不存在或已被删除。'**
  String get library_album_not_found_desc;

  /// No description provided for @library_album_semantics.
  ///
  /// In zh, this message translates to:
  /// **'{name}'**
  String library_album_semantics(String name);

  /// library_album_title
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get library_album_title;

  /// library_albums
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get library_albums;

  /// library_all_albums
  ///
  /// In zh, this message translates to:
  /// **'全部专辑'**
  String get library_all_albums;

  /// library_all_artists
  ///
  /// In zh, this message translates to:
  /// **'全部歌手'**
  String get library_all_artists;

  /// library_all_playlists
  ///
  /// In zh, this message translates to:
  /// **'全部歌单'**
  String get library_all_playlists;

  /// library_all_songs
  ///
  /// In zh, this message translates to:
  /// **'全部歌曲'**
  String get library_all_songs;

  /// No description provided for @library_artist_counts.
  ///
  /// In zh, this message translates to:
  /// **'{songCount} 首 · {albumCount} 张专辑'**
  String library_artist_counts(String songCount, String albumCount);

  /// No description provided for @library_artist_image_semantics.
  ///
  /// In zh, this message translates to:
  /// **'{name} 头像'**
  String library_artist_image_semantics(String name);

  /// library_artist_load_failed
  ///
  /// In zh, this message translates to:
  /// **'歌手加载失败'**
  String get library_artist_load_failed;

  /// library_artist_load_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'请检查网络或服务器状态后重试。'**
  String get library_artist_load_failed_desc;

  /// library_artist_no_albums
  ///
  /// In zh, this message translates to:
  /// **'该歌手暂无专辑'**
  String get library_artist_no_albums;

  /// library_artist_no_songs
  ///
  /// In zh, this message translates to:
  /// **'该歌手暂无歌曲'**
  String get library_artist_no_songs;

  /// library_artist_not_found
  ///
  /// In zh, this message translates to:
  /// **'未找到该歌手'**
  String get library_artist_not_found;

  /// library_artist_not_found_desc
  ///
  /// In zh, this message translates to:
  /// **'该歌手不存在或已被删除。'**
  String get library_artist_not_found_desc;

  /// No description provided for @library_artist_photo.
  ///
  /// In zh, this message translates to:
  /// **'{name} 照片'**
  String library_artist_photo(String name);

  /// No description provided for @library_artist_semantics.
  ///
  /// In zh, this message translates to:
  /// **'{name} 歌手'**
  String library_artist_semantics(String name);

  /// library_artist_song_source
  ///
  /// In zh, this message translates to:
  /// **'歌曲来源'**
  String get library_artist_song_source;

  /// library_artist_song_source_desc
  ///
  /// In zh, this message translates to:
  /// **'展示该歌手的歌曲来源信息。'**
  String get library_artist_song_source_desc;

  /// library_artist_title
  ///
  /// In zh, this message translates to:
  /// **'歌手'**
  String get library_artist_title;

  /// library_artists
  ///
  /// In zh, this message translates to:
  /// **'歌手'**
  String get library_artists;

  /// library_create_playlist_first
  ///
  /// In zh, this message translates to:
  /// **'请先创建歌单'**
  String get library_create_playlist_first;

  /// library_delete_failed_network
  ///
  /// In zh, this message translates to:
  /// **'删除失败，请检查网络。'**
  String get library_delete_failed_network;

  /// library_delete_playlist
  ///
  /// In zh, this message translates to:
  /// **'删除歌单'**
  String get library_delete_playlist;

  /// No description provided for @library_delete_playlist_confirm.
  ///
  /// In zh, this message translates to:
  /// **'确定删除歌单「{name}」吗？'**
  String library_delete_playlist_confirm(String name);

  /// library_delete_playlist_irreversible
  ///
  /// In zh, this message translates to:
  /// **'此操作不可撤销。'**
  String get library_delete_playlist_irreversible;

  /// library_deselect_all
  ///
  /// In zh, this message translates to:
  /// **'取消全选'**
  String get library_deselect_all;

  /// library_edit_add_address
  ///
  /// In zh, this message translates to:
  /// **'添加服务器地址'**
  String get library_edit_add_address;

  /// library_edit_add_address_short
  ///
  /// In zh, this message translates to:
  /// **'添加地址'**
  String get library_edit_add_address_short;

  /// library_edit_address
  ///
  /// In zh, this message translates to:
  /// **'地址'**
  String get library_edit_address;

  /// library_edit_address_failed
  ///
  /// In zh, this message translates to:
  /// **'地址无效'**
  String get library_edit_address_failed;

  /// library_edit_address_ok
  ///
  /// In zh, this message translates to:
  /// **'地址有效'**
  String get library_edit_address_ok;

  /// library_edit_address_unknown
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get library_edit_address_unknown;

  /// library_edit_addresses_desc
  ///
  /// In zh, this message translates to:
  /// **'管理该音乐库的服务器地址。'**
  String get library_edit_addresses_desc;

  /// library_edit_addresses
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get library_edit_addresses;

  /// library_edit_basic_info
  ///
  /// In zh, this message translates to:
  /// **'基本信息'**
  String get library_edit_basic_info;

  /// library_edit_basic_info_desc
  ///
  /// In zh, this message translates to:
  /// **'编辑音乐库的名称等信息。'**
  String get library_edit_basic_info_desc;

  /// library_edit_danger_zone
  ///
  /// In zh, this message translates to:
  /// **'危险操作'**
  String get library_edit_danger_zone;

  /// library_edit_danger_zone_desc
  ///
  /// In zh, this message translates to:
  /// **'删除音乐库会移除本地配置，且不可恢复。'**
  String get library_edit_danger_zone_desc;

  /// library_edit_delete_address
  ///
  /// In zh, this message translates to:
  /// **'删除地址'**
  String get library_edit_delete_address;

  /// No description provided for @library_edit_delete_address_confirm.
  ///
  /// In zh, this message translates to:
  /// **'确定删除地址「{label}」吗？'**
  String library_edit_delete_address_confirm(String label);

  /// No description provided for @library_edit_delete_address_short.
  ///
  /// In zh, this message translates to:
  /// **'删除「{label}」'**
  String library_edit_delete_address_short(String label);

  /// library_edit_delete_library
  ///
  /// In zh, this message translates to:
  /// **'删除音乐库'**
  String get library_edit_delete_library;

  /// library_edit_delete_library_action
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get library_edit_delete_library_action;

  /// No description provided for @library_edit_delete_library_confirm.
  ///
  /// In zh, this message translates to:
  /// **'确定删除音乐库「{name}」吗？'**
  String library_edit_delete_library_confirm(String name);

  /// No description provided for @library_edit_drag_hint.
  ///
  /// In zh, this message translates to:
  /// **'拖动「{label}」调整优先级'**
  String library_edit_drag_hint(String label);

  /// No description provided for @library_edit_edit_address.
  ///
  /// In zh, this message translates to:
  /// **'编辑「{label}」'**
  String library_edit_edit_address(String label);

  /// library_edit_failed_network
  ///
  /// In zh, this message translates to:
  /// **'保存失败，请检查网络。'**
  String get library_edit_failed_network;

  /// No description provided for @library_edit_latency.
  ///
  /// In zh, this message translates to:
  /// **'{ms} ms'**
  String library_edit_latency(String ms);

  /// library_edit_latency_unknown
  ///
  /// In zh, this message translates to:
  /// **'延迟未知'**
  String get library_edit_latency_unknown;

  /// library_edit_library
  ///
  /// In zh, this message translates to:
  /// **'编辑音乐库'**
  String get library_edit_library;

  /// library_edit_library_loading
  ///
  /// In zh, this message translates to:
  /// **'加载中…'**
  String get library_edit_library_loading;

  /// library_edit_library_name
  ///
  /// In zh, this message translates to:
  /// **'音乐库名称'**
  String get library_edit_library_name;

  /// library_edit_library_name_example
  ///
  /// In zh, this message translates to:
  /// **'例如：我的主音乐库'**
  String get library_edit_library_name_example;

  /// library_edit_library_updating
  ///
  /// In zh, this message translates to:
  /// **'更新中…'**
  String get library_edit_library_updating;

  /// library_edit_load_failed
  ///
  /// In zh, this message translates to:
  /// **'音乐库加载失败'**
  String get library_edit_load_failed;

  /// library_edit_load_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'请检查网络或服务器状态后重试。'**
  String get library_edit_load_failed_desc;

  /// library_edit_name_required
  ///
  /// In zh, this message translates to:
  /// **'请输入音乐库名称'**
  String get library_edit_name_required;

  /// library_edit_no_addresses
  ///
  /// In zh, this message translates to:
  /// **'暂无服务器地址'**
  String get library_edit_no_addresses;

  /// library_edit_no_addresses_desc
  ///
  /// In zh, this message translates to:
  /// **'添加一个服务器地址以连接音乐库。'**
  String get library_edit_no_addresses_desc;

  /// library_edit_playlist
  ///
  /// In zh, this message translates to:
  /// **'编辑歌单'**
  String get library_edit_playlist;

  /// library_edit_probe_all
  ///
  /// In zh, this message translates to:
  /// **'全部测试'**
  String get library_edit_probe_all;

  /// library_edit_save_success
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get library_edit_save_success;

  /// library_edit_server_addresses
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get library_edit_server_addresses;

  /// library_edit_verify_failed
  ///
  /// In zh, this message translates to:
  /// **'服务器验证失败'**
  String get library_edit_verify_failed;

  /// library_edit_verify_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'无法连接该服务器，请检查地址与网络。'**
  String get library_edit_verify_failed_desc;

  /// library_edit_verifying_server
  ///
  /// In zh, this message translates to:
  /// **'正在验证服务器…'**
  String get library_edit_verifying_server;

  /// library_empty_albums
  ///
  /// In zh, this message translates to:
  /// **'暂无专辑'**
  String get library_empty_albums;

  /// library_empty_albums_desc
  ///
  /// In zh, this message translates to:
  /// **'这里还没有任何专辑。'**
  String get library_empty_albums_desc;

  /// library_empty_artists
  ///
  /// In zh, this message translates to:
  /// **'暂无歌手'**
  String get library_empty_artists;

  /// library_empty_artists_desc
  ///
  /// In zh, this message translates to:
  /// **'这里还没有任何歌手。'**
  String get library_empty_artists_desc;

  /// library_empty_playlists
  ///
  /// In zh, this message translates to:
  /// **'暂无歌单'**
  String get library_empty_playlists;

  /// library_empty_playlists_desc
  ///
  /// In zh, this message translates to:
  /// **'这里还没有任何歌单。'**
  String get library_empty_playlists_desc;

  /// library_empty_songs
  ///
  /// In zh, this message translates to:
  /// **'暂无歌曲'**
  String get library_empty_songs;

  /// library_empty_songs_desc
  ///
  /// In zh, this message translates to:
  /// **'这里还没有任何歌曲。'**
  String get library_empty_songs_desc;

  /// library_empty_tracks
  ///
  /// In zh, this message translates to:
  /// **'暂无曲目'**
  String get library_empty_tracks;

  /// library_empty_tracks_desc
  ///
  /// In zh, this message translates to:
  /// **'该音乐库暂无曲目。'**
  String get library_empty_tracks_desc;

  /// library_exit_song_management
  ///
  /// In zh, this message translates to:
  /// **'退出歌曲管理'**
  String get library_exit_song_management;

  /// library_favorite_album
  ///
  /// In zh, this message translates to:
  /// **'收藏专辑'**
  String get library_favorite_album;

  /// library_favorite_artist
  ///
  /// In zh, this message translates to:
  /// **'收藏歌手'**
  String get library_favorite_artist;

  /// library_favorite_playlist
  ///
  /// In zh, this message translates to:
  /// **'收藏歌单'**
  String get library_favorite_playlist;

  /// library_favorited_album
  ///
  /// In zh, this message translates to:
  /// **'已收藏该专辑'**
  String get library_favorited_album;

  /// library_favorited_artist
  ///
  /// In zh, this message translates to:
  /// **'已收藏该歌手'**
  String get library_favorited_artist;

  /// No description provided for @library_favorited_playlist.
  ///
  /// In zh, this message translates to:
  /// **'已收藏歌单「{name}」'**
  String library_favorited_playlist(String name);

  /// library_got_it
  ///
  /// In zh, this message translates to:
  /// **'知道了'**
  String get library_got_it;

  /// library_http_hint
  ///
  /// In zh, this message translates to:
  /// **'请使用 http:// 或 https:// 协议'**
  String get library_http_hint;

  /// library_http_insecure_warning
  ///
  /// In zh, this message translates to:
  /// **'该服务器使用不安全的 HTTP 连接。'**
  String get library_http_insecure_warning;

  /// library_http_tip_title
  ///
  /// In zh, this message translates to:
  /// **'连接不安全'**
  String get library_http_tip_title;

  /// library_label
  ///
  /// In zh, this message translates to:
  /// **'标签'**
  String get library_label;

  /// library_label_hint
  ///
  /// In zh, this message translates to:
  /// **'为地址指定一个便于识别的标签'**
  String get library_label_hint;

  /// library_label_required
  ///
  /// In zh, this message translates to:
  /// **'请输入标签'**
  String get library_label_required;

  /// library_load_failed_retry
  ///
  /// In zh, this message translates to:
  /// **'加载失败，点击重试'**
  String get library_load_failed_retry;

  /// library_local_no_match_albums
  ///
  /// In zh, this message translates to:
  /// **'本地未找到匹配的专辑'**
  String get library_local_no_match_albums;

  /// library_local_no_match_artists
  ///
  /// In zh, this message translates to:
  /// **'本地未找到匹配的歌手'**
  String get library_local_no_match_artists;

  /// library_local_no_match_playlists
  ///
  /// In zh, this message translates to:
  /// **'本地未找到匹配的歌单'**
  String get library_local_no_match_playlists;

  /// library_local_no_match_songs
  ///
  /// In zh, this message translates to:
  /// **'本地未找到匹配的歌曲'**
  String get library_local_no_match_songs;

  /// library_manage_playlist_songs
  ///
  /// In zh, this message translates to:
  /// **'管理歌单歌曲'**
  String get library_manage_playlist_songs;

  /// library_network_add_failed
  ///
  /// In zh, this message translates to:
  /// **'添加失败，请检查网络。'**
  String get library_network_add_failed;

  /// library_network_album_load_failed
  ///
  /// In zh, this message translates to:
  /// **'专辑加载失败，请检查网络。'**
  String get library_network_album_load_failed;

  /// library_network_artist_load_failed
  ///
  /// In zh, this message translates to:
  /// **'歌手加载失败，请检查网络。'**
  String get library_network_artist_load_failed;

  /// library_network_cached_content
  ///
  /// In zh, this message translates to:
  /// **'当前正在使用缓存的离线内容。'**
  String get library_network_cached_content;

  /// library_network_op_failed
  ///
  /// In zh, this message translates to:
  /// **'操作失败，请检查网络。'**
  String get library_network_op_failed;

  /// library_no_albums
  ///
  /// In zh, this message translates to:
  /// **'暂无专辑'**
  String get library_no_albums;

  /// library_no_library_selected
  ///
  /// In zh, this message translates to:
  /// **'未选择音乐库'**
  String get library_no_library_selected;

  /// library_no_playable_songs
  ///
  /// In zh, this message translates to:
  /// **'没有可播放的歌曲'**
  String get library_no_playable_songs;

  /// library_no_playlists
  ///
  /// In zh, this message translates to:
  /// **'暂无歌单'**
  String get library_no_playlists;

  /// library_no_songs
  ///
  /// In zh, this message translates to:
  /// **'暂无歌曲'**
  String get library_no_songs;

  /// No description provided for @library_operation_failed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败：{reason}'**
  String library_operation_failed(String reason);

  /// library_play_album
  ///
  /// In zh, this message translates to:
  /// **'播放专辑'**
  String get library_play_album;

  /// library_play_all
  ///
  /// In zh, this message translates to:
  /// **'播放全部'**
  String get library_play_all;

  /// library_play_artist_top
  ///
  /// In zh, this message translates to:
  /// **'播放歌手热门歌曲'**
  String get library_play_artist_top;

  /// library_play_failed_network
  ///
  /// In zh, this message translates to:
  /// **'播放失败，请检查网络。'**
  String get library_play_failed_network;

  /// library_play_songs
  ///
  /// In zh, this message translates to:
  /// **'播放歌曲'**
  String get library_play_songs;

  /// library_playlist
  ///
  /// In zh, this message translates to:
  /// **'歌单'**
  String get library_playlist;

  /// library_playlist_actions
  ///
  /// In zh, this message translates to:
  /// **'歌单操作'**
  String get library_playlist_actions;

  /// library_playlist_comment
  ///
  /// In zh, this message translates to:
  /// **'歌单评论'**
  String get library_playlist_comment;

  /// library_playlist_comment_example
  ///
  /// In zh, this message translates to:
  /// **'例如：我的晨练歌单'**
  String get library_playlist_comment_example;

  /// No description provided for @library_playlist_count_duration.
  ///
  /// In zh, this message translates to:
  /// **'{count} 首 · {duration}'**
  String library_playlist_count_duration(String count, String duration);

  /// No description provided for @library_playlist_cover.
  ///
  /// In zh, this message translates to:
  /// **'{name} 封面'**
  String library_playlist_cover(String name);

  /// No description provided for @library_playlist_deleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除歌单「{name}」'**
  String library_playlist_deleted(String name);

  /// library_playlist_empty
  ///
  /// In zh, this message translates to:
  /// **'这个歌单是空的'**
  String get library_playlist_empty;

  /// library_playlist_empty_desc
  ///
  /// In zh, this message translates to:
  /// **'尝试添加一些歌曲到歌单。'**
  String get library_playlist_empty_desc;

  /// library_playlist_load_failed
  ///
  /// In zh, this message translates to:
  /// **'歌单加载失败'**
  String get library_playlist_load_failed;

  /// library_playlist_load_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'请检查网络或服务器状态后重试。'**
  String get library_playlist_load_failed_desc;

  /// library_playlist_name
  ///
  /// In zh, this message translates to:
  /// **'歌单名称'**
  String get library_playlist_name;

  /// library_playlist_name_hint
  ///
  /// In zh, this message translates to:
  /// **'给歌单起个名字'**
  String get library_playlist_name_hint;

  /// library_playlist_name_required
  ///
  /// In zh, this message translates to:
  /// **'请输入歌单名称'**
  String get library_playlist_name_required;

  /// library_playlist_no_available_songs
  ///
  /// In zh, this message translates to:
  /// **'没有可添加的歌曲'**
  String get library_playlist_no_available_songs;

  /// library_playlist_no_songs
  ///
  /// In zh, this message translates to:
  /// **'该歌单暂无歌曲'**
  String get library_playlist_no_songs;

  /// library_playlist_private_desc
  ///
  /// In zh, this message translates to:
  /// **'仅自己可见'**
  String get library_playlist_private_desc;

  /// library_playlist_public_desc
  ///
  /// In zh, this message translates to:
  /// **'所有用户可见'**
  String get library_playlist_public_desc;

  /// library_playlist_public
  ///
  /// In zh, this message translates to:
  /// **'公开'**
  String get library_playlist_public;

  /// No description provided for @library_playlist_updated.
  ///
  /// In zh, this message translates to:
  /// **'已更新「{name}」'**
  String library_playlist_updated(String name);

  /// library_playlist_updated_reselect
  ///
  /// In zh, this message translates to:
  /// **'歌单内容已变化，请重新选择'**
  String get library_playlist_updated_reselect;

  /// library_playlists
  ///
  /// In zh, this message translates to:
  /// **'歌单'**
  String get library_playlists;

  /// library_playlists_unavailable
  ///
  /// In zh, this message translates to:
  /// **'歌单暂不可用'**
  String get library_playlists_unavailable;

  /// library_private_playlist
  ///
  /// In zh, this message translates to:
  /// **'私有歌单'**
  String get library_private_playlist;

  /// library_public_playlist
  ///
  /// In zh, this message translates to:
  /// **'公开歌单'**
  String get library_public_playlist;

  /// library_remote_album_empty_desc
  ///
  /// In zh, this message translates to:
  /// **'远程音乐库暂无专辑。'**
  String get library_remote_album_empty_desc;

  /// library_remote_album_load_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'远程专辑加载失败，请检查网络。'**
  String get library_remote_album_load_failed_desc;

  /// library_remote_artist_empty_desc
  ///
  /// In zh, this message translates to:
  /// **'远程音乐库暂无歌手。'**
  String get library_remote_artist_empty_desc;

  /// library_remote_artist_load_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'远程歌手加载失败，请检查网络。'**
  String get library_remote_artist_load_failed_desc;

  /// library_remote_load_failed
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get library_remote_load_failed;

  /// library_remote_playlist_empty_desc
  ///
  /// In zh, this message translates to:
  /// **'远程音乐库暂无歌单。'**
  String get library_remote_playlist_empty_desc;

  /// library_remote_playlist_load_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'远程歌单加载失败，请检查网络。'**
  String get library_remote_playlist_load_failed_desc;

  /// No description provided for @library_remove_failed.
  ///
  /// In zh, this message translates to:
  /// **'移除失败：{reason}'**
  String library_remove_failed(String reason);

  /// library_remove_failed_network
  ///
  /// In zh, this message translates to:
  /// **'移除失败，请检查网络。'**
  String get library_remove_failed_network;

  /// library_remove_from_current_playlist
  ///
  /// In zh, this message translates to:
  /// **'从当前歌单移除'**
  String get library_remove_from_current_playlist;

  /// library_remove_from_playlist
  ///
  /// In zh, this message translates to:
  /// **'从歌单移除'**
  String get library_remove_from_playlist;

  /// library_remove_no_permission
  ///
  /// In zh, this message translates to:
  /// **'没有权限移除歌曲，请检查账户权限。'**
  String get library_remove_no_permission;

  /// library_remove_selected
  ///
  /// In zh, this message translates to:
  /// **'移除所选'**
  String get library_remove_selected;

  /// library_remove_selected_semantics
  ///
  /// In zh, this message translates to:
  /// **'移除所选歌曲'**
  String get library_remove_selected_semantics;

  /// library_remove_server_refused
  ///
  /// In zh, this message translates to:
  /// **'服务器拒绝了移除请求。'**
  String get library_remove_server_refused;

  /// library_remove_songs
  ///
  /// In zh, this message translates to:
  /// **'移除歌曲'**
  String get library_remove_songs;

  /// No description provided for @library_remove_songs_confirm.
  ///
  /// In zh, this message translates to:
  /// **'将移除 {count} 首歌曲，确定从歌单「{name}」移除吗？'**
  String library_remove_songs_confirm(String name, String count);

  /// library_remove_songs_desc
  ///
  /// In zh, this message translates to:
  /// **'已选择以下歌曲，执行后将从歌单移除。'**
  String get library_remove_songs_desc;

  /// No description provided for @library_removed_count.
  ///
  /// In zh, this message translates to:
  /// **'已移除 {count} 首'**
  String library_removed_count(String count);

  /// No description provided for @library_removed_from_playlist.
  ///
  /// In zh, this message translates to:
  /// **'已将「{title}」移出歌单'**
  String library_removed_from_playlist(String title);

  /// library_removing
  ///
  /// In zh, this message translates to:
  /// **'移除中…'**
  String get library_removing;

  /// library_retry_on_network
  ///
  /// In zh, this message translates to:
  /// **'点击重试'**
  String get library_retry_on_network;

  /// library_save_address
  ///
  /// In zh, this message translates to:
  /// **'保存地址'**
  String get library_save_address;

  /// library_save_anyway
  ///
  /// In zh, this message translates to:
  /// **'仍然保存'**
  String get library_save_anyway;

  /// library_save_insecure_http_title
  ///
  /// In zh, this message translates to:
  /// **'保存不安全的地址？'**
  String get library_save_insecure_http_title;

  /// library_save_library
  ///
  /// In zh, this message translates to:
  /// **'保存音乐库'**
  String get library_save_library;

  /// library_search_albums
  ///
  /// In zh, this message translates to:
  /// **'搜索专辑'**
  String get library_search_albums;

  /// library_search_artists
  ///
  /// In zh, this message translates to:
  /// **'搜索歌手'**
  String get library_search_artists;

  /// library_search_playlists
  ///
  /// In zh, this message translates to:
  /// **'搜索歌单'**
  String get library_search_playlists;

  /// library_search_songs
  ///
  /// In zh, this message translates to:
  /// **'搜索歌曲'**
  String get library_search_songs;

  /// library_select_all
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get library_select_all;

  /// library_select_songs_to_remove
  ///
  /// In zh, this message translates to:
  /// **'选择要移除的歌曲'**
  String get library_select_songs_to_remove;

  /// No description provided for @library_selected_count.
  ///
  /// In zh, this message translates to:
  /// **'已选择 {count} 项'**
  String library_selected_count(String count);

  /// No description provided for @library_selected_count_rationale.
  ///
  /// In zh, this message translates to:
  /// **'已选择 {count} 首歌曲'**
  String library_selected_count_rationale(String count);

  /// library_server_address
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get library_server_address;

  /// library_server_required
  ///
  /// In zh, this message translates to:
  /// **'请输入服务器地址'**
  String get library_server_required;

  /// No description provided for @library_song_count.
  ///
  /// In zh, this message translates to:
  /// **'{count} 首歌曲'**
  String library_song_count(String count);

  /// library_song_sort
  ///
  /// In zh, this message translates to:
  /// **'歌曲排序'**
  String get library_song_sort;

  /// No description provided for @library_song_sort_current.
  ///
  /// In zh, this message translates to:
  /// **'当前排序：{sort}'**
  String library_song_sort_current(String sort);

  /// No description provided for @library_song_sort_option.
  ///
  /// In zh, this message translates to:
  /// **'排序：{sort}'**
  String library_song_sort_option(String sort);

  /// library_songs
  ///
  /// In zh, this message translates to:
  /// **'歌曲'**
  String get library_songs;

  /// No description provided for @library_songs_count.
  ///
  /// In zh, this message translates to:
  /// **'{count} 首歌曲'**
  String library_songs_count(String count);

  /// library_sort_sheet_subtitle
  ///
  /// In zh, this message translates to:
  /// **'选择歌曲的排列顺序。'**
  String get library_sort_sheet_subtitle;

  /// No description provided for @library_starred_label.
  ///
  /// In zh, this message translates to:
  /// **'{label}（收藏）'**
  String library_starred_label(String label);

  /// library_starred_load_failed
  ///
  /// In zh, this message translates to:
  /// **'收藏加载失败'**
  String get library_starred_load_failed;

  /// library_starred_load_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'请检查网络或服务器状态后重试。'**
  String get library_starred_load_failed_desc;

  /// library_starred_no_albums
  ///
  /// In zh, this message translates to:
  /// **'暂无收藏专辑'**
  String get library_starred_no_albums;

  /// library_starred_no_albums_desc
  ///
  /// In zh, this message translates to:
  /// **'在专辑卡片点亮红心后，会显示在这里。'**
  String get library_starred_no_albums_desc;

  /// library_starred_no_artists
  ///
  /// In zh, this message translates to:
  /// **'暂无收藏歌手'**
  String get library_starred_no_artists;

  /// library_starred_no_artists_desc
  ///
  /// In zh, this message translates to:
  /// **'在歌手卡片点亮红心后，会显示在这里。'**
  String get library_starred_no_artists_desc;

  /// library_starred_no_playlists
  ///
  /// In zh, this message translates to:
  /// **'暂无收藏歌单'**
  String get library_starred_no_playlists;

  /// library_starred_no_playlists_desc
  ///
  /// In zh, this message translates to:
  /// **'在歌单卡片点亮红心后，会显示在这里。'**
  String get library_starred_no_playlists_desc;

  /// library_starred_no_songs
  ///
  /// In zh, this message translates to:
  /// **'暂无收藏歌曲'**
  String get library_starred_no_songs;

  /// library_starred_no_songs_desc
  ///
  /// In zh, this message translates to:
  /// **'在歌曲列表点亮红心后，会显示在这里。'**
  String get library_starred_no_songs_desc;

  /// No description provided for @library_starred_playlist_cover_semantics.
  ///
  /// In zh, this message translates to:
  /// **'{name} 封面'**
  String library_starred_playlist_cover_semantics(String name);

  /// No description provided for @library_starred_playlist_favorited_semantics.
  ///
  /// In zh, this message translates to:
  /// **'{name}，{count} 首，已收藏'**
  String library_starred_playlist_favorited_semantics(
    String name,
    String count,
  );

  /// No description provided for @library_starred_playlist_meta.
  ///
  /// In zh, this message translates to:
  /// **'{count} 首 · {duration}'**
  String library_starred_playlist_meta(String count, String duration);

  /// library_starred_playlists_load_failed
  ///
  /// In zh, this message translates to:
  /// **'歌单加载失败'**
  String get library_starred_playlists_load_failed;

  /// library_starred_title
  ///
  /// In zh, this message translates to:
  /// **'我喜欢'**
  String get library_starred_title;

  /// No description provided for @library_starred_total.
  ///
  /// In zh, this message translates to:
  /// **'共收藏 {count} 项'**
  String library_starred_total(String count);

  /// No description provided for @library_toggle_accessibility.
  ///
  /// In zh, this message translates to:
  /// **'{title}，{state}，{description}'**
  String library_toggle_accessibility(
    String title,
    String state,
    String description,
  );

  /// library_top_songs
  ///
  /// In zh, this message translates to:
  /// **'热门歌曲'**
  String get library_top_songs;

  /// No description provided for @library_top_songs_count.
  ///
  /// In zh, this message translates to:
  /// **'热门歌曲 {count} 首'**
  String library_top_songs_count(String count);

  /// library_top_songs_unavailable
  ///
  /// In zh, this message translates to:
  /// **'热门歌曲不可用'**
  String get library_top_songs_unavailable;

  /// No description provided for @library_track_count_sort.
  ///
  /// In zh, this message translates to:
  /// **'{count} 首 · {sort}'**
  String library_track_count_sort(String count, String sort);

  /// library_tracks
  ///
  /// In zh, this message translates to:
  /// **'曲目'**
  String get library_tracks;

  /// library_unfavorite_album
  ///
  /// In zh, this message translates to:
  /// **'取消收藏专辑'**
  String get library_unfavorite_album;

  /// library_unfavorite_artist
  ///
  /// In zh, this message translates to:
  /// **'取消收藏歌手'**
  String get library_unfavorite_artist;

  /// library_unfavorite_playlist
  ///
  /// In zh, this message translates to:
  /// **'取消收藏歌单'**
  String get library_unfavorite_playlist;

  /// library_unfavorited_album
  ///
  /// In zh, this message translates to:
  /// **'已取消收藏该专辑'**
  String get library_unfavorited_album;

  /// library_unfavorited_artist
  ///
  /// In zh, this message translates to:
  /// **'已取消收藏该歌手'**
  String get library_unfavorited_artist;

  /// No description provided for @library_unfavorited_playlist.
  ///
  /// In zh, this message translates to:
  /// **'已取消收藏歌单「{name}」'**
  String library_unfavorited_playlist(String name);

  /// library_unfavorited_short
  ///
  /// In zh, this message translates to:
  /// **'已取消收藏'**
  String get library_unfavorited_short;

  /// library_unknown_artist
  ///
  /// In zh, this message translates to:
  /// **'未知歌手'**
  String get library_unknown_artist;

  /// library_url_hint
  ///
  /// In zh, this message translates to:
  /// **'例如：http://192.168.1.100:4533'**
  String get library_url_hint;

  /// library_url_invalid
  ///
  /// In zh, this message translates to:
  /// **'地址格式无效'**
  String get library_url_invalid;

  /// playlist_sort_updated_asc
  ///
  /// In zh, this message translates to:
  /// **'最近更新（升序）'**
  String get playlist_sort_updated_asc;

  /// playlist_sort_updated_desc
  ///
  /// In zh, this message translates to:
  /// **'最近更新'**
  String get playlist_sort_updated_desc;

  /// song_sort_alphabetical_asc
  ///
  /// In zh, this message translates to:
  /// **'按标题（升序）'**
  String get song_sort_alphabetical_asc;

  /// song_sort_alphabetical_desc
  ///
  /// In zh, this message translates to:
  /// **'按标题（降序）'**
  String get song_sort_alphabetical_desc;

  /// song_sort_default_order
  ///
  /// In zh, this message translates to:
  /// **'默认排序'**
  String get song_sort_default_order;

  /// song_sort_duration_asc
  ///
  /// In zh, this message translates to:
  /// **'按时长（升序）'**
  String get song_sort_duration_asc;

  /// song_sort_duration_desc
  ///
  /// In zh, this message translates to:
  /// **'按时长（降序）'**
  String get song_sort_duration_desc;

  /// song_sort_recent_added
  ///
  /// In zh, this message translates to:
  /// **'最近添加'**
  String get song_sort_recent_added;

  /// song_sort_title_asc
  ///
  /// In zh, this message translates to:
  /// **'按标题（升序）'**
  String get song_sort_title_asc;

  /// song_sort_updated_asc
  ///
  /// In zh, this message translates to:
  /// **'按更新时间（升序）'**
  String get song_sort_updated_asc;

  /// song_sort_updated_desc
  ///
  /// In zh, this message translates to:
  /// **'按更新时间（降序）'**
  String get song_sort_updated_desc;

  /// state_disabled
  ///
  /// In zh, this message translates to:
  /// **'已关闭'**
  String get state_disabled;

  /// state_enabled
  ///
  /// In zh, this message translates to:
  /// **'已开启'**
  String get state_enabled;

  /// player_close
  ///
  /// In zh, this message translates to:
  /// **'关闭播放器'**
  String get player_close;

  /// player_empty_title
  ///
  /// In zh, this message translates to:
  /// **'暂无播放内容'**
  String get player_empty_title;

  /// player_empty_desc
  ///
  /// In zh, this message translates to:
  /// **'从音乐流、搜索或资料库选择一首歌曲开始播放。'**
  String get player_empty_desc;

  /// player_collapse
  ///
  /// In zh, this message translates to:
  /// **'收起播放器'**
  String get player_collapse;

  /// player_page_dots
  ///
  /// In zh, this message translates to:
  /// **'播放器页面，第 {page} 页，共 {total} 页'**
  String player_page_dots(int page, int total);

  /// player_no_lyrics_title
  ///
  /// In zh, this message translates to:
  /// **'暂无歌词'**
  String get player_no_lyrics_title;

  /// player_no_lyrics_desc
  ///
  /// In zh, this message translates to:
  /// **'当前曲目没有可用的歌词内容。'**
  String get player_no_lyrics_desc;

  /// player_lyrics_load_failed_title
  ///
  /// In zh, this message translates to:
  /// **'歌词加载失败'**
  String get player_lyrics_load_failed_title;

  /// player_lyrics_load_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'播放不受影响，可以立即重试。'**
  String get player_lyrics_load_failed_desc;

  /// player_lyrics_loading
  ///
  /// In zh, this message translates to:
  /// **'歌词加载中'**
  String get player_lyrics_loading;

  /// player_lyrics_synced_label
  ///
  /// In zh, this message translates to:
  /// **'同步歌词'**
  String get player_lyrics_synced_label;

  /// player_lyrics_label
  ///
  /// In zh, this message translates to:
  /// **'歌词'**
  String get player_lyrics_label;

  /// player_lyrics_current
  ///
  /// In zh, this message translates to:
  /// **'当前歌词'**
  String get player_lyrics_current;

  /// player_lyrics_seek
  ///
  /// In zh, this message translates to:
  /// **'跳转到 {time}'**
  String player_lyrics_seek(String time);

  /// player_mode_shuffle
  ///
  /// In zh, this message translates to:
  /// **'随机播放，点击切换到顺序播放'**
  String get player_mode_shuffle;

  /// player_mode_loop_one
  ///
  /// In zh, this message translates to:
  /// **'单曲循环，点击切换到列表循环'**
  String get player_mode_loop_one;

  /// player_mode_order
  ///
  /// In zh, this message translates to:
  /// **'顺序播放，点击切换到单曲循环'**
  String get player_mode_order;

  /// player_mode_list
  ///
  /// In zh, this message translates to:
  /// **'列表循环，点击切换到随机播放'**
  String get player_mode_list;

  /// player_previous
  ///
  /// In zh, this message translates to:
  /// **'上一首'**
  String get player_previous;

  /// player_pause
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get player_pause;

  /// player_next
  ///
  /// In zh, this message translates to:
  /// **'下一首'**
  String get player_next;

  /// player_queue
  ///
  /// In zh, this message translates to:
  /// **'播放队列'**
  String get player_queue;

  /// player_dlna_local
  ///
  /// In zh, this message translates to:
  /// **'局域网 DLNA 直投'**
  String get player_dlna_local;

  /// player_dlna_local_casting
  ///
  /// In zh, this message translates to:
  /// **'局域网 DLNA 直投，正在投屏到「{device}」'**
  String player_dlna_local_casting(String device);

  /// player_unfavorite
  ///
  /// In zh, this message translates to:
  /// **'取消红心'**
  String get player_unfavorite;

  /// player_favorite
  ///
  /// In zh, this message translates to:
  /// **'红心'**
  String get player_favorite;

  /// player_switch_current
  ///
  /// In zh, this message translates to:
  /// **'切换播放器，当前：{name}'**
  String player_switch_current(String name);

  /// player_casting_to
  ///
  /// In zh, this message translates to:
  /// **'正在投屏到「{name}」'**
  String player_casting_to(String name);

  /// player_switched_local
  ///
  /// In zh, this message translates to:
  /// **'已切换为本机播放'**
  String get player_switched_local;

  /// player_dlna_dialog_subtitle
  ///
  /// In zh, this message translates to:
  /// **'客户端自扫局域网设备并本地推流，与「切换播放器」（服务端投屏）相互独立。'**
  String get player_dlna_dialog_subtitle;

  /// player_progress
  ///
  /// In zh, this message translates to:
  /// **'播放进度'**
  String get player_progress;

  /// player_progress_percent
  ///
  /// In zh, this message translates to:
  /// **'播放进度 {percent}%'**
  String player_progress_percent(int percent);

  /// player_playlist_label
  ///
  /// In zh, this message translates to:
  /// **'当前播放列表'**
  String get player_playlist_label;

  /// player_playing_state
  ///
  /// In zh, this message translates to:
  /// **'正在播放'**
  String get player_playing_state;

  /// player_paused_state
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get player_paused_state;

  /// player_not_playing
  ///
  /// In zh, this message translates to:
  /// **'未在播放'**
  String get player_not_playing;

  /// player_mini_semantic
  ///
  /// In zh, this message translates to:
  /// **'迷你播放器，{title}{subtitle}'**
  String player_mini_semantic(String title, String subtitle);

  /// player_seek_forward
  ///
  /// In zh, this message translates to:
  /// **'快进 10 秒'**
  String get player_seek_forward;

  /// player_seek_backward
  ///
  /// In zh, this message translates to:
  /// **'后退 10 秒'**
  String get player_seek_backward;

  /// player_choose_song_prompt
  ///
  /// In zh, this message translates to:
  /// **'选择一首歌曲开始播放'**
  String get player_choose_song_prompt;

  /// player_volume_inc
  ///
  /// In zh, this message translates to:
  /// **'增大音量'**
  String get player_volume_inc;

  /// player_volume_dec
  ///
  /// In zh, this message translates to:
  /// **'减小音量'**
  String get player_volume_dec;

  /// player_volume_percent
  ///
  /// In zh, this message translates to:
  /// **'音量 {percent}%'**
  String player_volume_percent(int percent);

  /// player_select_source_title
  ///
  /// In zh, this message translates to:
  /// **'选择播放器'**
  String get player_select_source_title;

  /// player_select_source_subtitle
  ///
  /// In zh, this message translates to:
  /// **'切换播放器仅改变当前控制目标,不会停止其他播放器。'**
  String get player_select_source_subtitle;

  /// player_source_local_title
  ///
  /// In zh, this message translates to:
  /// **'本机播放'**
  String get player_source_local_title;

  /// player_source_local_desc
  ///
  /// In zh, this message translates to:
  /// **'使用此设备扬声器'**
  String get player_source_local_desc;

  /// player_source_casting
  ///
  /// In zh, this message translates to:
  /// **'当前正在投屏'**
  String get player_source_casting;

  /// player_source_offline
  ///
  /// In zh, this message translates to:
  /// **'设备离线,已暂停轮询'**
  String get player_source_offline;

  /// player_stop_cast
  ///
  /// In zh, this message translates to:
  /// **'停止投屏'**
  String get player_stop_cast;

  /// player_stop_cast_subtitle
  ///
  /// In zh, this message translates to:
  /// **'停止「{name}」播放并清除控制'**
  String player_stop_cast_subtitle(String name);

  /// player_cast_failed
  ///
  /// In zh, this message translates to:
  /// **'切换到「{name}」失败,请检查设备是否在线'**
  String player_cast_failed(String name);

  /// player_loading_peers
  ///
  /// In zh, this message translates to:
  /// **'正在获取可用播放器…'**
  String get player_loading_peers;

  /// player_no_other_players
  ///
  /// In zh, this message translates to:
  /// **'未发现其他可用播放器。'**
  String get player_no_other_players;

  /// player_refresh_players
  ///
  /// In zh, this message translates to:
  /// **'刷新播放器列表'**
  String get player_refresh_players;

  /// player_stopped_cast
  ///
  /// In zh, this message translates to:
  /// **'已停止投屏'**
  String get player_stopped_cast;

  /// player_remote_control
  ///
  /// In zh, this message translates to:
  /// **'正在远控「{name}」'**
  String player_remote_control(String name);

  /// song_cover_semantic
  ///
  /// In zh, this message translates to:
  /// **'{title} 封面'**
  String song_cover_semantic(String title);

  /// dlna_no_queue_to_cast
  ///
  /// In zh, this message translates to:
  /// **'当前没有可投屏的播放队列'**
  String get dlna_no_queue_to_cast;

  /// dlna_cast_success
  ///
  /// In zh, this message translates to:
  /// **'已投屏到「{device}」'**
  String dlna_cast_success(String device);

  /// dlna_cast_failed
  ///
  /// In zh, this message translates to:
  /// **'投屏到「{device}」失败，请检查设备是否在线'**
  String dlna_cast_failed(String device);

  /// dlna_cast_stopped
  ///
  /// In zh, this message translates to:
  /// **'已停止局域网投屏'**
  String get dlna_cast_stopped;

  /// dlna_queue_ended
  ///
  /// In zh, this message translates to:
  /// **'队列已结束'**
  String get dlna_queue_ended;

  /// dlna_stop
  ///
  /// In zh, this message translates to:
  /// **'停止局域网投屏'**
  String get dlna_stop;

  /// dlna_stop_subtitle
  ///
  /// In zh, this message translates to:
  /// **'停止设备播放并释放本地投屏队列'**
  String get dlna_stop_subtitle;

  /// dlna_scan_devices
  ///
  /// In zh, this message translates to:
  /// **'扫描局域网 DLNA 设备'**
  String get dlna_scan_devices;

  /// dlna_device_subtitle
  ///
  /// In zh, this message translates to:
  /// **'本机局域网发现 · 直投'**
  String get dlna_device_subtitle;

  /// dlna_searching
  ///
  /// In zh, this message translates to:
  /// **'正在搜索局域网内的 DLNA 设备…'**
  String get dlna_searching;

  /// dlna_no_device
  ///
  /// In zh, this message translates to:
  /// **'未发现可用 DLNA 设备。请确认与音箱/电视处于同一网络后再扫描。'**
  String get dlna_no_device;

  /// dlna_background_hint
  ///
  /// In zh, this message translates to:
  /// **'为保证后台持续投屏并自动切下一首：请在系统设置中将 MusicFlow 的「电池优化」改为「不限制」，并将「应用启动管理」改为「手动管理」后全部允许（允许自启动 / 关联启动 / 后台活动），避免曲末时因后台冻结而停播。'**
  String get dlna_background_hint;

  /// queue_title
  ///
  /// In zh, this message translates to:
  /// **'播放队列'**
  String get queue_title;

  /// queue_count
  ///
  /// In zh, this message translates to:
  /// **'{count} 首曲目'**
  String queue_count(int count);

  /// queue_close
  ///
  /// In zh, this message translates to:
  /// **'关闭播放队列'**
  String get queue_close;

  /// queue_empty
  ///
  /// In zh, this message translates to:
  /// **'队列为空'**
  String get queue_empty;

  /// queue_empty_desc
  ///
  /// In zh, this message translates to:
  /// **'开始播放一首歌曲后，接下来的曲目会出现在这里。'**
  String get queue_empty_desc;

  /// queue_clear_after
  ///
  /// In zh, this message translates to:
  /// **'清空后续队列'**
  String get queue_clear_after;

  /// queue_clear_after_semantic
  ///
  /// In zh, this message translates to:
  /// **'清空后续播放队列，保留当前曲目'**
  String get queue_clear_after_semantic;

  /// queue_remove
  ///
  /// In zh, this message translates to:
  /// **'从队列移除'**
  String get queue_remove;

  /// queue_remove_more_semantic
  ///
  /// In zh, this message translates to:
  /// **'{song}，从投屏队列移除'**
  String queue_remove_more_semantic(String song);

  /// queue_more_actions_semantic
  ///
  /// In zh, this message translates to:
  /// **'{song}，更多操作'**
  String queue_more_actions_semantic(String song);

  /// queue_cast_title
  ///
  /// In zh, this message translates to:
  /// **'投屏队列'**
  String get queue_cast_title;

  /// queue_cast_count
  ///
  /// In zh, this message translates to:
  /// **'{count} 首曲目 · 正在投屏到「{device}」'**
  String queue_cast_count(int count, String device);

  /// queue_cast_offline_suffix
  ///
  /// In zh, this message translates to:
  /// **' · 设备离线'**
  String get queue_cast_offline_suffix;

  /// queue_cast_close
  ///
  /// In zh, this message translates to:
  /// **'关闭投屏队列'**
  String get queue_cast_close;

  /// queue_cast_empty
  ///
  /// In zh, this message translates to:
  /// **'投屏队列为空'**
  String get queue_cast_empty;

  /// queue_cast_empty_desc
  ///
  /// In zh, this message translates to:
  /// **'后端投屏队列暂无曲目,可在歌曲菜单中添加到投屏队列。'**
  String get queue_cast_empty_desc;

  /// queue_cast_clear
  ///
  /// In zh, this message translates to:
  /// **'清空并停止投屏'**
  String get queue_cast_clear;

  /// queue_cast_clear_semantic
  ///
  /// In zh, this message translates to:
  /// **'清空投屏队列并停止投屏'**
  String get queue_cast_clear_semantic;

  /// queue_device_local
  ///
  /// In zh, this message translates to:
  /// **'局域网设备'**
  String get queue_device_local;

  /// song_info_title
  ///
  /// In zh, this message translates to:
  /// **'歌曲信息'**
  String get song_info_title;

  /// song_info_duration
  ///
  /// In zh, this message translates to:
  /// **'时长'**
  String get song_info_duration;

  /// song_info_genre
  ///
  /// In zh, this message translates to:
  /// **'按流派'**
  String get song_info_genre;

  /// song_info_disc
  ///
  /// In zh, this message translates to:
  /// **'唱片号'**
  String get song_info_disc;

  /// song_info_audio_title
  ///
  /// In zh, this message translates to:
  /// **'音频信息'**
  String get song_info_audio_title;

  /// song_info_file_type
  ///
  /// In zh, this message translates to:
  /// **'文件类型'**
  String get song_info_file_type;

  /// song_info_bit_rate
  ///
  /// In zh, this message translates to:
  /// **'码率'**
  String get song_info_bit_rate;

  /// song_info_sample_rate
  ///
  /// In zh, this message translates to:
  /// **'采样率'**
  String get song_info_sample_rate;

  /// song_info_bit_depth
  ///
  /// In zh, this message translates to:
  /// **'位深'**
  String get song_info_bit_depth;

  /// song_info_channels
  ///
  /// In zh, this message translates to:
  /// **'声道'**
  String get song_info_channels;

  /// song_info_file_title
  ///
  /// In zh, this message translates to:
  /// **'文件信息'**
  String get song_info_file_title;

  /// song_info_file_size
  ///
  /// In zh, this message translates to:
  /// **'文件大小'**
  String get song_info_file_size;

  /// song_info_path
  ///
  /// In zh, this message translates to:
  /// **'歌曲路径'**
  String get song_info_path;

  /// song_info_actions_title
  ///
  /// In zh, this message translates to:
  /// **'操作'**
  String get song_info_actions_title;

  /// song_info_song_actions
  ///
  /// In zh, this message translates to:
  /// **'歌曲操作'**
  String get song_info_song_actions;

  /// song_info_song_actions_desc
  ///
  /// In zh, this message translates to:
  /// **'下一曲播放、添加到歌单、查看歌手与专辑'**
  String get song_info_song_actions_desc;

  /// song_info_action_row
  ///
  /// In zh, this message translates to:
  /// **'{label}，{description}'**
  String song_info_action_row(String label, String description);

  /// song_info_mono
  ///
  /// In zh, this message translates to:
  /// **'单声道'**
  String get song_info_mono;

  /// song_info_stereo
  ///
  /// In zh, this message translates to:
  /// **'立体声'**
  String get song_info_stereo;

  /// song_info_channels_count
  ///
  /// In zh, this message translates to:
  /// **'{count} 声道'**
  String song_info_channels_count(int count);

  /// song_option_unknown_artist
  ///
  /// In zh, this message translates to:
  /// **'未知歌手'**
  String get song_option_unknown_artist;

  /// song_option_unknown_album
  ///
  /// In zh, this message translates to:
  /// **'未知专辑'**
  String get song_option_unknown_album;

  /// song_option_enqueue
  ///
  /// In zh, this message translates to:
  /// **'加入投屏队列'**
  String get song_option_enqueue;

  /// song_option_enqueued
  ///
  /// In zh, this message translates to:
  /// **'已加入投屏队列'**
  String get song_option_enqueued;

  /// song_option_play_next
  ///
  /// In zh, this message translates to:
  /// **'下一曲播放'**
  String get song_option_play_next;

  /// song_option_play_next_added
  ///
  /// In zh, this message translates to:
  /// **'已添加到下一曲'**
  String get song_option_play_next_added;

  /// song_option_favorite_added
  ///
  /// In zh, this message translates to:
  /// **'已添加红心'**
  String get song_option_favorite_added;

  /// song_option_favorite_removed
  ///
  /// In zh, this message translates to:
  /// **'已取消红心'**
  String get song_option_favorite_removed;

  /// song_option_operation_failed
  ///
  /// In zh, this message translates to:
  /// **'操作失败'**
  String get song_option_operation_failed;

  /// song_option_artist
  ///
  /// In zh, this message translates to:
  /// **'歌手：{name}'**
  String song_option_artist(String name);

  /// song_option_album
  ///
  /// In zh, this message translates to:
  /// **'专辑：{name}'**
  String song_option_album(String name);

  /// song_option_artist_copied
  ///
  /// In zh, this message translates to:
  /// **'已复制歌手: {name}'**
  String song_option_artist_copied(String name);

  /// song_option_album_copied
  ///
  /// In zh, this message translates to:
  /// **'已复制专辑: {name}'**
  String song_option_album_copied(String name);

  /// song_option_title_preview
  ///
  /// In zh, this message translates to:
  /// **'试听歌曲操作'**
  String get song_option_title_preview;

  /// song_option_title
  ///
  /// In zh, this message translates to:
  /// **'歌曲操作'**
  String get song_option_title;

  /// song_option_copied_title
  ///
  /// In zh, this message translates to:
  /// **'已复制歌曲名: {title}'**
  String song_option_copied_title(String title);

  /// song_option_summary_semantic
  ///
  /// In zh, this message translates to:
  /// **'{title}，{artist}，{album}，长按复制歌曲名'**
  String song_option_summary_semantic(
    String title,
    String artist,
    String album,
  );

  /// song_option_selected
  ///
  /// In zh, this message translates to:
  /// **'已选中'**
  String get song_option_selected;

  /// song_option_not_available
  ///
  /// In zh, this message translates to:
  /// **'不可用'**
  String get song_option_not_available;

  /// song_option_playlist_load_failed
  ///
  /// In zh, this message translates to:
  /// **'歌单加载失败'**
  String get song_option_playlist_load_failed;

  /// song_option_no_playlists
  ///
  /// In zh, this message translates to:
  /// **'暂无歌单'**
  String get song_option_no_playlists;

  /// song_option_load_failed_desc
  ///
  /// In zh, this message translates to:
  /// **'请检查网络或服务器状态后重试。'**
  String get song_option_load_failed_desc;

  /// song_option_create_playlist_hint
  ///
  /// In zh, this message translates to:
  /// **'创建歌单后，即可将这首歌曲加入收藏。'**
  String get song_option_create_playlist_hint;

  /// song_option_added_to_playlist
  ///
  /// In zh, this message translates to:
  /// **'已添加到歌单「{name}」'**
  String song_option_added_to_playlist(String name);

  /// song_option_network_error
  ///
  /// In zh, this message translates to:
  /// **'网络异常，添加失败'**
  String get song_option_network_error;

  /// song_option_playlist_row_semantic
  ///
  /// In zh, this message translates to:
  /// **'{name}，{count} 首歌曲'**
  String song_option_playlist_row_semantic(String name, int count);

  /// song_option_song_count
  ///
  /// In zh, this message translates to:
  /// **'{count} 首'**
  String song_option_song_count(int count);

  /// No description provided for @login_connect_server.
  ///
  /// In zh, this message translates to:
  /// **'连接到服务器'**
  String get login_connect_server;

  /// No description provided for @login_confirm_server_first.
  ///
  /// In zh, this message translates to:
  /// **'先确认服务器地址'**
  String get login_confirm_server_first;

  /// No description provided for @login_enter_auth.
  ///
  /// In zh, this message translates to:
  /// **'输入认证信息'**
  String get login_enter_auth;

  /// No description provided for @login_detecting.
  ///
  /// In zh, this message translates to:
  /// **'正在检测…'**
  String get login_detecting;

  /// No description provided for @login_logging_in.
  ///
  /// In zh, this message translates to:
  /// **'正在登录…'**
  String get login_logging_in;

  /// No description provided for @login_next.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get login_next;

  /// No description provided for @login_login.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get login_login;

  /// No description provided for @login_previous.
  ///
  /// In zh, this message translates to:
  /// **'上一步'**
  String get login_previous;

  /// No description provided for @login_detecting_ability.
  ///
  /// In zh, this message translates to:
  /// **'正在检测服务器能力'**
  String get login_detecting_ability;

  /// No description provided for @login_verifying_auth.
  ///
  /// In zh, this message translates to:
  /// **'正在验证认证信息'**
  String get login_verifying_auth;

  /// No description provided for @login_cannot_connect.
  ///
  /// In zh, this message translates to:
  /// **'无法连接到服务器，请检查地址是否正确'**
  String get login_cannot_connect;

  /// No description provided for @login_http_insecure_title.
  ///
  /// In zh, this message translates to:
  /// **'HTTP 连接不安全'**
  String get login_http_insecure_title;

  /// No description provided for @login_http_insecure_body.
  ///
  /// In zh, this message translates to:
  /// **'HTTP 不会加密传输。密码、API Key、令牌以及媒体请求都可能被同一网络中的其他人窃听或篡改。仅当你信任当前网络和该服务器时才继续。'**
  String get login_http_insecure_body;

  /// No description provided for @login_continue_anyway.
  ///
  /// In zh, this message translates to:
  /// **'仍然继续'**
  String get login_continue_anyway;

  /// No description provided for @login_server_section.
  ///
  /// In zh, this message translates to:
  /// **'服务器'**
  String get login_server_section;

  /// No description provided for @login_server_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'MusicFlow 会先探测服务器能力，再决定可用的认证方式。'**
  String get login_server_section_desc;

  /// No description provided for @login_server_url_hint.
  ///
  /// In zh, this message translates to:
  /// **'https://your-server.com'**
  String get login_server_url_hint;

  /// No description provided for @login_server_url_http_helper.
  ///
  /// In zh, this message translates to:
  /// **'优先使用 HTTPS。只有在可信局域网中才建议使用 HTTP。'**
  String get login_server_url_http_helper;

  /// No description provided for @login_server_url_required.
  ///
  /// In zh, this message translates to:
  /// **'请输入完整的 URL（包括 http:// 或 https://）'**
  String get login_server_url_required;

  /// No description provided for @login_library_name_label.
  ///
  /// In zh, this message translates to:
  /// **'音乐库名称（可选）'**
  String get login_library_name_label;

  /// No description provided for @login_library_name_hint.
  ///
  /// In zh, this message translates to:
  /// **'例如：家庭 NAS'**
  String get login_library_name_hint;

  /// No description provided for @login_library_name_helper.
  ///
  /// In zh, this message translates to:
  /// **'不填写则自动使用服务器类型。'**
  String get login_library_name_helper;

  /// No description provided for @login_address_label.
  ///
  /// In zh, this message translates to:
  /// **'线路名称（可选）'**
  String get login_address_label;

  /// No description provided for @login_address_hint.
  ///
  /// In zh, this message translates to:
  /// **'例如：主线路 / 家里'**
  String get login_address_hint;

  /// No description provided for @login_address_helper.
  ///
  /// In zh, this message translates to:
  /// **'不填写则默认使用 Primary。'**
  String get login_address_helper;

  /// No description provided for @login_auth_section.
  ///
  /// In zh, this message translates to:
  /// **'认证信息'**
  String get login_auth_section;

  /// No description provided for @login_auth_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'认证信息只用于连接你的音乐服务器。'**
  String get login_auth_section_desc;

  /// No description provided for @login_opensubsonic_detected.
  ///
  /// In zh, this message translates to:
  /// **'已检测到 OpenSubsonic'**
  String get login_opensubsonic_detected;

  /// No description provided for @login_unknown_server_type.
  ///
  /// In zh, this message translates to:
  /// **'未知服务器类型'**
  String get login_unknown_server_type;

  /// No description provided for @login_username_required.
  ///
  /// In zh, this message translates to:
  /// **'请输入用户名'**
  String get login_username_required;

  /// No description provided for @login_api_key_label.
  ///
  /// In zh, this message translates to:
  /// **'API Key（推荐）'**
  String get login_api_key_label;

  /// No description provided for @login_api_key_helper.
  ///
  /// In zh, this message translates to:
  /// **'填写 API Key 后将优先使用 API Key 认证。'**
  String get login_api_key_helper;

  /// No description provided for @login_or_password.
  ///
  /// In zh, this message translates to:
  /// **'或使用密码'**
  String get login_or_password;

  /// No description provided for @login_password_required.
  ///
  /// In zh, this message translates to:
  /// **'请输入密码'**
  String get login_password_required;

  /// login_step_semantics
  ///
  /// In zh, this message translates to:
  /// **'登录进度，第 {step} 步，共 {total} 步'**
  String login_step_semantics(String step, String total);

  /// No description provided for @login_step_server.
  ///
  /// In zh, this message translates to:
  /// **'服务器'**
  String get login_step_server;

  /// No description provided for @login_step_auth.
  ///
  /// In zh, this message translates to:
  /// **'认证'**
  String get login_step_auth;

  /// No description provided for @search_source_not_specified.
  ///
  /// In zh, this message translates to:
  /// **'未指定来源插件'**
  String get search_source_not_specified;

  /// search_entity_no_playable
  ///
  /// In zh, this message translates to:
  /// **'该{kind}暂无可播放歌曲'**
  String search_entity_no_playable(String kind);

  /// search_play_failed
  ///
  /// In zh, this message translates to:
  /// **'播放失败: {error}'**
  String search_play_failed(String error);

  /// No description provided for @search_import_submitted.
  ///
  /// In zh, this message translates to:
  /// **'已提交入库任务，完成后会通知你'**
  String get search_import_submitted;

  /// search_import_failed
  ///
  /// In zh, this message translates to:
  /// **'入库失败: {error}'**
  String search_import_failed(String error);

  /// search_import_done
  ///
  /// In zh, this message translates to:
  /// **'《{name}》入库完成，可在音乐库查看'**
  String search_import_done(String name);

  /// search_import_entry_failed
  ///
  /// In zh, this message translates to:
  /// **'《{name}》入库失败: {error}'**
  String search_import_entry_failed(String name, String error);

  /// search_playlist_import_submitted
  ///
  /// In zh, this message translates to:
  /// **'《{name}》入库任务已提交，完成后会通知你'**
  String search_playlist_import_submitted(String name);

  /// No description provided for @search_scope_all.
  ///
  /// In zh, this message translates to:
  /// **'所有'**
  String get search_scope_all;

  /// No description provided for @search_scope_all_desc.
  ///
  /// In zh, this message translates to:
  /// **'全部内容'**
  String get search_scope_all_desc;

  /// No description provided for @search_scope_playlist_desc.
  ///
  /// In zh, this message translates to:
  /// **'仅歌单'**
  String get search_scope_playlist_desc;

  /// No description provided for @search_scope_song_desc.
  ///
  /// In zh, this message translates to:
  /// **'即歌曲'**
  String get search_scope_song_desc;

  /// No description provided for @search_scope_artist_desc.
  ///
  /// In zh, this message translates to:
  /// **'歌手'**
  String get search_scope_artist_desc;

  /// No description provided for @search_network_search_failed.
  ///
  /// In zh, this message translates to:
  /// **'全网搜索失败'**
  String get search_network_search_failed;

  /// No description provided for @search_network_no_results.
  ///
  /// In zh, this message translates to:
  /// **'全网暂无结果'**
  String get search_network_no_results;

  /// No description provided for @search_try_another_keyword.
  ///
  /// In zh, this message translates to:
  /// **'换个关键词试试。'**
  String get search_try_another_keyword;

  /// No description provided for @search_bar_clear.
  ///
  /// In zh, this message translates to:
  /// **'清空搜索词'**
  String get search_bar_clear;

  /// No description provided for @search_add_to_library.
  ///
  /// In zh, this message translates to:
  /// **'加入库'**
  String get search_add_to_library;

  /// No description provided for @search_scope_title.
  ///
  /// In zh, this message translates to:
  /// **'搜索范围'**
  String get search_scope_title;

  /// No description provided for @search_scope_select_title.
  ///
  /// In zh, this message translates to:
  /// **'选择搜索范围'**
  String get search_scope_select_title;
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
